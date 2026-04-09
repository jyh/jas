(** GTK rendering for the dock panel system.

    Creates GTK widgets for the anchored right dock with panel groups,
    tab bars, collapse/expand, and panel body placeholders. *)

open Dock

(** Build the dock panel widget inside the given container.
    Returns a refresh function that rebuilds the dock UI when the layout changes. *)
let create (dock_box : GPack.box) (layout : dock_layout) =
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
          let group_box = GPack.vbox ~packing:(dock_box#pack ~expand:false) () in

          (* Tab bar *)
          let tab_bar = GPack.hbox ~packing:(group_box#pack ~expand:false) () in

          (* Grip handle *)
          let grip = GMisc.label ~text:"\xE2\xA0\x81\xE2\xA0\x81" ~packing:(tab_bar#pack ~expand:false) () in
          grip#misc#set_size_request ~width:20 ();

          (* Tab buttons *)
          Array.iteri (fun pi kind ->
            let label = panel_label kind in
            let btn = GButton.button ~label ~packing:(tab_bar#pack ~expand:false) () in
            if pi = group.active then
              btn#misc#modify_bg [`NORMAL, `NAME "#f0f0f0"];
            btn#connect#clicked ~callback:(fun () ->
              set_active_panel layout { group = { dock_id = dock.id; group_idx = gi }; panel_idx = pi };
              rebuild ()
            ) |> ignore
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
          ()
        ) dock.groups
      end
  in
  rebuild ();
  rebuild
