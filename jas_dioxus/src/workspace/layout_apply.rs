//! The single LAYOUT-op dispatcher — `layout_apply` (OP_LOG.md §12, Fork 5,
//! Increment 3d-2). The layout analogue of `document::op_apply`.
//!
//! PROMOTED from the `#[cfg(feature = "web")]` cross-language test harness
//! (`apply_workspace_op`) into a RUNTIME module so production layout mutations
//! and the test harness share ONE dispatcher and ONE per-verb mutation body —
//! exactly the unification 3b-B did for document ops. The harness shim
//! (`cross_language_test.rs::apply_workspace_op`) now delegates here, and the
//! production layout-mutation sites (menu_bar / dock_panel /
//! panel-menu dispatchers) build a resolved op JSON and call `layout_apply`
//! instead of calling `WorkspaceLayout::<method>` directly. The mutation is
//! byte-identical to the pre-3d-2 direct call (same args, now
//! serialized → dispatched → parsed).
//!
//! NON-GATED: `WorkspaceLayout`, `PaneLayout`, and every verb mutator compile
//! without the `web` feature (the module tree mounts them unconditionally), so
//! this module is feature-agnostic and the layout corpus runs under
//! `--no-default-features` too.
//!
//! LAYOUT STAYS NON-UNDOABLE (OP_LOG.md §12, Option B): there is NO layout
//! journal, NO layout undo, and NO `checkpoint_equivalence`-vs-journal gate
//! (that is Option C, deliberately NOT done). `layout_apply` is purely the
//! shared parse → apply envelope; the per-verb `WorkspaceLayout` mutators
//! already call `bump()` internally (the dirty signal), which the caller's
//! `act`/`layout_act` wrapper reads via `needs_save()` to persist — unchanged.
//!
//! Production input must never panic, so every param read is hardened: numbers
//! resolve with `as_f64().unwrap_or(0.0)` / `as_u64().unwrap_or(0)`; a missing
//! REQUIRED string (the verb name, a panel/pane `kind`) early-returns/skips
//! rather than unwrapping; a malformed op skips. The harness fixtures (which
//! always carry well-formed params) replay byte-identically.

use crate::workspace::workspace::{
    DockId, GroupAddr, PanelAddr, PanelKind, WorkspaceLayout,
};
use crate::workspace::pane::PaneId;
use crate::workspace::workspace::PaneKind;

/// Parse a panel-kind string to its `PanelKind`. Complete over all 13 kinds
/// (matches `test_json::parse_panel_kind`); an unknown/garbage string falls
/// back to `Layers` so a malformed op never panics. The pre-3d-2 harness shim
/// had a 5-kind subset; the runtime dispatcher needs the full set because the
/// production `show_panel` handler covers every `PanelKind`.
fn parse_panel_kind(s: &str) -> PanelKind {
    match s {
        "color" => PanelKind::Color,
        "swatches" => PanelKind::Swatches,
        "brushes" => PanelKind::Brushes,
        "stroke" => PanelKind::Stroke,
        "properties" => PanelKind::Properties,
        "character" => PanelKind::Character,
        "paragraph" => PanelKind::Paragraph,
        "artboards" => PanelKind::Artboards,
        "align" => PanelKind::Align,
        "boolean" => PanelKind::Boolean,
        "opacity" => PanelKind::Opacity,
        "magic_wand" => PanelKind::MagicWand,
        "symbols" => PanelKind::Symbols,
        _ => PanelKind::Layers,
    }
}

/// Serialize a `PanelKind` to its canonical lowercase op string (the inverse of
/// `parse_panel_kind`; matches `test_json::panel_kind_str`). Production
/// `show_panel` sites use this to build the op JSON, so the round-trip is
/// lossless across all 13 kinds.
pub fn panel_kind_str(k: PanelKind) -> &'static str {
    match k {
        PanelKind::Layers => "layers",
        PanelKind::Color => "color",
        PanelKind::Swatches => "swatches",
        PanelKind::Brushes => "brushes",
        PanelKind::Stroke => "stroke",
        PanelKind::Properties => "properties",
        PanelKind::Character => "character",
        PanelKind::Paragraph => "paragraph",
        PanelKind::Artboards => "artboards",
        PanelKind::Align => "align",
        PanelKind::Boolean => "boolean",
        PanelKind::Opacity => "opacity",
        PanelKind::MagicWand => "magic_wand",
        PanelKind::Symbols => "symbols",
    }
}

/// Parse a pane-kind string to its `PaneKind`. Unknown falls back to `Canvas`
/// (matches `test_json::parse_pane_kind`).
fn parse_pane_kind(s: &str) -> PaneKind {
    match s {
        "toolbar" => PaneKind::Toolbar,
        "dock" => PaneKind::Dock,
        _ => PaneKind::Canvas,
    }
}

/// Serialize a `PaneKind` to its canonical op string (inverse of
/// `parse_pane_kind`).
pub fn pane_kind_str(k: PaneKind) -> &'static str {
    match k {
        PaneKind::Toolbar => "toolbar",
        PaneKind::Canvas => "canvas",
        PaneKind::Dock => "dock",
    }
}

// ---------------------------------------------------------------------------
// Op-JSON builders (production → dispatcher).
//
// Production layout-mutation sites build their op via these typed constructors
// and pass the result to `layout_apply`, so the JSON SHAPE for each verb lives
// in exactly one place (alongside the parser above) and a shape drift between
// the producer and the consumer is impossible. Each builder mirrors the field
// names the matching `layout_apply` arm reads.
// ---------------------------------------------------------------------------

/// `{op:"close_panel", dock_id, group_idx, panel_idx}`.
pub fn op_close_panel(addr: PanelAddr) -> serde_json::Value {
    serde_json::json!({
        "op": "close_panel",
        "dock_id": addr.group.dock_id.0,
        "group_idx": addr.group.group_idx,
        "panel_idx": addr.panel_idx,
    })
}

/// `{op:"set_active_panel", dock_id, group_idx, panel_idx}`.
pub fn op_set_active_panel(addr: PanelAddr) -> serde_json::Value {
    serde_json::json!({
        "op": "set_active_panel",
        "dock_id": addr.group.dock_id.0,
        "group_idx": addr.group.group_idx,
        "panel_idx": addr.panel_idx,
    })
}

/// `{op:"show_panel", kind}`.
pub fn op_show_panel(kind: PanelKind) -> serde_json::Value {
    serde_json::json!({ "op": "show_panel", "kind": panel_kind_str(kind) })
}

/// `{op:"toggle_group_collapsed", dock_id, group_idx}`.
pub fn op_toggle_group_collapsed(addr: GroupAddr) -> serde_json::Value {
    serde_json::json!({
        "op": "toggle_group_collapsed",
        "dock_id": addr.dock_id.0,
        "group_idx": addr.group_idx,
    })
}

/// `{op:"reorder_panel", dock_id, group_idx, from, to}`.
pub fn op_reorder_panel(group: GroupAddr, from: usize, to: usize) -> serde_json::Value {
    serde_json::json!({
        "op": "reorder_panel",
        "dock_id": group.dock_id.0,
        "group_idx": group.group_idx,
        "from": from,
        "to": to,
    })
}

/// `{op:"move_panel_to_group", from_*, to_*}`.
pub fn op_move_panel_to_group(from: PanelAddr, to: GroupAddr) -> serde_json::Value {
    serde_json::json!({
        "op": "move_panel_to_group",
        "from_dock_id": from.group.dock_id.0,
        "from_group_idx": from.group.group_idx,
        "from_panel_idx": from.panel_idx,
        "to_dock_id": to.dock_id.0,
        "to_group_idx": to.group_idx,
    })
}

/// `{op:"redock", dock_id}`.
pub fn op_redock(id: DockId) -> serde_json::Value {
    serde_json::json!({ "op": "redock", "dock_id": id.0 })
}

/// `{op:"hide_pane", kind}`.
pub fn op_hide_pane(kind: PaneKind) -> serde_json::Value {
    serde_json::json!({ "op": "hide_pane", "kind": pane_kind_str(kind) })
}

/// `{op:"show_pane", kind}`.
pub fn op_show_pane(kind: PaneKind) -> serde_json::Value {
    serde_json::json!({ "op": "show_pane", "kind": pane_kind_str(kind) })
}

/// `{op:"bring_pane_to_front", pane_id}`.
pub fn op_bring_pane_to_front(id: PaneId) -> serde_json::Value {
    serde_json::json!({ "op": "bring_pane_to_front", "pane_id": id.0 })
}

/// `{op:"toggle_canvas_maximized"}` — no params (the verb is a pure toggle of
/// `PaneLayout::canvas_maximized`).
pub fn op_toggle_canvas_maximized() -> serde_json::Value {
    serde_json::json!({ "op": "toggle_canvas_maximized" })
}

/// `{op:"tile_panes", set_canvas_maximized, [override_pane_id, override_width]}`.
/// `override` is the collapsed-dock fixed-width override the menu "Tile" handler
/// supplies (`None` for the plain corpus path).
pub fn op_tile_panes(
    set_canvas_maximized: bool,
    override_pane: Option<(PaneId, f64)>,
) -> serde_json::Value {
    let mut v = serde_json::json!({
        "op": "tile_panes",
        "set_canvas_maximized": set_canvas_maximized,
    });
    if let Some((pid, w)) = override_pane {
        v["override_pane_id"] = serde_json::json!(pid.0);
        v["override_width"] = serde_json::json!(w);
    }
    v
}

// Small hardened readers: a malformed production payload never panics. A
// missing/wrong-typed numeric field reads as 0, mirroring the document
// `op_apply` discipline (the harness fixtures always carry well-formed params,
// so they replay byte-identically).
#[inline]
fn u(op: &serde_json::Value, key: &str) -> usize {
    op[key].as_u64().unwrap_or(0) as usize
}
#[inline]
fn f(op: &serde_json::Value, key: &str) -> f64 {
    op[key].as_f64().unwrap_or(0.0)
}

/// Apply one primitive LAYOUT op to `layout`. The SINGLE per-verb mutation body
/// shared by production and the cross-language harness. Hardened: an unknown
/// verb or a missing required `kind`/`op` string SKIPS (no panic, no mutation).
pub fn layout_apply(layout: &mut WorkspaceLayout, op: &serde_json::Value) {
    let name = match op["op"].as_str() {
        Some(n) => n,
        None => return, // malformed op envelope: skip
    };
    match name {
        // ---- Panel / dock operations (mutate WorkspaceLayout directly) ----
        "toggle_group_collapsed" => {
            layout.toggle_group_collapsed(GroupAddr {
                dock_id: DockId(u(op, "dock_id")),
                group_idx: u(op, "group_idx"),
            });
        }
        "set_active_panel" => {
            layout.set_active_panel(PanelAddr {
                group: GroupAddr {
                    dock_id: DockId(u(op, "dock_id")),
                    group_idx: u(op, "group_idx"),
                },
                panel_idx: u(op, "panel_idx"),
            });
        }
        "close_panel" => {
            layout.close_panel(PanelAddr {
                group: GroupAddr {
                    dock_id: DockId(u(op, "dock_id")),
                    group_idx: u(op, "group_idx"),
                },
                panel_idx: u(op, "panel_idx"),
            });
        }
        "show_panel" => {
            let kind = match op["kind"].as_str() {
                Some(s) => parse_panel_kind(s),
                None => return, // required field missing: skip
            };
            layout.show_panel(kind);
        }
        "reorder_panel" => {
            layout.reorder_panel(
                GroupAddr {
                    dock_id: DockId(u(op, "dock_id")),
                    group_idx: u(op, "group_idx"),
                },
                u(op, "from"),
                u(op, "to"),
            );
        }
        "move_panel_to_group" => {
            layout.move_panel_to_group(
                PanelAddr {
                    group: GroupAddr {
                        dock_id: DockId(u(op, "from_dock_id")),
                        group_idx: u(op, "from_group_idx"),
                    },
                    panel_idx: u(op, "from_panel_idx"),
                },
                GroupAddr {
                    dock_id: DockId(u(op, "to_dock_id")),
                    group_idx: u(op, "to_group_idx"),
                },
            );
        }
        "detach_group" => {
            layout.detach_group(
                GroupAddr {
                    dock_id: DockId(u(op, "dock_id")),
                    group_idx: u(op, "group_idx"),
                },
                f(op, "x"),
                f(op, "y"),
            );
        }
        "redock" => {
            layout.redock(DockId(u(op, "dock_id")));
        }
        // ---- Pane operations (mutate the inner PaneLayout) ----
        // Each early-returns (skips) when there is no pane layout, matching the
        // production handlers which all guard on `if let Some(pl) = ...`.
        "set_pane_position" => {
            let pl = match layout.pane_layout.as_mut() {
                Some(pl) => pl,
                None => return,
            };
            pl.set_pane_position(PaneId(u(op, "pane_id")), f(op, "x"), f(op, "y"));
        }
        "tile_panes" => {
            let pl = match layout.pane_layout.as_mut() {
                Some(pl) => pl,
                None => return,
            };
            // The menu "Tile" handler clears canvas maximization before tiling;
            // it is opt-in via the explicit `set_canvas_maximized` bool param so
            // the bare-`{"op":"tile_panes"}` fixture path is unchanged.
            if let Some(b) = op["set_canvas_maximized"].as_bool() {
                pl.canvas_maximized = b;
            }
            // Optional override: a collapsed dock is tiled at a fixed width.
            // Absent in the fixture (which calls `tile_panes(None)`); present
            // only from the menu handler when the right dock is collapsed.
            let override_id = match (op["override_pane_id"].as_u64(),
                                     op["override_width"].as_f64()) {
                (Some(id), Some(w)) => Some((PaneId(id as usize), w)),
                _ => None,
            };
            pl.tile_panes(override_id);
        }
        "toggle_canvas_maximized" => {
            let pl = match layout.pane_layout.as_mut() {
                Some(pl) => pl,
                None => return,
            };
            pl.toggle_canvas_maximized();
        }
        "resize_pane" => {
            let pl = match layout.pane_layout.as_mut() {
                Some(pl) => pl,
                None => return,
            };
            pl.resize_pane(
                PaneId(u(op, "pane_id")),
                f(op, "width"),
                f(op, "height"),
            );
        }
        "hide_pane" => {
            let pl = match layout.pane_layout.as_mut() {
                Some(pl) => pl,
                None => return,
            };
            let kind = match op["kind"].as_str() {
                Some(s) => parse_pane_kind(s),
                None => return, // required field missing: skip
            };
            pl.hide_pane(kind);
        }
        "show_pane" => {
            let pl = match layout.pane_layout.as_mut() {
                Some(pl) => pl,
                None => return,
            };
            let kind = match op["kind"].as_str() {
                Some(s) => parse_pane_kind(s),
                None => return, // required field missing: skip
            };
            pl.show_pane(kind);
        }
        "bring_pane_to_front" => {
            let pl = match layout.pane_layout.as_mut() {
                Some(pl) => pl,
                None => return,
            };
            pl.bring_pane_to_front(PaneId(u(op, "pane_id")));
        }
        // Unknown verb: skip rather than panic (a malformed/forward-compat op
        // must not crash production; the corpus only ever sends known verbs).
        _ => {}
    }
}
