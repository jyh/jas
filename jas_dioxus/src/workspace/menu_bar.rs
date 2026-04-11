//! Menu bar component.

use std::rc::Rc;

use dioxus::prelude::*;

use super::app::{
    Act, AppHandle, AppState, TabState,
    clipboard_read_and_paste, clipboard_write, download_file, find_panel,
    open_file_dialog, selection_to_svg,
};
use super::save_dialog::SaveAsDialog;
use super::theme::*;
use crate::document::controller::Controller;
use crate::geometry::element::Element as GeoElement;
use crate::geometry::svg::document_to_svg;
use crate::tools::tool::PASTE_OFFSET;

#[component]
pub(crate) fn MenuBarView(
    open_menu: Signal<Option<String>>,
    workspace_submenu_open: Signal<bool>,
    save_as_dialog: Signal<Option<SaveAsDialog>>,
) -> Element {
    let act = use_context::<Act>();
    let app = use_context::<AppHandle>();
    let revision = use_context::<Signal<u64>>();

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
                        tab.model.snapshot();
                        let new_doc = tab.model.document().delete_selection();
                        tab.model.set_document(new_doc);
                    }));
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
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            let new_doc = tab.model.document().delete_selection();
                            tab.model.set_document(new_doc);
                        }
                    }));
                }
                "group" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::group_selection(&mut tab.model);
                        }
                    }));
                }
                "ungroup" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::ungroup_selection(&mut tab.model);
                        }
                    }));
                }
                "ungroup_all" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::ungroup_all(&mut tab.model);
                        }
                    }));
                }
                "lock" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::lock_selection(&mut tab.model);
                        }
                    }));
                }
                "unlock_all" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::unlock_all(&mut tab.model);
                        }
                    }));
                }
                "hide" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::hide_selection(&mut tab.model);
                        }
                    }));
                }
                "show_all" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::show_all(&mut tab.model);
                        }
                    }));
                }
                "tile_panes" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        let dock_collapsed = st.workspace_layout.anchored_dock(super::workspace::DockEdge::Right)
                            .is_some_and(|d| d.collapsed);
                        if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                            pl.canvas_maximized = false;
                            let override_id = if dock_collapsed {
                                pl.pane_by_kind(super::workspace::PaneKind::Dock).map(|p| (p.id, 36.0))
                            } else {
                                None
                            };
                            pl.tile_panes(override_id);
                        }
                    }));
                }
                // Window menu: pane visibility
                "toggle_pane_toolbar" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                            if pl.is_pane_visible(super::workspace::PaneKind::Toolbar) {
                                pl.hide_pane(super::workspace::PaneKind::Toolbar);
                            } else {
                                pl.show_pane(super::workspace::PaneKind::Toolbar);
                            }
                        }
                    }));
                }
                "toggle_pane_dock" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                            if pl.is_pane_visible(super::workspace::PaneKind::Dock) {
                                pl.hide_pane(super::workspace::PaneKind::Dock);
                            } else {
                                pl.show_pane(super::workspace::PaneKind::Dock);
                            }
                        }
                    }));
                }
                // Window menu: panel visibility
                "toggle_panel_layers" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Layers) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Layers) {
                                st.workspace_layout.close_panel(addr);
                            }
                        } else {
                            st.workspace_layout.show_panel(super::workspace::PanelKind::Layers);
                        }
                    }));
                }
                "toggle_panel_color" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Color) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Color) {
                                st.workspace_layout.close_panel(addr);
                            }
                        } else {
                            st.workspace_layout.show_panel(super::workspace::PanelKind::Color);
                        }
                    }));
                }
                "toggle_panel_stroke" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Stroke) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Stroke) {
                                st.workspace_layout.close_panel(addr);
                            }
                        } else {
                            st.workspace_layout.show_panel(super::workspace::PanelKind::Stroke);
                        }
                    }));
                }
                "toggle_panel_properties" => {
                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Properties) {
                            if let Some(addr) = find_panel(&st.workspace_layout, super::workspace::PanelKind::Properties) {
                                st.workspace_layout.close_panel(addr);
                            }
                        } else {
                            st.workspace_layout.show_panel(super::workspace::PanelKind::Properties);
                        }
                    }));
                }
                "workspace_submenu" => {
                    // Handled by dynamic submenu rendering, not dispatch
                }
                _ => {}
            }
        })
    };

    let menus = super::menu::MENU_BAR;

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
            items.iter().flat_map(|&(label, cmd, shortcut)| {
                if label == "---" {
                    vec![rsx! {
                        div {
                            style: "height:1px; background:{THEME_BORDER}; margin:4px 8px;",
                        }
                    }]
                } else if cmd == "workspace_submenu" {
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
                                            let prefill = if has_saved_layout { active_name.clone() } else { String::new() };
                                            rsx! {
                                                div {
                                                    class: "jas-menu-item",
                                                    style: "padding:4px 16px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; white-space:nowrap; border-radius:3px; margin:0 4px;",
                                                    onmousedown: move |evt: Event<MouseData>| {
                                                        evt.stop_propagation();
                                                        save_as_dialog.set(Some(SaveAsDialog::Editing(prefill.clone())));
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
                } else {
                    let dispatch = dispatch.clone();
                    let cmd = cmd.to_string();
                    let mut open_menu_sig2 = open_menu_sig;
                    // Add checkmark prefix for toggle items
                    let display_label = {
                        let st = app.borrow();
                        let checked = match cmd.as_str() {
                            "toggle_pane_toolbar" => st.workspace_layout.pane_layout.as_ref().is_some_and(|pl| pl.is_pane_visible(super::workspace::PaneKind::Toolbar)),
                            "toggle_pane_dock" => st.workspace_layout.pane_layout.as_ref().is_some_and(|pl| pl.is_pane_visible(super::workspace::PaneKind::Dock)),
                            "toggle_panel_layers" => st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Layers),
                            "toggle_panel_color" => st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Color),
                            "toggle_panel_stroke" => st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Stroke),
                            "toggle_panel_properties" => st.workspace_layout.is_panel_visible(super::workspace::PanelKind::Properties),
                            _ => false,
                        };
                        if cmd.starts_with("toggle_") {
                            if checked { format!("\u{2713} {}", label) } else { format!("    {}", label) }
                        } else {
                            format!("    {}", label)
                        }
                    };
                    vec![rsx! {
                        div {
                            class: "jas-menu-item",
                            style: "padding:4px 24px 4px 8px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; display:flex; justify-content:space-between; white-space:nowrap; border-radius:3px; margin:0 4px;",
                            onmousedown: move |evt: Event<MouseData>| {
                                evt.stop_propagation();
                                dispatch(&cmd);
                                open_menu_sig2.set(None);
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
            for node in menu_nodes {
                {node}
            }
        }
    }
}
