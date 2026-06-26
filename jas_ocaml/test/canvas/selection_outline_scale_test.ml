(* Tests for [Canvas_subwindow.selection_outline_scale].

   The selection OUTLINE trace and the bezier/tangent handles are drawn
   UNDER the element transform with FIXED pen widths / circle radii, so
   scaling an element thickens them. The fix divides those fixed widths /
   radii by [selection_outline_scale doc path], the combined transform
   SCALE = the geometric mean of the linear part, [sqrt(|det|)], where
   [det = a*.d -. b*.c], multiplied over the element's own transform and
   every ancestor (group/layer) transform. Returns [1.0] when there is no
   transform. Mirrors the Python SelectionOutlineScaleTest:
     identity -> 1.0; uniform 2x -> 2.0; non-uniform det 16 -> 4.0. *)

module CS = Jas.Canvas_subwindow
module Doc = Jas.Document
module E = Jas.Element

let () = ignore (GMain.init ())

(* Build a document with [elem] as the single child of a single layer,
   with that element fully selected at path [0; 0]. *)
let doc_with elem =
  let layer = E.make_layer ~name:"L0" [| elem |] in
  let selection =
    Doc.PathMap.add [0; 0]
      (Doc.element_selection_all [0; 0])
      Doc.PathMap.empty
  in
  Doc.make_document ~selection [| layer |]

let tests = [
  (* (a) Identity / no transform -> scale 1.0. *)
  Alcotest.test_case "identity scale is one" `Quick (fun () ->
      let rect = E.make_rect 0.0 0.0 10.0 10.0 in
      Alcotest.(check (float 1e-9)) "identity"
        1.0 (CS.selection_outline_scale (doc_with rect) [0; 0]));

  (* (b) Uniform 2x scale -> det 4 -> sqrt 2.0. *)
  Alcotest.test_case "uniform 2x scale" `Quick (fun () ->
      let t : E.transform =
        { a = 2.0; b = 0.0; c = 0.0; d = 2.0; e = 0.0; f = 0.0 }
      in
      let rect = E.make_rect ~transform:(Some t) 0.0 0.0 10.0 10.0 in
      Alcotest.(check (float 1e-9)) "uniform 2x"
        2.0 (CS.selection_outline_scale (doc_with rect) [0; 0]));

  (* (c) Non-uniform scale: det = 2 *. 8 = 16 -> sqrt 4.0 (geometric mean). *)
  Alcotest.test_case "nonuniform geometric mean" `Quick (fun () ->
      let t : E.transform =
        { a = 2.0; b = 0.0; c = 0.0; d = 8.0; e = 0.0; f = 0.0 }
      in
      let rect = E.make_rect ~transform:(Some t) 0.0 0.0 10.0 10.0 in
      Alcotest.(check (float 1e-9)) "nonuniform det 16"
        4.0 (CS.selection_outline_scale (doc_with rect) [0; 0]));
]

let () =
  Alcotest.run "selection_outline_scale"
    [ ("selection_outline_scale", tests) ]
