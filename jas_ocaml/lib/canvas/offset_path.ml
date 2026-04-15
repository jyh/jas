(** Variable-width stroke rendering via offset paths.

    Flattens a path to a polyline, computes normals at each sample point,
    evaluates the width profile, and builds a filled polygon representing
    the stroke outline. *)

open Element

(** A sampled point along a path with position, unit normal, and path offset. *)
type path_sample = {
  ps_x : float;
  ps_y : float;
  ps_nx : float;  (** unit normal x (perpendicular to tangent, pointing left) *)
  ps_ny : float;  (** unit normal y *)
  ps_t : float;   (** fractional offset along path [0, 1] *)
}

(** Cumulative arc lengths for a polyline. *)
let arc_lengths pts =
  let arr = Array.of_list pts in
  let n = Array.length arr in
  let lengths = Array.make n 0.0 in
  for i = 1 to n - 1 do
    let (px, py) = arr.(i - 1) in
    let (qx, qy) = arr.(i) in
    let dx = qx -. px in
    let dy = qy -. py in
    lengths.(i) <- lengths.(i - 1) +. sqrt (dx *. dx +. dy *. dy)
  done;
  lengths

(** Sample a path at regular intervals, computing position and unit normal. *)
let sample_path_with_normals cmds =
  let pts = flatten_path_commands cmds in
  let n = List.length pts in
  if n < 2 then []
  else
    let arr = Array.of_list pts in
    let lengths = arc_lengths pts in
    let total = lengths.(Array.length lengths - 1) in
    if total = 0.0 then []
    else
      let samples = Array.init n (fun i ->
        let t = lengths.(i) /. total in
        let (dx, dy) =
          if i = 0 then
            (fst arr.(1) -. fst arr.(0), snd arr.(1) -. snd arr.(0))
          else if i = n - 1 then
            (fst arr.(i) -. fst arr.(i - 1), snd arr.(i) -. snd arr.(i - 1))
          else
            (fst arr.(i + 1) -. fst arr.(i - 1), snd arr.(i + 1) -. snd arr.(i - 1))
        in
        let len = sqrt (dx *. dx +. dy *. dy) in
        let (nx, ny) = if len > 1e-10 then (-. dy /. len, dx /. len) else (0.0, 1.0) in
        { ps_x = fst arr.(i); ps_y = snd arr.(i); ps_nx = nx; ps_ny = ny; ps_t = t }
      ) in
      Array.to_list samples

(** Sample a line segment with normals at regular intervals. *)
let sample_line_with_normals x1 y1 x2 y2 =
  let dx = x2 -. x1 in
  let dy = y2 -. y1 in
  let len = sqrt (dx *. dx +. dy *. dy) in
  if len < 1e-10 then []
  else
    let nx = -. dy /. len in
    let ny = dx /. len in
    let num_samples = 32 in
    let samples = Array.init (num_samples + 1) (fun i ->
      let t = float_of_int i /. float_of_int num_samples in
      { ps_x = x1 +. dx *. t; ps_y = y1 +. dy *. t;
        ps_nx = nx; ps_ny = ny; ps_t = t }
    ) in
    Array.to_list samples

(** Smoothstep: cubic ease-in-out for smooth width transitions. *)
let smoothstep t =
  let t = max 0.0 (min 1.0 t) in
  t *. t *. (3.0 -. 2.0 *. t)

(** Evaluate width at offset t by smoothly interpolating width control points.
    Uses smoothstep for each segment to avoid sharp kinks at control points. *)
let evaluate_width_at points t =
  match points with
  | [] -> (0.0, 0.0)
  | [p] -> (p.swp_width_left, p.swp_width_right)
  | first :: _ ->
    if t <= first.swp_t then (first.swp_width_left, first.swp_width_right)
    else
      let arr = Array.of_list points in
      let n = Array.length arr in
      let last = arr.(n - 1) in
      if t >= last.swp_t then (last.swp_width_left, last.swp_width_right)
      else
        let result = ref (last.swp_width_left, last.swp_width_right) in
        for i = 1 to n - 1 do
          if t <= arr.(i).swp_t && t > arr.(i - 1).swp_t then begin
            let dt = arr.(i).swp_t -. arr.(i - 1).swp_t in
            let frac = if dt > 0.0 then (t -. arr.(i - 1).swp_t) /. dt else 0.0 in
            let s = smoothstep frac in
            let wl = arr.(i - 1).swp_width_left +. s *. (arr.(i).swp_width_left -. arr.(i - 1).swp_width_left) in
            let wr = arr.(i - 1).swp_width_right +. s *. (arr.(i).swp_width_right -. arr.(i - 1).swp_width_right) in
            result := (wl, wr)
          end
        done;
        !result

(** Render from computed samples, building and filling the offset polygon. *)
let render_from_samples cr samples width_points stroke_color linecap =
  match samples with
  | [] | [_] -> ()
  | _ ->
    let n = List.length samples in
    let left = Array.make n (0.0, 0.0) in
    let right = Array.make n (0.0, 0.0) in
    List.iteri (fun i s ->
      let (wl, wr) = evaluate_width_at width_points s.ps_t in
      left.(i) <- (s.ps_x +. s.ps_nx *. wl, s.ps_y +. s.ps_ny *. wl);
      right.(i) <- (s.ps_x -. s.ps_nx *. wr, s.ps_y -. s.ps_ny *. wr)
    ) samples;

    let s0 = List.hd samples in
    let sn = List.nth samples (n - 1) in
    let (wl0, wr0) = evaluate_width_at width_points 0.0 in
    let (wln, wrn) = evaluate_width_at width_points 1.0 in

    Cairo.Path.clear cr;

    (* Start cap *)
    (match linecap with
     | Round_cap when wl0 +. wr0 > 0.1 ->
       let r = (wl0 +. wr0) /. 2.0 in
       let tangent_angle = atan2 s0.ps_ny (-. s0.ps_nx) in
       Cairo.move_to cr (fst right.(0)) (snd right.(0));
       Cairo.arc cr s0.ps_x s0.ps_y ~r
         ~a1:(tangent_angle +. Float.pi /. 2.0)
         ~a2:(tangent_angle -. Float.pi /. 2.0)
     | Square when wl0 +. wr0 > 0.1 ->
       let ext = (wl0 +. wr0) /. 2.0 in
       let bx = -. s0.ps_ny in
       let by = s0.ps_nx in
       Cairo.move_to cr (fst right.(0) +. bx *. ext) (snd right.(0) +. by *. ext);
       Cairo.line_to cr (fst left.(0) +. bx *. ext) (snd left.(0) +. by *. ext)
     | _ ->
       Cairo.move_to cr (fst left.(0)) (snd left.(0)));

    (* Left edge forward *)
    for i = 0 to n - 1 do
      Cairo.line_to cr (fst left.(i)) (snd left.(i))
    done;

    (* End cap *)
    (match linecap with
     | Round_cap when wln +. wrn > 0.1 ->
       let r = (wln +. wrn) /. 2.0 in
       let tangent_angle = atan2 sn.ps_ny (-. sn.ps_nx) in
       Cairo.arc cr sn.ps_x sn.ps_y ~r
         ~a1:(tangent_angle -. Float.pi /. 2.0)
         ~a2:(tangent_angle +. Float.pi /. 2.0)
     | Square when wln +. wrn > 0.1 ->
       let ext = (wln +. wrn) /. 2.0 in
       let fx = sn.ps_ny in
       let fy = -. sn.ps_nx in
       Cairo.line_to cr (fst left.(n - 1) +. fx *. ext) (snd left.(n - 1) +. fy *. ext);
       Cairo.line_to cr (fst right.(n - 1) +. fx *. ext) (snd right.(n - 1) +. fy *. ext)
     | _ -> ());

    (* Right edge reversed *)
    for i = n - 1 downto 0 do
      Cairo.line_to cr (fst right.(i)) (snd right.(i))
    done;

    Cairo.Path.close cr;
    let (r, g, b, a) = stroke_color in
    Cairo.set_source_rgba cr r g b a;
    Cairo.fill cr

(** Render a variable-width stroke for a path element. *)
let render_variable_width_path cr cmds width_points stroke_color linecap =
  let samples = sample_path_with_normals cmds in
  render_from_samples cr samples width_points stroke_color linecap

(** Render a variable-width stroke for a line element. *)
let render_variable_width_line cr x1 y1 x2 y2 width_points stroke_color linecap =
  let samples = sample_line_with_normals x1 y1 x2 y2 in
  render_from_samples cr samples width_points stroke_color linecap
