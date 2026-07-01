(* Art brush: one vector artwork stretched along the stroke path.
   Port of jas_dioxus/src/algorithms/art_along_path.rs (BRUSHES.md
   §Brush types > Art).

   The artwork is a set of closed polygons in artwork coordinates
   (x in [0, width], y in [0, height]); it is warped onto the path so
   the artwork x-axis maps to arc-length (0 to start, width to end) and
   the y-axis maps to the perpendicular offset, centred on the path and
   scaled to the ribbon height = (scale / 100) *. stroke_weight.
   [flip_along] reverses the arc-length mapping; [flip_across] mirrors the
   offset. Phase 1: polygon artwork only, first subpath only, proportional
   scale (artwork stretches to the full path length). *)

type t = {
  artwork_width : float;
  artwork_height : float;
  artwork : (float * float) list list;  (* closed polygons in artwork coords *)
  scale : float;                        (* percent *)
  flip_across : bool;
  flip_along : bool;
  stroke_weight : float;                (* pt *)
}

val warp : Element.path_command list -> t -> (float * float) list list
(* One warped polygon per artwork polygon; [] on degenerate input. *)

val flatten : Element.path_command list -> (float * float) array
(* Flatten the first subpath into a polyline. Shared with pattern /
   bristle brushes. *)

val point_at_arclength :
  (float * float) array -> float array -> float -> float -> float * float * float
(* Point (x, y) and tangent (radians) at arc-length [s]; args are the
   flattened points, their cumulative arc-lengths, the total length, and
   [s]. Shared with pattern / bristle brushes. *)
