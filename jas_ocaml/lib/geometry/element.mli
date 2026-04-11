(** Immutable document elements conforming to SVG element types. *)

(** Line segments per Bezier curve when flattening paths. *)
val flatten_steps : int

(** Average character width as a fraction of font size. *)
val approx_char_width_factor : float

(** Color with support for RGB, HSB, and CMYK color spaces. *)
type color =
  | Rgb of { r : float; g : float; b : float; a : float }
  | Hsb of { h : float; s : float; b : float; a : float }
  | Cmyk of { c : float; m : float; y : float; k : float; a : float }

(** Convenience constructors for opaque colors. *)
val color_rgb : float -> float -> float -> color
val color_hsb : float -> float -> float -> color
val color_cmyk : float -> float -> float -> float -> color

(** Common color constants. *)
val black : color
val white : color

(** Alpha component, regardless of color space. *)
val color_alpha : color -> float

(** Return a copy of this color with the alpha component replaced. *)
val color_with_alpha : float -> color -> color

(** Convert any color to (r, g, b, a). *)
val color_to_rgba : color -> float * float * float * float

(** Convert any color to (h, s, b, a). *)
val color_to_hsba : color -> float * float * float * float

(** Convert any color to (c, m, y, k, a). *)
val color_to_cmyka : color -> float * float * float * float * float

(** Per-element visibility mode.

    Declaration order is chosen so that [compare] and [min] treat
    [Invisible] as the smallest and [Preview] as the largest —
    [min a b] therefore picks the more restrictive mode. That is
    the rule used to combine an element's own visibility with the
    cap inherited from its parent Group or Layer. *)
type visibility = Invisible | Outline | Preview

(** SVG stroke-linecap. *)
type linecap = Butt | Round_cap | Square

(** SVG stroke-linejoin. *)
type linejoin = Miter | Round_join | Bevel

(** SVG fill presentation attribute. *)
type fill = { fill_color : color; fill_opacity : float }

(** SVG stroke presentation attributes. *)
type stroke = {
  stroke_color : color;
  stroke_width : float;
  stroke_linecap : linecap;
  stroke_linejoin : linejoin;
  stroke_opacity : float;
}

(** SVG transform as a 2D affine matrix [a b c d e f]. *)
type transform = {
  a : float; b : float; c : float;
  d : float; e : float; f : float;
}

(** SVG path commands (the 'd' attribute). *)
type path_command =
  | MoveTo of float * float
  | LineTo of float * float
  | CurveTo of float * float * float * float * float * float
  | SmoothCurveTo of float * float * float * float
  | QuadTo of float * float * float * float
  | SmoothQuadTo of float * float
  | ArcTo of float * float * float * bool * bool * float * float
  | ClosePath

(** SVG element types. All elements are immutable. *)
type element =
  | Line of {
      x1 : float; y1 : float;
      x2 : float; y2 : float;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Rect of {
      x : float; y : float;
      width : float; height : float;
      rx : float; ry : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Circle of {
      cx : float; cy : float; r : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Ellipse of {
      cx : float; cy : float;
      rx : float; ry : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Polyline of {
      points : (float * float) list;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Polygon of {
      points : (float * float) list;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Path of {
      d : path_command list;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Text of {
      x : float; y : float;
      content : string;
      font_family : string;
      font_size : float;
      font_weight : string;
      font_style : string;
      text_decoration : string;
      text_width : float;
      text_height : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Text_path of {
      d : path_command list;
      content : string;
      start_offset : float;
      font_family : string;
      font_size : float;
      font_weight : string;
      font_style : string;
      text_decoration : string;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Group of {
      children : element array;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Layer of {
      name : string;
      children : element array;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }

(** Return the bounding box as (x, y, width, height). *)
val bounds : element -> float * float * float * float

(** {2 Helper constructors} *)

val make_color : ?a:float -> float -> float -> float -> color
val make_fill : ?opacity:float -> color -> fill
val make_stroke : ?width:float -> ?linecap:linecap -> ?linejoin:linejoin -> ?opacity:float -> color -> stroke
val identity_transform : transform
val make_translate : float -> float -> transform
val make_scale : float -> float -> transform
val make_rotate : float -> transform
val apply_point : transform -> float -> float -> float * float
val inverse : transform -> transform option
val transform_of : element -> transform option
val make_line : ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> float -> float -> float -> float -> element
val make_rect : ?rx:float -> ?ry:float -> ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> float -> float -> float -> float -> element
val make_circle : ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> float -> float -> float -> element
val make_ellipse : ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> float -> float -> float -> float -> element
val make_polyline : ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> (float * float) list -> element
val make_polygon : ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> (float * float) list -> element
val make_path : ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> path_command list -> element
val make_text : ?font_family:string -> ?font_size:float -> ?font_weight:string -> ?font_style:string -> ?text_decoration:string -> ?text_width:float -> ?text_height:float -> ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> float -> float -> string -> element
val make_text_path : ?start_offset:float -> ?font_family:string -> ?font_size:float -> ?font_weight:string -> ?font_style:string -> ?text_decoration:string -> ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> path_command list -> string -> element
val make_group : ?opacity:float -> ?transform:transform option -> ?locked:bool -> element array -> element
val make_layer : ?name:string -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> element array -> element

(** {2 Lock state} *)

val is_locked : element -> bool
val set_locked : bool -> element -> element

(** {2 Visibility} *)

val get_visibility : element -> visibility
val set_visibility : visibility -> element -> element

(** {2 Control points} *)

val path_handle_positions : path_command list -> int ->
  (float * float) option * (float * float) option
val move_path_handle : path_command list -> int -> string -> float -> float ->
  path_command list
val move_path_handle_independent :
  path_command list -> int -> string -> float -> float -> path_command list
val is_smooth_point : path_command list -> int -> bool
val convert_corner_to_smooth :
  path_command list -> int -> float -> float -> path_command list
val convert_smooth_to_corner : path_command list -> int -> path_command list
val control_point_count : element -> int
val control_points : element -> (float * float) list

val move_control_points :
  ?is_all:bool -> element -> int list -> float -> float -> element
(** Move the listed control points by [(dx, dy)]. Pass [~is_all:true]
    to indicate that the element is selected as a whole — this lets
    Rect/Circle/Ellipse translate in place instead of converting to a
    Polygon. *)

(** {2 Path geometry utilities} *)

val flatten_path_commands : path_command list -> (float * float) list
val path_point_at_offset : path_command list -> float -> float * float
val path_closest_offset : path_command list -> float -> float -> float
val path_distance_to_point : path_command list -> float -> float -> float
