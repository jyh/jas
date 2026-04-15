(** Hit test primitives. Mirrors jas_dioxus/src/algorithms/hit_test.rs. *)

open Jas.Hit_test

let make_line ?(x1=0.0) ?(y1=0.0) ?(x2=10.0) ?(y2=10.0) () : Jas.Element.element =
  Jas.Element.make_line x1 y1 x2 y2

let make_rect ?(x=0.0) ?(y=0.0) ?(width=10.0) ?(height=10.0) () : Jas.Element.element =
  Jas.Element.Rect {
    x; y; width; height; rx = 0.0; ry = 0.0;
    fill = None; stroke = None;
    opacity = 1.0; transform = None; locked = false; visibility = Preview;
  }

let () =
  Alcotest.run "HitTest" [
    "point_in_rect", [
      Alcotest.test_case "interior" `Quick (fun () ->
        assert (point_in_rect 5.0 5.0 0.0 0.0 10.0 10.0));

      Alcotest.test_case "outside" `Quick (fun () ->
        assert (not (point_in_rect 15.0 5.0 0.0 0.0 10.0 10.0));
        assert (not (point_in_rect (-1.0) 5.0 0.0 0.0 10.0 10.0));
        assert (not (point_in_rect 5.0 15.0 0.0 0.0 10.0 10.0));
        assert (not (point_in_rect 5.0 (-1.0) 0.0 0.0 10.0 10.0)));

      Alcotest.test_case "on edge" `Quick (fun () ->
        assert (point_in_rect 0.0 5.0 0.0 0.0 10.0 10.0);
        assert (point_in_rect 10.0 5.0 0.0 0.0 10.0 10.0);
        assert (point_in_rect 5.0 0.0 0.0 0.0 10.0 10.0);
        assert (point_in_rect 5.0 10.0 0.0 0.0 10.0 10.0));

      Alcotest.test_case "on corner" `Quick (fun () ->
        assert (point_in_rect 0.0 0.0 0.0 0.0 10.0 10.0);
        assert (point_in_rect 10.0 10.0 0.0 0.0 10.0 10.0));
    ];

    "segments_intersect", [
      Alcotest.test_case "crossing" `Quick (fun () ->
        assert (segments_intersect 0.0 0.0 10.0 10.0 0.0 10.0 10.0 0.0));

      Alcotest.test_case "parallel no" `Quick (fun () ->
        assert (not (segments_intersect 0.0 0.0 10.0 0.0 0.0 1.0 10.0 1.0)));

      Alcotest.test_case "separate" `Quick (fun () ->
        assert (not (segments_intersect 0.0 0.0 1.0 1.0 5.0 5.0 6.0 6.0)));

      Alcotest.test_case "touching at endpoint" `Quick (fun () ->
        assert (segments_intersect 0.0 0.0 5.0 5.0 5.0 5.0 10.0 10.0));

      Alcotest.test_case "t-intersection" `Quick (fun () ->
        assert (segments_intersect 0.0 5.0 10.0 5.0 5.0 5.0 5.0 0.0));
    ];

    "segment_intersects_rect", [
      Alcotest.test_case "inside rect" `Quick (fun () ->
        assert (segment_intersects_rect 2.0 2.0 8.0 8.0 0.0 0.0 10.0 10.0));

      Alcotest.test_case "outside rect" `Quick (fun () ->
        assert (not (segment_intersects_rect 20.0 0.0 30.0 0.0 0.0 0.0 10.0 10.0)));

      Alcotest.test_case "crosses rect" `Quick (fun () ->
        assert (segment_intersects_rect (-5.0) 5.0 15.0 5.0 0.0 0.0 10.0 10.0));

      Alcotest.test_case "one endpoint inside" `Quick (fun () ->
        assert (segment_intersects_rect 5.0 5.0 20.0 20.0 0.0 0.0 10.0 10.0));

      Alcotest.test_case "endpoint on edge" `Quick (fun () ->
        assert (segment_intersects_rect 10.0 5.0 20.0 5.0 0.0 0.0 10.0 10.0));
    ];

    "rects_intersect", [
      Alcotest.test_case "overlapping" `Quick (fun () ->
        assert (rects_intersect 0.0 0.0 10.0 10.0 5.0 5.0 10.0 10.0));

      Alcotest.test_case "separate" `Quick (fun () ->
        assert (not (rects_intersect 0.0 0.0 10.0 10.0 20.0 0.0 10.0 10.0)));

      Alcotest.test_case "contained" `Quick (fun () ->
        assert (rects_intersect 0.0 0.0 100.0 100.0 25.0 25.0 50.0 50.0));

      Alcotest.test_case "edge touching" `Quick (fun () ->
        assert (not (rects_intersect 0.0 0.0 10.0 10.0 10.0 0.0 10.0 10.0)));

      Alcotest.test_case "corner touching" `Quick (fun () ->
        assert (not (rects_intersect 0.0 0.0 10.0 10.0 10.0 10.0 10.0 10.0)));

      Alcotest.test_case "identical" `Quick (fun () ->
        assert (rects_intersect 0.0 0.0 10.0 10.0 0.0 0.0 10.0 10.0));
    ];

    "element_intersects_rect", [
      Alcotest.test_case "line element overlapping rect" `Quick (fun () ->
        let line = make_line ~x1:(-5.0) ~y1:5.0 ~x2:15.0 ~y2:5.0 () in
        assert (element_intersects_rect line 0.0 0.0 10.0 10.0));

      Alcotest.test_case "line element outside rect" `Quick (fun () ->
        let line = make_line ~x1:20.0 ~y1:0.0 ~x2:30.0 ~y2:0.0 () in
        assert (not (element_intersects_rect line 0.0 0.0 10.0 10.0)));

      Alcotest.test_case "rect element overlapping rect" `Quick (fun () ->
        let rect = make_rect ~x:5.0 ~y:5.0 ~width:10.0 ~height:10.0 () in
        assert (element_intersects_rect rect 0.0 0.0 10.0 10.0));

      Alcotest.test_case "rect element outside rect" `Quick (fun () ->
        let rect = make_rect ~x:20.0 ~y:20.0 ~width:5.0 ~height:5.0 () in
        assert (not (element_intersects_rect rect 0.0 0.0 10.0 10.0)));
    ];

    "transform-aware hit-testing", [
      Alcotest.test_case "translated_line_intersects_rect" `Quick (fun () ->
        let line = Jas.Element.make_line ~transform:(Some (Jas.Element.make_translate 100.0 0.0)) 0.0 5.0 10.0 5.0 in
        assert (element_intersects_rect line 95.0 0.0 20.0 10.0);
        assert (not (element_intersects_rect line 0.0 0.0 10.0 10.0)));

      Alcotest.test_case "rotated_rect_intersects_rect" `Quick (fun () ->
        let fill = Some (Jas.Element.make_fill (Jas.Element.make_color 0.0 0.0 0.0)) in
        let rect = Jas.Element.make_rect ~fill ~transform:(Some (Jas.Element.make_rotate 45.0)) 0.0 0.0 10.0 10.0 in
        assert (element_intersects_rect rect 6.0 6.0 2.0 2.0);
        assert (not (element_intersects_rect rect 12.0 0.0 2.0 2.0)));

      Alcotest.test_case "scaled_line_intersects_rect" `Quick (fun () ->
        let line = Jas.Element.make_line ~transform:(Some (Jas.Element.make_scale 2.0 2.0)) 0.0 0.0 5.0 0.0 in
        assert (element_intersects_rect line 8.0 (-1.0) 4.0 2.0);
        assert (element_intersects_rect line 6.0 (-1.0) 2.0 2.0));

      Alcotest.test_case "singular_transform_returns_false" `Quick (fun () ->
        let line = Jas.Element.make_line ~transform:(Some (Jas.Element.make_scale 0.0 0.0)) 0.0 0.0 10.0 0.0 in
        assert (not (element_intersects_rect line 0.0 0.0 10.0 10.0)));

      Alcotest.test_case "no_transform_still_works" `Quick (fun () ->
        let line = Jas.Element.make_line 0.0 5.0 10.0 5.0 in
        assert (element_intersects_rect line 0.0 0.0 10.0 10.0);
        assert (not (element_intersects_rect line 20.0 0.0 10.0 10.0)));

      Alcotest.test_case "translated_line_intersects_polygon" `Quick (fun () ->
        let line = Jas.Element.make_line ~transform:(Some (Jas.Element.make_translate 100.0 0.0)) 0.0 5.0 10.0 5.0 in
        let sq = [| (95.0, 0.0); (115.0, 0.0); (115.0, 10.0); (95.0, 10.0) |] in
        assert (element_intersects_polygon line sq);
        let sq2 = [| (0.0, 0.0); (10.0, 0.0); (10.0, 10.0); (0.0, 10.0) |] in
        assert (not (element_intersects_polygon line sq2)));
    ];
  ]
