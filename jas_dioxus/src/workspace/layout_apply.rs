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
    DockEdge, DockId, GroupAddr, PanelAddr, PanelKind, WorkspaceLayout,
};
use crate::workspace::pane::PaneId;
use crate::workspace::workspace::PaneKind;

/// Parse a panel-kind string to its `PanelKind`. Complete over all 16 kinds
/// (matches `test_json::parse_panel_kind`); an unknown/garbage string falls
/// back to `Layers` so a malformed op never panics. The pre-3d-2 harness shim
/// had a 5-kind subset; the runtime dispatcher needs the full set because the
/// production `show_panel` handler covers every `PanelKind`. Public so the
/// generic native `toggle_panel` dispatch (renderer) can resolve a bundle
/// panel-id string to its `PanelKind`.
pub fn parse_panel_kind(s: &str) -> PanelKind {
    match s {
        "color" => PanelKind::Color,
        "swatches" => PanelKind::Swatches,
        "brushes" => PanelKind::Brushes,
        "gradient" => PanelKind::Gradient,
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
        "concepts" => PanelKind::Concepts,
        _ => PanelKind::Layers,
    }
}

/// Serialize a `PanelKind` to its canonical lowercase op string (the inverse of
/// `parse_panel_kind`; matches `test_json::panel_kind_str`). Production
/// `show_panel` sites use this to build the op JSON, so the round-trip is
/// lossless across all 16 kinds.
pub fn panel_kind_str(k: PanelKind) -> &'static str {
    match k {
        PanelKind::Layers => "layers",
        PanelKind::Color => "color",
        PanelKind::Swatches => "swatches",
        PanelKind::Brushes => "brushes",
        PanelKind::Gradient => "gradient",
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
        PanelKind::Concepts => "concepts",
    }
}

/// A detach that carries the drop's viewport (`viewport_w`, `viewport_h`)
/// snaps the new dock to the edge it was dropped near, in the same op, as the
/// web's dock-tab drop does (`is_near_edge`, then `snap_to_edge`). With no
/// viewport, or away from every edge, the dock floats. One op, so a shell
/// never needs the new dock's id to finish its own drop.
fn snap_if_dropped_near_an_edge(layout: &mut WorkspaceLayout, op: &serde_json::Value, fid: Option<DockId>) {
    let (Some(fid), Some(vw), Some(vh)) = (fid, op["viewport_w"].as_f64(), op["viewport_h"].as_f64()) else {
        return;
    };
    if let Some(edge) = WorkspaceLayout::is_near_edge(f(op, "x"), f(op, "y"), vw, vh) {
        layout.snap_to_edge(fid, edge);
    }
}

/// Parse a dock-edge string (`left` / `right` / `bottom`, as `test_json`
/// writes it). Unknown is `None`, so `snap_to_edge` skips rather than guess
/// an edge.
fn parse_dock_edge(s: &str) -> Option<DockEdge> {
    match s {
        "left" => Some(DockEdge::Left),
        "right" => Some(DockEdge::Right),
        "bottom" => Some(DockEdge::Bottom),
        _ => None,
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

/// `{op:"toggle_pane", kind}`: hide the pane if visible, else show it.
pub fn op_toggle_pane(kind: PaneKind) -> serde_json::Value {
    serde_json::json!({ "op": "toggle_pane", "kind": pane_kind_str(kind) })
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
/// verb or a missing required `kind`/`op`/`edge` string SKIPS (no panic, no
/// mutation).
///
/// Production sites call this; [`layout_apply_checked`] is the same body and
/// also says whether it recognised the op.
pub fn layout_apply(layout: &mut WorkspaceLayout, op: &serde_json::Value) {
    layout_apply_checked(layout, op);
}

/// [`layout_apply`], answering whether the op was one the dispatcher
/// RECOGNISES: `false` for a skip (no `op`, an unknown verb, a required field
/// missing), `true` otherwise, including a pane verb on a layout with no pane
/// layout, which is well formed with nothing to act on (that guard runs before
/// the verb's own fields are read). The FFI's `jas_layout_apply` refuses on
/// `false`, because a shell would read an unchanged layout as an answer.
pub fn layout_apply_checked(layout: &mut WorkspaceLayout, op: &serde_json::Value) -> bool {
    let name = match op["op"].as_str() {
        Some(n) => n,
        None => return false, // malformed op envelope: skip
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
                None => return false, // required field missing: skip
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
            let fid = layout.detach_group(
                GroupAddr {
                    dock_id: DockId(u(op, "dock_id")),
                    group_idx: u(op, "group_idx"),
                },
                f(op, "x"),
                f(op, "y"),
            );
            snap_if_dropped_near_an_edge(layout, op, fid);
        }
        "redock" => {
            layout.redock(DockId(u(op, "dock_id")));
        }
        // ---- Floating docks (the floating-panels node: one verb per
        // `WorkspaceLayout` method a shell drives, so no shell forks the law) ----
        "detach_panel" => {
            let fid = layout.detach_panel(
                PanelAddr {
                    group: GroupAddr {
                        dock_id: DockId(u(op, "dock_id")),
                        group_idx: u(op, "group_idx"),
                    },
                    panel_idx: u(op, "panel_idx"),
                },
                f(op, "x"),
                f(op, "y"),
            );
            snap_if_dropped_near_an_edge(layout, op, fid);
        }
        "set_floating_position" => {
            layout.set_floating_position(DockId(u(op, "dock_id")), f(op, "x"), f(op, "y"));
        }
        "bring_to_front" => {
            layout.bring_to_front(DockId(u(op, "dock_id")));
        }
        "snap_to_edge" => {
            let edge = match op["edge"].as_str().and_then(parse_dock_edge) {
                Some(e) => e,
                None => return false, // required field missing or unknown: skip
            };
            layout.snap_to_edge(DockId(u(op, "dock_id")), edge);
        }
        "clamp_floating_docks" => {
            layout.clamp_floating_docks(f(op, "viewport_w"), f(op, "viewport_h"));
        }
        // ---- Pane operations (mutate the inner PaneLayout) ----
        // Each early-returns (skips) when there is no pane layout, matching the
        // production handlers which all guard on `if let Some(pl) = ...`.
        "set_pane_position" => {
            let pl = match layout.pane_layout.as_mut() {
                Some(pl) => pl,
                None => return true, // no pane layout: nothing to act on
            };
            pl.set_pane_position(PaneId(u(op, "pane_id")), f(op, "x"), f(op, "y"));
        }
        "tile_panes" => {
            let pl = match layout.pane_layout.as_mut() {
                Some(pl) => pl,
                None => return true, // no pane layout: nothing to act on
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
                None => return true, // no pane layout: nothing to act on
            };
            pl.toggle_canvas_maximized();
        }
        // The dock at an edge, collapsed to its icon strip or expanded
        // (collapse_dock / expand_dock / toggle_dock_collapse). `set` is
        // idempotent; `toggle` flips. No anchored dock there: nothing to act on.
        "set_dock_collapsed" | "toggle_dock_collapsed" => {
            let Some(edge) = op["edge"].as_str().and_then(parse_dock_edge) else {
                return false; // required field missing or unknown: skip
            };
            let value = op["value"].as_bool();
            if op["op"] == "set_dock_collapsed" && value.is_none() {
                return false; // required field missing: skip
            }
            let Some(id) = layout.anchored_dock(edge).map(|d| d.id) else { return true };
            let collapsed = layout.anchored_dock(edge).is_some_and(|d| d.collapsed);
            if value.is_none_or(|v| v != collapsed) {
                layout.toggle_dock_collapsed(id);
            }
        }
        // The YAML's `set_canvas_maximized` (maximize_canvas / restore_canvas):
        // idempotent, unlike the toggle, so a second Maximize stays maximized.
        "set_canvas_maximized" => {
            let pl = match layout.pane_layout.as_mut() {
                Some(pl) => pl,
                None => return true, // no pane layout: nothing to act on
            };
            match op["value"].as_bool() {
                Some(b) => pl.canvas_maximized = b,
                None => return false, // required field missing: skip
            }
        }
        // The Window menu's Toolbar / Panels item: hide the pane if it is
        // visible, else show it (the rule both native menu routes applied).
        "toggle_pane" => {
            let pl = match layout.pane_layout.as_mut() {
                Some(pl) => pl,
                None => return true, // no pane layout: nothing to act on
            };
            let kind = match op["kind"].as_str() {
                Some(s) => parse_pane_kind(s),
                None => return false, // required field missing: skip
            };
            if pl.is_pane_visible(kind) { pl.hide_pane(kind) } else { pl.show_pane(kind) }
        }
        "resize_pane" => {
            let pl = match layout.pane_layout.as_mut() {
                Some(pl) => pl,
                None => return true, // no pane layout: nothing to act on
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
                None => return true, // no pane layout: nothing to act on
            };
            let kind = match op["kind"].as_str() {
                Some(s) => parse_pane_kind(s),
                None => return false, // required field missing: skip
            };
            pl.hide_pane(kind);
        }
        "show_pane" => {
            let pl = match layout.pane_layout.as_mut() {
                Some(pl) => pl,
                None => return true, // no pane layout: nothing to act on
            };
            let kind = match op["kind"].as_str() {
                Some(s) => parse_pane_kind(s),
                None => return false, // required field missing: skip
            };
            pl.show_pane(kind);
        }
        "bring_pane_to_front" => {
            let pl = match layout.pane_layout.as_mut() {
                Some(pl) => pl,
                None => return true, // no pane layout: nothing to act on
            };
            pl.bring_pane_to_front(PaneId(u(op, "pane_id")));
        }
        // Unknown verb: skip rather than panic (a malformed/forward-compat op
        // must not crash production; the corpus only ever sends known verbs).
        _ => return false,
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::workspace::DockEdge;
    use serde_json::json;

    fn edges(l: &WorkspaceLayout) -> Vec<DockEdge> {
        l.anchored.iter().map(|(e, _)| *e).collect()
    }

    /// The Window menu's Toolbar item dispatches `op_toggle_pane`: once hides
    /// the visible toolbar, twice shows it again. Pins the builder's spelling
    /// against the dispatcher, which skips an unknown verb silently.
    #[test]
    fn op_toggle_pane_hides_then_shows() {
        let mut l = WorkspaceLayout::default_layout();
        l.ensure_pane_layout(1200.0, 800.0);
        let visible = |l: &WorkspaceLayout| l.pane_layout.as_ref().unwrap().is_pane_visible(PaneKind::Toolbar);
        assert!(visible(&l));
        assert!(layout_apply_checked(&mut l, &op_toggle_pane(PaneKind::Toolbar)), "the verb is known");
        assert!(!visible(&l), "one toggle hides the toolbar");
        layout_apply(&mut l, &op_toggle_pane(PaneKind::Toolbar));
        assert!(visible(&l), "a second toggle shows it again");
    }

    /// A detach carrying the viewport snaps the new dock to the edge it was
    /// dropped near, in the same op, as the web's dock-tab drop does (detach,
    /// then `snap_to_edge` on `is_near_edge`); away from every edge, or with no
    /// viewport, it floats. Each case is driven against the plain detach. An
    /// edge that already holds an anchored dock takes the group INTO that dock
    /// (`snap_to_edge` merges, as `redock` does), so the right edge adds no dock:
    /// the detached group lands last in the right dock.
    #[test]
    fn a_detach_dropped_near_an_edge_snaps_there() {
        let vp = |mut op: serde_json::Value| { op["viewport_w"] = json!(1200.0); op["viewport_h"] = json!(800.0); op };
        let group = |x: f64, y: f64| json!({"op": "detach_group", "dock_id": 0, "group_idx": 0, "x": x, "y": y});
        let panel = |x: f64, y: f64| json!({"op": "detach_panel", "dock_id": 0, "group_idx": 0, "panel_idx": 1, "x": x, "y": y});
        for (op, want_edge) in [
            (vp(group(5.0, 200.0)), Some(DockEdge::Left)),
            (vp(panel(600.0, 790.0)), Some(DockEdge::Bottom)),
            (vp(group(500.0, 300.0)), None),
            (group(5.0, 200.0), None),
        ] {
            let mut l = WorkspaceLayout::default_layout();
            assert!(layout_apply_checked(&mut l, &op), "{op}");
            match want_edge {
                Some(e) => {
                    assert!(l.floating.is_empty(), "{op}: snapped, so nothing floats");
                    assert_eq!(edges(&l).len(), 2, "{op}: a second anchored dock");
                    assert_eq!(edges(&l)[1], e, "{op}");
                }
                None => {
                    assert_eq!(l.floating.len(), 1, "{op}: it floats");
                    assert_eq!(edges(&l), vec![DockEdge::Right], "{op}: no new anchored dock");
                }
            }
        }
        let mut l = WorkspaceLayout::default_layout();
        let first = l.anchored[0].1.groups[0].panels.clone();
        let n = l.anchored[0].1.groups.len();
        assert!(layout_apply_checked(&mut l, &vp(group(1195.0, 200.0))));
        assert!(l.floating.is_empty(), "snapped right, so nothing floats");
        assert_eq!(edges(&l), vec![DockEdge::Right], "merged into the right dock, no second one");
        assert_eq!(l.anchored[0].1.groups.len(), n, "the group left and came back");
        assert_eq!(l.anchored[0].1.groups[n - 1].panels, first, "it lands last");
    }
}
