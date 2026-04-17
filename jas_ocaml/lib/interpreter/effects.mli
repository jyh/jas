(** Effects interpreter for the workspace YAML schema.

    Executes effect lists from actions and behaviors. Each effect is a
    JSON object with a single key identifying the effect type.
    Port of [workspace_interpreter/effects.py]. *)

(** Platform-specific effect handler: takes an effect value, the current
    context, and the state store, and returns a JSON result. Registered
    by the calling app (e.g. [Panel_menu] wires [snapshot] / [doc.set]
    to the active Model). When non-[`Null], the result is bound to the
    effect's optional [as: <name>] field for subsequent sibling effects. *)
type platform_effect =
  Yojson.Safe.t -> (string * Yojson.Safe.t) list -> State_store.t -> Yojson.Safe.t

(** Run a list of effects against [store], threading [ctx] through
    sibling effects.  Optional [actions] and [dialogs] YAML are looked
    up for [dispatch:] and [open_dialog:] primitives.  [platform_effects]
    registers host-provided handlers keyed by effect name.
    [diagnostics] accumulates schema warnings/errors; defaults to a
    throwaway ref if omitted. *)
val run_effects :
  ?actions:Yojson.Safe.t ->
  ?dialogs:Yojson.Safe.t ->
  ?schema:bool ->
  ?platform_effects:(string * platform_effect) list ->
  ?diagnostics:Schema.diagnostic list ref ->
  Yojson.Safe.t list ->
  (string * Yojson.Safe.t) list ->
  State_store.t ->
  unit

(** Extract [(key, default_value)] pairs from a dialog state definition. *)
val state_defaults : Yojson.Safe.t -> (string * Yojson.Safe.t) list

(** Convert an evaluated expression value to JSON for storage. *)
val value_to_json : Expr_eval.value -> Yojson.Safe.t

(** Build a [Stroke] from the state store's [stroke_*] keys and apply
    it to the controller's current selection.
    Currently not wired into the OCaml dispatch path (see note in the
    review transcript — parity-propagation from sibling implementations
    is incomplete). *)
val apply_stroke_panel_to_selection :
  State_store.t -> Controller.controller -> unit

(** Sync the state store's [stroke_*] keys from the first selected
    element's stroke. Currently unwired in OCaml — see the note on
    [apply_stroke_panel_to_selection]. *)
val sync_stroke_panel_from_selection :
  State_store.t -> Controller.controller -> unit

(** Check whether a state key is a rendering-affecting stroke key. *)
val is_stroke_render_key : string -> bool
