(** Boolean ops tests. Mirrors the Rust suite at jas_dioxus/src/algorithms/boolean.rs. *)

open Jas.Boolean

let eps = 1e-9
let approx_eq a b = abs_float (a -. b) < eps

let ring_signed_area (ring : ring) =
  let n = Array.length ring in
  if n < 3 then 0.0
  else begin
    let sum = ref 0.0 in
    for i = 0 to n - 1 do
      let (x1, y1) = ring.(i) in
      let (x2, y2) = ring.((i + 1) mod n) in
      sum := !sum +. x1 *. y2 -. x2 *. y1
    done;
    !sum /. 2.0
  end

let point_in_ring (ring : ring) (px, py) =
  let n = Array.length ring in
  if n < 3 then false
  else begin
    let inside = ref false in
    let j = ref (n - 1) in
    for i = 0 to n - 1 do
      let (xi, yi) = ring.(i) in
      let (xj, yj) = ring.(!j) in
      let intersects =
        ((yi > py) <> (yj > py))
        && (px < (xj -. xi) *. (py -. yi) /. (yj -. yi) +. xi)
      in
      if intersects then inside := not !inside;
      j := i
    done;
    !inside
  end

let polygon_set_area (ps : polygon_set) =
  let arr = Array.of_list ps in
  let total = ref 0.0 in
  Array.iteri (fun i ring ->
    let a = abs_float (ring_signed_area ring) in
    let depth = ref 0 in
    if Array.length ring > 0 then begin
      let pt = ring.(0) in
      Array.iteri (fun j other ->
        if i <> j && point_in_ring other pt then incr depth
      ) arr
    end;
    if !depth mod 2 = 0 then total := !total +. a
    else total := !total -. a
  ) arr;
  !total

let point_in_polygon_set (ps : polygon_set) pt =
  let cnt = ref 0 in
  List.iter (fun ring -> if point_in_ring ring pt then incr cnt) ps;
  !cnt mod 2 = 1

let polygon_set_bbox (ps : polygon_set) =
  let min_x = ref infinity in
  let min_y = ref infinity in
  let max_x = ref neg_infinity in
  let max_y = ref neg_infinity in
  let any = ref false in
  List.iter (fun ring ->
    Array.iter (fun (x, y) ->
      if x < !min_x then min_x := x;
      if y < !min_y then min_y := y;
      if x > !max_x then max_x := x;
      if y > !max_y then max_y := y;
      any := true
    ) ring
  ) ps;
  if !any then Some (!min_x, !min_y, !max_x -. !min_x, !max_y -. !min_y)
  else None

let assert_region ?(inside=[]) ?(outside=[]) ?bbox actual expected_area =
  let area = polygon_set_area actual in
  if not (approx_eq area expected_area) then
    failwith (Printf.sprintf "area mismatch: expected %f got %f" expected_area area);
  List.iter (fun pt ->
    if not (point_in_polygon_set actual pt) then
      failwith (Printf.sprintf "point should be inside")
  ) inside;
  List.iter (fun pt ->
    if point_in_polygon_set actual pt then
      failwith (Printf.sprintf "point should be outside")
  ) outside;
  match bbox with
  | None -> ()
  | Some (ex, ey, ew, eh) when expected_area > eps ->
    let act = polygon_set_bbox actual in
    (match act with
     | None -> failwith "non-empty region should have a bbox"
     | Some (ax, ay, aw, ah) ->
       if not (approx_eq ax ex && approx_eq ay ey
               && approx_eq aw ew && approx_eq ah eh) then
         failwith (Printf.sprintf "bbox mismatch: expected (%f,%f,%f,%f) got (%f,%f,%f,%f)"
                     ex ey ew eh ax ay aw ah))
  | _ -> ()

let assert_empty actual =
  let area = List.fold_left (fun s r -> s +. abs_float (ring_signed_area r)) 0.0 actual in
  if area >= eps then failwith (Printf.sprintf "expected empty, got area %f" area)

(* Fixtures *)

let square_a () : polygon_set = [ [|(0.0, 0.0); (10.0, 0.0); (10.0, 10.0); (0.0, 10.0)|] ]
let square_b_overlap () : polygon_set = [ [|(5.0, 5.0); (15.0, 5.0); (15.0, 15.0); (5.0, 15.0)|] ]
let square_disjoint () : polygon_set = [ [|(20.0, 0.0); (30.0, 0.0); (30.0, 10.0); (20.0, 10.0)|] ]
let square_inside () : polygon_set = [ [|(3.0, 3.0); (7.0, 3.0); (7.0, 7.0); (3.0, 7.0)|] ]
let square_edge_touching () : polygon_set = [ [|(10.0, 0.0); (20.0, 0.0); (20.0, 10.0); (10.0, 10.0)|] ]

let bowtie () : polygon_set = [ [|(0.0, 0.0); (10.0, 10.0); (10.0, 0.0); (0.0, 10.0)|] ]

(* Test runner *)

let pass = ref 0
let fail = ref 0

let run name f =
  try
    f ();
    incr pass;
    Printf.printf "  PASS: %s\n" name
  with e ->
    incr fail;
    Printf.printf "  FAIL: %s — %s\n" name (Printexc.to_string e)

(* Trivial cases *)

let () =
  Printf.printf "Boolean tests:\n";

  run "union disjoint squares" (fun () ->
    assert_region (boolean_union (square_a ()) (square_disjoint ())) 200.0
      ~inside:[(5., 5.); (25., 5.)] ~outside:[(15., 5.); (-1., -1.)]);

  run "intersect disjoint is empty" (fun () ->
    assert_empty (boolean_intersect (square_a ()) (square_disjoint ())));

  run "subtract disjoint returns a" (fun () ->
    assert_region (boolean_subtract (square_a ()) (square_disjoint ())) 100.0
      ~inside:[(5., 5.)] ~outside:[(25., 5.)] ~bbox:(0., 0., 10., 10.));

  run "exclude disjoint is union" (fun () ->
    assert_region (boolean_exclude (square_a ()) (square_disjoint ())) 200.0
      ~inside:[(5., 5.); (25., 5.)] ~outside:[(15., 5.)]);

  run "union identical is one" (fun () ->
    assert_region (boolean_union (square_a ()) (square_a ())) 100.0
      ~inside:[(5., 5.)] ~outside:[(11., 11.)] ~bbox:(0., 0., 10., 10.));

  run "intersect identical is the polygon" (fun () ->
    assert_region (boolean_intersect (square_a ()) (square_a ())) 100.0
      ~inside:[(5., 5.)] ~outside:[(11., 11.)] ~bbox:(0., 0., 10., 10.));

  run "subtract identical is empty" (fun () ->
    assert_empty (boolean_subtract (square_a ()) (square_a ())));

  run "exclude identical is empty" (fun () ->
    assert_empty (boolean_exclude (square_a ()) (square_a ())));

  run "union with inner is the outer" (fun () ->
    assert_region (boolean_union (square_a ()) (square_inside ())) 100.0
      ~inside:[(5., 5.); (4., 4.)] ~outside:[(11., 11.)] ~bbox:(0., 0., 10., 10.));

  run "intersect with inner is the inner" (fun () ->
    assert_region (boolean_intersect (square_a ()) (square_inside ())) 16.0
      ~inside:[(5., 5.)] ~outside:[(2., 2.); (8., 8.)] ~bbox:(3., 3., 4., 4.));

  run "subtract inner creates a hole" (fun () ->
    assert_region (boolean_subtract (square_a ()) (square_inside ())) 84.0
      ~inside:[(1., 1.); (9., 9.); (1., 9.); (9., 1.)]
      ~outside:[(5., 5.)] ~bbox:(0., 0., 10., 10.));

  (* Overlapping *)

  run "union overlapping squares" (fun () ->
    assert_region (boolean_union (square_a ()) (square_b_overlap ())) 175.0
      ~inside:[(2., 2.); (12., 12.); (7., 7.)]
      ~outside:[(2., 12.); (12., 2.)] ~bbox:(0., 0., 15., 15.));

  run "intersect overlapping is 5x5 square" (fun () ->
    assert_region (boolean_intersect (square_a ()) (square_b_overlap ())) 25.0
      ~inside:[(7., 7.)] ~outside:[(2., 2.); (12., 12.)] ~bbox:(5., 5., 5., 5.));

  run "subtract overlap leaves L-shape" (fun () ->
    assert_region (boolean_subtract (square_a ()) (square_b_overlap ())) 75.0
      ~inside:[(2., 2.); (2., 8.); (8., 2.)]
      ~outside:[(7., 7.); (12., 12.)] ~bbox:(0., 0., 10., 10.));

  run "exclude overlapping is two L-shapes" (fun () ->
    assert_region (boolean_exclude (square_a ()) (square_b_overlap ())) 150.0
      ~inside:[(2., 2.); (12., 12.)] ~outside:[(7., 7.)] ~bbox:(0., 0., 15., 15.));

  (* Touching *)

  run "union edge touching" (fun () ->
    assert_region (boolean_union (square_a ()) (square_edge_touching ())) 200.0
      ~inside:[(5., 5.); (15., 5.)] ~outside:[(-1., 5.); (25., 5.)]
      ~bbox:(0., 0., 20., 10.));

  run "intersect edge touching empty" (fun () ->
    assert_empty (boolean_intersect (square_a ()) (square_edge_touching ())));

  (* Empty operands *)

  run "union with empty" (fun () ->
    assert_region (boolean_union (square_a ()) []) 100.0
      ~inside:[(5., 5.)] ~outside:[(15., 5.)] ~bbox:(0., 0., 10., 10.));

  run "intersect with empty" (fun () ->
    assert_empty (boolean_intersect (square_a ()) []));

  run "subtract empty from a" (fun () ->
    assert_region (boolean_subtract (square_a ()) []) 100.0
      ~inside:[(5., 5.)] ~bbox:(0., 0., 10., 10.));

  run "subtract a from empty" (fun () ->
    assert_empty (boolean_subtract [] (square_a ())));

  (* Property tests *)

  let property_grid =
    let pts = ref [] in
    for i = -2 to 18 do
      for j = -2 to 18 do
        pts := (float_of_int i +. 0.5, float_of_int j +. 0.5) :: !pts
      done
    done;
    !pts
  in

  let regions_equal p q =
    if not (approx_eq (polygon_set_area p) (polygon_set_area q)) then false
    else if List.exists (fun pt ->
        point_in_polygon_set p pt <> point_in_polygon_set q pt) property_grid then false
    else
      match polygon_set_bbox p, polygon_set_bbox q with
      | None, None -> true
      | Some _, None | None, Some _ -> false
      | Some (a1, a2, a3, a4), Some (b1, b2, b3, b4) ->
        approx_eq a1 b1 && approx_eq a2 b2 && approx_eq a3 b3 && approx_eq a4 b4
  in

  run "union commutative overlapping" (fun () ->
    let a = square_a () in let b = square_b_overlap () in
    assert (regions_equal (boolean_union a b) (boolean_union b a)));

  run "intersect commutative overlapping" (fun () ->
    let a = square_a () in let b = square_b_overlap () in
    assert (regions_equal (boolean_intersect a b) (boolean_intersect b a)));

  run "exclude commutative overlapping" (fun () ->
    let a = square_a () in let b = square_b_overlap () in
    assert (regions_equal (boolean_exclude a b) (boolean_exclude b a)));

  run "decomposition (a-b) ∪ (a∩b) = a" (fun () ->
    let a = square_a () in let b = square_b_overlap () in
    let lhs = boolean_union (boolean_subtract a b) (boolean_intersect a b) in
    assert (regions_equal lhs a));

  run "exclude involution (a⊕b)⊕b = a" (fun () ->
    let a = square_a () in let b = square_b_overlap () in
    let result = boolean_exclude (boolean_exclude a b) b in
    assert (regions_equal result a));

  (* Associativity *)

  let venn_a () : polygon_set = [ [|(0., 0.); (10., 0.); (10., 10.); (0., 10.)|] ] in
  let venn_b () : polygon_set = [ [|(6., 0.); (16., 0.); (16., 10.); (6., 10.)|] ] in
  let venn_c () : polygon_set = [ [|(3., 6.); (13., 6.); (13., 16.); (3., 16.)|] ] in

  run "union associative three squares" (fun () ->
    let lhs = boolean_union (boolean_union (venn_a ()) (venn_b ())) (venn_c ()) in
    let rhs = boolean_union (venn_a ()) (boolean_union (venn_b ()) (venn_c ())) in
    assert (regions_equal lhs rhs));

  run "intersect associative three squares" (fun () ->
    let lhs = boolean_intersect (boolean_intersect (venn_a ()) (venn_b ())) (venn_c ()) in
    let rhs = boolean_intersect (venn_a ()) (boolean_intersect (venn_b ()) (venn_c ())) in
    assert (regions_equal lhs rhs));

  run "exclude associative three squares" (fun () ->
    let lhs = boolean_exclude (boolean_exclude (venn_a ()) (venn_b ())) (venn_c ()) in
    let rhs = boolean_exclude (venn_a ()) (boolean_exclude (venn_b ()) (venn_c ())) in
    assert (regions_equal lhs rhs));

  (* Shared-edge regression *)

  run "shared edges all ops" (fun () ->
    let a : polygon_set = [ [|(0., 0.); (10., 0.); (10., 10.); (0., 10.)|] ] in
    let b : polygon_set = [ [|(5., 0.); (15., 0.); (15., 10.); (5., 10.)|] ] in
    assert (approx_eq (polygon_set_area (boolean_union a b)) 150.0);
    assert (approx_eq (polygon_set_area (boolean_intersect a b)) 50.0);
    assert (approx_eq (polygon_set_area (boolean_subtract a b)) 50.0);
    assert (approx_eq (polygon_set_area (boolean_subtract b a)) 50.0);
    assert (approx_eq (polygon_set_area (boolean_exclude a b)) 100.0));

  (* Self-intersecting bowtie *)

  run "union bowtie with empty is two triangles" (fun () ->
    let result = boolean_union (bowtie ()) [] in
    assert (approx_eq (polygon_set_area result) 50.0));

  run "union bowtie with covering rect" (fun () ->
    let rect : polygon_set = [ [|(0., 0.); (10., 0.); (10., 10.); (0., 10.)|] ] in
    assert (approx_eq (polygon_set_area (boolean_union (bowtie ()) rect)) 100.0));

  run "intersect bowtie with bottom half" (fun () ->
    let rect : polygon_set = [ [|(0., 0.); (10., 0.); (10., 5.); (0., 5.)|] ] in
    let result = boolean_intersect (bowtie ()) rect in
    assert (approx_eq (polygon_set_area result) 25.0));

  run "subtract rect from bowtie" (fun () ->
    let rect : polygon_set = [ [|(0., 0.); (10., 0.); (10., 5.); (0., 5.)|] ] in
    let result = boolean_subtract (bowtie ()) rect in
    assert (approx_eq (polygon_set_area result) 25.0));

  (* Perturbation *)

  let perturbed delta : polygon_set * polygon_set =
    let a : polygon_set = [ [|(0., 0.); (10., 0.); (10., 10.); (0., 10.)|] ] in
    let b : polygon_set = [ [|(5., delta); (15., delta); (15., 10. +. delta); (5., 10. +. delta)|] ] in
    (a, b)
  in
  let check_perturb delta name =
    run (Printf.sprintf "perturb %s" name) (fun () ->
      let (a, b) = perturbed delta in
      let u_area = polygon_set_area (boolean_union a b) in
      let s_area = polygon_set_area (boolean_subtract a b) in
      assert (abs_float (u_area -. 150.0) < 0.1);
      assert (abs_float (s_area -. 50.0) < 0.1))
  in
  check_perturb 1e-15 "1e-15";
  check_perturb 1e-10 "1e-10";
  check_perturb 1e-8 "1e-8";
  check_perturb 1e-3 "1e-3";

  (* project_onto_segment *)

  run "project_onto_segment horizontal" (fun () ->
    let p = project_onto_segment (0., 0.) (10., 0.) (5., 1e-11) in
    assert (p = (5., 0.)));

  run "project_onto_segment vertical" (fun () ->
    let p = project_onto_segment (5., 0.) (5., 10.) (5. +. 1e-11, 7.) in
    assert (p = (5., 7.)));

  run "project_onto_segment clamps low" (fun () ->
    assert (project_onto_segment (0., 0.) (10., 0.) (-5., 0.) = (0., 0.)));

  run "project_onto_segment clamps high" (fun () ->
    assert (project_onto_segment (0., 0.) (10., 0.) (15., 0.) = (10., 0.)));

  run "project_onto_segment degenerate" (fun () ->
    assert (project_onto_segment (5., 5.) (5., 5.) (100., 100.) = (5., 5.)));

  (* Normalizer *)

  let total_area ps = List.fold_left (fun s r -> s +. abs_float (ring_signed_area r)) 0.0 ps in

  run "normalize simple square passes through" (fun () ->
    let input : polygon_set = [ [|(0., 0.); (10., 0.); (10., 10.); (0., 10.)|] ] in
    let out = Jas.Boolean_normalize.normalize input in
    assert (List.length out = 1);
    assert (approx_eq (total_area out) 100.0));

  run "normalize empty input yields empty" (fun () ->
    assert (Jas.Boolean_normalize.normalize [] = []));

  run "normalize ring with consecutive duplicates" (fun () ->
    let input : polygon_set = [ [|
      (0., 0.); (0., 0.); (10., 0.); (10., 10.); (10., 10.); (0., 10.)
    |] ] in
    let out = Jas.Boolean_normalize.normalize input in
    assert (List.length out = 1);
    assert (Array.length (List.hd out) = 4);
    assert (approx_eq (total_area out) 100.0));

  run "normalize figure-8 becomes two triangles" (fun () ->
    let input : polygon_set = [ [|(0., 0.); (10., 10.); (10., 0.); (0., 10.)|] ] in
    let out = Jas.Boolean_normalize.normalize input in
    assert (List.length out = 2);
    assert (approx_eq (total_area out) 50.0);
    List.iter (fun r -> assert (Array.length r = 3)) out);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
