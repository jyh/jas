let () =
  ignore (GMain.init ());
  let main_window, fixed = Jas.Canvas.create_main_window () in
  let _canvas = Jas.Canvas.create_canvas_subwindow
    ~title:"Untitled" ~x:50 ~y:50 ~width:820 ~height:640 fixed in
  main_window#show ();
  GMain.main ()
