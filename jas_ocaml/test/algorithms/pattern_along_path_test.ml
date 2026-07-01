(* Equivalence vectors shared with the Rust reference
   (jas_dioxus/src/algorithms/pattern_along_path.rs) and the Swift port: a
   diamond side tile tiled twice along a straight 100-long path. *)

let brush () : Jas.Pattern_along_path.t =
  Jas.Pattern_along_path.{
    tile_width = 100.0;
    tile_height = 20.0;
    side = [ [ (0.0, 10.0); (50.0, 0.0); (100.0, 10.0); (50.0, 20.0) ] ];
    scale = 100.0;
    spacing = 0.0;
    flip_across = false;
    flip_along = false;
    stroke_weight = 10.0;
  }

let close (ax, ay) (bx, by) =
  Float.abs (ax -. bx) < 1e-6 && Float.abs (ay -. by) < 1e-6

let test_two_tiles () =
  let cmds = [ Jas.Element.MoveTo (0.0, 0.0); Jas.Element.LineTo (100.0, 0.0) ] in
  let out = Jas.Pattern_along_path.tile cmds (brush ()) in
  Alcotest.(check int) "two tiles" 2 (List.length out);
  let t0 = Array.of_list (List.nth out 0) in
  let t1 = Array.of_list (List.nth out 1) in
  Alcotest.(check bool) "t0 start" true (close t0.(0) (0.0, 0.0));
  Alcotest.(check bool) "t0 mid-top" true (close t0.(1) (25.0, -5.0));
  Alcotest.(check bool) "t0 end" true (close t0.(2) (50.0, 0.0));
  Alcotest.(check bool) "t1 start" true (close t1.(0) (50.0, 0.0));
  Alcotest.(check bool) "t1 end" true (close t1.(2) (100.0, 0.0))

let test_degenerate () =
  let out = Jas.Pattern_along_path.tile [ Jas.Element.MoveTo (0.0, 0.0) ] (brush ()) in
  Alcotest.(check bool) "empty" true (out = [])

let () =
  Alcotest.run "PatternAlongPath"
    [
      ( "tile",
        [
          Alcotest.test_case "two tiles" `Quick test_two_tiles;
          Alcotest.test_case "degenerate" `Quick test_degenerate;
        ] );
    ]
