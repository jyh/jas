//! Menu bar component.

use std::rc::Rc;

use dioxus::prelude::*;

use super::app_state::{Act, AppHandle, AppState, TabState};
use super::clipboard::{
    clipboard_read_and_paste, clipboard_write, download_bytes, download_file, find_panel,
    open_file_dialog, selection_to_svg,
};
// SaveAsDialog import removed — workspace save-as now uses YAML dialog system
use super::theme::*;
use crate::document::controller::Controller;
use crate::geometry::element::Element as GeoElement;
use crate::geometry::svg::document_to_svg;
use crate::panels::panel_menu_state::{MenuBarState, PanelMenuState};
use crate::tools::tool::PASTE_OFFSET;

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
                        }
                    }));
                }
                "close" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        let idx = st.active_tab;
                        st.close_tab(idx);
                    }));
                }
                "undo" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() { tab.model.undo(); }
                    }));
                }
                "redo" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() { tab.model.redo(); }
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
                            if let Some(svg) = selection_to_svg(st) {
                                clipboard_write(svg);
                            }
                            let elements: Vec<GeoElement> = {
                                let Some(tab) = st.tab() else { return; };
                                let doc = tab.model.document();
                                doc.selection.iter()
                                    .filter_map(|es| doc.get_element(&es.path).cloned())
                                    .collect()
                            };
                            let Some(tab) = st.tab_mut() else { return; };
                            tab.clipboard = elements;
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
                        if let Some(svg) = selection_to_svg(st) {
                            clipboard_write(svg);
                        }
                        let elements: Vec<GeoElement> = {
                            let Some(tab) = st.tab() else { return; };
                            let doc = tab.model.document();
                            doc.selection.iter()
                                .filter_map(|es| doc.get_element(&es.path).cloned())
                                .collect()
                        };
                        let Some(tab) = st.tab_mut() else { return; };
                        tab.clipboard = elements;
                    }));
                }
                "paste" => {
                    clipboard_read_and_paste(
                        app_for_menu.clone(), revision_for_menu, PASTE_OFFSET,
                    );
                }
                "paste_in_place" => {
                    clipboard_read_and_paste(
                        app_for_menu.clone(), revision_for_menu, 0.0,
                    );
                }
                "select_all" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() { Controller::select_all(&mut tab.model); }
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
                "group" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.with_txn(|m| Controller::group_selection(m));
                        }
                    }));
                }
                "ungroup" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.with_txn(|m| Controller::ungroup_selection(m));
                        }
                    }));
                }
                "ungroup_all" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.with_txn(|m| Controller::ungroup_all(m));
                        }
                    }));
                }
                "lock" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.with_txn(|m| Controller::lock_selection(m));
                        }
                    }));
                }
                "unlock_all" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.with_txn(|m| Controller::unlock_all(m));
                        }
                    }));
                }
                "hide" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.with_txn(|m| Controller::hide_selection(m));
                        }
                    }));
                }
                "show_all" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.with_txn(|m| Controller::show_all(m));
                        }
                    }));
                }
                "make_instance" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            make_instance_on_model(&mut tab.model);
                        }
                    }));
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
                // Window menu: panel visibility
                "toggle_panel_layers" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Layers) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Layers) {
                                crate::workspace::layout_apply::layout_apply(
                                    &mut st.workspace_layout,
                                    &crate::workspace::layout_apply::op_close_panel(addr),
                                );
                            }
                        } else {
                            crate::workspace::layout_apply::layout_apply(
                                &mut st.workspace_layout,
                                &crate::workspace::layout_apply::op_show_panel(super::workspace::PanelKind::Layers),
                            );
                        }
                    }));
                }
                "toggle_panel_color" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Color) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Color) {
                                crate::workspace::layout_apply::layout_apply(
                                    &mut st.workspace_layout,
                                    &crate::workspace::layout_apply::op_close_panel(addr),
                                );
                            }
                        } else {
                            crate::workspace::layout_apply::layout_apply(
                                &mut st.workspace_layout,
                                &crate::workspace::layout_apply::op_show_panel(super::workspace::PanelKind::Color),
                            );
                            // Per COLOR.md §Panel initialization rule:
                            // color_panel_mode is panel-local and
                            // resets to its default (HSB) on each
                            // reopen — not persisted across close.
                            st.color_panel_mode = super::color_panel_view::ColorMode::Hsb;
                        }
                    }));
                }
                "toggle_panel_swatches" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Swatches) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Swatches) {
                                crate::workspace::layout_apply::layout_apply(
                                    &mut st.workspace_layout,
                                    &crate::workspace::layout_apply::op_close_panel(addr),
                                );
                            }
                        } else {
                            crate::workspace::layout_apply::layout_apply(
                                &mut st.workspace_layout,
                                &crate::workspace::layout_apply::op_show_panel(super::workspace::PanelKind::Swatches),
                            );
                        }
                    }));
                }
                "toggle_panel_stroke" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Stroke) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Stroke) {
                                crate::workspace::layout_apply::layout_apply(
                                    &mut st.workspace_layout,
                                    &crate::workspace::layout_apply::op_close_panel(addr),
                                );
                            }
                        } else {
                            crate::workspace::layout_apply::layout_apply(
                                &mut st.workspace_layout,
                                &crate::workspace::layout_apply::op_show_panel(super::workspace::PanelKind::Stroke),
                            );
                        }
                    }));
                }
                "toggle_panel_properties" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Properties) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Properties) {
                                crate::workspace::layout_apply::layout_apply(
                                    &mut st.workspace_layout,
                                    &crate::workspace::layout_apply::op_close_panel(addr),
                                );
                            }
                        } else {
                            crate::workspace::layout_apply::layout_apply(
                                &mut st.workspace_layout,
                                &crate::workspace::layout_apply::op_show_panel(super::workspace::PanelKind::Properties),
                            );
                        }
                    }));
                }
                "toggle_panel_character" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Character) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Character) {
                                crate::workspace::layout_apply::layout_apply(
                                    &mut st.workspace_layout,
                                    &crate::workspace::layout_apply::op_close_panel(addr),
                                );
                            }
                        } else {
                            crate::workspace::layout_apply::layout_apply(
                                &mut st.workspace_layout,
                                &crate::workspace::layout_apply::op_show_panel(super::workspace::PanelKind::Character),
                            );
                        }
                    }));
                }
                "toggle_panel_paragraph" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Paragraph) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Paragraph) {
                                crate::workspace::layout_apply::layout_apply(
                                    &mut st.workspace_layout,
                                    &crate::workspace::layout_apply::op_close_panel(addr),
                                );
                            }
                        } else {
                            crate::workspace::layout_apply::layout_apply(
                                &mut st.workspace_layout,
                                &crate::workspace::layout_apply::op_show_panel(super::workspace::PanelKind::Paragraph),
                            );
                        }
                    }));
                }
                "toggle_panel_magic_wand" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::MagicWand) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::MagicWand) {
                                crate::workspace::layout_apply::layout_apply(
                                    &mut st.workspace_layout,
                                    &crate::workspace::layout_apply::op_close_panel(addr),
                                );
                            }
                        } else {
                            crate::workspace::layout_apply::layout_apply(
                                &mut st.workspace_layout,
                                &crate::workspace::layout_apply::op_show_panel(super::workspace::PanelKind::MagicWand),
                            );
                        }
                    }));
                }
                "toggle_panel_artboards" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Artboards) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Artboards) {
                                crate::workspace::layout_apply::layout_apply(
                                    &mut st.workspace_layout,
                                    &crate::workspace::layout_apply::op_close_panel(addr),
                                );
                            }
                        } else {
                            crate::workspace::layout_apply::layout_apply(
                                &mut st.workspace_layout,
                                &crate::workspace::layout_apply::op_show_panel(super::workspace::PanelKind::Artboards),
                            );
                        }
                    }));
                }
                "toggle_panel_symbols" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Symbols) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Symbols) {
                                crate::workspace::layout_apply::layout_apply(
                                    &mut st.workspace_layout,
                                    &crate::workspace::layout_apply::op_close_panel(addr),
                                );
                            }
                        } else {
                            crate::workspace::layout_apply::layout_apply(
                                &mut st.workspace_layout,
                                &crate::workspace::layout_apply::op_show_panel(super::workspace::PanelKind::Symbols),
                            );
                        }
                    }));
                }
                "toggle_panel_align" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Align) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Align) {
                                crate::workspace::layout_apply::layout_apply(
                                    &mut st.workspace_layout,
                                    &crate::workspace::layout_apply::op_close_panel(addr),
                                );
                            }
                        } else {
                            crate::workspace::layout_apply::layout_apply(
                                &mut st.workspace_layout,
                                &crate::workspace::layout_apply::op_show_panel(super::workspace::PanelKind::Align),
                            );
                        }
                    }));
                }
                "toggle_panel_boolean" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Boolean) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Boolean) {
                                crate::workspace::layout_apply::layout_apply(
                                    &mut st.workspace_layout,
                                    &crate::workspace::layout_apply::op_close_panel(addr),
                                );
                            }
                        } else {
                            crate::workspace::layout_apply::layout_apply(
                                &mut st.workspace_layout,
                                &crate::workspace::layout_apply::op_show_panel(super::workspace::PanelKind::Boolean),
                            );
                        }
                    }));
                }
                "toggle_panel_opacity" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Opacity) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Opacity) {
                                crate::workspace::layout_apply::layout_apply(
                                    &mut st.workspace_layout,
                                    &crate::workspace::layout_apply::op_close_panel(addr),
                                );
                            }
                        } else {
                            crate::workspace::layout_apply::layout_apply(
                                &mut st.workspace_layout,
                                &crate::workspace::layout_apply::op_show_panel(super::workspace::PanelKind::Opacity),
                            );
                        }
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
                "save_as" | "revert" | "quit" | "promote_to_concept"
                | "zoom_in" | "zoom_out" | "zoom_to_actual_size"
                | "fit_active_artboard" | "fit_all_artboards" | "fit_in_window" => {
                    let action = cmd.to_string();
                    (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                        let _ = crate::interpreter::renderer::dispatch_action(
                            &action, &serde_json::Map::new(), st);
                    }));
                }
                // Concepts panel toggle: not one of the legacy per-panel arms,
                // so dispatch the generic toggle_panel action with its param.
                "toggle_panel_concepts" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        let mut p = serde_json::Map::new();
                        p.insert("panel".to_string(), serde_json::json!("concepts"));
                        let _ = crate::interpreter::renderer::dispatch_action(
                            "toggle_panel", &p, st);
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
    type MenuItem = (String, String, String, Option<String>, Option<String>);
    let menus_owned: Vec<(String, Vec<MenuItem>)> =
        super::menu::menu_bar_model()
            .iter()
            .map(|m| {
                let items = m
                    .entries
                    .iter()
                    .map(|e| match e {
                        super::menu::MenuEntry::Separator => {
                            ("---".to_string(), String::new(), String::new(), None, None)
                        }
                        super::menu::MenuEntry::DynamicSubmenu { label, kind } => {
                            let cmd = match kind {
                                super::menu::SubmenuKind::Workspace => "workspace_submenu",
                                super::menu::SubmenuKind::Appearance => "appearance_submenu",
                            };
                            (strip_mnemonic(label), cmd.to_string(), String::new(), None, None)
                        }
                        super::menu::MenuEntry::Action {
                            label,
                            action,
                            params,
                            shortcut,
                            enabled_when,
                            checked_when,
                        } => (
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
            items.iter().flat_map(|(label, cmd, shortcut, enabled_when, checked_when)| {
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
                    // Filter out "Workspace" from the layout list
                    let visible_layouts: Vec<String> = saved_layout_names
                        .iter()
                        .filter(|n| n.as_str() != super::workspace::WORKSPACE_LAYOUT_NAME)
                        .cloned()
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
                                        for name in visible_layouts.clone() {
                                            {
                                                let act = act_ws.clone();
                                                let is_active = name == active_name;
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
                        .and_then(|v| v.as_string())
                        .unwrap_or_else(|| "dark_gray".to_string());

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

                                        for (name, app_label) in appearances.clone() {
                                            {
                                                let is_active = name == active_appearance;
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
                    vec![rsx! {
                        div {
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
/// - `active_document.*`: the 6 document predicates (selection, undo/redo,
///   modified, has_filename = filename does NOT start with "Untitled-").
/// - `workspace.has_saved_layout`: active layout != the system "Workspace".
/// - `panels.<id>`: is_panel_visible for the 14 Window-menu panel ids;
///   `concepts` has no `PanelKind` in this app, so it resolves to not-visible.
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
            })
        }
        None => serde_json::json!({
            "has_selection": false,
            "selection_count": 0,
            "can_undo": false,
            "can_redo": false,
            "is_modified": false,
            "has_filename": false,
        }),
    };

    // Window-menu panel id -> PanelKind (the `panels.*` namespace). `concepts`
    // has no PanelKind in this app, so it resolves to not-visible defensively
    // (mirrors Python's `_menu_panel_kinds` getattr fallback).
    let panel_kinds: [(&str, PanelKind); 13] = [
        ("artboards", PanelKind::Artboards),
        ("layers", PanelKind::Layers),
        ("color", PanelKind::Color),
        ("swatches", PanelKind::Swatches),
        ("stroke", PanelKind::Stroke),
        ("properties", PanelKind::Properties),
        ("character", PanelKind::Character),
        ("paragraph", PanelKind::Paragraph),
        ("align", PanelKind::Align),
        ("boolean", PanelKind::Boolean),
        ("magic_wand", PanelKind::MagicWand),
        ("opacity", PanelKind::Opacity),
        ("symbols", PanelKind::Symbols),
    ];
    let mut panels = serde_json::Map::new();
    for (id, kind) in panel_kinds {
        panels.insert(id.to_string(), J::Bool(st.workspace_layout.is_panel_visible(kind)));
    }
    panels.insert("concepts".to_string(), J::Bool(false));

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

/// Object > Make Instance, as a headless mutation on a [`Model`].
///
/// Replaces the single whole-element selection with a by-id reference to it,
/// offset by [`PASTE_OFFSET`], under ONE undo transaction. Shared by the live
/// menu handler (the `"make_instance"` arm above) and the cross-language
/// action corpus, so both drive the identical mutation. No-op unless exactly
/// ONE `All`-kind element is selected (the same guard the menu item's
/// enablement uses).
///
/// The two element ids are minted HERE in the UI layer (NOT inside a
/// `Controller` method — see `generate_element_id`'s contract) via a
/// collision-avoidance loop against the existing ids, then passed in to
/// `create_reference`. Under the action corpus's deterministic id source the
/// loop yields the golden-pinned `"01234567"` / `"89abcdef"`.
pub(crate) fn make_instance_on_model(model: &mut crate::document::model::Model) {
    use crate::document::artboard::generate_element_id;
    use crate::document::document::SelectionKind;
    // Enabled only when exactly ONE whole element is selected (kind = All; not
    // a control-point sub-selection). Otherwise no-op, like group's guard.
    let target_path = {
        let sel = &model.document().selection;
        let [es] = sel.as_slice() else { return; };
        if es.kind != SelectionKind::All { return; }
        es.path.clone()
    };
    // Gather every existing element id so the freshly minted target_id /
    // ref_id can avoid collisions.
    let mut existing: std::collections::HashSet<String> = std::collections::HashSet::new();
    fn gather_ids(elem: &GeoElement, out: &mut std::collections::HashSet<String>) {
        if let Some(id) = elem.common().id.as_deref() {
            out.insert(id.to_string());
        }
        if let Some(children) = elem.children() {
            for c in children { gather_ids(c, out); }
        }
    }
    for layer in &model.document().layers {
        gather_ids(layer, &mut existing);
    }
    // Mint two distinct, collision-free ids (mirrors the artboard mint loop in
    // effects.rs).
    let mut mint = |existing: &std::collections::HashSet<String>| -> Option<String> {
        for _ in 0..100 {
            let c = generate_element_id(None);
            if !existing.contains(&c) { return Some(c); }
        }
        None
    };
    let Some(target_id) = mint(&existing) else { return; };
    existing.insert(target_id.clone());
    let Some(ref_id) = mint(&existing) else { return; };
    // create_reference + offset-move under ONE snapshot = a single undo step
    // (offset rides on the new reference's common.transform via move_selection).
    model.with_txn(|m| {
        Controller::create_reference(m, &target_path, &target_id, &ref_id);
        Controller::move_selection(m, PASTE_OFFSET, PASTE_OFFSET);
    });
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

#[cfg(test)]
mod tests {
    use super::*;

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
        st.tabs[st.active_tab].model.set_document_unbracketed(doc);

        let ctx = build_menu_ctx(&st);
        let eval = |e: &str| crate::interpreter::expr::eval(e, &ctx).to_bool();

        // enabled_when wiring with 2 selected: group (>= 2) enabled,
        // make_instance (== 1) disabled, copy (has_selection) enabled,
        // tab-gated items (tab_count > 0) enabled.
        assert!(eval("active_document.selection_count >= 2"), "group enabled @ 2 selected");
        assert!(!eval("active_document.selection_count == 1"), "make_instance disabled @ 2 selected");
        assert!(eval("active_document.has_selection"), "copy enabled with a selection");
        assert!(eval("state.tab_count > 0"), "tab-gated items enabled with an open tab");

        // checked_when wiring: panels.<id> must equal live is_panel_visible.
        crate::workspace::layout_apply::layout_apply(
            &mut st.workspace_layout,
            &crate::workspace::layout_apply::op_show_panel(PanelKind::Layers),
        );
        let ctx2 = build_menu_ctx(&st);
        let eval2 = |e: &str| crate::interpreter::expr::eval(e, &ctx2).to_bool();
        assert_eq!(
            eval2("panels.layers"),
            st.workspace_layout.is_panel_visible(PanelKind::Layers),
            "panels.layers checked_when must equal is_panel_visible",
        );
        assert!(eval2("panels.layers"), "Layers checked after op_show_panel");
        // concepts has no PanelKind -> resolves to not-visible.
        assert!(!eval2("panels.concepts"), "concepts checked is false (no PanelKind)");
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
