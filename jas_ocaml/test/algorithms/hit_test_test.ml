(** Hit test primitives. Mirrors jas_dioxus/src/algorithms/hit_test.rs. *)

open Jas.Hit_test

let pass = ref 0
let fail = ref 0
let run name f =
  try f (); incr pass; Printf.printf "  PASS: %s\n" name
  with e -> incr fail; Printf.printf "  FAIL: %s — %s\n" name (Printexc.to_string e)

let make_line ?(x1=0.0) ?(y1=0.0) ?(x2=10.0) ?(y2=10.0) () : Jas.Element.element =
  Jas.Element.Line {
    x1; y1; x2; y2;
    stroke = None;
    opacity = 1.0; transform = None; locked = false; visibility = Preview;
  }

let make_rect ?(x=0.0) ?(y=0.0) ?(width=10.0) ?(height=10.0) () : Jas.Element.element =
  Jas.Element.Rect {
    x; y; width; height; rx = 0.0; ry = 0.0;
    fill = None; stroke = None;
    opacity = 1.0; transform = None; locked = false; visibility = Preview;
  }

let () =
  Printf.printf "Hit test tests:\n";

  (* point_in_rect *)

  run "point_in_rect interior" (fun () ->
    assert (point_in_rect 5.0 5.0 0.0 0.0 10.0 10.0));

  run "point_in_rect outside" (fun () ->
    assert (not (point_in_rect 15.0 5.0 0.0 0.0 10.0 10.0));
    assert (not (point_in_rect (-1.0) 5.0 0.0 0.0 10.0 10.0));
    assert (not (point_in_rect 5.0 15.0 0.0 0.0 10.0 10.0));
    assert (not (point_in_rect 5.0 (-1.0) 0.0 0.0 10.0 10.0)));

  run "point_in_rect on edge" (fun () ->
    assert (point_in_rect 0.0 5.0 0.0 0.0 10.0 10.0);
    assert (point_in_rect 10.0 5.0 0.0 0.0 10.0 10.0);
    assert (point_in_rect 5.0 0.0 0.0 0.0 10.0 10.0);
    assert (point_in_rect 5.0 10.0 0.0 0.0 10.0 10.0));

  run "point_in_rect on corner" (fun () ->
    assert (point_in_rect 0.0 0.0 0.0 0.0 10.0 10.0);
    assert (point_in_rect 10.0 10.0 0.0 0.0 10.0 10.0));

  (* segments_intersect *)

  run "segments_intersect crossing" (fun () ->
    assert (segments_intersect 0.0 0.0 10.0 10.0 0.0 10.0 10.0 0.0));

  run "segments_intersect parallel no" (fun () ->
    assert (not (segments_intersect 0.0 0.0 10.0 0.0 0.0 1.0 10.0 1.0)));

  run "segments_intersect separate" (fun () ->
    assert (not (segments_intersect 0.0 0.0 1.0 1.0 5.0 5.0 6.0 6.0)));

  run "segments_intersect touching at endpoint" (fun () ->
    assert (segments_intersect 0.0 0.0 5.0 5.0 5.0 5.0 10.0 10.0));

  run "segments_intersect t-intersection" (fun () ->
    assert (segments_intersect 0.0 5.0 10.0 5.0 5.0 5.0 5.0 0.0));

  (* segment_intersects_rect *)

  run "segment inside rect" (fun () ->
    assert (segment_intersects_rect 2.0 2.0 8.0 8.0 0.0 0.0 10.0 10.0));

  run "segment outside rect" (fun () ->
    assert (not (segment_intersects_rect 20.0 0.0 30.0 0.0 0.0 0.0 10.0 10.0)));

  run "segment crosses rect" (fun () ->
    assert (segment_intersects_rect (-5.0) 5.0 15.0 5.0 0.0 0.0 10.0 10.0));

  run "segment one endpoint inside" (fun () ->
    assert (segment_intersects_rect 5.0 5.0 20.0 20.0 0.0 0.0 10.0 10.0));

  run "segment endpoint on edge" (fun () ->
    assert (segment_intersects_rect 10.0 5.0 20.0 5.0 0.0 0.0 10.0 10.0));

  (* rects_intersect *)

  run "rects_intersect overlapping" (fun () ->
    assert (rects_intersect 0.0 0.0 10.0 10.0 5.0 5.0 10.0 10.0));

  run "rects_intersect separate" (fun () ->
    assert (not (rects_intersect 0.0 0.0 10.0 10.0 20.0 0.0 10.0 10.0)));

  run "rects_intersect contained" (fun () ->
    assert (rects_intersect 0.0 0.0 100.0 100.0 25.0 25.0 50.0 50.0));

  run "rects_intersect edge touching" (fun () ->
    assert (not (rects_intersect 0.0 0.0 10.0 10.0 10.0 0.0 10.0 10.0)));

  run "rects_intersect corner touching" (fun () ->
    assert (not (rects_intersect 0.0 0.0 10.0 10.0 10.0 10.0 10.0 10.0)));

  run "rects_intersect identical" (fun () ->
    assert (rects_intersect 0.0 0.0 10.0 10.0 0.0 0.0 10.0 10.0));

  (* element_intersects_rect *)

  run "line element overlapping rect" (fun () ->
    let line = make_line ~x1:(-5.0) ~y1:5.0 ~x2:15.0 ~y2:5.0 () in
    assert (element_intersects_rect line 0.0 0.0 10.0 10.0));

  run "line element outside rect" (fun () ->
    let line = make_line ~x1:20.0 ~y1:0.0 ~x2:30.0 ~y2:0.0 () in
    assert (not (element_intersects_rect line 0.0 0.0 10.0 10.0)));

  run "rect element overlapping rect" (fun () ->
    let rect = make_rect ~x:5.0 ~y:5.0 ~width:10.0 ~height:10.0 () in
    assert (element_intersects_rect rect 0.0 0.0 10.0 10.0));

  run "rect element outside rect" (fun () ->
    let rect = make_rect ~x:20.0 ~y:20.0 ~width:5.0 ~height:5.0 () in
    assert (not (element_intersects_rect rect 0.0 0.0 10.0 10.0)));

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
