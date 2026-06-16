(** Tests for the LiveElement framework — mirror of jas_dioxus
    live.rs tests. *)

open Jas.Element
module Live = Jas.Live

let rect_at x y =
  Rect { name = None; id = None; x; y; width = 10.0; height = 10.0; rx = 0.0; ry = 0.0;
         fill = None; stroke = None; opacity = 1.0; transform = None;
         locked = false; visibility = Preview; blend_mode = Normal; mask = None;
           fill_gradient = None;
           stroke_gradient = None;
         }

let bbox_of_ring ring =
  let min_x = ref infinity in
  let min_y = ref infinity in
  let max_x = ref neg_infinity in
  let max_y = ref neg_infinity in
  Array.iter (fun (x, y) ->
    if x < !min_x then min_x := x;
    if y < !min_y then min_y := y;
    if x > !max_x then max_x := x;
    if y > !max_y then max_y := y
  ) ring;
  (!min_x, !min_y, !max_x, !max_y)

let approx_equal a b = abs_float (a -. b) < 1e-6

let test_element_to_polygon_set_rect () =
  let ps = Live.element_to_polygon_set (rect_at 0.0 0.0)
             Live.default_precision in
  Alcotest.(check int) "one ring" 1 (List.length ps)

let test_union_of_two_rects () =
  let cs = {
    operation = Op_union;
    id = None;
    operands = [| rect_at 0.0 0.0; rect_at 5.0 0.0 |];
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview; blend_mode = Normal;
    mask = None;
  } in
  let ps = Live.evaluate cs Live.default_precision in
  Alcotest.(check int) "one ring" 1 (List.length ps);
  let ring = List.hd ps in
  let (min_x, _, max_x, _) = bbox_of_ring ring in
  Alcotest.(check bool) "min_x = 0" true (approx_equal min_x 0.0);
  Alcotest.(check bool) "max_x = 15" true (approx_equal max_x 15.0)

let test_intersection_of_two_rects () =
  let cs = {
    operation = Op_intersection;
    id = None;
    operands = [| rect_at 0.0 0.0; rect_at 5.0 0.0 |];
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview; blend_mode = Normal;
    mask = None;
  } in
  let ps = Live.evaluate cs Live.default_precision in
  Alcotest.(check int) "one ring" 1 (List.length ps);
  let ring = List.hd ps in
  let (min_x, _, max_x, _) = bbox_of_ring ring in
  Alcotest.(check bool) "min_x = 5" true (approx_equal min_x 5.0);
  Alcotest.(check bool) "max_x = 10" true (approx_equal max_x 10.0)

let test_exclude_is_symmetric_difference () =
  let cs = {
    operation = Op_exclude;
    id = None;
    operands = [| rect_at 0.0 0.0; rect_at 5.0 0.0 |];
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview; blend_mode = Normal;
    mask = None;
  } in
  let ps = Live.evaluate cs Live.default_precision in
  Alcotest.(check int) "two rings" 2 (List.length ps)

let test_subtract_front () =
  let cs = {
    operation = Op_subtract_front;
    id = None;
    operands = [| rect_at 0.0 0.0; rect_at 5.0 0.0 |];
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview; blend_mode = Normal;
    mask = None;
  } in
  let ps = Live.evaluate cs Live.default_precision in
  Alcotest.(check int) "one ring" 1 (List.length ps);
  let ring = List.hd ps in
  let (min_x, _, max_x, _) = bbox_of_ring ring in
  Alcotest.(check bool) "min_x = 0" true (approx_equal min_x 0.0);
  Alcotest.(check bool) "max_x = 5" true (approx_equal max_x 5.0)

let test_bounds_reflect_evaluation () =
  let cs = {
    operation = Op_union;
    id = None;
    operands = [| rect_at 0.0 0.0; rect_at 5.0 0.0 |];
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview; blend_mode = Normal;
    mask = None;
  } in
  let (bx, by, bw, bh) = Jas.Element.bounds (Live (Compound_shape cs)) in
  Alcotest.(check bool) "bx = 0" true (approx_equal bx 0.0);
  Alcotest.(check bool) "by = 0" true (approx_equal by 0.0);
  Alcotest.(check bool) "bw = 15" true (approx_equal bw 15.0);
  Alcotest.(check bool) "bh = 10" true (approx_equal bh 10.0)

let test_empty_compound_has_empty_bounds () =
  let cs = {
    operation = Op_union;
    id = None;
    operands = [||];
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview; blend_mode = Normal;
    mask = None;
  } in
  let (bx, by, bw, bh) = Jas.Element.bounds (Live (Compound_shape cs)) in
  Alcotest.(check bool) "bx = 0" true (approx_equal bx 0.0);
  Alcotest.(check bool) "by = 0" true (approx_equal by 0.0);
  Alcotest.(check bool) "bw = 0" true (approx_equal bw 0.0);
  Alcotest.(check bool) "bh = 0" true (approx_equal bh 0.0)

let test_path_flattens_into_polygon_set () =
  let path = Path { name = None; id = None;
    d = [
      MoveTo (0.0, 0.0);
      LineTo (10.0, 0.0);
      LineTo (10.0, 10.0);
      LineTo (0.0, 10.0);
      ClosePath;
    ];
    fill = None; stroke = None; width_points = [];
    opacity = 1.0; transform = None; locked = false; visibility = Preview;
    blend_mode = Normal;
    mask = None;
    fill_gradient = None;
    stroke_gradient = None;
    stroke_brush = None;
    stroke_brush_overrides = None;
    tool_origin = None;
  } in
  let ps = Live.element_to_polygon_set path Live.default_precision in
  Alcotest.(check int) "one ring" 1 (List.length ps)

(* --- Reference (REFERENCE_GRAPH.md Phase 1a) ---------------------- *)

(* A test resolver backed by an id->element association list. *)
let map_resolver pairs : Live.element_resolver =
  fun id -> List.assoc_opt id pairs

let reference_elem target = {
  ref_target = target;
  ref_id = None;
  ref_instance_transform = None;
  ref_fill = None;
  ref_stroke = None;
  ref_opacity = 1.0;
  ref_transform = None;
  ref_locked = false;
  ref_visibility = Preview;
  ref_blend_mode = Normal;
  ref_mask = None;
}

let test_reference_evaluates_to_target () =
  let resolver = map_resolver [ ("r1", rect_at 0.0 0.0) ] in
  let r = reference_elem "r1" in
  let visiting = ref Live.VisitSet.empty in
  let ps = Live.reference_evaluate r Live.default_precision resolver visiting in
  Alcotest.(check int) "one ring" 1 (List.length ps);
  let (min_x, _, max_x, _) = bbox_of_ring (List.hd ps) in
  Alcotest.(check bool) "min_x = 0" true (approx_equal min_x 0.0);
  Alcotest.(check bool) "max_x = 10" true (approx_equal max_x 10.0);
  (* The cycle-guard set is left clean after a successful resolve. *)
  Alcotest.(check bool) "visiting empty" true (Live.VisitSet.is_empty !visiting)

let test_dangling_reference_is_empty () =
  let r = reference_elem "missing" in
  let visiting = ref Live.VisitSet.empty in
  let ps =
    Live.reference_evaluate r Live.default_precision Live.null_resolver visiting in
  Alcotest.(check bool) "empty" true (ps = [])

let test_reference_cycle_breaks_to_empty () =
  (* Resolver where id "a" resolves to a reference back to "a" — a
     self-cycle. The threaded visited-set must break it. *)
  let cycle_resolver : Live.element_resolver = fun id ->
    if id = "a" then Some (Live (Reference (reference_elem "a")))
    else None
  in
  let r = reference_elem "a" in
  let visiting = ref Live.VisitSet.empty in
  let ps =
    Live.reference_evaluate r Live.default_precision cycle_resolver visiting in
  Alcotest.(check bool) "empty" true (ps = []);
  Alcotest.(check bool) "visiting restored" true
    (Live.VisitSet.is_empty !visiting)

let test_reference_reports_dependency () =
  let r = reference_elem "t" in
  Alcotest.(check (list string)) "dependency is target" ["t"]
    (Live.dependencies (Reference r))

(* A rect carrying a stable id (the [rect_at] helper leaves id = None). *)
let rect_with_id id x y =
  Rect { name = None; id = Some id; x; y; width = 10.0; height = 10.0;
         rx = 0.0; ry = 0.0;
         fill = None; stroke = None; opacity = 1.0; transform = None;
         locked = false; visibility = Preview; blend_mode = Normal; mask = None;
         fill_gradient = None; stroke_gradient = None;
       }

(* Mirror of Rust render_ref_index_resolves_reference_to_target:
   resolver_of_document builds the per-paint id->element index from the
   document layers; the resolver reads it, so a reference resolves and
   evaluates to its target's geometry (Phase 1b render wiring). A
   missing id resolves to None (dangling). *)
let test_resolver_of_document_resolves_reference () =
  let layer = make_layer [| rect_with_id "r1" 0.0 0.0 |] in
  let resolver = Live.resolver_of_document [| layer |] in
  Alcotest.(check bool) "resolves r1" true (resolver "r1" <> None);
  Alcotest.(check bool) "missing id is None" true (resolver "missing" = None);
  let r = reference_elem "r1" in
  let visiting = ref Live.VisitSet.empty in
  let ps = Live.reference_evaluate r Live.default_precision resolver visiting in
  Alcotest.(check int) "reference resolves to the rect single ring"
    1 (List.length ps);
  let (min_x, _, max_x, _) = bbox_of_ring (List.hd ps) in
  Alcotest.(check bool) "min_x = 0" true (approx_equal min_x 0.0);
  Alcotest.(check bool) "max_x = 10" true (approx_equal max_x 10.0)

let test_compound_has_no_dependencies () =
  let cs = {
    operation = Op_union;
    id = None;
    operands = [| rect_at 0.0 0.0 |];
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview; blend_mode = Normal;
    mask = None;
  } in
  Alcotest.(check (list string)) "no dependencies" []
    (Live.dependencies (Compound_shape cs))

let () =
  Alcotest.run "Live"
    [ "compound shape", [
        Alcotest.test_case "rect to polygon set" `Quick
          test_element_to_polygon_set_rect;
        Alcotest.test_case "union of two rects" `Quick
          test_union_of_two_rects;
        Alcotest.test_case "intersection of two rects" `Quick
          test_intersection_of_two_rects;
        Alcotest.test_case "exclude is symmetric difference" `Quick
          test_exclude_is_symmetric_difference;
        Alcotest.test_case "subtract front" `Quick
          test_subtract_front;
        Alcotest.test_case "bounds reflect evaluation" `Quick
          test_bounds_reflect_evaluation;
        Alcotest.test_case "empty compound has empty bounds" `Quick
          test_empty_compound_has_empty_bounds;
        Alcotest.test_case "path flattens to polygon set" `Quick
          test_path_flattens_into_polygon_set;
      ];
      "reference", [
        Alcotest.test_case "reference evaluates to target geometry" `Quick
          test_reference_evaluates_to_target;
        Alcotest.test_case "dangling reference evaluates empty" `Quick
          test_dangling_reference_is_empty;
        Alcotest.test_case "reference cycle breaks to empty" `Quick
          test_reference_cycle_breaks_to_empty;
        Alcotest.test_case "reference reports its target as dependency" `Quick
          test_reference_reports_dependency;
        Alcotest.test_case "resolver_of_document resolves reference" `Quick
          test_resolver_of_document_resolves_reference;
        Alcotest.test_case "compound shape has no dependencies" `Quick
          test_compound_has_no_dependencies;
      ]
    ]
