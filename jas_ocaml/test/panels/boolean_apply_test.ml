(** Tests for Boolean_apply — compound-shape menu dispatch.
    Mirrors jas_dioxus controller_test.rs boolean cases. *)

open Jas.Element
module Model = Jas.Model
module Document = Jas.Document
module Boolean_apply = Jas.Boolean_apply

let rect_at x y =
  Rect { x; y; width = 10.0; height = 10.0; rx = 0.0; ry = 0.0;
         fill = None; stroke = None; opacity = 1.0; transform = None;
         locked = false; visibility = Preview }

let make_model rects selected_paths =
  let layer = Layer {
    name = "L0";
    children = Array.of_list rects;
    opacity = 1.0; transform = None; locked = false; visibility = Preview;
  } in
  let sel = List.fold_left (fun acc path ->
    Document.PathMap.add path (Document.make_element_selection path) acc
  ) Document.PathMap.empty selected_paths in
  let doc = { (Document.make_document [| layer |]) with Document.selection = sel } in
  new Model.model ~document:doc ()

let top_children_count (model : Model.model) =
  match model#document.Document.layers.(0) with
  | Layer { children; _ } -> Array.length children
  | _ -> -1

let test_make_wraps_selection_in_one_compound () =
  let model = make_model [rect_at 0.0 0.0; rect_at 5.0 0.0]
    [[0; 0]; [0; 1]] in
  Boolean_apply.apply_make_compound_shape model;
  Alcotest.(check int) "one child" 1 (top_children_count model);
  match model#document.Document.layers.(0) with
  | Layer { children; _ } ->
    (match children.(0) with
     | Live _ -> ()
     | _ -> Alcotest.fail "expected Live element")
  | _ -> Alcotest.fail "expected Layer"

let test_less_than_two_is_noop () =
  let model = make_model [rect_at 0.0 0.0] [[0; 0]] in
  Boolean_apply.apply_make_compound_shape model;
  Alcotest.(check int) "one child" 1 (top_children_count model);
  match model#document.Document.layers.(0) with
  | Layer { children; _ } ->
    (match children.(0) with
     | Rect _ -> ()
     | _ -> Alcotest.fail "expected Rect")
  | _ -> Alcotest.fail "expected Layer"

let test_release_restores_operands () =
  let model = make_model [rect_at 0.0 0.0; rect_at 5.0 0.0]
    [[0; 0]; [0; 1]] in
  Boolean_apply.apply_make_compound_shape model;
  Boolean_apply.apply_release_compound_shape model;
  Alcotest.(check int) "two children" 2 (top_children_count model)

let test_expand_replaces_with_polygons () =
  let model = make_model [rect_at 0.0 0.0; rect_at 5.0 0.0]
    [[0; 0]; [0; 1]] in
  Boolean_apply.apply_make_compound_shape model;
  Boolean_apply.apply_expand_compound_shape model;
  Alcotest.(check int) "one child (union to 1 polygon)" 1
    (top_children_count model);
  match model#document.Document.layers.(0) with
  | Layer { children; _ } ->
    (match children.(0) with
     | Polygon _ -> ()
     | _ -> Alcotest.fail "expected Polygon")
  | _ -> Alcotest.fail "expected Layer"

(* ── Destructive boolean tests ──────────────────────────────── *)

let two_overlapping () =
  make_model [rect_at 0.0 0.0; rect_at 5.0 0.0] [[0; 0]; [0; 1]]

let test_union_produces_one_polygon () =
  let m = two_overlapping () in
  Boolean_apply.apply_destructive_boolean m "union";
  Alcotest.(check int) "one polygon" 1 (top_children_count m);
  match m#document.Document.layers.(0) with
  | Layer { children; _ } ->
    (match children.(0) with
     | Polygon _ -> ()
     | _ -> Alcotest.fail "expected Polygon")
  | _ -> Alcotest.fail "expected Layer"

let test_intersection_produces_one_polygon () =
  let m = two_overlapping () in
  Boolean_apply.apply_destructive_boolean m "intersection";
  Alcotest.(check int) "one polygon" 1 (top_children_count m)

let test_exclude_produces_two_polygons () =
  let m = two_overlapping () in
  Boolean_apply.apply_destructive_boolean m "exclude";
  Alcotest.(check int) "two polygons" 2 (top_children_count m)

let test_subtract_front_consumes_front () =
  let m = two_overlapping () in
  Boolean_apply.apply_destructive_boolean m "subtract_front";
  Alcotest.(check int) "one polygon" 1 (top_children_count m)

let test_subtract_back_consumes_back () =
  let m = two_overlapping () in
  Boolean_apply.apply_destructive_boolean m "subtract_back";
  Alcotest.(check int) "one polygon" 1 (top_children_count m)

let test_crop_uses_frontmost_as_mask () =
  let m = two_overlapping () in
  Boolean_apply.apply_destructive_boolean m "crop";
  Alcotest.(check int) "one polygon" 1 (top_children_count m)

let test_unknown_op_is_noop () =
  let m = two_overlapping () in
  let before = top_children_count m in
  Boolean_apply.apply_destructive_boolean m "nonexistent";
  Alcotest.(check int) "unchanged" before (top_children_count m)

let () =
  Alcotest.run "Boolean_apply"
    [ "compound shape", [
        Alcotest.test_case "make wraps selection" `Quick
          test_make_wraps_selection_in_one_compound;
        Alcotest.test_case "less than two is noop" `Quick
          test_less_than_two_is_noop;
        Alcotest.test_case "release restores operands" `Quick
          test_release_restores_operands;
        Alcotest.test_case "expand replaces with polygons" `Quick
          test_expand_replaces_with_polygons;
      ];
      "destructive boolean", [
        Alcotest.test_case "union produces one polygon" `Quick
          test_union_produces_one_polygon;
        Alcotest.test_case "intersection produces one polygon" `Quick
          test_intersection_produces_one_polygon;
        Alcotest.test_case "exclude produces two polygons" `Quick
          test_exclude_produces_two_polygons;
        Alcotest.test_case "subtract_front consumes front" `Quick
          test_subtract_front_consumes_front;
        Alcotest.test_case "subtract_back consumes back" `Quick
          test_subtract_back_consumes_back;
        Alcotest.test_case "crop uses frontmost as mask" `Quick
          test_crop_uses_frontmost_as_mask;
        Alcotest.test_case "unknown op is noop" `Quick
          test_unknown_op_is_noop;
      ]
    ]
