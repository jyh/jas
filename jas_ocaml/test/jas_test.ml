let () =
  ignore (GMain.init ());

  (* Test main window creation *)
  let main_window, fixed = Jas.Canvas.create_main_window () in
  assert (main_window#title = "Jas");

  (* Test canvas subwindow creation *)
  let canvas = Jas.Canvas.create_canvas_subwindow
    ~title:"Untitled" ~x:50 ~y:50 ~width:820 ~height:640 fixed in
  assert (canvas#title = "Untitled");
  assert (canvas#x = 50);
  assert (canvas#y = 50);
  ignore canvas#widget;

  Printf.printf "All tests passed.\n"
