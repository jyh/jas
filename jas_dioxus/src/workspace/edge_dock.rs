//! Where the `Left` and `Bottom` anchored docks are drawn.
//!
//! WORKSPACE.md §"Anchored Docks by Edge", "Where each edge dock is drawn".
//! The pane layout has no pane for these two edges, so they are cut from the
//! canvas pane's rectangle: no snap constraint, toolbar or Right-dock
//! position changes. The `Right` dock is the `Dock` pane and is not handled
//! here.
//!
//! A pure function of the layout, so every app draws the same rectangles.
//! The arms below are written against the SPEC TEXT and its worked example,
//! never against the Swift twin (`JasSwift/Sources/Workspace/EdgeDockRects.swift`).

use super::pane::PaneKind;
use super::workspace::{Dock, DockEdge, WorkspaceLayout, MAX_DOCK_WIDTH};

/// A collapsed edge dock's thickness (rule 1). Crate-visible only: a `pub`
/// const is exported into the C header by cbindgen, and this is not ABI.
pub(crate) const COLLAPSED_EDGE_DOCK_THICKNESS: f64 = 36.0;

/// An axis-aligned rectangle in viewport coordinates.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EdgeRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl EdgeRect {
    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Self {
        Self { x, y, w, h }
    }
}

/// The rectangles of the left column, the bottom row and the canvas. An edge
/// that takes no space (no dock, or a dock with no groups) is `None`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EdgeDockRects {
    pub left: Option<EdgeRect>,
    pub bottom: Option<EdgeRect>,
    pub canvas: EdgeRect,
}

/// A dock's extent across its edge (rule 1): its `width`, clamped to its own
/// `min_width`..`MAX_DOCK_WIDTH` as `set_dock_width` clamps it, or 36 when
/// collapsed.
pub fn edge_dock_thickness(dock: &Dock) -> f64 {
    if dock.collapsed {
        return COLLAPSED_EDGE_DOCK_THICKNESS;
    }
    dock.width.min(MAX_DOCK_WIDTH).max(dock.min_width)
}

/// Rules 2–5 and 8. `canvas_pane` is the canvas pane's rectangle; when
/// `maximized`, the base is the whole viewport and the canvas keeps all of
/// it, with the edge docks drawn over it.
///
/// No reflow (the section's last paragraph): a pane too small for the docks
/// still gets them at their stated thickness. The canvas's extent is floored
/// at 0 so it is never negative.
pub fn edge_dock_rects(
    left: Option<&Dock>,
    bottom: Option<&Dock>,
    canvas_pane: EdgeRect,
    maximized: bool,
    viewport_w: f64,
    viewport_h: f64,
) -> EdgeDockRects {
    let base = if maximized { EdgeRect::new(0.0, 0.0, viewport_w, viewport_h) } else { canvas_pane };
    let thickness = |d: Option<&Dock>| d.filter(|d| !d.groups.is_empty()).map(edge_dock_thickness);
    let t_l = thickness(left);
    let t_b = thickness(bottom);

    // Rule 2: the left column, at the base's full height.
    let left_rect = t_l.map(|t| EdgeRect::new(base.x, base.y, t, base.h));
    // Rule 3: the bottom row starts at the left column's right side; the
    // bottom-left corner belongs to the left column.
    let row_x = base.x + t_l.unwrap_or(0.0);
    let row_w = (base.x + base.w - row_x).max(0.0);
    let bottom_rect = t_b.map(|t| EdgeRect::new(row_x, base.y + base.h - t, row_w, t));

    // Rule 4 (and rule 8: a maximized canvas keeps the whole viewport).
    let canvas = if maximized {
        base
    } else {
        EdgeRect::new(row_x, base.y, row_w, (base.h - t_b.unwrap_or(0.0)).max(0.0))
    };
    EdgeDockRects { left: left_rect, bottom: bottom_rect, canvas }
}

impl WorkspaceLayout {
    /// The edge-dock rectangles for this layout's anchored `Left` and
    /// `Bottom` docks and its canvas pane, or `None` with no pane layout or
    /// no canvas pane.
    pub fn edge_dock_rects(&self) -> Option<EdgeDockRects> {
        let pl = self.pane_layout.as_ref()?;
        let c = pl.pane_by_kind(PaneKind::Canvas)?;
        Some(edge_dock_rects(
            self.anchored_dock(DockEdge::Left),
            self.anchored_dock(DockEdge::Bottom),
            EdgeRect::new(c.x, c.y, c.width, c.height),
            pl.canvas_maximized,
            pl.viewport_width,
            pl.viewport_height,
        ))
    }
}

impl WorkspaceLayout {
    /// The edge-dock rectangles cut from an APP's own canvas cell, for an app
    /// whose pane layout is not its real geometry (the FFI path, jas 823).
    /// Rule 8 reads this layout's `canvas_maximized`, `false` with no pane
    /// layout; the cell needs no pane layout, since it is the app's.
    pub fn edge_dock_rects_in(&self, cell: EdgeRect, viewport_w: f64, viewport_h: f64) -> EdgeDockRects {
        edge_dock_rects(
            self.anchored_dock(DockEdge::Left),
            self.anchored_dock(DockEdge::Bottom),
            cell,
            self.pane_layout.as_ref().is_some_and(|pl| pl.canvas_maximized),
            viewport_w,
            viewport_h,
        )
    }
}

/// The body of `jas_layout_edge_rects` (jas 823): read `cell` as
/// `{"x","y","w","h","viewport_w","viewport_h"}` in DIPs and answer
/// `{"edge_rects":{"left","bottom","canvas"}}`, an absent edge as `null`.
/// A pure query: the cell is an argument, never stored, so it cannot go
/// stale. Refused as `("BadCell", key)` for a key that is missing, not a
/// finite number, or (for `w`, `h`) negative; `("BadCell", "")` for a cell
/// that is not an object.
pub fn edge_rects_reply(
    layout: &WorkspaceLayout,
    cell: &serde_json::Value,
) -> Result<serde_json::Value, (&'static str, String)> {
    let obj = cell.as_object().ok_or(("BadCell", String::new()))?;
    let num = |k: &str| -> Result<f64, (&'static str, String)> {
        obj.get(k).and_then(serde_json::Value::as_f64).filter(|v| v.is_finite())
            .ok_or(("BadCell", k.to_string()))
    };
    let size = |k: &str| num(k).and_then(|v| if v < 0.0 { Err(("BadCell", k.to_string())) } else { Ok(v) });
    let rect = EdgeRect::new(num("x")?, num("y")?, size("w")?, size("h")?);
    let r = layout.edge_dock_rects_in(rect, num("viewport_w")?, num("viewport_h")?);
    let json = |r: EdgeRect| serde_json::json!({"x": r.x, "y": r.y, "w": r.w, "h": r.h});
    Ok(serde_json::json!({"edge_rects": {
        "left": r.left.map(json),
        "bottom": r.bottom.map(json),
        "canvas": json(r.canvas),
    }}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::pane::PaneLayout;
    use crate::workspace::workspace::{DockId, PanelGroup, PanelKind, MIN_CANVAS_WIDTH, MIN_DOCK_WIDTH};

    fn dock(id: usize, groups: usize, width: f64, collapsed: bool, min_width: f64) -> Dock {
        Dock::from_parts(
            DockId(id),
            (0..groups).map(|_| PanelGroup::new(vec![PanelKind::Layers])).collect(),
            collapsed, false, width, min_width,
        )
    }
    fn d(id: usize, width: f64) -> Dock {
        dock(id, 1, width, false, MIN_DOCK_WIDTH)
    }

    /// The worked example's canvas pane: viewport 1200×800, toolbar 72,
    /// Right dock 240, so the canvas pane is x 72..960, y 0..800.
    const PANE: EdgeRect = EdgeRect { x: 72.0, y: 0.0, w: 888.0, h: 800.0 };

    fn rects(left: Option<&Dock>, bottom: Option<&Dock>, pane: EdgeRect, maximized: bool) -> EdgeDockRects {
        edge_dock_rects(left, bottom, pane, maximized, 1200.0, 800.0)
    }

    #[test]
    fn edge_dock_worked_example() {
        let r = rects(Some(&d(1, 200.0)), Some(&d(2, 180.0)), PANE, false);
        assert_eq!(r.left, Some(EdgeRect::new(72.0, 0.0, 200.0, 800.0)));
        assert_eq!(r.bottom, Some(EdgeRect::new(272.0, 620.0, 688.0, 180.0)));
        assert_eq!(r.canvas, EdgeRect::new(272.0, 0.0, 688.0, 620.0));
    }

    /// The example's pane is the one the default three-pane layout builds,
    /// so the example is about the app's real starting state.
    #[test]
    fn edge_dock_example_pane_is_the_default_canvas_pane() {
        let pl = PaneLayout::default_three_pane(1200.0, 800.0);
        let c = pl.pane_by_kind(PaneKind::Canvas).unwrap();
        assert_eq!(EdgeRect::new(c.x, c.y, c.width, c.height), PANE);
    }

    // Rule 5: an empty or missing edge takes no space.
    #[test]
    fn edge_dock_no_edge_docks_leaves_the_canvas_pane_whole() {
        let r = rects(None, None, PANE, false);
        assert_eq!((r.left, r.bottom, r.canvas), (None, None, PANE));
    }

    #[test]
    fn edge_dock_with_no_groups_takes_no_space() {
        let l = dock(1, 0, 200.0, false, MIN_DOCK_WIDTH);
        let b = dock(2, 0, 180.0, false, MIN_DOCK_WIDTH);
        let r = rects(Some(&l), Some(&b), PANE, false);
        assert_eq!((r.left, r.bottom, r.canvas), (None, None, PANE));
    }

    // Rule 3: with no left column the bottom row starts at the pane's left.
    #[test]
    fn edge_dock_bottom_only_starts_at_the_pane_left() {
        let r = rects(None, Some(&d(2, 180.0)), PANE, false);
        assert_eq!(r.left, None);
        assert_eq!(r.bottom, Some(EdgeRect::new(72.0, 620.0, 888.0, 180.0)));
        assert_eq!(r.canvas, EdgeRect::new(72.0, 0.0, 888.0, 620.0));
    }

    // Rule 2: the left column is the pane's full height with no bottom row.
    #[test]
    fn edge_dock_left_only_runs_the_full_height() {
        let r = rects(Some(&d(1, 200.0)), None, PANE, false);
        assert_eq!(r.left, Some(EdgeRect::new(72.0, 0.0, 200.0, 800.0)));
        assert_eq!(r.bottom, None);
        assert_eq!(r.canvas, EdgeRect::new(272.0, 0.0, 688.0, 800.0));
    }

    // Rule 1: a collapsed edge dock is 36px thick, whatever its width.
    #[test]
    fn edge_dock_collapsed_is_36_thick() {
        let l = dock(1, 1, 200.0, true, MIN_DOCK_WIDTH);
        let b = dock(2, 1, 180.0, true, MIN_DOCK_WIDTH);
        let r = rects(Some(&l), Some(&b), PANE, false);
        assert_eq!(r.left, Some(EdgeRect::new(72.0, 0.0, 36.0, 800.0)));
        assert_eq!(r.bottom, Some(EdgeRect::new(108.0, 764.0, 852.0, 36.0)));
        assert_eq!(r.canvas, EdgeRect::new(108.0, 0.0, 852.0, 764.0));
    }

    // Rule 1: thickness clamps to the dock's OWN min_width (not
    // MIN_DOCK_WIDTH) and to MAX_DOCK_WIDTH, as set_dock_width clamps it.
    #[test]
    fn edge_dock_thickness_clamps_to_its_own_min_and_max() {
        assert_eq!(edge_dock_thickness(&dock(1, 1, 10.0, false, 120.0)), 120.0);
        assert_eq!(edge_dock_thickness(&d(1, 10.0)), MIN_DOCK_WIDTH);
        assert_eq!(edge_dock_thickness(&d(1, 9999.0)), MAX_DOCK_WIDTH);
        assert_eq!(edge_dock_thickness(&d(1, 200.0)), 200.0);
        assert_eq!(edge_dock_thickness(&dock(1, 1, 10.0, true, MIN_DOCK_WIDTH)), 36.0);
    }

    // Rule 8: canvas maximized — the canvas takes the whole viewport and the
    // edge docks are drawn over it at the viewport's left and bottom edges.
    #[test]
    fn edge_dock_maximized_draws_over_the_whole_viewport() {
        let r = rects(Some(&d(1, 200.0)), Some(&d(2, 180.0)), PANE, true);
        assert_eq!(r.left, Some(EdgeRect::new(0.0, 0.0, 200.0, 800.0)));
        assert_eq!(r.bottom, Some(EdgeRect::new(200.0, 620.0, 1000.0, 180.0)));
        assert_eq!(r.canvas, EdgeRect::new(0.0, 0.0, 1200.0, 800.0));
    }

    // No reflow: a pane too small still gets the docks at their stated
    // thickness; the canvas may go below MIN_CANVAS_WIDTH (never negative).
    #[test]
    fn edge_dock_too_small_a_pane_keeps_the_stated_thickness() {
        let pane = EdgeRect::new(72.0, 0.0, 250.0, 800.0);
        let r = rects(Some(&d(1, 200.0)), None, pane, false);
        assert_eq!(r.left, Some(EdgeRect::new(72.0, 0.0, 200.0, 800.0)));
        assert_eq!(r.canvas, EdgeRect::new(272.0, 0.0, 50.0, 800.0));
        assert!(r.canvas.w < MIN_CANVAS_WIDTH);
    }

    // The layout-level entry reads the anchored Left and Bottom docks and the
    // canvas pane; the Right dock never enters it.
    #[test]
    fn edge_dock_layout_entry_reads_anchored_docks_and_canvas_pane() {
        let mut l = WorkspaceLayout::default_layout();
        let mut pl = PaneLayout::default_three_pane(1200.0, 800.0);
        pl.canvas_maximized = false;
        l.pane_layout = Some(pl);
        l.anchored.push((DockEdge::Left, d(7, 200.0)));
        l.anchored.push((DockEdge::Bottom, d(8, 180.0)));
        let r = l.edge_dock_rects().unwrap();
        assert_eq!(r.left, Some(EdgeRect::new(72.0, 0.0, 200.0, 800.0)));
        assert_eq!(r.bottom, Some(EdgeRect::new(272.0, 620.0, 688.0, 180.0)));
        assert_eq!(r.canvas, EdgeRect::new(272.0, 0.0, 688.0, 620.0));
    }

    #[test]
    fn edge_dock_layout_entry_without_a_pane_layout_is_none() {
        let mut l = WorkspaceLayout::default_layout();
        l.pane_layout = None;
        assert_eq!(l.edge_dock_rects(), None);
    }

    // --- `edge_rects_reply`: the body of `jas_layout_edge_rects` (jas 823) ---

    fn cell(x: f64, y: f64, w: f64, h: f64, vw: f64, vh: f64) -> serde_json::Value {
        serde_json::json!({"x": x, "y": y, "w": w, "h": h, "viewport_w": vw, "viewport_h": vh})
    }

    fn rect_json(x: f64, y: f64, w: f64, h: f64) -> serde_json::Value {
        serde_json::json!({"x": x, "y": y, "w": w, "h": h})
    }

    fn with_panes() -> WorkspaceLayout {
        let mut l = WorkspaceLayout::default_layout();
        let mut pl = PaneLayout::default_three_pane(1200.0, 800.0);
        pl.canvas_maximized = false;
        l.pane_layout = Some(pl);
        l
    }

    /// Moved from `layout_seed` (the reply no longer carries `edge_rects`):
    /// the worked example, now over the cell the app passes.
    #[test]
    fn the_reply_cuts_the_worked_example_from_the_cell() {
        let mut l = with_panes();
        l.anchored.push((DockEdge::Left, dock(7, 1, 200.0, false, MIN_DOCK_WIDTH)));
        l.anchored.push((DockEdge::Bottom, dock(8, 1, 180.0, false, MIN_DOCK_WIDTH)));
        let r = &edge_rects_reply(&l, &cell(72.0, 0.0, 888.0, 800.0, 1200.0, 800.0)).unwrap()["edge_rects"];
        assert_eq!(r["left"], rect_json(72.0, 0.0, 200.0, 800.0));
        assert_eq!(r["bottom"], rect_json(272.0, 620.0, 688.0, 180.0));
        assert_eq!(r["canvas"], rect_json(272.0, 0.0, 688.0, 620.0));
    }

    /// Moved from `layout_seed`: an absent edge is `null`, never omitted.
    #[test]
    fn the_reply_with_a_left_dock_alone_reads_bottom_null() {
        let mut l = with_panes();
        l.anchored.push((DockEdge::Left, dock(7, 1, 200.0, false, MIN_DOCK_WIDTH)));
        let r = &edge_rects_reply(&l, &cell(72.0, 0.0, 888.0, 800.0, 1200.0, 800.0)).unwrap()["edge_rects"];
        assert!(r.as_object().is_some_and(|o| o.contains_key("bottom")), "bottom is present, as null: {r}");
        assert_eq!(r["bottom"], serde_json::Value::Null, "{r}");
        assert_eq!(r["left"], rect_json(72.0, 0.0, 200.0, 800.0));
        assert_eq!(r["canvas"], rect_json(272.0, 0.0, 688.0, 800.0));
    }

    /// Moved from `layout_seed`: no edge dock leaves the whole cell to the
    /// canvas, and a layout with NO pane layout still answers over the cell
    /// (the cell is the app's, so it needs none; maximized reads false).
    #[test]
    fn the_reply_with_no_edge_dock_gives_the_canvas_the_cell() {
        let mut l = with_panes();
        let r = &edge_rects_reply(&l, &cell(10.0, 30.0, 1500.0, 700.0, 1800.0, 760.0)).unwrap()["edge_rects"];
        assert_eq!((&r["left"], &r["bottom"]), (&serde_json::Value::Null, &serde_json::Value::Null), "{r}");
        assert_eq!(r["canvas"], rect_json(10.0, 30.0, 1500.0, 700.0));
        l.pane_layout = None;
        let r = &edge_rects_reply(&l, &cell(10.0, 30.0, 1500.0, 700.0, 1800.0, 760.0)).unwrap()["edge_rects"];
        assert_eq!(r["canvas"], rect_json(10.0, 30.0, 1500.0, 700.0));
    }

    /// The cell, never the held pane layout: the held canvas pane is
    /// 72,0 888x800, and the answer follows the cell passed.
    #[test]
    fn the_reply_reads_the_cell_not_the_held_pane_layout() {
        let mut l = with_panes();
        l.anchored.push((DockEdge::Left, dock(7, 1, 200.0, false, MIN_DOCK_WIDTH)));
        let r = &edge_rects_reply(&l, &cell(0.0, 40.0, 1000.0, 600.0, 1300.0, 700.0)).unwrap()["edge_rects"];
        assert_eq!(r["left"], rect_json(0.0, 40.0, 200.0, 600.0));
        assert_eq!(r["canvas"], rect_json(200.0, 40.0, 800.0, 600.0));
    }

    /// `BadCell`, detail the key: a missing key, a non-number, a negative
    /// `w` or `h`. (JSON carries no NaN or infinity, so a finite check
    /// guards only a caller that builds the Value in Rust.)
    #[test]
    fn a_bad_cell_is_refused_by_its_key() {
        let l = with_panes();
        let refused = |c: serde_json::Value| edge_rects_reply(&l, &c).err();
        let full = cell(0.0, 0.0, 100.0, 100.0, 100.0, 100.0);
        for key in ["x", "y", "w", "h", "viewport_w", "viewport_h"] {
            let mut c = full.clone();
            c.as_object_mut().unwrap().remove(key);
            assert_eq!(refused(c), Some(("BadCell", key.to_string())), "missing {key}");
            let mut c = full.clone();
            c[key] = serde_json::json!("1");
            assert_eq!(refused(c), Some(("BadCell", key.to_string())), "string {key}");
        }
        for key in ["w", "h"] {
            let mut c = full.clone();
            c[key] = serde_json::json!(-1.0);
            assert_eq!(refused(c), Some(("BadCell", key.to_string())), "negative {key}");
        }
        assert_eq!(refused(serde_json::json!([1, 2])), Some(("BadCell", String::new())), "not an object");
        assert_eq!(edge_rects_reply(&l, &full).err(), None, "the full cell is accepted");
    }
}
