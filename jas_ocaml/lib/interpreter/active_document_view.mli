(** Centralised construction of the [active_document] context
    namespace used by panel rendering and layers-panel action
    dispatch. See implementation for details. *)

val build
  : ?panel_selection:int list list
  -> Model.model option
  -> Yojson.Safe.t
