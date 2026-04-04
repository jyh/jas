(** Immutable document elements conforming to SVG element types. *)

(** RGBA color with components in [0, 1]. *)
type color = {
  r : float;
  g : float;
  b : float;
  a : float;
}

(** SVG stroke-linecap. *)
type linecap = Butt | Round_cap | Square

(** SVG stroke-linejoin. *)
type linejoin = Miter | Round_join | Bevel

(** SVG fill presentation attribute. *)
type fill = { fill_color : color }

(** SVG stroke presentation attributes. *)
type stroke = {
  stroke_color : color;
  stroke_width : float;
  stroke_linecap : linecap;
  stroke_linejoin : linejoin;
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
      text_width : float;
      text_height : float;
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
val bounds : element -> float * float * float * float

(** {2 Helper constructors} *)

val make_color : ?a:float -> float -> float -> float -> color
val make_fill : color -> fill
val make_stroke : ?width:float -> ?linecap:linecap -> ?linejoin:linejoin -> color -> stroke
val identity_transform : transform
val make_translate : float -> float -> transform
val make_scale : float -> float -> transform
val make_rotate : float -> transform
val make_line : ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> float -> float -> float -> float -> element
val make_rect : ?rx:float -> ?ry:float -> ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> float -> float -> float -> float -> element
val make_circle : ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> float -> float -> float -> element
val make_ellipse : ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> float -> float -> float -> float -> element
val make_polyline : ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> (float * float) list -> element
val make_polygon : ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> (float * float) list -> element
val make_path : ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> path_command list -> element
val make_text : ?font_family:string -> ?font_size:float -> ?text_width:float -> ?text_height:float -> ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> float -> float -> string -> element
val make_group : ?opacity:float -> ?transform:transform option -> element list -> element
val make_layer : ?name:string -> ?opacity:float -> ?transform:transform option -> element list -> element

(** {2 Control points} *)

val control_point_count : element -> int
val control_points : element -> (float * float) list
val move_control_points : element -> int list -> float -> float -> element
