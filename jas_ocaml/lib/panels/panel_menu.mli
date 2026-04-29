(** Per-panel hamburger-menu definitions and command dispatchers.

    This module is the single point of truth for what items appear in
    each panel kind's menu and what each command does when chosen. The
    YAML interpreter ([Yaml_panel_view], [Effects]) reaches into the
    [paragraph_store_ref] / [opacity_store_ref] panel-store back-pointers
    here so menu commands can operate on live panel state; that
    arrangement avoids a module dependency cycle.

    [dispatch_yaml_action] is the bridge to compiled YAML effects so
    menu commands can mutate the active document through the same
    pipeline as user-driven panel actions. *)

open Workspace_layout

(** A menu item in a panel's hamburger menu. *)
type panel_menu_item =
  | Action of { label : string; command : string; shortcut : string }
  | Toggle of { label : string; command : string }
  | Radio of { label : string; command : string; group : string }
  | Separator

(* ── Panel-store registry ────────────────────────────────── *)

(** Register (or replace) the live State_store for a panel id.
    Yaml_panel_view calls this on every panel mount so menu commands
    and cross-panel bridges can reach the live store. *)
val register_panel_store : string -> State_store.t -> unit

(** Drop the registered store for a panel id. Call from the
    yaml_panel_view destroy hook so menu commands targeting an
    unmounted panel see [None] rather than a stale handle. *)
val unregister_panel_store : string -> unit

(** Look up a panel store by id; [None] when the panel is not
    currently mounted. *)
val lookup_panel_store : string -> State_store.t option

(** Iterate every registered panel store. Cross-panel bridges
    (recent_colors etc.) use this to fan out a write to siblings. *)
val iter_panel_stores : (string -> State_store.t -> unit) -> unit

(* ── Menu rendering ───────────────────────────────────────── *)

(** All panel kinds, for iteration. Consumed by tests that assert
    every kind is covered by [panel_menu] / [panel_label]. *)
val all_panel_kinds : panel_kind array

(** Human-readable label for a panel kind. *)
val panel_label : panel_kind -> string

(** Menu items for a panel kind. *)
val panel_menu : panel_kind -> panel_menu_item list

(* ── Recent colors bridge ─────────────────────────────────── *)

(** Register a callback fired after [push_recent_color] commits. The
    Color/Swatches YAML state bridge uses this so a native push can be
    mirrored into [panel.recent_colors] of every panel that exposes it. *)
val add_recent_colors_listener : (Model.model -> string -> unit) -> unit

(** Push a hex color to the model's recent_colors with move-to-front
    dedup and a max length of 10, then notify registered listeners. *)
val push_recent_color : string -> Model.model -> unit

(** Set the active color (fill or stroke depending on [fill_on_top]),
    apply it to the current selection, and push to recent colors. *)
val set_active_color :
  Element.color -> fill_on_top:bool -> Model.model -> unit

(** Set the active color without pushing to recent colors. Reserved
    for live-slider-drag preview where intermediate values should not
    pollute the recent-colors list. *)
val set_active_color_live :
  Element.color -> fill_on_top:bool -> Model.model -> unit

(* ── Action dispatchers ──────────────────────────────────── *)

(** Dispatch a layers/panel action through the compiled YAML effects
    pipeline. Optional [panel_selection] is needed by Group B actions
    (delete_layer_selection, duplicate_layer_selection) that operate on
    the panel-local selection rather than the document selection. *)
val dispatch_yaml_action :
  ?panel_selection:int list list ->
  ?on_selection_changed:(int list list -> unit) option ->
  ?params:(string * Yojson.Safe.t) list ->
  ?on_close_dialog:(unit -> unit) option ->
  string -> Model.model -> unit

(** Dispatch a hamburger-menu command for the named panel. Reads the
    layout for radio/mode toggles and the panel back-pointers for
    panel-local state mutations. *)
val panel_dispatch :
  panel_kind ->
  string ->
  panel_addr ->
  workspace_layout ->
  fill_on_top:bool ->
  get_model:(unit -> Model.model) ->
  ?get_panel_selection:(unit -> int list list) ->
  unit -> unit

(** Query whether a toggle/radio command is currently checked, for the
    menu's leading-checkmark glyph. *)
val panel_is_checked : panel_kind -> string -> workspace_layout -> bool
