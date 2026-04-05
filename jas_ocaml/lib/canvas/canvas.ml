(** Main window with toolbar and tabbed canvas workspace. *)

let create_main_window ~get_model ~on_open () =
  let window = GWindow.window
    ~title:"Jas"
    ~width:1200 ~height:900
    () in
  window#connect#destroy ~callback:GMain.quit |> ignore;

  (* Create a vbox to hold menubar and workspace *)
  let vbox = GPack.vbox ~packing:window#add () in

  (* Create menubar *)
  Menubar.create get_model window ~on_open vbox;

  (* Horizontal layout: toolbar | notebook *)
  let hbox = GPack.hbox ~packing:(vbox#pack ~expand:true ~fill:true) () in

  (* Toolbar container - use a fixed so the toolbar can position itself *)
  let toolbar_fixed = GPack.fixed ~packing:(hbox#pack ~expand:false) () in

  (* Tabbed notebook for canvases *)
  let notebook = GPack.notebook ~packing:(hbox#pack ~expand:true ~fill:true) () in

  (window, toolbar_fixed, notebook)
