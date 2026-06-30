(* Menu evaluation context (TESTING_STRATEGY.md chrome seam).

   OCaml port of menu.menu._build_menu_ctx (Python). Builds the exact data
   scope the bundle menubar [enabled_when] / [checked_when] predicates read,
   so the live menu and the cross-app [Menu_state] gate evaluate the same
   expressions against the same shape. See the .mli for the full shape. *)

(* The 15 Window-menu panel-toggle ids paired with their layout panel kind.
   Mirrors the Python _menu_panel_kinds dict. "concepts" has no dockable
   panel_kind in this app (the Concepts panel is a widget, not a layout
   panel), so it maps to [None] and evaluates to not-visible — matching the
   always-false [panels.concepts] in the seeded menu_state contexts. *)
let panel_ids : (string * Workspace_layout.panel_kind option) list =
  [ ("artboards", Some Workspace_layout.Artboards);
    ("layers", Some Workspace_layout.Layers);
    ("color", Some Workspace_layout.Color);
    ("swatches", Some Workspace_layout.Swatches);
    ("brushes", Some Workspace_layout.Brushes);
    ("stroke", Some Workspace_layout.Stroke);
    ("properties", Some Workspace_layout.Properties);
    ("character", Some Workspace_layout.Character);
    ("paragraph", Some Workspace_layout.Paragraph);
    ("align", Some Workspace_layout.Align);
    ("boolean", Some Workspace_layout.Boolean);
    ("magic_wand", Some Workspace_layout.Magic_wand);
    ("opacity", Some Workspace_layout.Opacity);
    ("symbols", Some Workspace_layout.Symbols);
    ("concepts", None) ]

(* The two pane-toggle ids paired with their pane kind. *)
let pane_ids : (string * Pane.pane_kind) list =
  [ ("toolbar", Pane.Toolbar); ("dock", Pane.Dock) ]

(* A filename starting with "Untitled-" denotes a never-saved document, so
   it has NO real on-disk filename. Mirrors the Python
   [not m.filename.startswith("Untitled-")] and the [Menubar.is_untitled]
   helper (kept local to avoid a Menubar -> Menu_ctx -> Menubar cycle). *)
let is_untitled (filename : string) : bool =
  String.length filename >= 9 && String.sub filename 0 9 = "Untitled-"

let active_document_of_model (m : Model.model) : Yojson.Safe.t =
  let doc = m#document in
  let n = Document.PathMap.cardinal doc.Document.selection in
  `Assoc
    [ ("has_selection", `Bool (n > 0));
      ("selection_count", `Int n);
      ("can_undo", `Bool m#can_undo);
      ("can_redo", `Bool m#can_redo);
      ("is_modified", `Bool m#is_modified);
      ("has_filename", `Bool (not (is_untitled m#filename))) ]

let no_active_document : Yojson.Safe.t =
  `Assoc
    [ ("has_selection", `Bool false);
      ("selection_count", `Int 0);
      ("can_undo", `Bool false);
      ("can_redo", `Bool false);
      ("is_modified", `Bool false);
      ("has_filename", `Bool false) ]

let build ~(tab_count : int) ~(model : Model.model option)
    ~(workspace_layout : Workspace_layout.workspace_layout option)
    ~(app_config : Workspace_layout.app_config option) : Yojson.Safe.t =
  let active_document =
    match model with
    | Some m -> active_document_of_model m
    | None -> no_active_document
  in
  let has_saved_layout =
    match app_config with
    | Some c ->
      c.Workspace_layout.active_layout <> Workspace_layout.workspace_layout_name
    | None -> false
  in
  let panels =
    List.map
      (fun (id, kind_opt) ->
        let visible =
          match (kind_opt, workspace_layout) with
          | Some kind, Some l -> Workspace_layout.is_panel_visible l kind
          | _ -> false
        in
        (id, `Bool visible))
      panel_ids
  in
  let panes =
    List.map
      (fun (id, kind) ->
        let visible =
          match workspace_layout with
          | Some l ->
            (match Workspace_layout.panes l with
             | Some pl -> Pane.is_pane_visible pl kind
             | None -> false)
          | None -> false
        in
        (id, `Bool visible))
      pane_ids
  in
  `Assoc
    [ ("state", `Assoc [ ("tab_count", `Int tab_count) ]);
      ("active_document", active_document);
      ("workspace", `Assoc [ ("has_saved_layout", `Bool has_saved_layout) ]);
      ("panels", `Assoc panels);
      ("panes", `Assoc panes) ]
