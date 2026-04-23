(** Shape-geometry helpers for regular polygons and stars. *)

val star_inner_ratio : float

(** Compute vertices of a regular N-gon whose first edge runs from
    [(x1, y1)] to [(x2, y2)]. *)
val regular_polygon_points :
  float -> float -> float -> float -> int -> (float * float) list

(** Compute the [2 * points] vertices of a star inscribed in the
    axis-aligned bounding box between [(sx, sy)] and [(ex, ey)]. *)
val star_points :
  float -> float -> float -> float -> int -> (float * float) list
