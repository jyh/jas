(** Brush library registry shared between the canvas renderer and
    the brush.* effect handlers. Lives in its own module to avoid a
    dependency cycle (yaml_tool_effects → canvas_subwindow → ...).

    Carries the current brush_libraries JSON (loaded from
    workspace, possibly mutated by brush.* effects) and a callback
    invoked after each mutation so the canvas can re-register its
    drawing-time copy. *)

val set : Yojson.Safe.t -> unit
(** Replace the current libraries and fire any registered listener. *)

val get : unit -> Yojson.Safe.t

val on_change : (Yojson.Safe.t -> unit) -> unit
(** Install a single change listener (replaces any prior). The
    canvas subwindow installs its set_brush_libraries here at app
    startup; the brush.* effects fire it on every mutation. *)
