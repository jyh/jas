(** Main window with dark workspace and menubar. *)

let create_main_window () =
  let window = GWindow.window
    ~title:"Jas"
    ~width:1200 ~height:900
    () in
  window#connect#destroy ~callback:GMain.quit |> ignore;

  (* Create a vbox to hold menubar and workspace *)
  let vbox = GPack.vbox ~packing:window#add () in

  (* Menubar *)
  let menubar = GMenu.menu_bar ~packing:vbox#pack () in
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
  ignore (edit_factory#add_item "Copy" ~key:GdkKeysyms._c ~callback:(fun () -> print_endline "Copy"));
  ignore (edit_factory#add_item "Paste" ~key:GdkKeysyms._v ~callback:(fun () -> print_endline "Paste"));
  ignore (edit_factory#add_item "Select All" ~key:GdkKeysyms._a ~callback:(fun () -> print_endline "Select All"));

  (* View menu *)
  let _view_menu = factory#add_submenu "View" in
  let view_factory = new GMenu.factory _view_menu in
  ignore (view_factory#add_item "Zoom In" ~key:GdkKeysyms._plus ~callback:(fun () -> print_endline "Zoom In"));
  ignore (view_factory#add_item "Zoom Out" ~key:GdkKeysyms._minus ~callback:(fun () -> print_endline "Zoom Out"));
  ignore (view_factory#add_item "Fit in Window" ~key:GdkKeysyms._0 ~callback:(fun () -> print_endline "Fit in Window"));

  (* Dark workspace background *)
  let fixed = GPack.fixed ~packing:vbox#add () in
  let bg = GMisc.drawing_area ~packing:(fixed#put ~x:0 ~y:0) () in
  let resize_bg () =
    let alloc = fixed#misc#allocation in
    bg#misc#set_size_request ~width:alloc.Gtk.width ~height:alloc.Gtk.height ()
  in
  fixed#misc#connect#size_allocate ~callback:(fun _ -> resize_bg ()) |> ignore;
  bg#misc#connect#draw ~callback:(fun cr ->
    let alloc = bg#misc#allocation in
    let w = float_of_int alloc.Gtk.width in
    let h = float_of_int alloc.Gtk.height in
    Cairo.set_source_rgb cr 0.235 0.235 0.235;
    Cairo.rectangle cr 0.0 0.0 ~w ~h;
    Cairo.fill cr;
    true
  ) |> ignore;

  (window, fixed)
