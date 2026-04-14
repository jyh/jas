//! Toolbar grid component with tool buttons and long-press popup.

use std::collections::HashMap;

use dioxus::prelude::*;
use wasm_bindgen::prelude::*;

use super::app_state::{Act, AppState};
use super::icons::toolbar_svg_icon;
use super::theme::*;
use crate::tools::tool::ToolKind;

/// Toolbar layout: 2-column grid matching the Python/Qt version.
/// Each entry is (row, col, primary_tool, alternates).
/// Slots with alternates show the current alternate and support long-press to switch.
pub(crate) const TOOLBAR_SLOTS: &[(usize, usize, &[ToolKind])] = &[
    (0, 0, &[ToolKind::Selection]),
    (0, 1, &[ToolKind::PartialSelection, ToolKind::InteriorSelection]),
    (1, 0, &[ToolKind::Pen, ToolKind::AddAnchorPoint, ToolKind::DeleteAnchorPoint, ToolKind::AnchorPoint]),
    (1, 1, &[ToolKind::Pencil, ToolKind::PathEraser, ToolKind::Smooth]),
    (2, 0, &[ToolKind::Type, ToolKind::TypeOnPath]),
    (2, 1, &[ToolKind::Line]),
    (3, 0, &[ToolKind::Rect, ToolKind::RoundedRect, ToolKind::Polygon, ToolKind::Star]),
    (3, 1, &[ToolKind::Lasso]),
];

/// Long-press threshold in milliseconds (matches theme.sizes.long_press_ms).
const LONG_PRESS_MS: i32 = 250;

/// Icon color for toolbar alternate indicator triangles.
const IC: &str = "rgb(204,204,204)";

#[component]
pub(crate) fn ToolbarGrid(
    active_tool: ToolKind,
    slot_alternates: Signal<HashMap<usize, usize>>,
    popup_slot: Signal<Option<usize>>,
) -> Element {
    let act = use_context::<Act>();

    // If active tool is an alternate that's not currently visible, update the slot.
    // Collect updates first, then apply — writing to signals during render can cause
    // borrow conflicts in the Dioxus runtime.
    let slot_updates: Vec<(usize, usize)> = TOOLBAR_SLOTS.iter().enumerate()
        .filter_map(|(si, (_r, _c, tools))| {
            if tools.len() > 1
                && let Some(pos) = tools.iter().position(|&t| t == active_tool) {
                    let current = *slot_alternates.peek().get(&si).unwrap_or(&0);
                    if current != pos {
                        return Some((si, pos));
                    }
                }
            None
        })
        .collect();
    if !slot_updates.is_empty() {
        let mut alts = slot_alternates.write();
        for (si, pos) in slot_updates {
            alts.insert(si, pos);
        }
    }

    let tool_buttons: Vec<Result<VNode, RenderError>> = TOOLBAR_SLOTS
        .iter()
        .enumerate()
        .map(|(si, &(row, col, tools))| {
            let act = act.clone();
            let alt_idx = *slot_alternates.peek().get(&si).unwrap_or(&0);
            let kind = tools[alt_idx.min(tools.len() - 1)];
            let has_alternates = tools.len() > 1;
            let is_active = tools.contains(&active_tool);
            let bg = if is_active { THEME_BG_TOOLBAR_BTN } else { "transparent" };

            // Build SVG with optional alternate triangle indicator
            let svg_inner = toolbar_svg_icon(kind);
            let triangle = if has_alternates {
                format!(r#"<path d="M28,28 L23,28 L28,23 Z" fill="{IC}"/>"#)
            } else {
                String::new()
            };
            let svg_html = format!(
                r#"<svg viewBox="0 0 28 28" width="28" height="28" xmlns="http://www.w3.org/2000/svg">{svg_inner}{triangle}</svg>"#
            );
            let grid_col = col + 1;
            let grid_row = row + 1;

            rsx! {
                div {
                    key: "slot-{si}",
                    style: "grid-column:{grid_col}; grid-row:{grid_row}; width:32px; height:32px; background:{bg}; cursor:pointer; display:flex; align-items:center; justify-content:center; border-radius:2px; position:relative;",
                    title: "{kind.label()}",
                    onmousedown: {
                        let act = act.clone();
                        move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                            if has_alternates {
                                // Start long-press timer via setTimeout
                                let slot_idx = si;
                                let mut popup = popup_slot;
                                let Some(window) = web_sys::window() else { return; };
                                let cb = Closure::once(move || {
                                    popup.set(Some(slot_idx));
                                });
                                window.set_timeout_with_callback_and_timeout_and_arguments_0(
                                    cb.as_ref().unchecked_ref(), LONG_PRESS_MS
                                ).ok();
                                cb.forget();
                            }
                            // Normal click: select this tool
                            (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                                st.set_tool(kind);
                            }));
                        }
                    },
                    onmouseup: move |_| {
                        // If popup hasn't shown yet, cancel by ignoring
                        // (timer will fire but popup will be dismissed on next click)
                    },
                    dangerous_inner_html: "{svg_html}",
                }
            }
        })
        .collect();

    // Build popup for long-press alternate selection
    let popup_node: Option<Result<VNode, RenderError>> = popup_slot().map(|si| {
        let (_row, _col, tools) = TOOLBAR_SLOTS[si];
        let items: Vec<Result<VNode, RenderError>> = tools.iter().enumerate().map(|(ti, &tool_kind)| {
            let act = act.clone();
            let label = tool_kind.label();
            let is_current = tool_kind == active_tool;
            let bg = if is_current { "#606060" } else { THEME_BG_TAB };
            rsx! {
                div {
                    class: "jas-tool-popup-item",
                    style: "padding:4px 10px; cursor:pointer; font-size:12px; color:{THEME_TEXT}; white-space:nowrap; background:{bg}; border-radius:2px;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        slot_alternates.write().insert(si, ti);
                        popup_slot.set(None);
                        (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                            st.set_tool(tool_kind);
                        }));
                    },
                    "{label}"
                }
            }
        }).collect();
        // Position the popup next to the toolbar
        let top = _row as u32 * 34 + 4;
        let left = 72;
        rsx! {
            div {
                style: "position:fixed; top:{top}px; left:{left}px; background:{THEME_BG_TAB}; border:1px solid #666; box-shadow:2px 2px 8px rgba(0,0,0,0.3); z-index:2000; padding:4px; border-radius:4px;",
                for item in items {
                    {item}
                }
            }
        }
    });

    rsx! {
        // Tool buttons
        div {
            style: "padding:4px 2px; display:grid; grid-template-columns:repeat(auto-fill, 32px); grid-auto-rows:32px; gap:2px; justify-content:center; align-content:start;",
            for btn in tool_buttons {
                {btn}
            }
        }

        // Tool alternate popup (shown on long-press, position:fixed)
        if let Some(popup) = popup_node {
            {popup}
        }
    }
}
