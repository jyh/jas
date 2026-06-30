(** Menu evaluation context (TESTING_STRATEGY.md chrome seam).

    Builds the exact data scope the bundle's menubar [enabled_when] /
    [checked_when] predicates read, so the live menu (see [Menubar]) and the
    cross-app [Menu_state] gate evaluate the same expressions against the same
    shape and agree by construction. The returned object's shape matches the
    seeded contexts in [test_fixtures/algorithms/menu_state.json]:

    - [state.tab_count] : int
    - [active_document] : \{ has_selection, selection_count, can_undo,
      can_redo, is_modified, has_filename \} — all from the active [model]
      ([has_filename] is true iff the filename does NOT start with "Untitled-");
      all-false when [model] is [None] (no open document).
    - [workspace.has_saved_layout] : bool — the active layout is not the
      system "Workspace" layout.
    - [panels.<id>] : bool for all 15 panel ids (concepts is always false —
      it has no layout panel kind in this app).
    - [panes.<id>] : bool for [toolbar] and [dock].

    GTK-free so it can be unit-tested headless. Mirrors the per-app menu ctx
    built in the other apps ([menu.menu._build_menu_ctx] in Python). *)

(** [build ~tab_count ~model ~workspace_layout ~app_config] assembles the
    menu evaluation context as a [Yojson.Safe.t] object. Pass [model:None]
    (or [tab_count:0]) when no document is open so [active_document] reads
    all-false; [workspace_layout]/[app_config] are [None] when unavailable
    (then panels/panes are all not-visible and the layout is unsaved). *)
val build :
  tab_count:int ->
  model:Model.model option ->
  workspace_layout:Workspace_layout.workspace_layout option ->
  app_config:Workspace_layout.app_config option ->
  Yojson.Safe.t
