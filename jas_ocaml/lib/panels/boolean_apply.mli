(** Boolean panel apply pipeline. Dispatches the three compound-
    shape menu entries (Make / Release / Expand) on the given
    [Model.model]. No-op when preconditions aren't met (e.g. fewer
    than 2 selected for Make; no selected compound shapes for
    Release / Expand). *)

val apply_make_compound_shape : Model.model -> unit

(** Alt/Option+click on the four Shape Mode buttons. Creates a live
    compound shape with the chosen operation (union / subtract_front
    / intersection / exclude) instead of applying the destructive
    variant. Unknown op names are no-ops. See [transcripts/BOOLEAN.md]
    §Compound shapes. *)
val apply_compound_creation : Model.model -> string -> unit

val apply_release_compound_shape : Model.model -> unit

val apply_expand_compound_shape : Model.model -> unit

(** Destructively apply one of the six implemented boolean ops to the
    current selection. Supported names: [union], [intersection],
    [exclude], [subtract_front], [subtract_back], [crop]. Unknown ops
    are no-ops. DIVIDE / TRIM / MERGE ship in phase 9e. See
    [transcripts/BOOLEAN.md] §Operand and paint rules. *)
val apply_destructive_boolean : Model.model -> string -> unit
