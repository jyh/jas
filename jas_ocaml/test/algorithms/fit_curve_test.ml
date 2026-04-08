(** Bezier curve fitter tests. Mirrors jas_dioxus/src/algorithms/fit_curve.rs. *)

open Jas.Fit_curve

let bezier_at (s : segment) t =
  let mt = 1.0 -. t in
  let b0 = mt *. mt *. mt in
  let b1 = 3.0 *. t *. mt *. mt in
  let b2 = 3.0 *. t *. t *. mt in
  let b3 = t *. t *. t in
  ( b0 *. s.p1x +. b1 *. s.c1x +. b2 *. s.c2x +. b3 *. s.p2x,
    b0 *. s.p1y +. b1 *. s.c1y +. b2 *. s.c2y +. b3 *. s.p2y )

let approx_eq ?(tol = 1e-9) a b = abs_float (a -. b) < tol
let point_approx_eq ?(tol = 1e-9) (ax, ay) (bx, by) =
  approx_eq ~tol ax bx && approx_eq ~tol ay by

let pass = ref 0
let fail = ref 0
let run name f =
  try f (); incr pass; Printf.printf "  PASS: %s\n" name
  with e -> incr fail; Printf.printf "  FAIL: %s — %s\n" name (Printexc.to_string e)

let make_pts n f =
  List.init n f

let last lst = List.nth lst (List.length lst - 1)

let () =
  Printf.printf "Fit curve tests:\n";

  run "empty returns empty" (fun () ->
    assert (fit_curve [] 1.0 = []));

  run "single point returns empty" (fun () ->
    assert (fit_curve [(0.0, 0.0)] 1.0 = []));

  run "two points returns one segment" (fun () ->
    let r = fit_curve [(0.0, 0.0); (10.0, 0.0)] 1.0 in
    assert (List.length r = 1));

  run "two points endpoints preserved" (fun () ->
    let pts = [(0.0, 0.0); (10.0, 0.0)] in
    let r = fit_curve pts 1.0 in
    let s = List.hd r in
    assert (point_approx_eq (s.p1x, s.p1y) (List.hd pts));
    assert (point_approx_eq (s.p2x, s.p2y) (last pts)));

  run "endpoints preserved on quarter arc" (fun () ->
    let pts = make_pts 21 (fun i ->
      let t = float_of_int i /. 20.0 *. (Float.pi /. 2.0) in
      (10.0 *. cos t, 10.0 *. sin t)) in
    let r = fit_curve pts 0.5 in
    assert (List.length r > 0);
    let first = List.hd r in
    let last_seg = last r in
    assert (point_approx_eq (first.p1x, first.p1y) (List.hd pts));
    assert (point_approx_eq (last_seg.p2x, last_seg.p2y) (last pts)));

  run "segments are C0 continuous" (fun () ->
    let pts = make_pts 30 (fun i ->
      let x = float_of_int i in
      (x, 5.0 *. sin (x *. 0.3))) in
    let r = fit_curve pts 0.5 in
    assert (List.length r >= 2);
    let arr = Array.of_list r in
    for i = 0 to Array.length arr - 2 do
      let prev_end = (arr.(i).p2x, arr.(i).p2y) in
      let next_start = (arr.(i+1).p1x, arr.(i+1).p1y) in
      assert (point_approx_eq prev_end next_start)
    done);

  run "two-point segment passes through endpoints" (fun () ->
    let pts = [(0.0, 0.0); (100.0, 50.0)] in
    let r = fit_curve pts 1.0 in
    let s = List.hd r in
    assert (point_approx_eq (bezier_at s 0.0) (List.hd pts));
    assert (point_approx_eq (bezier_at s 1.0) (last pts)));

  run "input points within 2x error of fit" (fun () ->
    let pts = make_pts 15 (fun i ->
      let x = float_of_int i in
      (x, 0.1 *. x *. x)) in
    let error = 1.0 in
    let segs = fit_curve pts error in
    let samples_per = 100 in
    let samples = List.concat_map (fun s ->
      List.init (samples_per + 1) (fun i ->
        bezier_at s (float_of_int i /. float_of_int samples_per))
    ) segs in
    List.iter (fun (px, py) ->
      let min_d = List.fold_left (fun m (sx, sy) ->
        let dx = sx -. px in
        let dy = sy -. py in
        let d = sqrt (dx *. dx +. dy *. dy) in
        min m d) infinity samples in
      assert (min_d <= error *. 2.0)
    ) pts);

  run "tighter error gives at least as many segments" (fun () ->
    let pts = make_pts 50 (fun i ->
      let x = float_of_int i *. 0.5 in
      (x, 5.0 *. sin (x *. 0.5))) in
    let loose = fit_curve pts 5.0 in
    let tight = fit_curve pts 0.1 in
    assert (List.length tight >= List.length loose));

  run "straight line collinear points" (fun () ->
    let pts = make_pts 10 (fun i -> (float_of_int i, 2.0 *. float_of_int i)) in
    let r = fit_curve pts 1.0 in
    assert (List.length r = 1));

  run "horizontal line" (fun () ->
    let pts = make_pts 10 (fun i -> (float_of_int i, 5.0)) in
    let r = fit_curve pts 1.0 in
    assert (List.length r = 1);
    let s = List.hd r in
    assert (point_approx_eq (s.p1x, s.p1y) (0.0, 5.0));
    assert (point_approx_eq (s.p2x, s.p2y) (9.0, 5.0)));

  run "vertical line" (fun () ->
    let pts = make_pts 10 (fun i -> (3.0, float_of_int i)) in
    let r = fit_curve pts 1.0 in
    assert (List.length r = 1);
    let s = List.hd r in
    assert (point_approx_eq (s.p1x, s.p1y) (3.0, 0.0));
    assert (point_approx_eq (s.p2x, s.p2y) (3.0, 9.0)));

  run "circular arc returns some segments" (fun () ->
    let pts = make_pts 61 (fun i ->
      let t = float_of_int i /. 60.0 *. Float.pi in
      (50.0 *. cos t, 50.0 *. sin t)) in
    let r = fit_curve pts 0.5 in
    assert (List.length r > 0);
    assert (List.length r <= List.length pts));

  run "two coincident points does not crash" (fun () ->
    let _ = fit_curve [(5.0, 5.0); (5.0, 5.0)] 1.0 in
    ());

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
