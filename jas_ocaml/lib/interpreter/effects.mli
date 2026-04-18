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

(** Element-attribute surface that [apply_character_panel_to_selection]
    pushes onto each selected Text / Text_path. *)
type character_attrs = {
  font_family : string option;
  font_size : float option;
  font_weight : string option;
  font_style : string option;
  text_decoration : string;
  text_transform : string;
  font_variant : string;
  baseline_shift : string;
  line_height : string;
  letter_spacing : string;
  xml_lang : string option;
  aa_mode : string;
  rotate : string;
  horizontal_scale : string;
  vertical_scale : string;
  kerning : string;
}

(** Pure function: translate the Character-panel state dict into the
    element-attribute surface used by
    [apply_character_panel_to_selection]. Extracted from the apply
    pipeline so the mapping rules can be tested in isolation. *)
val attrs_from_character_panel :
  (string * Yojson.Safe.t) list -> character_attrs

(** Apply a computed [character_attrs] dict to a single Text /
    Text_path element, returning a new element. Non-text elements
    pass through unchanged. *)
val apply_character_attrs_to_elem :
  Element.element -> character_attrs -> Element.element

(** Build a [tspan] override template from the Character panel state
    that contains only the fields where the panel differs from the
    element. Returns [None] when everything matches. *)
val build_panel_pending_template :
  (string * Yojson.Safe.t) list -> Element.element -> Element.tspan option

(** Push the Character-panel state to every selected Text / Text_path.
    Mirrors Rust's [apply_character_panel_to_selection]. No-op when
    the selection is empty or contains no text elements. When an
    active edit session is present with a bare caret (Phase 3), the
    write is rerouted to [Text_edit.set_pending_override] on the
    session instead of being applied to the element. *)
val apply_character_panel_to_selection :
  State_store.t -> Controller.controller -> unit

(** Subscribe [apply_character_panel_to_selection] to writes on the
    [character_panel] scope so widget changes flow to the selected
    element automatically. [ctrl_getter] is a thunk so the
    subscription follows the active model as the user switches tabs. *)
val subscribe_character_panel :
  State_store.t -> (unit -> Controller.controller) -> unit

(** Subscribe [apply_stroke_panel_to_selection] to global-state writes
    filtered by [is_stroke_render_key]. Stroke state lives in the
    global scope (keys like [stroke_cap], [stroke_align_stroke]), so
    this uses [subscribe_global] rather than [subscribe_panel].
    [ctrl_getter] is a thunk so the subscription follows the active
    model as the user switches tabs. *)
val subscribe_stroke_panel :
  State_store.t -> (unit -> Controller.controller) -> unit
