(** YAML-interpreted dialog component for GTK3.

    Renders a modal dialog from workspace YAML definitions, reusing the
    existing element renderer in [Yaml_panel_view] for the content tree. *)

(** Dialog state — id, evaluated state bindings, and resolved params. *)
type dialog_state = {
  id : string;
  state : (string * Yojson.Safe.t) list;
  params : (string * Yojson.Safe.t) list;
}

(** Open a dialog by id, initializing its state from the workspace
    definition.  Returns [Some] on success, [None] if the dialog is
    not found. *)
val open_dialog :
  string ->
  (string * Yojson.Safe.t) list ->
  (string * Yojson.Safe.t) list ->
  dialog_state option

(** Render the dialog as a GTK modal and run it synchronously. *)
val show_dialog : ?parent:GWindow.window -> dialog_state -> unit
