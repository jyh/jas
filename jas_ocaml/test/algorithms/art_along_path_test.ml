(* Equivalence vectors shared with the Rust reference
   (jas_dioxus/src/algorithms/art_along_path.rs) and the Swift port: a
   tapered lens (rhombus) warped along a straight horizontal path. *)

let brush () : Jas.Art_along_path.t =
  Jas.Art_along_path.{
    artwork_width = 100.0;
    artwork_height = 20.0;
    artwork = [ [ (0.0, 10.0); (50.0, 0.0); (100.0, 10.0); (50.0, 20.0) ] ];
    scale = 100.0;
    flip_across = false;
    flip_along = false;
    stroke_weight = 2.0;
  }

let close (ax, ay) (bx, by) =
  Float.abs (ax -. bx) < 1e-6 && Float.abs (ay -. by) < 1e-6

let test_straight () =
  let cmds = [ Jas.Element.MoveTo (0.0, 0.0); Jas.Element.LineTo (100.0, 0.0) ] in
  let out = Jas.Art_along_path.warp cmds (brush ()) in
  Alcotest.(check int) "one polygon" 1 (List.length out);
  let a = Array.of_list (List.hd out) in
  Alcotest.(check int) "4 points" 4 (Array.length a);
  Alcotest.(check bool) "start on path" true (close a.(0) (0.0, 0.0));
  Alcotest.(check bool) "mid-top offset -1" true (close a.(1) (50.0, -1.0));
  Alcotest.(check bool) "end on path" true (close a.(2) (100.0, 0.0));
  Alcotest.(check bool) "mid-bottom offset +1" true (close a.(3) (50.0, 1.0))

let test_degenerate () =
  let out = Jas.Art_along_path.warp [ Jas.Element.MoveTo (0.0, 0.0) ] (brush ()) in
  Alcotest.(check bool) "empty" true (out = [])

let test_flip_across () =
  let b = Jas.Art_along_path.{ (brush ()) with flip_across = true } in
  let cmds = [ Jas.Element.MoveTo (0.0, 0.0); Jas.Element.LineTo (100.0, 0.0) ] in
  let a = Array.of_list (List.hd (Jas.Art_along_path.warp cmds b)) in
  let _, y = a.(1) in
  Alcotest.(check bool) "flipped mid +1" true (Float.abs (y -. 1.0) < 1e-6)

let () =
  Alcotest.run "ArtAlongPath"
    [
      ( "warp",
        [
          Alcotest.test_case "straight ribbon" `Quick test_straight;
          Alcotest.test_case "degenerate" `Quick test_degenerate;
          Alcotest.test_case "flip_across" `Quick test_flip_across;
        ] );
    ]
