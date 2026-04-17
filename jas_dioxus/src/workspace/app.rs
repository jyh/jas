//! Main Dioxus application component.
//!
//! Hosts the toolbar, tab bar, canvas, and wires keyboard shortcuts.
//! State types live in `app_state`, clipboard/file I/O in `clipboard`,
//! and keyboard handlers in `keyboard`.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use dioxus::prelude::*;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;

use crate::document::controller::{
    FillSummary, StrokeSummary,
    selection_fill_summary, selection_stroke_summary,
};
use crate::geometry::element::{Color, Stroke};
use super::app_state::{Act, AppState};
use super::keyboard::{make_keydown_handler, make_keyup_handler};
use super::theme::*;
// ColorPickerDialogView removed — color picker now uses YAML dialog system
use super::fill_stroke_widget::FillStrokeWidgetView;
use super::menu_bar::MenuBarView;
// SaveAsDialogView removed — workspace save-as now uses YAML dialog system
use super::dock_panel::{DragState, DockGroupsView, FloatingDocksView};
use super::toolbar_grid::{ToolbarGrid, TOOLBAR_SLOTS};
use crate::panels::panel_menu_state::{PanelMenuState, MenuBarState};
use crate::panels::panel_menu_view::PanelMenuOverlay;

/// Toolbar content rendered from YAML. Takes revision as prop so it only
/// re-renders on state changes, not during layout drag/resize.
#[component]
fn YamlToolbarContent(revision: u64) -> Element {
    use std::sync::OnceLock;
    static TOOLBAR_CONTENT: OnceLock<Option<serde_json::Value>> = OnceLock::new();
    let content = TOOLBAR_CONTENT.get_or_init(|| {
        let ws = crate::interpreter::workspace::Workspace::load()?;
        let layout = ws.data().get("layout")?;
        let toolbar_pane = layout.get("children")?.as_array()?.iter()
            .find(|c| c.get("id").and_then(|i| i.as_str()) == Some("toolbar_pane"))?;
        toolbar_pane.get("content").cloned()
    });
    if let Some(el) = content {
        let app = use_context::<super::app_state::AppHandle>();
        let st = app.borrow();
        let live_state = crate::workspace::dock_panel::build_live_state_map(&st);
        drop(st);
        let icons = crate::interpreter::workspace::Workspace::load()
            .map(|w| w.icons().clone()).unwrap_or(serde_json::Value::Null);
        let eval_ctx = serde_json::json!({
            "state": serde_json::Value::Object(live_state),
            "icons": icons,
        });
        crate::interpreter::renderer::render_element(el, &eval_ctx)
    } else {
        rsx! { div { "Toolbar not found" } }
    }
}

#[component]
pub fn App() -> Element {
    let app = use_hook(|| Rc::new(RefCell::new(AppState::new())));
    let mut revision = use_signal(|| 0u64);
    let mut layout_revision = use_signal(|| 0u64);

    // Repaint after each render
    {
        let app = app.clone();
        use_effect(move || {
            let _rev = revision();
            if let Ok(st) = app.try_borrow() {
                st.repaint();
            }
        });
    }

    // Blink timer: while a tool is in a text-editing session, bump the
    // revision every ~265ms so the caret blinks. The interval is installed
    // for the lifetime of the component; it cheaply checks each tick whether
    // editing is still active and only triggers a repaint then.
    {
        let app_b = app.clone();
        let mut rev_b = revision;
        use_hook(move || {
            #[cfg(target_arch = "wasm32")]
            {
                use wasm_bindgen::closure::Closure;
                let app_b = app_b.clone();
                let cb = Closure::<dyn FnMut()>::new(move || {
                    let editing = if let Ok(st) = app_b.try_borrow() {
                        let kind = st.active_tool;
                        st.tab()
                            .and_then(|tab| tab.tools.get(&kind).map(|t| t.is_editing()))
                            .unwrap_or(false)
                    } else {
                        false
                    };
                    if editing {
                        rev_b += 1;
                    }
                });
                if let Some(window) = web_sys::window() {
                    let _ = window
                        .set_interval_with_callback_and_timeout_and_arguments_0(
                            cb.as_ref().unchecked_ref(),
                            265,
                        );
                }
                // Leak the closure so it stays alive for the app lifetime.
                cb.forget();
            }
            #[cfg(not(target_arch = "wasm32"))]
            { let _ = (&app_b, &mut rev_b); }
        });
    }

    // Window resize listener: clamp floating docks to viewport.
    {
        let app_r = app.clone();
        let mut rev_r = revision;
        use_hook(move || {
            #[cfg(target_arch = "wasm32")]
            {
                use wasm_bindgen::closure::Closure;
                let cb = Closure::<dyn FnMut()>::new(move || {
                    if let Some(win) = web_sys::window() {
                        let vw = win.inner_width().ok().and_then(|v| v.as_f64()).unwrap_or(1000.0);
                        let vh = win.inner_height().ok().and_then(|v| v.as_f64()).unwrap_or(700.0);
                        if let Ok(mut st) = app_r.try_borrow_mut() {
                            if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                pl.on_viewport_resize(vw, vh);
                            }
                            st.workspace_layout.clamp_floating_docks(vw, vh);
                            st.workspace_layout.bump();
                            st.save_workspace_layout();
                            st.workspace_layout.mark_saved();
                        }
                        rev_r += 1;
                    }
                });
                if let Some(window) = web_sys::window() {
                    let _ = window.add_event_listener_with_callback(
                        "resize",
                        cb.as_ref().unchecked_ref(),
                    );
                }
                cb.forget();
            }
            #[cfg(not(target_arch = "wasm32"))]
            { let _ = (&app_r, &mut rev_r); }
        });
    }

    // Session persistence: save all open documents before the page unloads.
    {
        let app_bu = app.clone();
        use_hook(move || {
            #[cfg(target_arch = "wasm32")]
            {
                use wasm_bindgen::closure::Closure;
                let app_bu = app_bu.clone();
                let cb = Closure::<dyn FnMut()>::new(move || {
                    if let Ok(st) = app_bu.try_borrow() {
                        super::session::save_session(&st.tabs, st.active_tab);
                    }
                });
                if let Some(window) = web_sys::window() {
                    let _ = window.add_event_listener_with_callback(
                        "beforeunload",
                        cb.as_ref().unchecked_ref(),
                    );
                }
                cb.forget();
            }
            #[cfg(not(target_arch = "wasm32"))]
            { let _ = &app_bu; }
        });
    }

    // Periodic auto-save: save session every 30 seconds.
    {
        let app_as = app.clone();
        use_hook(move || {
            #[cfg(target_arch = "wasm32")]
            {
                use wasm_bindgen::closure::Closure;
                let app_as = app_as.clone();
                let cb = Closure::<dyn FnMut()>::new(move || {
                    if let Ok(st) = app_as.try_borrow() {
                        super::session::save_session(&st.tabs, st.active_tab);
                    }
                });
                if let Some(window) = web_sys::window() {
                    let _ = window.set_interval_with_callback_and_timeout_and_arguments_0(
                        cb.as_ref().unchecked_ref(),
                        30_000,
                    );
                }
                cb.forget();
            }
            #[cfg(not(target_arch = "wasm32"))]
            { let _ = &app_as; }
        });
    }

    // Macro-like helper: mutate state, then bump revision to trigger repaint.
    // Use `act` for state changes (color, tool, etc.) — panels re-render.
    // Use `layout_act` for pane drag/resize — only geometry re-renders.
    let act = {
        let app = app.clone();
        move |f: Box<dyn FnOnce(&mut AppState)>| {
            {
                let mut st = app.borrow_mut();
                f(&mut st);
                st.workspace_layout.bump();
                st.save_workspace_layout();
                st.workspace_layout.mark_saved();
            }
            revision += 1;
        }
    };
    let act = Rc::new(RefCell::new(act));

    let layout_act = {
        let app = app.clone();
        move |f: Box<dyn FnOnce(&mut AppState)>| {
            {
                let mut st = app.borrow_mut();
                f(&mut st);
                st.workspace_layout.bump();
                st.save_workspace_layout();
                st.workspace_layout.mark_saved();
            }
            layout_revision += 1;  // does NOT bump revision
        }
    };
    let layout_act = Rc::new(RefCell::new(layout_act));

    // Provide shared state via context so child components can access them.
    use_context_provider(|| Act(act.clone()));
    use_context_provider(|| app.clone());
    use_context_provider(|| revision);

    // --- Mouse events ---

    let on_mousedown = {
        let act = act.clone();
        move |evt: Event<MouseData>| {
            let coords = evt.data().element_coordinates();
            let cx = coords.x;
            let cy = coords.y;
            let mods = evt.data().modifiers();
            let shift = mods.shift();
            let alt = mods.alt();
            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                let kind = st.active_tool;
                if let Some(tab) = st.tab_mut()
                    && let Some(tool) = tab.tools.get_mut(&kind) {
                        tool.on_press(&mut tab.model, cx, cy, shift, alt);
                    }
            }));
        }
    };

    let on_mousemove = {
        let act = act.clone();
        move |evt: Event<MouseData>| {
            let coords = evt.data().element_coordinates();
            let cx = coords.x;
            let cy = coords.y;
            let mods = evt.data().modifiers();
            let shift = mods.shift();
            let alt = mods.alt();
            let dragging = evt.data().held_buttons().contains(dioxus::html::input_data::MouseButton::Primary);
            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                let kind = st.active_tool;
                if let Some(tab) = st.tab_mut()
                    && let Some(tool) = tab.tools.get_mut(&kind) {
                        tool.on_move(&mut tab.model, cx, cy, shift, alt, dragging);
                    }
            }));
        }
    };

    let on_mouseup = {
        let act = act.clone();
        move |evt: Event<MouseData>| {
            let coords = evt.data().element_coordinates();
            let cx = coords.x;
            let cy = coords.y;
            let mods = evt.data().modifiers();
            let shift = mods.shift();
            let alt = mods.alt();
            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                let kind = st.active_tool;
                if let Some(tab) = st.tab_mut()
                    && let Some(tool) = tab.tools.get_mut(&kind) {
                        tool.on_release(&mut tab.model, cx, cy, shift, alt);
                    }
            }));
        }
    };

    let on_dblclick = {
        let act = act.clone();
        move |evt: Event<MouseData>| {
            let coords = evt.data().element_coordinates();
            let cx = coords.x;
            let cy = coords.y;
            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                let kind = st.active_tool;
                if let Some(tab) = st.tab_mut()
                    && let Some(tool) = tab.tools.get_mut(&kind) {
                        tool.on_double_click(&mut tab.model, cx, cy);
                    }
            }));
        }
    };

    // --- Keyboard events ---
    let on_keydown = make_keydown_handler(act.clone(), app.clone(), revision);
    let on_keyup = make_keyup_handler(act.clone());

    // --- Tool buttons with shared slots ---
    // Track which alternate is visible in each shared slot.
    // Key: index into TOOLBAR_SLOTS for slots with alternates.
    let slot_alternates = use_signal(|| {
        let mut map = HashMap::<usize, usize>::new();
        for (i, (_r, _c, tools)) in TOOLBAR_SLOTS.iter().enumerate() {
            if tools.len() > 1 {
                map.insert(i, 0); // default to first alternate
            }
        }
        map
    });
    // Signal for which slot is showing a long-press popup (-1 = none)
    let mut popup_slot = use_signal(|| Option::<usize>::None);

    // Dock drag-and-drop state.
    let drag_source = use_signal(|| Option::<super::workspace::DragPayload>::None);
    let mut drop_target_sig = use_signal(|| Option::<super::workspace::DropTarget>::None);
    let was_dropped = use_signal(|| false);
    let mut last_drag_pos = use_signal(|| (0.0f64, 0.0f64));
    // Floating dock title bar drag (dock_id, offset_x, offset_y).
    let mut title_drag = use_signal(|| Option::<(super::workspace::DockId, f64, f64)>::None);
    // Provide drag state via context for dock_panel components.
    use_context_provider(|| DragState {
        drag_source,
        drop_target: drop_target_sig,
        was_dropped,
        last_drag_pos,
        title_drag,
    });
    // Pane drag-and-drop state.
    // (pane_id, offset_x, offset_y)
    let mut pane_drag = use_signal(|| Option::<(super::workspace::PaneId, f64, f64)>::None);
    // (snap_idx, start_coord)
    let mut border_drag = use_signal(|| Option::<(usize, f64)>::None);
    // Pane edge resize: (pane_id, edge, start_mouse_x, start_mouse_y, start_pane_width, start_pane_height, start_pane_x, start_pane_y)
    let mut pane_resize = use_signal(|| Option::<(super::workspace::PaneId, super::workspace::EdgeSide, f64, f64, f64, f64, f64, f64)>::None);
    // Snap preview lines shown during drag
    let mut snap_preview = use_signal(Vec::<super::workspace::SnapConstraint>::new);

    // Read both signals to trigger re-render on state OR layout changes.
    let _ = revision();
    let _ = layout_revision();

    // Ensure pane layout exists and repair snaps once on init.
    {
        let mut st = app.borrow_mut();
        if st.workspace_layout.pane_layout.is_none() {
            #[cfg(target_arch = "wasm32")]
            {
                if let Some(win) = web_sys::window() {
                    let vw = win.inner_width().ok().and_then(|v| v.as_f64()).unwrap_or(1000.0);
                    let vh = win.inner_height().ok().and_then(|v| v.as_f64()).unwrap_or(700.0);
                    st.workspace_layout.ensure_pane_layout(vw, vh);
                    if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                        pl.repair_snaps(vw, vh);
                    }
                }
            }
            #[cfg(not(target_arch = "wasm32"))]
            {
                st.workspace_layout.ensure_pane_layout(1000.0, 700.0);
                if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                    pl.repair_snaps(1000.0, 700.0);
                }
            }
        }
    }

    let active_tool = app.borrow().active_tool;
    let fill_on_top = app.borrow().fill_on_top;

    // Compute fill/stroke display state for toolbar widget.
    let (fs_fill_summary, fs_stroke_summary, fs_default_fill, fs_default_stroke) = {
        let st = app.borrow();
        let (fill_sum, stroke_sum, df, ds) = if let Some(tab) = st.tab() {
            let doc = tab.model.document();
            (
                selection_fill_summary(doc),
                selection_stroke_summary(doc),
                tab.model.default_fill,
                tab.model.default_stroke,
            )
        } else {
            (FillSummary::NoSelection, StrokeSummary::NoSelection, None, Some(Stroke::new(Color::BLACK, 1.0)))
        };
        (fill_sum, stroke_sum, df, ds)
    };

    // Per-frame cursor: tools may override (e.g. Type tool returns the
    // text-insertion SVG when hovering text, and "none" while editing).
    let canvas_cursor: String = {
        let st = app.borrow();
        st.tab()
            .and_then(|tab| tab.tools.get(&active_tool).and_then(|t| t.cursor_css_override()))
            .unwrap_or_else(|| active_tool.cursor_css().to_string())
    };
    // --- Tab bar ---
    let borrowed = app.borrow();
    let tab_info: Vec<(usize, String, bool)> = borrowed.tabs.iter().enumerate().map(|(i, tab)| {
        (i, tab.model.filename.clone(), i == borrowed.active_tab)
    }).collect();
    let has_tabs = !borrowed.tabs.is_empty();
    drop(borrowed);

    let tab_buttons: Vec<Result<VNode, RenderError>> = tab_info.iter().map(|(i, name, is_active)| {
        let idx = *i;
        let act = act.clone();
        let bg = if *is_active { THEME_BG_TAB } else { THEME_BG_TAB_INACTIVE };
        let border_bottom = if *is_active { "2px solid #4a4a4a" } else { "2px solid #555" };
        let display_name = name.clone();
        rsx! {
            div {
                key: "tab-{idx}",
                style: "display:inline-flex; align-items:center; padding:4px 8px; margin-right:1px; background:{bg}; border:1px solid {THEME_BORDER}; border-bottom:{border_bottom}; cursor:pointer; font-size:12px; color:{THEME_TEXT}; user-select:none;",
                onclick: move |_| {
                    let act = act.clone();
                    (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                        st.active_tab = idx;
                    }));
                },
                span { "{display_name}" }
                {
                    let act2 = act.clone();
                    rsx! {
                        span {
                            style: "margin-left:6px; color:{THEME_TEXT_BUTTON}; cursor:pointer; font-size:14px; line-height:1;",
                            onclick: move |evt: Event<MouseData>| {
                                evt.stop_propagation();
                                (act2.borrow_mut())(Box::new(move |st: &mut AppState| {
                                    st.close_tab(idx);
                                }));
                            },
                            "\u{00d7}"
                        }
                    }
                }
            }
        }
    }).collect();

    // --- Menu bar signals ---
    let mut open_menu = use_signal(|| Option::<String>::None);
    let workspace_submenu_open = use_signal(|| false);
    let appearance_submenu_open = use_signal(|| false);
    // color_picker_state removed — color picker now uses YAML dialog system
    let yaml_dialog = use_signal(|| Option::<crate::interpreter::dialog_view::DialogState>::None);
    use_context_provider(|| crate::interpreter::dialog_view::DialogCtx(yaml_dialog));
    use_context_provider(|| crate::interpreter::timer::TimerCtx(
        std::rc::Rc::new(std::cell::RefCell::new(std::collections::HashMap::new()))
    ));

    // --- Panel menu context ---
    let mut panel_menu_sig = use_signal(|| None);
    use_context_provider(|| PanelMenuState { open: panel_menu_sig });
    use_context_provider(|| MenuBarState { open_menu });

    // --- Build dock nodes ---
    use super::workspace::{DockEdge, DockId, DropTarget};
    #[cfg(target_arch = "wasm32")]
    use super::workspace::WorkspaceLayout;

    let layout_snapshot = app.borrow().workspace_layout.clone();
    let right_dock = layout_snapshot.anchored_dock(DockEdge::Right);
    let dock_collapsed = right_dock.is_none_or(|d| d.collapsed);
    let dock_id = right_dock.map_or(DockId(0), |d| d.id);

    // Dock collapse toggle
    let _dock_toggle_label = if dock_collapsed { "\u{25C0}" } else { "\u{25B6}" };

    // Snap indicator: show a highlight on the edge being targeted during drag
    let snap_edge = match drop_target_sig() {
        Some(DropTarget::Edge(edge)) => Some(edge),
        _ => None,
    };
    let snap_left = if snap_edge == Some(DockEdge::Left) { "4px solid #4a90d9" } else { "none" };
    let snap_right = if snap_edge == Some(DockEdge::Right) { "4px solid #4a90d9" } else { "none" };
    let snap_bottom = if snap_edge == Some(DockEdge::Bottom) { "4px solid #4a90d9" } else { "none" };

    // --- Pane positions ---
    use super::workspace::{PaneKind, PaneId, EdgeSide, SnapTarget, PaneLayout};

    let pane_snapshot = layout_snapshot.pane_layout.clone();
    let canvas_maximized = pane_snapshot.as_ref().is_some_and(|pl| pl.canvas_maximized);

    let (tx, ty, tw, th, toolbar_z) = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Toolbar).map(|p| {
            let z = pl.pane_z_index(p.id);
            // When canvas is maximized, toolbar floats on top
            let z = if canvas_maximized { z + 50 } else { z };
            (p.x, p.y, p.width, p.height, z)
        }))
        .unwrap_or((0.0, 0.0, 72.0, 700.0, 0));
    let toolbar_pane_id = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Toolbar))
        .map(|p| p.id)
        .unwrap_or(PaneId(0));
    let toolbar_config = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Toolbar))
        .map(|p| p.config.clone())
        .unwrap_or_else(|| super::workspace::PaneConfig::for_kind(PaneKind::Toolbar));

    let (cx, cy, cw, ch, canvas_z) = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Canvas).map(|p| {
            if canvas_maximized {
                (0.0, 0.0, pl.viewport_width, pl.viewport_height, 0)
            } else {
                (p.x, p.y, p.width, p.height, pl.pane_z_index(p.id))
            }
        }))
        .unwrap_or((72.0, 0.0, 688.0, 700.0, 0));
    let canvas_pane_id = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Canvas))
        .map(|p| p.id)
        .unwrap_or(PaneId(1));
    let canvas_config = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Canvas))
        .map(|p| p.config.clone())
        .unwrap_or_else(|| super::workspace::PaneConfig::for_kind(PaneKind::Canvas));
    let canvas_border = if canvas_maximized { "none" } else { "1px solid #555" };

    let collapsed_dock_width = 36.0;
    let (dx, dy, dw, dh, dock_z) = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Dock).map(|p| {
            let z = pl.pane_z_index(p.id);
            let z = if canvas_maximized { z + 50 } else { z };
            if dock_collapsed {
                // Anchor collapsed dock at its right edge
                let right = p.x + p.width;
                (right - collapsed_dock_width, p.y, collapsed_dock_width, p.height, z)
            } else {
                (p.x, p.y, p.width, p.height, z)
            }
        }))
        .unwrap_or((760.0, 0.0, 240.0, 700.0, 0));
    let dock_pane_id = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Dock))
        .map(|p| p.id)
        .unwrap_or(PaneId(2));
    let dock_config = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Dock))
        .map(|p| p.config.clone())
        .unwrap_or_else(|| super::workspace::PaneConfig::for_kind(PaneKind::Dock));

    // Collect shared border positions for rendering drag handles
    // Each entry: (snap_idx, x, y, w, h, cursor_css)
    let shared_borders: Vec<(usize, f64, f64, f64, f64, String)> = pane_snapshot.as_ref().map(|pl| {
        let mut borders = Vec::new();
        for (i, snap) in pl.snaps.iter().enumerate() {
            let (other_id, other_edge) = match snap.target {
                SnapTarget::Pane(pid, oe) => (pid, oe),
                _ => continue,
            };
            let is_vertical = snap.edge == EdgeSide::Right && other_edge == EdgeSide::Left;
            let is_horizontal = snap.edge == EdgeSide::Bottom && other_edge == EdgeSide::Top;
            if !is_vertical && !is_horizontal { continue; }
            let pane_a = match pl.pane(snap.pane) { Some(p) => p, None => continue };
            let pane_b = match pl.pane(other_id) { Some(p) => p, None => continue };
            // Skip borders where both panes are fixed-width (not draggable)
            if pane_a.config.fixed_width && pane_b.config.fixed_width { continue; }
            // Skip stale snaps where edges have separated
            if is_vertical && (pane_a.x + pane_a.width - pane_b.x).abs() > 1.0 { continue; }
            if is_horizontal && (pane_a.y + pane_a.height - pane_b.y).abs() > 1.0 { continue; }
            if is_vertical {
                let bx = pane_a.x + pane_a.width;
                let by = pane_a.y.max(pane_b.y);
                let bh = (pane_a.y + pane_a.height).min(pane_b.y + pane_b.height) - by;
                if bh > 0.0 { borders.push((i, bx - 3.0, by, 6.0, bh, "col-resize".to_string())); }
            } else {
                let by = pane_a.y + pane_a.height;
                let bx = pane_a.x.max(pane_b.x);
                let bw = (pane_a.x + pane_a.width).min(pane_b.x + pane_b.width) - bx;
                if bw > 0.0 { borders.push((i, bx, by - 3.0, bw, 6.0, "row-resize".to_string())); }
            }
        }
        borders
    }).unwrap_or_default();

    // Snap preview lines: (x, y, width, height)
    let snap_lines: Vec<(f64, f64, f64, f64)> = snap_preview().iter().filter_map(|snap| {
        let pl = pane_snapshot.as_ref()?;
        let pane = pl.pane(snap.pane)?;
        let coord = PaneLayout::pane_edge_coord(pane, snap.edge);
        match snap.edge {
            EdgeSide::Left | EdgeSide::Right => Some((coord - 2.0, pane.y, 4.0, pane.height)),
            EdgeSide::Top | EdgeSide::Bottom => Some((pane.x, coord - 2.0, pane.width, 4.0)),
        }
    }).collect();

    rsx! {
        document::Link {
            rel: "icon",
            r#type: "image/png",
            sizes: "32x32",
            href: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAACXBIWXMAAAsTAAALEwEAmpwYAAACi0lEQVR4nOXWXYhVVRQH8F85fqZQpiA65IOSBPkyDyIpipI4BKYvRpSgQZBmQYoQFCn6ICqCAwq+iCIU2FggKEhEkBYjgvQiGAgZDhIiqFNZieVc2bAObA5n7twZ594R+sPm7HP2Onv919rrY/M/wcTRVL4I93GiWQrmYXqd9VOo4T88N5KKx+M73EQfNlbIzMS/QSCN1Y+rdBbmxHx9EGjDi7iHCSX545nyNLoeR/ku3MZv+BKb4ylc+w8mZ/Kvoj8U/xHPi40qW4df0Yt38AL+wvNh5WWswTV8g6sl617CnVD6M7bE/E88NZjy9vh5ITpivjyez4TMD1iFKXgDS7EgjqgjvFQL0h2xXhxDMqYuFuOn7L0HK9Ad38/jUim3P4zN+8LKNH+A12J9Rkams5HovoaD4dbesHwMVuJ1PFv650Ap2Poy5cLt92PtXQ1gFnZjT4XL9sRGeyPQzuBhprwnsqKMX2L9Ew1kami2PQuctiy4yiPVg/fDU1X4caipuCPb/HjkfHG++UiWfZQF6EA4G/Kf1xN6M1x6JTuzqpFiZD9ewdMNGvRV/FvUjkp0VSjrD0JH8R7mGx6+iP1ODoXAQ3yPnZH3KZ2Gi+7Y8+t6Qttwq47ra1H1kjc2YPYQCBRdMREZFNOwJFx+CBei1lcRSvX9g1IfqMK3IX/EMDE2ynPK43NR6XIidyNzJg3w/+WQ22eEMAVvRzMqul4a17GsQr442o81AfOzICtuP1tL5b2olm9pIjpxIyNSWPty9i0dY1MxM7ploTC167XZe73744hhalxEatE7jsU8eadlmIu/S5lyWovxaYnAZ60mMBm/ZwTSbavlOJzdD8eNBoH26AObRkO5Jx6PAEOB3bAxAGnpAAAAAElFTkSuQmCC"
        }
        document::Link {
            rel: "stylesheet",
            href: "https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css",
        }
        style { r#"
            html, body {{ margin: 0; padding: 0; overflow: hidden; width: 100%; height: 100%; }}
            #main {{ height: 100%; }}
            .jas-menu-title:hover {{ background: {THEME_BG_ACTIVE}; }}
            .jas-menu-item:hover {{ background: {THEME_BG_ACTIVE}; }}
            .jas-tool-popup-item:hover {{ background: #606060 !important; }}
            .jas-dock-group {{ transition: max-height 0.15s ease, opacity 0.15s ease; }}
            .jas-dock {{ transition: width 0.15s ease; }}
            .jas-floating-dock {{ transition: opacity 0.15s ease; }}
            .jas-tab:hover {{ background: #505050 !important; }}
            .jas-border-handle {{ background: transparent; }}
            .jas-border-handle:hover {{ background: rgba(74,144,217,0.3); }}
            .jas-border-handle:active {{ background: rgba(74,144,217,0.5); }}
        "#  }
        div {
            tabindex: "0",
            onkeydown: on_keydown,
            onkeyup: on_keyup,
            onmousedown: move |_| {
                popup_slot.set(None);
            },
            onmousemove: {
                let layout_act = layout_act.clone();
                let app = app.clone();
                move |evt: Event<MouseData>| {
                    let coords = evt.data().page_coordinates();
                    // Floating dock title bar drag
                    if let Some((fid, off_x, off_y)) = title_drag() {
                        (layout_act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            st.workspace_layout.set_floating_position(fid, coords.x - off_x, coords.y - off_y);
                        }));
                        return;
                    }
                    // Pane drag (move with live snapping)
                    if let Some((pid, off_x, off_y)) = pane_drag() {
                        let new_x = coords.x - off_x;
                        let new_y = coords.y - off_y;
                        (layout_act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                // Move to raw mouse position first
                                pl.set_pane_position(pid, new_x, new_y);
                                // Detect snaps at raw position
                                let vw = pl.viewport_width;
                                let vh = pl.viewport_height;
                                let preview = pl.detect_snaps(pid, vw, vh);
                                // If snaps found, align pane to snap targets immediately
                                if !preview.is_empty() {
                                    pl.align_to_snaps(pid, &preview, vw, vh);
                                }
                                snap_preview.set(preview);
                            }
                        }));
                        return;
                    }
                    // Shared border drag
                    if let Some((snap_idx, start_coord)) = border_drag() {
                        // Read snap direction from live state (not stale snapshot)
                        let is_vert = {
                            let st = app.borrow();
                            st.workspace_layout.pane_layout.as_ref()
                                .and_then(|pl| pl.snaps.get(snap_idx))
                                .map(|s| s.edge == EdgeSide::Right)
                                .unwrap_or(true)
                        };
                        let delta = if is_vert { coords.x - start_coord } else { coords.y - start_coord };
                        let new_start = if is_vert { coords.x } else { coords.y };
                        border_drag.set(Some((snap_idx, new_start)));
                        (layout_act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                pl.drag_shared_border(snap_idx, delta);
                            }
                        }));
                        return;
                    }
                    // Pane edge resize
                    if let Some((pid, edge, start_mx, start_my, start_w, start_h, start_px, start_py)) = pane_resize() {
                        (layout_act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                let dx = coords.x - start_mx;
                                let dy = coords.y - start_my;
                                match edge {
                                    EdgeSide::Right => {
                                        pl.resize_pane(pid, start_w + dx, start_h);
                                    }
                                    EdgeSide::Left => {
                                        let new_w = (start_w - dx).max(
                                            pl.pane(pid).map(|p| p.config.min_width).unwrap_or(200.0)
                                        );
                                        let actual_dx = start_w - new_w;
                                        if let Some(p) = pl.pane_mut(pid) {
                                            p.x = start_px + actual_dx;
                                            p.width = new_w;
                                        }
                                    }
                                    EdgeSide::Bottom => {
                                        pl.resize_pane(pid, start_w, start_h + dy);
                                    }
                                    EdgeSide::Top => {
                                        let new_h = (start_h - dy).max(
                                            pl.pane(pid).map(|p| p.config.min_height).unwrap_or(200.0)
                                        );
                                        let actual_dy = start_h - new_h;
                                        if let Some(p) = pl.pane_mut(pid) {
                                            p.y = start_py + actual_dy;
                                            p.height = new_h;
                                        }
                                    }
                                }
                            }
                        }));
                    }
                }
            },
            onmouseup: {
                let act = act.clone();
                move |_| {
                    // Finalize pane drag: apply snaps
                    if let Some((pid, _, _)) = pane_drag() {
                        let preview = snap_preview();
                        if !preview.is_empty() {
                            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                    let vw = pl.viewport_width;
                                    let vh = pl.viewport_height;
                                    pl.apply_snaps(pid, preview, vw, vh);
                                }
                            }));
                        }
                        snap_preview.set(vec![]);
                    }
                    pane_drag.set(None);
                    border_drag.set(None);
                    pane_resize.set(None);
                    title_drag.set(None);
                }
            },
            ondragover: move |evt: Event<DragData>| {
                // Track drag position and detect edge snapping
                let coords = evt.data().page_coordinates();
                last_drag_pos.set((coords.x, coords.y));
                // Check if near a screen edge for snap-to-dock
                #[cfg(target_arch = "wasm32")]
                {
                    if let Some(win) = web_sys::window() {
                        let vw = win.inner_width().ok().and_then(|v| v.as_f64()).unwrap_or(1000.0);
                        let vh = win.inner_height().ok().and_then(|v| v.as_f64()).unwrap_or(700.0);
                        if let Some(edge) = WorkspaceLayout::is_near_edge(coords.x, coords.y, vw, vh) {
                            drop_target_sig.set(Some(DropTarget::Edge(edge)));
                        }
                    }
                }
            },
            style: "position:relative; width:100%; height:100%; overflow:hidden; outline:none; font-family:sans-serif; background:{THEME_BG_DARK}; border-left:{snap_left}; border-right:{snap_right}; border-bottom:{snap_bottom}; box-sizing:border-box; display:flex; flex-direction:column;",

            // ===== Menu bar (full width, top of window) =====
            MenuBarView {
                workspace_submenu_open,
                appearance_submenu_open,
            }

            // ===== Pane container (fills remaining space) =====
            div {
                style: "flex:1; position:relative; overflow:hidden;",

            // ===== Toolbar pane (position:absolute) =====
            if pane_snapshot.as_ref().is_some_and(|pl| pl.is_pane_visible(PaneKind::Toolbar)) {
            div {
                style: "position:absolute; left:{tx}px; top:{ty}px; width:{tw}px; height:{th}px; z-index:{toolbar_z}; display:flex; flex-direction:column; overflow:hidden; background:{THEME_BG}; border:1px solid {THEME_BORDER}; box-sizing:border-box;",
                onmousedown: {
                    let act = act.clone();
                    move |_| {
                        open_menu.set(None);
                        panel_menu_sig.set(None);
                        (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                pl.bring_pane_to_front(toolbar_pane_id);
                            }
                        }));
                    }
                },

                // Title bar
                div {
                    style: "height:20px; min-height:20px; cursor:grab; background:{THEME_BG_DARK}; flex-shrink:0; display:flex; align-items:center; padding:0 4px; user-select:none;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        pane_drag.set(Some((toolbar_pane_id, coords.x - tx, coords.y - ty)));
                    },
                    div { style: "flex:1;" }
                    {
                        let act = act.clone();
                        rsx! {
                            div {
                                style: "cursor:pointer; font-size:12px; color:{THEME_TEXT_BUTTON}; padding:0 2px;",
                                onmousedown: move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                        if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                            pl.hide_pane(PaneKind::Toolbar);
                                        }
                                    }));
                                },
                                "\u{00D7}" // ×
                            }
                        }
                    }
                }

                // Toolbar content from YAML — memoized, only re-renders on state changes
                YamlToolbarContent { revision: revision() }

                // Toolbar width is not resizable
            }
            } // close toolbar visibility if

            // ===== Canvas pane (position:absolute) =====
            div {
                style: "position:absolute; left:{cx}px; top:{cy}px; width:{cw}px; height:{ch}px; z-index:{canvas_z}; display:flex; flex-direction:column; overflow:hidden; background:{THEME_BG}; border:{canvas_border}; box-sizing:border-box;",
                onmousedown: {
                    let act = act.clone();
                    move |_: Event<MouseData>| {
                        open_menu.set(None);
                        panel_menu_sig.set(None);
                        popup_slot.set(None);
                        if !canvas_maximized {
                            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                    pl.bring_pane_to_front(canvas_pane_id);
                                }
                            }));
                        }
                    }
                },

                // Title bar (hidden when maximized)
                if !canvas_maximized {
                    div {
                        style: "height:20px; min-height:20px; cursor:grab; background:{THEME_BG_DARK}; flex-shrink:0; display:flex; align-items:center; padding:0 4px; user-select:none;",
                        onmousedown: move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                            let coords = evt.data().page_coordinates();
                            pane_drag.set(Some((canvas_pane_id, coords.x - cx, coords.y - cy)));
                        },
                        ondoubleclick: {
                            let act = act.clone();
                            let can_maximize = canvas_config.double_click_action == super::workspace::DoubleClickAction::Maximize;
                            move |evt: Event<MouseData>| {
                                if !can_maximize { return; }
                                evt.stop_propagation();
                                pane_drag.set(None);
                                (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                    if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                        pl.toggle_canvas_maximized();
                                    }
                                }));
                            }
                        },
                        div { style: "flex:1;" }
                    }
                }

                // Restore button (visible only when maximized)
                if canvas_maximized {
                    button {
                        style: "position:absolute; top:4px; right:4px; z-index:200; background:{THEME_BG_DARK}; border:1px solid {THEME_BORDER}; color:{THEME_TEXT}; cursor:pointer; padding:2px 8px; font-size:10px; border-radius:3px;",
                        title: "Restore canvas (double-click tab bar)",
                        onclick: {
                            let act = act.clone();
                            move |_| {
                                (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                    if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                        pl.toggle_canvas_maximized();
                                    }
                                }));
                            }
                        },
                        "⬜ Restore"
                    }
                }

                // Tab bar
                div {
                    style: "display:flex; background:{THEME_BG_DARK}; border-bottom:1px solid {THEME_BORDER}; padding:2px 4px 0; min-height:28px; align-items:flex-end; flex-shrink:0;",
                    for btn in tab_buttons {
                        {btn}
                    }
                }

                // Canvas
                div {
                    style: "flex:1; position:relative; overflow:hidden;",
                    if has_tabs {
                        canvas {
                            id: "jas-canvas",
                            style: "display:block; width:100%; height:100%; cursor:{canvas_cursor};",
                            onmousedown: on_mousedown,
                            onmousemove: on_mousemove,
                            onmouseup: on_mouseup,
                            ondoubleclick: on_dblclick,
                        }
                    } else {
                        span {
                            style: "position:absolute; top:10px; right:12px; width:54px; height:24px; opacity:0.25;",
                            dangerous_inner_html: BRAND_LOGO_SVG,
                        }
                    }
                }

                // Edge resize handles (always present; shared border handles
                // at z-index:100 take priority when they exist)
                div {
                    style: "position:absolute; top:0; left:0; width:4px; height:100%; cursor:ew-resize;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        pane_resize.set(Some((canvas_pane_id, EdgeSide::Left, coords.x, coords.y, cw, ch, cx, cy)));
                    },
                }
                div {
                    style: "position:absolute; top:0; right:0; width:4px; height:100%; cursor:ew-resize;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        pane_resize.set(Some((canvas_pane_id, EdgeSide::Right, coords.x, coords.y, cw, ch, cx, cy)));
                    },
                }
            }
            // (canvas pane is always visible, no close button)

            // ===== Dock pane (position:absolute) =====
            if pane_snapshot.as_ref().is_some_and(|pl| pl.is_pane_visible(PaneKind::Dock)) {
            div {
                style: "position:absolute; left:{dx}px; top:{dy}px; width:{dw}px; height:{dh}px; z-index:{dock_z}; display:flex; flex-direction:column; overflow:hidden; background:{THEME_BG}; border:1px solid {THEME_BORDER}; box-sizing:border-box;",
                onmousedown: {
                    let act = act.clone();
                    move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                pl.bring_pane_to_front(dock_pane_id);
                            }
                        }));
                    }
                },

                // Title bar with collapse chevron and close button
                div {
                    style: "height:20px; min-height:20px; cursor:grab; background:{THEME_BG_DARK}; flex-shrink:0; display:flex; align-items:center; padding:0 4px; user-select:none; border-bottom:1px solid {THEME_BORDER};",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        pane_drag.set(Some((dock_pane_id, coords.x - dx, coords.y - dy)));
                    },
                    div { style: "flex:1;" }
                    // Collapse chevron (if collapsed_width is set)
                    if dock_config.collapsed_width.is_some() {
                        {
                            let act = act.clone();
                            let chevron = if dock_collapsed { "\u{00BB}" } else { "\u{00AB}" }; // >> or <<
                            rsx! {
                                div {
                                    style: "cursor:pointer; font-size:18px; color:{THEME_TEXT_BUTTON}; padding:0 4px; line-height:1;",
                                    title: "Collapse",
                                    onmousedown: move |evt: Event<MouseData>| {
                                        evt.stop_propagation();
                                        (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                            st.workspace_layout.toggle_dock_collapsed(dock_id);
                                        }));
                                    },
                                    "{chevron}"
                                }
                            }
                        }
                    }
                    // Close button
                    {
                        let act = act.clone();
                        rsx! {
                            div {
                                style: "cursor:pointer; font-size:12px; color:{THEME_TEXT_BUTTON}; padding:0 2px;",
                                onmousedown: move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                        if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                            pl.hide_pane(PaneKind::Dock);
                                        }
                                    }));
                                },
                                "\u{00D7}" // x
                            }
                        }
                    }
                }

                // Panel groups
                div {
                    style: "flex:1; overflow-y:auto;",
                    DockGroupsView {}
                }

                // Left edge resize handle
                div {
                    style: "position:absolute; top:0; left:0; width:4px; height:100%; cursor:ew-resize;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        pane_resize.set(Some((dock_pane_id, EdgeSide::Left, coords.x, coords.y, dw, dh, dx, dy)));
                    },
                }
            }
            } // close dock visibility if

            // ===== Shared border drag handles =====
            for (snap_idx, bx, by, bw, bh, cursor_css) in shared_borders {
                {
                    let is_vert = cursor_css == "col-resize";
                    rsx! {
                        div {
                            key: "border-{snap_idx}",
                            class: "jas-border-handle",
                            style: "position:absolute; left:{bx}px; top:{by}px; width:{bw}px; height:{bh}px; cursor:{cursor_css}; z-index:100;",
                            onmousedown: move |evt: Event<MouseData>| {
                                evt.stop_propagation();
                                let coords = evt.data().page_coordinates();
                                let start = if is_vert { coords.x } else { coords.y };
                                border_drag.set(Some((snap_idx, start)));
                            },
                        }
                    }
                }
            }

            // ===== Snap preview lines =====
            for (i, (sl_x, sl_y, sl_w, sl_h)) in snap_lines.iter().enumerate() {
                div {
                    key: "snap-line-{i}",
                    style: "position:absolute; left:{sl_x}px; top:{sl_y}px; width:{sl_w}px; height:{sl_h}px; background:rgba(50,120,220,0.8); pointer-events:none; z-index:200;",
                }
            }

            // Floating docks (position:fixed overlays)
            FloatingDocksView {}

            } // close pane container div

            // Panel menu overlay (z-index 1100-1101, above floating docks)
            PanelMenuOverlay {}

            // Color Picker dialog removed — now uses YAML dialog system

            // YAML-interpreted dialogs
            crate::interpreter::dialog_view::YamlDialogView { dialog_ctx: yaml_dialog }
        }
    }
}
