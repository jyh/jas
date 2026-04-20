(** Boolean panel apply pipeline. Dispatches the three compound-
    shape menu entries (Make / Release / Expand) on the given
    [Model.model]. No-op when preconditions aren't met (e.g. fewer
    than 2 selected for Make; no selected compound shapes for
    Release / Expand). *)

val apply_make_compound_shape : Model.model -> unit

val apply_release_compound_shape : Model.model -> unit

val apply_expand_compound_shape : Model.model -> unit
