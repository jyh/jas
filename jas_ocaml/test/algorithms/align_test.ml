(** Tests for the OCaml Align algorithm primitives. Parallels
    [jas_dioxus/src/algorithms/align.rs] and
    [JasSwift/Tests/Algorithms/AlignTests.swift]. *)

open Jas

let rect x y w h =
  Element.make_rect x y w h

let tests = [
  Alcotest.test_case "union_bounds_empty_returns_zero" `Quick (fun () ->
    let b = Align.union_bounds [] Align.geometric_bounds in
    assert (b = (0.0, 0.0, 0.0, 0.0)));

  Alcotest.test_case "union_bounds_single_element" `Quick (fun () ->
    let b = Align.union_bounds [rect 10.0 20.0 30.0 40.0] Align.geometric_bounds in
    assert (b = (10.0, 20.0, 30.0, 40.0)));

  Alcotest.test_case "union_bounds_three_elements_spans_all" `Quick (fun () ->
    let b = Align.union_bounds
      [rect 0.0 0.0 10.0 10.0;
       rect 20.0 5.0 10.0 10.0;
       rect 40.0 40.0 20.0 20.0]
      Align.geometric_bounds in
    assert (b = (0.0, 0.0, 60.0, 60.0)));

  Alcotest.test_case "axis_extent_horizontal" `Quick (fun () ->
    let (lo, hi, mid) = Align.axis_extent (10.0, 20.0, 40.0, 60.0) Align.Horizontal in
    assert (lo = 10.0 && hi = 50.0 && mid = 30.0));

  Alcotest.test_case "axis_extent_vertical" `Quick (fun () ->
    let (lo, hi, mid) = Align.axis_extent (10.0, 20.0, 40.0, 60.0) Align.Vertical in
    assert (lo = 20.0 && hi = 80.0 && mid = 50.0));

  Alcotest.test_case "anchor_position_min_center_max" `Quick (fun () ->
    let b = (10.0, 20.0, 40.0, 60.0) in
    assert (Align.anchor_position b Align.Horizontal Align.Anchor_min = 10.0);
    assert (Align.anchor_position b Align.Horizontal Align.Anchor_center = 30.0);
    assert (Align.anchor_position b Align.Horizontal Align.Anchor_max = 50.0);
    assert (Align.anchor_position b Align.Vertical Align.Anchor_min = 20.0);
    assert (Align.anchor_position b Align.Vertical Align.Anchor_center = 50.0);
    assert (Align.anchor_position b Align.Vertical Align.Anchor_max = 80.0));

  Alcotest.test_case "reference_bbox_unpacks_each_variant" `Quick (fun () ->
    let b = (1.0, 2.0, 3.0, 4.0) in
    assert (Align.reference_bbox (Align.Selection b) = b);
    assert (Align.reference_bbox (Align.Artboard b) = b);
    assert (Align.reference_bbox (Align.Key_object { bbox = b; path = [0] }) = b));

  Alcotest.test_case "reference_key_path_only_for_key_object" `Quick (fun () ->
    let b = (0.0, 0.0, 10.0, 10.0) in
    assert (Align.reference_key_path (Align.Selection b) = None);
    assert (Align.reference_key_path (Align.Artboard b) = None);
    assert (Align.reference_key_path
              (Align.Key_object { bbox = b; path = [0; 2] }) = Some [0; 2]));

  Alcotest.test_case "preview_bounds_matches_element_bounds" `Quick (fun () ->
    let r = rect 10.0 20.0 30.0 40.0 in
    assert (Align.preview_bounds r = Element.bounds r));

  Alcotest.test_case "geometric_bounds_matches_element_geometric_bounds" `Quick (fun () ->
    let r = rect 10.0 20.0 30.0 40.0 in
    assert (Align.geometric_bounds r = Element.geometric_bounds r));
]

let ref_of rects =
  Align.Selection (Align.union_bounds rects Align.geometric_bounds)

let pair path e = (path, e)

let op_tests = [
  Alcotest.test_case "align_left_moves_two_rects_to_left_edge" `Quick (fun () ->
    let rs = [rect 10.0 0.0 10.0 10.0; rect 30.0 0.0 10.0 10.0;
              rect 60.0 0.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.align_left input r Align.geometric_bounds in
    assert (List.length out = 2);
    let t1 = List.nth out 0 in
    assert (t1.Align.path = [1] && t1.Align.dx = -20.0 && t1.Align.dy = 0.0);
    let t2 = List.nth out 1 in
    assert (t2.Align.path = [2] && t2.Align.dx = -50.0 && t2.Align.dy = 0.0));

  Alcotest.test_case "align_right_moves_to_right_edge" `Quick (fun () ->
    let rs = [rect 10.0 0.0 10.0 10.0; rect 30.0 0.0 10.0 10.0;
              rect 60.0 0.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.align_right input r Align.geometric_bounds in
    assert (List.length out = 2);
    assert ((List.nth out 0).Align.dx = 50.0);
    assert ((List.nth out 1).Align.dx = 30.0));

  Alcotest.test_case "align_horizontal_center_moves_to_midpoint" `Quick (fun () ->
    let rs = [rect 10.0 0.0 10.0 10.0; rect 30.0 0.0 10.0 10.0;
              rect 60.0 0.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.align_horizontal_center input r Align.geometric_bounds in
    assert (List.length out = 3);
    assert ((List.nth out 0).Align.dx = 25.0);
    assert ((List.nth out 1).Align.dx = 5.0);
    assert ((List.nth out 2).Align.dx = -25.0));

  Alcotest.test_case "align_top_only_affects_y" `Quick (fun () ->
    let rs = [rect 0.0 10.0 10.0 10.0; rect 20.0 30.0 10.0 10.0;
              rect 40.0 50.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.align_top input r Align.geometric_bounds in
    List.iter (fun t -> assert (t.Align.dx = 0.0)) out;
    assert (List.length out = 2));

  Alcotest.test_case "align_vertical_center_moves_to_midline" `Quick (fun () ->
    let rs = [rect 0.0 0.0 10.0 10.0; rect 20.0 20.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.align_vertical_center input r Align.geometric_bounds in
    assert (List.length out = 2);
    assert ((List.nth out 0).Align.dy = 10.0);
    assert ((List.nth out 1).Align.dy = -10.0));

  Alcotest.test_case "align_bottom_moves_to_bottom_edge" `Quick (fun () ->
    let rs = [rect 0.0 0.0 10.0 20.0; rect 20.0 0.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.align_bottom input r Align.geometric_bounds in
    assert (List.length out = 1);
    assert ((List.nth out 0).Align.path = [1]);
    assert ((List.nth out 0).Align.dy = 10.0));

  Alcotest.test_case "align_left_with_key_object_does_not_move_key" `Quick (fun () ->
    let rs = [rect 10.0 0.0 10.0 10.0; rect 30.0 0.0 10.0 10.0;
              rect 60.0 0.0 10.0 10.0] in
    let key = Align.Key_object {
      bbox = Element.geometric_bounds (List.nth rs 1); path = [1] } in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.align_left input key Align.geometric_bounds in
    List.iter (fun t -> assert (t.Align.path <> [1])) out;
    assert (List.length out = 2);
    let t0 = List.nth out 0 in
    assert (t0.Align.path = [0] && t0.Align.dx = 20.0);
    let t2 = List.nth out 1 in
    assert (t2.Align.path = [2] && t2.Align.dx = -30.0));

  Alcotest.test_case "align_left_empty_input_yields_empty_output" `Quick (fun () ->
    let r = Align.Selection (0.0, 0.0, 10.0, 10.0) in
    let out = Align.align_left [] r Align.geometric_bounds in
    assert (out = []));
]

let dist_tests = [
  Alcotest.test_case "distribute_requires_at_least_three" `Quick (fun () ->
    let rs = [rect 0.0 0.0 10.0 10.0; rect 50.0 0.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    assert (Align.distribute_left input r Align.geometric_bounds = []));

  Alcotest.test_case "distribute_left_already_even_no_translations" `Quick (fun () ->
    let rs = [rect 0.0 0.0 10.0 10.0; rect 50.0 0.0 10.0 10.0;
              rect 100.0 0.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    assert (Align.distribute_left input r Align.geometric_bounds = []));

  Alcotest.test_case "distribute_left_uneven_moves_middle" `Quick (fun () ->
    let rs = [rect 0.0 0.0 10.0 10.0; rect 30.0 0.0 10.0 10.0;
              rect 100.0 0.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.distribute_left input r Align.geometric_bounds in
    assert (List.length out = 1);
    assert ((List.nth out 0).Align.path = [1]);
    assert ((List.nth out 0).Align.dx = 20.0));

  Alcotest.test_case "distribute_horizontal_center_evenly_spaces" `Quick (fun () ->
    let rs = [rect 0.0 0.0 10.0 10.0; rect 20.0 0.0 10.0 10.0;
              rect 100.0 0.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.distribute_horizontal_center input r Align.geometric_bounds in
    assert (List.length out = 1);
    assert ((List.nth out 0).Align.dx = 30.0));

  Alcotest.test_case "distribute_right_distributes_right_edges" `Quick (fun () ->
    let rs = [rect 0.0 0.0 10.0 10.0; rect 20.0 0.0 10.0 10.0;
              rect 100.0 0.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.distribute_right input r Align.geometric_bounds in
    assert (List.length out = 1);
    assert ((List.nth out 0).Align.dx = 30.0));

  Alcotest.test_case "distribute_top_moves_only_y" `Quick (fun () ->
    let rs = [rect 0.0 0.0 10.0 10.0; rect 5.0 30.0 10.0 10.0;
              rect 10.0 100.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.distribute_top input r Align.geometric_bounds in
    assert (List.length out = 1);
    assert ((List.nth out 0).Align.dx = 0.0);
    assert ((List.nth out 0).Align.dy = 20.0));

  Alcotest.test_case "distribute_handles_unsorted_input" `Quick (fun () ->
    let rs = [rect 100.0 0.0 10.0 10.0; rect 30.0 0.0 10.0 10.0;
              rect 0.0 0.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.distribute_left input r Align.geometric_bounds in
    assert (List.length out = 1);
    assert ((List.nth out 0).Align.path = [1]);
    assert ((List.nth out 0).Align.dx = 20.0));

  Alcotest.test_case "distribute_artboard_uses_artboard_extent" `Quick (fun () ->
    let rs = [rect 20.0 0.0 10.0 10.0; rect 40.0 0.0 10.0 10.0;
              rect 60.0 0.0 10.0 10.0] in
    let r = Align.Artboard (0.0, 0.0, 200.0, 100.0) in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.distribute_left input r Align.geometric_bounds in
    assert (List.length out = 3);
    assert ((List.nth out 0).Align.dx = -20.0);
    assert ((List.nth out 1).Align.dx = 60.0);
    assert ((List.nth out 2).Align.dx = 140.0));

  Alcotest.test_case "distribute_vertical_center_with_key_skips_key" `Quick (fun () ->
    let rs = [rect 0.0 0.0 10.0 10.0; rect 0.0 30.0 10.0 10.0;
              rect 0.0 100.0 10.0 10.0] in
    let key = Align.Key_object {
      bbox = Element.geometric_bounds (List.nth rs 1); path = [1] } in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.distribute_vertical_center input key Align.geometric_bounds in
    List.iter (fun t -> assert (t.Align.path <> [1])) out);
]

let spacing_tests = [
  Alcotest.test_case "distribute_spacing_requires_at_least_three" `Quick (fun () ->
    let rs = [rect 0.0 0.0 10.0 10.0; rect 50.0 0.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    assert (Align.distribute_horizontal_spacing input r None Align.geometric_bounds = []));

  Alcotest.test_case "distribute_horizontal_spacing_average" `Quick (fun () ->
    let rs = [rect 0.0 0.0 10.0 10.0; rect 20.0 0.0 10.0 10.0;
              rect 90.0 0.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.distribute_horizontal_spacing input r None Align.geometric_bounds in
    assert (List.length out = 1);
    assert ((List.nth out 0).Align.path = [1]);
    assert ((List.nth out 0).Align.dx = 25.0));

  Alcotest.test_case "distribute_vertical_spacing_average" `Quick (fun () ->
    let rs = [rect 0.0 0.0 10.0 10.0; rect 0.0 20.0 10.0 10.0;
              rect 0.0 90.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.distribute_vertical_spacing input r None Align.geometric_bounds in
    assert (List.length out = 1);
    assert ((List.nth out 0).Align.path = [1]);
    assert ((List.nth out 0).Align.dy = 25.0));

  Alcotest.test_case "distribute_spacing_explicit_without_key_empty" `Quick (fun () ->
    let rs = [rect 0.0 0.0 10.0 10.0; rect 50.0 0.0 10.0 10.0;
              rect 100.0 0.0 10.0 10.0] in
    let r = ref_of rs in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.distribute_horizontal_spacing input r (Some 12.0) Align.geometric_bounds in
    assert (out = []));

  Alcotest.test_case "distribute_horizontal_spacing_explicit_applies" `Quick (fun () ->
    let rs = [rect 0.0 0.0 10.0 10.0; rect 100.0 0.0 10.0 10.0;
              rect 200.0 0.0 10.0 10.0] in
    let key = Align.Key_object {
      bbox = Element.geometric_bounds (List.nth rs 1); path = [1] } in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.distribute_horizontal_spacing input key (Some 20.0) Align.geometric_bounds in
    assert (List.length out = 2);
    assert ((List.nth out 0).Align.path = [0] && (List.nth out 0).Align.dx = 70.0);
    assert ((List.nth out 1).Align.path = [2] && (List.nth out 1).Align.dx = -70.0));

  Alcotest.test_case "distribute_spacing_explicit_zero_gap" `Quick (fun () ->
    let rs = [rect 0.0 0.0 10.0 10.0; rect 100.0 0.0 10.0 10.0;
              rect 200.0 0.0 10.0 10.0] in
    let key = Align.Key_object {
      bbox = Element.geometric_bounds (List.nth rs 1); path = [1] } in
    let input = List.mapi (fun i e -> pair [i] e) rs in
    let out = Align.distribute_horizontal_spacing input key (Some 0.0) Align.geometric_bounds in
    assert (List.length out = 2);
    assert ((List.nth out 0).Align.dx = 90.0);
    assert ((List.nth out 1).Align.dx = -90.0));
]

let () =
  Alcotest.run "align" [
    "primitives", tests;
    "align_ops", op_tests;
    "distribute_ops", dist_tests;
    "distribute_spacing_ops", spacing_tests;
  ]
