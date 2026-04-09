(** Geometry helpers for precise hit-testing. *)

val point_in_rect : float -> float -> float -> float -> float -> float -> bool
val segments_intersect : float -> float -> float -> float -> float -> float -> float -> float -> bool
val segment_intersects_rect : float -> float -> float -> float -> float -> float -> float -> float -> bool
val rects_intersect : float -> float -> float -> float -> float -> float -> float -> float -> bool
val circle_intersects_rect : float -> float -> float -> float -> float -> float -> float -> bool -> bool
val ellipse_intersects_rect : float -> float -> float -> float -> float -> float -> float -> float -> bool -> bool
val segments_of_element : Element.element -> (float * float * float * float) list
val all_cps : Element.element -> int list
val element_intersects_rect : Element.element -> float -> float -> float -> float -> bool
val point_in_polygon : float -> float -> (float * float) array -> bool
val segment_intersects_polygon : float -> float -> float -> float -> (float * float) array -> bool
val element_intersects_polygon : Element.element -> (float * float) array -> bool
