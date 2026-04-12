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

let create (dock_box : GPack.box) (layout : workspace_layout) =
  let drag_ref = ref No_drag in

  let rec rebuild () =
    (* Clear existing children *)
    List.iter (fun w -> w#destroy ()) dock_box#children;

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
              set_active_panel layout { group = { dock_id = dock.id; group_idx = gi }; panel_idx = pi };
              rebuild ()
            ) |> ignore
          ) group.panels
        ) dock.groups
      end else begin
        (* Expanded: render panel groups *)
        Array.iteri (fun gi group ->
          let group_eb = GBin.event_box ~packing:(dock_box#pack ~expand:false) () in
          let group_box = GPack.vbox ~packing:group_eb#add () in

          (* Tab bar *)
          let tab_bar = GPack.hbox ~packing:(group_box#pack ~expand:false) () in

          (* Grip handle *)
          apply_dark_css tab_bar (Printf.sprintf "* { background-color: %s; border-bottom: 1px solid %s; }" !theme_bg_dark !theme_border);

          (* Grip handle — set drag state on press *)
          let grip_eb = GBin.event_box ~packing:(tab_bar#pack ~expand:false) () in
          let grip = GMisc.label ~text:"\xE2\xA0\x81\xE2\xA0\x81" ~packing:grip_eb#add () in
          grip#misc#set_size_request ~width:20 ();
          apply_dark_css grip (Printf.sprintf "* { color: %s; }" !theme_text_hint);
          grip_eb#event#connect#button_press ~callback:(fun _ ->
            drag_ref := Dragging_group { dock_id = dock.id; group_idx = gi }; false
          ) |> ignore;
          grip_eb#event#add [`BUTTON_PRESS];

          (* Tab buttons — set drag state on press, click to activate *)
          Array.iteri (fun pi kind ->
            let label = Panel_menu.panel_label kind in
            let btn = GButton.button ~label ~packing:(tab_bar#pack ~expand:false) () in
            let tab_bg = if pi = group.active then !theme_bg_tab else !theme_bg_tab_inactive in
            apply_dark_css btn (Printf.sprintf "button { color: %s; background: %s; font-size: 11px; padding: 3px 8px; border: none; border-radius: 0; box-shadow: none; min-height: 0; }" !theme_text tab_bg);
            btn#connect#clicked ~callback:(fun () ->
              (match !drag_ref with
               | No_drag ->
                 set_active_panel layout { group = { dock_id = dock.id; group_idx = gi }; panel_idx = pi };
                 rebuild ()
               | _ -> ())
            ) |> ignore;
            btn#event#connect#button_press ~callback:(fun _ ->
              drag_ref := Dragging_panel { group = { dock_id = dock.id; group_idx = gi }; panel_idx = pi }; false
            ) |> ignore;
            btn#event#add [`BUTTON_PRESS]
          ) group.panels;

          (* Collapse chevron *)
          let chevron_label = if group.collapsed then "\xC2\xBB" else "\xC2\xAB" in
          let chevron = GButton.button ~label:chevron_label ~packing:(tab_bar#pack ~from:`END ~expand:false) () in
          apply_dark_css chevron (Printf.sprintf "button { color: %s; background: %s; font-size: 18px; border: none; border-radius: 0; box-shadow: none; min-height: 0; min-width: 0; padding: 0 4px; }" !theme_text_button !theme_bg_dark);
          chevron#connect#clicked ~callback:(fun () ->
            toggle_group_collapsed layout { dock_id = dock.id; group_idx = gi };
            rebuild ()
          ) |> ignore;

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
                List.iter (fun item ->
                  match item with
                  | Panel_menu.Action { label; command; _ } ->
                    let mi = GMenu.menu_item ~label ~packing:menu#append () in
                    mi#connect#activate ~callback:(fun () ->
                      Panel_menu.panel_dispatch active_kind command addr layout;
                      rebuild ()
                    ) |> ignore
                  | Panel_menu.Toggle { label; command } ->
                    let checked = Panel_menu.panel_is_checked active_kind command layout in
                    let mi = GMenu.check_menu_item ~label ~packing:menu#append () in
                    mi#set_active checked;
                    mi#connect#activate ~callback:(fun () ->
                      Panel_menu.panel_dispatch active_kind command addr layout;
                      rebuild ()
                    ) |> ignore
                  | Panel_menu.Radio { label; command; _ } ->
                    let selected = Panel_menu.panel_is_checked active_kind command layout in
                    let mi = GMenu.check_menu_item ~label ~packing:menu#append () in
                    mi#set_active selected;
                    mi#connect#activate ~callback:(fun () ->
                      Panel_menu.panel_dispatch active_kind command addr layout;
                      rebuild ()
                    ) |> ignore
                  | Panel_menu.Separator ->
                    let _sep = GMenu.separator_item ~packing:menu#append () in
                    ()
                ) items;
                menu#popup ~button:1 ~time:(GtkMain.Main.get_current_event_time ())
              ) |> ignore
            | None -> ()
          end;

          (* Panel body placeholder *)
          if not group.collapsed then begin
            match active_panel group with
            | Some kind ->
              let body = GMisc.label ~text:(Panel_menu.panel_label kind) ~packing:(group_box#pack ~expand:false) () in
              body#misc#set_size_request ~height:60 ();
              body#set_xalign 0.0;
              body#set_yalign 0.0;
              apply_dark_css body (Printf.sprintf "* { color: %s; font-size: 12px; padding: 12px; }" !theme_text_body)
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
               if from.dock_id = dock.id then
                 move_group_within_dock layout dock.id ~from:from.group_idx ~to_:gi
               else
                 move_group_to_dock layout ~from ~to_dock:dock.id ~to_idx:gi;
               drag_ref := No_drag;
               rebuild ()
             | Dragging_panel from ->
               if from.group = target_group then
                 reorder_panel layout ~group:target_group ~from:from.panel_idx ~to_:(Array.length group.panels)
               else
                 move_panel_to_group layout ~from ~to_:target_group;
               drag_ref := No_drag;
               rebuild ()
             | No_drag -> ());
            false
          ) |> ignore;
          group_eb#event#add [`BUTTON_RELEASE]
        ) dock.groups
      end
  in
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
      win#move ~x:(int_of_float fd.x) ~y:(int_of_float fd.y);

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
          Workspace_layout.redock layout fid;
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
          apply_dark_css btn (Printf.sprintf "* { color: %s; background-color: %s; }" !theme_text tab_bg);
          btn#connect#clicked ~callback:(fun () ->
            Workspace_layout.set_active_panel layout { group = { dock_id = fid; group_idx = gi }; panel_idx = pi };
            rebuild_floating ()
          ) |> ignore
        ) group.panels;
        if not group.collapsed then begin
          match Workspace_layout.active_panel group with
          | Some kind ->
            let body = GMisc.label ~text:(Panel_menu.panel_label kind) ~packing:(group_box#pack ~expand:false) () in
            body#misc#set_size_request ~height:60 ();
            body#set_xalign 0.0;
            apply_dark_css body (Printf.sprintf "* { color: %s; font-size: 12px; }" !theme_text_body)
          | None -> ()
        end
      ) fd.dock.groups;

      win#show ();
      floating_windows := win :: !floating_windows
    ) layout.floating
  in

  let rebuild_all () = rebuild (); rebuild_floating () in
  rebuild_all ();
  rebuild_all
