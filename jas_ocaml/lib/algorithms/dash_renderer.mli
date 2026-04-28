(** Dash-alignment renderer for stroked paths.

    Pure function — port of [workspace_interpreter/dash_renderer.py]
    and [jas_dioxus/src/algorithms/dash_renderer.rs]. See
    [DASH_ALIGN.md] §Algorithm. Keep all four ports in lockstep.

    Phase 4 ships lines-only support ([MoveTo] / [LineTo] /
    [ClosePath]). Curve segments will join in a follow-up phase.

    Output: a list of sub-paths. Each sub-path is one solid dash;
    the caller draws each via the existing solid-stroke pipeline. *)

(** [expand_dashed_stroke path dash_array align_anchors] returns the
    list of solid sub-paths to draw. Each sub-path is a list of path
    commands ([MoveTo], [LineTo], etc.) representing one dash.
    Sub-paths are emitted in arc-length order along [path]. Returns
    an empty list when [path] has no drawable segments or
    [dash_array] is empty. Returns a single-element list containing
    the original path unchanged when [dash_array] is all zeros. *)
val expand_dashed_stroke :
  Element.path_command list -> float list -> bool ->
  Element.path_command list list
