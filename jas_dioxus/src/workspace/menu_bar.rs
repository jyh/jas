//! Menu bar component.

use std::cell::RefCell;
use std::rc::Rc;

use dioxus::prelude::*;

use super::app_state::{Act, AppHandle, AppState, TabState};
use super::clipboard::{
    clipboard_read_and_paste, clipboard_write, download_bytes, download_file,
    open_file_dialog, save_document_as, selection_to_svg,
};
// SaveAsDialog import removed — workspace save-as now uses YAML dialog system
use super::theme::*;
use crate::document::controller::Controller;
use crate::geometry::svg::document_to_svg;
use crate::panels::panel_menu_state::{MenuBarState, PanelMenuState};

#[component]
pub(crate) fn MenuBarView(
    workspace_submenu_open: Signal<bool>,
    appearance_submenu_open: Signal<bool>,
) -> Element {
    let act = use_context::<Act>();
    let app = use_context::<AppHandle>();
    let revision = use_context::<Signal<u64>>();
    let mbs = use_context::<MenuBarState>();
    let mut panel_menu = use_context::<PanelMenuState>();
    let open_menu = mbs.open_menu;
    let mut yaml_dialog_sig = use_context::<crate::interpreter::dialog_view::DialogCtx>().0;

    // --- Menu dispatch ---
    let dispatch = {
        let act = act.clone();
        let app_for_menu = app.clone();
        let revision_for_menu = revision;
        Rc::new(move |cmd: &str| {
            match cmd {
                "new" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.add_tab(TabState::new());
                    }));
                }
                "open" => {
                    open_file_dialog(app_for_menu.clone(), revision_for_menu);
                }
                "save" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            let svg = document_to_svg(tab.model.document());
                            let filename = if tab.model.filename.ends_with(".svg") {
                                tab.model.filename.clone()
                            } else {
                                format!("{}.svg", tab.model.filename)
                            };
                            download_file(&filename, &svg);
                            tab.model.mark_saved();
                            // What was just written becomes the version Revert
                            // returns to (council O1.2).
                            tab.saved_svg = Some(svg.clone());
                        }
                    }));
                }
                "close" => {
                    // No menubar.yaml item emits `close` today. Kept routed
                    // through the YAML `close_tab`, as the tab strip's x and
                    // Cmd-W are, so no close path skips the save prompt.
                    let deferred = Rc::new(RefCell::new(Vec::new()));
                    let out = deferred.clone();
                    (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                        let idx = st.active_tab;
                        *out.borrow_mut() = crate::interpreter::renderer::request_close_tab(st, idx);
                    }));
                    let mut sig = yaml_dialog_sig;
                    let effects = deferred.borrow().clone();
                    crate::interpreter::renderer::apply_deferred_dialog_effects(
                        &effects, &app_for_menu, &mut sig);
                }
                "undo" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            // Recorder: history nav segments an open
                            // gesture case (pre-nav doc is the oracle).
                            crate::recorder::hooks::history_nav(&tab.model);
                            tab.model.undo();
                        }
                    }));
                }
                "redo" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            crate::recorder::hooks::history_nav(&tab.model);
                            tab.model.redo();
                        }
                    }));
                }
                "cut" => {
                    // Reference-aware cut (warn-then-orphan). Cut is
                    // copy-to-clipboard + delete, so it can orphan live
                    // instances exactly like delete; gate it identically.
                    // Empty -> cut inline exactly as before (copy + snapshot
                    // + delete, no dialog). Non-empty -> open the confirm
                    // dialog with the orphan count and return WITHOUT
                    // mutating the clipboard or document; the dialog's Cut
                    // button runs copy + snapshot + delete_selection, so
                    // Cancel is a true no-op. Selection is left intact so the
                    // OK action cuts the same elements.
                    let orphan_count: usize = {
                        let st = app_for_menu.borrow();
                        match st.tab() {
                            Some(tab) => {
                                let doc = tab.model.document();
                                let paths: Vec<Vec<usize>> = doc
                                    .selection
                                    .iter()
                                    .map(|es| es.path.clone())
                                    .collect();
                                crate::document::dependency_index::orphaned_references(
                                    doc, &paths,
                                )
                                .len()
                            }
                            None => 0,
                        }
                    };
                    if orphan_count == 0 {
                        (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                            if st.tab().is_none() { return; }
                            // Copy to the SYSTEM clipboard (the only clipboard —
                            // D4/D5, see `TabState`), then delete.
                            if let Some(svg) = selection_to_svg(st) {
                                clipboard_write(svg);
                            }
                            let Some(tab) = st.tab_mut() else { return; };
                            crate::document::op_apply::journal_delete_selection(
                                &mut tab.model, "cut_selection");
                        }));
                    } else {
                        let st = app_for_menu.borrow();
                        let live_state =
                            crate::workspace::dock_panel::build_live_state_map(&st);
                        drop(st);
                        let mut params = serde_json::Map::new();
                        params.insert(
                            "count".to_string(),
                            serde_json::json!(orphan_count),
                        );
                        let mut sig = yaml_dialog_sig;
                        crate::interpreter::dialog_view::open_dialog(
                            &mut sig,
                            "cut_orphan_confirm",
                            &params,
                            &live_state,
                        );
                    }
                }
                "copy" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.tab().is_none() { return; }
                        // The SYSTEM clipboard is the only clipboard (D4/D5 —
                        // see `TabState`).
                        if let Some(svg) = selection_to_svg(st) {
                            clipboard_write(svg);
                        }
                    }));
                }
                // The offsets and the layer targeting are the clipboard table
                // the engine's menu and key routes read (`menu_native`). R2:
                // plain Paste FLATTENS into the active layer; R3: Paste
                // Preserving Layers differs in layer TARGETING only.
                "paste" | "paste_in_place" | "paste_preserving_layers" => {
                    if let Some(super::menu_native::ClipVerb::Paste { offset, preserve_layers }) =
                        super::menu_native::clipboard_verb(cmd)
                    {
                        clipboard_read_and_paste(
                            app_for_menu.clone(), revision_for_menu, offset, preserve_layers,
                        );
                    }
                }
                // The menu's model verbs, as the web keyboard runs them
                // ([`run_model_verb`]): the declared action where the YAML is
                // `doc.op`, else the native table shared with the action
                // corpus and the engine's menu dispatch (`menu_native`).
                "select_all" | "unlock_all" | "hide" | "show_all" | "lock"
                | "group" | "ungroup" | "ungroup_all" | "make_instance" => {
                    let action = cmd.to_string();
                    (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                        run_model_verb(&action, st);
                    }));
                }
                "delete" => {
                    // Reference-aware delete (warn-then-orphan). Phase A:
                    // compute the pure orphaned_references predicate over the
                    // current selection. Empty -> delete inline exactly as
                    // before (no dialog). Non-empty -> open the confirm
                    // dialog with the orphan count and return WITHOUT
                    // mutating; the dialog's Delete button runs the snapshot
                    // + delete_selection. Selection is left intact so the OK
                    // action deletes the same elements.
                    let orphan_count: usize = {
                        let st = app_for_menu.borrow();
                        match st.tab() {
                            Some(tab) => {
                                let doc = tab.model.document();
                                let paths: Vec<Vec<usize>> = doc
                                    .selection
                                    .iter()
                                    .map(|es| es.path.clone())
                                    .collect();
                                crate::document::dependency_index::orphaned_references(
                                    doc, &paths,
                                )
                                .len()
                            }
                            None => 0,
                        }
                    };
                    if orphan_count == 0 {
                        (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                            if let Some(tab) = st.tab_mut() {
                                crate::document::op_apply::journal_delete_selection(
                                    &mut tab.model, "delete_selection");
                            }
                        }));
                    } else {
                        let st = app_for_menu.borrow();
                        let live_state =
                            crate::workspace::dock_panel::build_live_state_map(&st);
                        drop(st);
                        let mut params = serde_json::Map::new();
                        params.insert(
                            "count".to_string(),
                            serde_json::json!(orphan_count),
                        );
                        let mut sig = yaml_dialog_sig;
                        crate::interpreter::dialog_view::open_dialog(
                            &mut sig,
                            "delete_orphan_confirm",
                            &params,
                            &live_state,
                        );
                    }
                }
                "simplify" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        let precision = st.boolean_panel.simplify_precision;
                        if let Some(tab) = st.tab_mut() {
                            Controller::simplify_selection(&mut tab.model, precision);
                        }
                    }));
                }
                "tile_panes" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        let dock_collapsed = st.workspace_layout.anchored_dock(super::workspace::DockEdge::Right)
                            .is_some_and(|d| d.collapsed);
                        // Resolve the collapsed-dock width override against the
                        // live pane layout, then dispatch through the shared
                        // layout-op runtime (OP_LOG.md §12). `set_canvas_maximized:
                        // false` reproduces the pre-3d-2 `pl.canvas_maximized = false`.
                        let override_pane = if dock_collapsed {
                            st.workspace_layout.pane_layout.as_ref()
                                .and_then(|pl| pl.pane_by_kind(super::workspace::PaneKind::Dock).map(|p| (p.id, 36.0)))
                        } else {
                            None
                        };
                        crate::workspace::layout_apply::layout_apply(
                            &mut st.workspace_layout,
                            &crate::workspace::layout_apply::op_tile_panes(false, override_pane),
                        );
                    }));
                }
                // Window menu: pane visibility
                "toggle_pane_toolbar" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        let visible = st.workspace_layout.pane_layout.as_ref()
                            .map(|pl| pl.is_pane_visible(super::workspace::PaneKind::Toolbar));
                        if let Some(visible) = visible {
                            let op = if visible {
                                crate::workspace::layout_apply::op_hide_pane(super::workspace::PaneKind::Toolbar)
                            } else {
                                crate::workspace::layout_apply::op_show_pane(super::workspace::PaneKind::Toolbar)
                            };
                            crate::workspace::layout_apply::layout_apply(&mut st.workspace_layout, &op);
                        }
                    }));
                }
                "toggle_pane_dock" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        let visible = st.workspace_layout.pane_layout.as_ref()
                            .map(|pl| pl.is_pane_visible(super::workspace::PaneKind::Dock));
                        if let Some(visible) = visible {
                            let op = if visible {
                                crate::workspace::layout_apply::op_hide_pane(super::workspace::PaneKind::Dock)
                            } else {
                                crate::workspace::layout_apply::op_show_pane(super::workspace::PaneKind::Dock)
                            };
                            crate::workspace::layout_apply::layout_apply(&mut st.workspace_layout, &op);
                        }
                    }));
                }
                // Window menu: panel visibility. All 16 dock panels route
                // through the ONE generic native toggle_panel path
                // (renderer::dispatch_action), keyed by the panel-id string
                // recovered from the cmd (`toggle_panel_<id>` -> `<id>`, the
                // bundle snake_case name, e.g. `magic_wand`, `gradient`,
                // `concepts`). This replaces the 15 legacy per-panel arms; see
                // actions.yaml `toggle_panel` for the behavior contract (show /
                // hide against the dock model; Color also resets its panel-local
                // mode to HSB on reopen, handled inside the native path).
                c if c.starts_with("toggle_panel_") => {
                    let panel_id = c.strip_prefix("toggle_panel_").unwrap_or("").to_string();
                    (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                        let mut p = serde_json::Map::new();
                        p.insert("panel".to_string(), serde_json::json!(panel_id));
                        let _ = crate::interpreter::renderer::dispatch_action(
                            "toggle_panel", &p, st);
                    }));
                }
                "workspace_submenu" | "appearance_submenu" => {
                    // Handled by dynamic submenu rendering, not dispatch
                }
                "document_setup" => {
                    let st = app_for_menu.borrow();
                    let live_state = crate::workspace::dock_panel::build_live_state_map(&st);
                    let outer_scope = crate::interpreter::renderer::build_dialog_outer_scope(&st);
                    drop(st);
                    // Signal is Copy; shadow into a local mutable
                    // binding so the &mut required by open_dialog
                    // doesn't make this dispatch closure FnMut.
                    let mut sig = yaml_dialog_sig;
                    // open_dialog_with_outer threads `active_document`
                    // into the init context, so init expressions like
                    // `active_document.document_setup.bleed_top`
                    // resolve to the persisted value rather than the
                    // YAML default.
                    crate::interpreter::dialog_view::open_dialog_with_outer(
                        &mut sig,
                        "document_setup",
                        &serde_json::Map::new(),
                        &live_state,
                        &outer_scope,
                    );
                }
                "print" => {
                    let st = app_for_menu.borrow();
                    let live_state = crate::workspace::dock_panel::build_live_state_map(&st);
                    let outer_scope = crate::interpreter::renderer::build_dialog_outer_scope(&st);
                    drop(st);
                    let mut sig = yaml_dialog_sig;
                    crate::interpreter::dialog_view::open_dialog_with_outer(
                        &mut sig,
                        "print",
                        &serde_json::Map::new(),
                        &live_state,
                        &outer_scope,
                    );
                }
                "export_to_pdf" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            let bytes = crate::geometry::pdf::document_to_pdf(tab.model.document());
                            let stem = filename_stem(&tab.model.filename);
                            let filename = format!("{}.pdf", stem);
                            download_bytes(&filename, &bytes, "application/pdf");
                        }
                    }));
                }
                // Bundle actions with no bespoke handler above — route through
                // the generic action pipeline (all are defined in actions.yaml).
                // These take no params and do not open dialogs today, so the
                // deferred-effect return is intentionally ignored.
                "save_as" => {
                    // Real handler as of council O1.1. This used to sit in the
                    // pass-through list below, which routes to
                    // `dispatch_action` -- and `save_as`'s declared effect is a
                    // bare `- log:`, so File > Save As did nothing at all in
                    // this port while JasSwift implemented it fully.
                    save_document_as(app_for_menu.clone(), revision_for_menu);
                }
                "revert" => {
                    // JasSwift re-reads the file from disk by path. A browser
                    // has no path, so the saved bytes are retained on the tab
                    // (`TabState::saved_svg`) and re-parsed -- JYH's ruling at
                    // council 2026-07-30, chosen over rewinding the journal so
                    // both ports round-trip through SVG identically.
                    (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                        if !crate::workspace::clipboard::can_revert(st) {
                            return;
                        }
                        let name = st
                            .tab()
                            .map(|t| t.model.filename.clone())
                            .unwrap_or_default();
                        // Swift raises an NSAlert with Revert / Cancel; the
                        // browser's own confirm is the same contract.
                        let ok = web_sys::window()
                            .and_then(|w| {
                                w.confirm_with_message(&format!(
                                    "Revert to the saved version of \"{name}\"?\n\
                                     All current modifications will be lost."
                                ))
                                .ok()
                            })
                            .unwrap_or(false);
                        if ok {
                            crate::workspace::clipboard::apply_revert(st);
                        }
                    }));
                }
                "quit" | "promote_to_concept"
                | "zoom_in" | "zoom_out" | "zoom_to_actual_size"
                | "fit_active_artboard" | "fit_all_artboards" | "fit_in_window" => {
                    let action = cmd.to_string();
                    (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                        let _ = crate::interpreter::renderer::dispatch_action(
                            &action, &serde_json::Map::new(), st);
                    }));
                }
                _ => {}
            }
        })
    };

    // Menu data projected from the compiled bundle menubar (menubar.yaml) —
    // the single source of truth. Translate each item to the (label, cmd,
    // shortcut) shape the renderer + dispatch below consume; the dynamic
    // Workspace / Appearance submenus map to their sentinel cmds.
    // Each item carries its bundle `enabled_when` / `checked_when` predicate
    // (None for separators / dynamic submenus) so the renderer can evaluate
    // them live against the menu ctx below — the SAME evaluation the cross-app
    // `menu_state` gate pins.
    // (id, label, cmd, shortcut, enabled_when, checked_when). `id` is the
    // menubar.yaml item id, emitted as the DOM id so a menu entry is
    // spec-addressed rather than matched on its text.
    type MenuItem = (String, String, String, String, Option<String>, Option<String>);
    let menus_owned: Vec<(String, Vec<MenuItem>)> =
        super::menu::menu_bar_model()
            .iter()
            .map(|m| {
                let items = m
                    .entries
                    .iter()
                    .map(|e| match e {
                        super::menu::MenuEntry::Separator => {
                            (String::new(), "---".to_string(), String::new(), String::new(), None, None)
                        }
                        super::menu::MenuEntry::DynamicSubmenu { label, kind } => {
                            let cmd = match kind {
                                super::menu::SubmenuKind::Workspace => "workspace_submenu",
                                super::menu::SubmenuKind::Appearance => "appearance_submenu",
                            };
                            (String::new(), strip_mnemonic(label), cmd.to_string(), String::new(), None, None)
                        }
                        super::menu::MenuEntry::Action {
                            id,
                            label,
                            action,
                            params,
                            shortcut,
                            enabled_when,
                            checked_when,
                        } => (
                            id.clone(),
                            strip_mnemonic(label),
                            cmd_for(action, params),
                            shortcut.clone(),
                            enabled_when.clone(),
                            checked_when.clone(),
                        ),
                    })
                    .collect();
                (strip_mnemonic(&m.label), items)
            })
            .collect();
    let menus = &menus_owned;

    // Live menu evaluation context — the exact namespace shape the bundle's
    // enabled_when / checked_when predicates read (and the menu_state gate
    // pins). Built once per render from AppState; Dioxus re-renders reactively,
    // so each item's enable / check reflects the live document + layout.
    let menu_ctx = build_menu_ctx(&app.borrow());

    // Workspace data for dynamic submenu
    let config_snapshot = app.borrow().app_config.clone();
    let active_layout_name = config_snapshot.active_layout.clone();
    let saved_layout_names = config_snapshot.saved_layouts.clone();

    // Pre-build each menu dropdown as a complete VNode
    let menu_nodes: Vec<Result<VNode, RenderError>> = menus.iter().enumerate().map(|(mi, (menu_name, items))| {
        let menu_name_str = menu_name.to_string();
        let menu_name_str2 = menu_name_str.clone();
        let is_open = open_menu() == Some(menu_name_str.clone());
        let dispatch = dispatch.clone();
        let mut open_menu_sig = open_menu;

        // Pre-build item nodes for this menu
        let item_nodes: Vec<Result<VNode, RenderError>> = if is_open {
            items.iter().flat_map(|(item_id, label, cmd, shortcut, enabled_when, checked_when)| {
                if label.as_str() == "---" {
                    vec![rsx! {
                        div {
                            style: "height:1px; background:{THEME_BORDER}; margin:4px 8px;",
                        }
                    }]
                } else if cmd.as_str() == "workspace_submenu" {
                    // Dynamic workspace submenu
                    let act_ws = act.clone();
                    let open_menu_ws = open_menu_sig;
                    let active_name = active_layout_name.clone();
                    let has_saved_layout = active_name != super::workspace::WORKSPACE_LAYOUT_NAME;
                    // The listed layouts and their checks: one rule, pinned by
                    // submenu_entries.json (`menu_state::workspace_entries`).
                    let visible_layouts: Vec<(String, bool)> =
                        crate::interpreter::menu_state::workspace_entries(&saved_layout_names, &active_name)
                            .as_array().into_iter().flatten()
                            .map(|e| (e["name"].as_str().unwrap_or_default().to_string(),
                                      e["checked"].as_bool().unwrap_or(false)))
                            .collect();

                    let mut items: Vec<Result<VNode, RenderError>> = Vec::new();

                    // Submenu trigger with nested flyout
                    items.push({
                        let sub_open = workspace_submenu_open();
                        rsx! {
                            div {
                                style: "position:relative;",
                                onmouseenter: move |_| { workspace_submenu_open.set(true); },
                                onmouseleave: move |_| { workspace_submenu_open.set(false); },

                                div {
                                    class: "jas-menu-item",
                                    style: "padding:4px 24px 4px 16px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; display:flex; justify-content:space-between; white-space:nowrap; border-radius:3px; margin:0 4px;",
                                    span { "{label}" }
                                }

                                if sub_open {
                                    div {
                                        style: "position:absolute; left:100%; top:0; background:{THEME_BG}; border:1px solid {THEME_BORDER}; box-shadow:2px 2px 8px rgba(0,0,0,0.4); min-width:180px; z-index:1001; padding:4px 0; border-radius:4px;",
                                        onmouseenter: move |_| { workspace_submenu_open.set(true); },

                                        // List saved layouts with check mark
                                        for (name, is_active) in visible_layouts.clone() {
                                            {
                                                let act = act_ws.clone();
                                                let check = if is_active { "\u{2713} " } else { "    " };
                                                let display = format!("{check}{name}");
                                                let name_clone = name.clone();
                                                let mut open_menu_cl = open_menu_ws;
                                                rsx! {
                                                    div {
                                                        class: "jas-menu-item",
                                                        style: "padding:4px 16px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; white-space:nowrap; border-radius:3px; margin:0 4px;",
                                                        onmousedown: move |evt: Event<MouseData>| {
                                                            evt.stop_propagation();
                                                            let n = name_clone.clone();
                                                            (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                                                                st.switch_layout(&n);
                                                            }));
                                                            open_menu_cl.set(None);
                                                            workspace_submenu_open.set(false);
                                                        },
                                                        "{display}"
                                                    }
                                                }
                                            }
                                        }

                                        // Separator
                                        div { style: "height:1px; background:{THEME_BORDER}; margin:4px 8px;" }

                                        // Save As...
                                        {
                                            let mut open_menu_cl = open_menu_ws;
                                            let app_save_as = app.clone();
                                            rsx! {
                                                div {
                                                    class: "jas-menu-item",
                                                    style: "padding:4px 16px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; white-space:nowrap; border-radius:3px; margin:0 4px;",
                                                    onmousedown: move |evt: Event<MouseData>| {
                                                        evt.stop_propagation();
                                                        // Open via YAML dialog system
                                                        let st = app_save_as.borrow();
                                                        let live_state = crate::workspace::dock_panel::build_live_state_map(&st);
                                                        drop(st);
                                                        crate::interpreter::dialog_view::open_dialog(
                                                            &mut yaml_dialog_sig,
                                                            "workspace_save_as",
                                                            &serde_json::Map::new(),
                                                            &live_state,
                                                        );
                                                        open_menu_cl.set(None);
                                                        workspace_submenu_open.set(false);
                                                    },
                                                    "Save As\u{2026}"
                                                }
                                            }
                                        }

                                        // Separator
                                        div { style: "height:1px; background:{THEME_BORDER}; margin:4px 8px;" }

                                        // Reset to Default
                                        {
                                            let act = act_ws.clone();
                                            let mut open_menu_cl = open_menu_ws;
                                            rsx! {
                                                div {
                                                    class: "jas-menu-item",
                                                    style: "padding:4px 16px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; white-space:nowrap; border-radius:3px; margin:0 4px;",
                                                    onmousedown: move |evt: Event<MouseData>| {
                                                        evt.stop_propagation();
                                                        (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                                                            st.reset_to_default();
                                                        }));
                                                        open_menu_cl.set(None);
                                                        workspace_submenu_open.set(false);
                                                    },
                                                    "Reset to Default"
                                                }
                                            }
                                        }

                                        // Revert to Saved (enabled only when a named layout is selected)
                                        {
                                            let act = act_ws.clone();
                                            let mut open_menu_cl = open_menu_ws;
                                            let disabled_style = if has_saved_layout {
                                                format!("padding:4px 16px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; white-space:nowrap; border-radius:3px; margin:0 4px;")
                                            } else {
                                                format!("padding:4px 16px; cursor:default; font-size:13px; color:{THEME_TEXT_DIM}; white-space:nowrap; border-radius:3px; margin:0 4px;")
                                            };
                                            rsx! {
                                                div {
                                                    class: if has_saved_layout { "jas-menu-item" } else { "" },
                                                    style: "{disabled_style}",
                                                    onmousedown: move |evt: Event<MouseData>| {
                                                        evt.stop_propagation();
                                                        if has_saved_layout {
                                                            (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                                                                st.revert_to_saved();
                                                            }));
                                                            open_menu_cl.set(None);
                                                            workspace_submenu_open.set(false);
                                                        }
                                                    },
                                                    "Revert to Saved"
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    });
                    items
                } else if cmd.as_str() == "appearance_submenu" {
                    // Dynamic appearance submenu
                    let mut open_menu_ap = open_menu_sig;

                    // Read available appearances and active name from JS
                    let appearances: Vec<(String, String)> = {
                        let json = js_sys::eval("getAppearanceList()")
                            .ok()
                            .and_then(|v| v.as_string())
                            .unwrap_or_else(|| "[]".to_string());
                        #[derive(serde::Deserialize)]
                        struct AppEntry { name: String, label: String }
                        serde_json::from_str::<Vec<AppEntry>>(&json)
                            .unwrap_or_default()
                            .into_iter()
                            .map(|e| (e.name, e.label))
                            .collect()
                    };
                    let active_appearance = js_sys::eval("getActiveAppearance()")
                        .ok()
                        .and_then(|v| v.as_string());
                    // The rows and their checks: one rule, pinned by
                    // submenu_entries.json (`menu_state::appearance_entries`).
                    let appearance_rows: Vec<(String, String, bool)> =
                        crate::interpreter::menu_state::appearance_entries(&appearances, active_appearance.as_deref())
                            .as_array().into_iter().flatten()
                            .map(|e| (e["name"].as_str().unwrap_or_default().to_string(),
                                      e["label"].as_str().unwrap_or_default().to_string(),
                                      e["checked"].as_bool().unwrap_or(false)))
                            .collect();

                    let mut items: Vec<Result<VNode, RenderError>> = Vec::new();
                    items.push({
                        let sub_open = appearance_submenu_open();
                        rsx! {
                            div {
                                style: "position:relative;",
                                onmouseenter: move |_| { appearance_submenu_open.set(true); },
                                onmouseleave: move |_| { appearance_submenu_open.set(false); },

                                div {
                                    class: "jas-menu-item",
                                    style: "padding:4px 24px 4px 16px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; display:flex; justify-content:space-between; white-space:nowrap; border-radius:3px; margin:0 4px;",
                                    span { "{label}" }
                                }

                                if sub_open {
                                    div {
                                        style: "position:absolute; left:100%; top:0; background:{THEME_BG}; border:1px solid {THEME_BORDER}; box-shadow:2px 2px 8px rgba(0,0,0,0.4); min-width:180px; z-index:1001; padding:4px 0; border-radius:4px;",
                                        onmouseenter: move |_| { appearance_submenu_open.set(true); },

                                        for (name, app_label, is_active) in appearance_rows.clone() {
                                            {
                                                let check = if is_active { "\u{2713} " } else { "    " };
                                                let display = format!("{check}{app_label}");
                                                let name_clone = name.clone();
                                                rsx! {
                                                    div {
                                                        class: "jas-menu-item",
                                                        style: "padding:4px 16px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; white-space:nowrap; border-radius:3px; margin:0 4px;",
                                                        onmousedown: move |evt: Event<MouseData>| {
                                                            evt.stop_propagation();
                                                            let _ = js_sys::eval(&format!("applyAppearance('{}')", name_clone));
                                                            open_menu_ap.set(None);
                                                            appearance_submenu_open.set(false);
                                                        },
                                                        "{display}"
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    });
                    items
                } else {
                    let dispatch = dispatch.clone();
                    let cmd = cmd.to_string();
                    let mut open_menu_sig2 = open_menu_sig;
                    // Evaluate the bundle predicates against the live menu ctx
                    // (replacing the prior hardcoded per-PanelKind checkmark
                    // match + always-enabled items). A non-empty enabled_when
                    // gates the item; an empty/absent one stays enabled. A
                    // checked_when makes the item show a check glyph when true
                    // and a blank-aligned indent when false; items without one
                    // keep the plain indent. Same eval the menu_state gate pins.
                    let enabled = match enabled_when {
                        Some(e) if !e.is_empty() => {
                            crate::interpreter::expr::eval(e, &menu_ctx).to_bool()
                        }
                        _ => true,
                    };
                    let checked: Option<bool> = match checked_when {
                        Some(c) if !c.is_empty() => {
                            Some(crate::interpreter::expr::eval(c, &menu_ctx).to_bool())
                        }
                        _ => None,
                    };
                    let display_label = match checked {
                        Some(true) => format!("\u{2713} {}", label),
                        _ => format!("    {}", label),
                    };
                    let item_class = if enabled { "jas-menu-item" } else { "" };
                    let cursor = if enabled { "pointer" } else { "default" };
                    let text_color = if enabled { THEME_TEXT } else { THEME_TEXT_DIM };
                    let dom_id = item_id.clone();
                    vec![rsx! {
                        div {
                            id: "{dom_id}",
                            class: "{item_class}",
                            style: "padding:4px 24px 4px 8px; cursor:{cursor}; font-size:13px; color:{text_color}; display:flex; justify-content:space-between; white-space:nowrap; border-radius:3px; margin:0 4px;",
                            onmousedown: move |evt: Event<MouseData>| {
                                evt.stop_propagation();
                                // Disabled items are inert (mirrors the Revert-to-Saved
                                // gate above): no dispatch, menu stays open.
                                if enabled {
                                    dispatch(&cmd);
                                    open_menu_sig2.set(None);
                                }
                            },
                            span { "{display_label}" }
                            span {
                                style: "color:{THEME_TEXT_HINT}; margin-left:24px; font-size:12px;",
                                "{shortcut}"
                            }
                        }
                    }]
                }
            }).collect()
        } else {
            Vec::new()
        };

        let bg = if is_open { THEME_BG_ACTIVE } else { "transparent" };
        rsx! {
            div {
                key: "menu-{mi}",
                style: "position:relative; display:inline-block;",
                div {
                    class: "jas-menu-title",
                    style: "padding:3px 8px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; user-select:none; border-radius:3px; background:{bg};",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        panel_menu.open.set(None);
                        let name = menu_name_str2.clone();
                        if open_menu() == Some(name.clone()) {
                            open_menu_sig.set(None);
                        } else {
                            open_menu_sig.set(Some(name));
                        }
                    },
                    "{menu_name_str}"
                }
                if is_open {
                    div {
                        style: "position:absolute; top:100%; left:0; background:{THEME_BG}; border:1px solid {THEME_BORDER}; box-shadow:2px 2px 8px rgba(0,0,0,0.4); min-width:200px; z-index:1000; padding:4px 0;",
                        for node in item_nodes {
                            {node}
                        }
                    }
                }
            }
        }
    }).collect();

    rsx! {
        div {
            style: "display:flex; background:{THEME_BG}; border-bottom:1px solid {THEME_BORDER}; padding:0 4px; min-height:24px; align-items:center; flex-shrink:0; z-index:300;",
            onmousedown: move |evt: Event<MouseData>| {
                evt.stop_propagation();
            },
            span {
                style: "display:inline-block; width:45px; height:20px; flex-shrink:0; margin-right:4px;",
                dangerous_inner_html: BRAND_LOGO_SVG,
            }
            for node in menu_nodes {
                {node}
            }
        }
    }
}

/// Build the menu evaluation context (TESTING_STRATEGY.md chrome seam): the
/// exact namespaces the bundle's `enabled_when` / `checked_when` predicates
/// read. Its shape matches the seeded contexts in
/// `test_fixtures/algorithms/menu_state.json` so the live menu evaluates
/// precisely what the cross-app `menu_state` gate pins. Mirrors the per-app
/// menu ctx built in the other apps (Python `menu.menu._build_menu_ctx`).
///
/// - `state.tab_count`: open tab count.
/// - `active_document.*`: the 7 document predicates (selection, undo/redo,
///   modified, has_filename = filename does NOT start with "Untitled-",
///   active_layer_locked).
/// - `workspace.has_saved_layout`: active layout != the system "Workspace".
/// - `panels.<id>`: panel_on_screen for all 16 Window-menu panel ids.
/// - `panes.<id>`: is_pane_visible for toolbar / dock.
fn build_menu_ctx(st: &AppState) -> serde_json::Value {
    use super::workspace::{PaneKind, PanelKind, WORKSPACE_LAYOUT_NAME};
    use serde_json::Value as J;

    let active_document = match st.tab() {
        Some(tab) => {
            let m = &tab.model;
            let doc = m.document();
            serde_json::json!({
                "has_selection": !doc.selection.is_empty(),
                "selection_count": doc.selection.len(),
                "can_undo": m.can_undo(),
                "can_redo": m.can_redo(),
                "is_modified": m.is_modified(),
                "has_filename": !m.filename.starts_with("Untitled-"),
                // §15's VISIBLE HALF: `paste` and `paste_in_place` grey out
                // while the active layer is locked, so the refusal the paste
                // body enforces is seen BEFORE the artist presses Cmd+V rather
                // than experienced as a key that does nothing. It reads
                // `Document::active_layer_locked` — the very function the
                // refusal reads — so the menu and the code cannot disagree.
                "active_layer_locked": doc.active_layer_locked(),
            })
        }
        None => serde_json::json!({
            "has_selection": false,
            "selection_count": 0,
            "can_undo": false,
            "can_redo": false,
            "is_modified": false,
            "has_filename": false,
            // No document: paste is already disabled by `state.tab_count > 0`,
            // and "the active layer of no document" is not locked.
            "active_layer_locked": false,
        }),
    };

    // Window-menu panel id -> PanelKind (the `panels.*` namespace). All 16
    // dock panels now have a PanelKind, so each check mark tracks live
    // `is_panel_visible` group membership (gradient / concepts included).
    let panel_kinds: [(&str, PanelKind); 16] = [
        ("artboards", PanelKind::Artboards),
        ("layers", PanelKind::Layers),
        ("color", PanelKind::Color),
        ("swatches", PanelKind::Swatches),
        ("brushes", PanelKind::Brushes),
        ("gradient", PanelKind::Gradient),
        ("stroke", PanelKind::Stroke),
        ("properties", PanelKind::Properties),
        ("character", PanelKind::Character),
        ("paragraph", PanelKind::Paragraph),
        ("align", PanelKind::Align),
        ("boolean", PanelKind::Boolean),
        ("magic_wand", PanelKind::MagicWand),
        ("opacity", PanelKind::Opacity),
        ("symbols", PanelKind::Symbols),
        ("concepts", PanelKind::Concepts),
    ];
    let mut panels = serde_json::Map::new();
    for (id, kind) in panel_kinds {
        panels.insert(id.to_string(), J::Bool(st.workspace_layout.panel_on_screen(kind)));
    }

    let mut panes = serde_json::Map::new();
    for (id, kind) in [("toolbar", PaneKind::Toolbar), ("dock", PaneKind::Dock)] {
        let visible = st
            .workspace_layout
            .pane_layout
            .as_ref()
            .is_some_and(|pl| pl.is_pane_visible(kind));
        panes.insert(id.to_string(), J::Bool(visible));
    }

    serde_json::json!({
        "state": { "tab_count": st.tabs.len() },
        "active_document": active_document,
        "workspace": {
            "has_saved_layout": st.app_config.active_layout != WORKSPACE_LAYOUT_NAME,
        },
        "panels": J::Object(panels),
        "panes": J::Object(panes),
    })
}

/// Strip Windows/GTK-style `&` mnemonic markers from a label for display.
/// The bundle labels (e.g. `&File`, `Zoom &In`) mark the accelerator key for
/// frameworks that support mnemonics; the Dioxus menu bar does not, so the
/// marker is removed for display. `&&` is an escaped literal ampersand → `&`.
fn strip_mnemonic(label: &str) -> String {
    let mut out = String::with_capacity(label.len());
    let mut chars = label.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '&' {
            if chars.peek() == Some(&'&') {
                out.push('&');
                chars.next();
            }
            // otherwise drop the mnemonic marker
        } else {
            out.push(c);
        }
    }
    out
}

/// Translate a bundle menu `(action, params)` into the legacy command string
/// the menu dispatch + checkmark logic key on. Actions with a bespoke handler
/// keep their historical cmd name; `toggle_pane`/`toggle_panel` fold their
/// param into the per-target cmd; everything else passes through (handled by
/// the generic `dispatch_action` arm).
fn cmd_for(action: &str, params: &serde_json::Map<String, serde_json::Value>) -> String {
    match action {
        "new_document" => "new".to_string(),
        "open_file" => "open".to_string(),
        "open_document_setup" => "document_setup".to_string(),
        "open_print_dialog" => "print".to_string(),
        "hide_selection" => "hide".to_string(),
        "toggle_pane" => format!(
            "toggle_pane_{}",
            params.get("pane").and_then(|v| v.as_str()).unwrap_or("")
        ),
        "toggle_panel" => format!(
            "toggle_panel_{}",
            params.get("panel").and_then(|v| v.as_str()).unwrap_or("")
        ),
        other => other.to_string(),
    }
}

/// Strip a known extension from a filename so we can append a new one
/// (`Untitled.svg` → `Untitled` → `Untitled.pdf`). Falls back to the
/// raw filename when no extension matches; an empty filename returns
/// `"Untitled"`.
fn filename_stem(filename: &str) -> String {
    let trimmed = filename.trim();
    if trimmed.is_empty() {
        return "Untitled".to_string();
    }
    for ext in [".svg", ".pdf", ".jas"] {
        if let Some(stripped) = trimmed.strip_suffix(ext) {
            return stripped.to_string();
        }
    }
    trimmed.to_string()
}

/// Run one of the menu's model verbs on the active tab, as the web menu and
/// the web keyboard both do: those whose YAML is `doc.op` (the op layer by
/// name) run the declared action, the rest the shared native table
/// (`menu_native`). `hide` is `hide_selection`'s cmd name. `false` (nothing
/// run) for any other name.
pub(crate) fn run_model_verb(cmd: &str, st: &mut AppState) -> bool {
    match cmd {
        "select_all" | "unlock_all" | "hide" | "show_all" | "lock" | "group" | "ungroup"
        | "ungroup_all" => {
            let action = if cmd == "hide" { "hide_selection" } else { cmd };
            let _ = crate::interpreter::renderer::dispatch_action(
                action, &serde_json::Map::new(), st);
            true
        }
        _ if super::menu_native::VERBS.contains(&cmd) => {
            if let Some(tab) = st.tab_mut() {
                super::menu_native::run(cmd, &mut tab.model);
            }
            true
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state_on(svg: &str) -> AppState {
        let mut st = AppState::new();
        st.add_tab(TabState::new());
        st.tabs[st.active_tab].model = crate::document::model::Model::new(
            crate::geometry::svg::svg_to_document(svg), None);
        st
    }

    fn selected_paths(st: &AppState) -> Vec<Vec<usize>> {
        let mut p: Vec<Vec<usize>> = st.tabs[st.active_tab].model.document()
            .selection.iter().map(|es| es.path.clone()).collect();
        p.sort();
        p
    }

    /// Select All on the web (menu and Cmd+A) runs its YAML, `doc.op:
    /// {op: select_all}`: every visible, unlocked direct child of a layer, a
    /// group as one object, and selecting is not an undo step.
    #[test]
    fn select_all_runs_its_yaml_and_records_no_undo_step() {
        let mut st = state_on(include_str!("../../../test_fixtures/svg/locked_inheritance.svg"));
        assert!(run_model_verb("select_all", &mut st));
        assert_eq!(selected_paths(&st), vec![vec![1, 2], vec![1, 3]],
                   "the cyan rect and the Mixed Group; nothing locked");
        assert!(!st.tabs[st.active_tab].model.can_undo(), "select_all recorded an undo step");
    }

    /// The `doc.op` verbs the web keyboard reaches (Cmd+2, Cmd+Alt+2, Cmd+3,
    /// Cmd+Alt+3) are each ONE undo step on this route, as the native table
    /// made them with `with_txn`.
    #[test]
    fn the_doc_op_verbs_are_each_one_undo_step_on_the_web_route() {
        let svg = include_str!("../../../test_fixtures/svg/two_rects.svg");
        let locked = |st: &AppState| -> Vec<bool> {
            st.tabs[st.active_tab].model.document().layers[0].children()
                .map(|cs| cs.iter().map(|c| c.locked()).collect()).unwrap_or_default()
        };
        let hidden = |st: &AppState| -> Vec<bool> {
            st.tabs[st.active_tab].model.document().layers[0].children()
                .map(|cs| cs.iter().map(|c| c.visibility() == crate::geometry::element::Visibility::Invisible).collect())
                .unwrap_or_default()
        };
        let mut st = state_on(svg);
        run_model_verb("select_all", &mut st);
        assert!(run_model_verb("lock", &mut st));
        assert_eq!(locked(&st), vec![true, true], "lock");
        st.tab_mut().unwrap().model.undo();
        assert_eq!(locked(&st), vec![false, false], "one undo restores lock");
        run_model_verb("lock", &mut st);
        assert!(run_model_verb("unlock_all", &mut st));
        assert_eq!(locked(&st), vec![false, false], "unlock_all");
        st.tab_mut().unwrap().model.undo();
        assert_eq!(locked(&st), vec![true, true], "one undo restores unlock_all");

        let mut st = state_on(svg);
        run_model_verb("select_all", &mut st);
        assert!(run_model_verb("hide", &mut st));
        assert_eq!(hidden(&st), vec![true, true], "hide is hide_selection");
        st.tab_mut().unwrap().model.undo();
        assert_eq!(hidden(&st), vec![false, false], "one undo restores hide");
        run_model_verb("hide", &mut st);
        assert!(run_model_verb("show_all", &mut st));
        assert_eq!(hidden(&st), vec![false, false], "show_all");
        st.tab_mut().unwrap().model.undo();
        assert_eq!(hidden(&st), vec![true, true], "one undo restores show_all");
    }

    /// Group, Ungroup and Ungroup All run their YAML (`snapshot` + `doc.op`)
    /// from the web menu and Cmd+G / Cmd+Shift+G: each ONE undo step, as the
    /// native table made them with `with_txn`.
    #[test]
    fn the_group_verbs_are_each_one_undo_step_on_the_web_route() {
        let kinds = |st: &AppState| -> Vec<&'static str> {
            st.tabs[st.active_tab].model.document().layers[0].children()
                .map(|cs| cs.iter().map(|c| if c.is_group() { "group" } else { "leaf" }).collect())
                .unwrap_or_default()
        };
        let mut st = state_on(include_str!("../../../test_fixtures/svg/two_rects.svg"));
        run_model_verb("select_all", &mut st);
        assert!(run_model_verb("group", &mut st));
        assert_eq!(kinds(&st), vec!["group"], "group");
        assert_eq!(selected_paths(&st), vec![vec![0, 0]], "the new group is selected");
        assert!(run_model_verb("ungroup", &mut st));
        assert_eq!(kinds(&st), vec!["leaf", "leaf"], "ungroup");
        assert_eq!(selected_paths(&st), vec![vec![0, 0], vec![0, 1]], "its members are selected");
        st.tab_mut().unwrap().model.undo();
        assert_eq!(kinds(&st), vec!["group"], "one undo restores ungroup");
        st.tab_mut().unwrap().model.undo();
        assert_eq!(kinds(&st), vec!["leaf", "leaf"], "one more restores group");

        let mut st = state_on(include_str!("../../../test_fixtures/svg/group_nested.svg"));
        assert!(run_model_verb("ungroup_all", &mut st));
        assert_eq!(kinds(&st), vec!["leaf", "leaf"], "ungroup_all");
        st.tab_mut().unwrap().model.undo();
        assert_eq!(kinds(&st), vec!["group"], "one undo restores ungroup_all");
        assert!(!st.tabs[st.active_tab].model.can_undo(), "ungroup_all was ONE step");
    }

    #[test]
    fn run_model_verb_refuses_anything_else() {
        let mut st = state_on(include_str!("../../../test_fixtures/svg/two_rects.svg"));
        for other in ["copy", "paste", "delete", "", "Select_all", "hide_selection"] {
            assert!(!run_model_verb(other, &mut st), "{other:?}");
        }
        assert!(selected_paths(&st).is_empty());
    }

    #[test]
    fn filename_stem_strips_known_extensions() {
        assert_eq!(filename_stem("Untitled.svg"), "Untitled");
        assert_eq!(filename_stem("art.pdf"), "art");
        assert_eq!(filename_stem("doc.jas"), "doc");
    }

    #[test]
    fn filename_stem_keeps_unknown_extension() {
        assert_eq!(filename_stem("photo.png"), "photo.png");
    }

    #[test]
    fn filename_stem_empty_yields_untitled() {
        assert_eq!(filename_stem(""), "Untitled");
        assert_eq!(filename_stem("   "), "Untitled");
    }

    #[test]
    fn live_menu_ctx_drives_enabled_and_checked() {
        // Mirror of the Python LiveMenuStateWiringTest idea: seed a live
        // AppState, build the menu ctx, and assert the bundle predicates the
        // renderer now evaluates yield the right enable / check state — the
        // SAME evaluation the cross-app menu_state gate pins.
        use crate::document::document::{Document, ElementSelection};
        use crate::workspace::workspace::PanelKind;

        let mut st = AppState::new();
        if st.tabs.is_empty() {
            st.tabs.push(TabState::new());
            st.active_tab = 0;
        }
        // Seed a 2-element selection (selection_count == 2). build_menu_ctx
        // reads only doc.selection.len(), so placeholder paths suffice.
        let doc = Document {
            selection: vec![
                ElementSelection::all(vec![0, 0]),
                ElementSelection::all(vec![0, 1]),
            ],
            ..Document::default()
        };
        st.tabs[st.active_tab].model.set_document_for_test(doc);

        let ctx = build_menu_ctx(&st);
        let eval = |e: &str| crate::interpreter::expr::eval(e, &ctx).to_bool();

        // enabled_when wiring with 2 selected: group (>= 2) enabled,
        // make_instance (== 1) disabled, copy (has_selection) enabled,
        // tab-gated items (tab_count > 0) enabled.
        assert!(eval("active_document.selection_count >= 2"), "group enabled @ 2 selected");
        assert!(!eval("active_document.selection_count == 1"), "make_instance disabled @ 2 selected");
        assert!(eval("active_document.has_selection"), "copy enabled with a selection");
        assert!(eval("state.tab_count > 0"), "tab-gated items enabled with an open tab");

        // §15's VISIBLE HALF. Lock the ACTIVE layer and nothing else: `paste`
        // and `paste_in_place` must grey out, while `paste_preserving_layers`,
        // which DIVERTS rather than refusing, must stay available. The
        // asymmetry IS the ruling, so it is asserted rather than assumed.
        //
        // WHY THIS ASSERTION HAS TO LIVE HERE AND CANNOT BE THE SHARED GATE:
        // the cross-app `menu_state` corpus SEEDS its context, so it pins how
        // the predicate is EVALUATED and is structurally blind to a port that
        // forgets to BUILD the key. A missing key evaluates to null -> false ->
        // `!false` -> paste stays enabled, which is silently the pre-ruling
        // behaviour. Only a live-ctx assertion catches that; the Swift twin is
        // `liveMenuCtxDrivesEnabledAndChecked`.
        let paste_expr = "state.tab_count > 0 && !active_document.active_layer_locked";
        assert!(eval(paste_expr), "paste enabled while the active layer is open");
        {
            use crate::geometry::element::{CommonProps, Element, LayerElem};
            let mut locked_doc = Document::default();
            locked_doc.layers = vec![Element::Layer(LayerElem {
                children: Vec::new(),
                common: CommonProps { locked: true, ..CommonProps::default() },
                isolated_blending: false,
                knockout_group: false,
            })];
            let mut st_locked = AppState::new();
            if st_locked.tabs.is_empty() {
                st_locked.tabs.push(TabState::new());
                st_locked.active_tab = 0;
            }
            st_locked.tabs[st_locked.active_tab]
                .model
                .set_document_for_test(locked_doc);
            let lctx = build_menu_ctx(&st_locked);
            let leval = |e: &str| crate::interpreter::expr::eval(e, &lctx).to_bool();
            assert!(
                !leval(paste_expr),
                "paste must grey out on a locked active layer"
            );
            assert!(
                leval("state.tab_count > 0"),
                "preserving paste DIVERTS rather than refusing, so its own \
                 predicate stays true and unrelated tab-gated items stay enabled"
            );
        }

        // checked_when wiring: panels.<id> must equal live panel_on_screen
        // (what is DRAWN), not mere group membership.
        crate::workspace::layout_apply::layout_apply(
            &mut st.workspace_layout,
            &crate::workspace::layout_apply::op_show_panel(PanelKind::Layers),
        );
        let ctx2 = build_menu_ctx(&st);
        let eval2 = |e: &str| crate::interpreter::expr::eval(e, &ctx2).to_bool();
        assert_eq!(
            eval2("panels.layers"),
            st.workspace_layout.panel_on_screen(PanelKind::Layers),
            "panels.layers checked_when must equal panel_on_screen",
        );
        assert!(eval2("panels.layers"), "Layers checked after op_show_panel");
        // concepts now HAS a PanelKind but is not in the default layout, so it
        // is still unchecked until summoned; gradient likewise.
        assert!(!eval2("panels.concepts"), "concepts unchecked (not in a group)");
        assert!(!eval2("panels.gradient"), "gradient unchecked (not in a group)");
        // Summon concepts via the generic toggle path -> now checked.
        st.workspace_layout.show_panel_in_last_group(PanelKind::Concepts);
        let ctx3 = build_menu_ctx(&st);
        let eval3 = |e: &str| crate::interpreter::expr::eval(e, &ctx3).to_bool();
        assert!(eval3("panels.concepts"), "concepts checked after summon");
    }

    // The bug (JYH live): Window > Gradient did nothing in the Rust app,
    // because gradient/concepts had no PanelKind and no dispatch arm (concepts
    // hit the log-stub). These tests drive the ACTUAL production path —
    // `dispatch_action("toggle_panel", {panel})` — that the collapsed generic
    // menu arm now routes through, for the two panels that were unreachable.
    fn toggle_panel(st: &mut AppState, panel: &str) {
        let mut p = serde_json::Map::new();
        p.insert("panel".to_string(), serde_json::json!(panel));
        let _ = crate::interpreter::renderer::dispatch_action("toggle_panel", &p, st);
    }

    fn seeded_state() -> AppState {
        let mut st = AppState::new();
        if st.tabs.is_empty() {
            st.tabs.push(TabState::new());
            st.active_tab = 0;
        }
        st
    }

    #[test]
    fn toggle_panel_gradient_shows_in_last_group_then_hides() {
        use crate::workspace::workspace::PanelKind;
        let mut st = seeded_state();
        let (_, dock) = st.workspace_layout.anchored.first().unwrap();
        let dock_id = dock.id;
        let last = dock.groups.len() - 1;
        assert!(!st.workspace_layout.is_panel_visible(PanelKind::Gradient));

        // First toggle: SHOW -> lands in dock_main's LAST group, activated.
        toggle_panel(&mut st, "gradient");
        assert!(st.workspace_layout.is_panel_visible(PanelKind::Gradient));
        let g = st.workspace_layout.dock(dock_id).unwrap();
        assert!(
            g.groups[last].panels.contains(&PanelKind::Gradient),
            "gradient summoned into the LAST group of dock_main",
        );
        assert_eq!(
            g.groups[last].active,
            g.groups[last].panels.len() - 1,
            "gradient is the active tab",
        );

        // Second toggle: HIDE.
        toggle_panel(&mut st, "gradient");
        assert!(!st.workspace_layout.is_panel_visible(PanelKind::Gradient));
    }

    #[test]
    fn toggle_panel_concepts_shows_then_hides() {
        use crate::workspace::workspace::PanelKind;
        let mut st = seeded_state();
        assert!(!st.workspace_layout.is_panel_visible(PanelKind::Concepts));
        toggle_panel(&mut st, "concepts");
        assert!(st.workspace_layout.is_panel_visible(PanelKind::Concepts));
        toggle_panel(&mut st, "concepts");
        assert!(!st.workspace_layout.is_panel_visible(PanelKind::Concepts));
    }

    #[test]
    fn toggle_off_last_panel_in_group_removes_the_group() {
        use crate::workspace::workspace::PanelKind;
        let mut st = seeded_state();
        let (_, dock) = st.workspace_layout.anchored.first().unwrap();
        let dock_id = dock.id;
        let before = dock.groups.len();
        // Default group 0 = [color, swatches] — a TAB STACK, so only Color
        // is drawn. Swatches is a member that is on screen nowhere, and the
        // toggle raises it before it can hide it.
        assert!(st.workspace_layout.panel_on_screen(PanelKind::Color));
        assert!(!st.workspace_layout.panel_on_screen(PanelKind::Swatches));
        toggle_panel(&mut st, "swatches"); // raise: Swatches to the front
        assert!(st.workspace_layout.panel_on_screen(PanelKind::Swatches));
        assert!(!st.workspace_layout.panel_on_screen(PanelKind::Color));
        toggle_panel(&mut st, "swatches"); // now drawn, so this hides it
        toggle_panel(&mut st, "color"); // sole survivor, drawn again, hides
        assert!(!st.workspace_layout.is_panel_visible(PanelKind::Color));
        assert!(!st.workspace_layout.is_panel_visible(PanelKind::Swatches));
        let after = st.workspace_layout.dock(dock_id).unwrap().groups.len();
        assert_eq!(after, before - 1, "emptied group auto-removed on toggle-off");
    }

    #[test]
    fn strip_mnemonic_removes_markers() {
        assert_eq!(strip_mnemonic("&File"), "File");
        assert_eq!(strip_mnemonic("Zoom &In"), "Zoom In");
        assert_eq!(strip_mnemonic("Save &As..."), "Save As...");
        assert_eq!(strip_mnemonic("Fit A&ll in Window"), "Fit All in Window");
        assert_eq!(strip_mnemonic("Tile"), "Tile");
        assert_eq!(strip_mnemonic("A && B"), "A & B");
    }
}
