(** Bezier curve fitting using the Schneider algorithm.

    Fits a sequence of points to a piecewise cubic Bezier curve.
    Based on "An Algorithm for Automatically Fitting Digitized Curves"
    by Philip J. Schneider, Graphics Gems I, 1990. *)

type segment = {
  p1x: float; p1y: float;
  c1x: float; c1y: float;
  c2x: float; c2y: float;
  p2x: float; p2y: float;
}

(* Vector helpers *)
let vadd (ax, ay) (bx, by) = (ax +. bx, ay +. by)
let vsub (ax, ay) (bx, by) = (ax -. bx, ay -. by)
let vscale (vx, vy) s = (vx *. s, vy *. s)
let vdot (ax, ay) (bx, by) = ax *. bx +. ay *. by
let vdist (ax, ay) (bx, by) = hypot (ax -. bx) (ay -. by)
let vnormalize (vx, vy) =
  let len = hypot vx vy in
  if len = 0.0 then (vx, vy)
  else (vx /. len, vy /. len)

(* Bernstein basis functions *)
let b0 u = let t = 1.0 -. u in t *. t *. t
let b1 u = let t = 1.0 -. u in 3.0 *. u *. t *. t
let b2 u = let t = 1.0 -. u in 3.0 *. u *. u *. t
let b3 u = u *. u *. u

let max_iterations = 4

let left_tangent d idx = vnormalize (vsub d.(idx + 1) d.(idx))
let right_tangent d idx = vnormalize (vsub d.(idx - 1) d.(idx))
let center_tangent d idx =
  let v1 = vsub d.(idx - 1) d.(idx) in
  let v2 = vsub d.(idx) d.(idx + 1) in
  vnormalize ((fst v1 +. fst v2) /. 2.0, (snd v1 +. snd v2) /. 2.0)

let chord_length_parameterize d first last =
  let n = last - first + 1 in
  let u = Array.make n 0.0 in
  for i = first + 1 to last do
    u.(i - first) <- u.(i - first - 1) +. vdist d.(i) d.(i - 1)
  done;
  let total = u.(last - first) in
  if total > 0.0 then
    for i = first + 1 to last do
      u.(i - first) <- u.(i - first) /. total
    done;
  u

let bezier_ii degree v t =
  let vtemp = Array.copy v in
  for i = 1 to degree do
    for j = 0 to degree - i do
      let (x0, y0) = vtemp.(j) in
      let (x1, y1) = vtemp.(j + 1) in
      vtemp.(j) <- ((1.0 -. t) *. x0 +. t *. x1, (1.0 -. t) *. y0 +. t *. y1)
    done
  done;
  vtemp.(0)

let newton_raphson q p u =
  let q_u = bezier_ii 3 q u in
  let q1 = [|
    ((fst q.(1) -. fst q.(0)) *. 3.0, (snd q.(1) -. snd q.(0)) *. 3.0);
    ((fst q.(2) -. fst q.(1)) *. 3.0, (snd q.(2) -. snd q.(1)) *. 3.0);
    ((fst q.(3) -. fst q.(2)) *. 3.0, (snd q.(3) -. snd q.(2)) *. 3.0);
  |] in
  let q2 = [|
    ((fst q1.(1) -. fst q1.(0)) *. 2.0, (snd q1.(1) -. snd q1.(0)) *. 2.0);
    ((fst q1.(2) -. fst q1.(1)) *. 2.0, (snd q1.(2) -. snd q1.(1)) *. 2.0);
  |] in
  let q1_u = bezier_ii 2 q1 u in
  let q2_u = bezier_ii 1 q2 u in
  let numerator =
    (fst q_u -. fst p) *. fst q1_u +. (snd q_u -. snd p) *. snd q1_u
  in
  let denominator =
    fst q1_u *. fst q1_u +. snd q1_u *. snd q1_u
    +. (fst q_u -. fst p) *. fst q2_u
    +. (snd q_u -. snd p) *. snd q2_u
  in
  if denominator = 0.0 then u
  else u -. numerator /. denominator

let generate_bezier d first last u_prime that1 that2 =
  let n_pts = last - first + 1 in
  let a = Array.init n_pts (fun i ->
    (vscale that1 (b1 u_prime.(i)), vscale that2 (b2 u_prime.(i)))
  ) in
  let c = [| [| 0.0; 0.0 |]; [| 0.0; 0.0 |] |] in
  let x = [| 0.0; 0.0 |] in
  for i = 0 to n_pts - 1 do
    c.(0).(0) <- c.(0).(0) +. vdot (fst a.(i)) (fst a.(i));
    c.(0).(1) <- c.(0).(1) +. vdot (fst a.(i)) (snd a.(i));
    c.(1).(0) <- c.(0).(1);
    c.(1).(1) <- c.(1).(1) +. vdot (snd a.(i)) (snd a.(i));
    let tmp = vsub d.(first + i)
      (vadd (vscale d.(first) (b0 u_prime.(i)))
        (vadd (vscale d.(first) (b1 u_prime.(i)))
          (vadd (vscale d.(last) (b2 u_prime.(i)))
            (vscale d.(last) (b3 u_prime.(i)))))) in
    x.(0) <- x.(0) +. vdot (fst a.(i)) tmp;
    x.(1) <- x.(1) +. vdot (snd a.(i)) tmp
  done;
  let det_c0_c1 = c.(0).(0) *. c.(1).(1) -. c.(1).(0) *. c.(0).(1) in
  let det_c0_x = c.(0).(0) *. x.(1) -. c.(1).(0) *. x.(0) in
  let det_x_c1 = x.(0) *. c.(1).(1) -. x.(1) *. c.(0).(1) in
  let alpha_l = if det_c0_c1 = 0.0 then 0.0 else det_x_c1 /. det_c0_c1 in
  let alpha_r = if det_c0_c1 = 0.0 then 0.0 else det_c0_x /. det_c0_c1 in
  let seg_length = vdist d.(first) d.(last) in
  let epsilon = 1.0e-6 *. seg_length in
  if alpha_l < epsilon || alpha_r < epsilon then begin
    let dist = seg_length /. 3.0 in
    { p1x = fst d.(first); p1y = snd d.(first);
      c1x = fst d.(first) +. fst that1 *. dist;
      c1y = snd d.(first) +. snd that1 *. dist;
      c2x = fst d.(last) +. fst that2 *. dist;
      c2y = snd d.(last) +. snd that2 *. dist;
      p2x = fst d.(last); p2y = snd d.(last) }
  end else
    { p1x = fst d.(first); p1y = snd d.(first);
      c1x = fst d.(first) +. fst that1 *. alpha_l;
      c1y = snd d.(first) +. snd that1 *. alpha_l;
      c2x = fst d.(last) +. fst that2 *. alpha_r;
      c2y = snd d.(last) +. snd that2 *. alpha_r;
      p2x = fst d.(last); p2y = snd d.(last) }

let compute_max_error d first last bez u =
  let pts = [| (bez.p1x, bez.p1y); (bez.c1x, bez.c1y);
               (bez.c2x, bez.c2y); (bez.p2x, bez.p2y) |] in
  let split_point = ref ((last - first + 1) / 2) in
  let max_dist = ref 0.0 in
  for i = first + 1 to last - 1 do
    let p = bezier_ii 3 pts u.(i - first) in
    let dx = fst p -. fst d.(i) in
    let dy = snd p -. snd d.(i) in
    let dist = dx *. dx +. dy *. dy in
    if dist >= !max_dist then begin
      max_dist := dist;
      split_point := i
    end
  done;
  (!max_dist, !split_point)

let reparameterize d first last u bez =
  let pts = [| (bez.p1x, bez.p1y); (bez.c1x, bez.c1y);
               (bez.c2x, bez.c2y); (bez.p2x, bez.p2y) |] in
  Array.init (last - first + 1) (fun i ->
    newton_raphson pts d.(first + i) u.(i)
  )

let rec fit_cubic d first last that1 that2 error result =
  let n_pts = last - first + 1 in
  if n_pts = 2 then begin
    let dist = vdist d.(first) d.(last) /. 3.0 in
    let seg = {
      p1x = fst d.(first); p1y = snd d.(first);
      c1x = fst d.(first) +. fst that1 *. dist;
      c1y = snd d.(first) +. snd that1 *. dist;
      c2x = fst d.(last) +. fst that2 *. dist;
      c2y = snd d.(last) +. snd that2 *. dist;
      p2x = fst d.(last); p2y = snd d.(last);
    } in
    result := seg :: !result
  end else begin
    let u = chord_length_parameterize d first last in
    let bez = ref (generate_bezier d first last u that1 that2) in
    let (max_err, sp) = compute_max_error d first last !bez u in
    let max_error = ref max_err in
    let split_point = ref sp in
    if !max_error < error then
      result := !bez :: !result
    else begin
      let iteration_error = error *. error in
      let u_ref = ref u in
      if !max_error < iteration_error then begin
        let done_ = ref false in
        for _ = 0 to max_iterations - 1 do
          if not !done_ then begin
            let u_prime = reparameterize d first last !u_ref !bez in
            bez := generate_bezier d first last u_prime that1 that2;
            let (me, sp2) = compute_max_error d first last !bez u_prime in
            max_error := me;
            split_point := sp2;
            if !max_error < error then begin
              result := !bez :: !result;
              done_ := true
            end else
              u_ref := u_prime
          end
        done;
        if !done_ then ()
        else begin
          let tc = center_tangent d !split_point in
          fit_cubic d first !split_point that1 tc error result;
          let tc_neg = (-. fst tc, -. snd tc) in
          fit_cubic d !split_point last tc_neg that2 error result
        end
      end else begin
        let tc = center_tangent d !split_point in
        fit_cubic d first !split_point that1 tc error result;
        let tc_neg = (-. fst tc, -. snd tc) in
        fit_cubic d !split_point last tc_neg that2 error result
      end
    end
  end

let fit_curve (points : (float * float) list) (error : float) : segment list =
  match points with
  | [] | [_] -> []
  | _ ->
    let d = Array.of_list points in
    let n = Array.length d in
    let that1 = left_tangent d 0 in
    let that2 = right_tangent d (n - 1) in
    let result = ref [] in
    fit_cubic d 0 (n - 1) that1 that2 error result;
    List.rev !result
