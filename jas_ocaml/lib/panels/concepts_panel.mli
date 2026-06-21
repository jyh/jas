(** Concepts panel native glue (CONCEPTS.md section 6): the native Place arm and
    the render-time concept resolver for the YAML-rendered Concepts panel. *)

(** The panel content id ([concepts_panel_content]). *)
val content_id : string

(** The panel-selected concept id, or [None] when none is selected. *)
val selected_concept : State_store.t -> string option

(** [default_params id] is the concept's declared default parameters as a JSON
    object [{ name -> default }], or [`Assoc []] when missing. *)
val default_params : string -> Yojson.Safe.t

(** PLACE INSTANCE: build the VALUE-IN-OP [place_concept_instance] op for the
    panel-selected concept (concept id + resolved default params + a freshly
    minted element id). [None] when no concept is selected. The caller brackets
    one undo and routes the op through [Op_apply.op_apply] so it both mutates and
    journals (CONCEPTS.md section 6-7). *)
val place_concept_op : State_store.t -> Model.model -> Yojson.Safe.t option

(** SET PARAM: build the VALUE-IN-OP [set_concept_param] op writing the float
    value onto the named parameter of the single selected Generated instance so
    it re-generates live (CONCEPTS.md section 6.4). [None] unless exactly one
    Generated element is selected. The caller brackets one undo and routes
    through [Op_apply.op_apply]. *)
val set_concept_param_op :
  State_store.t -> Model.model -> string -> float -> Yojson.Safe.t option

(** APPLY OPERATION: build the VALUE-IN-OP [apply_concept_operation] op for the
    named operation of the single selected Generated instance (CONCEPTS.md
    section 9). Resolves the operation's [set:] expressions over the instance's
    current params (bound under [param]) into a [changes] map baked into the op.
    [None] unless exactly one Generated element is selected, the concept/operation
    is known, and the resolved changes are non-empty. The caller brackets one undo
    and routes through [Op_apply.op_apply]; replay merges [changes] without
    re-evaluating. *)
val apply_concept_operation_op :
  State_store.t -> Model.model -> string -> Yojson.Safe.t option

(** The render-time concept resolver (concept id -> params -> points), for the
    canvas to evaluate a Generated instance's geometry. *)
val concept_resolver : Live.concept_resolver
