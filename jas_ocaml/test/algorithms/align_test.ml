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

let () =
  Alcotest.run "align" [ "primitives", tests ]
