(** Polyline-to-Bezier simplification with corner detection.

    Wraps [Fit_curve.fit_curve] (Schneider 1990) so it can be applied to
    a closed or open polyline that mixes straight runs and smooth arcs.
    The wrapper:

    1. Detects corners — vertices where the direction change exceeds
       [corner_angle_threshold] (default 30 degrees). Boolean operation
       outputs preserve original sharp corners but flatten arcs into many
       short segments; fitting one curve across a corner would round it
       off, so corners must split the polyline into per-segment runs
       before fitting.
    2. For each run between corners, calls [Fit_curve.fit_curve] with the
       supplied error tolerance. A run of two points emits a single
       [LineTo]; longer runs emit one or more [CurveTo] segments.
    3. Re-stitches the run outputs into a single path-command sequence,
       closing with [ClosePath] when the input was a closed ring.

    Mirrors jas_dioxus/src/algorithms/simplify.rs. *)

(** Default corner angle threshold: 30 degrees, in radians. *)
val default_corner_angle : float

(** Simplify a polyline to a Bezier-rich path-command sequence.

    [points] is the polyline (no duplicate closing vertex). [precision]
    is the Schneider max-error tolerance in document units (typically
    points). [closed] controls whether the wraparound seam can become a
    corner and whether the output ends with [ClosePath].

    Returns a sequence starting with [MoveTo] and ending with (for closed
    inputs) [ClosePath]. Returns an empty list when fewer than 2 points
    are supplied. *)
val simplify_polyline :
  (float * float) list -> float -> bool -> Element.path_command list

(** [simplify_polyline] with an explicit corner-angle threshold, in
    radians. Useful for tests and future tuning surfaces. *)
val simplify_polyline_with_angle :
  (float * float) list -> float -> bool -> float ->
  Element.path_command list

(** Return indices of corner vertices. A corner is a vertex where the
    direction change between the incoming and outgoing edges exceeds
    [angle_threshold] radians. For [closed] inputs, the wraparound seam
    (vertex 0) is treated like any other interior vertex; for open
    inputs, endpoints (index 0 and n-1) are never corners. Exposed for
    testing. *)
val detect_corners : (float * float) list -> float -> bool -> int list
