(** Menubar for the main window. *)

let group_selection (model : Model.model) () =
  let doc = model#document in
  let sel = doc.Document.selection in
  if Document.PathMap.is_empty sel then ()
  else begin
    let paths = Document.PathMap.fold (fun path _ acc -> path :: acc) sel [] in
    let sorted_paths = List.sort compare paths in
    if List.length sorted_paths < 2 then ()
    else begin
      (* Check all selected elements are siblings *)
      let parent p = match List.rev p with _ :: rest -> List.rev rest | [] -> [] in
      let first_parent = parent (List.hd sorted_paths) in
      if List.for_all (fun p -> parent p = first_parent) sorted_paths then begin
        let elements = List.map (fun p -> Document.get_element doc p) sorted_paths in
        model#snapshot;
        (* Delete in reverse order *)
        let rev_paths = List.sort (fun a b -> compare b a) sorted_paths in
        let new_doc = List.fold_left Document.delete_element doc rev_paths in
        (* Create group and insert at position of first element *)
        let group = Element.make_group (Array.of_list elements) in
        let insert_path = List.hd sorted_paths in
        let layer_idx = List.hd insert_path in
        let child_idx = match insert_path with _ :: i :: _ -> i | _ -> 0 in
        let layer = new_doc.Document.layers.(layer_idx) in
        let old_children = Document.children_of layer in
        let n = Array.length old_children in
        let new_children = Array.init (n + 1) (fun i ->
          if i < child_idx then old_children.(i)
          else if i = child_idx then group
          else old_children.(i - 1)
        ) in
        let new_layer = Document.with_children layer new_children in
        let new_layers = Array.copy new_doc.Document.layers in
        new_layers.(layer_idx) <- new_layer;
        let new_sel = Document.PathMap.singleton insert_path
          (Document.make_element_selection insert_path) in
        model#set_document { new_doc with
          Document.layers = new_layers;
          Document.selection = new_sel }
      end
    end
  end

let ungroup_selection (model : Model.model) () =
  let doc = model#document in
  let sel = doc.Document.selection in
  if Document.PathMap.is_empty sel then ()
  else begin
    (* Collect selected paths that are Groups *)
    let group_paths = Document.PathMap.fold (fun path _ acc ->
      try
        let elem = Document.get_element doc path in
        (match elem with Element.Group _ -> path :: acc | _ -> acc)
      with _ -> acc
    ) sel [] in
    let sorted_paths = List.sort compare group_paths in
    if sorted_paths = [] then ()
    else begin
      model#snapshot;
      (* Process in reverse order to preserve indices *)
      let new_doc = List.fold_left (fun doc gpath ->
        let group_elem = Document.get_element doc gpath in
        let children = Document.children_of group_elem in
        (* Delete the group *)
        let doc = Document.delete_element doc gpath in
        let layer_idx = List.hd gpath in
        let child_idx = match gpath with _ :: i :: _ -> i | _ -> 0 in
        let layer = doc.Document.layers.(layer_idx) in
        let old_children = Document.children_of layer in
        let n_old = Array.length old_children in
        let n_new = Array.length children in
        let new_children = Array.init (n_old + n_new) (fun i ->
          if i < child_idx then old_children.(i)
          else if i < child_idx + n_new then children.(i - child_idx)
          else old_children.(i - n_new)
        ) in
        let new_layer = Document.with_children layer new_children in
        let new_layers = Array.copy doc.Document.layers in
        new_layers.(layer_idx) <- new_layer;
        { doc with Document.layers = new_layers }
      ) doc (List.rev sorted_paths) in
      (* Build selection for unpacked children *)
      let new_sel = ref Document.PathMap.empty in
      let offset = ref 0 in
      List.iter (fun gpath ->
        let group_elem = Document.get_element doc gpath in
        let children = Document.children_of group_elem in
        let n_children = Array.length children in
        let layer_idx = List.hd gpath in
        let child_idx = (match gpath with _ :: i :: _ -> i | _ -> 0) + !offset in
        for j = 0 to n_children - 1 do
          let path = [layer_idx; child_idx + j] in
          let elem = Document.get_element new_doc path in
          let n = Element.control_point_count elem in
          new_sel := Document.PathMap.add path
            (Document.make_element_selection ~control_points:(List.init n Fun.id) path)
            !new_sel
        done;
        offset := !offset + n_children - 1
      ) sorted_paths;
      model#set_document { new_doc with Document.selection = !new_sel }
    end
  end

let ungroup_all (model : Model.model) () =
  let doc = model#document in
  let changed = ref false in
  let rec flatten children =
    Array.to_list children |> List.concat_map (fun child ->
      match child with
      | Element.Group { children = gc; locked = false; _ } ->
        changed := true;
        flatten gc
      | Element.Group r ->
        (* Locked group: recurse into children but keep the group *)
        let new_children = Array.of_list (flatten r.children) in
        [Element.Group { r with children = new_children }]
      | _ -> [child]
    )
  in
  let new_layers = Array.map (fun layer ->
    match layer with
    | Element.Layer r ->
      let new_children = Array.of_list (flatten r.children) in
      Element.Layer { r with children = new_children }
    | _ -> layer
  ) doc.Document.layers in
  if !changed then begin
    model#snapshot;
    model#set_document { doc with
      Document.layers = new_layers;
      Document.selection = Document.PathMap.empty }
  end

let copy_selection (model : Model.model) () =
  let doc = model#document in
  let sel = doc.Document.selection in
  if Document.PathMap.is_empty sel then ()
  else begin
    let elements = Document.PathMap.fold (fun path _ acc ->
      try Document.get_element doc path :: acc
      with _ -> acc
    ) sel [] in
    match elements with
    | [] -> ()
    | elems ->
      let temp_doc = Document.make_document
        [|Element.make_layer (Array.of_list (List.rev elems))|] in
      let svg = Svg.document_to_svg temp_doc in
      let clipboard = GtkBase.Clipboard.get Gdk.Atom.clipboard in
      GtkBase.Clipboard.set_text clipboard svg
  end

let cut_selection (model : Model.model) () =
  model#snapshot;
  copy_selection model ();
  model#set_document (Document.delete_selection model#document)

let rec translate_element elem dx dy =
  if dx = 0.0 && dy = 0.0 then elem
  else
    match elem with
    | Element.Group { children; opacity; transform; locked; visibility; blend_mode;
                      isolated_blending; knockout_group; _ } ->
      Element.Group { children = Array.map (fun c -> translate_element c dx dy) children;
                      opacity; transform; locked; visibility; blend_mode;
                      mask = None;
                      isolated_blending; knockout_group }
    | Element.Layer { name; children; opacity; transform; locked; visibility; blend_mode;
                      isolated_blending; knockout_group; _ } ->
      Element.Layer { name; children = Array.map (fun c -> translate_element c dx dy) children;
                      opacity; transform; locked; visibility; blend_mode;
                      mask = None;
                      isolated_blending; knockout_group }
    | _ ->
      let n = Element.control_point_count elem in
      let indices = List.init n Fun.id in
      Element.move_control_points elem indices dx dy

let is_svg text =
  let s = String.trim text in
  let starts_with prefix =
    String.length s >= String.length prefix &&
    String.sub s 0 (String.length prefix) = prefix
  in
  starts_with "<?xml" || starts_with "<svg"

let paste_clipboard (model : Model.model) offset () =
  model#snapshot;
  let clipboard = GtkBase.Clipboard.get Gdk.Atom.clipboard in
  GtkBase.Clipboard.request_text clipboard ~callback:(fun text_opt ->
    match text_opt with
    | None -> ()
    | Some text when String.length text = 0 -> ()
    | Some text ->
      let doc = model#document in
      let new_sel = ref Document.PathMap.empty in
      if is_svg text then begin
        let pasted_doc = Svg.svg_to_document text in
        let new_layers = Array.copy doc.Document.layers in
        Array.iter (fun pasted_layer ->
          let children = match pasted_layer with
            | Element.Layer { children; _ } ->
              Array.map (fun c -> translate_element c offset offset) children
            | _ -> [||]
          in
          if Array.length children = 0 then ()
          else begin
            let name = match pasted_layer with
              | Element.Layer { name; _ } -> name
              | _ -> ""
            in
            (* Find matching layer by name *)
            let target_idx = ref (-1) in
            if name <> "" then
              Array.iteri (fun i existing ->
                if !target_idx < 0 then
                  match existing with
                  | Element.Layer { name = n; _ } when n = name ->
                    target_idx := i
                  | _ -> ()
              ) new_layers;
            if !target_idx < 0 then
              target_idx := doc.Document.selected_layer;
            let idx = !target_idx in
            (* Record paths for pasted elements *)
            let base = match new_layers.(idx) with
              | Element.Layer { children = ec; _ } -> Array.length ec
              | _ -> 0
            in
            Array.iteri (fun j child ->
              let path = [idx; base + j] in
              let n = Element.control_point_count child in
              new_sel := Document.PathMap.add path
                (Document.make_element_selection ~control_points:(List.init n Fun.id) path)
                !new_sel
            ) children;
            match new_layers.(idx) with
            | Element.Layer { name = n; children = ec; opacity; transform; locked; visibility; blend_mode;
                              isolated_blending; knockout_group; _ } ->
              new_layers.(idx) <- Element.Layer { name = n; children = Array.append ec children; opacity; transform; locked; visibility; blend_mode;
                                                   mask = None;
                                                   isolated_blending; knockout_group }
            | _ -> ()
          end
        ) pasted_doc.Document.layers;
        model#set_document { doc with layers = new_layers;
                                      selection = !new_sel }
      end else begin
        (* Plain text: create a Text element *)
        let elem = Element.make_text (offset) (offset +. 16.0) text in
        let idx = doc.Document.selected_layer in
        let base = match doc.Document.layers.(idx) with
          | Element.Layer { children; _ } -> Array.length children
          | _ -> 0
        in
        let path = [idx; base] in
        let n = Element.control_point_count elem in
        new_sel := Document.PathMap.add path
          (Document.make_element_selection ~control_points:(List.init n Fun.id) path)
          !new_sel;
        let new_layers = Array.mapi (fun i l ->
          if i = idx then
            match l with
            | Element.Layer layer ->
              Element.Layer { layer with children = Array.append layer.children [| elem |] }
            | _ -> l
          else l
        ) doc.Document.layers in
        model#set_document { doc with layers = new_layers;
                                      selection = !new_sel }
      end
  )

let open_file on_open (parent : GWindow.window) () =
  let dialog = GWindow.file_chooser_dialog
    ~action:`OPEN
    ~title:"Open"
    ~parent
    () in
  dialog#add_button_stock `CANCEL `CANCEL;
  dialog#add_button_stock `OPEN `ACCEPT;
  let filter = GFile.filter ~name:"SVG Files" ~patterns:["*.svg"] () in
  dialog#add_filter filter;
  dialog#set_filter filter;
  begin match dialog#run () with
  | `ACCEPT ->
    begin match dialog#filename with
    | Some path ->
      let max_file_size = 100 * 1024 * 1024 in
      let ic = open_in path in
      let n = in_channel_length ic in
      if n > max_file_size then begin
        close_in ic;
        dialog#destroy ();
        let _ = GWindow.message_dialog ~message:"File too large (over 100 MB)."
          ~message_type:`ERROR ~buttons:GWindow.Buttons.ok ~parent () in ()
      end else begin
        let svg = really_input_string ic n in
        close_in ic;
        let new_model = Model.create
          ~document:(Svg.svg_to_document svg) ~filename:path () in
        dialog#destroy ();
        on_open new_model
      end
    | None -> dialog#destroy ()
    end
  | _ -> dialog#destroy ()
  end

let save_as (model : Model.model) (parent : GWindow.window) () =
  let dialog = GWindow.file_chooser_dialog
    ~action:`SAVE
    ~title:"Save As"
    ~parent
    () in
  dialog#add_button_stock `CANCEL `CANCEL;
  dialog#add_button_stock `SAVE `ACCEPT;
  dialog#set_current_name (Filename.basename model#filename);
  let filter = GFile.filter ~name:"SVG Files" ~patterns:["*.svg"] () in
  dialog#add_filter filter;
  dialog#set_filter filter;
  dialog#set_do_overwrite_confirmation true;
  begin match dialog#run () with
  | `ACCEPT ->
    begin match dialog#filename with
    | Some path ->
      let svg = Svg.document_to_svg model#document in
      let oc = open_out path in
      output_string oc svg;
      close_out oc;
      model#mark_saved;
      model#set_filename path
    | None -> ()
    end
  | _ -> ()
  end;
  dialog#destroy ()

let is_untitled filename =
  String.length filename >= 9 && String.sub filename 0 9 = "Untitled-"

let save (model : Model.model) (parent : GWindow.window) () =
  if is_untitled model#filename then
    save_as model parent ()
  else begin
    let svg = Svg.document_to_svg model#document in
    let oc = open_out model#filename in
    output_string oc svg;
    close_out oc;
    model#mark_saved
  end

let revert (get_model : unit -> Model.model) (parent : GWindow.window) () =
  let model = get_model () in
  if not model#is_modified then ()
  else if is_untitled model#filename then ()
  else begin
    let dialog = GWindow.message_dialog
      ~message:(Printf.sprintf "Revert to the saved version of \"%s\"?\n\nAll current modifications will be lost." model#filename)
      ~message_type:`WARNING
      ~buttons:GWindow.Buttons.ok_cancel
      ~parent
      () in
    let response = dialog#run () in
    dialog#destroy ();
    match response with
    | `OK ->
      let max_file_size = 100 * 1024 * 1024 in
      let ic = open_in model#filename in
      let n = in_channel_length ic in
      if n > max_file_size then begin
        close_in ic;
        let _ = GWindow.message_dialog ~message:"File too large (over 100 MB)."
          ~message_type:`ERROR ~buttons:GWindow.Buttons.ok ~parent () in ()
      end else begin
        let svg = really_input_string ic n in
        close_in ic;
        model#snapshot;
        model#set_document (Svg.svg_to_document svg);
        model#mark_saved
      end
    | _ -> ()
  end

let create (get_model : unit -> Model.model) (parent : GWindow.window) ~on_open ?(workspace_layout : Workspace_layout.workspace_layout option) ?(app_config : Workspace_layout.app_config option) ?(refresh_dock : (unit -> unit) option) (vbox : GPack.box) =
  let m () = get_model () in
  (* Menubar *)
  let menubar = GMenu.menu_bar ~packing:(fun w -> vbox#pack w) () in
  let menubar_css = new GObj.css_provider (GtkData.CssProvider.create ()) in
  let apply_menubar_css () =
    menubar_css#load_from_data (Printf.sprintf
      "menubar, menubar > menuitem, menu, menu > menuitem { background-color: %s; color: %s; }"
      !(Dock_panel.theme_bg_dark) !(Dock_panel.theme_text))
  in
  apply_menubar_css ();
  menubar#misc#style_context#add_provider menubar_css 600;
  let factory = new GMenu.factory menubar in

  (* File menu *)
  let _file_menu = factory#add_submenu "File" in
  let file_factory = new GMenu.factory _file_menu in
  ignore (file_factory#add_item "New" ~key:GdkKeysyms._n ~callback:(fun () -> on_open (Model.create ())));
  ignore (file_factory#add_item "Open..." ~key:GdkKeysyms._o ~callback:(open_file on_open parent));
  ignore (file_factory#add_item "Save" ~key:GdkKeysyms._s ~callback:(fun () -> save (m ()) parent ()));
  ignore (file_factory#add_item "Save As..." ~key:GdkKeysyms._s ~callback:(fun () -> save_as (m ()) parent ()));
  ignore (file_factory#add_item "Revert" ~callback:(revert m parent));
  ignore (file_factory#add_separator ());
  ignore (file_factory#add_item "Quit" ~key:GdkKeysyms._q ~callback:(fun () -> GMain.quit ()));

  (* Edit menu *)
  let _edit_menu = factory#add_submenu "Edit" in
  let edit_factory = new GMenu.factory _edit_menu in
  ignore (edit_factory#add_item "Undo" ~key:GdkKeysyms._z ~callback:(fun () -> (m ())#undo));
  ignore (edit_factory#add_item "Redo" ~callback:(fun () -> (m ())#redo));
  ignore (edit_factory#add_separator ());
  ignore (edit_factory#add_item "Cut" ~key:GdkKeysyms._x ~callback:(fun () -> cut_selection (m ()) ()));
  ignore (edit_factory#add_item "Copy" ~key:GdkKeysyms._c ~callback:(fun () -> copy_selection (m ()) ()));
  ignore (edit_factory#add_item "Paste" ~key:GdkKeysyms._v ~callback:(fun () -> paste_clipboard (m ()) Canvas_tool.paste_offset ()));
  ignore (edit_factory#add_item "Paste in Place" ~callback:(fun () -> paste_clipboard (m ()) 0.0 ()));
  ignore (edit_factory#add_separator ());
  ignore (edit_factory#add_item "Select All" ~key:GdkKeysyms._a ~callback:(fun () ->
    let model = m () in
    (new Controller.controller ~model ())#select_all));

  (* Object menu *)
  let _object_menu = factory#add_submenu "Object" in
  let object_factory = new GMenu.factory _object_menu in
  ignore (object_factory#add_item "Group" ~key:GdkKeysyms._g ~callback:(fun () -> group_selection (m ()) ()));
  ignore (object_factory#add_item "Ungroup" ~callback:(fun () -> ungroup_selection (m ()) ()));
  ignore (object_factory#add_item "Ungroup All" ~callback:(fun () -> ungroup_all (m ()) ()));
  ignore (object_factory#add_separator ());
  ignore (object_factory#add_item "Lock" ~key:GdkKeysyms._2 ~callback:(fun () ->
    let model = m () in model#snapshot; (new Controller.controller ~model ())#lock_selection));
  ignore (object_factory#add_item "Unlock All" ~callback:(fun () ->
    let model = m () in model#snapshot; (new Controller.controller ~model ())#unlock_all));
  ignore (object_factory#add_separator ());
  ignore (object_factory#add_item "Hide" ~key:GdkKeysyms._3 ~callback:(fun () ->
    let model = m () in model#snapshot; (new Controller.controller ~model ())#hide_selection));
  ignore (object_factory#add_item "Show All" ~callback:(fun () ->
    let model = m () in model#snapshot; (new Controller.controller ~model ())#show_all));

  (* View menu *)
  let _view_menu = factory#add_submenu "View" in
  let view_factory = new GMenu.factory _view_menu in
  ignore (view_factory#add_item "Zoom In" ~key:GdkKeysyms._plus ~callback:(fun () -> print_endline "Zoom In"));
  ignore (view_factory#add_item "Zoom Out" ~key:GdkKeysyms._minus ~callback:(fun () -> print_endline "Zoom Out"));
  ignore (view_factory#add_item "Fit in Window" ~key:GdkKeysyms._0 ~callback:(fun () -> print_endline "Fit in Window"));

  (* Window menu *)
  let _window_menu = factory#add_submenu "Window" in
  let window_factory = new GMenu.factory _window_menu in

  (* Workspace submenu *)
  (match workspace_layout, app_config, refresh_dock with
   | Some layout, Some config, Some refresh ->
     let _ws_menu = window_factory#add_submenu "Workspace" in
     let ws_factory = new GMenu.factory _ws_menu in
     (* List saved layouts, filtering out "Workspace" *)
     let visible = List.filter (fun n -> n <> Workspace_layout.workspace_layout_name) config.Workspace_layout.saved_layouts in
     List.iter (fun name ->
       let prefix = if name = config.Workspace_layout.active_layout then "\xE2\x9C\x93 " else "    " in
       ignore (ws_factory#add_item (prefix ^ name) ~callback:(fun () ->
         Workspace_layout.save_layout layout;
         let loaded = Workspace_layout.load_layout name in
         layout.Workspace_layout.version <- loaded.Workspace_layout.version;
         layout.Workspace_layout.name <- Workspace_layout.workspace_layout_name;
         layout.Workspace_layout.anchored <- loaded.Workspace_layout.anchored;
         layout.Workspace_layout.floating <- loaded.Workspace_layout.floating;
         layout.Workspace_layout.hidden_panels <- loaded.Workspace_layout.hidden_panels;
         layout.Workspace_layout.z_order <- loaded.Workspace_layout.z_order;
         layout.Workspace_layout.focused_panel <- loaded.Workspace_layout.focused_panel;
         layout.Workspace_layout.appearance <- loaded.Workspace_layout.appearance;
         layout.Workspace_layout.pane_layout <- loaded.Workspace_layout.pane_layout;
         layout.Workspace_layout.next_id <- loaded.Workspace_layout.next_id;
         config.Workspace_layout.active_layout <- name;
         config.Workspace_layout.active_appearance <- loaded.Workspace_layout.appearance;
         Dock_panel.set_theme loaded.Workspace_layout.appearance;
         Workspace_layout.save_app_config config;
         Workspace_layout.save_layout layout;
         refresh ()
       ))
     ) visible;
     ignore (ws_factory#add_separator ());
     (* Save As... *)
     ignore (ws_factory#add_item "Save As\xE2\x80\xA6" ~callback:(fun () ->
       let dialog = GWindow.dialog ~title:"Save Workspace As" ~parent ~modal:true () in
       let vbox = dialog#vbox in
       let prefill = if config.Workspace_layout.active_layout <> Workspace_layout.workspace_layout_name
         then config.Workspace_layout.active_layout else "" in
       let entry = GEdit.entry ~text:prefill ~packing:vbox#add () in
       dialog#add_button_stock `CANCEL `CANCEL;
       dialog#add_button_stock `SAVE `ACCEPT;
       let response = dialog#run () in
       let name = String.trim (entry#text) in
       dialog#destroy ();
       if response = `ACCEPT && name <> "" then begin
         if String.lowercase_ascii name = String.lowercase_ascii Workspace_layout.workspace_layout_name then begin
           let info = GWindow.message_dialog ~message:"\xE2\x80\x9CWorkspace\xE2\x80\x9D is a system workspace that is saved automatically."
             ~message_type:`INFO ~buttons:GWindow.Buttons.ok ~parent ~modal:true () in
           ignore (info#run ());
           info#destroy ()
         end else if List.mem name config.Workspace_layout.saved_layouts then begin
           let confirm = GWindow.message_dialog
             ~message:(Printf.sprintf "Layout \xE2\x80\x9C%s\xE2\x80\x9D already exists. Overwrite?" name)
             ~message_type:`QUESTION ~buttons:GWindow.Buttons.ok_cancel ~parent ~modal:true () in
           let resp = confirm#run () in
           confirm#destroy ();
           if resp = `OK then begin
             layout.Workspace_layout.appearance <- config.Workspace_layout.active_appearance;
             Workspace_layout.save_layout_as layout name;
             Workspace_layout.register_layout config name;
             config.Workspace_layout.active_layout <- name;
             Workspace_layout.save_app_config config
           end
         end else begin
           layout.Workspace_layout.appearance <- config.Workspace_layout.active_appearance;
           Workspace_layout.save_layout_as layout name;
           Workspace_layout.register_layout config name;
           config.Workspace_layout.active_layout <- name;
           Workspace_layout.save_app_config config
         end
       end
     ));
     ignore (ws_factory#add_separator ());
     (* Reset to Default *)
     ignore (ws_factory#add_item "Reset to Default" ~callback:(fun () ->
       Workspace_layout.reset_to_default layout;
       layout.Workspace_layout.name <- Workspace_layout.workspace_layout_name;
       config.Workspace_layout.active_layout <- Workspace_layout.workspace_layout_name;
       Workspace_layout.save_app_config config;
       Workspace_layout.save_layout layout;
       refresh ()
     ));
     (* Revert to Saved *)
     ignore (ws_factory#add_item "Revert to Saved" ~callback:(fun () ->
       if config.Workspace_layout.active_layout <> Workspace_layout.workspace_layout_name then begin
         let loaded = Workspace_layout.load_layout config.Workspace_layout.active_layout in
         layout.Workspace_layout.version <- loaded.Workspace_layout.version;
         layout.Workspace_layout.name <- Workspace_layout.workspace_layout_name;
         layout.Workspace_layout.anchored <- loaded.Workspace_layout.anchored;
         layout.Workspace_layout.floating <- loaded.Workspace_layout.floating;
         layout.Workspace_layout.hidden_panels <- loaded.Workspace_layout.hidden_panels;
         layout.Workspace_layout.z_order <- loaded.Workspace_layout.z_order;
         layout.Workspace_layout.focused_panel <- loaded.Workspace_layout.focused_panel;
         layout.Workspace_layout.pane_layout <- loaded.Workspace_layout.pane_layout;
         layout.Workspace_layout.next_id <- loaded.Workspace_layout.next_id;
         Workspace_layout.save_layout layout;
         refresh ()
       end
     ));
     ignore (ws_factory#add_separator ())
   | _ -> ());

  (* Appearance submenu — rebuilt on each show to update checkmarks *)
  (match app_config, refresh_dock with
   | Some config, Some refresh ->
     let app_menu = window_factory#add_submenu "Appearance" in
     let rec rebuild_appearance_menu () =
       List.iter (fun c -> c#destroy ()) app_menu#children;
       let app_factory = new GMenu.factory app_menu in
       List.iter (fun (entry : Theme.appearance_entry) ->
         let prefix = if entry.name = config.Workspace_layout.active_appearance then "\xE2\x9C\x93 " else "    " in
         ignore (app_factory#add_item (prefix ^ entry.label) ~callback:(fun () ->
           config.Workspace_layout.active_appearance <- entry.name;
           Dock_panel.set_theme entry.name;
           Workspace_layout.save_app_config config;
           apply_menubar_css ();
           refresh ();
           rebuild_appearance_menu ()
         ))
       ) Theme.predefined_appearances
     in
     rebuild_appearance_menu ()
   | _ -> ());

  (* Pane toggles *)
  (match workspace_layout, refresh_dock with
   | Some layout, Some refresh ->
     ignore (window_factory#add_separator ());
     ignore (window_factory#add_item "Tile" ~callback:(fun () ->
       Workspace_layout.panes_mut layout (fun pl ->
         Pane.tile_panes pl ~collapsed_override:None);
       refresh ()
     ));
     ignore (window_factory#add_separator ());
     let toggle_pane kind label =
       ignore (window_factory#add_item label ~callback:(fun () ->
         Workspace_layout.panes_mut layout (fun pl ->
           if Pane.is_pane_visible pl kind then
             Pane.hide_pane pl kind
           else
             Pane.show_pane pl kind);
         refresh ()
       ))
     in
     toggle_pane Pane.Toolbar "Toolbar";
     toggle_pane Pane.Dock "Panels"
   | _ -> ());

  ignore (window_factory#add_separator ());

  (* Panel toggles *)
  let toggle_panel kind label =
    ignore (window_factory#add_item label ~callback:(fun () ->
      match workspace_layout, refresh_dock with
      | Some layout, Some refresh ->
        if Workspace_layout.is_panel_visible layout kind then begin
          (* Find and close the panel *)
          let found = ref false in
          List.iter (fun (_, (d : Workspace_layout.dock)) ->
            Array.iteri (fun gi (g : Workspace_layout.panel_group) ->
              Array.iteri (fun pi k ->
                if k = kind && not !found then begin
                  Workspace_layout.close_panel layout { group = { dock_id = d.id; group_idx = gi }; panel_idx = pi };
                  found := true
                end
              ) g.panels
            ) d.groups
          ) layout.anchored;
          List.iter (fun (fd : Workspace_layout.floating_dock) ->
            Array.iteri (fun gi (g : Workspace_layout.panel_group) ->
              Array.iteri (fun pi k ->
                if k = kind && not !found then begin
                  Workspace_layout.close_panel layout { group = { dock_id = fd.dock.id; group_idx = gi }; panel_idx = pi };
                  found := true
                end
              ) g.panels
            ) fd.dock.groups
          ) layout.floating
        end else
          Workspace_layout.show_panel layout kind;
        refresh ()
      | _ -> ()
    ))
  in
  toggle_panel Workspace_layout.Layers "Layers";
  toggle_panel Workspace_layout.Color "Color";
  toggle_panel Workspace_layout.Swatches "Swatches";
  toggle_panel Workspace_layout.Stroke "Stroke";
  toggle_panel Workspace_layout.Properties "Properties";
  toggle_panel Workspace_layout.Magic_wand "Magic Wand"
