(** GTK rendering for the dock panel system.

    Creates GTK widgets for the anchored right dock with panel groups,
    tab bars, collapse/expand, and panel body placeholders. *)

open Dock

(** Build the dock panel widget inside the given container.
    Returns a refresh function that rebuilds the dock UI when the layout changes. *)
(* Drag state: shared mutable ref for tracking what's being dragged *)
type drag_state =
  | No_drag
  | Dragging_group of group_addr
  | Dragging_panel of panel_addr

let create (dock_box : GPack.box) (layout : dock_layout) =
  let drag_ref = ref No_drag in

  let rec rebuild () =
    (* Clear existing children *)
    List.iter (fun w -> w#destroy ()) dock_box#children;

    match anchored_dock layout Right with
    | None -> ()
    | Some dock when Array.length dock.groups = 0 -> ()
    | Some dock ->
      (* Set dock width *)
      dock_box#misc#set_size_request ~width:(int_of_float dock.width) ();

      (* Collapse/expand toggle *)
      let toggle_btn = GButton.button ~packing:(dock_box#pack ~expand:false) () in
      toggle_btn#set_label (if dock.collapsed then "\xE2\x97\x80" else "\xE2\x96\xB6");
      toggle_btn#misc#set_size_request ~height:20 ();
      toggle_btn#connect#clicked ~callback:(fun () ->
        toggle_dock_collapsed layout dock.id;
        rebuild ()
      ) |> ignore;

      if dock.collapsed then begin
        (* Collapsed: show icon strip *)
        Array.iteri (fun gi group ->
          Array.iteri (fun pi kind ->
            let label = panel_label kind in
            let first = String.sub label 0 1 in
            let btn = GButton.button ~label:first ~packing:(dock_box#pack ~expand:false) () in
            btn#misc#set_size_request ~width:28 ~height:28 ();
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
          (* Grip handle — set drag state on press *)
          let grip_eb = GBin.event_box ~packing:(tab_bar#pack ~expand:false) () in
          let grip = GMisc.label ~text:"\xE2\xA0\x81\xE2\xA0\x81" ~packing:grip_eb#add () in
          grip#misc#set_size_request ~width:20 ();
          grip_eb#event#connect#button_press ~callback:(fun _ ->
            drag_ref := Dragging_group { dock_id = dock.id; group_idx = gi }; false
          ) |> ignore;
          grip_eb#event#add [`BUTTON_PRESS];

          (* Tab buttons — set drag state on press, click to activate *)
          Array.iteri (fun pi kind ->
            let label = panel_label kind in
            let btn = GButton.button ~label ~packing:(tab_bar#pack ~expand:false) () in
            if pi = group.active then
              btn#misc#modify_bg [`NORMAL, `NAME "#f0f0f0"];
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
          let chevron_label = if group.collapsed then "\xE2\x96\xBC" else "\xE2\x96\xB2" in
          let chevron = GButton.button ~label:chevron_label ~packing:(tab_bar#pack ~from:`END ~expand:false) () in
          chevron#connect#clicked ~callback:(fun () ->
            toggle_group_collapsed layout { dock_id = dock.id; group_idx = gi };
            rebuild ()
          ) |> ignore;

          (* Panel body placeholder *)
          if not group.collapsed then begin
            match active_panel group with
            | Some kind ->
              let body = GMisc.label ~text:(panel_label kind) ~packing:(group_box#pack ~expand:false) () in
              body#misc#set_size_request ~height:60 ();
              body#set_xalign 0.0;
              body#set_yalign 0.0
            | None -> ()
          end;

          (* Separator *)
          let _sep = GMisc.separator `HORIZONTAL ~packing:(group_box#pack ~expand:false) () in

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
    List.iter (fun (fd : Dock.floating_dock) ->
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
      title_bar#misc#modify_bg [`NORMAL, `NAME "#d0d0d0"];

      (* Drag to reposition *)
      let drag_start = ref None in
      title_bar#event#connect#button_press ~callback:(fun ev ->
        let mx = GdkEvent.Button.x_root ev in
        let my = GdkEvent.Button.y_root ev in
        drag_start := Some (mx -. fd.x, my -. fd.y);
        Dock.bring_to_front layout fid;
        true
      ) |> ignore;
      title_bar#event#connect#motion_notify ~callback:(fun ev ->
        (match !drag_start with
         | Some (off_x, off_y) ->
           let mx = GdkEvent.Motion.x_root ev in
           let my = GdkEvent.Motion.y_root ev in
           let nx = mx -. off_x in
           let ny = my -. off_y in
           Dock.set_floating_position layout fid ~x:nx ~y:ny;
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
          Dock.redock layout fid;
          rebuild ();
          rebuild_floating ();
          true
        end else false
      ) |> ignore;

      (* Panel groups *)
      Array.iteri (fun gi (group : Dock.panel_group) ->
        let group_box = GPack.vbox ~packing:(vbox#pack ~expand:false) () in
        let tab_bar = GPack.hbox ~packing:(group_box#pack ~expand:false) () in
        let grip = GMisc.label ~text:"\xE2\xA0\x81\xE2\xA0\x81" ~packing:(tab_bar#pack ~expand:false) () in
        grip#misc#set_size_request ~width:20 ();
        Array.iteri (fun pi kind ->
          let label = Dock.panel_label kind in
          let btn = GButton.button ~label ~packing:(tab_bar#pack ~expand:false) () in
          if pi = group.active then
            btn#misc#modify_bg [`NORMAL, `NAME "#f0f0f0"];
          btn#connect#clicked ~callback:(fun () ->
            Dock.set_active_panel layout { group = { dock_id = fid; group_idx = gi }; panel_idx = pi };
            rebuild_floating ()
          ) |> ignore
        ) group.panels;
        if not group.collapsed then begin
          match Dock.active_panel group with
          | Some kind ->
            let body = GMisc.label ~text:(Dock.panel_label kind) ~packing:(group_box#pack ~expand:false) () in
            body#misc#set_size_request ~height:60 ();
            body#set_xalign 0.0
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
