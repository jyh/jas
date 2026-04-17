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

(* ── Panel-scoped state ──────────────────────────────────── *)

val init_panel : t -> string -> (string * Yojson.Safe.t) list -> unit
val get_panel : t -> string -> string -> Yojson.Safe.t
val set_panel : t -> string -> string -> Yojson.Safe.t -> unit
val set_active_panel : t -> string option -> unit
val get_active_panel_id : t -> string option
val get_active_panel_state : t -> (string * Yojson.Safe.t) list
val destroy_panel : t -> string -> unit

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

(* ── Evaluation context ──────────────────────────────────── *)

(** Build a [`Assoc] context suitable for [Expr_eval.evaluate].
    [extra] is merged at the top level (e.g. for [param], [event]). *)
val eval_context :
  ?extra:(string * Yojson.Safe.t) list ->
  t ->
  Yojson.Safe.t
