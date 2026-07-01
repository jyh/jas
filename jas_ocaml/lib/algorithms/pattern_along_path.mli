(* Pattern brush: side artwork tile repeated along the stroke path.
   Port of jas_dioxus/src/algorithms/pattern_along_path.rs (BRUSHES.md
   §Brush types > Pattern). Phase 1: SIDE tile only (corner tiles need
   path-corner classification, deferred); polygon artwork; first subpath. *)

type t = {
  tile_width : float;
  tile_height : float;
  side : (float * float) list list;  (* side-tile polygons in tile coords *)
  scale : float;                     (* percent *)
  spacing : float;                   (* percent of tile width *)
  flip_across : bool;
  flip_along : bool;
  stroke_weight : float;             (* pt *)
}

val tile : Element.path_command list -> t -> (float * float) list list
(* One warped polygon per (tile placement * side polygon); [] on
   degenerate input. *)
