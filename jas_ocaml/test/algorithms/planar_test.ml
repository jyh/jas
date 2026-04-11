(** Planar graph extraction tests. Mirrors the Rust suite at
    jas_dioxus/src/algorithms/planar.rs. *)

open Jas.Planar

let area_eps = 1e-6

let approx_eq a b = abs_float (a -. b) < area_eps

let closed_square x y side : polyline =
  [| (x, y);
     (x +. side, y);
     (x +. side, y +. side);
     (x, y +. side);
     (x, y) |]

let segment a b : polyline = [| a; b |]

let total_top_level_area g =
  List.fold_left
    (fun acc f -> acc +. abs_float (face_net_area g f))
    0.0 (top_level_faces g)

let check name cond =
  if not cond then failwith ("FAIL: " ^ name)

(* ----- 1. Two crossing segments ----- *)
let test_two_crossing_segments_have_no_bounded_faces () =
  let g = build [
    segment (-1.0, 0.0) (1.0, 0.0);
    segment (0.0, -1.0) (0.0, 1.0);
  ] in
  check "two_crossing.face_count" (face_count g = 0)

(* ----- 2. Closed square ----- *)
let test_closed_square_is_one_face () =
  let g = build [closed_square 0.0 0.0 10.0] in
  check "closed_square.face_count" (face_count g = 1);
  check "closed_square.area" (approx_eq (total_top_level_area g) 100.0)

(* ----- 3. Square with one diagonal ----- *)
let test_square_with_one_diagonal () =
  let g = build [
    closed_square 0.0 0.0 10.0;
    segment (0.0, 0.0) (10.0, 10.0);
  ] in
  check "one_diag.face_count" (face_count g = 2);
  check "one_diag.area" (approx_eq (total_top_level_area g) 100.0);
  List.iter (fun f ->
    check "one_diag.tri_area" (approx_eq (abs_float (face_net_area g f)) 50.0)
  ) (top_level_faces g)

(* ----- 4. Square with both diagonals ----- *)
let test_square_with_both_diagonals () =
  let g = build [
    closed_square 0.0 0.0 10.0;
    segment (0.0, 0.0) (10.0, 10.0);
    segment (10.0, 0.0) (0.0, 10.0);
  ] in
  check "both_diag.face_count" (face_count g = 4);
  check "both_diag.area" (approx_eq (total_top_level_area g) 100.0);
  List.iter (fun f ->
    check "both_diag.tri_area" (approx_eq (abs_float (face_net_area g f)) 25.0)
  ) (top_level_faces g)

(* ----- 5. Two disjoint squares ----- *)
let test_two_disjoint_squares () =
  let g = build [
    closed_square 0.0 0.0 10.0;
    closed_square 20.0 0.0 10.0;
  ] in
  check "disjoint.face_count" (face_count g = 2);
  check "disjoint.area" (approx_eq (total_top_level_area g) 200.0)

(* ----- 6. Two squares sharing an edge ----- *)
let test_two_squares_sharing_an_edge () =
  let g = build [
    closed_square 0.0 0.0 10.0;
    closed_square 10.0 0.0 10.0;
  ] in
  check "shared.face_count" (face_count g = 2);
  check "shared.area" (approx_eq (total_top_level_area g) 200.0)

(* ----- 8. Concentric squares ----- *)
let test_square_with_inner_square () =
  let g = build [
    closed_square 0.0 0.0 20.0;
    closed_square 5.0 5.0 10.0;
  ] in
  check "concentric.face_count" (face_count g = 2);
  let top = top_level_faces g in
  check "concentric.top_count" (List.length top = 1);
  let outer = List.hd top in
  check "concentric.holes_count"
    (List.length g.faces.(outer).holes = 1);
  check "concentric.outer_area"
    (approx_eq (abs_float (face_outer_area g outer)) 400.0);
  check "concentric.net_area"
    (approx_eq (abs_float (face_net_area g outer)) 300.0);
  let inner = ref (-1) in
  for i = 0 to Array.length g.faces - 1 do
    if g.faces.(i).depth = 2 then inner := i
  done;
  check "concentric.inner_found" (!inner >= 0);
  check "concentric.inner_parent" (g.faces.(!inner).parent = Some outer);
  check "concentric.inner_area"
    (approx_eq (abs_float (face_net_area g !inner)) 100.0)

(* ----- 9. Hit test on the diagonal-cross square ----- *)
let test_hit_test_diagonal_quadrants () =
  let g = build [
    closed_square 0.0 0.0 10.0;
    segment (0.0, 0.0) (10.0, 10.0);
    segment (10.0, 0.0) (0.0, 10.0);
  ] in
  let samples = [
    (5.0, 1.0); (9.0, 5.0); (5.0, 9.0); (1.0, 5.0);
  ] in
  let hits = List.map (fun s ->
    match hit_test g s with
    | Some f -> f
    | None -> failwith "expected hit"
  ) samples in
  let unique = List.sort_uniq compare hits in
  check "diag_hit.distinct" (List.length unique = 4)

(* ----- 10. Degenerate inputs ----- *)
let test_empty_input () =
  let g = build [] in
  check "empty.face_count" (face_count g = 0)

let test_zero_length_segment () =
  let g = build [segment (1.0, 1.0) (1.0, 1.0)] in
  check "zero.face_count" (face_count g = 0)

let test_single_point_polyline () =
  let g = build [[| (3.0, 3.0) |]] in
  check "single.face_count" (face_count g = 0)

(* ----- 11. Square with external tail ----- *)
let test_square_with_external_tail () =
  let g = build [
    closed_square 0.0 0.0 10.0;
    segment (10.0, 10.0) (15.0, 15.0);
  ] in
  check "ext_tail.face_count" (face_count g = 1);
  check "ext_tail.area" (approx_eq (total_top_level_area g) 100.0)

(* ----- 12. Square with internal tail ----- *)
let test_square_with_internal_tail () =
  let g = build [
    closed_square 0.0 0.0 10.0;
    segment (0.0, 0.0) (5.0, 5.0);
  ] in
  check "int_tail.face_count" (face_count g = 1);
  check "int_tail.area" (approx_eq (total_top_level_area g) 100.0)

(* ----- 13. Square with branching tree ----- *)
let test_square_with_internal_tree () =
  let g = build [
    closed_square 0.0 0.0 10.0;
    [| (0.0, 0.0); (3.0, 3.0) |];
    [| (3.0, 3.0); (5.0, 3.0) |];
    [| (3.0, 3.0); (3.0, 5.0) |];
    [| (5.0, 3.0); (6.0, 4.0) |];
  ] in
  check "tree.face_count" (face_count g = 1);
  check "tree.area" (approx_eq (total_top_level_area g) 100.0)

(* ----- 14. Isolated open stroke ----- *)
let test_isolated_open_stroke () =
  let g = build [segment (0.0, 0.0) (5.0, 5.0)] in
  check "isolated.face_count" (face_count g = 0)

(* ----- 15. Square with two disjoint holes ----- *)
let test_square_with_two_disjoint_holes () =
  let g = build [
    closed_square 0.0 0.0 30.0;
    closed_square 5.0 5.0 5.0;
    closed_square 20.0 20.0 5.0;
  ] in
  check "two_holes.face_count" (face_count g = 3);
  let top = top_level_faces g in
  check "two_holes.top_count" (List.length top = 1);
  let outer = List.hd top in
  check "two_holes.holes_count"
    (List.length g.faces.(outer).holes = 2);
  check "two_holes.net_area"
    (approx_eq (abs_float (face_net_area g outer)) 850.0)

(* ----- 16. Three-deep nested squares ----- *)
let test_three_deep_nested () =
  let g = build [
    closed_square 0.0 0.0 30.0;
    closed_square 5.0 5.0 20.0;
    closed_square 10.0 10.0 10.0;
  ] in
  check "nested.face_count" (face_count g = 3);
  let by_depth = Array.make 4 [] in
  for i = 0 to Array.length g.faces - 1 do
    let d = g.faces.(i).depth in
    if d >= 1 && d <= 3 then by_depth.(d) <- i :: by_depth.(d)
  done;
  check "nested.depth1" (List.length by_depth.(1) = 1);
  check "nested.depth2" (List.length by_depth.(2) = 1);
  check "nested.depth3" (List.length by_depth.(3) = 1);
  let a = List.hd by_depth.(1) in
  let b = List.hd by_depth.(2) in
  let c = List.hd by_depth.(3) in
  check "nested.b_parent" (g.faces.(b).parent = Some a);
  check "nested.c_parent" (g.faces.(c).parent = Some b);
  check "nested.a_area" (approx_eq (abs_float (face_net_area g a)) 500.0);
  check "nested.b_area" (approx_eq (abs_float (face_net_area g b)) 300.0);
  check "nested.c_area" (approx_eq (abs_float (face_net_area g c)) 100.0)

(* ----- 17. Hit test inside a hole ----- *)
let test_hit_test_in_hole () =
  let g = build [
    closed_square 0.0 0.0 20.0;
    closed_square 5.0 5.0 10.0;
  ] in
  let outer_hit =
    match hit_test g (1.0, 1.0) with
    | Some f -> f
    | None -> failwith "outer expected"
  in
  check "hole_hit.outer_depth" (g.faces.(outer_hit).depth = 1);
  let hole_hit =
    match hit_test g (10.0, 10.0) with
    | Some f -> f
    | None -> failwith "hole expected"
  in
  check "hole_hit.hole_depth" (g.faces.(hole_hit).depth = 2);
  check "hole_hit.hole_parent" (g.faces.(hole_hit).parent = Some outer_hit)

let () =
  Alcotest.run "Planar" [
    "planar", [
      Alcotest.test_case "two_crossing_segments_have_no_bounded_faces" `Quick test_two_crossing_segments_have_no_bounded_faces;
      Alcotest.test_case "closed_square_is_one_face" `Quick test_closed_square_is_one_face;
      Alcotest.test_case "square_with_one_diagonal" `Quick test_square_with_one_diagonal;
      Alcotest.test_case "square_with_both_diagonals" `Quick test_square_with_both_diagonals;
      Alcotest.test_case "two_disjoint_squares" `Quick test_two_disjoint_squares;
      Alcotest.test_case "two_squares_sharing_an_edge" `Quick test_two_squares_sharing_an_edge;
      Alcotest.test_case "square_with_inner_square" `Quick test_square_with_inner_square;
      Alcotest.test_case "hit_test_diagonal_quadrants" `Quick test_hit_test_diagonal_quadrants;
      Alcotest.test_case "empty_input" `Quick test_empty_input;
      Alcotest.test_case "zero_length_segment" `Quick test_zero_length_segment;
      Alcotest.test_case "single_point_polyline" `Quick test_single_point_polyline;
      Alcotest.test_case "square_with_external_tail" `Quick test_square_with_external_tail;
      Alcotest.test_case "square_with_internal_tail" `Quick test_square_with_internal_tail;
      Alcotest.test_case "square_with_internal_tree" `Quick test_square_with_internal_tree;
      Alcotest.test_case "isolated_open_stroke" `Quick test_isolated_open_stroke;
      Alcotest.test_case "square_with_two_disjoint_holes" `Quick test_square_with_two_disjoint_holes;
      Alcotest.test_case "three_deep_nested" `Quick test_three_deep_nested;
      Alcotest.test_case "hit_test_in_hole" `Quick test_hit_test_in_hole;
    ];
  ]
