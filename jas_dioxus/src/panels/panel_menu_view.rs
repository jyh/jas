//! Panel menu overlay component.
//!
//! Renders the panel menu dropdown as a fixed-position overlay above
//! all other content, with an invisible backdrop for click-outside dismissal.

use dioxus::prelude::*;

use crate::workspace::app_state::{Act, AppHandle, AppState};
use crate::workspace::theme::*;
use super::panel_menu::PanelMenuItem;
use super::panel_menu_state::PanelMenuState;

/// Overlay that renders the active panel's menu dropdown.
///
/// Placed at the app root so it is not clipped by floating dock overflow.
/// Backdrop at z-index 1100, menu at z-index 1101.
#[component]
pub fn PanelMenuOverlay() -> Element {
    let mut panel_menu = use_context::<PanelMenuState>();
    let act = use_context::<Act>();
    let app = use_context::<AppHandle>();
    let dialog_ctx = use_context::<crate::interpreter::dialog_view::DialogCtx>();
    // Tracks which Action command currently has its submenu showing
    // (set by mouseenter on the parent item, cleared by mouseleave
    // on parent + submenu).
    let mut submenu_open_for = use_signal::<Option<&'static str>>(|| None);

    let Some(open) = (panel_menu.open)() else {
        return rsx! {};
    };

    let items = super::panel_menu(open.kind);
    let st = app.borrow();
    // Position menu to the left of click point so it doesn't go off-screen.
    let menu_width = 180.0_f64;
    let x = (open.x - menu_width).max(0.0);
    let y = open.y;
    let kind = open.kind;
    let addr = open.addr;

    let item_nodes: Vec<Result<VNode, RenderError>> = items.into_iter().map(|item| {
        match item {
            PanelMenuItem::Action { label, command, shortcut } if command == "open_swatch_library" => {
                // Submenu host: hovering shows a flyout listing every
                // available library. Each flyout item single-clicks to
                // open (no-op if already open). Already-open libraries
                // carry a ✓.
                let act = act.clone();
                let cmd = command;
                let display_label = format!("{label} \u{25B6}"); // ▶
                // Collect available library entries (id, name)
                let libs: Vec<(String, String)> = st.swatch_libraries
                    .as_object()
                    .map(|m| m.iter()
                        .map(|(k, v)| {
                            let name = v.get("name")
                                .and_then(|n| n.as_str())
                                .unwrap_or(k.as_str())
                                .to_string();
                            (k.clone(), name)
                        })
                        .collect())
                    .unwrap_or_default();
                // Already-open ids from panel.open_libraries
                let open_ids: std::collections::HashSet<String> = st.swatches_panel.open_libraries
                    .as_array()
                    .map(|a| a.iter()
                        .filter_map(|e| e.get("id").and_then(|i| i.as_str()).map(String::from))
                        .collect())
                    .unwrap_or_default();
                let is_open = submenu_open_for() == Some(cmd);
                let submenu_nodes: Vec<Result<VNode, RenderError>> = libs.into_iter().map(|(lib_id, lib_name)| {
                    let act = act.clone();
                    let checked = open_ids.contains(&lib_id);
                    let prefix = if checked { "\u{2713} " } else { "    " };
                    let display = format!("{prefix}{lib_name}");
                    let cmd_str = format!("open_swatch_library:{lib_id}");
                    rsx! {
                        div {
                            class: "jas-menu-item",
                            style: "padding:4px 16px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; white-space:nowrap; border-radius:3px; margin:0 4px;",
                            onmousedown: move |evt: Event<MouseData>| { evt.stop_propagation(); },
                            onclick: move |evt: Event<MouseData>| {
                                evt.stop_propagation();
                                let cmd_clone = cmd_str.clone();
                                (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                                    super::panel_dispatch(kind, &cmd_clone, addr, st);
                                }));
                                submenu_open_for.set(None);
                                panel_menu.open.set(None);
                            },
                            "{display}"
                        }
                    }
                }).collect();
                rsx! {
                    div {
                        style: "position:relative;",
                        onmouseenter: move |_| { submenu_open_for.set(Some(cmd)); },
                        onmouseleave: move |_| { submenu_open_for.set(None); },
                        div {
                            class: "jas-menu-item",
                            style: "padding:4px 24px 4px 16px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; display:flex; justify-content:space-between; white-space:nowrap; border-radius:3px; margin:0 4px;",
                            onmousedown: move |evt: Event<MouseData>| { evt.stop_propagation(); },
                            span { "{display_label}" }
                        }
                        if is_open {
                            div {
                                style: "position:absolute; left:100%; top:0; background:{THEME_BG}; border:1px solid {THEME_BORDER}; box-shadow:2px 2px 8px rgba(0,0,0,0.4); min-width:180px; z-index:1102; padding:4px 0; border-radius:4px;",
                                onmouseenter: move |_| { submenu_open_for.set(Some(cmd)); },
                                onmouseleave: move |_| { submenu_open_for.set(None); },
                                onmousedown: move |evt: Event<MouseData>| { evt.stop_propagation(); },
                                for node in submenu_nodes { {node} }
                            }
                        }
                    }
                }
            }
            PanelMenuItem::Action { label, command, shortcut } => {
                let act = act.clone();
                let app_for_dialog = app.clone();
                let dialog_ctx = dialog_ctx.clone();
                let cmd = command;
                let display_label = super::panel_dynamic_label(kind, cmd, &st)
                    .unwrap_or_else(|| label.to_string());
                let enabled = super::panel_is_enabled(kind, cmd, &st);
                let (color, cursor, opacity) = if enabled {
                    (THEME_TEXT, "pointer", "1")
                } else {
                    (THEME_TEXT_HINT, "default", "0.5")
                };
                rsx! {
                    div {
                        class: "jas-menu-item",
                        style: "padding:4px 24px 4px 16px; cursor:{cursor}; font-size:13px; color:{color}; opacity:{opacity}; display:flex; justify-content:space-between; white-space:nowrap; border-radius:3px; margin:0 4px;",
                        // Stop the mousedown so the backdrop doesn't
                        // dismiss the menu before our onclick fires.
                        onmousedown: move |evt: Event<MouseData>| { evt.stop_propagation(); },
                        // Run the action on click (mouse-up inside the
                        // item) rather than mousedown, so the
                        // mouseup/click event is consumed by the menu
                        // item — otherwise dismissing the menu on
                        // mousedown exposes whatever is underneath
                        // (e.g. a recent-color swatch) and the click
                        // bubbles to that target instead.
                        onclick: move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                            if !enabled {
                                return;
                            }
                            // Some menu actions open dialogs and need
                            // a Signal<Option<DialogState>> handle
                            // (out of reach from the AppState-only
                            // panel_dispatch). Intercept those here
                            // and call open_dialog directly.
                            let dialog_id = match cmd {
                                "open_paragraph_justification" => Some("paragraph_justification"),
                                "open_paragraph_hyphenation" => Some("paragraph_hyphenation"),
                                "save_swatch_library" => Some("swatch_library_save"),
                                _ => None,
                            };
                            if let Some(did) = dialog_id {
                                let mut sig = dialog_ctx.0;
                                let st_borrow = app_for_dialog.borrow();
                                let live = crate::workspace::dock_panel::
                                    build_live_state_map(&st_borrow);
                                drop(st_borrow);
                                let empty: serde_json::Map<String, serde_json::Value> =
                                    serde_json::Map::new();
                                crate::interpreter::dialog_view::open_dialog(
                                    &mut sig, did, &empty, &live);
                            } else {
                                (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                                    super::panel_dispatch(kind, cmd, addr, st);
                                }));
                            }
                            panel_menu.open.set(None);
                        },
                        span { "{display_label}" }
                        if !shortcut.is_empty() {
                            span {
                                style: "color:{THEME_TEXT_HINT}; margin-left:24px; font-size:12px;",
                                "{shortcut}"
                            }
                        }
                    }
                }
            }
            PanelMenuItem::Toggle { label, command } => {
                let act = act.clone();
                let cmd = command;
                // TODO: query checked state from AppState when toggle items are used
                let prefix = "    ";
                let display = format!("{prefix}{label}");
                rsx! {
                    div {
                        class: "jas-menu-item",
                        style: "padding:4px 24px 4px 8px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; white-space:nowrap; border-radius:3px; margin:0 4px;",
                        onmousedown: move |evt: Event<MouseData>| { evt.stop_propagation(); },
                        onclick: move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                            (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                                super::panel_dispatch(kind, cmd, addr, st);
                            }));
                            panel_menu.open.set(None);
                        },
                        "{display}"
                    }
                }
            }
            PanelMenuItem::Radio { label, command, .. } => {
                let act = act.clone();
                let cmd = command;
                let checked = super::panel_is_checked(kind, cmd, &st);
                let prefix = if checked { "\u{2713} " } else { "    " };
                let display = format!("{prefix}{label}");
                rsx! {
                    div {
                        class: "jas-menu-item",
                        style: "padding:4px 24px 4px 8px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; white-space:nowrap; border-radius:3px; margin:0 4px;",
                        onmousedown: move |evt: Event<MouseData>| { evt.stop_propagation(); },
                        onclick: move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                            (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                                super::panel_dispatch(kind, cmd, addr, st);
                            }));
                            panel_menu.open.set(None);
                        },
                        "{display}"
                    }
                }
            }
            PanelMenuItem::Separator => {
                rsx! {
                    div {
                        style: "height:1px; background:{THEME_BORDER}; margin:4px 8px;",
                    }
                }
            }
        }
    }).collect();

    drop(st);

    rsx! {
        // Invisible backdrop — click to dismiss
        div {
            style: "position:fixed; left:0; top:0; width:100vw; height:100vh; z-index:1100;",
            onmousedown: move |_| {
                panel_menu.open.set(None);
            },
        }
        // Menu dropdown
        div {
            style: "position:fixed; left:{x}px; top:{y}px; background:{THEME_BG}; border:1px solid {THEME_BORDER}; box-shadow:2px 2px 8px rgba(0,0,0,0.4); min-width:180px; z-index:1101; padding:4px 0; border-radius:4px;",
            onmousedown: move |evt: Event<MouseData>| {
                evt.stop_propagation();
            },
            for node in item_nodes {
                {node}
            }
        }
    }
}
