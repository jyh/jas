(** Generic YAML element renderer for GTK3 dock panels, dialogs, and the
    toolbar pane.

    Renders the workspace bundle's declarative widget trees
    (containers / grids / buttons / sliders / swatches / the fill-stroke
    widget / etc.) into lablgtk3 widgets, evaluating ``bind`` and
    ``foreach`` expressions against a per-render context. The same entry
    point ([render_element]) backs the dock panels (via
    [create_panel_body]), the YAML dialogs (via [Yaml_dialog_view]), and
    — STEP A of the toolbar migration — the toolbar pane (via
    [mount_toolbar]).

    This interface exposes only the cross-module surface: the render
    entry points, the panel-body registry, the color-panel targeted-
    update slots, and the hook refs main.ml wires at startup. The large
    family of mutually-recursive ``render_*`` helpers stays private. *)

(** Accessor for the active model, set by [create_panel_body] /
    [mount_toolbar] and read by widget renderers that reach back into
    the document. Exposed so test harnesses can inject a model and
    restore the prior accessor afterwards. *)
val _get_model_ref : (unit -> Model.model option) ref

(** The store backing the currently-rendered panel / toolbar. Exposed so
    test harnesses can inject and restore panel state around a render. *)
val _current_store : State_store.t option ref

(** Walk an element's ``behavior`` array, running every ``event: click``
    entry (``set:`` effects and named ``action:`` dispatch — including
    the toolbar's ``select_tool``). Returns [true] when a ``set:`` wrote
    panel-bound state, so the caller can schedule a re-render. *)
val dispatch_click_behaviors : Yojson.Safe.t -> Yojson.Safe.t -> bool

(** Delete the current panel-state selection (reference-aware; consults
    [confirm_delete_orphans_hook] when the deletion would orphan live
    references). Backs the panel's Delete Selection command. *)
val do_delete_panel_selection : unit -> unit

(* ── Hooks wired in main.ml ──────────────────────────────────────── *)

(** Re-render the open dock panel bodies without a full dock rebuild. *)
val panel_rerender_hook : (unit -> unit) ref

(** Re-check / re-sync open panels (used by menu-driven state changes). *)
val panel_check_sync_hook : (unit -> unit) ref

(** Consulted before deleting elements that would orphan live
    references; returns [true] to proceed. The argument is the orphan
    count for the confirmation wording. *)
val confirm_delete_orphans_hook : (int -> bool) ref

(** Open a GTK dialog window by id, with resolved params. The actual
    window creation lives in main.ml against [Yaml_dialog_view] to avoid
    a renderer ↔ dialog-runner cycle. *)
val open_yaml_dialog_hook :
  (string -> (string * Yojson.Safe.t) list -> unit) ref

(** Switch the active canvas's tool from a YAML ``set: { active_tool:
    ... }`` effect or a toolbar ``select_tool`` action. Wired in main.ml
    against the active toolbar. *)
val set_active_tool_hook : (string -> unit) ref

(** Current active-tool name as the YAML toolbar's ``bind.checked``
    expressions read it. Mirrors the native toolbar / canvas tool;
    updated on every tool change so the bundle-rendered toolbar can
    re-evaluate its highlight. Toolbar STEP A. *)
val active_tool_name : string ref

(** Rebuild the bundle-rendered toolbar pane in place so the tool-button
    highlight re-evaluates after [active_tool_name] changes. Wired in
    main.ml to re-run [mount_toolbar]. No-op until wired. *)
val toolbar_rerender_hook : (unit -> unit) ref

(** Active appearance's text color, for label defaults that re-skin on
    appearance change. Wired in main.ml against [Dock_panel.theme_text]
    to avoid a renderer ↔ dock cycle. *)
val theme_text_hook : (unit -> string) ref

(* ── Panel-body registry & targeted updates ──────────────────────── *)

(** Register a fast in-place re-render function for a panel kind, used
    in place of a full dock rebuild when available. *)
val register_panel_body_renderer :
  Workspace_layout.panel_kind -> (unit -> unit) -> unit

(** Drop all registered panel-body renderers (on a full dock rebuild). *)
val clear_panel_body_renderers : unit -> unit

(** Forget the color-panel targeted-update widget slots (on rebuild). *)
val clear_color_panel_slots : unit -> unit

(** Refresh the color panel's fill/stroke swatches + hex entry in place
    from the active selection, without a body rebuild. No-op when no
    color panel is mounted. *)
val update_color_panel_widgets : unit -> unit

(** Install the cross-panel recent-colors bridge so a color commit
    repaints the recent strip in place. *)
val install_recent_colors_bridge : unit -> unit

(** Re-sync the open Paragraph panel from the active model's selection.
    No-op when no Paragraph panel is open. *)
val paragraph_panel_resync_from_active_model : unit -> unit

(* ── Render entry points ─────────────────────────────────────────── *)

(** Render a single YAML element node into the given packing slot,
    evaluating ``bind`` / ``foreach`` against [ctx]. The recursive
    workhorse behind every panel / dialog / toolbar render. *)
val render_element :
  packing:(GObj.widget -> unit) -> ctx:Yojson.Safe.t -> Yojson.Safe.t -> unit

(** Build a dock panel body for [kind] into the packing slot, wiring its
    state store, ``bind`` ctx, and panel-specific subscriptions. *)
val create_panel_body :
  packing:(GObj.widget -> unit) ->
  kind:Workspace_layout.panel_kind ->
  ?get_model:(unit -> Model.model option) ->
  ?max_width:int ->
  unit -> unit

(** Toolbar STEP A: render the bundle's ``layout → toolbar_pane →
    content`` (the tool grid + fill/stroke widget) through
    [render_element], instead of the hand-built native toolbar class.
    The render ctx sources ``state.active_tool`` from [active_tool_name]
    so each tool button's ``bind.checked`` highlight tracks. Re-invoked
    by [toolbar_rerender_hook] after the active tool changes. *)
val mount_toolbar :
  packing:(GObj.widget -> unit) ->
  ?get_model:(unit -> Model.model option) ->
  unit -> unit
