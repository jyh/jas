(** Shape-geometry helpers for regular polygons and stars — the OCaml
    analogue of [jas_dioxus/src/geometry/regular_shapes.rs] and
    [JasSwift/Sources/Geometry/RegularShapes.swift].

    L2 primitives per NATIVE_BOUNDARY.md §5: shape geometry is shared
    across vector-illustration apps, not app-specific behavior. *)

(** Ratio of inner radius to outer radius for the default star. *)
let star_inner_ratio : float = 0.4

(** Compute vertices of a regular N-gon whose first edge runs from
    [(x1, y1)] to [(x2, y2)]. Returns [n] points. For degenerate
    zero-length edges returns [n] copies of the start point. *)
let regular_polygon_points x1 y1 x2 y2 n =
  let ex = x2 -. x1 and ey = y2 -. y1 in
  let s = Float.sqrt (ex *. ex +. ey *. ey) in
  if s = 0.0 then
    List.init n (fun _ -> (x1, y1))
  else
    let mx = (x1 +. x2) /. 2.0 and my = (y1 +. y2) /. 2.0 in
    let px = -. ey /. s and py = ex /. s in
    let d = s /. (2.0 *. Float.tan (Float.pi /. float_of_int n)) in
    let cx = mx +. d *. px and cy = my +. d *. py in
    let r = s /. (2.0 *. Float.sin (Float.pi /. float_of_int n)) in
    let theta0 = Float.atan2 (y1 -. cy) (x1 -. cx) in
    List.init n (fun k ->
      let angle = theta0 +. 2.0 *. Float.pi *. float_of_int k /. float_of_int n in
      (cx +. r *. Float.cos angle, cy +. r *. Float.sin angle))

(** Compute vertices of a star inscribed in the axis-aligned bounding
    box with corners [(sx, sy)] and [(ex, ey)]. [points] is the number
    of outer vertices; the returned list alternates outer / inner
    points for [2 * points] total. First outer point sits at top-center. *)
let star_points sx sy ex ey points =
  let cx = (sx +. ex) /. 2.0 and cy = (sy +. ey) /. 2.0 in
  let rx_outer = Float.abs (ex -. sx) /. 2.0 in
  let ry_outer = Float.abs (ey -. sy) /. 2.0 in
  let rx_inner = rx_outer *. star_inner_ratio in
  let ry_inner = ry_outer *. star_inner_ratio in
  let n = points * 2 in
  let theta0 = -. Float.pi /. 2.0 in
  List.init n (fun k ->
    let angle = theta0 +. Float.pi *. float_of_int k /. float_of_int points in
    let (rx, ry) =
      if k mod 2 = 0 then (rx_outer, ry_outer)
      else (rx_inner, ry_inner)
    in
    (cx +. rx *. Float.cos angle, cy +. ry *. Float.sin angle))
