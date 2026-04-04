(** Main window with dark workspace and menubar. *)

let create_main_window ~model () =
  let window = GWindow.window
    ~title:"Jas"
    ~width:1200 ~height:900
    () in
  window#connect#destroy ~callback:GMain.quit |> ignore;

  (* Create a vbox to hold menubar and workspace *)
  let vbox = GPack.vbox ~packing:window#add () in

  (* Create menubar *)
  Menubar.create model vbox;

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
