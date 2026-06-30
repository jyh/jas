(** GTK rendering for the dock panel system.

    Creates GTK widgets for the anchored right dock with panel groups,
    tab bars, collapse/expand, and panel body placeholders. *)

open Workspace_layout

(** Build the dock panel widget inside the given container.
    Returns a refresh function that rebuilds the dock UI when the layout changes. *)
(* Drag state: shared mutable ref for tracking what's being dragged *)
type drag_state =
  | No_drag
  | Dragging_group of group_addr
  | Dragging_panel of panel_addr

(* Module-level drag state + drop hook. Lets canvas_subwindow's
   button_release handler check whether a panel-tab drag is in
   progress and, if the cursor is outside the dock when released,
   detach the panel into a floating dock. The hook is registered by
   [create] alongside its private drag_ref so the canvas doesn't need
   to know dock_panel internals. Returns true when the drag was
   consumed (so the canvas's own release logic should skip). *)
let _global_drop_handler : (x_root:float -> y_root:float -> bool) ref =
  ref (fun ~x_root:_ ~y_root:_ -> false)

let try_handle_drop ~x_root ~y_root : bool =
  !_global_drop_handler ~x_root ~y_root

(* Drag-motion hook. canvas_subwindow's motion handler calls this so
   the dock can move the preview popup to track the cursor while a
   panel drag is in progress. Returns unit; never consumes the event
   (motion is informational, not a click). *)
let _global_motion_handler : (x_root:float -> y_root:float -> unit) ref =
  ref (fun ~x_root:_ ~y_root:_ -> ())

let notify_drag_motion ~x_root ~y_root : unit =
  !_global_motion_handler ~x_root ~y_root

(* Theme colors — mutable refs resolved from the active appearance *)
let theme_window_bg = ref "#2e2e2e"
let theme_bg = ref "#3c3c3c"
let theme_bg_dark = ref "#333333"
let theme_bg_tab = ref "#4a4a4a"
let theme_bg_tab_inactive = ref "#353535"
let theme_border = ref "#555555"
let theme_text = ref "#cccccc"
let theme_text_dim = ref "#999999"
let theme_text_body = ref "#aaaaaa"
let theme_text_hint = ref "#777777"
let theme_text_button = ref "#888888"

let set_theme name =
  let t = Theme.resolve name in
  theme_window_bg := t.window_bg;
  theme_bg := t.pane_bg;
  theme_bg_dark := t.pane_bg_dark;
  theme_bg_tab := t.tab_active;
  theme_bg_tab_inactive := t.tab_inactive;
  theme_border := t.border;
  theme_text := t.text;
  theme_text_dim := t.text_dim;
  theme_text_body := t.text_body;
  theme_text_hint := t.text_hint;
  theme_text_button := t.text_button

let apply_dark_css w css_str =
  let css = new GObj.css_provider (GtkData.CssProvider.create ()) in
  css#load_from_data css_str;
  w#misc#style_context#add_provider css 600

let create ~get_model ~get_fill_on_top ~(window : GWindow.window) (dock_box : GPack.box) (layout : workspace_layout) =
  let drag_ref = ref No_drag in
  (* A tab [button_press] only RECORDS the press here; the actual panel
     drag ([drag_ref := Dragging_panel]) is armed lazily in the tab's
     [motion_notify] once the pointer moves past [tab_drag_threshold].
     Without this, a plain click (press + release, no movement) was armed
     as a drag and the release resolved as a "drop back on my own group",
     which the drop handler reorders to the end — so every click shoved
     the clicked tab to the rightmost slot. Recording press position +
     gating on real motion makes a click just activate. *)
  let tab_press : (float * float * panel_addr) option ref = ref None in
  let tab_drag_threshold = 5.0 in
  let _color_panel_refresh = ref (fun () -> ()) in
  (* Each rebuild records the current anchored groups as
     (group_addr, panel_count, event_box) so the drop handler can hit-test the
     release point against group screen bounds. The drop must be resolved here
     (not in each group_eb's button_release) because the drag source tab/grip
     holds an implicit pointer grab, so the release is delivered to the SOURCE
     widget, never to the group_eb under the cursor. *)
  let current_groups = ref [] in

  (* Drag preview popup — a small undecorated window with the panel's
     name, repositioned on every motion event so the user has visual
     feedback that something is being dragged. Created on drag start,
     destroyed on release. *)
  let preview_window : GWindow.window option ref = ref None in
  let destroy_preview () =
    (match !preview_window with
     | Some w -> w#destroy (); preview_window := None
     | None -> ())
  in
  let create_preview ~label ~x ~y =
    destroy_preview ();
    let win = GWindow.window
      ~type_hint:`UTILITY ~decorated:false ~resizable:false
      ~width:120 ~height:24 () in
    win#set_transient_for window#as_window;
    win#move ~x:(int_of_float x - 60) ~y:(int_of_float y - 12);
    let eb = GBin.event_box ~packing:win#add () in
    apply_dark_css eb (Printf.sprintf
      "* { background-color: %s; color: %s; border: 1px solid %s; \
       padding: 4px 8px; }"
      !theme_bg_tab !theme_text !theme_border);
    let lbl = GMisc.label ~text:label ~packing:eb#add () in
    apply_dark_css lbl (Printf.sprintf "* { color: %s; }" !theme_text);
    win#misc#show_all ();
    win#present ();
    preview_window := Some win
  in
  let move_preview ~x ~y =
    match !preview_window with
    | Some win -> win#move ~x:(int_of_float x - 60) ~y:(int_of_float y - 12)
    | None -> ()
  in
  _global_motion_handler := (fun ~x_root ~y_root ->
    if !drag_ref <> No_drag then move_preview ~x:x_root ~y:y_root);

  let rec rebuild () =
    (* Clear the per-panel body-renderer registry — the closures
       captured the previous dock's body_containers, which we're
       about to destroy. Without this, [schedule_panel_rerender]
       would dispatch into freed widgets after a structural dock
       rebuild. *)
    Yaml_panel_view.clear_panel_body_renderers ();
    (* Clear existing children *)
    List.iter (fun w -> w#destroy ()) dock_box#children;
    current_groups := [];

    match anchored_dock layout Right with
    | None -> ()
    | Some dock when Array.length dock.groups = 0 -> ()
    | Some dock ->
      (* Set dock width and dark background *)
      let collapsed_w = match panes layout with
        | Some pl -> (match Pane.pane_by_kind pl Pane.Dock with
          | Some p -> (match p.config.collapsed_width with Some w -> int_of_float w | None -> 32)
          | None -> 32)
        | None -> 32 in
      let display_width = if dock.collapsed then collapsed_w else int_of_float dock.width in
      dock_box#misc#set_size_request ~width:display_width ();
      apply_dark_css dock_box (Printf.sprintf "* { background-color: %s; }" !theme_bg);

      if dock.collapsed then begin
        (* Collapsed: show icon strip *)
        Array.iteri (fun gi group ->
          Array.iteri (fun pi kind ->
            let label = Panel_menu.panel_label kind in
            let first = String.sub label 0 1 in
            let btn = GButton.button ~label:first ~packing:(dock_box#pack ~expand:false) () in
            btn#misc#set_size_request ~width:28 ~height:28 ();
            apply_dark_css btn (Printf.sprintf "* { color: %s; background-color: #505050; }" !theme_text_dim);
            btn#connect#clicked ~callback:(fun () ->
              toggle_dock_collapsed layout dock.id;
              (* OP_LOG 3d-2: route through the shared runtime layout dispatcher.
                 [set_active_panel] bumps internally, preserving the dirty signal. *)
              Layout_apply.layout_apply layout
                (Layout_apply.op_set_active_panel
                   { group = { dock_id = dock.id; group_idx = gi }; panel_idx = pi });
              rebuild ()
            ) |> ignore
          ) group.panels
        ) dock.groups
      end else begin
        (* Expanded: render panel groups *)
        Array.iteri (fun gi group ->
          let group_eb = GBin.event_box ~packing:(dock_box#pack ~expand:false) () in
          let group_box = GPack.vbox ~packing:group_eb#add () in
          current_groups :=
            ({ dock_id = dock.id; group_idx = gi }, Array.length group.panels, group_eb)
            :: !current_groups;

          (* Tab bar *)
          let tab_bar = GPack.hbox ~packing:(group_box#pack ~expand:false) () in

          (* Grip handle *)
          apply_dark_css tab_bar (Printf.sprintf "* { background-color: %s; border-bottom: 1px solid %s; }" !theme_bg_dark !theme_border);

          (* Grip handle — set drag state on press *)
          let grip_eb = GBin.event_box ~packing:(tab_bar#pack ~expand:false) () in
          let grip = GMisc.label ~text:"\xE2\xA0\x81\xE2\xA0\x81" ~packing:grip_eb#add () in
          grip#misc#set_size_request ~width:20 ();
          apply_dark_css grip (Printf.sprintf "* { color: %s; }" !theme_text_hint);
          grip_eb#event#connect#button_press ~callback:(fun ev ->
            drag_ref := Dragging_group { dock_id = dock.id; group_idx = gi };
            create_preview ~label:"Group"
              ~x:(GdkEvent.Button.x_root ev)
              ~y:(GdkEvent.Button.y_root ev);
            false
          ) |> ignore;
          grip_eb#event#connect#button_release ~callback:(fun ev ->
            let xr = GdkEvent.Button.x_root ev in
            let yr = GdkEvent.Button.y_root ev in
            ignore (try_handle_drop ~x_root:xr ~y_root:yr);
            destroy_preview ();
            false
          ) |> ignore;
          grip_eb#event#connect#motion_notify ~callback:(fun ev ->
            notify_drag_motion
              ~x_root:(GdkEvent.Motion.x_root ev)
              ~y_root:(GdkEvent.Motion.y_root ev);
            false
          ) |> ignore;
          grip_eb#event#add [`BUTTON_PRESS; `BUTTON_RELEASE; `POINTER_MOTION];

          (* Tab buttons — set drag state on press, click to activate *)
          Array.iteri (fun pi kind ->
            let label = Panel_menu.panel_label kind in
            let btn = GButton.button ~label ~packing:(tab_bar#pack ~expand:false) () in
            let tab_bg = if pi = group.active then !theme_bg_tab else !theme_bg_tab_inactive in
            apply_dark_css btn (Printf.sprintf "button { color: %s; background: %s; font-size: 11px; padding: 3px 8px; border: none; border-radius: 0; box-shadow: none; min-height: 0; }" !theme_text tab_bg);
            btn#connect#clicked ~callback:(fun () ->
              (match !drag_ref with
               | No_drag ->
                 (* OP_LOG 3d-2: route through the shared runtime dispatcher. *)
                 Layout_apply.layout_apply layout
                   (Layout_apply.op_set_active_panel
                      { group = { dock_id = dock.id; group_idx = gi }; panel_idx = pi });
                 rebuild ()
               | _ -> ())
            ) |> ignore;
            btn#event#connect#button_press ~callback:(fun ev ->
              (* Record the press only; arm the drag lazily on motion past
                 the threshold so a click (no movement) just activates. *)
              tab_press := Some
                (GdkEvent.Button.x_root ev, GdkEvent.Button.y_root ev,
                 { group = { dock_id = dock.id; group_idx = gi }; panel_idx = pi });
              false
            ) |> ignore;
            (* Tab button has implicit pointer grab from button_press,
               so the matching release fires on this button regardless
               of where the cursor moved to. Use x_root/y_root (screen
               coords) and [try_handle_drop] to detect drops outside
               the dock and detach into a floating window. Returning
               false lets the button's normal click logic still run for
               in-dock releases. *)
            btn#event#connect#button_release ~callback:(fun ev ->
              let xr = GdkEvent.Button.x_root ev in
              let yr = GdkEvent.Button.y_root ev in
              (* [try_handle_drop] no-ops when [drag_ref = No_drag], so a
                 plain click (drag never armed) falls through to [clicked],
                 which activates the tab. *)
              ignore (try_handle_drop ~x_root:xr ~y_root:yr);
              destroy_preview ();
              tab_press := None;
              false
            ) |> ignore;
            (* Forward motion to the dock-panel motion hook so the
               drag preview can track the cursor. The tab button has
               implicit pointer grab during the drag, so motion events
               stay on this button until release — without this hook
               the canvas's motion handler never fires while the user
               drags from a tab. *)
            btn#event#connect#motion_notify ~callback:(fun ev ->
              let xr = GdkEvent.Motion.x_root ev in
              let yr = GdkEvent.Motion.y_root ev in
              (* Arm the real drag once the pointer moves past the threshold
                 from the recorded press — turning a press-and-hold-move into
                 a drag while leaving a stationary click as a plain click. *)
              (match !tab_press with
               | Some (px, py, addr)
                 when !drag_ref = No_drag
                      && (abs_float (xr -. px) > tab_drag_threshold
                          || abs_float (yr -. py) > tab_drag_threshold) ->
                 drag_ref := Dragging_panel addr;
                 create_preview ~label ~x:xr ~y:yr
               | _ -> ());
              if !drag_ref <> No_drag then
                notify_drag_motion ~x_root:xr ~y_root:yr;
              false
            ) |> ignore;
            btn#event#add [`BUTTON_PRESS; `BUTTON_RELEASE; `POINTER_MOTION]
          ) group.panels;

          (* Header trailing controls — order (left-to-right): chevron,
             then hamburger. Both pack from [END], so the FIRST one
             packed lands at the rightmost edge: pack hamburger before
             chevron to put hamburger on the right. When the group is
             collapsed the hamburger is suppressed so only the chevron
             remains on the right edge. *)

          (* Hamburger menu button — hidden when collapsed *)
          if not group.collapsed then begin
            match active_panel group with
            | Some active_kind ->
              let hamburger = GButton.button ~label:"\xE2\x89\xA1" ~packing:(tab_bar#pack ~from:`END ~expand:false) () in
              apply_dark_css hamburger (Printf.sprintf "button { color: %s; background: %s; font-size: 18px; border: none; border-radius: 0; box-shadow: none; min-height: 0; min-width: 0; padding: 0 4px; }" !theme_text_button !theme_bg_dark);
              hamburger#connect#clicked ~callback:(fun () ->
                let menu = GMenu.menu () in
                let items = Panel_menu.panel_menu active_kind in
                let addr = { group = { dock_id = dock.id; group_idx = gi }; panel_idx = group.active } in
                let model = get_model () in
                let enabled cmd =
                  Panel_menu.panel_command_is_enabled active_kind cmd model in
                List.iter (fun item ->
                  match item with
                  | Panel_menu.Action { label; command; _ } ->
                    let mi = GMenu.menu_item ~label ~packing:menu#append () in
                    mi#misc#set_sensitive (enabled command);
                    mi#connect#activate ~callback:(fun () ->
                      Panel_menu.panel_dispatch active_kind command addr layout ~fill_on_top:(get_fill_on_top ()) ~get_model ~get_panel_selection:Layers_panel_state.get_panel_selection ();
                      rebuild ();
                      !Yaml_panel_view.panel_check_sync_hook ()
                    ) |> ignore
                  | Panel_menu.Toggle { label; command } ->
                    let checked = Panel_menu.panel_is_checked active_kind command layout in
                    let mi = GMenu.check_menu_item ~label ~packing:menu#append () in
                    mi#set_active checked;
                    mi#misc#set_sensitive (enabled command);
                    mi#connect#activate ~callback:(fun () ->
                      Panel_menu.panel_dispatch active_kind command addr layout ~fill_on_top:(get_fill_on_top ()) ~get_model ~get_panel_selection:Layers_panel_state.get_panel_selection ();
                      rebuild ();
                      !Yaml_panel_view.panel_check_sync_hook ()
                    ) |> ignore
                  | Panel_menu.Radio { label; command; _ } ->
                    let selected = Panel_menu.panel_is_checked active_kind command layout in
                    let mi = GMenu.check_menu_item ~label ~packing:menu#append () in
                    mi#set_active selected;
                    mi#misc#set_sensitive (enabled command);
                    mi#connect#activate ~callback:(fun () ->
                      Panel_menu.panel_dispatch active_kind command addr layout ~fill_on_top:(get_fill_on_top ()) ~get_model ~get_panel_selection:Layers_panel_state.get_panel_selection ();
                      rebuild ();
                      !Yaml_panel_view.panel_check_sync_hook ()
                    ) |> ignore
                  | Panel_menu.Separator ->
                    let _sep = GMenu.separator_item ~packing:menu#append () in
                    ()
                ) items;
                menu#popup ~button:1 ~time:(GtkMain.Main.get_current_event_time ())
              ) |> ignore
            | None -> ()
          end;

          (* Collapse chevron — packed AFTER the hamburger so it lands to
             the LEFT of it. When expanded points » (click to collapse
             toward the right edge); when collapsed points « (click to
             expand back). *)
          let chevron_label = if group.collapsed then "\xC2\xAB" else "\xC2\xBB" in
          let chevron = GButton.button ~label:chevron_label ~packing:(tab_bar#pack ~from:`END ~expand:false) () in
          apply_dark_css chevron (Printf.sprintf "button { color: %s; background: %s; font-size: 18px; border: none; border-radius: 0; box-shadow: none; min-height: 0; min-width: 0; padding: 0 4px; }" !theme_text_button !theme_bg_dark);
          chevron#connect#clicked ~callback:(fun () ->
            (* OP_LOG 3d-2: route through the shared runtime dispatcher
               ([toggle_group_collapsed] bumps internally). *)
            Layout_apply.layout_apply layout
              (Layout_apply.op_toggle_group_collapsed { dock_id = dock.id; group_idx = gi });
            rebuild ()
          ) |> ignore;

          (* Panel body — pass [display_width] so render_container can
             allocate exact pixel widths to each Bootstrap-12 cell.
             Without this hint the homogeneous grid's natural width
             (≈ 12 × max(child natural / span)) propagates up through
             the vbox chain to dock_box, which is hosted by a
             GtkLayout that doesn't constrain child size — the dock
             then overflows the viewport. *)
          if not group.collapsed then begin
            match active_panel group with
            | Some kind ->
              (* Wrap the panel body in its OWN container so a state
                 change can repaint just the body without touching
                 the tab bar / chevron / hamburger (which otherwise
                 flash + resize every rebuild). [render_body] tears
                 down the body_container's existing children and
                 re-runs create_panel_body. Registered globally so
                 [schedule_panel_rerender] hits this fast path
                 instead of the full dock rebuild. *)
              let body_container =
                GPack.vbox ~packing:(group_box#pack ~expand:false) () in
              let render_body () =
                (* Clear targeted-update slots first — render_color_swatch
                   re-registers them when the body re-mounts, but any
                   stale references would otherwise queue_draw on
                   already-destroyed widgets. *)
                if kind = Workspace_layout.Color then
                  Yaml_panel_view.clear_color_panel_slots ();
                List.iter (fun w -> w#destroy ()) body_container#children;
                let packing = fun w -> body_container#pack ~expand:false w in
                Yaml_panel_view.create_panel_body ~packing ~kind
                  ~get_model:(fun () -> Some (get_model ()))
                  ~max_width:display_width ()
              in
              render_body ();
              Yaml_panel_view.register_panel_body_renderer kind render_body
            | None -> ()
          end;

          (* Separator *)
          let _sep = GMisc.separator `HORIZONTAL ~packing:(group_box#pack ~expand:false) () in
          apply_dark_css _sep (Printf.sprintf "* { background-color: %s; }" !theme_border);

          (* Drop handling: button_release on the group event_box *)
          group_eb#event#connect#button_release ~callback:(fun _ ->
            let target_group = { dock_id = dock.id; group_idx = gi } in
            (match !drag_ref with
             | Dragging_group from ->
               (* DEFERRED (OP_LOG 3d-2): the dock GROUP-MOVE verbs
                  [move_group_within_dock]/[move_group_to_dock] are NOT in the
                  15-verb [Layout_apply] vocabulary, so they stay direct
                  (mirrors the Rust deferral). *)
               if from.dock_id = dock.id then
                 move_group_within_dock layout dock.id ~from:from.group_idx ~to_:gi
               else
                 move_group_to_dock layout ~from ~to_dock:dock.id ~to_idx:gi;
               drag_ref := No_drag;
               rebuild ()
             | Dragging_panel from ->
               (* OP_LOG 3d-2: route through the shared runtime dispatcher
                  (both verbs bump internally). *)
               if from.group = target_group then
                 Layout_apply.layout_apply layout
                   (Layout_apply.op_reorder_panel target_group
                      ~from:from.panel_idx ~to_:(Array.length group.panels))
               else
                 Layout_apply.layout_apply layout
                   (Layout_apply.op_move_panel_to_group ~from ~to_:target_group);
               drag_ref := No_drag;
               rebuild ()
             | No_drag -> ());
            false
          ) |> ignore;
          group_eb#event#add [`BUTTON_RELEASE]
        ) dock.groups
      end
  in

  (* Forward-declared rebuilder so the drop hook can call rebuild_all
     (anchored + floating) — the floating-dock rendering machinery is
     defined below this point in the file. *)
  let rebuild_all_ref = ref (fun () -> ()) in

  (* Drop hook for releases that miss every group_eb (i.e. user
     released outside the dock entirely). canvas_subwindow's
     button_release calls [try_handle_drop] before its own logic; if
     a panel drag is in progress and the cursor is outside the dock's
     allocation, we detach the panel into a new floating dock at the
     drop point. GTK grabs only block other GtkWindows, not sibling
     widgets in the same window, so we need this cooperation rather
     than a global event capture. *)
  _global_drop_handler := (fun ~x_root ~y_root ->
    if !drag_ref = No_drag then false
    else begin
      let xr = int_of_float x_root in
      let yr = int_of_float y_root in
      let alloc = dock_box#misc#allocation in
      let (pox, poy) =
        try Gdk.Window.get_origin dock_box#misc#window
        with _ -> (0, 0) in
      let dox = pox + alloc.Gtk.x in
      let doy = poy + alloc.Gtk.y in
      let outside =
        xr < dox || xr > dox + alloc.Gtk.width
        || yr < doy || yr > doy + alloc.Gtk.height
      in
      (* Which anchored group is under the release point? The drag source
         (tab / grip) holds the pointer grab, so the release never reaches the
         target group_eb's own handler — hit-test the groups recorded by the
         last rebuild against the event-box screen bounds here instead. *)
      let target =
        List.fold_left (fun acc (addr, pcount, eb) ->
          match acc with
          | Some _ -> acc
          | None ->
            let a = eb#misc#allocation in
            let (gx, gy) =
              try Gdk.Window.get_origin eb#misc#window
              with _ -> (max_int, max_int) in
            if xr >= gx && xr <= gx + a.Gtk.width
               && yr >= gy && yr <= gy + a.Gtk.height
            then Some (addr, pcount) else None
        ) None !current_groups
      in
      let consumed =
        match !drag_ref with
        | Dragging_panel from ->
          (match target with
           | Some (tgt, pcount) when tgt = from.group ->
             (* Released back on its own group: nudge to the end. *)
             Layout_apply.layout_apply layout
               (Layout_apply.op_reorder_panel tgt ~from:from.panel_idx ~to_:pcount);
             true
           | Some (tgt, _) ->
             (* Add the panel to a different group. *)
             Layout_apply.layout_apply layout
               (Layout_apply.op_move_panel_to_group ~from ~to_:tgt);
             true
           | None ->
             if outside then begin
               (* Released outside the dock: detach into a floating dock. *)
               ignore (Workspace_layout.detach_panel layout ~from
                         ~x:x_root ~y:y_root);
               true
             end else
               (* Inside the dock but over no group (the empty area below the
                  groups, or a panel dragged back from a floating window): make
                  a new group at the end of the anchored dock. *)
               (match Workspace_layout.anchored_dock layout
                        Workspace_layout.Right with
                | Some d ->
                  Workspace_layout.insert_panel_as_new_group layout
                    ~from ~to_dock:d.id ~at_idx:(Array.length d.groups);
                  true
                | None -> false))
        | Dragging_group from ->
          (match target with
           | Some (tgt, _) ->
             (* DEFERRED (OP_LOG 3d-2): group-move verbs are not in the
                Layout_apply vocabulary, so they stay direct (mirrors Rust). *)
             if from.dock_id = tgt.dock_id then
               move_group_within_dock layout tgt.dock_id
                 ~from:from.group_idx ~to_:tgt.group_idx
             else
               move_group_to_dock layout ~from
                 ~to_dock:tgt.dock_id ~to_idx:tgt.group_idx;
             true
           | None -> false)
        | No_drag -> false
      in
      drag_ref := No_drag;
      if consumed then !rebuild_all_ref ();
      consumed
    end);
  ignore window;
  (* Floating dock windows *)
  let floating_windows : GWindow.window list ref = ref [] in

  let rec rebuild_floating () =
    List.iter (fun w -> w#destroy ()) !floating_windows;
    floating_windows := [];
    List.iter (fun (fd : Workspace_layout.floating_dock) ->
      let fid = fd.dock.id in
      let win = GWindow.window
        ~type_hint:`UTILITY
        ~decorated:false
        ~width:(int_of_float fd.dock.width)
        ~height:200
        () in
      (* Keep the floating panel stacked above the main window so the
         canvas can't draw over it. transient_for ties its lifetime to
         the parent (closed when main window closes) and asks the
         window manager to keep it on top of [window]. *)
      win#set_transient_for window#as_window;
      win#move ~x:(int_of_float fd.x) ~y:(int_of_float fd.y);

      (* Apply the active theme's background to the window itself so
         the chrome around the panel content matches the dock — without
         this the floating panel renders on the GTK default light grey. *)
      apply_dark_css win
        (Printf.sprintf "* { background-color: %s; color: %s; }"
           !theme_bg !theme_text);

      let vbox = GPack.vbox ~packing:win#add () in

      (* Title bar *)
      let title_bar = GBin.event_box ~packing:(vbox#pack ~expand:false) () in
      let title_label = GMisc.label ~text:" " ~packing:title_bar#add () in
      title_label#misc#set_size_request ~height:20 ();
      apply_dark_css title_bar (Printf.sprintf "* { background-color: %s; color: %s; }" !theme_bg_dark !theme_text_dim);

      (* Drag to reposition *)
      let drag_start = ref None in
      title_bar#event#connect#button_press ~callback:(fun ev ->
        let mx = GdkEvent.Button.x_root ev in
        let my = GdkEvent.Button.y_root ev in
        drag_start := Some (mx -. fd.x, my -. fd.y);
        Workspace_layout.bring_to_front layout fid;
        true
      ) |> ignore;
      title_bar#event#connect#motion_notify ~callback:(fun ev ->
        (match !drag_start with
         | Some (off_x, off_y) ->
           let mx = GdkEvent.Motion.x_root ev in
           let my = GdkEvent.Motion.y_root ev in
           let nx = mx -. off_x in
           let ny = my -. off_y in
           Workspace_layout.set_floating_position layout fid ~x:nx ~y:ny;
           win#move ~x:(int_of_float nx) ~y:(int_of_float ny)
         | None -> ());
        true
      ) |> ignore;
      title_bar#event#connect#button_release ~callback:(fun _ ->
        drag_start := None; true
      ) |> ignore;
      title_bar#event#add [`BUTTON_PRESS; `BUTTON_RELEASE; `POINTER_MOTION];

      (* Double-click to redock *)
      title_bar#event#connect#button_press ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 &&
           GdkEvent.get_type (ev :> GdkEvent.any) = `TWO_BUTTON_PRESS then begin
          (* OP_LOG 3d-2: route through the shared runtime dispatcher
             ([redock] bumps internally). *)
          Layout_apply.layout_apply layout (Layout_apply.op_redock fid);
          rebuild ();
          rebuild_floating ();
          true
        end else false
      ) |> ignore;

      (* Panel groups *)
      Array.iteri (fun gi (group : Workspace_layout.panel_group) ->
        let group_box = GPack.vbox ~packing:(vbox#pack ~expand:false) () in
        let tab_bar = GPack.hbox ~packing:(group_box#pack ~expand:false) () in
        apply_dark_css tab_bar (Printf.sprintf "* { background-color: %s; }" !theme_bg_dark);
        let grip = GMisc.label ~text:"\xE2\xA0\x81\xE2\xA0\x81" ~packing:(tab_bar#pack ~expand:false) () in
        grip#misc#set_size_request ~width:20 ();
        apply_dark_css grip (Printf.sprintf "* { color: %s; }" !theme_text_hint);
        Array.iteri (fun pi kind ->
          let label = Panel_menu.panel_label kind in
          let btn = GButton.button ~label ~packing:(tab_bar#pack ~expand:false) () in
          let tab_bg = if pi = group.active then !theme_bg_tab else !theme_bg_tab_inactive in
          (* Match the anchored-dock tab CSS — without border / box-shadow /
             border-radius overrides the GTK default chrome shows through
             and the tab looks light grey instead of themed. *)
          apply_dark_css btn (Printf.sprintf
            "button { color: %s; background: %s; font-size: 11px; \
             padding: 3px 8px; border: none; border-radius: 0; \
             box-shadow: none; min-height: 0; }"
            !theme_text tab_bg);
          btn#connect#clicked ~callback:(fun () ->
            (match !drag_ref with
             | No_drag ->
               (* OP_LOG 3d-2: route through the shared runtime dispatcher. *)
               Layout_apply.layout_apply layout
                 (Layout_apply.op_set_active_panel
                    { group = { dock_id = fid; group_idx = gi }; panel_idx = pi });
               rebuild_floating ()
             | _ -> ())
          ) |> ignore;
          (* Same drag wiring as anchored-dock tabs — lets the user
             drag a panel out of the floating dock back to the dock or
             to another floating window. See the anchored handler for
             the rationale. *)
          btn#event#connect#button_press ~callback:(fun ev ->
            drag_ref := Dragging_panel { group = { dock_id = fid; group_idx = gi }; panel_idx = pi };
            create_preview ~label
              ~x:(GdkEvent.Button.x_root ev)
              ~y:(GdkEvent.Button.y_root ev);
            false
          ) |> ignore;
          btn#event#connect#button_release ~callback:(fun ev ->
            ignore (try_handle_drop
                      ~x_root:(GdkEvent.Button.x_root ev)
                      ~y_root:(GdkEvent.Button.y_root ev));
            destroy_preview ();
            false
          ) |> ignore;
          btn#event#connect#motion_notify ~callback:(fun ev ->
            notify_drag_motion
              ~x_root:(GdkEvent.Motion.x_root ev)
              ~y_root:(GdkEvent.Motion.y_root ev);
            false
          ) |> ignore;
          btn#event#add [`BUTTON_PRESS; `BUTTON_RELEASE; `POINTER_MOTION]
        ) group.panels;
        if not group.collapsed then begin
          match Workspace_layout.active_panel group with
          | Some kind ->
            let packing = fun w -> group_box#pack ~expand:false w in
            Yaml_panel_view.create_panel_body ~packing ~kind
              ~get_model:(fun () -> Some (get_model ()))
              ~max_width:(int_of_float fd.dock.width) ()
          | None -> ()
        end
      ) fd.dock.groups;

      win#show ();
      floating_windows := win :: !floating_windows
    ) layout.floating
  in

  let rebuild_all () = rebuild (); rebuild_floating () in
  rebuild_all_ref := rebuild_all;
  (* Expose the rebuild to the YAML widget click handlers so they
     can force a structural re-render after state writes that
     change bind: { z_index, color, ... } evaluations — the
     color_swatch fill/stroke click is the canonical case. *)
  Yaml_panel_view.panel_rerender_hook := rebuild_all;
  rebuild_all ();
  rebuild_all
