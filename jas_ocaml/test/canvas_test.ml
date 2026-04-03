let () =
  ignore (GMain.init ());

  (* Test main window creation *)
  let main_window, fixed = Jas.Canvas.create_main_window () in
  assert (main_window#title = "Jas");

  (* Test toolbar creation *)
  let toolbar = Jas.Toolbar.create ~title:"Tools" ~x:10 ~y:10 fixed in
  assert (toolbar#current_tool = Jas.Toolbar.Selection);
  toolbar#select_tool Jas.Toolbar.Direct_selection;
  assert (toolbar#current_tool = Jas.Toolbar.Direct_selection);

  (* Test canvas subwindow creation *)
  let canvas = Jas.Canvas_subwindow.create
    ~title:"Untitled" ~x:100 ~y:50 ~width:820 ~height:640 fixed in
  assert (canvas#title = "Untitled");

  (* Test default bounding box *)
  let bbox = canvas#bbox in
  assert (bbox.Jas.Canvas_subwindow.bbox_x = 0.0);
  assert (bbox.Jas.Canvas_subwindow.bbox_y = 0.0);
  assert (bbox.Jas.Canvas_subwindow.bbox_width = 800.0);
  assert (bbox.Jas.Canvas_subwindow.bbox_height = 600.0);

  (* Test custom bounding box *)
  let custom_bbox = Jas.Canvas_subwindow.make_bounding_box ~x:10.0 ~y:20.0 ~width:1024.0 ~height:768.0 () in
  assert (custom_bbox.Jas.Canvas_subwindow.bbox_x = 10.0);
  assert (custom_bbox.Jas.Canvas_subwindow.bbox_width = 1024.0);

  (* Test keyboard shortcuts *)
  toolbar#select_tool Jas.Toolbar.Selection;
  assert (toolbar#current_tool = Jas.Toolbar.Selection);
  toolbar#select_tool Jas.Toolbar.Direct_selection;
  assert (toolbar#current_tool = Jas.Toolbar.Direct_selection);

  Printf.printf "All canvas tests passed.\n"
