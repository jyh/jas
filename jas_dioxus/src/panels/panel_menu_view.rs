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
    // Row 298: the open submenu's key and its item's rect (left, right, top),
    // read when the item is hovered; the submenu is drawn beside that rect as
    // a sibling of the flyout. It stays open until another item is hovered,
    // the flyout scrolls, or the menu closes, as a native menu's does.
    let mut submenu_open_for =
        use_signal::<Option<(&'static str, Option<(f64, f64, f64)>)>>(|| None);

    let Some(open) = (panel_menu.open)() else {
        return rsx! {};
    };

    let items = super::panel_menu(open.kind);
    let st = app.borrow();
    // Rows 291/294/296: the menu sits to the LEFT of the press and DOWN from
    // it, shifted just enough to stay in the window whatever its size
    // (`flyout_position_css`).
    #[cfg(target_arch = "wasm32")]
    let (viewport_w, viewport_h): (f64, f64) = web_sys::window()
        .map(|w| (
            w.inner_width().ok().and_then(|v| v.as_f64()).unwrap_or(1280.0),
            w.inner_height().ok().and_then(|v| v.as_f64()).unwrap_or(900.0),
        ))
        .unwrap_or((1280.0, 900.0));
    #[cfg(not(target_arch = "wasm32"))]
    let (viewport_w, viewport_h): (f64, f64) = (1280.0, 900.0);
    let menu_position = flyout_position_css(open.x, open.y, viewport_w, viewport_h);
    // The menu's right edge is the press (pinned into the window); a
    // submenu whose item rect could not be read is placed from it.
    let press_x = open.x.clamp(0.0, viewport_w.max(0.0));
    let press_y = open.y;
    let kind = open.kind;
    let addr = open.addr;
    // One expression context per menu render, shared by every row's
    // `enabled_when` / `checked_when` — the same context `panel_is_enabled` /
    // `panel_is_checked` build per call.
    let content_id = crate::interpreter::workspace::panel_kind_to_content_id(kind);
    let items_dom_id = crate::workspace::test_hook::panel_menu_items_dom_id(content_id);
    let menu_ctx = super::panel_menu::panel_menu_ctx(content_id, &st);
    // Row 298: the open submenu's rows and its item's rect, collected by the
    // item loop and drawn AFTER the flyout as its sibling
    // (`submenu_position_css`).
    let mut open_submenu: Option<(Vec<Element>, Option<(f64, f64, f64)>)> = None;

    // One `items_from` row: a check where its `checked_when` holds; a click
    // runs the row's own action with its own params
    // (`panel_menu::dispatch_menu_row`) and closes the menu. Used by a
    // submenu's flyout and by a menu opened as that submenu alone
    // (`PanelMenuOpen::only`, an `open_menu` request).
    let render_row = {
        let act = act.clone();
        move |row: serde_json::Value| -> Element {
            let act = act.clone();
            let enabled = row.get("enabled").and_then(|v| v.as_bool()).unwrap_or(true);
            let checked = row.get("checked").and_then(|v| v.as_bool()).unwrap_or(false);
            let prefix = if checked { "\u{2713} " } else { "    " };
            let text = row.get("label").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let display = format!("{prefix}{text}");
            let (color, cursor, opacity) = if enabled {
                (THEME_TEXT, "pointer", "1")
            } else {
                (THEME_TEXT_HINT, "default", "0.5")
            };
            rsx! {
                div {
                    class: "jas-menu-item",
                    style: "padding:4px 16px; cursor:{cursor}; font-size:13px; color:{color}; opacity:{opacity}; white-space:nowrap; border-radius:3px; margin:0 4px;",
                    onmousedown: move |evt: Event<MouseData>| { evt.stop_propagation(); },
                    onclick: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        if !enabled {
                            return;
                        }
                        let row = row.clone();
                        (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                            super::panel_menu::dispatch_menu_row(content_id, &row, st);
                        }));
                        submenu_open_for.set(None);
                        panel_menu.open.set(None);
                    },
                    "{display}"
                }
            }
        }
    };

    // An `open_menu` request shows the named submenu's rows ALONE, at the
    // click; an empty source shows one disabled "(none)" row rather than an
    // empty box.
    let only_nodes: Option<Vec<Element>> = open.only.map(|key| {
        let rows = items.iter().find_map(|i| match i {
            PanelMenuItem::Submenu { label, spec } if *label == key => Some(*spec),
            _ => None,
        }).map(|spec| super::panel_menu::submenu_rows(content_id, spec, &st))
            .and_then(|r| r.as_array().cloned()).unwrap_or_default();
        if rows.is_empty() {
            vec![rsx! { div { style: "padding:4px 16px; font-size:13px; color:{THEME_TEXT_HINT}; opacity:0.5;", "(none)" } }]
        } else {
            rows.into_iter().map(&render_row).collect()
        }
    });

    let item_nodes: Vec<Result<VNode, RenderError>> = if let Some(nodes) = only_nodes { nodes } else { items.into_iter().map(|item| {
        match item {
            PanelMenuItem::Action { label, command, shortcut } => {
                let act = act.clone();
                let app_for_dialog = app.clone();
                let dialog_ctx = dialog_ctx.clone();
                let cmd = command;
                // A label's `{{expr}}` regions are evaluated against the menu's
                // own context, as the shared walk does (`menu_state`); the
                // Layers panel's toggle-all rows say what they will do.
                let display_label = crate::interpreter::expr::eval_text(label, &menu_ctx);
                let enabled = super::panel_menu::is_enabled_from_yaml(content_id, cmd, &menu_ctx);
                let (color, cursor, opacity) = if enabled {
                    (THEME_TEXT, "pointer", "1")
                } else {
                    (THEME_TEXT_HINT, "default", "0.5")
                };
                let disabled = if enabled { "false" } else { "true" };
                rsx! {
                    div {
                        class: "jas-menu-item",
                        // Row 291: an action item a level-2 driver picks by
                        // its title, as the Mac picks it by its AX title.
                        role: "menuitem",
                        "aria-disabled": "{disabled}",
                        style: "padding:4px 24px 4px 16px; cursor:{cursor}; font-size:13px; color:{color}; opacity:{opacity}; display:flex; justify-content:space-between; white-space:nowrap; border-radius:3px; margin:0 4px;",
                        // Row 298: hovering another item closes an open
                        // submenu, as in a native menu.
                        onmouseenter: move |_| { submenu_open_for.set(None); },
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
                            // The action may defer a dialog (its YAML's
                            // `open_dialog`): `act` runs synchronously,
                            // so take what it handed back and open it
                            // once the AppState borrow is released.
                            let deferred = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
                            let sink = deferred.clone();
                            (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                                *sink.borrow_mut() = super::panel_dispatch(kind, cmd, addr, st);
                            }));
                            let effects = deferred.take();
                            if !effects.is_empty() {
                                let mut sig = dialog_ctx.0;
                                crate::interpreter::renderer::apply_deferred_dialog_effects(
                                    &effects, &app_for_dialog, &mut sig);
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
                let label = crate::interpreter::expr::eval_text(label, &menu_ctx);
                let act = act.clone();
                let cmd = command;
                let checked = super::panel_menu::is_checked_from_yaml(content_id, cmd, &menu_ctx);
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
            PanelMenuItem::Radio { label, command, .. } => {
                let label = crate::interpreter::expr::eval_text(label, &menu_ctx);
                let act = act.clone();
                let cmd = command;
                let checked = super::panel_menu::is_checked_from_yaml(content_id, cmd, &menu_ctx);
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
            PanelMenuItem::Submenu { label, spec } => {
                // An `items_from` submenu (brushes.yaml's Open Brush
                // Library): hovering shows a flyout whose rows are evaluated
                // NOW, in the menu's context; a row shows a check where its
                // `checked_when` holds and runs its own action with its own
                // params (`panel_menu::dispatch_menu_row`).
                let key = label;
                let display_label = format!("{label} \u{25B6}"); // ▶
                let rows = super::panel_menu::submenu_rows(content_id, spec, &st);
                let open_rect = submenu_open_for().filter(|(k, _)| *k == key).map(|(_, r)| r);
                let row_nodes: Vec<Element> = rows.as_array().cloned().unwrap_or_default()
                    .into_iter().map(&render_row).collect();
                if let Some(rect) = open_rect {
                    if !row_nodes.is_empty() {
                        open_submenu = Some((row_nodes, rect));
                    }
                }
                // The item's DOM id, so a hover can read its rect.
                let item_dom_id = format!("{items_dom_id}_sub_{}",
                    key.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect::<String>());
                let item_dom_id_c = item_dom_id.clone();
                rsx! {
                    div {
                        id: "{item_dom_id}",
                        class: "jas-menu-item",
                        style: "padding:4px 24px 4px 16px; cursor:pointer; font-size:13px; color:{THEME_TEXT}; display:flex; justify-content:space-between; white-space:nowrap; border-radius:3px; margin:0 4px;",
                        onmouseenter: move |_| {
                            #[cfg(target_arch = "wasm32")]
                            let rect = web_sys::window()
                                .and_then(|w| w.document())
                                .and_then(|d| d.get_element_by_id(&item_dom_id_c))
                                .map(|el| { let r = el.get_bounding_client_rect(); (r.left(), r.right(), r.top()) });
                            // No DOM off the web, where no hover arrives.
                            #[cfg(not(target_arch = "wasm32"))]
                            let rect: Option<(f64, f64, f64)> = { let _ = &item_dom_id_c; None };
                            submenu_open_for.set(Some((key, rect)));
                        },
                        onmousedown: move |evt: Event<MouseData>| { evt.stop_propagation(); },
                        span { "{display_label}" }
                    }
                }
            }
            PanelMenuItem::Separator => {
                rsx! {
                    div {
                        style: "height:1px; background-color:{THEME_BORDER}; margin:4px 8px;",
                    }
                }
            }
        }
    }).collect() };

    drop(st);

    let submenu: Option<(Vec<Element>, String)> = open_submenu.map(|(nodes, rect)| {
        let (l, r, t) = rect.unwrap_or((press_x, press_x, press_y));
        (nodes, submenu_position_css(l, r, t, viewport_w, viewport_h))
    });

    rsx! {
        // Invisible backdrop — click to dismiss
        div {
            style: "position:fixed; left:0; top:0; width:100vw; height:100vh; z-index:1100;",
            onmousedown: move |_| {
                submenu_open_for.set(None);
                panel_menu.open.set(None);
            },
        }
        // Menu dropdown. Row 298: a menu taller than the window scrolls
        // (`max-height`, border-box so its border and padding count), and a
        // scroll closes an open submenu, whose item has moved.
        div {
            id: "{items_dom_id}",
            role: "menu",
            style: "position:fixed; {menu_position} box-sizing:border-box; max-height:100vh; overflow-y:auto; background-color:{THEME_BG}; border-width:1px; border-style:solid; border-top-color:{THEME_BORDER}; border-right-color:{THEME_BORDER}; border-bottom-color:{THEME_BORDER}; border-left-color:{THEME_BORDER}; box-shadow:2px 2px 8px rgba(0,0,0,0.4); min-width:180px; z-index:1101; padding:4px 0; border-radius:4px;",
            onmousedown: move |evt: Event<MouseData>| {
                evt.stop_propagation();
            },
            onscroll: move |_| { submenu_open_for.set(None); },
            for node in item_nodes {
                {node}
            }
        }
        // Row 298: the open `items_from` submenu, a SIBLING of the flyout so
        // the flyout's scroll and transform cannot clip it.
        if let Some((sub_nodes, sub_style)) = submenu {
            div {
                role: "menu",
                style: "position:fixed; {sub_style} box-sizing:border-box; max-height:100vh; overflow-y:auto; background-color:{THEME_BG}; border-width:1px; border-style:solid; border-top-color:{THEME_BORDER}; border-right-color:{THEME_BORDER}; border-bottom-color:{THEME_BORDER}; border-left-color:{THEME_BORDER}; box-shadow:2px 2px 8px rgba(0,0,0,0.4); min-width:180px; z-index:1102; padding:4px 0; border-radius:4px;",
                onmousedown: move |evt: Event<MouseData>| { evt.stop_propagation(); },
                for node in sub_nodes { {node} }
            }
        }
    }
}

/// Row 291 / row 294: the flyout's vertical placement, as CSS, for a press at
/// `y` in a window `viewport_h` tall. The top sits at the press point and a
/// `translateY` shifts the menu UP by just enough to keep its bottom in the
/// window (`100%` is the menu's own height), never past the window's top:
/// `clamp(-y, (viewport_h - y) - height, 0)`. So a menu opens DOWN when it fits
/// below, and any menu shorter than the window stays wholly on screen,
/// whatever its height. Live (row 291), a group near the bottom opened its
/// menu below the window; a half-window flip (#1155) still let the tallest
/// menu (Brushes, ~570 px) overflow near the middle (row 294). The submenus are
/// absolutely placed inside their item, so the transform leaves them as they
/// were. `bottom` is stated too (dioxus restores a dropped property, rows
/// 121-122).
///
/// Row 296: the horizontal half. The left sits at the press and the same
/// `translate` shifts the menu LEFT by its own width (`-100%`), never past
/// the window's left edge (`max(-x, -100%)`), so its RIGHT edge is the
/// press whatever its width. Before, `left = x - 180` assumed a 180 px
/// menu; the Brushes menu is 211 px, and it ran 18 px off the window's right
/// edge from its hamburger in the right dock. Both shifts live in ONE
/// `transform`: a second property would replace the first.
pub(crate) fn flyout_position_css(x: f64, y: f64, viewport_w: f64, viewport_h: f64) -> String {
    // A press point outside the window is pinned to its edge first.
    let x = x.clamp(0.0, viewport_w.max(0.0));
    let y = y.clamp(0.0, viewport_h.max(0.0));
    let room = (viewport_h - y).max(0.0);
    format!("left:{x}px; right:auto; top:{y}px; bottom:auto; \
             transform:translate(max(-{x}px, -100%), clamp(-{y}px, calc({room}px - 100%), 0px));")
}

/// Row 298: an `items_from` submenu's placement, from its item's rect. The
/// submenu is drawn as a SIBLING of the flyout, never inside it: the flyout
/// scrolls (`overflow-y: auto`) when it is taller than the window, and it
/// carries a `transform`, so even a `position:fixed` descendant would be
/// placed against it and clipped by it. Beside the item on its right when a
/// submenu `SUBMENU_ROOM` wide fits there, else on its left (its right edge
/// at the item's left, never past the window's left edge); its top at the
/// item's top, shifted up just enough to stay in the window, as the flyout's.
pub(crate) fn submenu_position_css(item_left: f64, item_right: f64, item_top: f64,
                                   viewport_w: f64, viewport_h: f64) -> String {
    let vw = viewport_w.max(0.0);
    let y = item_top.clamp(0.0, viewport_h.max(0.0));
    let room = (viewport_h - y).max(0.0);
    let vertical = format!("clamp(-{y}px, calc({room}px - 100%), 0px)");
    if item_right + SUBMENU_ROOM <= vw {
        let x = item_right.clamp(0.0, vw);
        format!("left:{x}px; right:auto; top:{y}px; bottom:auto; transform:translate(0px, {vertical});")
    } else {
        let x = item_left.clamp(0.0, vw);
        format!("left:{x}px; right:auto; top:{y}px; bottom:auto; transform:translate(max(-{x}px, -100%), {vertical});")
    }
}

/// The width a submenu is assumed to need on the item's right before it is
/// placed on the left instead (the flip the nested flyout made, row 296).
pub(crate) const SUBMENU_ROOM: f64 = 200.0;

/// The left edge `flyout_position_css` yields for a menu `width` wide: the
/// CSS `max` term's own arithmetic, for the tests.
#[cfg(test)]
pub(crate) fn flyout_left_for(x: f64, width: f64, viewport_w: f64) -> f64 {
    let x = x.clamp(0.0, viewport_w.max(0.0));
    x + (-width).max(-x)
}

/// The top edge `flyout_position_css` yields for a menu `height` tall: the
/// CSS clamp's own arithmetic, for the tests.
#[cfg(test)]
pub(crate) fn flyout_top_for(y: f64, height: f64, viewport_h: f64) -> f64 {
    let y = y.clamp(0.0, viewport_h.max(0.0));
    let room = (viewport_h - y).max(0.0);
    y + (room - height).min(0.0).max(-y)
}

#[cfg(test)]
mod tests {
    use super::{flyout_left_for, flyout_position_css, flyout_top_for, submenu_position_css};

    /// Row 298: a submenu sits beside its item, on the right when 200 px fit
    /// there and on the left otherwise (the Brushes menu's own hamburger is
    /// in the right dock, so its submenu goes LEFT), with the flyout's
    /// vertical clamp. Each branch is pinned by its CSS.
    #[test]
    fn a_submenu_sits_beside_its_item_inside_the_window() {
        // Room on the right (a menu opened mid-window).
        assert_eq!(submenu_position_css(500.0, 711.0, 120.0, 1400.0, 900.0),
                   "left:711px; right:auto; top:120px; bottom:auto; \
                    transform:translate(0px, clamp(-120px, calc(780px - 100%), 0px));");
        // No room: the right dock (item 1177..1388 in a 1400 px window).
        assert_eq!(submenu_position_css(1177.0, 1388.0, 300.0, 1400.0, 900.0),
                   "left:1177px; right:auto; top:300px; bottom:auto; \
                    transform:translate(max(-1177px, -100%), clamp(-300px, calc(600px - 100%), 0px));");
        // The boundary: exactly 200 px of room stays on the right.
        assert!(submenu_position_css(0.0, 1200.0, 0.0, 1400.0, 900.0).starts_with("left:1200px;"));
        assert!(submenu_position_css(0.0, 1200.5, 0.0, 1400.0, 900.0).starts_with("left:0px;"));
        // An item scrolled above the window's top: the submenu's top is pinned at 0.
        assert!(submenu_position_css(500.0, 711.0, -40.0, 1400.0, 900.0).contains("top:0px;"));
    }

    /// Row 294: the menu opens DOWN from the press when it fits below, is
    /// shifted UP just enough when it does not, and never above the window's
    /// top; any menu shorter than the window stays wholly on screen.
    #[test]
    fn a_flyout_stays_on_screen_whatever_its_height() {
        assert_eq!(flyout_top_for(100.0, 250.0, 900.0), 100.0, "fits below: opens down from the press");
        assert_eq!(flyout_top_for(880.0, 250.0, 900.0), 650.0, "a low press: shifted up, bottom at the window's");
        assert_eq!(flyout_top_for(440.0, 573.0, 900.0), 327.0, "the tallest menu (Brushes) mid-window: both edges in");
        assert_eq!(flyout_top_for(100.0, 573.0, 900.0), 100.0, "the tallest menu from a high press: opens down");
        assert_eq!(flyout_top_for(440.0, 1000.0, 900.0), 0.0, "taller than the window: pinned to its top");
        assert_eq!(flyout_top_for(1010.0, 250.0, 900.0), 650.0, "a press below the window still lands on screen");
    }

    /// Row 296, measured live at main be311876 (Playwright, CI's pinned
    /// 1.49.1, main's Pages bundle): the Brushes ≡ menu is 211 px wide, the
    /// placement assumed 180 (`left = press - 180`), so from its hamburger
    /// (centre x 1388 in a 1400 px window) it ran 18 px past the window's
    /// right edge at every window size. Now its RIGHT edge sits at the press
    /// whatever its width, and its left edge never leaves the window.
    #[test]
    fn a_flyout_never_leaves_the_window_sideways() {
        assert_eq!(flyout_left_for(1388.0, 211.0, 1400.0), 1177.0, "the Brushes menu from its hamburger: right edge at the press");
        assert_eq!(flyout_left_for(1388.0, 180.0, 1400.0), 1208.0, "a 180 px menu lands where it always did");
        assert_eq!(flyout_left_for(100.0, 211.0, 1400.0), 0.0, "a press near the left: pinned to the window's left edge");
        assert_eq!(flyout_left_for(1500.0, 211.0, 1400.0), 1189.0, "a press right of the window is pinned to its edge first");
        assert_eq!(flyout_left_for(-20.0, 211.0, 1400.0), 0.0, "a press left of the window: at its left edge");
        // Margins: every right edge is <= the window's width.
        for (x, w) in [(1388.0, 211.0), (1399.0, 300.0), (700.0, 211.0)] {
            assert!(flyout_left_for(x, w, 1400.0) + w <= 1400.0, "press {x}, width {w}: right edge inside");
        }
    }

    /// The CSS carries exactly the terms `flyout_left_for` and
    /// `flyout_top_for` model, in ONE transform (a second `transform`
    /// property would replace the first).
    #[test]
    fn the_flyout_css_is_the_modelled_clamp() {
        assert_eq!(flyout_position_css(1388.0, 880.0, 1400.0, 900.0),
                   "left:1388px; right:auto; top:880px; bottom:auto; \
                    transform:translate(max(-1388px, -100%), clamp(-880px, calc(20px - 100%), 0px));");
        assert_eq!(flyout_position_css(1500.0, -5.0, 1400.0, 900.0),
                   "left:1400px; right:auto; top:0px; bottom:auto; \
                    transform:translate(max(-1400px, -100%), clamp(-0px, calc(900px - 100%), 0px));",
                   "a press outside the window is pinned to its edges first");
    }
}
