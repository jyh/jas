let () = ignore (GMain.init ())

let model = Jas.Model.create ()
let main_window, toolbar_fixed, notebook, _dock_box = Jas.Canvas.create_main_window ~get_model:(fun () -> model) ~get_fill_on_top:(fun () -> true) ~on_open:(fun _ -> ()) ()
let toolbar = Jas.Toolbar.create ~title:"Tools" ~x:10 ~y:10 toolbar_fixed
let controller = Jas.Controller.create ~model ()
let canvas = Jas.Canvas_subwindow.create
  ~model ~controller ~toolbar notebook
let model2 = Jas.Model.create ~filename:"My Drawing" ()
let controller2 = Jas.Controller.create ~model:model2 ()
let canvas2 = Jas.Canvas_subwindow.create
  ~model:model2 ~controller:controller2 ~toolbar notebook

let tests = [
  Alcotest.test_case "main window creation" `Quick (fun () ->
    assert (main_window#title = "Jas")
  );

  Alcotest.test_case "toolbar initial tool is Selection" `Quick (fun () ->
    assert (toolbar#current_tool = Jas.Toolbar.Selection)
  );

  Alcotest.test_case "toolbar select Partial_selection" `Quick (fun () ->
    toolbar#select_tool Jas.Toolbar.Partial_selection;
    assert (toolbar#current_tool = Jas.Toolbar.Partial_selection)
  );

  Alcotest.test_case "canvas subwindow default title starts with Untitled-" `Quick (fun () ->
    assert (String.sub canvas#title 0 9 = "Untitled-")
  );

  Alcotest.test_case "canvas subwindow named model title" `Quick (fun () ->
    assert (canvas2#title = "My Drawing")
  );

  Alcotest.test_case "canvas title updates when model filename changes" `Quick (fun () ->
    model2#set_filename "Renamed";
    assert (canvas2#title = "Renamed")
  );

  Alcotest.test_case "default bounding box values" `Quick (fun () ->
    let bbox = canvas#bbox in
    assert (bbox.Jas.Canvas_subwindow.bbox_x = 0.0);
    assert (bbox.Jas.Canvas_subwindow.bbox_y = 0.0);
    assert (bbox.Jas.Canvas_subwindow.bbox_width = 800.0);
    assert (bbox.Jas.Canvas_subwindow.bbox_height = 600.0)
  );

  Alcotest.test_case "custom bounding box values" `Quick (fun () ->
    let custom_bbox = Jas.Canvas_subwindow.make_bounding_box ~x:10.0 ~y:20.0 ~width:1024.0 ~height:768.0 () in
    assert (custom_bbox.Jas.Canvas_subwindow.bbox_x = 10.0);
    assert (custom_bbox.Jas.Canvas_subwindow.bbox_width = 1024.0)
  );

  Alcotest.test_case "keyboard shortcuts: select Selection tool" `Quick (fun () ->
    toolbar#select_tool Jas.Toolbar.Selection;
    assert (toolbar#current_tool = Jas.Toolbar.Selection)
  );

  Alcotest.test_case "keyboard shortcuts: select Partial_selection tool" `Quick (fun () ->
    toolbar#select_tool Jas.Toolbar.Partial_selection;
    assert (toolbar#current_tool = Jas.Toolbar.Partial_selection)
  );

  Alcotest.test_case "keyboard shortcuts: select Line tool" `Quick (fun () ->
    toolbar#select_tool Jas.Toolbar.Line;
    assert (toolbar#current_tool = Jas.Toolbar.Line)
  );

  Alcotest.test_case "keyboard shortcuts: select Rect tool" `Quick (fun () ->
    toolbar#select_tool Jas.Toolbar.Rect;
    assert (toolbar#current_tool = Jas.Toolbar.Rect)
  );

  Alcotest.test_case "add line element via controller" `Quick (fun () ->
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

  Alcotest.test_case "add rect element via controller" `Quick (fun () ->
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
]

let () =
  Alcotest.run "Canvas" [
    "Canvas tests", tests;
  ]
