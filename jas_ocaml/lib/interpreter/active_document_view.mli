(** Centralised construction of the [active_document] context
    namespace used by panel rendering and layers-panel action
    dispatch. See implementation for details. *)

val build
  : ?panel_selection:int list list
  -> Model.model option
  -> Yojson.Safe.t

(** Build the three OPACITY.md \167States predicates at top-level for
    the yaml eval context: [selection_has_mask],
    [selection_mask_clip], [selection_mask_invert]. *)
val build_selection_predicates
  : Model.model option
  -> (string * Yojson.Safe.t) list
