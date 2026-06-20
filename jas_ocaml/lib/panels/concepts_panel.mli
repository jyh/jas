(** Concepts panel native glue (CONCEPTS.md section 6): the native Place arm and
    the render-time concept resolver for the YAML-rendered Concepts panel. *)

(** The panel content id ([concepts_panel_content]). *)
val content_id : string

(** The panel-selected concept id, or [None] when none is selected. *)
val selected_concept : State_store.t -> string option

(** [default_params id] is the concept's declared default parameters as a JSON
    object [{ name -> default }], or [`Assoc []] when missing. *)
val default_params : string -> Yojson.Safe.t

(** PLACE INSTANCE: append a generated instance of the panel-selected concept
    (with its default params) to the active layer, one undo step. No-op when no
    concept is selected. *)
val place_concept_instance : State_store.t -> Model.model -> unit

(** The render-time concept resolver (concept id -> params -> points), for the
    canvas to evaluate a Generated instance's geometry. *)
val concept_resolver : Live.concept_resolver
