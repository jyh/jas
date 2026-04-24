(* Variable-width outline of a path stroked with a Calligraphic
   brush. See the .mli for the public contract.

   Per-point offset distance perpendicular to the path tangent:
     phi = theta_brush - (theta_path + pi/2)
     d(phi) = sqrt((a/2 cos phi)^2 + (b/2 sin phi)^2)
   where a = brush.size, b = brush.size * brush.roundness / 100. *)

type t = {
  angle : float;
  roundness : float;
  size : float;
}

let sample_interval_pt = 1.0
let cubic_samples = 32
let quadratic_samples = 24

type sample = { x : float; y : float; tangent : float }

let sample_line out x0 y0 x1 y1 =
  let len = sqrt ((x1 -. x0) *. (x1 -. x0) +. (y1 -. y0) *. (y1 -. y0)) in
  if len = 0.0 then out
  else begin
    let tangent = atan2 (y1 -. y0) (x1 -. x0) in
    let n = max 1 (int_of_float (Float.ceil (len /. sample_interval_pt))) in
    let start_i = if out = [] then 0 else 1 in
    let acc = ref out in
    for i = start_i to n do
      let t = float_of_int i /. float_of_int n in
      acc := {
        x = x0 +. (x1 -. x0) *. t;
        y = y0 +. (y1 -. y0) *. t;
        tangent;
      } :: !acc
    done;
    !acc
  end

let sample_cubic out x0 y0 x1 y1 x2 y2 x3 y3 =
  let start_i = if out = [] then 0 else 1 in
  let acc = ref out in
  for i = start_i to cubic_samples do
    let t = float_of_int i /. float_of_int cubic_samples in
    let u = 1.0 -. t in
    let x = u *. u *. u *. x0 +. 3.0 *. u *. u *. t *. x1
            +. 3.0 *. u *. t *. t *. x2 +. t *. t *. t *. x3 in
    let y = u *. u *. u *. y0 +. 3.0 *. u *. u *. t *. y1
            +. 3.0 *. u *. t *. t *. y2 +. t *. t *. t *. y3 in
    let dx = 3.0 *. u *. u *. (x1 -. x0) +. 6.0 *. u *. t *. (x2 -. x1)
             +. 3.0 *. t *. t *. (x3 -. x2) in
    let dy = 3.0 *. u *. u *. (y1 -. y0) +. 6.0 *. u *. t *. (y2 -. y1)
             +. 3.0 *. t *. t *. (y3 -. y2) in
    let tangent =
      if dx = 0.0 && dy = 0.0 then atan2 (y3 -. y0) (x3 -. x0)
      else atan2 dy dx
    in
    acc := { x; y; tangent } :: !acc
  done;
  !acc

let sample_quadratic out x0 y0 x1 y1 x2 y2 =
  let start_i = if out = [] then 0 else 1 in
  let acc = ref out in
  for i = start_i to quadratic_samples do
    let t = float_of_int i /. float_of_int quadratic_samples in
    let u = 1.0 -. t in
    let x = u *. u *. x0 +. 2.0 *. u *. t *. x1 +. t *. t *. x2 in
    let y = u *. u *. y0 +. 2.0 *. u *. t *. y1 +. t *. t *. y2 in
    let dx = 2.0 *. u *. (x1 -. x0) +. 2.0 *. t *. (x2 -. x1) in
    let dy = 2.0 *. u *. (y1 -. y0) +. 2.0 *. t *. (y2 -. y1) in
    let tangent =
      if dx = 0.0 && dy = 0.0 then atan2 (y2 -. y0) (x2 -. x0)
      else atan2 dy dx
    in
    acc := { x; y; tangent } :: !acc
  done;
  !acc

(* Sample the path. Returns the samples in forward order. The fold
   accumulates in reverse for efficiency, then reverses at the end. *)
let sample_stroke_path commands =
  let cx = ref 0.0 and cy = ref 0.0 in
  let sx = ref 0.0 and sy = ref 0.0 in
  let started = ref false in
  let stop = ref false in
  let acc = ref [] in
  List.iter (fun cmd ->
    if not !stop then
      match cmd with
      | Element.MoveTo (x, y) ->
        if !started then stop := true
        else begin
          cx := x; cy := y;
          sx := x; sy := y
        end
      | Element.LineTo (x, y) ->
        acc := sample_line !acc !cx !cy x y;
        cx := x; cy := y;
        started := true
      | Element.CurveTo (x1, y1, x2, y2, x, y) ->
        acc := sample_cubic !acc !cx !cy x1 y1 x2 y2 x y;
        cx := x; cy := y;
        started := true
      | Element.QuadTo (x1, y1, x, y) ->
        acc := sample_quadratic !acc !cx !cy x1 y1 x y;
        cx := x; cy := y;
        started := true
      | Element.ClosePath ->
        if !cx <> !sx || !cy <> !sy then
          acc := sample_line !acc !cx !cy !sx !sy;
        stop := true
      | _ -> stop := true
  ) commands;
  List.rev !acc

let outline (commands : Element.path_command list) (brush : t) : (float * float) list =
  let samples = sample_stroke_path commands in
  if List.length samples < 2 then []
  else begin
    let a = brush.size /. 2.0 in
    let b = brush.size *. (brush.roundness /. 100.0) /. 2.0 in
    let theta_brush = brush.angle *. (Float.pi /. 180.0) in
    let two_pairs = List.map (fun s ->
      let phi = theta_brush -. (s.tangent +. (Float.pi /. 2.0)) in
      let d = sqrt ((a *. cos phi) ** 2.0 +. (b *. sin phi) ** 2.0) in
      let nx = -. (sin s.tangent) in
      let ny = cos s.tangent in
      let left = (s.x +. nx *. d, s.y +. ny *. d) in
      let right = (s.x -. nx *. d, s.y -. ny *. d) in
      (left, right)
    ) samples in
    let lefts = List.map fst two_pairs in
    let rights_rev = List.rev_map snd two_pairs in
    lefts @ rights_rev
  end
