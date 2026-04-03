(** Immutable document elements for the Jas illustration app.

    All elements are immutable value types. To modify an element, create a new
    one with the desired changes. *)

(** A 2D point. *)
type point = {
  x : float;
  y : float;
}

(** RGBA color with components in [0, 1]. *)
type color = {
  r : float;
  g : float;
  b : float;
  a : float;
}

(** Stroke alignment relative to the path. *)
type stroke_alignment =
  | Center
  | Inside
  | Outside

(** Fill style for a closed path. *)
type fill = {
  fill_color : color;
}

(** Stroke style for a path. *)
type stroke = {
  stroke_color : color;
  stroke_width : float;
  stroke_alignment : stroke_alignment;
}

(** An anchor point on a path, with optional control handles for curves. *)
type anchor_point = {
  position : point;
  handle_in : point option;
  handle_out : point option;
}

(** A vector path defined by anchor points. *)
type path = {
  anchors : anchor_point list;
  closed : bool;
  path_fill : fill option;
  path_stroke : stroke option;
}

(** A rectangle defined by origin and size. *)
type rect = {
  origin : point;
  width : float;
  height : float;
  rect_fill : fill option;
  rect_stroke : stroke option;
}

(** An ellipse defined by center and radii. *)
type ellipse = {
  center : point;
  rx : float;
  ry : float;
  ellipse_fill : fill option;
  ellipse_stroke : stroke option;
}

(** A document element. All elements are immutable. *)
type element =
  | Path of path
  | Rect of rect
  | Ellipse of ellipse
  | Group of element list

(** Return the bounding box as (top_left, bottom_right). *)
let rec bounds = function
  | Path { anchors; _ } ->
    begin match anchors with
    | [] -> ({ x = 0.0; y = 0.0 }, { x = 0.0; y = 0.0 })
    | _ ->
      let xs = List.map (fun a -> a.position.x) anchors in
      let ys = List.map (fun a -> a.position.y) anchors in
      let min_f = List.fold_left min infinity in
      let max_f = List.fold_left max neg_infinity in
      ({ x = min_f xs; y = min_f ys },
       { x = max_f xs; y = max_f ys })
    end
  | Rect { origin; width; height; _ } ->
    (origin, { x = origin.x +. width; y = origin.y +. height })
  | Ellipse { center; rx; ry; _ } ->
    ({ x = center.x -. rx; y = center.y -. ry },
     { x = center.x +. rx; y = center.y +. ry })
  | Group children ->
    begin match children with
    | [] -> ({ x = 0.0; y = 0.0 }, { x = 0.0; y = 0.0 })
    | _ ->
      let all_bounds = List.map bounds children in
      let min_x = List.fold_left (fun acc (tl, _) -> min acc tl.x) infinity all_bounds in
      let min_y = List.fold_left (fun acc (tl, _) -> min acc tl.y) infinity all_bounds in
      let max_x = List.fold_left (fun acc (_, br) -> max acc br.x) neg_infinity all_bounds in
      let max_y = List.fold_left (fun acc (_, br) -> max acc br.y) neg_infinity all_bounds in
      ({ x = min_x; y = min_y }, { x = max_x; y = max_y })
    end

(** Helper constructors. *)

let make_color ?(a = 1.0) r g b = { r; g; b; a }

let make_point x y = { x; y }

let make_fill color = { fill_color = color }

let make_stroke ?(width = 1.0) ?(alignment = Center) color =
  { stroke_color = color; stroke_width = width; stroke_alignment = alignment }

let make_anchor ?(handle_in = None) ?(handle_out = None) position =
  { position; handle_in; handle_out }
