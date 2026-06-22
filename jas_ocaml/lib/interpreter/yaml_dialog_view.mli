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
    not found.  ``outer_scope`` exposes top-level keys (typically
    ``active_document``) to init expressions so dialogs whose [init:]
    reads ``active_document.print_preferences.*`` resolve correctly
    rather than silently falling back to the YAML state defaults. *)
val open_dialog :
  ?outer_scope:(string * Yojson.Safe.t) list ->
  string ->
  (string * Yojson.Safe.t) list ->
  (string * Yojson.Safe.t) list ->
  dialog_state option

(** Render the dialog as a GTK modal and run it synchronously.
    ``outer_scope`` is exposed to render-time bind expressions. *)
val show_dialog :
  ?parent:GWindow.window ->
  ?outer_scope:(string * Yojson.Safe.t) list ->
  dialog_state -> unit

(** Render a ``modal: false`` dialog as a non-blocking GTK flyout
    (undecorated popup positioned at the pointer). Unlike [show_dialog]
    this does NOT run a blocking [dialog#run] loop, so the canvas /
    toolbar stay interactive; the popup dismisses on an outside click
    or when an item's ``close_dialog`` effect fires. Backs the toolbar
    long-press tool-alternates flyout. *)
val show_nonmodal_dialog : dialog_state -> unit

(** Read the live dialog state list, or [[]] when no dialog is open.
    Used by widget renderers to rebuild contexts at click time so the
    OK action sees typed-in values rather than the stale render-time
    snapshot. *)
val current_dialog_state : unit -> (string * Yojson.Safe.t) list

(** Set [key] in the live dialog state. Called by widget write-back
    handlers in [Yaml_panel_view] when a number_input / toggle /
    select / etc. is bound to ``dialog.X``. No-op when no dialog is
    open. *)
val set_dialog_field : string -> Yojson.Safe.t -> unit

(** Build a fresh evaluation context against the live dialog state.
    Used by widget action callbacks (button OK / Done / Print) at
    click time so the resolved params reflect typed-in values rather
    than the render-time defaults. Returns [`Assoc []] when no dialog
    is open. *)
val current_dialog_ctx : unit -> Yojson.Safe.t

(** Close the active dialog widget. Called by close_dialog action
    effects and by ``dismiss_dialog`` button actions. *)
val close_current_dialog : unit -> unit

(** Dispatch a YAML action by name with the given resolved params.
    ``dismiss_dialog`` is special-cased to dismiss the dialog widget
    without running any effects. All other action names look up the
    action in workspace, build a context with [param] set, and run
    the effects through [Effects.run_effects] with platform_effects
    that include ``snapshot``, ``close_dialog``, and the full
    [Yaml_tool_effects] table (so ``doc.set_document_setup_field``
    and ``doc.set_print_preferences_field`` work).

    The [Controller.controller option] is the active model's
    controller; pass [None] to make every effect a no-op (used for
    test harnesses with no live model). *)
val dispatch_action :
  string ->
  (string * Yojson.Safe.t) list ->
  Controller.controller option ->
  (unit -> unit) ->
  unit
