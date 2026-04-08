(** Boolean operations on planar polygons. *)

type point = float * float
type ring = point array
type polygon_set = ring list

val boolean_union : polygon_set -> polygon_set -> polygon_set
val boolean_intersect : polygon_set -> polygon_set -> polygon_set
val boolean_subtract : polygon_set -> polygon_set -> polygon_set
val boolean_exclude : polygon_set -> polygon_set -> polygon_set

(** Hook for the ring normalizer. Set by [Boolean_normalize] at module
    init time. *)
val normalize_hook : (polygon_set -> polygon_set) ref

(** Project [p] onto the segment [a -> b], clamped to the segment
    endpoints. Exposed for testing. *)
val project_onto_segment : point -> point -> point -> point
