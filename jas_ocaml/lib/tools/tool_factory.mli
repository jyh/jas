(** Factory for creating tool instances from toolbar enum values. *)

val create_tool : Toolbar.tool -> Canvas_tool.canvas_tool
(** Construct a fresh instance of the canvas tool corresponding to
    [tool]. Each call returns a new object — tools that hold mutable
    drag/edit state should not be shared between canvases. *)
