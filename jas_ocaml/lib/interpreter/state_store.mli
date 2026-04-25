(** Reactive state store for the workspace interpreter.

    Manages global state, panel-scoped state, and dialog-scoped state.
    Port of [workspace_interpreter/state_store.py]. *)

type t

(** Dialog property with optional getter / setter expressions.
    Internal structure — construct via YAML loader, not directly. *)
type prop_def

(** Create an empty store, seeded with optional state defaults. *)
val create : ?defaults:(string * Yojson.Safe.t) list -> unit -> t

(* ── Global state ────────────────────────────────────────── *)

val get : t -> string -> Yojson.Safe.t
val set : t -> string -> Yojson.Safe.t -> unit
val get_all : t -> (string * Yojson.Safe.t) list

(* ── Data namespace (workspace-loaded reference data) ──── *)

val set_data : t -> Yojson.Safe.t -> unit
(** Replace the data namespace. App startup typically calls this
    with the loaded workspace so data.brush_libraries etc.
    resolve. *)

val get_data : t -> Yojson.Safe.t

val get_data_path : t -> string -> Yojson.Safe.t
(** Read a value at a dotted "data.x.y" or "x.y" path. Returns
    Null on any missing intermediate. *)

val set_data_path : t -> string -> Yojson.Safe.t -> unit
(** Write at a dotted path inside the data namespace. Intermediate
    objects are created on demand. *)

(* ── Panel-scoped state ──────────────────────────────────── *)

val init_panel : t -> string -> (string * Yojson.Safe.t) list -> unit
val get_panel : t -> string -> string -> Yojson.Safe.t
val set_panel : t -> string -> string -> Yojson.Safe.t -> unit
val set_active_panel : t -> string option -> unit
val get_active_panel_id : t -> string option
val get_active_panel_state : t -> (string * Yojson.Safe.t) list
val destroy_panel : t -> string -> unit

(* ── Tool-scoped state ───────────────────────────────────── *)

(** Seed a tool's state with its declared defaults. Called by
    [Yaml_tool] when a tool is constructed. *)
val init_tool : t -> string -> (string * Yojson.Safe.t) list -> unit

val has_tool : t -> string -> bool
val get_tool : t -> string -> string -> Yojson.Safe.t

(** Write into a tool's scope. Auto-creates the namespace on first
    write, matching the Rust/Swift set_tool behavior. *)
val set_tool : t -> string -> string -> Yojson.Safe.t -> unit

val get_tool_state : t -> string -> (string * Yojson.Safe.t) list
val destroy_tool : t -> string -> unit

(** Inspect every tool scope — useful for tests. *)
val get_tool_scopes : t -> (string * (string * Yojson.Safe.t) list) list

(** Callback invoked on a panel-state write: (key, new_value). *)
type panel_subscriber = string -> Yojson.Safe.t -> unit

(** Subscribe to panel state changes on [panel_id]. Callbacks fire
    after every [set_panel] on that panel. Mirrors Python's
    [StateStore.subscribe_panel]. *)
val subscribe_panel : t -> string -> panel_subscriber -> unit

(** Callback invoked on a global-state write: (key, new_value). *)
type global_subscriber = string -> Yojson.Safe.t -> unit

(** Subscribe to global state changes. Callbacks fire after every
    [set]. The stroke panel uses this path (via
    [Effects.subscribe_stroke_panel]) because stroke keys live in
    global state rather than in a named panel scope. *)
val subscribe_global : t -> global_subscriber -> unit

(* ── Dialog-scoped state ─────────────────────────────────── *)

val init_dialog :
  t ->
  string ->
  (string * Yojson.Safe.t) list ->
  ?params:(string * Yojson.Safe.t) list ->
  ?props:(string * prop_def) list ->
  unit -> unit
val get_dialog : t -> string -> Yojson.Safe.t option
val set_dialog : t -> string -> Yojson.Safe.t -> unit
val get_dialog_state : t -> (string * Yojson.Safe.t) list
val get_dialog_id : t -> string option
val get_dialog_params : t -> (string * Yojson.Safe.t) list option
val close_dialog : t -> unit

(** Capture the current value of every state key referenced by a
    dialog's [preview_targets]. Phase 0 supports only top-level
    state keys; deep paths (containing a dot) are silently skipped
    and will land alongside their first real consumer in Phase 8/9.
    [targets] maps [(dialog_state_key, state_key)]. *)
val capture_dialog_snapshot : t -> (string * string) list -> unit

val get_dialog_snapshot : t -> (string * Yojson.Safe.t) list option
val clear_dialog_snapshot : t -> unit
val has_dialog_snapshot : t -> bool

(* Dialog on_change hook — see SCALE_TOOL.md \167 Preview. *)
val set_dialog_on_change : t -> string option -> unit
val get_dialog_on_change : t -> string option
val take_dialog_dirty : t -> bool
val is_firing_on_change : t -> bool
val set_firing_on_change : t -> bool -> unit

(* ── Evaluation context ──────────────────────────────────── *)

(** Build a [`Assoc] context suitable for [Expr_eval.evaluate].
    [extra] is merged at the top level (e.g. for [param], [event]). *)
val eval_context :
  ?extra:(string * Yojson.Safe.t) list ->
  t ->
  Yojson.Safe.t
