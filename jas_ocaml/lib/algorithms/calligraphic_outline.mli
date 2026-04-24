(* Variable-width outline of a path stroked with a Calligraphic
   brush. Faithful port of jas_dioxus/src/algorithms/calligraphic_outline.rs
   and jas_flask/static/js/engine/geometry.mjs's calligraphicOutline.

   Per BRUSHES.md Calligraphic section. Phase 1 limits: only the
   fixed variation mode is honoured; multi-subpath paths render the
   first subpath only. *)

type t = {
  angle : float;     (* degrees, screen-fixed orientation of major axis *)
  roundness : float; (* 0 to 100; 100 = circular *)
  size : float;      (* pt; major-axis length *)
}

val outline : Element.path_command list -> t -> (float * float) list
(* Returns the closed polygon's points in (x, y) order, going forward
   along the left-offset and back along the right-offset. Returns []
   on degenerate input (no segments, single MoveTo, zero-area sweep). *)
