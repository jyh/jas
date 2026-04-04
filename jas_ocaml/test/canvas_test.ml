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

  (* Test canvas subwindow with default model *)
  let model = Jas.Model.create () in
  let controller = Jas.Controller.create ~model () in
  let canvas = Jas.Canvas_subwindow.create
    ~model ~controller ~toolbar ~x:100 ~y:50 ~width:820 ~height:640 fixed in
  assert (canvas#title = "Untitled");

  (* Test canvas with named document via model *)
  let doc = Jas.Document.make_document ~title:"My Drawing" [] in
  let model2 = Jas.Model.create ~document:doc () in
  let controller2 = Jas.Controller.create ~model:model2 () in
  let canvas2 = Jas.Canvas_subwindow.create
    ~model:model2 ~controller:controller2 ~toolbar ~x:100 ~y:50 ~width:820 ~height:640 fixed in
  assert (canvas2#title = "My Drawing");

  (* Test title updates when model changes document *)
  model2#set_document (Jas.Document.make_document ~title:"Renamed" []);
  assert (canvas2#title = "Renamed");

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
  toolbar#select_tool Jas.Toolbar.Line;
  assert (toolbar#current_tool = Jas.Toolbar.Line);

  Printf.printf "All canvas tests passed.\n"
