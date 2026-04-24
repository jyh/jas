(** Shape recognition: classify a freehand path as the nearest geometric
    primitive (line, scribble, triangle, rectangle, rounded rectangle,
    circle, ellipse, filled-arrow outline, or lemniscate). *)

type pt = float * float

type shape_kind =
  | Line | Triangle | Rectangle | Square | Round_rect
  | Circle | Ellipse | Arrow | Lemniscate | Scribble

type recognized_shape =
  | Recognized_line of { a : pt; b : pt }
  | Recognized_triangle of { pts : pt * pt * pt }
  | Recognized_rectangle of { x : float; y : float; w : float; h : float }
  | Recognized_round_rect of { x : float; y : float; w : float; h : float; r : float }
  | Recognized_circle of { cx : float; cy : float; r : float }
  | Recognized_ellipse of { cx : float; cy : float; rx : float; ry : float }
  | Recognized_arrow of { tail : pt; tip : pt; head_len : float; head_half_width : float; shaft_half_width : float }
  | Recognized_lemniscate of { center : pt; a : float; horizontal : bool }
  | Recognized_scribble of { points : pt list }

let shape_kind = function
  | Recognized_line _ -> Line
  | Recognized_triangle _ -> Triangle
  | Recognized_rectangle { w; h; _ } ->
    if abs_float (w -. h) < 1e-9 then Square else Rectangle
  | Recognized_round_rect _ -> Round_rect
  | Recognized_circle _ -> Circle
  | Recognized_ellipse _ -> Ellipse
  | Recognized_arrow _ -> Arrow
  | Recognized_lemniscate _ -> Lemniscate
  | Recognized_scribble _ -> Scribble

type recognize_config = {
  tolerance : float;
  close_gap_frac : float;
  corner_angle_deg : float;
  square_aspect_eps : float;
  circle_eccentricity_eps : float;
  resample_n : int;
}

let default_config = {
  tolerance = 0.05;
  close_gap_frac = 0.10;
  corner_angle_deg = 35.0;
  square_aspect_eps = 0.10;
  circle_eccentricity_eps = 0.92;
  resample_n = 64;
}

let min_closed_bbox_aspect = 0.10

(* Geometric helpers *)

let dist (x1, y1) (x2, y2) =
  let dx = x2 -. x1 and dy = y2 -. y1 in
  sqrt (dx *. dx +. dy *. dy)

let bbox_of pts =
  let xmin = ref infinity and ymin = ref infinity in
  let xmax = ref neg_infinity and ymax = ref neg_infinity in
  List.iter (fun (x, y) ->
    if x < !xmin then xmin := x;
    if x > !xmax then xmax := x;
    if y < !ymin then ymin := y;
    if y > !ymax then ymax := y
  ) pts;
  (!xmin, !ymin, !xmax, !ymax)

let bbox_diag_of pts =
  let (xmin, ymin, xmax, ymax) = bbox_of pts in
  sqrt ((xmax -. xmin) *. (xmax -. xmin) +. (ymax -. ymin) *. (ymax -. ymin))

let arc_length pts =
  let rec go acc = function
    | [] | [_] -> acc
    | a :: (b :: _ as rest) -> go (acc +. dist a b) rest
  in go 0.0 pts

let is_closed pts frac =
  match pts with
  | [] | [_] -> false
  | _ ->
    let total = arc_length pts in
    if total < 1e-12 then false
    else
      let first = List.hd pts in
      let last = List.nth pts (List.length pts - 1) in
      dist first last /. total <= frac

let resample pts n =
  let arr = Array.of_list pts in
  let len = Array.length arr in
  if len < 2 || n < 2 then pts
  else begin
    let cum = Array.make len 0.0 in
    for i = 1 to len - 1 do
      cum.(i) <- cum.(i - 1) +. dist arr.(i - 1) arr.(i)
    done;
    let total = cum.(len - 1) in
    if total < 1e-12 then pts
    else begin
      let step = total /. Float.of_int (n - 1) in
      let out = Array.make n arr.(0) in
      let idx = ref 1 in
      for k = 1 to n - 2 do
        let target = step *. Float.of_int k in
        while !idx < len - 1 && cum.(!idx) < target do incr idx done;
        let seg_start = cum.(!idx - 1) in
        let seg_len = cum.(!idx) -. seg_start in
        let t = if seg_len > 1e-12 then
          Float.min 1.0 (Float.max 0.0 ((target -. seg_start) /. seg_len))
        else 0.0 in
        let (x0, y0) = arr.(!idx - 1) in
        let (x1, y1) = arr.(!idx) in
        out.(k) <- (x0 +. t *. (x1 -. x0), y0 +. t *. (y1 -. y0))
      done;
      out.(n - 1) <- arr.(len - 1);
      Array.to_list out
    end
  end

let point_to_segment_dist (px, py) (ax, ay) (bx, by) =
  let dx = bx -. ax and dy = by -. ay in
  let len2 = dx *. dx +. dy *. dy in
  if len2 < 1e-12 then dist (px, py) (ax, ay)
  else begin
    let t = Float.min 1.0 (Float.max 0.0 (((px -. ax) *. dx +. (py -. ay) *. dy) /. len2)) in
    let qx = ax +. t *. dx and qy = ay +. t *. dy in
    sqrt ((px -. qx) *. (px -. qx) +. (py -. qy) *. (py -. qy))
  end

let point_to_line_dist (px, py) (ax, ay) (bx, by) =
  let dx = bx -. ax and dy = by -. ay in
  let len = sqrt (dx *. dx +. dy *. dy) in
  if len < 1e-12 then dist (px, py) (ax, ay)
  else abs_float ((px -. ax) *. dy -. (py -. ay) *. dx) /. len

(* Fits *)

let fit_line pts =
  let arr = Array.of_list pts in
  let n = Array.length arr in
  if n < 2 then None
  else begin
    let nf = Float.of_int n in
    let cx = ref 0.0 and cy = ref 0.0 in
    Array.iter (fun (x, y) -> cx := !cx +. x; cy := !cy +. y) arr;
    cx := !cx /. nf; cy := !cy /. nf;
    let sxx = ref 0.0 and syy = ref 0.0 and sxy = ref 0.0 in
    Array.iter (fun (x, y) ->
      let dx = x -. !cx and dy = y -. !cy in
      sxx := !sxx +. dx *. dx;
      syy := !syy +. dy *. dy;
      sxy := !sxy +. dx *. dy
    ) arr;
    let trace = !sxx +. !syy in
    let det = !sxx *. !syy -. !sxy *. !sxy in
    let disc = sqrt (Float.max 0.0 (trace *. trace /. 4.0 -. det)) in
    let lambda1 = trace /. 2.0 +. disc in
    let dx = ref 0.0 and dy = ref 0.0 in
    if abs_float !sxy > 1e-12 then begin
      dx := lambda1 -. !syy; dy := !sxy
    end else if !sxx >= !syy then begin
      dx := 1.0; dy := 0.0
    end else begin
      dx := 0.0; dy := 1.0
    end;
    let len = sqrt (!dx *. !dx +. !dy *. !dy) in
    if len < 1e-12 then None
    else begin
      dx := !dx /. len; dy := !dy /. len;
      let tmin = ref infinity and tmax = ref neg_infinity in
      let sq_sum = ref 0.0 in
      Array.iter (fun (x, y) ->
        let t = (x -. !cx) *. !dx +. (y -. !cy) *. !dy in
        if t < !tmin then tmin := t;
        if t > !tmax then tmax := t;
        let perp = (x -. !cx) *. (-. !dy) +. (y -. !cy) *. !dx in
        sq_sum := !sq_sum +. perp *. perp
      ) arr;
      let rms = sqrt (!sq_sum /. nf) in
      let a = (!cx +. !tmin *. !dx, !cy +. !tmin *. !dy) in
      let b = (!cx +. !tmax *. !dx, !cy +. !tmax *. !dy) in
      Some (a, b, rms)
    end
  end

let fit_ellipse_aa pts =
  let (xmin, ymin, xmax, ymax) = bbox_of pts in
  let rx = (xmax -. xmin) /. 2.0 and ry = (ymax -. ymin) /. 2.0 in
  if rx <= 1e-9 || ry <= 1e-9 then None
  else if Float.min rx ry /. Float.max rx ry < min_closed_bbox_aspect then None
  else begin
    let cx = (xmin +. xmax) /. 2.0 and cy = (ymin +. ymax) /. 2.0 in
    let scale = Float.min rx ry in
    let sq_sum = ref 0.0 in
    List.iter (fun (x, y) ->
      let nx = (x -. cx) /. rx and ny = (y -. cy) /. ry in
      let r = sqrt (nx *. nx +. ny *. ny) in
      let d = (r -. 1.0) *. scale in
      sq_sum := !sq_sum +. d *. d
    ) pts;
    let rms = sqrt (!sq_sum /. Float.of_int (List.length pts)) in
    Some (cx, cy, rx, ry, rms)
  end

let fit_rect_aa pts =
  let (xmin, ymin, xmax, ymax) = bbox_of pts in
  let w = xmax -. xmin and h = ymax -. ymin in
  if w <= 1e-9 || h <= 1e-9 then None
  else if Float.min w h /. Float.max w h < min_closed_bbox_aspect then None
  else begin
    let sq_sum = ref 0.0 in
    List.iter (fun (x, y) ->
      let dx = Float.min (abs_float (x -. xmin)) (abs_float (x -. xmax)) in
      let dy = Float.min (abs_float (y -. ymin)) (abs_float (y -. ymax)) in
      let d = Float.min dx dy in
      sq_sum := !sq_sum +. d *. d
    ) pts;
    let rms = sqrt (!sq_sum /. Float.of_int (List.length pts)) in
    Some (xmin, ymin, w, h, rms)
  end

let dist_to_round_rect (px, py) x y w h r =
  let px = px -. x and py = py -. y in
  let qx = if px > w /. 2.0 then w -. px else px in
  let qy = if py > h /. 2.0 then h -. py else py in
  if qx >= r && qy >= r then Float.min qx qy
  else if qx >= r then qy
  else if qy >= r then qx
  else begin
    let dx = qx -. r and dy = qy -. r in
    abs_float (sqrt (dx *. dx +. dy *. dy) -. r)
  end

let round_rect_rms pts x y w h r =
  let sq_sum = ref 0.0 in
  List.iter (fun p ->
    let d = dist_to_round_rect p x y w h r in
    sq_sum := !sq_sum +. d *. d
  ) pts;
  sqrt (!sq_sum /. Float.of_int (List.length pts))

let fit_round_rect pts =
  let (xmin, ymin, xmax, ymax) = bbox_of pts in
  let w = xmax -. xmin and h = ymax -. ymin in
  if w <= 1e-9 || h <= 1e-9 then None
  else if Float.min w h /. Float.max w h < min_closed_bbox_aspect then None
  else begin
    let r_max = Float.min w h /. 2.0 in
    let n_steps = 40 in
    let best_r = ref 0.0 and best_rms = ref infinity in
    for i = 0 to n_steps do
      let r = r_max *. Float.of_int i /. Float.of_int n_steps in
      let rms = round_rect_rms pts xmin ymin w h r in
      if rms < !best_rms then begin best_rms := rms; best_r := r end
    done;
    let step = r_max /. Float.of_int n_steps in
    let lo = ref (Float.max (!best_r -. step) 0.0) in
    let hi = ref (Float.min (!best_r +. step) r_max) in
    for _ = 1 to 30 do
      let m1 = !lo +. (!hi -. !lo) *. 0.382 in
      let m2 = !lo +. (!hi -. !lo) *. 0.618 in
      let r1 = round_rect_rms pts xmin ymin w h m1 in
      let r2 = round_rect_rms pts xmin ymin w h m2 in
      if r1 < r2 then hi := m2 else lo := m1
    done;
    let r = (!lo +. !hi) /. 2.0 in
    let rms = round_rect_rms pts xmin ymin w h r in
    Some (xmin, ymin, w, h, r, rms)
  end

let rdp pts epsilon =
  let arr = Array.of_list pts in
  let n = Array.length arr in
  if n < 3 then pts
  else begin
    let keep = Array.make n false in
    keep.(0) <- true; keep.(n - 1) <- true;
    let rec recurse s e =
      if e <= s + 1 then ()
      else begin
        let a = arr.(s) and b = arr.(e) in
        let max_d = ref 0.0 and max_i = ref s in
        for i = s + 1 to e - 1 do
          let d = point_to_segment_dist arr.(i) a b in
          if d > !max_d then begin max_d := d; max_i := i end
        done;
        if !max_d > epsilon then begin
          keep.(!max_i) <- true;
          recurse s !max_i;
          recurse !max_i e
        end
      end
    in
    recurse 0 (n - 1);
    let result = ref [] in
    for i = n - 1 downto 0 do
      if keep.(i) then result := arr.(i) :: !result
    done;
    !result
  end

let fit_scribble pts diag =
  if List.length pts < 6 then None
  else begin
    let total_arc = arc_length pts in
    if total_arc < 1.5 *. diag then None
    else begin
      let eps = 0.05 *. diag in
      let simplified = rdp pts eps in
      let sa = Array.of_list simplified in
      let sn = Array.length sa in
      if sn < 5 then None
      else begin
        let sign_changes = ref 0 in
        let last_sign = ref 0.0 in
        for i = 1 to sn - 2 do
          let (px, py) = sa.(i - 1) in
          let (cx, cy) = sa.(i) in
          let (nx, ny) = sa.(i + 1) in
          let v1x = cx -. px and v1y = cy -. py in
          let v2x = nx -. cx and v2y = ny -. cy in
          let cross = v1x *. v2y -. v1y *. v2x in
          if abs_float cross > 1e-9 then begin
            let sign = if cross > 0.0 then 1.0 else -1.0 in
            if !last_sign <> 0.0 && sign <> !last_sign then
              incr sign_changes;
            last_sign := sign
          end
        done;
        if !sign_changes < 2 then None
        else begin
          let sq_sum = ref 0.0 in
          List.iter (fun p ->
            let min_d = ref infinity in
            for i = 0 to sn - 2 do
              let d = point_to_segment_dist p sa.(i) sa.(i + 1) in
              if d < !min_d then min_d := d
            done;
            sq_sum := !sq_sum +. !min_d *. !min_d
          ) pts;
          let rms = sqrt (!sq_sum /. Float.of_int (List.length pts)) in
          Some (simplified, rms)
        end
      end
    end
  end

let fit_triangle pts =
  let arr = Array.of_list pts in
  let n = Array.length arr in
  if n < 3 then None
  else begin
    let max_d = ref 0.0 and ai = ref 0 and bi = ref 0 in
    for i = 0 to n - 1 do
      for j = i + 1 to n - 1 do
        let d = dist arr.(i) arr.(j) in
        if d > !max_d then begin max_d := d; ai := i; bi := j end
      done
    done;
    if !max_d < 1e-9 then None
    else begin
      let pa = arr.(!ai) and pb = arr.(!bi) in
      let max_perp = ref 0.0 and ci = ref 0 in
      Array.iteri (fun i p ->
        if i <> !ai && i <> !bi then begin
          let d = point_to_line_dist p pa pb in
          if d > !max_perp then begin max_perp := d; ci := i end
        end
      ) arr;
      if !max_perp < 1e-9 then None
      else if !max_perp /. !max_d < 0.05 then None
      else begin
        let pc = arr.(!ci) in
        let edges = [| (pa, pb); (pb, pc); (pc, pa) |] in
        let sq_sum = ref 0.0 in
        Array.iter (fun p ->
          let min_d = ref infinity in
          Array.iter (fun (e0, e1) ->
            let d = point_to_segment_dist p e0 e1 in
            if d < !min_d then min_d := d
          ) edges;
          sq_sum := !sq_sum +. !min_d *. !min_d
        ) arr;
        let rms = sqrt (!sq_sum /. Float.of_int n) in
        Some ((pa, pb, pc), rms)
      end
    end
  end

let count_self_intersections pts =
  let ccw (ax, ay) (bx, by) (cx, cy) =
    (bx -. ax) *. (cy -. ay) -. (by -. ay) *. (cx -. ax)
  in
  let segs_intersect a1 a2 b1 b2 =
    let d1 = ccw b1 b2 a1 and d2 = ccw b1 b2 a2 in
    let d3 = ccw a1 a2 b1 and d4 = ccw a1 a2 b2 in
    d1 *. d2 < 0.0 && d3 *. d4 < 0.0
  in
  let arr = Array.of_list pts in
  let n = Array.length arr in
  if n < 4 then 0
  else begin
    let n_segs = n - 1 in
    let count = ref 0 in
    for i = 0 to n_segs - 1 do
      for j = i + 2 to n_segs - 1 do
        if i = 0 && j = n_segs - 1 then begin
          if dist arr.(0) arr.(n - 1) >= 1e-6 then
            if segs_intersect arr.(i) arr.(i + 1) arr.(j) arr.(j + 1) then
              incr count
        end else begin
          if segs_intersect arr.(i) arr.(i + 1) arr.(j) arr.(j + 1) then
            incr count
        end
      done
    done;
    !count
  end

let fit_lemniscate pts =
  let (xmin, ymin, xmax, ymax) = bbox_of pts in
  let w = xmax -. xmin and h = ymax -. ymin in
  if w <= 1e-9 || h <= 1e-9 then None
  else begin
    let cx = (xmin +. xmax) /. 2.0 and cy = (ymin +. ymax) /. 2.0 in
    let horizontal = w >= h in
    let a = if horizontal then w /. 2.0 else h /. 2.0 in
    let cross = if horizontal then h else w in
    let expected_cross = a *. sqrt 2.0 /. 2.0 in
    if abs_float (cross /. expected_cross -. 1.0) > 0.20 then None
    else begin
      let n_samples = 200 in
      let samples = Array.init n_samples (fun i ->
        let t = 2.0 *. Float.pi *. Float.of_int i /. Float.of_int n_samples in
        let s = sin t and c = cos t in
        let denom = 1.0 +. s *. s in
        let lx = a *. c /. denom and ly = a *. s *. c /. denom in
        if horizontal then (cx +. lx, cy +. ly)
        else (cx +. ly, cy +. lx)
      ) in
      let sq_sum = ref 0.0 in
      List.iter (fun (px, py) ->
        let min_d_sq = ref infinity in
        Array.iter (fun (sx, sy) ->
          let dx = px -. sx and dy = py -. sy in
          let d2 = dx *. dx +. dy *. dy in
          if d2 < !min_d_sq then min_d_sq := d2
        ) samples;
        sq_sum := !sq_sum +. !min_d_sq
      ) pts;
      let rms = sqrt (!sq_sum /. Float.of_int (List.length pts)) in
      Some (cx, cy, a, horizontal, rms)
    end
  end

let fit_arrow pts diag =
  let arr = Array.of_list pts in
  let n = Array.length arr in
  if n < 7 then None
  else begin
    let fracs = [| 0.04; 0.02; 0.01; 0.005 |] in
    let corners = ref [||] in
    Array.iter (fun frac ->
      if Array.length !corners = 0 then begin
        let eps = frac *. diag in
        let s = Array.of_list (rdp pts eps) in
        let sn = Array.length s in
        let s, sn =
          if sn >= 2 && dist s.(0) s.(sn - 1) < Float.max eps 1e-6 then
            Array.sub s 0 (sn - 1), sn - 1
          else s, sn
        in
        if sn = 7 then corners := s
      end
    ) fracs;
    let c = !corners in
    let nc = Array.length c in
    if nc <> 7 then None
    else begin
      let cross_signs = Array.init nc (fun i ->
        let prev = c.((i + nc - 1) mod nc) in
        let curr = c.(i) in
        let next = c.((i + 1) mod nc) in
        let v1x = fst prev -. fst curr and v1y = snd prev -. snd curr in
        let v2x = fst next -. fst curr and v2y = snd next -. snd curr in
        v2x *. v1y -. v2y *. v1x
      ) in
      let positives = Array.fold_left (fun acc s -> if s > 0.0 then acc + 1 else acc) 0 cross_signs in
      let negatives = nc - positives in
      if max positives negatives <> 5 || min positives negatives <> 2 then None
      else begin
        let majority_positive = positives > negatives in
        let is_majority s = (s > 0.0) = majority_positive in
        let tip_idx = ref (-1) in
        let ambiguous = ref false in
        for i = 0 to nc - 1 do
          if is_majority cross_signs.(i)
             && is_majority cross_signs.((i + nc - 1) mod nc)
             && is_majority cross_signs.((i + 1) mod nc) then begin
            if !tip_idx >= 0 then ambiguous := true;
            tip_idx := i
          end
        done;
        if !tip_idx < 0 || !ambiguous then None
        else begin
          let ti = !tip_idx in
          let tip = c.(ti) in
          let ci k = c.(((ti + k) mod nc + nc) mod nc) in
          let head_back_a = ci (-1) and head_back_b = ci 1 in
          let shaft_end_a = ci (-2) and shaft_end_b = ci 2 in
          let tail_a = ci (-3) and tail_b = ci 3 in
          let tail = ((fst tail_a +. fst tail_b) /. 2.0,
                      (snd tail_a +. snd tail_b) /. 2.0) in
          let dx = fst tip -. fst tail and dy = snd tip -. snd tail in
          let len = sqrt (dx *. dx +. dy *. dy) in
          if len < 1e-9 then None
          else begin
            let nx = abs_float (dx /. len) and ny = abs_float (dy /. len) in
            if Float.max nx ny < 0.95 then None
            else begin
              let shaft_half_width = dist tail_a tail_b /. 2.0 in
              let head_half_width = dist head_back_a head_back_b /. 2.0 in
              let shaft_end_mid = ((fst shaft_end_a +. fst shaft_end_b) /. 2.0,
                                   (snd shaft_end_a +. snd shaft_end_b) /. 2.0) in
              let head_len = dist tip shaft_end_mid in
              if head_half_width <= shaft_half_width then None
              else if shaft_half_width < 1e-6 || head_len < 1e-6 then None
              else begin
                let arrow_corners = [| tail_a; shaft_end_a; head_back_a; tip;
                                       head_back_b; shaft_end_b; tail_b |] in
                let edges = Array.init 7 (fun i ->
                  (arrow_corners.(i), arrow_corners.((i + 1) mod 7))
                ) in
                let sq_sum = ref 0.0 in
                Array.iter (fun p ->
                  let min_d = ref infinity in
                  Array.iter (fun (e0, e1) ->
                    let d = point_to_segment_dist p e0 e1 in
                    if d < !min_d then min_d := d
                  ) edges;
                  sq_sum := !sq_sum +. !min_d *. !min_d
                ) arr;
                let rms = sqrt (!sq_sum /. Float.of_int n) in
                Some (tail, tip, head_len, head_half_width, shaft_half_width, rms)
              end
            end
          end
        end
      end
    end
  end

(* Main recognizer *)

let recognize points cfg =
  if List.length points < 3 then None
  else begin
    let pts = resample points cfg.resample_n in
    let diag = bbox_diag_of pts in
    if diag < 1e-9 then None
    else begin
      let closed = is_closed pts cfg.close_gap_frac in
      let tol_abs = cfg.tolerance *. diag in
      let candidates = ref [] in
      let add res shape = candidates := (res, shape) :: !candidates in
      (* Line *)
      (match fit_line pts with
       | Some (a, b, res) when res <= tol_abs ->
         add res (Recognized_line { a; b })
       | _ -> ());
      (* Scribble (open only) *)
      if not closed then
        (match fit_scribble pts diag with
         | Some (segs, res) when res <= tol_abs ->
           add res (Recognized_scribble { points = segs })
         | _ -> ());
      if closed then begin
        (* Ellipse *)
        (match fit_ellipse_aa pts with
         | Some (cx, cy, rx, ry, res) when res <= tol_abs ->
           let ratio = Float.min rx ry /. Float.max rx ry in
           if ratio >= cfg.circle_eccentricity_eps then begin
             let r = (rx +. ry) /. 2.0 in
             add res (Recognized_circle { cx; cy; r })
           end else
             add res (Recognized_ellipse { cx; cy; rx; ry })
         | _ -> ());
        (* Rectangle *)
        let rect_fit = fit_rect_aa pts in
        (match rect_fit with
         | Some (x, y, w, h, res) when res <= tol_abs ->
           let aspect = abs_float (w -. h) /. Float.max w h in
           let w, h = if aspect <= cfg.square_aspect_eps then
             let m = (w +. h) /. 2.0 in (m, m)
           else (w, h) in
           add res (Recognized_rectangle { x; y; w; h })
         | _ -> ());
        (* Round rect *)
        (match fit_round_rect pts with
         | Some (x, y, w, h, r, res) ->
           let short = Float.min w h in
           let rect_rms = match rect_fit with Some (_, _, _, _, rms) -> rms | None -> infinity in
           if res <= tol_abs && r /. short > 0.05 && r /. short < 0.45 && res < 0.5 *. rect_rms then
             add res (Recognized_round_rect { x; y; w; h; r })
         | None -> ());
        (* Triangle *)
        (match fit_triangle pts with
         | Some ((a, b, c), res) when res <= tol_abs ->
           add res (Recognized_triangle { pts = (a, b, c) })
         | _ -> ());
        (* Lemniscate *)
        if count_self_intersections pts >= 1 then
          (match fit_lemniscate pts with
           | Some (cx, cy, a, horizontal, res) when res <= tol_abs ->
             add res (Recognized_lemniscate { center = (cx, cy); a; horizontal })
           | _ -> ());
        (* Arrow *)
        (match fit_arrow points diag with
         | Some (tail, tip, head_len, head_half_width, shaft_half_width, res) when res <= tol_abs ->
           add res (Recognized_arrow { tail; tip; head_len; head_half_width; shaft_half_width })
         | _ -> ())
      end;
      let sorted = List.sort (fun (a, _) (b, _) -> compare a b) !candidates in
      match sorted with
      | (_, shape) :: _ -> Some shape
      | [] -> None
    end
  end

let recognize_path d cfg =
  let pts = Element.flatten_path_commands d in
  recognize pts cfg

(* Element integration *)

type appearance = {
  a_fill : Element.fill option;
  a_stroke : Element.stroke option;
  a_opacity : float;
  a_transform : Element.transform option;
  a_locked : bool;
  a_visibility : Element.visibility;
}

let template_appearance = function
  | Element.Line { stroke; opacity; transform; locked; visibility; _ } ->
    { a_fill = None; a_stroke = stroke; a_opacity = opacity;
      a_transform = transform; a_locked = locked; a_visibility = visibility }
  | Element.Rect { fill; stroke; opacity; transform; locked; visibility; _ } ->
    { a_fill = fill; a_stroke = stroke; a_opacity = opacity;
      a_transform = transform; a_locked = locked; a_visibility = visibility }
  | Element.Circle { fill; stroke; opacity; transform; locked; visibility; _ } ->
    { a_fill = fill; a_stroke = stroke; a_opacity = opacity;
      a_transform = transform; a_locked = locked; a_visibility = visibility }
  | Element.Ellipse { fill; stroke; opacity; transform; locked; visibility; _ } ->
    { a_fill = fill; a_stroke = stroke; a_opacity = opacity;
      a_transform = transform; a_locked = locked; a_visibility = visibility }
  | Element.Polyline { fill; stroke; opacity; transform; locked; visibility; _ } ->
    { a_fill = fill; a_stroke = stroke; a_opacity = opacity;
      a_transform = transform; a_locked = locked; a_visibility = visibility }
  | Element.Polygon { fill; stroke; opacity; transform; locked; visibility; _ } ->
    { a_fill = fill; a_stroke = stroke; a_opacity = opacity;
      a_transform = transform; a_locked = locked; a_visibility = visibility }
  | Element.Path { fill; stroke; opacity; transform; locked; visibility; _ } ->
    { a_fill = fill; a_stroke = stroke; a_opacity = opacity;
      a_transform = transform; a_locked = locked; a_visibility = visibility }
  | _ ->
    { a_fill = None; a_stroke = None; a_opacity = 1.0;
      a_transform = None; a_locked = false; a_visibility = Preview }

let recognized_to_element shape template =
  let a = template_appearance template in
  match shape with
  | Recognized_line { a = (x1, y1); b = (x2, y2) } ->
    Element.Line { x1; y1; x2; y2; stroke = a.a_stroke; width_points = [];
                   opacity = a.a_opacity;
                   transform = a.a_transform; locked = a.a_locked; visibility = a.a_visibility; blend_mode = Element.Normal; mask = None;
                     stroke_gradient = None;
                   }
  | Recognized_triangle { pts = (p1, p2, p3) } ->
    Element.Polygon { points = [p1; p2; p3]; fill = a.a_fill; stroke = a.a_stroke;
                      opacity = a.a_opacity; transform = a.a_transform;
                      locked = a.a_locked; visibility = a.a_visibility; blend_mode = Element.Normal; mask = None;
                        fill_gradient = None;
                        stroke_gradient = None;
                      }
  | Recognized_rectangle { x; y; w; h } ->
    Element.Rect { x; y; width = w; height = h; rx = 0.0; ry = 0.0;
                   fill = a.a_fill; stroke = a.a_stroke; opacity = a.a_opacity;
                   transform = a.a_transform; locked = a.a_locked; visibility = a.a_visibility; blend_mode = Element.Normal; mask = None;
                     fill_gradient = None;
                     stroke_gradient = None;
                   }
  | Recognized_round_rect { x; y; w; h; r } ->
    Element.Rect { x; y; width = w; height = h; rx = r; ry = r;
                   fill = a.a_fill; stroke = a.a_stroke; opacity = a.a_opacity;
                   transform = a.a_transform; locked = a.a_locked; visibility = a.a_visibility; blend_mode = Element.Normal; mask = None;
                     fill_gradient = None;
                     stroke_gradient = None;
                   }
  | Recognized_circle { cx; cy; r } ->
    Element.Circle { cx; cy; r; fill = a.a_fill; stroke = a.a_stroke;
                     opacity = a.a_opacity; transform = a.a_transform;
                     locked = a.a_locked; visibility = a.a_visibility; blend_mode = Element.Normal; mask = None;
                       fill_gradient = None;
                       stroke_gradient = None;
                     }
  | Recognized_ellipse { cx; cy; rx; ry } ->
    Element.Ellipse { cx; cy; rx; ry; fill = a.a_fill; stroke = a.a_stroke;
                      opacity = a.a_opacity; transform = a.a_transform;
                      locked = a.a_locked; visibility = a.a_visibility; blend_mode = Element.Normal; mask = None;
                        fill_gradient = None;
                        stroke_gradient = None;
                      }
  | Recognized_arrow { tail; tip; head_len; head_half_width; shaft_half_width } ->
    let dx = fst tip -. fst tail and dy = snd tip -. snd tail in
    let len = sqrt (dx *. dx +. dy *. dy) in
    let ux, uy = if len > 1e-9 then (dx /. len, dy /. len) else (1.0, 0.0) in
    let px, py = (-. uy, ux) in
    let shaft_end = (fst tip -. ux *. head_len, snd tip -. uy *. head_len) in
    let p (cx, cy) s = (cx +. px *. s, cy +. py *. s) in
    let points = [
      p tail (-. shaft_half_width);
      p shaft_end (-. shaft_half_width);
      p shaft_end (-. head_half_width);
      tip;
      p shaft_end head_half_width;
      p shaft_end shaft_half_width;
      p tail shaft_half_width;
    ] in
    Element.Polygon { points; fill = a.a_fill; stroke = a.a_stroke;
                      opacity = a.a_opacity; transform = a.a_transform;
                      locked = a.a_locked; visibility = a.a_visibility; blend_mode = Element.Normal; mask = None;
                        fill_gradient = None;
                        stroke_gradient = None;
                      }
  | Recognized_scribble { points } ->
    Element.Polyline { points; fill = None; stroke = a.a_stroke;
                       opacity = a.a_opacity; transform = a.a_transform;
                       locked = a.a_locked; visibility = a.a_visibility; blend_mode = Element.Normal; mask = None;
                         fill_gradient = None;
                         stroke_gradient = None;
                       }
  | Recognized_lemniscate { center; a = la; horizontal } ->
    let n = 96 in
    let d = List.init (n + 1) (fun i ->
      let t = 2.0 *. Float.pi *. Float.of_int i /. Float.of_int n in
      let s = sin t and c = cos t in
      let denom = 1.0 +. s *. s in
      let lx = la *. c /. denom and ly = la *. s *. c /. denom in
      let x, y = if horizontal then (fst center +. lx, snd center +. ly)
                 else (fst center +. ly, snd center +. lx) in
      if i = 0 then Element.MoveTo (x, y)
      else Element.LineTo (x, y)
    ) @ [Element.ClosePath] in
    Element.Path { d; fill = a.a_fill; stroke = a.a_stroke;
                   width_points = [];
                   opacity = a.a_opacity; transform = a.a_transform;
                   locked = a.a_locked; visibility = a.a_visibility; blend_mode = Element.Normal; mask = None;
                     fill_gradient = None;
                     stroke_gradient = None;
                     stroke_brush = None;
                     stroke_brush_overrides = None;
                   }

let recognize_element element cfg =
  let pts = match element with
    | Element.Path { d; _ } -> Some (Element.flatten_path_commands d)
    | Element.Polyline { points; _ } -> Some points
    | Element.Line _ | Element.Rect _ | Element.Circle _ | Element.Ellipse _
    | Element.Polygon _ | Element.Text _ | Element.Text_path _
    | Element.Group _ | Element.Layer _ | Element.Live _ -> None
  in
  match pts with
  | None -> None
  | Some pts ->
    match recognize pts cfg with
    | None -> None
    | Some shape ->
      let kind = shape_kind shape in
      Some (kind, recognized_to_element shape element)
