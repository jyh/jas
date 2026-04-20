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

(** Document-scoped boolean op settings. Mirrors the Boolean Options
    dialog state (see [transcripts/BOOLEAN.md] §Boolean Options
    dialog).
    - [precision] geometric tolerance in points
    - [remove_redundant_points] collapse near-collinear points within
      [precision]
    - [divide_remove_unpainted] drop DIVIDE fragments with no fill
      and no stroke *)
type boolean_options = {
  precision : float;
  remove_redundant_points : bool;
  divide_remove_unpainted : bool;
}

(** Defaults: precision = [Live.default_precision], redundant-point
    collapse on, divide-remove-unpainted off. *)
val default_boolean_options : boolean_options

(** Single-pass removal of collinear / near-duplicate points within
    [tol]. Returns the original ring if collapse would leave fewer
    than 3 points. *)
val collapse_collinear_points :
  (float * float) array -> float -> (float * float) array

(** Destructively apply one of the nine boolean ops to the current
    selection. Supported names: [union], [intersection], [exclude],
    [subtract_front], [subtract_back], [crop], [divide], [trim],
    [merge]. Unknown ops are no-ops. See
    [transcripts/BOOLEAN.md] §Operand and paint rules. *)
val apply_destructive_boolean :
  ?options:boolean_options -> Model.model -> string -> unit

(** Re-apply the last destructive or compound-creating boolean op.
    Reads the 13-value state enum (see BOOLEAN.md §Repeat state):
    op names ending in [_compound] dispatch to apply_compound_
    creation; all others dispatch to apply_destructive_boolean.
    No-op when [last_op] is [None] or empty. *)
val apply_repeat_boolean_operation :
  ?options:boolean_options -> Model.model -> string option -> unit
