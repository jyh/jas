let run_test name f =
  f ();
  Printf.printf "  PASS: %s\n" name

let () =
  ignore (GMain.init ());

  let model = Jas.Model.create () in
  let main_window, toolbar_fixed, notebook, _dock_box = Jas.Canvas.create_main_window ~get_model:(fun () -> model) ~on_open:(fun _ -> ()) () in
  let toolbar = Jas.Toolbar.create ~title:"Tools" ~x:10 ~y:10 toolbar_fixed in
  let controller = Jas.Controller.create ~model () in
  let canvas = Jas.Canvas_subwindow.create
    ~model ~controller ~toolbar notebook in
  let model2 = Jas.Model.create ~filename:"My Drawing" () in
  let controller2 = Jas.Controller.create ~model:model2 () in
  let canvas2 = Jas.Canvas_subwindow.create
    ~model:model2 ~controller:controller2 ~toolbar notebook in

  Printf.printf "Canvas tests:\n";

  run_test "main window creation" (fun () ->
    assert (main_window#title = "Jas")
  );

  run_test "toolbar initial tool is Selection" (fun () ->
    assert (toolbar#current_tool = Jas.Toolbar.Selection)
  );

  run_test "toolbar select Direct_selection" (fun () ->
    toolbar#select_tool Jas.Toolbar.Direct_selection;
    assert (toolbar#current_tool = Jas.Toolbar.Direct_selection)
  );

  run_test "canvas subwindow default title starts with Untitled-" (fun () ->
    assert (String.sub canvas#title 0 9 = "Untitled-")
  );

  run_test "canvas subwindow named model title" (fun () ->
    assert (canvas2#title = "My Drawing")
  );

  run_test "canvas title updates when model filename changes" (fun () ->
    model2#set_filename "Renamed";
    assert (canvas2#title = "Renamed")
  );

  run_test "default bounding box values" (fun () ->
    let bbox = canvas#bbox in
    assert (bbox.Jas.Canvas_subwindow.bbox_x = 0.0);
    assert (bbox.Jas.Canvas_subwindow.bbox_y = 0.0);
    assert (bbox.Jas.Canvas_subwindow.bbox_width = 800.0);
    assert (bbox.Jas.Canvas_subwindow.bbox_height = 600.0)
  );

  run_test "custom bounding box values" (fun () ->
    let custom_bbox = Jas.Canvas_subwindow.make_bounding_box ~x:10.0 ~y:20.0 ~width:1024.0 ~height:768.0 () in
    assert (custom_bbox.Jas.Canvas_subwindow.bbox_x = 10.0);
    assert (custom_bbox.Jas.Canvas_subwindow.bbox_width = 1024.0)
  );

  run_test "keyboard shortcuts: select Selection tool" (fun () ->
    toolbar#select_tool Jas.Toolbar.Selection;
    assert (toolbar#current_tool = Jas.Toolbar.Selection)
  );

  run_test "keyboard shortcuts: select Direct_selection tool" (fun () ->
    toolbar#select_tool Jas.Toolbar.Direct_selection;
    assert (toolbar#current_tool = Jas.Toolbar.Direct_selection)
  );

  run_test "keyboard shortcuts: select Line tool" (fun () ->
    toolbar#select_tool Jas.Toolbar.Line;
    assert (toolbar#current_tool = Jas.Toolbar.Line)
  );

  run_test "keyboard shortcuts: select Rect tool" (fun () ->
    toolbar#select_tool Jas.Toolbar.Rect;
    assert (toolbar#current_tool = Jas.Toolbar.Rect)
  );

  run_test "add line element via controller" (fun () ->
    let model3 = Jas.Model.create () in
    let ctrl3 = Jas.Controller.create ~model:model3 () in
    let line = Jas.Element.Line {
      x1 = 10.0; y1 = 20.0; x2 = 50.0; y2 = 60.0;
      stroke = Some { stroke_color = Rgb { r = 0.0; g = 0.0; b = 0.0; a = 1.0 };
                      stroke_width = 1.0;
                      stroke_linecap = Butt;
                      stroke_linejoin = Miter;
                      stroke_opacity = 1.0 };
      opacity = 1.0; transform = None; locked = false;
      visibility = Jas.Element.Preview;
    } in
    let layer = Jas.Element.make_layer ~name:"Layer 1" [|line|] in
    ctrl3#set_document (Jas.Document.make_document [|layer|]);
    assert (Array.length ctrl3#document.Jas.Document.layers = 1);
    begin match ctrl3#document.Jas.Document.layers.(0) with
    | Jas.Element.Layer { children; _ } ->
      assert (Array.length children = 1);
      begin match children.(0) with
      | Jas.Element.Line { x1; y1; x2; y2; _ } ->
        assert (x1 = 10.0); assert (y1 = 20.0);
        assert (x2 = 50.0); assert (y2 = 60.0)
      | _ -> assert false
      end
    | _ -> assert false
    end
  );

  run_test "add rect element via controller" (fun () ->
    let model3 = Jas.Model.create () in
    let ctrl3 = Jas.Controller.create ~model:model3 () in
    let rect = Jas.Element.Rect {
      x = 10.0; y = 20.0; width = 40.0; height = 40.0;
      rx = 0.0; ry = 0.0;
      fill = None;
      stroke = Some { stroke_color = Rgb { r = 0.0; g = 0.0; b = 0.0; a = 1.0 };
                      stroke_width = 1.0;
                      stroke_linecap = Butt;
                      stroke_linejoin = Miter;
                      stroke_opacity = 1.0 };
      opacity = 1.0; transform = None; locked = false;
      visibility = Jas.Element.Preview;
    } in
    let layer_r = Jas.Element.make_layer ~name:"Layer 1" [|rect|] in
    ctrl3#set_document (Jas.Document.make_document [|layer_r|]);
    begin match ctrl3#document.Jas.Document.layers.(0) with
    | Jas.Element.Layer { children; _ } ->
      begin match children.(0) with
      | Jas.Element.Rect { x; y; width; height; _ } ->
        assert (x = 10.0); assert (y = 20.0);
        assert (width = 40.0); assert (height = 40.0)
      | _ -> assert false
      end
    | _ -> assert false
    end
  );

  Printf.printf "All canvas tests passed.\n"
