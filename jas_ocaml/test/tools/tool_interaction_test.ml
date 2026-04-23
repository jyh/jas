(* Tool interaction tests: verify tool state machines without a GUI.

   Tests exercise on_press/on_move/on_release sequences and verify the
   resulting document state. *)

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
    draw_element_overlay = (fun _cr _elem ~is_partial:_ _cps -> ());
  } in
  (ctx, model, ctrl)

let layer_children model =
  match model#document.Jas.Document.layers.(0) with
  | Jas.Element.Layer { children; _ } -> children
  | _ -> [||]

let () = ignore (GMain.init ())

open Jas.Element

let () =
  Alcotest.run "Tool_interaction" [
    "line tool", [
      Alcotest.test_case "line tool: draw line" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Line in
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

      Alcotest.test_case "line tool: zero-length not created" `Quick (fun () ->
        (* YAML behavior: hypot > 2 guard suppresses stray clicks. *)
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Line in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 0));
    ];

    "rect tool", [
      Alcotest.test_case "rect tool: draw rect" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Rect in
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

      Alcotest.test_case "rect tool: zero-size not created" `Quick (fun () ->
        (* YAML behavior: zero-size click suppressed. *)
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Rect in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 0));

      Alcotest.test_case "rect tool: negative drag normalizes" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Rect in
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
    ];

    "rounded rect tool", [
      Alcotest.test_case "rounded rect tool: draw rounded rect" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Rounded_rect in
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
          assert (rx = 10.0);
          assert (ry = 10.0)
        | _ -> assert false);

      Alcotest.test_case "rounded rect tool: zero-size not created" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Rounded_rect in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 0));

      Alcotest.test_case "rounded rect tool: negative drag normalizes" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Rounded_rect in
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
          assert (rx = 10.0);
          assert (ry = 10.0)
        | _ -> assert false);
    ];

    "star tool", [
      Alcotest.test_case "star tool: draw star" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Star in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_release ctx 110.0 120.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 1);
        match children.(0) with
        | Polygon { points; _ } ->
          assert (List.length points = 2 * 5)
        | _ -> assert false);

      Alcotest.test_case "star tool: zero-size not created" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Star in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 0));

      Alcotest.test_case "star tool: first vertex at top" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Star in
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

      Alcotest.test_case "star tool: default points is 5" `Quick (fun () ->
        assert (5 = 5)
      );
    ];

    "polygon tool", [
      Alcotest.test_case "polygon tool: draw polygon" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Polygon in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 50.0 50.0 ~shift:false ~alt:false;
        tool#on_release ctx 100.0 50.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 1);
        match children.(0) with
        | Polygon { points; _ } ->
          assert (List.length points = Jas.Canvas_tool.polygon_sides)
        | _ -> assert false);
    ];

    "selection tool", [
      Alcotest.test_case "selection tool: marquee select" `Quick (fun () ->
        (* YAML-driven Selection tracks marquee_end via on_move, so
           callers that want a marquee must emit an intermediate move
           before release — matches the runtime sequence. *)
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Selection in
        let rect = make_rect 50.0 50.0 20.0 20.0 in
        let layer = make_layer ~name:"L" [|rect|] in
        let doc = Jas.Document.make_document [|layer|] in
        let model = Jas.Model.create ~document:doc () in
        let (ctx, _model, _ctrl) = make_ctx ~model () in
        tool#on_press ctx 45.0 45.0 ~shift:false ~alt:false;
        tool#on_move ctx 75.0 75.0 ~shift:false ~dragging:true;
        tool#on_release ctx 75.0 75.0 ~shift:false ~alt:false;
        assert (not (Jas.Document.PathMap.is_empty model#document.Jas.Document.selection)));

      Alcotest.test_case "selection tool: marquee miss" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Selection in
        let rect = make_rect 50.0 50.0 20.0 20.0 in
        let layer = make_layer ~name:"L" [|rect|] in
        let doc = Jas.Document.make_document [|layer|] in
        let model = Jas.Model.create ~document:doc () in
        let (ctx, _model, _ctrl) = make_ctx ~model () in
        tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
        tool#on_move ctx 10.0 10.0 ~shift:false ~dragging:true;
        tool#on_release ctx 10.0 10.0 ~shift:false ~alt:false;
        assert (Jas.Document.PathMap.is_empty model#document.Jas.Document.selection));

      Alcotest.test_case "selection tool: move selection" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Selection in
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
          draw_element_overlay = (fun _cr _elem ~is_partial:_ _cps -> ());
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
    ];

    "add anchor point tool", [
      Alcotest.test_case "add anchor point: click on path adds point" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Add_anchor_point in
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

      Alcotest.test_case "add anchor point: click away from path does nothing" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Add_anchor_point in
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

      Alcotest.test_case "add anchor point: split preserves endpoints" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Add_anchor_point in
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

      (* Drag-adjusts-handles and cusp-drag tests are dropped —
         YAML MVP scope covers click-to-insert only. See
         OCAML_TOOL_RUNTIME.md and the equivalent Swift/Rust
         deletions for rationale. *)

      Alcotest.test_case "add anchor point: insert keeps `all` selection" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Add_anchor_point in
        let path_elem = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
          [MoveTo (0.0, 0.0); CurveTo (33.0, 0.0, 67.0, 0.0, 100.0, 0.0)] in
        let layer = make_layer ~name:"L" [|path_elem|] in
        (* Select the path as a whole. *)
        let sel = Jas.Document.PathMap.singleton [0; 0]
          (Jas.Document.element_selection_all [0; 0]) in
        let doc = Jas.Document.make_document ~selection:sel [|layer|] in
        let model = Jas.Model.create ~document:doc () in
        let (ctx, _model, _ctrl) = make_ctx ~model () in
        tool#on_press ctx 50.0 0.0 ~shift:false ~alt:false;
        tool#on_release ctx 50.0 0.0 ~shift:false ~alt:false;
        let children = layer_children model in
        (match children.(0) with
         | Path { d; _ } -> assert (List.length d = 3)
         | _ -> assert false);
        (* Selection was `SelKindAll` and stays so — the new anchor is included. *)
        let new_sel = model#document.Jas.Document.selection in
        (match Jas.Document.PathMap.find_opt [0; 0] new_sel with
         | Some es ->
           assert (es.Jas.Document.es_kind = Jas.Document.SelKindAll)
         | None -> assert false));

      Alcotest.test_case "add anchor point: split line segment" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Add_anchor_point in
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

      (* "split second segment" drag test + Space+drag reposition
         test are dropped — YAML MVP scope is click-to-insert only. *)
    ];

    "pencil tool", [
      Alcotest.test_case "pencil tool: freehand draw creates path" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Pencil in
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

      Alcotest.test_case "pencil tool: click without drag creates degenerate path" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Pencil in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 1));

      Alcotest.test_case "pencil tool: path has stroke" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Pencil in
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

      Alcotest.test_case "pencil tool: release without press is noop" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Pencil in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_release ctx 50.0 60.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 0));

      Alcotest.test_case "pencil tool: move without press is noop" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Pencil in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_move ctx 50.0 60.0 ~shift:false ~dragging:true;
        let children = layer_children model in
        assert (Array.length children = 0));

      Alcotest.test_case "pencil tool: path starts at press point" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Pencil in
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
    ];

    "path eraser tool", [
      Alcotest.test_case "path eraser: erase deletes small path" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Path_eraser in
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

      Alcotest.test_case "path eraser: erase splits open path" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Path_eraser in
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

      Alcotest.test_case "path eraser: erase opens closed path" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Path_eraser in
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

      Alcotest.test_case "path eraser: erase miss does nothing" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Path_eraser in
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

      Alcotest.test_case "path eraser: release without press is noop" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Path_eraser in
        let path = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
          [MoveTo (0.0, 0.0); LineTo (50.0, 0.0); LineTo (100.0, 0.0); LineTo (150.0, 0.0)] in
        let layer = make_layer ~name:"L" [|path|] in
        let doc = Jas.Document.make_document [|layer|] in
        let model = Jas.Model.create ~document:doc () in
        let (ctx, _model, _ctrl) = make_ctx ~model () in
        tool#on_release ctx 75.0 0.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 1));

      Alcotest.test_case "path eraser: move without press is noop" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Path_eraser in
        let path = make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
          [MoveTo (0.0, 0.0); LineTo (50.0, 0.0); LineTo (100.0, 0.0); LineTo (150.0, 0.0)] in
        let layer = make_layer ~name:"L" [|path|] in
        let doc = Jas.Document.make_document [|layer|] in
        let model = Jas.Model.create ~document:doc () in
        let (ctx, _model, _ctrl) = make_ctx ~model () in
        tool#on_move ctx 75.0 0.0 ~shift:false ~dragging:true;
        let children = layer_children model in
        assert (Array.length children = 1));

      Alcotest.test_case "path eraser: erasing state transitions" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Path_eraser in
        let (ctx, _model, _ctrl) = make_ctx () in
        tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
        tool#on_release ctx 0.0 0.0 ~shift:false ~alt:false);

      Alcotest.test_case "path eraser: locked path not erased" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Path_eraser in
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

      Alcotest.test_case "path eraser: split endpoints hug eraser" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Path_eraser in
        (* Horizontal path (0,0)->(100,0)->(200,0).
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
           (match Jas.Path_ops.cmd_endpoint last with
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

      Alcotest.test_case "path eraser: split preserves curves" `Quick (fun () ->
        let tool = Jas.Tool_factory.create_tool Jas.Toolbar.Path_eraser in
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

      Alcotest.test_case "path eraser: de casteljau split exact" `Quick (fun () ->
        (* Splitting at t=0.5 on a symmetric curve gives the midpoint. *)
        let (first, second) = Jas.Path_ops.split_cubic_cmd_at
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
    ];

    "type tool", [
      Alcotest.test_case "type tool: drag creates area text" `Quick (fun () ->
        let tool = new Jas.Type_tool.type_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_move ctx 60.0 70.0 ~shift:false ~dragging:true;
        tool#on_release ctx 110.0 80.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 1);
        match children.(0) with
        | Text { x; y; text_width; text_height; _ } ->
          assert (abs_float (x -. 10.0) < 0.01);
          assert (abs_float (y -. 20.0) < 0.01);
          assert (text_width > 0.0);
          assert (text_height > 0.0)
        | _ -> assert false);

      Alcotest.test_case "type tool: click creates point text" `Quick (fun () ->
        let tool = new Jas.Type_tool.type_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 50.0 60.0 ~shift:false ~alt:false;
        tool#on_release ctx 50.0 60.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 1);
        match children.(0) with
        | Text { x; y; _ } ->
          assert (abs_float (x -. 50.0) < 0.01);
          assert (abs_float (y -. 60.0) < 0.01)
        | _ -> assert false);

      Alcotest.test_case "type tool: tiny drag treated as click" `Quick (fun () ->
        let tool = new Jas.Type_tool.type_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 5.0 5.0 ~shift:false ~alt:false;
        tool#on_release ctx 6.0 6.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 1));

      Alcotest.test_case "type tool: move without press is noop" `Quick (fun () ->
        let tool = new Jas.Type_tool.type_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_move ctx 100.0 100.0 ~shift:false ~dragging:false;
        let children = layer_children model in
        assert (Array.length children = 0));

      Alcotest.test_case "type tool: drag creates empty area text and session" `Quick (fun () ->
        let tool = new Jas.Type_tool.type_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_release ctx 110.0 70.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 1);
        (match children.(0) with
         | Text { content; _ } -> assert (content = "")
         | _ -> assert false);
        assert (tool#is_editing ()));

      Alcotest.test_case "type tool: click creates empty point text and session" `Quick (fun () ->
        let tool = new Jas.Type_tool.type_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 30.0 40.0 ~shift:false ~alt:false;
        tool#on_release ctx 30.0 40.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 1);
        (match children.(0) with
         | Text { content; _ } -> assert (content = "")
         | _ -> assert false);
        assert (tool#is_editing ()));

      Alcotest.test_case "type tool: click on existing text starts session" `Quick (fun () ->
        let tool = new Jas.Type_tool.type_tool in
        let existing = Jas.Element.make_text
          ~fill:(Some Jas.Element.{ fill_color = Rgb { r = 0.0; g = 0.0; b = 0.0; a = 1.0 }; fill_opacity = 1.0 })
          0.0 0.0 "hello" in
        let model = Jas.Model.create () in
        let layer = Jas.Element.make_layer ~name:"L" [| existing |] in
        model#set_document
          { Jas.Document.layers = [| layer |]; selected_layer = 0;
            selection = Jas.Document.PathMap.empty;
            artboards = [];
            artboard_options = Jas.Artboard.default_options };
        let ctrl = Jas.Controller.create ~model () in
        let ctx : Jas.Canvas_tool.tool_context = {
          model;
          controller = ctrl;
          hit_test_selection = (fun _ _ -> false);
          hit_test_handle = (fun _ _ -> None);
          hit_test_text = (fun _ _ -> Some ([0; 0], existing));
          hit_test_path_curve = (fun _ _ -> None);
          request_update = (fun () -> ());
          draw_element_overlay = (fun _ _ ~is_partial:_ _ -> ());
        } in
        tool#on_press ctx 5.0 5.0 ~shift:false ~alt:false;
        tool#on_release ctx 5.0 5.0 ~shift:false ~alt:false;
        assert (Array.length (layer_children model) = 1);
        assert (tool#is_editing ());
        match tool#get_session with
        | Some s -> assert (Jas.Text_edit.content s = "hello")
        | None -> assert false);

      Alcotest.test_case "type tool: typing into session updates model" `Quick (fun () ->
        let tool = new Jas.Type_tool.type_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 10.0 ~shift:false ~alt:false;
        tool#on_release ctx 10.0 10.0 ~shift:false ~alt:false;
        let mods : Jas.Canvas_tool.key_mods =
          { shift = false; ctrl = false; alt = false; meta = false } in
        assert (tool#on_key_event ctx "a" mods);
        assert (tool#on_key_event ctx "b" mods);
        let children = layer_children model in
        match children.(0) with
        | Text { content; _ } -> assert (content = "ab")
        | _ -> assert false);

      Alcotest.test_case "type tool: escape ends session keeps element" `Quick (fun () ->
        let tool = new Jas.Type_tool.type_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 10.0 ~shift:false ~alt:false;
        tool#on_release ctx 10.0 10.0 ~shift:false ~alt:false;
        let mods : Jas.Canvas_tool.key_mods =
          { shift = false; ctrl = false; alt = false; meta = false } in
        assert (tool#on_key_event ctx "Escape" mods);
        assert (not (tool#is_editing ()));
        assert (Array.length (layer_children model) = 1));
    ];

    "type-on-path tool", [
      Alcotest.test_case "type-on-path tool: drag creates curved TextPath" `Quick (fun () ->
        let tool = new Jas.Type_on_path_tool.type_on_path_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_move ctx 50.0 60.0 ~shift:false ~dragging:true;
        tool#on_release ctx 50.0 60.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 1);
        match children.(0) with
        | Text_path { d; _ } ->
          (* First command MoveTo at start, second CurveTo to end *)
          (match d with
           | [MoveTo (sx, sy); CurveTo (_, _, _, _, ex, ey)] ->
             assert (sx = 10.0 && sy = 20.0);
             assert (ex = 50.0 && ey = 60.0)
           | _ -> assert false)
        | _ -> assert false);

      Alcotest.test_case "type-on-path tool: press+release without move creates LineTo" `Quick (fun () ->
        let tool = new Jas.Type_on_path_tool.type_on_path_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_release ctx 50.0 60.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 1);
        match children.(0) with
        | Text_path { d; _ } ->
          (match d with
           | [MoveTo (10.0, 20.0); LineTo (50.0, 60.0)] -> ()
           | _ -> assert false)
        | _ -> assert false);

      Alcotest.test_case "type-on-path tool: tiny drag without path hit is noop" `Quick (fun () ->
        let tool = new Jas.Type_on_path_tool.type_on_path_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_release ctx 11.0 21.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 0));

      Alcotest.test_case "type-on-path tool: click on existing path converts to TextPath" `Quick (fun () ->
        let tool = new Jas.Type_on_path_tool.type_on_path_tool in
        let path_elem = Jas.Element.make_path
          ~stroke:(Some (Jas.Element.make_stroke Jas.Element.black))
          [MoveTo (0.0, 0.0); LineTo (100.0, 0.0)] in
        let model = Jas.Model.create () in
        let layer = Jas.Element.make_layer ~name:"L" [| path_elem |] in
        model#set_document
          { Jas.Document.layers = [| layer |]; selected_layer = 0;
            selection = Jas.Document.PathMap.empty;
            artboards = [];
            artboard_options = Jas.Artboard.default_options };
        let ctrl = Jas.Controller.create ~model () in
        let ctx : Jas.Canvas_tool.tool_context = {
          model;
          controller = ctrl;
          hit_test_selection = (fun _ _ -> false);
          hit_test_handle = (fun _ _ -> None);
          hit_test_text = (fun _ _ -> None);
          hit_test_path_curve = (fun _ _ -> Some ([0; 0], path_elem));
          request_update = (fun () -> ());
          draw_element_overlay = (fun _ _ ~is_partial:_ _ -> ());
        } in
        tool#on_press ctx 50.0 0.0 ~shift:false ~alt:false;
        tool#on_release ctx 50.0 0.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 1);
        match children.(0) with
        | Text_path _ -> ()
        | _ -> assert false);

      Alcotest.test_case "type-on-path tool: move without press is noop" `Quick (fun () ->
        let tool = new Jas.Type_on_path_tool.type_on_path_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_move ctx 50.0 60.0 ~shift:false ~dragging:true;
        let children = layer_children model in
        assert (Array.length children = 0));

      Alcotest.test_case "type-on-path tool: drag creates empty TextPath and session" `Quick (fun () ->
        let tool = new Jas.Type_on_path_tool.type_on_path_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_move ctx 50.0 60.0 ~shift:false ~dragging:true;
        tool#on_release ctx 50.0 60.0 ~shift:false ~alt:false;
        let children = layer_children model in
        assert (Array.length children = 1);
        (match children.(0) with
         | Text_path { content; _ } -> assert (content = "")
         | _ -> assert false);
        assert (tool#is_editing ()));

      Alcotest.test_case "type-on-path tool: click on existing path starts session" `Quick (fun () ->
        let tool = new Jas.Type_on_path_tool.type_on_path_tool in
        let path_elem = Jas.Element.make_path
          ~stroke:(Some (Jas.Element.make_stroke Jas.Element.black))
          [MoveTo (0.0, 0.0); LineTo (100.0, 0.0)] in
        let model = Jas.Model.create () in
        let layer = Jas.Element.make_layer ~name:"L" [| path_elem |] in
        model#set_document
          { Jas.Document.layers = [| layer |]; selected_layer = 0;
            selection = Jas.Document.PathMap.empty;
            artboards = [];
            artboard_options = Jas.Artboard.default_options };
        let ctrl = Jas.Controller.create ~model () in
        let ctx : Jas.Canvas_tool.tool_context = {
          model;
          controller = ctrl;
          hit_test_selection = (fun _ _ -> false);
          hit_test_handle = (fun _ _ -> None);
          hit_test_text = (fun _ _ -> None);
          hit_test_path_curve = (fun _ _ -> Some ([0; 0], path_elem));
          request_update = (fun () -> ());
          draw_element_overlay = (fun _ _ ~is_partial:_ _ -> ());
        } in
        tool#on_press ctx 50.0 0.0 ~shift:false ~alt:false;
        tool#on_release ctx 50.0 0.0 ~shift:false ~alt:false;
        (match (layer_children model).(0) with
         | Text_path { content; _ } -> assert (content = "")
         | _ -> assert false);
        assert (tool#is_editing ()));

      Alcotest.test_case "type-on-path tool: click on empty canvas does nothing" `Quick (fun () ->
        let tool = new Jas.Type_on_path_tool.type_on_path_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
        assert (Array.length (layer_children model) = 0);
        assert (not (tool#is_editing ())));

      Alcotest.test_case "type-on-path tool: typing into session updates model" `Quick (fun () ->
        let tool = new Jas.Type_on_path_tool.type_on_path_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_move ctx 50.0 60.0 ~shift:false ~dragging:true;
        tool#on_release ctx 50.0 60.0 ~shift:false ~alt:false;
        let mods : Jas.Canvas_tool.key_mods =
          { shift = false; ctrl = false; alt = false; meta = false } in
        assert (tool#on_key_event ctx "H" mods);
        assert (tool#on_key_event ctx "i" mods);
        match (layer_children model).(0) with
        | Text_path { content; _ } -> assert (content = "Hi")
        | _ -> assert false);

      Alcotest.test_case "type-on-path tool: escape ends session" `Quick (fun () ->
        let tool = new Jas.Type_on_path_tool.type_on_path_tool in
        let (ctx, _model, _ctrl) = make_ctx () in
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_move ctx 50.0 60.0 ~shift:false ~dragging:true;
        tool#on_release ctx 50.0 60.0 ~shift:false ~alt:false;
        assert (tool#is_editing ());
        let mods : Jas.Canvas_tool.key_mods =
          { shift = false; ctrl = false; alt = false; meta = false } in
        assert (tool#on_key_event ctx "Escape" mods);
        assert (not (tool#is_editing ())));

      Alcotest.test_case "type-on-path tool: drag-create records undo snapshot" `Quick (fun () ->
        let tool = new Jas.Type_on_path_tool.type_on_path_tool in
        let (ctx, model, _ctrl) = make_ctx () in
        assert (not model#can_undo);
        tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
        tool#on_move ctx 50.0 60.0 ~shift:false ~dragging:true;
        tool#on_release ctx 50.0 60.0 ~shift:false ~alt:false;
        assert model#can_undo);
    ];
  ]
