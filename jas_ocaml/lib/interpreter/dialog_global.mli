(** Cross-module refs surfacing the active YAML dialog to widget
    renderers. Lives in its own module to break a circular dep
    between [Yaml_panel_view] and [Yaml_dialog_view]. *)

val current_state : (string * Yojson.Safe.t) list ref option ref
val current_id : string option ref
val current_outer_scope : (string * Yojson.Safe.t) list ref
val current_close : (unit -> unit) ref
val current_build_ctx : (unit -> Yojson.Safe.t) ref

type prop_def = {
  prop_get : string option;
  prop_set : string option;
}
val current_props : (string * prop_def) list ref

val add_state_change_listener : (unit -> unit) -> unit
val clear_state_change_listeners : unit -> unit

(** Read the live dialog state list, or [[]] when no dialog is open.
    Evaluates [get:] getters in [current_props] so derived keys
    reflect the canonical underlying state. *)
val read_state : unit -> (string * Yojson.Safe.t) list

(** Set [key] in the live dialog state. Runs the [set:] lambda from
    [current_props] when present; otherwise stores [value] directly.
    Fires registered state-change listeners after the write. No-op
    when no dialog is open. *)
val set_field : string -> Yojson.Safe.t -> unit

(** Close the active dialog widget. *)
val close : unit -> unit

(** Dispatch a YAML action with resolved params and a close-the-widget
    callback. Used by [Yaml_panel_view.render_button] when the YAML
    declares ``action: <name>`` (OK / Done / Print / Cancel buttons). *)
val dispatch_action :
  string ->
  (string * Yojson.Safe.t) list ->
  Controller.controller option ->
  (unit -> unit) ->
  unit
