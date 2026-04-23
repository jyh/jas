(** Phase 3 of the OCaml YAML tool-runtime migration.
    Tests for doc_primitives, point_buffers, anchor_buffers, and
    the new evaluator primitives (math + doc-aware + buffer_length). *)

open Jas

let make_rect x y w h =
  Element.Rect {
    x; y; width = w; height = h;
    rx = 0.0; ry = 0.0;
    fill = None; stroke = None;
    opacity = 1.0; transform = None; locked = false;
    visibility = Preview; blend_mode = Normal; mask = None;
    fill_gradient = None; stroke_gradient = None;
  }

let doc_with_rect () =
  let layer = Element.Layer {
    name = "L"; children = [| make_rect 10.0 10.0 20.0 20.0 |];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  Document.make_document [| layer |]

(* ── Doc primitives ────────────────────────────────────── *)

let doc_primitive_tests = [
  Alcotest.test_case "hit_test_without_doc_returns_null" `Quick (fun () ->
    let v = Expr_eval.evaluate "hit_test(15, 15)" (`Assoc []) in
    assert (v = Expr_eval.Null));

  Alcotest.test_case "hit_test_hits_inside" `Quick (fun () ->
    Doc_primitives.with_doc (doc_with_rect ()) (fun () ->
      let v = Expr_eval.evaluate "hit_test(15, 15)" (`Assoc []) in
      assert (v = Expr_eval.Path [0; 0])));

  Alcotest.test_case "hit_test_misses_outside" `Quick (fun () ->
    Doc_primitives.with_doc (doc_with_rect ()) (fun () ->
      let v = Expr_eval.evaluate "hit_test(100, 100)" (`Assoc []) in
      assert (v = Expr_eval.Null)));

  Alcotest.test_case "doc_guard_restores_prior" `Quick (fun () ->
    let outer = doc_with_rect () in
    Doc_primitives.with_doc outer (fun () ->
      assert (Expr_eval.evaluate "hit_test(15, 15)" (`Assoc []) = Path [0; 0]);
      Doc_primitives.with_doc (Document.make_document [||]) (fun () ->
        assert (Expr_eval.evaluate "hit_test(15, 15)" (`Assoc []) = Null));
      (* After inner exit, outer is restored. *)
      assert (Expr_eval.evaluate "hit_test(15, 15)" (`Assoc []) = Path [0; 0]));
    (* After outer exit, no doc. *)
    assert (Expr_eval.evaluate "hit_test(15, 15)" (`Assoc []) = Null));

  Alcotest.test_case "selection_contains_path" `Quick (fun () ->
    let doc = doc_with_rect () in
    let sel = Document.PathMap.add [0; 0]
      (Document.element_selection_all [0; 0]) Document.PathMap.empty in
    let doc = { doc with Document.selection = sel } in
    Doc_primitives.with_doc doc (fun () ->
      let v = Expr_eval.evaluate "selection_contains(path(0, 0))" (`Assoc []) in
      assert (v = Expr_eval.Bool true);
      let no = Expr_eval.evaluate "selection_contains(path(0, 1))" (`Assoc []) in
      assert (no = Expr_eval.Bool false)));

  Alcotest.test_case "selection_empty_reflects_doc" `Quick (fun () ->
    let empty = Document.make_document [||] in
    Doc_primitives.with_doc empty (fun () ->
      let v = Expr_eval.evaluate "selection_empty()" (`Assoc []) in
      assert (v = Expr_eval.Bool true)));
]

(* ── Math primitives ───────────────────────────────────── *)

let math_tests = [
  Alcotest.test_case "min_max_abs" `Quick (fun () ->
    assert (Expr_eval.evaluate "min(3, 1, 2)" (`Assoc []) = Number 1.0);
    assert (Expr_eval.evaluate "max(3, 1, 2)" (`Assoc []) = Number 3.0);
    assert (Expr_eval.evaluate "abs(-5)" (`Assoc []) = Number 5.0));

  Alcotest.test_case "sqrt_and_hypot" `Quick (fun () ->
    assert (Expr_eval.evaluate "sqrt(9)" (`Assoc []) = Number 3.0);
    assert (Expr_eval.evaluate "hypot(3, 4)" (`Assoc []) = Number 5.0));

  Alcotest.test_case "sqrt_rejects_negative" `Quick (fun () ->
    assert (Expr_eval.evaluate "sqrt(-1)" (`Assoc []) = Null));
]

(* ── Point buffers ─────────────────────────────────────── *)

let point_buffer_tests = [
  Alcotest.test_case "push_and_length" `Quick (fun () ->
    Point_buffers.clear "test_buf_a";
    assert (Point_buffers.length "test_buf_a" = 0);
    Point_buffers.push "test_buf_a" 1.0 2.0;
    Point_buffers.push "test_buf_a" 3.0 4.0;
    assert (Point_buffers.length "test_buf_a" = 2);
    let pts = Point_buffers.points "test_buf_a" in
    assert (List.length pts = 2);
    assert (List.nth pts 0 = (1.0, 2.0));
    assert (List.nth pts 1 = (3.0, 4.0));
    Point_buffers.clear "test_buf_a";
    assert (Point_buffers.length "test_buf_a" = 0));

  Alcotest.test_case "buffer_length_primitive" `Quick (fun () ->
    Point_buffers.clear "test_buf_b";
    Point_buffers.push "test_buf_b" 1.0 2.0;
    Point_buffers.push "test_buf_b" 3.0 4.0;
    Point_buffers.push "test_buf_b" 5.0 6.0;
    let v = Expr_eval.evaluate "buffer_length('test_buf_b')" (`Assoc []) in
    assert (v = Number 3.0);
    Point_buffers.clear "test_buf_b");
]

(* ── Anchor buffers ────────────────────────────────────── *)

let anchor_buffer_tests = [
  Alcotest.test_case "push_creates_corner" `Quick (fun () ->
    Anchor_buffers.clear "test_anc_a";
    Anchor_buffers.push "test_anc_a" 10.0 20.0;
    (match Anchor_buffers.first "test_anc_a" with
     | Some a ->
       assert (a.x = 10.0); assert (a.y = 20.0);
       assert (a.hx_in = 10.0); assert (a.hy_in = 20.0);
       assert (a.hx_out = 10.0); assert (a.hy_out = 20.0);
       assert (not a.smooth)
     | None -> assert false);
    Anchor_buffers.clear "test_anc_a");

  Alcotest.test_case "set_last_out_mirrors_in" `Quick (fun () ->
    Anchor_buffers.clear "test_anc_b";
    Anchor_buffers.push "test_anc_b" 50.0 50.0;
    Anchor_buffers.set_last_out_handle "test_anc_b" 60.0 50.0;
    (match Anchor_buffers.first "test_anc_b" with
     | Some a ->
       assert (a.hx_out = 60.0); assert (a.hy_out = 50.0);
       (* Mirrored: (2*50 - 60, 2*50 - 50) = (40, 50) *)
       assert (a.hx_in = 40.0); assert (a.hy_in = 50.0);
       assert a.smooth
     | None -> assert false);
    Anchor_buffers.clear "test_anc_b");

  Alcotest.test_case "pop" `Quick (fun () ->
    Anchor_buffers.clear "test_anc_c";
    Anchor_buffers.push "test_anc_c" 1.0 2.0;
    Anchor_buffers.push "test_anc_c" 3.0 4.0;
    assert (Anchor_buffers.length "test_anc_c" = 2);
    Anchor_buffers.pop "test_anc_c";
    assert (Anchor_buffers.length "test_anc_c" = 1);
    (match Anchor_buffers.first "test_anc_c" with
     | Some a -> assert (a.x = 1.0)
     | None -> assert false);
    Anchor_buffers.clear "test_anc_c");

  Alcotest.test_case "close_hit_primitive" `Quick (fun () ->
    Anchor_buffers.clear "test_anc_d";
    Anchor_buffers.push "test_anc_d" 0.0 0.0;
    Anchor_buffers.push "test_anc_d" 100.0 0.0;
    (* Cursor at (3, 4) — hypot = 5, within r=8. *)
    let hit = Expr_eval.evaluate
      "anchor_buffer_close_hit('test_anc_d', 3, 4, 8)" (`Assoc []) in
    assert (hit = Bool true);
    (* Cursor at (20, 0) — too far. *)
    let miss = Expr_eval.evaluate
      "anchor_buffer_close_hit('test_anc_d', 20, 0, 8)" (`Assoc []) in
    assert (miss = Bool false);
    Anchor_buffers.clear "test_anc_d");

  Alcotest.test_case "close_hit_rejects_short_buffer" `Quick (fun () ->
    Anchor_buffers.clear "test_anc_e";
    Anchor_buffers.push "test_anc_e" 0.0 0.0;
    (* Only 1 anchor — close_hit requires >= 2. *)
    let v = Expr_eval.evaluate
      "anchor_buffer_close_hit('test_anc_e', 1, 1, 10)" (`Assoc []) in
    assert (v = Bool false);
    Anchor_buffers.clear "test_anc_e");
]

let () =
  Alcotest.run "Doc primitives + buffers" [
    "Doc primitives", doc_primitive_tests;
    "Math", math_tests;
    "Point buffers", point_buffer_tests;
    "Anchor buffers", anchor_buffer_tests;
  ]
