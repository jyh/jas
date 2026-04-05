let () =
  ignore (GMain.init ());

  (* Test main window creation *)
  let model = Jas.Model.create () in
  let main_window, fixed = Jas.Canvas.create_main_window ~model () in
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
  assert (String.sub canvas#title 0 9 = "Untitled-");

  (* Test canvas with named model *)
  let model2 = Jas.Model.create ~filename:"My Drawing" () in
  let controller2 = Jas.Controller.create ~model:model2 () in
  let canvas2 = Jas.Canvas_subwindow.create
    ~model:model2 ~controller:controller2 ~toolbar ~x:100 ~y:50 ~width:820 ~height:640 fixed in
  assert (canvas2#title = "My Drawing");

  (* Test title updates when model filename changes *)
  model2#set_filename "Renamed";
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
  toolbar#select_tool Jas.Toolbar.Rect;
  assert (toolbar#current_tool = Jas.Toolbar.Rect);

  (* Test adding a line element via controller *)
  let model3 = Jas.Model.create () in
  let ctrl3 = Jas.Controller.create ~model:model3 () in
  let line = Jas.Element.Line {
    x1 = 10.0; y1 = 20.0; x2 = 50.0; y2 = 60.0;
    stroke = Some { stroke_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 };
                    stroke_width = 1.0;
                    stroke_linecap = Butt;
                    stroke_linejoin = Miter };
    opacity = 1.0; transform = None;
  } in
  let layer = Jas.Element.make_layer ~name:"Layer 1" [line] in
  ctrl3#set_document (Jas.Document.make_document [layer]);
  assert (List.length ctrl3#document.Jas.Document.layers = 1);
  begin match List.hd ctrl3#document.Jas.Document.layers with
  | Jas.Element.Layer { children; _ } ->
    assert (List.length children = 1);
    begin match List.hd children with
    | Jas.Element.Line { x1; y1; x2; y2; _ } ->
      assert (x1 = 10.0); assert (y1 = 20.0);
      assert (x2 = 50.0); assert (y2 = 60.0)
    | _ -> assert false
    end
  | _ -> assert false
  end;

  (* Test adding a rect element via controller *)
  let rect = Jas.Element.Rect {
    x = 10.0; y = 20.0; width = 40.0; height = 40.0;
    rx = 0.0; ry = 0.0;
    fill = None;
    stroke = Some { stroke_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 };
                    stroke_width = 1.0;
                    stroke_linecap = Butt;
                    stroke_linejoin = Miter };
    opacity = 1.0; transform = None;
  } in
  let layer_r = Jas.Element.make_layer ~name:"Layer 1" [rect] in
  ctrl3#set_document (Jas.Document.make_document [layer_r]);
  begin match List.hd ctrl3#document.Jas.Document.layers with
  | Jas.Element.Layer { children; _ } ->
    begin match List.hd children with
    | Jas.Element.Rect { x; y; width; height; _ } ->
      assert (x = 10.0); assert (y = 20.0);
      assert (width = 40.0); assert (height = 40.0)
    | _ -> assert false
    end
  | _ -> assert false
  end;

  Printf.printf "All canvas tests passed.\n"
