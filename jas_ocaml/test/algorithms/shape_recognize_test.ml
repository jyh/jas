(** Shape recognition tests. Mirrors jas_dioxus shape_recognize.rs. *)

open Jas.Shape_recognize

(* Deterministic PRNG *)
let lcg_state = ref 0L
let lcg () =
  lcg_state := Int64.add (Int64.mul !lcg_state 1664525L) 1013904223L;
  let v = Int64.to_float (Int64.shift_right_logical !lcg_state 11) /.
          Int64.to_float (Int64.shift_left 1L 53) in
  2.0 *. v -. 1.0

(* Generators *)

let sample_line (ax, ay) (bx, by) n =
  List.init n (fun i ->
    let t = Float.of_int i /. Float.of_int (n - 1) in
    (ax +. (bx -. ax) *. t, ay +. (by -. ay) *. t))

let sample_triangle a b c n_per_side =
  let sides = [(a, b); (b, c); (c, a)] in
  let pts = List.concat_map (fun (p, q) ->
    let side = sample_line p q n_per_side in
    List.filteri (fun i _ -> i < n_per_side - 1) side
  ) sides in
  pts @ [a]

let sample_rect x y w h n_per_side =
  let p0 = (x, y) and p1 = (x +. w, y) in
  let p2 = (x +. w, y +. h) and p3 = (x, y +. h) in
  let sides = [(p0, p1); (p1, p2); (p2, p3); (p3, p0)] in
  let pts = List.concat_map (fun (p, q) ->
    let side = sample_line p q n_per_side in
    List.filteri (fun i _ -> i < n_per_side - 1) side
  ) sides in
  pts @ [p0]

let sample_round_rect x y w h r n =
  let arc_n = max (n / 16) 4 and side_n = max (n / 8) 4 in
  let pts = ref [] in
  let arc cx cy a0 a1 k =
    for i = 0 to k - 1 do
      let t = Float.of_int i /. Float.of_int k in
      let a = a0 +. (a1 -. a0) *. t in
      pts := (cx +. r *. cos a, cy +. r *. sin a) :: !pts
    done in
  let line x0 y0 x1 y1 k =
    for i = 0 to k - 1 do
      let t = Float.of_int i /. Float.of_int k in
      pts := (x0 +. (x1 -. x0) *. t, y0 +. (y1 -. y0) *. t) :: !pts
    done in
  line (x +. r) y (x +. w -. r) y side_n;
  arc (x +. w -. r) (y +. r) (-. Float.pi /. 2.0) 0.0 arc_n;
  line (x +. w) (y +. r) (x +. w) (y +. h -. r) side_n;
  arc (x +. w -. r) (y +. h -. r) 0.0 (Float.pi /. 2.0) arc_n;
  line (x +. w -. r) (y +. h) (x +. r) (y +. h) side_n;
  arc (x +. r) (y +. h -. r) (Float.pi /. 2.0) Float.pi arc_n;
  line x (y +. h -. r) x (y +. r) side_n;
  arc (x +. r) (y +. r) Float.pi (3.0 *. Float.pi /. 2.0) arc_n;
  List.rev ((x +. r, y) :: !pts)

let sample_circle cx cy r n =
  List.init (n + 1) (fun i ->
    let a = 2.0 *. Float.pi *. Float.of_int i /. Float.of_int n in
    (cx +. r *. cos a, cy +. r *. sin a))

let sample_ellipse cx cy rx ry n =
  List.init (n + 1) (fun i ->
    let a = 2.0 *. Float.pi *. Float.of_int i /. Float.of_int n in
    (cx +. rx *. cos a, cy +. ry *. sin a))

let sample_arrow_outline (tx, ty) (tipx, tipy) head_len head_half_w shaft_half_w =
  let dx = tipx -. tx and dy = tipy -. ty in
  let corners =
    if abs_float dy < 1e-9 then
      let dir = if dx > 0.0 then 1.0 else -1.0 in
      let sex = tipx -. dir *. head_len in
      [| (tx, ty -. shaft_half_w); (sex, ty -. shaft_half_w);
         (sex, ty -. head_half_w); (tipx, tipy);
         (sex, ty +. head_half_w); (sex, ty +. shaft_half_w);
         (tx, ty +. shaft_half_w) |]
    else
      let dir = if dy > 0.0 then 1.0 else -1.0 in
      let sey = tipy -. dir *. head_len in
      [| (tx -. shaft_half_w, ty); (tx -. shaft_half_w, sey);
         (tx -. head_half_w, sey); (tipx, tipy);
         (tx +. head_half_w, sey); (tx +. shaft_half_w, sey);
         (tx +. shaft_half_w, ty) |]
  in
  let pts = ref [] in
  for i = 0 to 6 do
    let p = corners.(i) and q = corners.((i + 1) mod 7) in
    let side = sample_line p q 10 in
    List.iteri (fun j pt -> if j < 9 then pts := pt :: !pts) side
  done;
  List.rev (corners.(0) :: !pts)

let sample_lemniscate cx cy a horizontal n =
  List.init (n + 1) (fun i ->
    let t = 2.0 *. Float.pi *. Float.of_int i /. Float.of_int n in
    let s = sin t and c = cos t in
    let denom = 1.0 +. s *. s in
    let lx = a *. c /. denom and ly = a *. s *. c /. denom in
    if horizontal then (cx +. lx, cy +. ly)
    else (cx +. ly, cy +. lx))

let sample_zigzag x_start y_center x_step y_amplitude n_zags pts_per_seg =
  let vertices = List.init (n_zags + 1) (fun i ->
    let x = x_start +. x_step *. Float.of_int i in
    let y = if i mod 2 = 0 then y_center -. y_amplitude else y_center +. y_amplitude in
    (x, y)) in
  let arr = Array.of_list vertices in
  let pts = ref [] in
  for i = 0 to Array.length arr - 2 do
    let seg = sample_line arr.(i) arr.(i + 1) pts_per_seg in
    List.iteri (fun j pt -> if j < pts_per_seg - 1 then pts := pt :: !pts) seg
  done;
  List.rev (arr.(Array.length arr - 1) :: !pts)

let jitter pts seed amplitude =
  lcg_state := seed;
  List.map (fun (x, y) -> (x +. amplitude *. lcg (), y +. amplitude *. lcg ())) pts

let open_gap pts frac =
  let n = List.length pts in
  let keep = max (int_of_float (Float.of_int n *. (1.0 -. frac))) 2 in
  List.filteri (fun i _ -> i < keep) pts

let bbox_diag pts =
  let xmin = ref infinity and xmax = ref neg_infinity in
  let ymin = ref infinity and ymax = ref neg_infinity in
  List.iter (fun (x, y) ->
    if x < !xmin then xmin := x; if x > !xmax then xmax := x;
    if y < !ymin then ymin := y; if y > !ymax then ymax := y
  ) pts;
  sqrt ((!xmax -. !xmin) *. (!xmax -. !xmin) +. (!ymax -. !ymin) *. (!ymax -. !ymin))

let rotate_pts pts cx cy theta =
  let s = sin theta and c = cos theta in
  List.map (fun (x, y) ->
    let dx = x -. cx and dy = y -. cy in
    (cx +. dx *. c -. dy *. s, cy +. dx *. s +. dy *. c)
  ) pts

let assert_close a b tol name =
  if abs_float (a -. b) > tol then
    failwith (Printf.sprintf "%s: expected %f, got %f, tol %f" name b a tol)

let cfg = default_config

let () =
  Alcotest.run "ShapeRecognize" [
    "generator sanity", [
      Alcotest.test_case "generator_circle_has_expected_radius" `Quick (fun () ->
        let pts = sample_circle 50.0 50.0 30.0 64 in
        List.iter (fun (x, y) ->
          let r = sqrt ((x -. 50.0) *. (x -. 50.0) +. (y -. 50.0) *. (y -. 50.0)) in
          assert (abs_float (r -. 30.0) < 1e-9)
        ) pts);

      Alcotest.test_case "generator_round_rect_runs" `Quick (fun () ->
        let pts = sample_round_rect 0.0 0.0 100.0 60.0 10.0 200 in
        assert (List.length pts > 50));

      Alcotest.test_case "generator_lemniscate_passes_through_origin_offset" `Quick (fun () ->
        let pts = sample_lemniscate 100.0 100.0 40.0 true 64 in
        let (x, y) = List.hd pts in
        assert (abs_float (x -. 140.0) < 1e-9);
        assert (abs_float (y -. 100.0) < 1e-9));

      Alcotest.test_case "jitter_is_deterministic" `Quick (fun () ->
        let pts = sample_circle 0.0 0.0 10.0 32 in
        let a = jitter pts 42L 0.5 and b = jitter pts 42L 0.5 in
        List.iter2 (fun (ax, ay) (bx, by) ->
          assert (ax = bx && ay = by)
        ) a b);
    ];

    "clean positive ID", [
      Alcotest.test_case "recognize_clean_line" `Quick (fun () ->
        let pts = sample_line (10.0, 20.0) (110.0, 20.0) 32 in
        match recognize pts cfg with
        | Some (Recognized_line { a; b }) ->
          let tol = 0.02 *. bbox_diag pts in
          assert_close (Float.min (fst a) (fst b)) 10.0 tol "x_min";
          assert_close (Float.max (fst a) (fst b)) 110.0 tol "x_max";
          assert_close (snd a) 20.0 tol "y1";
          assert_close (snd b) 20.0 tol "y2"
        | _ -> failwith "expected Line");

      Alcotest.test_case "recognize_clean_triangle" `Quick (fun () ->
        let pts = sample_triangle (0.0, 0.0) (100.0, 0.0) (50.0, 86.6) 20 in
        match recognize pts cfg with
        | Some (Recognized_triangle _) -> ()
        | _ -> failwith "expected Triangle");

      Alcotest.test_case "recognize_clean_rectangle" `Quick (fun () ->
        let pts = sample_rect 10.0 20.0 100.0 60.0 16 in
        match recognize pts cfg with
        | Some (Recognized_rectangle { x; y; w; h }) ->
          let tol = 0.02 *. bbox_diag pts in
          assert_close x 10.0 tol "x"; assert_close y 20.0 tol "y";
          assert_close w 100.0 tol "w"; assert_close h 60.0 tol "h"
        | _ -> failwith "expected Rectangle");

      Alcotest.test_case "recognize_clean_square_emits_rectangle_with_equal_sides" `Quick (fun () ->
        let pts = sample_rect 0.0 0.0 80.0 80.0 16 in
        match recognize pts cfg with
        | Some (Recognized_rectangle { w; h; _ }) ->
          assert (abs_float (w -. h) < 1e-6)
        | _ -> failwith "expected Rectangle");

      Alcotest.test_case "recognize_clean_round_rect" `Quick (fun () ->
        let pts = sample_round_rect 0.0 0.0 120.0 80.0 15.0 256 in
        match recognize pts cfg with
        | Some (Recognized_round_rect { x; y; w; h; r }) ->
          let tol = 0.04 *. bbox_diag pts in
          assert_close x 0.0 tol "x"; assert_close y 0.0 tol "y";
          assert_close w 120.0 tol "w"; assert_close h 80.0 tol "h";
          assert_close r 15.0 tol "r"
        | _ -> failwith "expected RoundRect");

      Alcotest.test_case "recognize_clean_circle" `Quick (fun () ->
        let pts = sample_circle 50.0 50.0 30.0 64 in
        match recognize pts cfg with
        | Some (Recognized_circle { cx; cy; r }) ->
          let tol = 0.02 *. bbox_diag pts in
          assert_close cx 50.0 tol "cx"; assert_close cy 50.0 tol "cy";
          assert_close r 30.0 tol "r"
        | _ -> failwith "expected Circle");

      Alcotest.test_case "recognize_clean_ellipse" `Quick (fun () ->
        let pts = sample_ellipse 50.0 50.0 60.0 30.0 64 in
        match recognize pts cfg with
        | Some (Recognized_ellipse { cx; cy; rx; ry }) ->
          let tol = 0.02 *. bbox_diag pts in
          assert_close cx 50.0 tol "cx"; assert_close cy 50.0 tol "cy";
          assert_close rx 60.0 tol "rx"; assert_close ry 30.0 tol "ry"
        | _ -> failwith "expected Ellipse");

      Alcotest.test_case "recognize_clean_arrow_outline" `Quick (fun () ->
        let pts = sample_arrow_outline (0.0, 50.0) (100.0, 50.0) 25.0 20.0 8.0 in
        match recognize pts cfg with
        | Some (Recognized_arrow { tail; tip; head_len; head_half_width; shaft_half_width }) ->
          let tol = 0.05 *. bbox_diag pts in
          assert_close (fst tail) 0.0 tol "tail.x";
          assert_close (fst tip) 100.0 tol "tip.x";
          assert_close head_len 25.0 tol "head_len";
          assert_close head_half_width 20.0 tol "head_hw";
          assert_close shaft_half_width 8.0 tol "shaft_hw"
        | _ -> failwith "expected Arrow");

      Alcotest.test_case "recognize_clean_lemniscate_horizontal" `Quick (fun () ->
        let pts = sample_lemniscate 100.0 100.0 50.0 true 128 in
        match recognize pts cfg with
        | Some (Recognized_lemniscate { center; a; horizontal }) ->
          let tol = 0.05 *. bbox_diag pts in
          assert_close (fst center) 100.0 tol "cx";
          assert_close (snd center) 100.0 tol "cy";
          assert_close a 50.0 tol "a";
          assert horizontal
        | _ -> failwith "expected Lemniscate");

      Alcotest.test_case "recognize_clean_lemniscate_vertical" `Quick (fun () ->
        let pts = sample_lemniscate 0.0 0.0 30.0 false 128 in
        match recognize pts cfg with
        | Some (Recognized_lemniscate { horizontal; _ }) -> assert (not horizontal)
        | _ -> failwith "expected Lemniscate");
    ];

    "noisy positive ID", [
      Alcotest.test_case "recognize_noisy_circle" `Quick (fun () ->
        let clean = sample_circle 50.0 50.0 30.0 64 in
        let pts = jitter clean 1L (0.03 *. bbox_diag clean) in
        match recognize pts cfg with
        | Some (Recognized_circle { cx; cy; r }) ->
          let tol = 0.05 *. bbox_diag clean in
          assert_close cx 50.0 tol "cx"; assert_close cy 50.0 tol "cy";
          assert_close r 30.0 tol "r"
        | _ -> failwith "expected Circle");

      Alcotest.test_case "recognize_noisy_rectangle" `Quick (fun () ->
        let clean = sample_rect 0.0 0.0 100.0 60.0 16 in
        let pts = jitter clean 2L (0.03 *. bbox_diag clean) in
        match recognize pts cfg with
        | Some (Recognized_rectangle _) -> ()
        | _ -> failwith "expected Rectangle");

      Alcotest.test_case "recognize_noisy_ellipse" `Quick (fun () ->
        let clean = sample_ellipse 0.0 0.0 60.0 30.0 64 in
        let pts = jitter clean 3L (0.03 *. bbox_diag clean) in
        match recognize pts cfg with
        | Some (Recognized_ellipse _) -> ()
        | _ -> failwith "expected Ellipse");

      Alcotest.test_case "recognize_noisy_triangle" `Quick (fun () ->
        let clean = sample_triangle (0.0, 0.0) (100.0, 0.0) (50.0, 86.6) 20 in
        let pts = jitter clean 4L (0.03 *. bbox_diag clean) in
        match recognize pts cfg with
        | Some (Recognized_triangle _) -> ()
        | _ -> failwith "expected Triangle");
    ];

    "closed/open dispatch", [
      Alcotest.test_case "nearly_closed_polyline_treated_as_closed" `Quick (fun () ->
        let clean = sample_rect 0.0 0.0 100.0 60.0 16 in
        let pts = open_gap clean 0.05 in
        match recognize pts cfg with
        | Some (Recognized_rectangle _) -> ()
        | _ -> failwith "expected Rectangle");

      Alcotest.test_case "clearly_open_polyline_not_rectangle" `Quick (fun () ->
        let clean = sample_rect 0.0 0.0 100.0 60.0 16 in
        let pts = open_gap clean 0.25 in
        match recognize pts cfg with
        | Some (Recognized_rectangle _) -> failwith "should not be Rectangle"
        | _ -> ());

      Alcotest.test_case "recognize_path_via_bezier_input" `Quick (fun () ->
        let open Jas.Element in
        let d = [MoveTo (0.0, 0.0); LineTo (100.0, 0.0); LineTo (100.0, 100.0);
                 LineTo (0.0, 100.0); ClosePath] in
        match recognize_path d cfg with
        | Some (Recognized_rectangle _) -> ()
        | _ -> failwith "expected Rectangle");
    ];

    "disambiguation", [
      Alcotest.test_case "square_with_aspect_1_04_is_square" `Quick (fun () ->
        let pts = sample_rect 0.0 0.0 104.0 100.0 16 in
        match recognize pts cfg with
        | Some (Recognized_rectangle { w; h; _ }) ->
          assert (abs_float (w -. h) < 1e-6)
        | _ -> failwith "expected Rectangle");

      Alcotest.test_case "rect_with_aspect_1_15_is_not_square" `Quick (fun () ->
        let pts = sample_rect 0.0 0.0 115.0 100.0 16 in
        match recognize pts cfg with
        | Some (Recognized_rectangle { w; h; _ }) ->
          assert (abs_float (w -. h) > 1.0)
        | _ -> failwith "expected Rectangle");

      Alcotest.test_case "nearly_circular_ellipse_is_circle" `Quick (fun () ->
        let pts = sample_ellipse 0.0 0.0 30.0 29.5 64 in
        match recognize pts cfg with
        | Some (Recognized_circle _) -> ()
        | _ -> failwith "expected Circle");

      Alcotest.test_case "clearly_elliptical_is_ellipse" `Quick (fun () ->
        let pts = sample_ellipse 0.0 0.0 30.0 15.0 64 in
        match recognize pts cfg with
        | Some (Recognized_ellipse _) -> ()
        | _ -> failwith "expected Ellipse");

      Alcotest.test_case "tiny_corner_radius_is_plain_rect" `Quick (fun () ->
        let pts = sample_round_rect 0.0 0.0 100.0 60.0 1.0 256 in
        match recognize pts cfg with
        | Some (Recognized_rectangle _) -> ()
        | _ -> failwith "expected Rectangle");

      Alcotest.test_case "flat_triangle_is_line" `Quick (fun () ->
        let pts = sample_triangle (0.0, 0.0) (100.0, 0.0) (50.0, 0.5) 20 in
        match recognize pts cfg with
        | Some (Recognized_line _) -> ()
        | _ -> failwith "expected Line");

      Alcotest.test_case "random_scribble_returns_none" `Quick (fun () ->
        lcg_state := 99L;
        let pts = List.init 64 (fun _ ->
          (50.0 +. 50.0 *. lcg (), 50.0 +. 50.0 *. lcg ())) in
        assert (recognize pts cfg = None));

      Alcotest.test_case "nearly_straight_arrow_outline_still_recognized" `Quick (fun () ->
        let pts = sample_arrow_outline (0.0, 50.0) (200.0, 50.0) 20.0 15.0 4.0 in
        match recognize pts cfg with
        | Some (Recognized_arrow _) -> ()
        | _ -> failwith "expected Arrow");

      Alcotest.test_case "tilted_square_returns_none" `Quick (fun () ->
        let clean = sample_rect (-50.0) (-50.0) 100.0 100.0 16 in
        let pts = rotate_pts clean 0.0 0.0 (30.0 *. Float.pi /. 180.0) in
        match recognize pts cfg with
        | Some (Recognized_rectangle _) -> failwith "tilted square should not be Rectangle"
        | _ -> ());

      Alcotest.test_case "lemniscate_off_center_crossing_returns_none" `Quick (fun () ->
        let pts = sample_lemniscate 0.0 0.0 50.0 true 128 in
        let skewed = List.map (fun (x, y) -> if x > 0.0 then (x +. 30.0, y) else (x, y)) pts in
        assert (recognize skewed cfg = None));
    ];

    "element conversion", [
      Alcotest.test_case "recognized_to_element_preserves_stroke_and_common" `Quick (fun () ->
        let open Jas.Element in
        let template = make_path
          ~stroke:(Some (make_stroke ~width:2.5 (make_color 0.0 0.0 0.0)))
          ~opacity:0.7 [] in
        let shape = Recognized_rectangle { x = 10.0; y = 20.0; w = 30.0; h = 40.0 } in
        match recognized_to_element shape template with
        | Rect { x; width; height; rx; stroke; opacity; _ } ->
          assert (x = 10.0); assert (width = 30.0); assert (height = 40.0);
          assert (rx = 0.0);
          (match stroke with
           | Some s -> assert (abs_float (s.stroke_width -. 2.5) < 1e-9)
           | None -> failwith "expected stroke");
          assert (abs_float (opacity -. 0.7) < 1e-9)
        | _ -> failwith "expected Rect");

      Alcotest.test_case "recognized_to_element_round_rect_sets_rx_ry" `Quick (fun () ->
        let open Jas.Element in
        let template = make_path [] in
        let shape = Recognized_round_rect { x = 0.0; y = 0.0; w = 100.0; h = 60.0; r = 12.0 } in
        match recognized_to_element shape template with
        | Rect { rx; ry; _ } -> assert (rx = 12.0); assert (ry = 12.0)
        | _ -> failwith "expected Rect");

      Alcotest.test_case "recognized_to_element_arrow_emits_polygon" `Quick (fun () ->
        let open Jas.Element in
        let template = make_path [] in
        let shape = Recognized_arrow { tail = (0.0, 0.0); tip = (100.0, 0.0);
          head_len = 25.0; head_half_width = 20.0; shaft_half_width = 8.0 } in
        match recognized_to_element shape template with
        | Polygon { points; _ } ->
          assert (List.length points = 7);
          let p3 = List.nth points 3 in
          assert (abs_float (fst p3 -. 100.0) < 1e-9);
          assert (abs_float (snd p3) < 1e-9)
        | _ -> failwith "expected Polygon");
    ];

    "scribble tests", [
      Alcotest.test_case "recognize_clean_zigzag_scribble" `Quick (fun () ->
        let pts = sample_zigzag 0.0 50.0 20.0 30.0 8 10 in
        match recognize pts cfg with
        | Some (Recognized_scribble { points }) ->
          assert (List.length points >= 5)
        | _ -> failwith "expected Scribble");

      Alcotest.test_case "recognize_noisy_zigzag_scribble" `Quick (fun () ->
        let clean = sample_zigzag 0.0 50.0 15.0 25.0 10 10 in
        let pts = jitter clean 7L (0.02 *. bbox_diag clean) in
        match recognize pts cfg with
        | Some (Recognized_scribble _) -> ()
        | _ -> failwith "expected Scribble");

      Alcotest.test_case "straight_line_not_scribble" `Quick (fun () ->
        let pts = sample_line (0.0, 0.0) (200.0, 0.0) 64 in
        match recognize pts cfg with
        | Some (Recognized_scribble _) -> failwith "should not be Scribble"
        | Some (Recognized_line _) -> ()
        | _ -> failwith "expected Line");

      Alcotest.test_case "diagonal_line_not_scribble" `Quick (fun () ->
        let pts = sample_line (0.0, 0.0) (100.0, 80.0) 64 in
        match recognize pts cfg with
        | Some (Recognized_line _) -> ()
        | _ -> failwith "expected Line");

      Alcotest.test_case "recognized_to_element_scribble_emits_polyline" `Quick (fun () ->
        let open Jas.Element in
        let template = make_path [] in
        let shape = Recognized_scribble {
          points = [(0.0, 0.0); (10.0, 20.0); (20.0, 0.0); (30.0, 20.0); (40.0, 0.0)] } in
        match recognized_to_element shape template with
        | Polyline { points; _ } -> assert (List.length points = 5)
        | _ -> failwith "expected Polyline");
    ];

    "recognize_element", [
      Alcotest.test_case "recognize_element_skips_line" `Quick (fun () ->
        let open Jas.Element in
        let elem = make_line 0.0 0.0 100.0 0.0 in
        assert (recognize_element elem cfg = None));

      Alcotest.test_case "recognize_element_skips_rect" `Quick (fun () ->
        let open Jas.Element in
        let elem = Rect { x = 0.0; y = 0.0; width = 100.0; height = 60.0; rx = 0.0; ry = 0.0;
          fill = None; stroke = None; opacity = 1.0; transform = None; locked = false; visibility = Preview } in
        assert (recognize_element elem cfg = None));

      Alcotest.test_case "recognize_element_skips_circle" `Quick (fun () ->
        let open Jas.Element in
        let elem = Circle { cx = 50.0; cy = 50.0; r = 30.0;
          fill = None; stroke = None; opacity = 1.0; transform = None; locked = false; visibility = Preview } in
        assert (recognize_element elem cfg = None));

      Alcotest.test_case "recognize_element_skips_polygon" `Quick (fun () ->
        let open Jas.Element in
        let elem = Polygon { points = [(0.0, 0.0); (100.0, 0.0); (50.0, 86.6)];
          fill = None; stroke = None; opacity = 1.0; transform = None; locked = false; visibility = Preview } in
        assert (recognize_element elem cfg = None));

      Alcotest.test_case "recognize_element_converts_path_circle" `Quick (fun () ->
        let open Jas.Element in
        let pts = sample_circle 50.0 50.0 30.0 64 in
        let d = List.mapi (fun i (x, y) ->
          if i = 0 then MoveTo (x, y) else LineTo (x, y)) pts in
        let elem = make_path d in
        match recognize_element elem cfg with
        | Some (Circle, Jas.Element.Circle _) -> ()
        | _ -> failwith "expected (Circle, Circle)");

      Alcotest.test_case "recognize_element_square_returns_square_kind" `Quick (fun () ->
        let open Jas.Element in
        let pts = sample_rect 0.0 0.0 80.0 80.0 16 in
        let d = List.mapi (fun i (x, y) ->
          if i = 0 then MoveTo (x, y) else LineTo (x, y)) pts in
        let elem = make_path d in
        match recognize_element elem cfg with
        | Some (Square, Jas.Element.Rect _) -> ()
        | _ -> failwith "expected (Square, Rect)");
    ];
  ]
