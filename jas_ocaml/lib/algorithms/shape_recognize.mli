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

val shape_kind : recognized_shape -> shape_kind

type recognize_config = {
  tolerance : float;
  close_gap_frac : float;
  corner_angle_deg : float;
  square_aspect_eps : float;
  circle_eccentricity_eps : float;
  resample_n : int;
}

val default_config : recognize_config

val recognize : pt list -> recognize_config -> recognized_shape option

val recognize_path : Element.path_command list -> recognize_config -> recognized_shape option

val recognize_element : Element.element -> recognize_config -> (shape_kind * Element.element) option

val recognized_to_element : recognized_shape -> Element.element -> Element.element
