(* Tool interaction tests: verify tool state machines without a GUI.

   Tests exercise on_press/on_move/on_release sequences and verify the
   resulting document state. *)

let run_test name f =
  f ();
  Printf.printf "  PASS: %s\n" name

(* Create a mock tool_context with a fresh model and controller. *)
let make_ctx ?model () =
  let model = match model with
    | Some m -> m
    | None -> Jas.Model.create ()
  in
  let ctrl = Jas.Controller.create ~model () in
  let ctx : Jas.Canvas_tool.tool_context = {
    model;
    controller = ctrl;
    hit_test_selection = (fun _x _y -> false);
    hit_test_handle = (fun _x _y -> None);
    hit_test_text = (fun _x _y -> None);
    hit_test_path_curve = (fun _x _y -> None);
    request_update = (fun () -> ());
    start_text_edit = (fun _path _elem -> ());
    commit_text_edit = (fun () -> ());
    draw_element_overlay = (fun _cr _elem _cps -> ());
  } in
  (ctx, model, ctrl)

let layer_children model =
  match model#document.Jas.Document.layers.(0) with
  | Jas.Element.Layer { children; _ } -> children
  | _ -> [||]

let () =
  ignore (GMain.init ());
  let open Jas.Element in
  Printf.printf "Tool interaction tests:\n";

  (* ---- Line tool ---- *)

  run_test "line tool: draw line" (fun () ->
    let tool = new Jas.Drawing_tool.line_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
    tool#on_move ctx 30.0 40.0 ~shift:false ~dragging:true;
    tool#on_release ctx 50.0 60.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1);
    match children.(0) with
    | Line { x1; y1; x2; y2; _ } ->
      assert (x1 = 10.0);
      assert (y1 = 20.0);
      assert (x2 = 50.0);
      assert (y2 = 60.0)
    | _ -> assert false);

  run_test "line tool: zero-length line still created" (fun () ->
    let tool = new Jas.Drawing_tool.line_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
    tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1));

  (* ---- Rect tool ---- *)

  run_test "rect tool: draw rect" (fun () ->
    let tool = new Jas.Drawing_tool.rect_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
    tool#on_release ctx 110.0 70.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1);
    match children.(0) with
    | Rect { x; y; width; height; _ } ->
      assert (x = 10.0);
      assert (y = 20.0);
      assert (width = 100.0);
      assert (height = 50.0)
    | _ -> assert false);

  run_test "rect tool: zero-size rect still created" (fun () ->
    let tool = new Jas.Drawing_tool.rect_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
    tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1);
    match children.(0) with
    | Rect { width; height; _ } ->
      assert (width = 0.0);
      assert (height = 0.0)
    | _ -> assert false);

  run_test "rect tool: negative drag normalizes" (fun () ->
    let tool = new Jas.Drawing_tool.rect_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 100.0 80.0 ~shift:false ~alt:false;
    tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1);
    match children.(0) with
    | Rect { x; y; width; height; _ } ->
      assert (x = 10.0);
      assert (y = 20.0);
      assert (width = 90.0);
      assert (height = 60.0)
    | _ -> assert false);

  (* ---- Polygon tool ---- *)

  run_test "polygon tool: draw polygon" (fun () ->
    let tool = new Jas.Drawing_tool.polygon_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 50.0 50.0 ~shift:false ~alt:false;
    tool#on_release ctx 100.0 50.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1);
    match children.(0) with
    | Polygon { points; _ } ->
      assert (List.length points = Jas.Canvas_tool.polygon_sides)
    | _ -> assert false);

  (* ---- Selection tool ---- *)

  run_test "selection tool: marquee select" (fun () ->
    let tool = new Jas.Selection_tool.selection_tool in
    let rect = make_rect 50.0 50.0 20.0 20.0 in
    let layer = make_layer ~name:"L" [|rect|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_press ctx 45.0 45.0 ~shift:false ~alt:false;
    tool#on_release ctx 75.0 75.0 ~shift:false ~alt:false;
    assert (not (Jas.Document.PathMap.is_empty model#document.Jas.Document.selection)));

  run_test "selection tool: marquee miss" (fun () ->
    let tool = new Jas.Selection_tool.selection_tool in
    let rect = make_rect 50.0 50.0 20.0 20.0 in
    let layer = make_layer ~name:"L" [|rect|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
    tool#on_release ctx 10.0 10.0 ~shift:false ~alt:false;
    assert (Jas.Document.PathMap.is_empty model#document.Jas.Document.selection));

  run_test "selection tool: move selection" (fun () ->
    let tool = new Jas.Selection_tool.selection_tool in
    let rect = make_rect 50.0 50.0 20.0 20.0 in
    let layer = make_layer ~name:"L" [|rect|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let ctrl = Jas.Controller.create ~model () in
    ctrl#select_rect 45.0 45.0 30.0 30.0 ~extend:false;
    assert (not (Jas.Document.PathMap.is_empty model#document.Jas.Document.selection));
    let ctx : Jas.Canvas_tool.tool_context = {
      model;
      controller = ctrl;
      hit_test_selection = (fun _x _y -> true);
      hit_test_handle = (fun _x _y -> None);
      hit_test_text = (fun _x _y -> None);
      hit_test_path_curve = (fun _x _y -> None);
      request_update = (fun () -> ());
      start_text_edit = (fun _path _elem -> ());
      commit_text_edit = (fun () -> ());
      draw_element_overlay = (fun _cr _elem _cps -> ());
    } in
    tool#on_press ctx 60.0 60.0 ~shift:false ~alt:false;
    tool#on_move ctx 70.0 70.0 ~shift:false ~dragging:true;
    tool#on_release ctx 70.0 70.0 ~shift:false ~alt:false;
    let moved = (layer_children model).(0) in
    match moved with
    | Rect { x; y; _ } ->
      assert (x = 60.0);
      assert (y = 60.0)
    | _ -> assert false);

  Printf.printf "All tool interaction tests passed.\n"
