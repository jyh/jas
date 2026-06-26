(* Tests for [Canvas_subwindow.selection_handle_rects].

   The selection control-point handles must be FIXED SIZE: an element's
   transform MOVES the handle positions but never SCALES the handle
   glyphs. [selection_handle_rects doc path] returns document-space
   rects (x, y, w, h) whose CENTER is the element-transformed control
   point and whose SIZE is the constant [handle_size] (NOT multiplied by
   the element transform). Mirrors the Python SelectionHandleRectsTest. *)

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

(* Centers of the returned rects, sorted, for order-independent compare. *)
let centers_of rects =
  let half = CS.handle_size /. 2.0 in
  List.map (fun (x, y, _w, _h) -> (x +. half, y +. half)) rects
  |> List.sort compare

let pf = Printf.sprintf

let check_centers name expected rects =
  let got = centers_of rects in
  let to_s l =
    String.concat "; " (List.map (fun (x, y) -> pf "(%g,%g)" x y) l)
  in
  Alcotest.(check string) (name ^ " centers")
    (to_s (List.sort compare expected)) (to_s got)

let check_all_fixed_size name rects =
  List.iter (fun (_x, _y, w, h) ->
    Alcotest.(check (float 1e-9)) (name ^ " width = handle_size")
      CS.handle_size w;
    Alcotest.(check (float 1e-9)) (name ^ " height = handle_size")
      CS.handle_size h)
    rects

let tests = [
  (* (a) Identity transform: handles sit on the raw control points and
     each rect is exactly [handle_size]. *)
  Alcotest.test_case "identity transform handles at control points" `Quick
    (fun () ->
      let rect = E.make_rect 10.0 20.0 30.0 40.0 in
      let rects = CS.selection_handle_rects (doc_with rect) [0; 0] in
      Alcotest.(check int) "four handles" 4 (List.length rects);
      check_centers "identity"
        [(10., 20.); (40., 20.); (40., 60.); (10., 60.)] rects;
      check_all_fixed_size "identity" rects);

  (* (b) 100x100 rect at origin with a 2x scale transform: the handle
     CENTERS are the transformed corners (0,0),(200,0),(200,200),(0,200)
     but each rect is still [handle_size] — NOT 2x. *)
  Alcotest.test_case "scaled element handles move but do not grow" `Quick
    (fun () ->
      let t : E.transform =
        { a = 2.0; b = 0.0; c = 0.0; d = 2.0; e = 0.0; f = 0.0 }
      in
      let rect = E.make_rect ~transform:(Some t) 0.0 0.0 100.0 100.0 in
      let rects = CS.selection_handle_rects (doc_with rect) [0; 0] in
      Alcotest.(check int) "four handles" 4 (List.length rects);
      check_centers "scaled"
        [(0., 0.); (200., 0.); (200., 200.); (0., 200.)] rects;
      check_all_fixed_size "scaled" rects);

  (* (c) A Group carries no control-point squares. *)
  Alcotest.test_case "no handles for group" `Quick (fun () ->
      let inner = E.make_rect 0.0 0.0 10.0 10.0 in
      let grp = E.make_group [| inner |] in
      let rects = CS.selection_handle_rects (doc_with grp) [0; 0] in
      Alcotest.(check int) "no handles" 0 (List.length rects));
]

let () =
  Alcotest.run "selection_handle_rects"
    [ ("selection_handle_rects", tests) ]
