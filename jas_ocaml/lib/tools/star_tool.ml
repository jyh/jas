(** Star tool: drag to draw an N-pointed star inscribed in the bounding box. *)

(** Default number of outer vertices for new stars. *)
let star_points = 5

(** Ratio of inner radius to outer radius for stars. *)
let star_inner_ratio = 0.4

(** Compute vertices of a star inscribed in the given bounding box. The star
    has [n] outer vertices alternating with [n] inner vertices, for [2 * n]
    total. The first outer vertex is at the top of the box. *)
let compute_star_points sx sy ex ey n =
  let cx = (sx +. ex) /. 2.0 in
  let cy = (sy +. ey) /. 2.0 in
  let rx_outer = abs_float (ex -. sx) /. 2.0 in
  let ry_outer = abs_float (ey -. sy) /. 2.0 in
  let rx_inner = rx_outer *. star_inner_ratio in
  let ry_inner = ry_outer *. star_inner_ratio in
  let theta0 = -. Float.pi /. 2.0 in
  List.init (2 * n) (fun k ->
    let angle = theta0 +. Float.pi *. float_of_int k /. float_of_int n in
    let rx = if k mod 2 = 0 then rx_outer else rx_inner in
    let ry = if k mod 2 = 0 then ry_outer else ry_inner in
    (cx +. rx *. cos angle, cy +. ry *. sin angle))

class star_tool = object
  inherit Drawing_tool.drawing_tool_base

  method private create_element (ctx : Canvas_tool.tool_context) sx sy ex ey =
    if abs_float (ex -. sx) <= 0.0 || abs_float (ey -. sy) <= 0.0 then None
    else
      let pts = compute_star_points sx sy ex ey star_points in
      Some (Element.Polygon {
        points = pts;
        fill = ctx.model#default_fill; stroke = ctx.model#default_stroke;
        opacity = 1.0; transform = None; locked = false; visibility = Preview;
      })

  method private draw_preview cr sx sy ex ey =
    let pts = compute_star_points sx sy ex ey star_points in
    match pts with
    | (fx, fy) :: rest ->
      Cairo.move_to cr fx fy;
      List.iter (fun (px, py) -> Cairo.line_to cr px py) rest;
      Cairo.Path.close cr
    | [] -> ()
end
