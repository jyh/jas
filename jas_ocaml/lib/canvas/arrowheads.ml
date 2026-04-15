(** Arrowhead shape definitions and rendering.

    Each shape is defined as a normalized path in a unit coordinate system:
    - Pointing right (+x direction)
    - Tip at origin (0, 0) for tip-at-end alignment
    - Unit size (1.0 = stroke width at 100% scale)

    At render time the shape is transformed: translate to endpoint,
    rotate to match path tangent, scale by stroke_width * scale%. *)

open Element

(** Whether the shape should be filled, stroked (outline), or both. *)
type shape_style = Filled | Outline

(** A static arrowhead shape definition. *)
type arrow_shape = {
  cmds : path_command list;
  style : shape_style;
  (** How far back from the tip the shape extends (in unit coords).
      The path is shortened by this x scale so the stroke ends at the base. *)
  back : float;
}

(* ------------------------------------------------------------------ *)
(* Shape definitions -- all in unit coordinates, tip at (0,0), right.  *)
(* Scale factor of ~4.0 relative to stroke width gives good size.      *)
(* ------------------------------------------------------------------ *)

let simple_arrow_cmds = [
  MoveTo (0.0, 0.0); LineTo (-4.0, -2.0); LineTo (-4.0, 2.0); ClosePath
]
let open_arrow_cmds = [
  MoveTo (-4.0, -2.0); LineTo (0.0, 0.0); LineTo (-4.0, 2.0)
]
let closed_arrow_cmds = [
  MoveTo (0.0, 0.0); LineTo (-4.0, -2.0); LineTo (-4.0, 2.0); ClosePath;
  MoveTo (-4.5, -2.0); LineTo (-4.5, 2.0)
]
let stealth_arrow_cmds = [
  MoveTo (0.0, 0.0); LineTo (-4.5, -1.8); LineTo (-3.0, 0.0);
  LineTo (-4.5, 1.8); ClosePath
]
let barbed_arrow_cmds = [
  MoveTo (0.0, 0.0);
  CurveTo (-2.0, -0.5, -3.5, -1.5, -4.5, -2.0);
  LineTo (-3.0, 0.0); LineTo (-4.5, 2.0);
  CurveTo (-3.5, 1.5, -2.0, 0.5, 0.0, 0.0);
  ClosePath
]
let half_arrow_upper_cmds = [
  MoveTo (0.0, 0.0); LineTo (-4.0, -2.0); LineTo (-4.0, 0.0); ClosePath
]
let half_arrow_lower_cmds = [
  MoveTo (0.0, 0.0); LineTo (-4.0, 0.0); LineTo (-4.0, 2.0); ClosePath
]

let circle_r = 2.0
let kk = 0.5522847498  (* bezier circle constant: 4/3 * (sqrt 2 - 1) *)
let circle_cmds = [
  MoveTo (0.0, 0.0);
  CurveTo (0.0, -. circle_r *. kk,
           -. circle_r +. circle_r *. kk, -. circle_r,
           -. circle_r, -. circle_r);
  CurveTo (-. circle_r -. circle_r *. kk, -. circle_r,
           -2.0 *. circle_r, -. circle_r *. kk,
           -2.0 *. circle_r, 0.0);
  CurveTo (-2.0 *. circle_r, circle_r *. kk,
           -. circle_r -. circle_r *. kk, circle_r,
           -. circle_r, circle_r);
  CurveTo (-. circle_r +. circle_r *. kk, circle_r,
           0.0, circle_r *. kk,
           0.0, 0.0);
  ClosePath
]
let square_cmds = [
  MoveTo (0.0, -2.0); LineTo (-4.0, -2.0); LineTo (-4.0, 2.0);
  LineTo (0.0, 2.0); ClosePath
]
let diamond_cmds = [
  MoveTo (0.0, 0.0); LineTo (-2.5, -2.0); LineTo (-5.0, 0.0);
  LineTo (-2.5, 2.0); ClosePath
]
let slash_cmds = [
  MoveTo (0.5, -2.0); LineTo (-0.5, 2.0)
]

let get_shape name =
  match name with
  | "none" | "" -> None
  | "simple_arrow"     -> Some { cmds = simple_arrow_cmds; style = Filled; back = 4.0 }
  | "open_arrow"       -> Some { cmds = open_arrow_cmds; style = Outline; back = 4.0 }
  | "closed_arrow"     -> Some { cmds = closed_arrow_cmds; style = Filled; back = 4.0 }
  | "stealth_arrow"    -> Some { cmds = stealth_arrow_cmds; style = Filled; back = 3.0 }
  | "barbed_arrow"     -> Some { cmds = barbed_arrow_cmds; style = Filled; back = 3.0 }
  | "half_arrow_upper" -> Some { cmds = half_arrow_upper_cmds; style = Filled; back = 4.0 }
  | "half_arrow_lower" -> Some { cmds = half_arrow_lower_cmds; style = Filled; back = 4.0 }
  | "circle"           -> Some { cmds = circle_cmds; style = Filled; back = 2.0 *. circle_r }
  | "open_circle"      -> Some { cmds = circle_cmds; style = Outline; back = 2.0 *. circle_r }
  | "square"           -> Some { cmds = square_cmds; style = Filled; back = 4.0 }
  | "open_square"      -> Some { cmds = square_cmds; style = Outline; back = 4.0 }
  | "diamond"          -> Some { cmds = diamond_cmds; style = Filled; back = 2.5 }
  | "open_diamond"     -> Some { cmds = diamond_cmds; style = Outline; back = 2.5 }
  | "slash"            -> Some { cmds = slash_cmds; style = Outline; back = 0.5 }
  | _ -> None

(** Get the path shortening distance for an arrowhead (in canvas pixels).
    Returns 0.0 if no arrowhead. *)
let arrow_setback name stroke_width scale_pct =
  match get_shape name with
  | Some shape -> shape.back *. stroke_width *. scale_pct /. 100.0
  | None -> 0.0

(** Collect significant points from path commands for tangent computation. *)
let collect_points cmds =
  let pts = ref [] in
  List.iter (fun cmd ->
    match cmd with
    | MoveTo (x, y) | LineTo (x, y) ->
      pts := (x, y) :: !pts
    | CurveTo (x1, y1, x2, y2, x, y) ->
      pts := (x, y) :: (x2, y2) :: (x1, y1) :: !pts
    | QuadTo (x1, y1, x, y) ->
      pts := (x, y) :: (x1, y1) :: !pts
    | SmoothCurveTo (x2, y2, x, y) ->
      pts := (x, y) :: (x2, y2) :: !pts
    | SmoothQuadTo (x, y) | ArcTo (_, _, _, _, _, x, y) ->
      pts := (x, y) :: !pts
    | ClosePath -> ()
  ) cmds;
  List.rev !pts

(** Compute tangent at the start of a path.
    Returns (x, y, angle) where angle points away from the path interior. *)
let start_tangent cmds =
  let pts = collect_points cmds in
  match pts with
  | [] -> (0.0, 0.0, 0.0)
  | (sx, sy) :: rest ->
    let threshold = 0.1 in
    let rec find = function
      | [] -> (sx, sy, Float.pi)
      | (nx, ny) :: tl ->
        let dx = sx -. nx in
        let dy = sy -. ny in
        if dx *. dx +. dy *. dy > threshold *. threshold then
          (sx, sy, atan2 dy dx)
        else find tl
    in
    find rest

(** Compute tangent at the end of a path.
    Returns (x, y, angle) where angle points along the path direction. *)
let end_tangent cmds =
  let pts = collect_points cmds in
  match pts with
  | [] -> (0.0, 0.0, 0.0)
  | _ ->
    let arr = Array.of_list pts in
    let n = Array.length arr in
    let (ex, ey) = arr.(n - 1) in
    let threshold = 0.1 in
    let rec find i =
      if i < 0 then (ex, ey, 0.0)
      else
        let (px, py) = arr.(i) in
        let dx = ex -. px in
        let dy = ey -. py in
        if dx *. dx +. dy *. dy > threshold *. threshold then
          (ex, ey, atan2 dy dx)
        else find (i - 1)
    in
    find (n - 2)

(** Shorten a path by moving start/end points inward along their tangent. *)
let shorten_path cmds start_setback end_setback =
  if cmds = [] then cmds
  else
    let result = Array.of_list cmds in
    let n = Array.length result in
    (* Shorten start *)
    if start_setback > 0.0 then begin
      let (sx, sy, angle) = start_tangent cmds in
      let dx = -. (cos angle) *. start_setback in
      let dy = -. (sin angle) *. start_setback in
      for i = 0 to n - 1 do
        match result.(i) with
        | MoveTo (x, y) when abs_float (x -. sx) < 1e-6 && abs_float (y -. sy) < 1e-6 ->
          result.(i) <- MoveTo (x +. dx, y +. dy)
        | _ -> ()
      done
    end;
    (* Shorten end *)
    if end_setback > 0.0 then begin
      let (ex, ey, angle) = end_tangent cmds in
      let dx = -. (cos angle) *. end_setback in
      let dy = -. (sin angle) *. end_setback in
      let found = ref false in
      for i = n - 1 downto 0 do
        if not !found then
          match result.(i) with
          | LineTo (x, y) when abs_float (x -. ex) < 1e-6 && abs_float (y -. ey) < 1e-6 ->
            result.(i) <- LineTo (x +. dx, y +. dy); found := true
          | CurveTo (x1, y1, x2, y2, x, y) when abs_float (x -. ex) < 1e-6 && abs_float (y -. ey) < 1e-6 ->
            result.(i) <- CurveTo (x1, y1, x2, y2, x +. dx, y +. dy); found := true
          | MoveTo (x, y) when abs_float (x -. ex) < 1e-6 && abs_float (y -. ey) < 1e-6 ->
            result.(i) <- MoveTo (x +. dx, y +. dy); found := true
          | _ -> ()
      done
    end;
    Array.to_list result

(** Build a Cairo path from PathCommand list. *)
let build_arrow_path cr cmds =
  List.iter (fun cmd ->
    match cmd with
    | MoveTo (x, y) -> Cairo.move_to cr x y
    | LineTo (x, y) -> Cairo.line_to cr x y
    | CurveTo (x1, y1, x2, y2, x, y) ->
      Cairo.curve_to cr x1 y1 x2 y2 x y
    | QuadTo (x1, y1, x, y) ->
      let (cx, cy) = Cairo.Path.get_current_point cr in
      let c1x = cx +. 2.0 /. 3.0 *. (x1 -. cx) in
      let c1y = cy +. 2.0 /. 3.0 *. (y1 -. cy) in
      let c2x = x +. 2.0 /. 3.0 *. (x1 -. x) in
      let c2y = y +. 2.0 /. 3.0 *. (y1 -. y) in
      Cairo.curve_to cr c1x c1y c2x c2y x y
    | ClosePath -> Cairo.Path.close cr
    | _ -> ()
  ) cmds

(** Draw a single arrowhead shape at the given position and angle. *)
let draw_one cr shape x y angle scale stroke_color center_at_end =
  if scale <= 0.0 then ()
  else begin
    Cairo.save cr;
    Cairo.translate cr x y;
    Cairo.rotate cr angle;
    if center_at_end then
      Cairo.translate cr (-2.0 *. scale) 0.0;
    Cairo.scale cr scale scale;
    Cairo.Path.clear cr;
    build_arrow_path cr shape.cmds;
    let (r, g, b, a) = stroke_color in
    (match shape.style with
    | Filled ->
      Cairo.set_source_rgba cr r g b a;
      Cairo.fill cr
    | Outline ->
      (* Fill with white first to mask the stroke line underneath *)
      Cairo.set_source_rgba cr 1.0 1.0 1.0 1.0;
      Cairo.fill_preserve cr;
      Cairo.set_source_rgba cr r g b a;
      Cairo.set_line_width cr (1.0 /. scale);
      Cairo.stroke cr);
    Cairo.restore cr
  end

(** Draw arrowheads for a path element. *)
let draw_arrowheads cr cmds start_name end_name start_scale end_scale
    stroke_width stroke_color center_at_end =
  (match get_shape start_name with
   | Some shape ->
     let (x, y, angle) = start_tangent cmds in
     let s = stroke_width *. start_scale /. 100.0 in
     draw_one cr shape x y angle s stroke_color center_at_end
   | None -> ());
  (match get_shape end_name with
   | Some shape ->
     let (x, y, angle) = end_tangent cmds in
     let s = stroke_width *. end_scale /. 100.0 in
     draw_one cr shape x y angle s stroke_color center_at_end
   | None -> ())

(** Draw arrowheads for a line element. *)
let draw_arrowheads_line cr x1 y1 x2 y2 start_name end_name
    start_scale end_scale stroke_width stroke_color center_at_end =
  let dx = x2 -. x1 in
  let dy = y2 -. y1 in
  let end_angle = atan2 dy dx in
  let start_angle = atan2 (y1 -. y2) (x1 -. x2) in
  (match get_shape start_name with
   | Some shape ->
     let s = stroke_width *. start_scale /. 100.0 in
     draw_one cr shape x1 y1 start_angle s stroke_color center_at_end
   | None -> ());
  (match get_shape end_name with
   | Some shape ->
     let s = stroke_width *. end_scale /. 100.0 in
     draw_one cr shape x2 y2 end_angle s stroke_color center_at_end
   | None -> ())
