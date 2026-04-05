(** Menubar for the main window. *)

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
        [Element.make_layer (List.rev elems)] in
      let svg = Svg.document_to_svg temp_doc in
      let clipboard = GtkBase.Clipboard.get Gdk.Atom.clipboard in
      GtkBase.Clipboard.set_text clipboard svg
  end

let cut_selection (model : Model.model) () =
  model#snapshot;
  copy_selection model ();
  model#set_document (Document.delete_selection model#document)

let translate_element elem dx dy =
  if dx = 0.0 && dy = 0.0 then elem
  else
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
        let new_layers = Array.of_list doc.Document.layers in
        List.iter (fun pasted_layer ->
          let children = match pasted_layer with
            | Element.Layer { children; _ } ->
              List.map (fun c -> translate_element c offset offset) children
            | _ -> []
          in
          if children = [] then ()
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
              | Element.Layer { children = ec; _ } -> List.length ec
              | _ -> 0
            in
            List.iteri (fun j child ->
              let path = [idx; base + j] in
              let n = Element.control_point_count child in
              new_sel := Document.PathMap.add path
                (Document.make_element_selection ~control_points:(List.init n Fun.id) path)
                !new_sel
            ) children;
            match new_layers.(idx) with
            | Element.Layer { name = n; children = ec; opacity; transform } ->
              new_layers.(idx) <- Element.Layer { name = n; children = ec @ children; opacity; transform }
            | _ -> ()
          end
        ) pasted_doc.Document.layers;
        model#set_document { doc with layers = Array.to_list new_layers;
                                      selection = !new_sel }
      end else begin
        (* Plain text: create a Text element *)
        let elem = Element.make_text (offset) (offset +. 16.0) text in
        let idx = doc.Document.selected_layer in
        let base = match List.nth doc.Document.layers idx with
          | Element.Layer { children; _ } -> List.length children
          | _ -> 0
        in
        let path = [idx; base] in
        let n = Element.control_point_count elem in
        new_sel := Document.PathMap.add path
          (Document.make_element_selection ~control_points:(List.init n Fun.id) path)
          !new_sel;
        let new_layers = List.mapi (fun i l ->
          if i = idx then
            match l with
            | Element.Layer layer ->
              Element.Layer { layer with children = layer.children @ [elem] }
            | _ -> l
          else l
        ) doc.Document.layers in
        model#set_document { doc with layers = new_layers;
                                      selection = !new_sel }
      end
  )

let create (model : Model.model) (vbox : GPack.box) =
  (* Menubar *)
  let menubar = GMenu.menu_bar ~packing:(fun w -> vbox#pack w) () in
  let factory = new GMenu.factory menubar in

  (* File menu *)
  let _file_menu = factory#add_submenu "File" in
  let file_factory = new GMenu.factory _file_menu in
  ignore (file_factory#add_item "New" ~key:GdkKeysyms._n ~callback:(fun () -> print_endline "New"));
  ignore (file_factory#add_item "Open..." ~key:GdkKeysyms._o ~callback:(fun () -> print_endline "Open"));
  ignore (file_factory#add_item "Save" ~key:GdkKeysyms._s ~callback:(fun () -> print_endline "Save"));
  ignore (file_factory#add_item "Save As..." ~key:GdkKeysyms._s ~callback:(fun () -> print_endline "Save As"));
  ignore (file_factory#add_separator ());
  ignore (file_factory#add_item "Quit" ~key:GdkKeysyms._q ~callback:(fun () -> GMain.quit ()));

  (* Edit menu *)
  let _edit_menu = factory#add_submenu "Edit" in
  let edit_factory = new GMenu.factory _edit_menu in
  let undo_item = edit_factory#add_item "Undo" ~key:GdkKeysyms._z ~callback:(fun () -> model#undo) in
  let redo_item = edit_factory#add_item "Redo" ~key:GdkKeysyms._y ~callback:(fun () -> model#redo) in
  undo_item#misc#set_sensitive model#can_undo;
  redo_item#misc#set_sensitive model#can_redo;
  model#on_document_changed (fun _doc ->
    undo_item#misc#set_sensitive model#can_undo;
    redo_item#misc#set_sensitive model#can_redo
  );
  ignore (edit_factory#add_separator ());
  ignore (edit_factory#add_item "Cut" ~key:GdkKeysyms._x ~callback:(cut_selection model));
  ignore (edit_factory#add_item "Copy" ~key:GdkKeysyms._c ~callback:(copy_selection model));
  ignore (edit_factory#add_item "Paste" ~key:GdkKeysyms._v ~callback:(paste_clipboard model 24.0));
  ignore (edit_factory#add_item "Paste in Place" ~callback:(paste_clipboard model 0.0));
  ignore (edit_factory#add_separator ());
  ignore (edit_factory#add_item "Select All" ~key:GdkKeysyms._a ~callback:(fun () -> print_endline "Select All"));

  (* View menu *)
  let _view_menu = factory#add_submenu "View" in
  let view_factory = new GMenu.factory _view_menu in
  ignore (view_factory#add_item "Zoom In" ~key:GdkKeysyms._plus ~callback:(fun () -> print_endline "Zoom In"));
  ignore (view_factory#add_item "Zoom Out" ~key:GdkKeysyms._minus ~callback:(fun () -> print_endline "Zoom Out"));
  ignore (view_factory#add_item "Fit in Window" ~key:GdkKeysyms._0 ~callback:(fun () -> print_endline "Fit in Window"))
