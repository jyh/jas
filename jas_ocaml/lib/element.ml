(** Immutable document elements conforming to SVG element types.

    All elements are immutable value types. Element types and attributes
    follow the SVG 1.1 specification. *)

(** RGBA color with components in [0, 1]. *)
type color = {
  r : float;
  g : float;
  b : float;
  a : float;
}

(** SVG stroke-linecap. *)
type linecap =
  | Butt
  | Round_cap
  | Square

(** SVG stroke-linejoin. *)
type linejoin =
  | Miter
  | Round_join
  | Bevel

(** SVG fill presentation attribute. *)
type fill = {
  fill_color : color;
}

(** SVG stroke presentation attributes. *)
type stroke = {
  stroke_color : color;
  stroke_width : float;
  stroke_linecap : linecap;
  stroke_linejoin : linejoin;
}

(** SVG transform as a 2D affine matrix [a b c d e f]. *)
type transform = {
  a : float;
  b : float;
  c : float;
  d : float;
  e : float;
  f : float;
}

(** SVG path commands (the 'd' attribute). *)
type path_command =
  | MoveTo of float * float                                       (** M x y *)
  | LineTo of float * float                                       (** L x y *)
  | CurveTo of float * float * float * float * float * float      (** C x1 y1 x2 y2 x y *)
  | SmoothCurveTo of float * float * float * float                (** S x2 y2 x y *)
  | QuadTo of float * float * float * float                       (** Q x1 y1 x y *)
  | SmoothQuadTo of float * float                                 (** T x y *)
  | ArcTo of float * float * float * bool * bool * float * float  (** A rx ry rot large sweep x y *)
  | ClosePath                                                     (** Z *)

(** SVG element types. All elements are immutable. *)
type element =
  | Line of {
      x1 : float; y1 : float;
      x2 : float; y2 : float;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
    }
  | Rect of {
      x : float; y : float;
      width : float; height : float;
      rx : float; ry : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
    }
  | Circle of {
      cx : float; cy : float; r : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
    }
  | Ellipse of {
      cx : float; cy : float;
      rx : float; ry : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
    }
  | Polyline of {
      points : (float * float) list;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
    }
  | Polygon of {
      points : (float * float) list;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
    }
  | Path of {
      d : path_command list;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
    }
  | Text of {
      x : float; y : float;
      content : string;
      font_family : string;
      font_size : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
    }
  | Group of {
      children : element list;
      opacity : float;
      transform : transform option;
    }
  | Layer of {
      name : string;
      children : element list;
      opacity : float;
      transform : transform option;
    }

(** Return the bounding box as (x, y, width, height). *)
let rec bounds = function
  | Line { x1; y1; x2; y2; _ } ->
    let min_x = min x1 x2 in
    let min_y = min y1 y2 in
    (min_x, min_y, abs_float (x2 -. x1), abs_float (y2 -. y1))
  | Rect { x; y; width; height; _ } ->
    (x, y, width, height)
  | Circle { cx; cy; r; _ } ->
    (cx -. r, cy -. r, r *. 2.0, r *. 2.0)
  | Ellipse { cx; cy; rx; ry; _ } ->
    (cx -. rx, cy -. ry, rx *. 2.0, ry *. 2.0)
  | Polyline { points; _ } | Polygon { points; _ } ->
    begin match points with
    | [] -> (0.0, 0.0, 0.0, 0.0)
    | _ ->
      let xs = List.map fst points in
      let ys = List.map snd points in
      let min_f = List.fold_left min infinity in
      let max_f = List.fold_left max neg_infinity in
      let min_x = min_f xs and min_y = min_f ys in
      (min_x, min_y, max_f xs -. min_x, max_f ys -. min_y)
    end
  | Path { d; _ } ->
    let collect_endpoints cmds =
      List.fold_left (fun (xs, ys) cmd ->
        match cmd with
        | MoveTo (x, y) | LineTo (x, y) | SmoothQuadTo (x, y) ->
          (x :: xs, y :: ys)
        | CurveTo (_, _, _, _, x, y) | SmoothCurveTo (_, _, x, y) ->
          (x :: xs, y :: ys)
        | QuadTo (_, _, x, y) ->
          (x :: xs, y :: ys)
        | ArcTo (_, _, _, _, _, x, y) ->
          (x :: xs, y :: ys)
        | ClosePath -> (xs, ys)
      ) ([], []) cmds
    in
    let (xs, ys) = collect_endpoints d in
    begin match xs, ys with
    | [], [] -> (0.0, 0.0, 0.0, 0.0)
    | _ ->
      let min_f = List.fold_left min infinity in
      let max_f = List.fold_left max neg_infinity in
      let min_x = min_f xs and min_y = min_f ys in
      (min_x, min_y, max_f xs -. min_x, max_f ys -. min_y)
    end
  | Text { x; y; content; font_size; _ } ->
    let approx_width = float_of_int (String.length content) *. font_size *. 0.6 in
    (x, y -. font_size, approx_width, font_size)
  | Group { children; _ } | Layer { children; _ } ->
    begin match children with
    | [] -> (0.0, 0.0, 0.0, 0.0)
    | _ ->
      let all_bounds = List.map bounds children in
      let min_x = List.fold_left (fun acc (x, _, _, _) -> min acc x) infinity all_bounds in
      let min_y = List.fold_left (fun acc (_, y, _, _) -> min acc y) infinity all_bounds in
      let max_x = List.fold_left (fun acc (x, _, w, _) -> max acc (x +. w)) neg_infinity all_bounds in
      let max_y = List.fold_left (fun acc (_, y, _, h) -> max acc (y +. h)) neg_infinity all_bounds in
      (min_x, min_y, max_x -. min_x, max_y -. min_y)
    end

(** Helper constructors. *)

let make_color ?(a = 1.0) r g b = { r; g; b; a }

let make_fill color = { fill_color = color }

let make_stroke ?(width = 1.0) ?(linecap = Butt) ?(linejoin = Miter) color =
  { stroke_color = color; stroke_width = width; stroke_linecap = linecap; stroke_linejoin = linejoin }

let identity_transform = { a = 1.0; b = 0.0; c = 0.0; d = 1.0; e = 0.0; f = 0.0 }

let make_translate tx ty = { identity_transform with e = tx; f = ty }

let make_scale sx sy = { identity_transform with a = sx; d = sy }

let make_rotate angle_deg =
  let rad = angle_deg *. Float.pi /. 180.0 in
  { identity_transform with a = cos rad; b = sin rad; c = -. sin rad; d = cos rad }

let make_line ?(stroke = None) ?(opacity = 1.0) ?(transform = None) x1 y1 x2 y2 =
  Line { x1; y1; x2; y2; stroke; opacity; transform }

let make_rect ?(rx = 0.0) ?(ry = 0.0) ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) x y width height =
  Rect { x; y; width; height; rx; ry; fill; stroke; opacity; transform }

let make_circle ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) cx cy r =
  Circle { cx; cy; r; fill; stroke; opacity; transform }

let make_ellipse ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) cx cy rx ry =
  Ellipse { cx; cy; rx; ry; fill; stroke; opacity; transform }

let make_polyline ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) points =
  Polyline { points; fill; stroke; opacity; transform }

let make_polygon ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) points =
  Polygon { points; fill; stroke; opacity; transform }

let make_path ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) d =
  Path { d; fill; stroke; opacity; transform }

let make_text ?(font_family = "sans-serif") ?(font_size = 16.0) ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) x y content =
  Text { x; y; content; font_family; font_size; fill; stroke; opacity; transform }

let make_group ?(opacity = 1.0) ?(transform = None) children =
  Group { children; opacity; transform }

let make_layer ?(name = "Layer") ?(opacity = 1.0) ?(transform = None) children =
  Layer { name; children; opacity; transform }

let control_point_count = function
  | Line _ -> 2
  | Rect _ | Circle _ | Ellipse _ -> 4
  | _ -> 4
