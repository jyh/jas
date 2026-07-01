(* Bristle brush: N semi-transparent bristle lines spread across the brush
   width, each following the path at a fixed perpendicular offset. Port of
   jas_dioxus/src/algorithms/bristle_stroke.rs (BRUSHES.md §Brush types >
   Bristle). The caller strokes each polyline in the stroke colour with
   [alpha] / [line_width]. Phase 1: straight offset bristles, first subpath. *)

type t = {
  size : float;      (* diameter at 1 pt stroke *)
  density : float;   (* percent -> bristle count *)
  thickness : float; (* percent -> per-bristle line width *)
  opacity : float;   (* percent -> per-bristle alpha *)
  stroke_weight : float; (* pt *)
}

val count : t -> int          (* bristle count, 2..12 *)
val line_width : t -> float    (* per-bristle line width (min 0.5) *)
val alpha : t -> float         (* per-bristle stroke alpha (0..1) *)

val stroke : Element.path_command list -> t -> (float * float) list list
(* One polyline per bristle; [] on degenerate input. *)
