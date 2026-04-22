(** Tests for the LiveElement framework — mirror of jas_dioxus
    live.rs tests. *)

open Jas.Element
module Live = Jas.Live

let rect_at x y =
  Rect { x; y; width = 10.0; height = 10.0; rx = 0.0; ry = 0.0;
         fill = None; stroke = None; opacity = 1.0; transform = None;
         locked = false; visibility = Preview; blend_mode = Normal; mask = None }

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
  let path = Path {
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
  } in
  let ps = Live.element_to_polygon_set path Live.default_precision in
  Alcotest.(check int) "one ring" 1 (List.length ps)

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
      ]
    ]
