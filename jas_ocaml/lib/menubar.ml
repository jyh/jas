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
  ignore (edit_factory#add_item "Undo" ~key:GdkKeysyms._z ~callback:(fun () -> print_endline "Undo"));
  ignore (edit_factory#add_item "Redo" ~key:GdkKeysyms._y ~callback:(fun () -> print_endline "Redo"));
  ignore (edit_factory#add_separator ());
  ignore (edit_factory#add_item "Cut" ~key:GdkKeysyms._x ~callback:(fun () -> print_endline "Cut"));
  ignore (edit_factory#add_item "Copy" ~key:GdkKeysyms._c ~callback:(copy_selection model));
  ignore (edit_factory#add_item "Paste" ~key:GdkKeysyms._v ~callback:(fun () -> print_endline "Paste"));
  ignore (edit_factory#add_item "Select All" ~key:GdkKeysyms._a ~callback:(fun () -> print_endline "Select All"));

  (* View menu *)
  let _view_menu = factory#add_submenu "View" in
  let view_factory = new GMenu.factory _view_menu in
  ignore (view_factory#add_item "Zoom In" ~key:GdkKeysyms._plus ~callback:(fun () -> print_endline "Zoom In"));
  ignore (view_factory#add_item "Zoom Out" ~key:GdkKeysyms._minus ~callback:(fun () -> print_endline "Zoom Out"));
  ignore (view_factory#add_item "Fit in Window" ~key:GdkKeysyms._0 ~callback:(fun () -> print_endline "Fit in Window"))
