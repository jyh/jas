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

  (* ---- Rounded rect tool ---- *)

  run_test "rounded rect tool: draw rounded rect" (fun () ->
    let tool = new Jas.Drawing_tool.rounded_rect_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
    tool#on_release ctx 110.0 70.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1);
    match children.(0) with
    | Rect { x; y; width; height; rx; ry; _ } ->
      assert (x = 10.0);
      assert (y = 20.0);
      assert (width = 100.0);
      assert (height = 50.0);
      assert (rx = Jas.Drawing_tool.rounded_rect_radius);
      assert (ry = Jas.Drawing_tool.rounded_rect_radius)
    | _ -> assert false);

  run_test "rounded rect tool: zero-size not created" (fun () ->
    let tool = new Jas.Drawing_tool.rounded_rect_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
    tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 0));

  run_test "rounded rect tool: negative drag normalizes" (fun () ->
    let tool = new Jas.Drawing_tool.rounded_rect_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 100.0 80.0 ~shift:false ~alt:false;
    tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1);
    match children.(0) with
    | Rect { x; y; width; height; rx; ry; _ } ->
      assert (x = 10.0);
      assert (y = 20.0);
      assert (width = 90.0);
      assert (height = 60.0);
      assert (rx = Jas.Drawing_tool.rounded_rect_radius);
      assert (ry = Jas.Drawing_tool.rounded_rect_radius)
    | _ -> assert false);

  (* ---- Star tool ---- *)

  run_test "star tool: draw star" (fun () ->
    let tool = new Jas.Drawing_tool.star_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
    tool#on_release ctx 110.0 120.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1);
    match children.(0) with
    | Polygon { points; _ } ->
      assert (List.length points = 2 * Jas.Drawing_tool.star_points)
    | _ -> assert false);

  run_test "star tool: zero-size not created" (fun () ->
    let tool = new Jas.Drawing_tool.star_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
    tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 0));

  run_test "star tool: first vertex at top" (fun () ->
    let tool = new Jas.Drawing_tool.star_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
    tool#on_release ctx 100.0 100.0 ~shift:false ~alt:false;
    let children = layer_children model in
    match children.(0) with
    | Polygon { points; _ } ->
      let (x, y) = List.hd points in
      assert (abs_float (x -. 50.0) < 1e-9);
      assert (abs_float y < 1e-9)
    | _ -> assert false);

  run_test "star tool: default points is 5" (fun () ->
    assert (Jas.Drawing_tool.star_points = 5)
  );

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

  (* ---- Add Anchor Point tool ---- *)

  run_test "add anchor point: click on path adds point" (fun () ->
    let tool = new Jas.Add_anchor_point_tool.add_anchor_point_tool in
    let path_elem = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); CurveTo (33.0, 0.0, 67.0, 0.0, 100.0, 0.0)] in
    let layer = make_layer ~name:"L" [|path_elem|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_press ctx 50.0 0.0 ~shift:false ~alt:false;
    tool#on_release ctx 50.0 0.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1);
    match children.(0) with
    | Path { d; _ } ->
      (* Original: MoveTo + 1 CurveTo = 2 commands *)
      (* After split: MoveTo + 2 CurveTos = 3 commands *)
      assert (List.length d = 3);
      (match List.nth d 0 with MoveTo _ -> () | _ -> assert false);
      (match List.nth d 1 with CurveTo _ -> () | _ -> assert false);
      (match List.nth d 2 with CurveTo _ -> () | _ -> assert false)
    | _ -> assert false);

  run_test "add anchor point: click away from path does nothing" (fun () ->
    let tool = new Jas.Add_anchor_point_tool.add_anchor_point_tool in
    let path_elem = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); CurveTo (33.0, 0.0, 67.0, 0.0, 100.0, 0.0)] in
    let layer = make_layer ~name:"L" [|path_elem|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_press ctx 50.0 100.0 ~shift:false ~alt:false;
    tool#on_release ctx 50.0 100.0 ~shift:false ~alt:false;
    let children = layer_children model in
    match children.(0) with
    | Path { d; _ } -> assert (List.length d = 2)
    | _ -> assert false);

  run_test "add anchor point: split preserves endpoints" (fun () ->
    let tool = new Jas.Add_anchor_point_tool.add_anchor_point_tool in
    let path_elem = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); CurveTo (33.0, 0.0, 67.0, 0.0, 100.0, 0.0)] in
    let layer = make_layer ~name:"L" [|path_elem|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_press ctx 50.0 0.0 ~shift:false ~alt:false;
    tool#on_release ctx 50.0 0.0 ~shift:false ~alt:false;
    let children = layer_children model in
    match children.(0) with
    | Path { d; _ } ->
      (* First CurveTo endpoint near (50, 0) *)
      (match List.nth d 1 with
       | CurveTo (_, _, _, _, x, y) ->
         assert (abs_float (x -. 50.0) < 1.0);
         assert (abs_float y < 1.0)
       | _ -> assert false);
      (* Second CurveTo endpoint at (100, 0) *)
      (match List.nth d 2 with
       | CurveTo (_, _, _, _, x, y) ->
         assert (abs_float (x -. 100.0) < 0.01);
         assert (abs_float y < 0.01)
       | _ -> assert false)
    | _ -> assert false);

  run_test "add anchor point: drag adjusts handles" (fun () ->
    let tool = new Jas.Add_anchor_point_tool.add_anchor_point_tool in
    let path_elem = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); CurveTo (33.0, 0.0, 67.0, 0.0, 100.0, 0.0)] in
    let layer = make_layer ~name:"L" [|path_elem|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_press ctx 50.0 0.0 ~shift:false ~alt:false;
    tool#on_move ctx 50.0 20.0 ~shift:false ~dragging:true;
    tool#on_release ctx 50.0 20.0 ~shift:false ~alt:false;
    let children = layer_children model in
    match children.(0) with
    | Path { d; _ } ->
      assert (List.length d = 3);
      (* Outgoing handle (x1, y1 of second CurveTo) at drag position *)
      (match List.nth d 2 with
       | CurveTo (x1, y1, _, _, _, _) ->
         assert (abs_float (x1 -. 50.0) < 0.01);
         assert (abs_float (y1 -. 20.0) < 0.01)
       | _ -> assert false);
      (* Incoming handle (x2, y2 of first CurveTo) mirrored *)
      (match List.nth d 1 with
       | CurveTo (_, _, x2, y2, _, _) ->
         assert (abs_float (x2 -. 50.0) < 0.01);
         assert (abs_float (y2 -. (~-.20.0)) < 0.01)
       | _ -> assert false)
    | _ -> assert false);

  run_test "add anchor point: cusp drag leaves incoming handle" (fun () ->
    let tool = new Jas.Add_anchor_point_tool.add_anchor_point_tool in
    let path_elem = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); CurveTo (33.0, 0.0, 67.0, 0.0, 100.0, 0.0)] in
    let layer = make_layer ~name:"L" [|path_elem|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    (* Split the curve at midpoint *)
    tool#on_press ctx 50.0 0.0 ~shift:false ~alt:false;
    tool#on_release ctx 50.0 0.0 ~shift:false ~alt:false;
    let children = layer_children model in
    (match children.(0) with
     | Path { d; _ } ->
       assert (List.length d = 3);
       (* Record incoming handle before cusp update *)
       let in_x2, in_y2 = match List.nth d 1 with
         | CurveTo (_, _, x2, y2, _, _) -> (x2, y2)
         | _ -> assert false
       in
       (* Apply cusp update directly *)
       let new_cmds = Jas.Add_anchor_point_tool.update_handles d 1 50.0 0.0 50.0 20.0 true in
       (* Outgoing handle at drag position *)
       (match List.nth new_cmds 2 with
        | CurveTo (x1, y1, _, _, _, _) ->
          assert (abs_float (x1 -. 50.0) < 0.01);
          assert (abs_float (y1 -. 20.0) < 0.01)
        | _ -> assert false);
       (* Incoming handle unchanged (cusp) *)
       (match List.nth new_cmds 1 with
        | CurveTo (_, _, x2, y2, _, _) ->
          assert (abs_float (x2 -. in_x2) < 0.01);
          assert (abs_float (y2 -. in_y2) < 0.01)
        | _ -> assert false)
     | _ -> assert false));

  run_test "add anchor point: insert updates selection indices" (fun () ->
    let tool = new Jas.Add_anchor_point_tool.add_anchor_point_tool in
    let path_elem = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); CurveTo (33.0, 0.0, 67.0, 0.0, 100.0, 0.0)] in
    let layer = make_layer ~name:"L" [|path_elem|] in
    (* Select the path with all CPs (indices 0 and 1) *)
    let sel = Jas.Document.PathMap.singleton [0; 0]
      { Jas.Document.es_path = [0; 0]; es_control_points = [0; 1] } in
    let doc = Jas.Document.make_document ~selection:sel [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_press ctx 50.0 0.0 ~shift:false ~alt:false;
    tool#on_release ctx 50.0 0.0 ~shift:false ~alt:false;
    let children = layer_children model in
    (match children.(0) with
     | Path { d; _ } -> assert (List.length d = 3)
     | _ -> assert false);
    (* Selection should include all 3 CPs *)
    let new_sel = model#document.Jas.Document.selection in
    (match Jas.Document.PathMap.find_opt [0; 0] new_sel with
     | Some es ->
       let cps = List.sort compare es.Jas.Document.es_control_points in
       assert (List.length cps = 3);
       assert (List.nth cps 0 = 0);
       assert (List.nth cps 1 = 1);
       assert (List.nth cps 2 = 2)
     | None -> assert false));

  run_test "add anchor point: split line segment" (fun () ->
    let tool = new Jas.Add_anchor_point_tool.add_anchor_point_tool in
    let path_elem = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); LineTo (100.0, 0.0)] in
    let layer = make_layer ~name:"L" [|path_elem|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_press ctx 50.0 0.0 ~shift:false ~alt:false;
    tool#on_release ctx 50.0 0.0 ~shift:false ~alt:false;
    let children = layer_children model in
    match children.(0) with
    | Path { d; _ } ->
      assert (List.length d = 3);
      (match List.nth d 1 with LineTo _ -> () | _ -> assert false);
      (match List.nth d 2 with LineTo _ -> () | _ -> assert false);
      (match List.nth d 1 with
       | LineTo (x, _) -> assert (abs_float (x -. 50.0) < 1.0)
       | _ -> assert false)
    | _ -> assert false);

  (* Regression: insert_point_in_path returned wrong index when splitting a
     segment other than the first one.  The old formula was
     "total - 1 - first_new_idx" which only works for 2-command paths. *)
  run_test "add anchor point: split second segment returns correct index" (fun () ->
    let tool = new Jas.Add_anchor_point_tool.add_anchor_point_tool in
    (* 3 anchors: MoveTo, CurveTo, CurveTo — click on the SECOND curve *)
    let path_elem = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0);
       CurveTo (10.0, 0.0, 20.0, 0.0, 30.0, 0.0);
       CurveTo (40.0, 0.0, 50.0, 0.0, 60.0, 0.0)] in
    let layer = make_layer ~name:"L" [|path_elem|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    (* Click at x=45 which is on the second curve segment *)
    tool#on_press ctx 45.0 0.0 ~shift:false ~alt:false;
    (* Drag to pull handles — if index is wrong, this modifies the wrong cmd *)
    tool#on_move ctx 45.0 20.0 ~shift:false ~dragging:true;
    tool#on_release ctx 45.0 20.0 ~shift:false ~alt:false;
    let children = layer_children model in
    match children.(0) with
    | Path { d; _ } ->
      (* Should have 4 commands: MoveTo, CurveTo, CurveTo(new), CurveTo *)
      assert (List.length d = 4);
      (* The new anchor at index 2 should be near x=45 *)
      (match List.nth d 2 with
       | CurveTo (_, _, _, _, x, _) ->
         assert (abs_float (x -. 45.0) < 1.0)
       | _ -> assert false);
      (* The first curve (index 1) should still end at x=30 — unchanged *)
      (match List.nth d 1 with
       | CurveTo (_, _, _, _, x, _) ->
         assert (abs_float (x -. 30.0) < 0.01)
       | _ -> assert false);
      (* The outgoing handle of the new anchor (x1 of cmd 3) should reflect
         the drag direction, not be at the original position *)
      (match List.nth d 3 with
       | CurveTo (x1, y1, _, _, _, _) ->
         (* Drag was to (45, 20), so outgoing handle should be near there *)
         assert (abs_float (x1 -. 45.0) < 1.0);
         assert (abs_float (y1 -. 20.0) < 1.0)
       | _ -> assert false)
    | _ -> assert false);

  run_test "add anchor point: space repositions anchor during drag" (fun () ->
    let tool = new Jas.Add_anchor_point_tool.add_anchor_point_tool in
    let path_elem = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); CurveTo (33.0, 0.0, 67.0, 0.0, 100.0, 0.0)] in
    let layer = make_layer ~name:"L" [|path_elem|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    (* Insert point at midpoint *)
    tool#on_press ctx 50.0 0.0 ~shift:false ~alt:false;
    (* Simulate Space press, then drag to reposition *)
    assert (tool#on_key ctx GdkKeysyms._space);
    tool#on_move ctx 60.0 10.0 ~shift:false ~dragging:true;
    (* Anchor command endpoint should be at (60, 10) *)
    let children = layer_children model in
    (match children.(0) with
     | Path { d; _ } ->
       (match List.nth d 1 with
        | CurveTo (_, _, _, _, x, y) ->
          assert (abs_float (x -. 60.0) < 1.0);
          assert (abs_float (y -. 10.0) < 1.0)
        | _ -> assert false)
     | _ -> assert false);
    (* Release Space, drag further — should adjust handles, not reposition *)
    ignore (tool#on_key_release ctx GdkKeysyms._space);
    tool#on_move ctx 70.0 20.0 ~shift:false ~dragging:true;
    (* Anchor should still be near (60, 10) *)
    let children2 = layer_children model in
    (match children2.(0) with
     | Path { d; _ } ->
       (match List.nth d 1 with
        | CurveTo (_, _, _, _, x, y) ->
          assert (abs_float (x -. 60.0) < 1.0);
          assert (abs_float (y -. 10.0) < 1.0)
        | _ -> assert false);
       (* But outgoing handle (x1 of cmd 2) should reflect the drag *)
       (match List.nth d 2 with
        | CurveTo (x1, y1, _, _, _, _) ->
          assert (abs_float (x1 -. 70.0) < 1.0);
          assert (abs_float (y1 -. 20.0) < 1.0)
        | _ -> assert false)
     | _ -> assert false);
    tool#on_release ctx 70.0 20.0 ~shift:false ~alt:false);

  (* ---- Pencil tool ---- *)

  run_test "pencil tool: freehand draw creates path" (fun () ->
    let tool = new Jas.Pencil_tool.pencil_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
    for i = 1 to 20 do
      let x = float_of_int i *. 5.0 in
      let y = sin (float_of_int i *. 0.1) *. 20.0 in
      tool#on_move ctx x y ~shift:false ~dragging:true
    done;
    tool#on_release ctx 100.0 0.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1);
    match children.(0) with
    | Path { d; _ } ->
      assert (List.length d >= 2);
      (match List.hd d with
       | MoveTo _ -> ()
       | _ -> assert false);
      List.iter (fun cmd ->
        match cmd with
        | MoveTo _ | CurveTo _ -> ()
        | _ -> assert false
      ) d
    | _ -> assert false);

  run_test "pencil tool: click without drag creates degenerate path" (fun () ->
    let tool = new Jas.Pencil_tool.pencil_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
    tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1));

  run_test "pencil tool: path has stroke" (fun () ->
    let tool = new Jas.Pencil_tool.pencil_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
    tool#on_move ctx 50.0 50.0 ~shift:false ~dragging:true;
    tool#on_release ctx 100.0 0.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1);
    match children.(0) with
    | Path { stroke; fill; _ } ->
      assert (stroke <> None);
      assert (fill = None)
    | _ -> assert false);

  run_test "pencil tool: release without press is noop" (fun () ->
    let tool = new Jas.Pencil_tool.pencil_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_release ctx 50.0 60.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 0));

  run_test "pencil tool: move without press is noop" (fun () ->
    let tool = new Jas.Pencil_tool.pencil_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_move ctx 50.0 60.0 ~shift:false ~dragging:true;
    let children = layer_children model in
    assert (Array.length children = 0));

  run_test "pencil tool: path starts at press point" (fun () ->
    let tool = new Jas.Pencil_tool.pencil_tool in
    let (ctx, model, _ctrl) = make_ctx () in
    tool#on_press ctx 15.0 25.0 ~shift:false ~alt:false;
    tool#on_move ctx 50.0 50.0 ~shift:false ~dragging:true;
    tool#on_release ctx 100.0 0.0 ~shift:false ~alt:false;
    let children = layer_children model in
    match children.(0) with
    | Path { d; _ } ->
      (match List.hd d with
       | MoveTo (x, y) ->
         assert (x = 15.0);
         assert (y = 25.0)
       | _ -> assert false)
    | _ -> assert false);

  (* ---- Path Eraser tool ---- *)

  run_test "path eraser: erase deletes small path" (fun () ->
    let tool = new Jas.Path_eraser_tool.path_eraser_tool in
    let small = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); LineTo (1.0, 1.0)] in
    let layer = make_layer ~name:"L" [|small|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_press ctx 0.5 0.5 ~shift:false ~alt:false;
    tool#on_release ctx 0.5 0.5 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 0));

  run_test "path eraser: erase splits open path" (fun () ->
    let tool = new Jas.Path_eraser_tool.path_eraser_tool in
    let path = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); LineTo (50.0, 0.0); LineTo (100.0, 0.0); LineTo (150.0, 0.0)] in
    let layer = make_layer ~name:"L" [|path|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_press ctx 75.0 0.0 ~shift:false ~alt:false;
    tool#on_release ctx 75.0 0.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 2));

  run_test "path eraser: erase opens closed path" (fun () ->
    let tool = new Jas.Path_eraser_tool.path_eraser_tool in
    let path = make_path
      ~fill:(Some (make_fill (make_color 0.0 0.0 0.0)))
      ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); LineTo (100.0, 0.0); LineTo (100.0, 100.0);
       LineTo (0.0, 100.0); ClosePath] in
    let layer = make_layer ~name:"L" [|path|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_press ctx 50.0 0.0 ~shift:false ~alt:false;
    tool#on_release ctx 50.0 0.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1);
    (match children.(0) with
     | Path { d; _ } ->
       assert (not (List.exists (fun c -> c = ClosePath) d))
     | _ -> assert false));

  run_test "path eraser: erase miss does nothing" (fun () ->
    let tool = new Jas.Path_eraser_tool.path_eraser_tool in
    let path = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); LineTo (50.0, 0.0); LineTo (100.0, 0.0); LineTo (150.0, 0.0)] in
    let layer = make_layer ~name:"L" [|path|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_press ctx 75.0 50.0 ~shift:false ~alt:false;
    tool#on_release ctx 75.0 50.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1));

  run_test "path eraser: release without press is noop" (fun () ->
    let tool = new Jas.Path_eraser_tool.path_eraser_tool in
    let path = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); LineTo (50.0, 0.0); LineTo (100.0, 0.0); LineTo (150.0, 0.0)] in
    let layer = make_layer ~name:"L" [|path|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_release ctx 75.0 0.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1));

  run_test "path eraser: move without press is noop" (fun () ->
    let tool = new Jas.Path_eraser_tool.path_eraser_tool in
    let path = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); LineTo (50.0, 0.0); LineTo (100.0, 0.0); LineTo (150.0, 0.0)] in
    let layer = make_layer ~name:"L" [|path|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_move ctx 75.0 0.0 ~shift:false ~dragging:true;
    let children = layer_children model in
    assert (Array.length children = 1));

  run_test "path eraser: erasing state transitions" (fun () ->
    let tool = new Jas.Path_eraser_tool.path_eraser_tool in
    let (ctx, _model, _ctrl) = make_ctx () in
    tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
    tool#on_release ctx 0.0 0.0 ~shift:false ~alt:false);

  run_test "path eraser: locked path not erased" (fun () ->
    let tool = new Jas.Path_eraser_tool.path_eraser_tool in
    let small = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      ~locked:true
      [MoveTo (0.0, 0.0); LineTo (1.0, 1.0)] in
    let layer = make_layer ~name:"L" [|small|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_press ctx 0.5 0.5 ~shift:false ~alt:false;
    tool#on_release ctx 0.5 0.5 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 1));

  run_test "path eraser: split endpoints hug eraser" (fun () ->
    let tool = new Jas.Path_eraser_tool.path_eraser_tool in
    (* Horizontal path (0,0)→(100,0)→(200,0).
       Erase at x=50 with eraser_size=2 => eraser rect x=[48,52]. *)
    let path = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); LineTo (100.0, 0.0); LineTo (200.0, 0.0)] in
    let layer = make_layer ~name:"L" [|path|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_press ctx 50.0 0.0 ~shift:false ~alt:false;
    tool#on_release ctx 50.0 0.0 ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 2);
    (* Part 1 should end near x=48. *)
    (match children.(0) with
     | Path { d; _ } ->
       let last = List.nth d (List.length d - 1) in
       (match Jas.Path_eraser_tool.cmd_endpoint last with
        | Some (x, _) -> assert (abs_float (x -. 48.0) < 0.5)
        | None -> assert false)
     | _ -> assert false);
    (* Part 2 should start near x=52. *)
    (match children.(1) with
     | Path { d; _ } ->
       (match List.hd d with
        | MoveTo (x, _) -> assert (abs_float (x -. 52.0) < 0.5)
        | _ -> assert false)
     | _ -> assert false));

  run_test "path eraser: split preserves curves" (fun () ->
    let tool = new Jas.Path_eraser_tool.path_eraser_tool in
    (* Cubic curve from (0,0) to (200,0) arching upward. *)
    let path = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); CurveTo (50.0, -100.0, 150.0, -100.0, 200.0, 0.0)] in
    let layer = make_layer ~name:"L" [|path|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let (ctx, _model, _ctrl) = make_ctx ~model () in
    tool#on_press ctx 100.0 (-75.0) ~shift:false ~alt:false;
    tool#on_release ctx 100.0 (-75.0) ~shift:false ~alt:false;
    let children = layer_children model in
    assert (Array.length children = 2);
    (* Part 1 should end with CurveTo. *)
    (match children.(0) with
     | Path { d; _ } ->
       let last = List.nth d (List.length d - 1) in
       (match last with CurveTo _ -> () | _ -> assert false)
     | _ -> assert false);
    (* Part 2 should contain CurveTo ending at (200, 0). *)
    (match children.(1) with
     | Path { d; _ } ->
       assert (List.length d >= 2);
       let second = List.nth d 1 in
       (match second with
        | CurveTo (_, _, _, _, x, y) ->
          assert (abs_float (x -. 200.0) < 0.01);
          assert (abs_float y < 0.01)
        | _ -> assert false)
     | _ -> assert false));

  run_test "path eraser: de casteljau split exact" (fun () ->
    (* Splitting at t=0.5 on a symmetric curve should give the midpoint. *)
    let (first, second) = Jas.Path_eraser_tool.split_cubic_at
      (0.0, 0.0) 0.0 100.0 100.0 100.0 100.0 0.0 0.5 in
    (match first with
     | CurveTo (_, _, _, _, x, y) ->
       assert (abs_float (x -. 50.0) < 0.01);
       assert (abs_float (y -. 75.0) < 0.01)
     | _ -> assert false);
    (match second with
     | CurveTo (_, _, _, _, x, y) ->
       assert (abs_float (x -. 100.0) < 0.01);
       assert (abs_float y < 0.01)
     | _ -> assert false));

  Printf.printf "All tool interaction tests passed.\n"
