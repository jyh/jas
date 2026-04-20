(** Boolean panel apply pipeline. Dispatches the three compound-
    shape menu entries (Make / Release / Expand) on the given
    [Model.model]. No-op when preconditions aren't met (e.g. fewer
    than 2 selected for Make; no selected compound shapes for
    Release / Expand). *)

val apply_make_compound_shape : Model.model -> unit

val apply_release_compound_shape : Model.model -> unit

val apply_expand_compound_shape : Model.model -> unit

(** Destructively apply one of the six implemented boolean ops to the
    current selection. Supported names: [union], [intersection],
    [exclude], [subtract_front], [subtract_back], [crop]. Unknown ops
    are no-ops. DIVIDE / TRIM / MERGE ship in phase 9e. See
    [transcripts/BOOLEAN.md] §Operand and paint rules. *)
val apply_destructive_boolean : Model.model -> string -> unit
