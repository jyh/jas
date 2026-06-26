(* Tests for [Canvas_subwindow.transform_scale_factor] and
   [Canvas_subwindow.counter_scaled_element].

   An element's own STROKE is drawn UNDER the element transform, so the
   matrix would scale the stroke width — on top of the [scale_strokes] bake
   that already multiplies the stored width by [sqrt(|sx*sy|)] at apply time.
   That is a DOUBLE-scale: a 1pt stroke scaled f x rendered at f^2 pt.

   The render-only fix threads an accumulated [element_scale] through the
   element-draw recursion. At each element [counter_scaled_element elem
   element_scale] returns [(elem_with_divided_stroke, accumulated_scale)],
   where [accumulated_scale = element_scale *. transform_scale_factor
   elem_own_transform] and the returned element has its stroke width divided
   by that scale, so the element transform never thickens the stroke (it
   still scales with ZOOM, which is applied separately). The accumulated
   scale threads to children so a stroked shape inside a transformed group is
   counter-scaled by the full ancestor chain.

   [transform_scale_factor t] is the per-transform geometric-mean scale —
   [sqrt(|det|)] with [det = a*.d -. b*.c], 1.0 for [None] or a degenerate
   (det 0) transform. Mirrors the Python ElementStrokeCounterScaleTest:
     transform_scale_factor None -> 1.0; uniform 2x -> 2.0; det 16 -> 4.0;
     a stroked rect (width 4) with a 2x transform -> stroke width 2.0;
     no transform -> unchanged; nested parent 3x + own 2x (width 12) -> 2.0. *)

module CS = Jas.Canvas_subwindow
module E = Jas.Element

let () = ignore (GMain.init ())

(* Read the stroke width off an element, failing the test if absent. *)
let stroke_width_of (elem : E.element) : float =
  match elem with
  | E.Rect { stroke = Some s; _ } -> s.E.stroke_width
  | _ -> Alcotest.fail "expected a Rect with a stroke"

let scaled_rect ?transform width =
  let stroke = E.make_stroke ~width E.black in
  E.make_rect ?transform ~stroke:(Some stroke) 0.0 0.0 100.0 100.0

let tests = [
  (* (a) transform_scale_factor: None / 2x / det 16. *)
  Alcotest.test_case "transform_scale_factor none is one" `Quick (fun () ->
      Alcotest.(check (float 1e-9)) "none"
        1.0 (CS.transform_scale_factor None));

  Alcotest.test_case "transform_scale_factor uniform 2x" `Quick (fun () ->
      let t : E.transform =
        { a = 2.0; b = 0.0; c = 0.0; d = 2.0; e = 0.0; f = 0.0 } in
      Alcotest.(check (float 1e-9)) "2x"
        2.0 (CS.transform_scale_factor (Some t)));

  Alcotest.test_case "transform_scale_factor det 16" `Quick (fun () ->
      (* det = 2 *. 8 = 16 -> sqrt = 4. *)
      let t : E.transform =
        { a = 2.0; b = 0.0; c = 0.0; d = 8.0; e = 0.0; f = 0.0 } in
      Alcotest.(check (float 1e-9)) "det 16"
        4.0 (CS.transform_scale_factor (Some t)));

  (* (b) Stroked rect (width 4) with a 2x transform -> effective width 2.0. *)
  Alcotest.test_case "stroke divided by element scale" `Quick (fun () ->
      let t : E.transform =
        { a = 2.0; b = 0.0; c = 0.0; d = 2.0; e = 0.0; f = 0.0 } in
      let rect = scaled_rect ~transform:(Some t) 4.0 in
      let (out, scale) = CS.counter_scaled_element rect 1.0 in
      Alcotest.(check (float 1e-9)) "scale" 2.0 scale;
      Alcotest.(check (float 1e-9)) "width 4/2" 2.0 (stroke_width_of out));

  (* (c) No transform -> stroke unchanged, scale 1.0. *)
  Alcotest.test_case "no transform unchanged" `Quick (fun () ->
      let rect = scaled_rect 4.0 in
      let (out, scale) = CS.counter_scaled_element rect 1.0 in
      Alcotest.(check (float 1e-9)) "scale" 1.0 scale;
      Alcotest.(check (float 1e-9)) "width unchanged" 4.0 (stroke_width_of out));

  (* (d) Nested: own 2x inside a parent already at 3x, width 12 -> 12/6 = 2. *)
  Alcotest.test_case "accumulates with parent scale" `Quick (fun () ->
      let t : E.transform =
        { a = 2.0; b = 0.0; c = 0.0; d = 2.0; e = 0.0; f = 0.0 } in
      let rect = scaled_rect ~transform:(Some t) 12.0 in
      let (out, scale) = CS.counter_scaled_element rect 3.0 in
      Alcotest.(check (float 1e-9)) "scale 3*2" 6.0 scale;
      Alcotest.(check (float 1e-9)) "width 12/6" 2.0 (stroke_width_of out));
]

let () =
  Alcotest.run "element_stroke_counter_scale"
    [ ("element_stroke_counter_scale", tests) ]
