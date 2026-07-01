(* Equivalence vectors shared with the Rust reference
   (jas_dioxus/src/algorithms/bristle_stroke.rs) and the Swift port: width 4,
   density 25 -> two bristles at ±2 along a straight horizontal path. *)

let brush () : Jas.Bristle_stroke.t =
  Jas.Bristle_stroke.{
    size = 4.0;
    density = 25.0;
    thickness = 30.0;
    opacity = 30.0;
    stroke_weight = 1.0;
  }

let close (ax, ay) (bx, by) =
  Float.abs (ax -. bx) < 1e-6 && Float.abs (ay -. by) < 1e-6

let test_two_bristles () =
  let cmds = [ Jas.Element.MoveTo (0.0, 0.0); Jas.Element.LineTo (100.0, 0.0) ] in
  let out = Jas.Bristle_stroke.stroke cmds (brush ()) in
  Alcotest.(check int) "two bristles" 2 (List.length out);
  let b0 = Array.of_list (List.nth out 0) in
  let b1 = Array.of_list (List.nth out 1) in
  Alcotest.(check bool) "b0 start" true (close b0.(0) (0.0, -2.0));
  Alcotest.(check bool) "b0 end" true (close b0.(1) (100.0, -2.0));
  Alcotest.(check bool) "b1 start" true (close b1.(0) (0.0, 2.0));
  Alcotest.(check bool) "b1 end" true (close b1.(1) (100.0, 2.0))

let test_count_alpha () =
  Alcotest.(check int) "count" 2 (Jas.Bristle_stroke.count (brush ()));
  Alcotest.(check bool) "alpha" true
    (Float.abs (Jas.Bristle_stroke.alpha (brush ()) -. 0.3) < 1e-9)

let () =
  Alcotest.run "BristleStroke"
    [
      ( "stroke",
        [
          Alcotest.test_case "two bristles" `Quick test_two_bristles;
          Alcotest.test_case "count/alpha" `Quick test_count_alpha;
        ] );
    ]
