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
            PanelMenuItem::Action { label, command, shortcut } => {
                let act = act.clone();
                let cmd = command;
                rsx! {
                    div {
                        class: "jas-menu-item",
                        style: "padding:4px 24px 4px 16px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; display:flex; justify-content:space-between; white-space:nowrap; border-radius:3px; margin:0 4px;",
                        onmousedown: move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                            (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                                super::panel_dispatch(kind, cmd, addr, st);
                            }));
                            panel_menu.open.set(None);
                        },
                        span { "{label}" }
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
                        onmousedown: move |evt: Event<MouseData>| {
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
                        onmousedown: move |evt: Event<MouseData>| {
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
