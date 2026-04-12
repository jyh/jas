//! Pane layout: floating, movable, resizable panes.
//!
//! A [`PaneLayout`] manages the positions, sizes, and snap constraints
//! for the top-level panes (toolbar, canvas, dock). Each [`Pane`] carries
//! a [`PaneConfig`] that drives generic behavior like tiling, resizing,
//! and title bar chrome.
//!
//! This module contains only pure data types and state operations — no
//! rendering code.

use serde::{Serialize, Deserialize};

use super::workspace::{DEFAULT_DOCK_WIDTH, MIN_CANVAS_WIDTH, SNAP_DISTANCE};

// ---------------------------------------------------------------------------
// Pane layout: floating, movable, resizable panes for toolbar/canvas/dock
// ---------------------------------------------------------------------------

pub const MIN_TOOLBAR_WIDTH: f64 = 72.0;
pub const MIN_TOOLBAR_HEIGHT: f64 = 200.0;
pub const MIN_CANVAS_HEIGHT: f64 = 200.0;
pub const MIN_PANE_DOCK_WIDTH: f64 = 150.0;
pub const MIN_PANE_DOCK_HEIGHT: f64 = 100.0;
pub const DEFAULT_TOOLBAR_WIDTH: f64 = 72.0;
pub const BORDER_HIT_TOLERANCE: f64 = 6.0;
pub const MIN_PANE_VISIBLE: f64 = 50.0;

/// Stable identifier for a pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PaneId(pub usize);

/// Which top-level region a pane represents.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum PaneKind {
    Toolbar,
    Canvas,
    Dock,
}

/// How a pane's width is allocated during the Tile operation.
/// Derived at tile time from PaneConfig fields, not stored.
#[derive(Debug, Clone, Copy, PartialEq)]
enum TileWidth {
    /// Keep current width (fixed-width or collapsible panes).
    Fixed(f64),
    /// Keep current width (collapsible panes like Dock).
    KeepCurrent(f64),
    /// Fill all remaining space (e.g., Canvas).
    Flex,
}

/// Action triggered by double-clicking a pane's title bar.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
pub enum DoubleClickAction {
    /// Toggle maximize (canvas).
    Maximize,
    /// Merge floating dock back into nearest anchored dock.
    Redock,
    /// No action.
    #[default]
    None,
}

/// Configuration that drives generic pane management behavior.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaneConfig {
    pub label: String,
    pub min_width: f64,
    pub min_height: f64,
    pub fixed_width: bool,
    /// Width when in collapsed state; None means not collapsible.
    #[serde(default)]
    pub collapsed_width: Option<f64>,
    /// Action triggered by double-clicking the title bar.
    #[serde(default)]
    pub double_click_action: DoubleClickAction,
}

impl PaneConfig {
    /// Return the default config for a given pane kind.
    pub fn for_kind(kind: PaneKind) -> Self {
        match kind {
            PaneKind::Toolbar => Self {
                label: "Tools".into(),
                min_width: MIN_TOOLBAR_WIDTH,
                min_height: MIN_TOOLBAR_HEIGHT,
                fixed_width: true,
                collapsed_width: None,
                double_click_action: DoubleClickAction::None,
            },
            PaneKind::Canvas => Self {
                label: "Canvas".into(),
                min_width: MIN_CANVAS_WIDTH,
                min_height: MIN_CANVAS_HEIGHT,
                fixed_width: false,
                collapsed_width: None,
                double_click_action: DoubleClickAction::Maximize,
            },
            PaneKind::Dock => Self {
                label: "Panels".into(),
                min_width: MIN_PANE_DOCK_WIDTH,
                min_height: MIN_PANE_DOCK_HEIGHT,
                fixed_width: false,
                collapsed_width: Some(36.0),
                double_click_action: DoubleClickAction::Redock,
            },
        }
    }
}

impl Default for PaneConfig {
    fn default() -> Self {
        Self::for_kind(PaneKind::Canvas)
    }
}

/// A floating pane with position, size, and configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Pane {
    pub id: PaneId,
    pub kind: PaneKind,
    #[serde(default)]
    pub config: PaneConfig,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Which side of a rectangle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum EdgeSide {
    Left,
    Right,
    Top,
    Bottom,
}

/// What a pane edge is snapped to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SnapTarget {
    /// Snapped to a window edge.
    Window(EdgeSide),
    /// Snapped to another pane's edge.
    Pane(PaneId, EdgeSide),
}

/// A snap constraint: one pane edge is attached to a target.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnapConstraint {
    pub pane: PaneId,
    pub edge: EdgeSide,
    pub target: SnapTarget,
}

/// Layout of the three top-level panes (toolbar, canvas, dock).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaneLayout {
    pub panes: Vec<Pane>,
    pub snaps: Vec<SnapConstraint>,
    pub z_order: Vec<PaneId>,
    /// Pane kinds that are currently hidden (closed).
    #[serde(default)]
    pub hidden_panes: Vec<PaneKind>,
    /// Whether the canvas pane is maximized to fill the window.
    #[serde(default)]
    pub canvas_maximized: bool,
    pub viewport_width: f64,
    pub viewport_height: f64,
    next_pane_id: usize,
}

impl PaneLayout {
    // -----------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------

    /// Create the default three-pane layout filling the viewport left-to-right:
    /// toolbar(72px) | canvas(flex) | dock(240px).
    pub fn default_three_pane(viewport_w: f64, viewport_h: f64) -> Self {
        let toolbar_w = DEFAULT_TOOLBAR_WIDTH;
        let dock_w = DEFAULT_DOCK_WIDTH;
        let canvas_w = (viewport_w - toolbar_w - dock_w).max(MIN_CANVAS_WIDTH);

        let toolbar_id = PaneId(0);
        let canvas_id = PaneId(1);
        let dock_id = PaneId(2);

        let panes = vec![
            Pane { id: toolbar_id, kind: PaneKind::Toolbar, config: PaneConfig::for_kind(PaneKind::Toolbar), x: 0.0, y: 0.0, width: toolbar_w, height: viewport_h },
            Pane { id: canvas_id, kind: PaneKind::Canvas, config: PaneConfig::for_kind(PaneKind::Canvas), x: toolbar_w, y: 0.0, width: canvas_w, height: viewport_h },
            Pane { id: dock_id, kind: PaneKind::Dock, config: PaneConfig::for_kind(PaneKind::Dock), x: toolbar_w + canvas_w, y: 0.0, width: dock_w, height: viewport_h },
        ];

        let snaps = vec![
            // Toolbar: left to window, right to canvas, top/bottom to window
            SnapConstraint { pane: toolbar_id, edge: EdgeSide::Left, target: SnapTarget::Window(EdgeSide::Left) },
            SnapConstraint { pane: toolbar_id, edge: EdgeSide::Top, target: SnapTarget::Window(EdgeSide::Top) },
            SnapConstraint { pane: toolbar_id, edge: EdgeSide::Bottom, target: SnapTarget::Window(EdgeSide::Bottom) },
            SnapConstraint { pane: toolbar_id, edge: EdgeSide::Right, target: SnapTarget::Pane(canvas_id, EdgeSide::Left) },
            // Canvas: top/bottom to window, right to dock (left covered by toolbar snap)
            SnapConstraint { pane: canvas_id, edge: EdgeSide::Top, target: SnapTarget::Window(EdgeSide::Top) },
            SnapConstraint { pane: canvas_id, edge: EdgeSide::Bottom, target: SnapTarget::Window(EdgeSide::Bottom) },
            SnapConstraint { pane: canvas_id, edge: EdgeSide::Right, target: SnapTarget::Pane(dock_id, EdgeSide::Left) },
            // Dock: right to window, top/bottom to window (left covered by canvas snap)
            SnapConstraint { pane: dock_id, edge: EdgeSide::Right, target: SnapTarget::Window(EdgeSide::Right) },
            SnapConstraint { pane: dock_id, edge: EdgeSide::Top, target: SnapTarget::Window(EdgeSide::Top) },
            SnapConstraint { pane: dock_id, edge: EdgeSide::Bottom, target: SnapTarget::Window(EdgeSide::Bottom) },
        ];

        let z_order = vec![canvas_id, toolbar_id, dock_id];

        Self {
            panes,
            snaps,
            z_order,
            hidden_panes: vec![],
            canvas_maximized: false,
            viewport_width: viewport_w,
            viewport_height: viewport_h,
            next_pane_id: 3,
        }
    }

    /// Return the next pane id counter (for test JSON serialization).
    pub fn next_pane_id(&self) -> usize {
        self.next_pane_id
    }

    /// Reconstruct a PaneLayout from all fields (for test JSON deserialization).
    pub fn from_parts(
        panes: Vec<Pane>,
        snaps: Vec<SnapConstraint>,
        z_order: Vec<PaneId>,
        hidden_panes: Vec<PaneKind>,
        canvas_maximized: bool,
        viewport_width: f64,
        viewport_height: f64,
        next_pane_id: usize,
    ) -> Self {
        Self { panes, snaps, z_order, hidden_panes, canvas_maximized, viewport_width, viewport_height, next_pane_id }
    }

    // -----------------------------------------------------------------------
    // Lookup
    // -----------------------------------------------------------------------

    pub fn pane(&self, id: PaneId) -> Option<&Pane> {
        self.panes.iter().find(|p| p.id == id)
    }

    pub fn pane_mut(&mut self, id: PaneId) -> Option<&mut Pane> {
        self.panes.iter_mut().find(|p| p.id == id)
    }

    pub fn pane_by_kind(&self, kind: PaneKind) -> Option<&Pane> {
        self.panes.iter().find(|p| p.kind == kind)
    }

    pub fn pane_by_kind_mut(&mut self, kind: PaneKind) -> Option<&mut Pane> {
        self.panes.iter_mut().find(|p| p.kind == kind)
    }

    // min sizes are now read from pane.config.min_width / pane.config.min_height

    // -----------------------------------------------------------------------
    // Move
    // -----------------------------------------------------------------------

    /// Move a pane to a new position. Removes all snap constraints for
    /// this pane (since the user manually repositioned it).
    pub fn set_pane_position(&mut self, id: PaneId, x: f64, y: f64) {
        if let Some(p) = self.pane_mut(id) {
            p.x = x;
            p.y = y;
        }
        self.snaps.retain(|s| s.pane != id && !matches!(s.target, SnapTarget::Pane(pid, _) if pid == id));
    }

    // -----------------------------------------------------------------------
    // Resize
    // -----------------------------------------------------------------------

    /// Set a pane's size, clamped to its minimum.
    pub fn resize_pane(&mut self, id: PaneId, width: f64, height: f64) {
        if let Some(p) = self.pane_mut(id) {
            let (min_w, min_h) = (p.config.min_width, p.config.min_height);
            p.width = width.max(min_w);
            p.height = height.max(min_h);
        }
    }

    // -----------------------------------------------------------------------
    // Snap detection
    // -----------------------------------------------------------------------

    /// Return the coordinate of a pane edge.
    pub fn pane_edge_coord(pane: &Pane, edge: EdgeSide) -> f64 {
        match edge {
            EdgeSide::Left => pane.x,
            EdgeSide::Right => pane.x + pane.width,
            EdgeSide::Top => pane.y,
            EdgeSide::Bottom => pane.y + pane.height,
        }
    }

    /// Return the coordinate of a window edge.
    fn window_edge_coord(edge: EdgeSide, vw: f64, vh: f64) -> f64 {
        match edge {
            EdgeSide::Left | EdgeSide::Top => 0.0,
            EdgeSide::Right => vw,
            EdgeSide::Bottom => vh,
        }
    }

    /// True if two edges are parallel and on opposite sides (can snap together).
    fn edges_can_snap(a: EdgeSide, b: EdgeSide) -> bool {
        matches!(
            (a, b),
            (EdgeSide::Right, EdgeSide::Left)
            | (EdgeSide::Left, EdgeSide::Right)
            | (EdgeSide::Bottom, EdgeSide::Top)
            | (EdgeSide::Top, EdgeSide::Bottom)
        )
    }

    /// Detect potential snap constraints for a pane at its current position.
    /// Returns constraints that would form if released now.
    pub fn detect_snaps(
        &self,
        dragged: PaneId,
        viewport_w: f64,
        viewport_h: f64,
    ) -> Vec<SnapConstraint> {
        let dp = match self.pane(dragged) {
            Some(p) => p.clone(),
            None => return vec![],
        };
        let mut result = Vec::new();

        // Check against window edges
        for &edge in &[EdgeSide::Left, EdgeSide::Right, EdgeSide::Top, EdgeSide::Bottom] {
            let coord = Self::pane_edge_coord(&dp, edge);
            let window_coord = Self::window_edge_coord(edge, viewport_w, viewport_h);
            if (coord - window_coord).abs() <= SNAP_DISTANCE {
                result.push(SnapConstraint {
                    pane: dragged,
                    edge,
                    target: SnapTarget::Window(edge),
                });
            }
        }

        // Check against other panes
        for other in &self.panes {
            if other.id == dragged {
                continue;
            }
            // Check if the panes overlap on the perpendicular axis (so the snap is meaningful)
            for &d_edge in &[EdgeSide::Left, EdgeSide::Right, EdgeSide::Top, EdgeSide::Bottom] {
                for &o_edge in &[EdgeSide::Left, EdgeSide::Right, EdgeSide::Top, EdgeSide::Bottom] {
                    if !Self::edges_can_snap(d_edge, o_edge) {
                        continue;
                    }
                    let d_coord = Self::pane_edge_coord(&dp, d_edge);
                    let o_coord = Self::pane_edge_coord(other, o_edge);
                    if (d_coord - o_coord).abs() <= SNAP_DISTANCE {
                        // Check perpendicular overlap
                        let overlaps = match d_edge {
                            EdgeSide::Left | EdgeSide::Right => {
                                dp.y < other.y + other.height && dp.y + dp.height > other.y
                            }
                            EdgeSide::Top | EdgeSide::Bottom => {
                                dp.x < other.x + other.width && dp.x + dp.width > other.x
                            }
                        };
                        if overlaps {
                            // Normalize pane-to-pane snaps to canonical
                            // Right->Left / Bottom->Top so that
                            // shared_border_at and drag_shared_border
                            // always find them.
                            let (norm_pane, norm_edge, norm_other, norm_oedge) =
                                if d_edge == EdgeSide::Right || d_edge == EdgeSide::Bottom {
                                    (dragged, d_edge, other.id, o_edge)
                                } else {
                                    // Flip: Left->Right becomes other.Right->dragged.Left
                                    (other.id, o_edge, dragged, d_edge)
                                };
                            result.push(SnapConstraint {
                                pane: norm_pane,
                                edge: norm_edge,
                                target: SnapTarget::Pane(norm_other, norm_oedge),
                            });
                        }
                    }
                }
            }
        }

        result
    }

    // -----------------------------------------------------------------------
    // Snap application
    // -----------------------------------------------------------------------

    /// Align a pane's position to match snap constraint targets.
    /// Handles both direct snaps (pane == pane_id) and normalized
    /// pane-to-pane snaps (pane_id appears in the target field).
    fn align_pane_impl(
        &mut self,
        pane_id: PaneId,
        snaps: &[SnapConstraint],
        viewport_w: f64,
        viewport_h: f64,
    ) {
        for snap in snaps {
            if snap.pane == pane_id {
                let target_coord = match snap.target {
                    SnapTarget::Window(we) => Self::window_edge_coord(we, viewport_w, viewport_h),
                    SnapTarget::Pane(other_id, other_edge) => {
                        match self.pane(other_id) {
                            Some(other) => Self::pane_edge_coord(other, other_edge),
                            None => continue,
                        }
                    }
                };
                if let Some(p) = self.pane_mut(pane_id) {
                    match snap.edge {
                        EdgeSide::Left => p.x = target_coord,
                        EdgeSide::Right => p.x = target_coord - p.width,
                        EdgeSide::Top => p.y = target_coord,
                        EdgeSide::Bottom => p.y = target_coord - p.height,
                    }
                }
            } else if let SnapTarget::Pane(target_pid, target_edge) = snap.target
                && target_pid == pane_id {
                    let anchor_coord = match self.pane(snap.pane) {
                        Some(other) => Self::pane_edge_coord(other, snap.edge),
                        None => continue,
                    };
                    if let Some(p) = self.pane_mut(pane_id) {
                        match target_edge {
                            EdgeSide::Left => p.x = anchor_coord,
                            EdgeSide::Right => p.x = anchor_coord - p.width,
                            EdgeSide::Top => p.y = anchor_coord,
                            EdgeSide::Bottom => p.y = anchor_coord - p.height,
                        }
                    }
                }
        }
    }

    /// Align a pane's position to match snap targets without modifying
    /// the snap list. Used for live snapping during drag.
    pub fn align_to_snaps(
        &mut self,
        pane_id: PaneId,
        snaps: &[SnapConstraint],
        viewport_w: f64,
        viewport_h: f64,
    ) {
        self.align_pane_impl(pane_id, snaps, viewport_w, viewport_h);
    }

    /// Remove old snaps for a pane and apply new ones, aligning the pane's
    /// position to match the snap targets exactly.
    pub fn apply_snaps(
        &mut self,
        pane_id: PaneId,
        new_snaps: Vec<SnapConstraint>,
        viewport_w: f64,
        viewport_h: f64,
    ) {
        self.snaps.retain(|s| s.pane != pane_id && !matches!(s.target, SnapTarget::Pane(pid, _) if pid == pane_id));
        self.align_pane_impl(pane_id, &new_snaps, viewport_w, viewport_h);
        self.snaps.extend(new_snaps);
    }

    // -----------------------------------------------------------------------
    // Shared border
    // -----------------------------------------------------------------------

    /// Find a snap constraint representing a shared border at (x, y).
    /// Returns the snap index and the orientation of the border.
    /// A "shared border" is a pane-to-pane snap where one pane's Right
    /// meets another's Left (vertical border) or Bottom meets Top
    /// (horizontal border).
    pub fn shared_border_at(
        &self,
        x: f64,
        y: f64,
        tolerance: f64,
    ) -> Option<(usize, EdgeSide)> {
        for (i, snap) in self.snaps.iter().enumerate() {
            let (other_id, other_edge) = match snap.target {
                SnapTarget::Pane(pid, oe) => (pid, oe),
                _ => continue,
            };

            // Only Right->Left or Bottom->Top borders are draggable
            let is_vertical = snap.edge == EdgeSide::Right && other_edge == EdgeSide::Left;
            let is_horizontal = snap.edge == EdgeSide::Bottom && other_edge == EdgeSide::Top;
            if !is_vertical && !is_horizontal {
                continue;
            }

            let pane_a = match self.pane(snap.pane) {
                Some(p) => p,
                None => continue,
            };
            let pane_b = match self.pane(other_id) {
                Some(p) => p,
                None => continue,
            };

            if is_vertical {
                let border_x = pane_a.x + pane_a.width;
                let min_y = pane_a.y.max(pane_b.y);
                let max_y = (pane_a.y + pane_a.height).min(pane_b.y + pane_b.height);
                if (x - border_x).abs() <= tolerance && y >= min_y && y <= max_y {
                    return Some((i, EdgeSide::Left)); // vertical border
                }
            } else {
                let border_y = pane_a.y + pane_a.height;
                let min_x = pane_a.x.max(pane_b.x);
                let max_x = (pane_a.x + pane_a.width).min(pane_b.x + pane_b.width);
                if (y - border_y).abs() <= tolerance && x >= min_x && x <= max_x {
                    return Some((i, EdgeSide::Top)); // horizontal border
                }
            }
        }
        None
    }

    /// Drag a shared border by `delta` pixels. For a vertical border (Right->Left),
    /// positive delta widens the left pane and narrows the right pane.
    /// For a horizontal border (Bottom->Top), positive delta grows the top pane
    /// and shrinks the bottom pane. Propagates changes through chained snaps.
    pub fn drag_shared_border(
        &mut self,
        snap_idx: usize,
        delta: f64,
    ) {
        let snap = match self.snaps.get(snap_idx) {
            Some(s) => *s,
            None => return,
        };
        let (other_id, _other_edge) = match snap.target {
            SnapTarget::Pane(pid, oe) => (pid, oe),
            _ => return,
        };

        // Read config for min-size and fixed-width enforcement
        let (a_min_w, a_min_h, a_fixed) = match self.pane(snap.pane) {
            Some(p) => (p.config.min_width, p.config.min_height, p.config.fixed_width),
            None => return,
        };
        let (b_min_w, b_min_h, b_fixed) = match self.pane(other_id) {
            Some(p) => (p.config.min_width, p.config.min_height, p.config.fixed_width),
            None => return,
        };

        let is_vertical = snap.edge == EdgeSide::Right;

        if is_vertical {
            let a_w = self.pane(snap.pane).unwrap().width;
            let b_x = self.pane(other_id).unwrap().x;
            let b_w = self.pane(other_id).unwrap().width;

            let max_expand = if b_fixed { 0.0 } else { b_w - b_min_w };
            let max_shrink = if a_fixed { 0.0 } else { a_w - a_min_w };
            let clamped = delta.clamp(-max_shrink, max_expand);

            if !a_fixed
                && let Some(a) = self.pane_mut(snap.pane) {
                    a.width += clamped;
                }
            if !b_fixed
                && let Some(b) = self.pane_mut(other_id) {
                    b.x = b_x + clamped;
                    b.width -= clamped;
                }
            // Propagate: shift panes snapped to B's right edge
            self.propagate_border_shift(other_id, EdgeSide::Right, true);
        } else {
            let a_h = self.pane(snap.pane).unwrap().height;
            let b_y = self.pane(other_id).unwrap().y;
            let b_h = self.pane(other_id).unwrap().height;

            let max_expand = if b_fixed { 0.0 } else { b_h - b_min_h };
            let max_shrink = if a_fixed { 0.0 } else { a_h - a_min_h };
            let clamped = delta.clamp(-max_shrink, max_expand);

            if !a_fixed
                && let Some(a) = self.pane_mut(snap.pane) {
                    a.height += clamped;
                }
            if !b_fixed
                && let Some(b) = self.pane_mut(other_id) {
                    b.y = b_y + clamped;
                    b.height -= clamped;
                }
            // Propagate: shift panes snapped to B's bottom edge
            self.propagate_border_shift(other_id, EdgeSide::Bottom, false);
        }

    }

    /// After a border drag changes pane B's position, find any panes
    /// snapped to B's far edge and shift them by the same delta.
    /// This keeps chained snaps (e.g., toolbar|canvas|dock) in sync.
    fn propagate_border_shift(
        &mut self,
        source_pane: PaneId,
        source_edge: EdgeSide,
        is_vertical: bool,
    ) {
        // Find snaps where source_pane's source_edge connects to another pane
        let chained: Vec<(PaneId, EdgeSide)> = self.snaps.iter().filter_map(|s| {
            if s.pane == source_pane && s.edge == source_edge
                && let SnapTarget::Pane(pid, pe) = s.target {
                    return Some((pid, pe));
                }
            None
        }).collect();

        // Align chained panes to the new edge position
        let edge_coord = match self.pane(source_pane) {
            Some(p) => Self::pane_edge_coord(p, source_edge),
            None => return,
        };

        for (pid, pe) in chained {
            if let Some(p) = self.pane_mut(pid) {
                if is_vertical {
                    match pe {
                        EdgeSide::Left => p.x = edge_coord,
                        EdgeSide::Right => p.x = edge_coord - p.width,
                        _ => {}
                    }
                } else {
                    match pe {
                        EdgeSide::Top => p.y = edge_coord,
                        EdgeSide::Bottom => p.y = edge_coord - p.height,
                        _ => {}
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Canvas maximization
    // -----------------------------------------------------------------------

    /// Toggle canvas maximized state.
    pub fn toggle_canvas_maximized(&mut self) {
        self.canvas_maximized = !self.canvas_maximized;
    }

    /// Tile all visible panes left-to-right, snapped together, filling
    /// the viewport. Hidden panes are skipped; their space is given to
    /// the remaining panes.
    /// `dock_collapsed_width`: if `Some(w)`, the dock is collapsed and
    /// `collapsed_override`: if `Some((pane_id, width))`, override that
    /// pane's KeepCurrent width with the given value (e.g., collapsed dock).
    pub fn tile_panes(&mut self, collapsed_override: Option<(PaneId, f64)>) {
        let vw = self.viewport_width;
        let vh = self.viewport_height;

        // Unmaximize and show all panes.
        self.canvas_maximized = false;
        self.hidden_panes.clear();

        // Sort panes by position: ascending x, tiebreak by descending y.
        let mut visible: Vec<(PaneId, f64, f64)> = self.panes.iter()
            .map(|p| (p.id, p.x, p.y))
            .collect();
        visible.sort_by(|a, b| {
            a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal)
                .then(b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal))
        });
        if visible.is_empty() {
            return;
        }

        // Derive tile width from config and compute widths.
        let mut fixed_total = 0.0;
        let mut flex_count = 0;
        let tile_widths: Vec<TileWidth> = visible.iter().map(|&(id, _, _)| {
            if let Some((oid, cw)) = collapsed_override
                && oid == id { return TileWidth::Fixed(cw); }
            match self.pane(id) {
                Some(p) if p.config.fixed_width => TileWidth::Fixed(p.width),
                Some(p) if p.config.collapsed_width.is_some() => TileWidth::KeepCurrent(p.width),
                _ => TileWidth::Flex,
            }
        }).collect();
        let widths: Vec<f64> = tile_widths.iter().map(|tw| {
            match *tw {
                TileWidth::Fixed(w) => { fixed_total += w; w }
                TileWidth::KeepCurrent(w) => { fixed_total += w; w }
                TileWidth::Flex => { flex_count += 1; 0.0 }
            }
        }).collect();
        let flex_each = if flex_count > 0 {
            let min_flex = visible.iter().zip(&tile_widths)
                .filter(|(_, tw)| matches!(tw, TileWidth::Flex))
                .filter_map(|(&(id, _, _), _)| self.pane(id).map(|p| p.config.min_width))
                .fold(0.0_f64, f64::max);
            ((vw - fixed_total) / flex_count as f64).max(min_flex)
        } else {
            0.0
        };
        let widths: Vec<f64> = tile_widths.iter().zip(&widths).map(|(tw, &w)| {
            if matches!(tw, TileWidth::Flex) { flex_each } else { w }
        }).collect();

        // Assign positions to panes
        let mut x = 0.0;
        for (i, &(id, _, _)) in visible.iter().enumerate() {
            let w = widths[i];
            if let Some(p) = self.pane_mut(id) {
                p.x = x;
                p.y = 0.0;
                p.width = w;
                p.height = vh;
            }
            x += w;
        }

        // Rebuild all snap constraints
        self.snaps.clear();
        for (i, &(id, ..)) in visible.iter().enumerate() {
            // Left edge: first pane snaps to window left
            if i == 0 {
                self.snaps.push(SnapConstraint { pane: id, edge: EdgeSide::Left, target: SnapTarget::Window(EdgeSide::Left) });
            }
            // Right edge: last pane snaps to window right
            if i == visible.len() - 1 {
                self.snaps.push(SnapConstraint { pane: id, edge: EdgeSide::Right, target: SnapTarget::Window(EdgeSide::Right) });
            }
            // Top/bottom snap to window
            self.snaps.push(SnapConstraint { pane: id, edge: EdgeSide::Top, target: SnapTarget::Window(EdgeSide::Top) });
            self.snaps.push(SnapConstraint { pane: id, edge: EdgeSide::Bottom, target: SnapTarget::Window(EdgeSide::Bottom) });
            // Pane-to-pane snap to next visible pane
            if i + 1 < visible.len() {
                let next_id = visible[i + 1].0;
                self.snaps.push(SnapConstraint { pane: id, edge: EdgeSide::Right, target: SnapTarget::Pane(next_id, EdgeSide::Left) });
            }
        }
    }

    // -----------------------------------------------------------------------
    // Pane visibility
    // -----------------------------------------------------------------------

    /// Hide a pane (close it). If the pane is maximized, unmaximize first.
    pub fn hide_pane(&mut self, kind: PaneKind) {
        if self.canvas_maximized
            && let Some(p) = self.pane_by_kind(kind)
                && p.config.double_click_action == DoubleClickAction::Maximize {
                    self.canvas_maximized = false;
                }
        if !self.hidden_panes.contains(&kind) {
            self.hidden_panes.push(kind);
        }
    }

    /// Show a hidden pane and bring it to the front.
    pub fn show_pane(&mut self, kind: PaneKind) {
        self.hidden_panes.retain(|&k| k != kind);
        if let Some(p) = self.pane_by_kind(kind) {
            let id = p.id;
            self.bring_pane_to_front(id);
        }
    }

    /// Whether a pane kind is currently visible.
    pub fn is_pane_visible(&self, kind: PaneKind) -> bool {
        !self.hidden_panes.contains(&kind)
    }

    // pane labels are now read from pane.config.label

    // -----------------------------------------------------------------------
    // Z-order
    // -----------------------------------------------------------------------

    /// Bring a pane to the front of the z-order.
    pub fn bring_pane_to_front(&mut self, id: PaneId) {
        if let Some(pos) = self.z_order.iter().position(|&zid| zid == id) {
            self.z_order.remove(pos);
            self.z_order.push(id);
        }
    }

    /// Return the z-index position for a pane (0 = back).
    pub fn pane_z_index(&self, id: PaneId) -> usize {
        self.z_order.iter().position(|&zid| zid == id).unwrap_or(0)
    }

    // -----------------------------------------------------------------------
    // Viewport resize
    // -----------------------------------------------------------------------

    /// Proportionally rescale all panes when the viewport changes size.
    pub fn on_viewport_resize(&mut self, new_w: f64, new_h: f64) {
        if self.viewport_width <= 0.0 || self.viewport_height <= 0.0 {
            self.viewport_width = new_w;
            self.viewport_height = new_h;
            return;
        }
        let sx = new_w / self.viewport_width;
        let sy = new_h / self.viewport_height;
        for p in &mut self.panes {
            let (min_w, min_h) = (p.config.min_width, p.config.min_height);
            p.x *= sx;
            p.y *= sy;
            if !p.config.fixed_width {
                p.width = (p.width * sx).max(min_w);
            }
            p.height = (p.height * sy).max(min_h);
        }
        self.viewport_width = new_w;
        self.viewport_height = new_h;
        self.clamp_panes(new_w, new_h);
    }

    // -----------------------------------------------------------------------
    // Clamping
    // -----------------------------------------------------------------------

    /// Ensure every pane has at least MIN_PANE_VISIBLE pixels within the viewport.
    pub fn clamp_panes(&mut self, viewport_w: f64, viewport_h: f64) {
        for p in &mut self.panes {
            p.x = p.x.clamp(-p.width + MIN_PANE_VISIBLE, viewport_w - MIN_PANE_VISIBLE);
            p.y = p.y.clamp(-p.height + MIN_PANE_VISIBLE, viewport_h - MIN_PANE_VISIBLE);
        }
    }

    /// Re-establish snap constraints between panes whose edges are touching
    /// but have no existing snap. Also snaps pane edges touching window edges.
    /// Call on load to repair layouts saved with missing snaps.
    pub fn repair_snaps(&mut self, viewport_w: f64, viewport_h: f64) {
        let tolerance = SNAP_DISTANCE;
        let pane_copies: Vec<Pane> = self.panes.clone();

        for a in &pane_copies {
            // Check against window edges
            for &edge in &[EdgeSide::Left, EdgeSide::Right, EdgeSide::Top, EdgeSide::Bottom] {
                let coord = Self::pane_edge_coord(a, edge);
                let win_coord = Self::window_edge_coord(edge, viewport_w, viewport_h);
                if (coord - win_coord).abs() <= tolerance {
                    let exists = self.snaps.iter().any(|s|
                        s.pane == a.id && s.edge == edge && s.target == SnapTarget::Window(edge)
                    );
                    if !exists {
                        self.snaps.push(SnapConstraint {
                            pane: a.id,
                            edge,
                            target: SnapTarget::Window(edge),
                        });
                    }
                }
            }

            // Check against other panes (canonical Right->Left / Bottom->Top)
            for b in &pane_copies {
                if a.id == b.id { continue; }

                // Vertical: a.Right near b.Left
                if (Self::pane_edge_coord(a, EdgeSide::Right) - Self::pane_edge_coord(b, EdgeSide::Left)).abs() <= tolerance {
                    // Check perpendicular overlap
                    if a.y < b.y + b.height && a.y + a.height > b.y {
                        let exists = self.snaps.iter().any(|s|
                            s.pane == a.id && s.edge == EdgeSide::Right
                            && s.target == SnapTarget::Pane(b.id, EdgeSide::Left)
                        );
                        if !exists {
                            self.snaps.push(SnapConstraint {
                                pane: a.id,
                                edge: EdgeSide::Right,
                                target: SnapTarget::Pane(b.id, EdgeSide::Left),
                            });
                        }
                    }
                }

                // Horizontal: a.Bottom near b.Top
                if (Self::pane_edge_coord(a, EdgeSide::Bottom) - Self::pane_edge_coord(b, EdgeSide::Top)).abs() <= tolerance
                    && a.x < b.x + b.width && a.x + a.width > b.x {
                        let exists = self.snaps.iter().any(|s|
                            s.pane == a.id && s.edge == EdgeSide::Bottom
                            && s.target == SnapTarget::Pane(b.id, EdgeSide::Top)
                        );
                        if !exists {
                            self.snaps.push(SnapConstraint {
                                pane: a.id,
                                edge: EdgeSide::Bottom,
                                target: SnapTarget::Pane(b.id, EdgeSide::Top),
                            });
                        }
                    }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -----------------------------------------------------------------------
    // PaneLayout
    // -----------------------------------------------------------------------

    #[test]
    fn default_three_pane_fills_viewport() {
        let pl = PaneLayout::default_three_pane(1000.0, 700.0);
        assert_eq!(pl.panes.len(), 3);
        // Toolbar starts at x=0, canvas follows, dock ends at viewport width
        let toolbar = pl.pane_by_kind(PaneKind::Toolbar).unwrap();
        let canvas = pl.pane_by_kind(PaneKind::Canvas).unwrap();
        let dock = pl.pane_by_kind(PaneKind::Dock).unwrap();
        assert_eq!(toolbar.x, 0.0);
        assert_eq!(toolbar.width, DEFAULT_TOOLBAR_WIDTH);
        assert_eq!(canvas.x, toolbar.x + toolbar.width);
        assert_eq!(dock.x, canvas.x + canvas.width);
        // Widths sum to viewport width
        let total = toolbar.width + canvas.width + dock.width;
        assert!((total - 1000.0).abs() < 0.001);
        // All full height
        assert_eq!(toolbar.height, 700.0);
        assert_eq!(canvas.height, 700.0);
        assert_eq!(dock.height, 700.0);
    }

    #[test]
    fn default_three_pane_snap_count() {
        let pl = PaneLayout::default_three_pane(1000.0, 700.0);
        // 10 snaps: toolbar(4) + canvas(2 to window + 1 to dock) + dock(3)
        assert_eq!(pl.snaps.len(), 10);
    }

    #[test]
    fn pane_lookup_by_id() {
        let pl = PaneLayout::default_three_pane(1000.0, 700.0);
        assert!(pl.pane(PaneId(0)).is_some());
        assert!(pl.pane(PaneId(1)).is_some());
        assert!(pl.pane(PaneId(2)).is_some());
    }

    #[test]
    fn pane_lookup_by_kind() {
        let pl = PaneLayout::default_three_pane(1000.0, 700.0);
        assert_eq!(pl.pane_by_kind(PaneKind::Toolbar).unwrap().kind, PaneKind::Toolbar);
        assert_eq!(pl.pane_by_kind(PaneKind::Canvas).unwrap().kind, PaneKind::Canvas);
        assert_eq!(pl.pane_by_kind(PaneKind::Dock).unwrap().kind, PaneKind::Dock);
    }

    #[test]
    fn pane_lookup_invalid_id() {
        let pl = PaneLayout::default_three_pane(1000.0, 700.0);
        assert!(pl.pane(PaneId(99)).is_none());
    }

    #[test]
    fn set_pane_position_moves_pane() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        pl.set_pane_position(id, 100.0, 50.0);
        let p = pl.pane(id).unwrap();
        assert_eq!(p.x, 100.0);
        assert_eq!(p.y, 50.0);
    }

    #[test]
    fn set_pane_position_clears_snaps() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let canvas_id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        let snaps_before = pl.snaps.len();
        assert!(snaps_before > 0);
        pl.set_pane_position(canvas_id, 200.0, 200.0);
        // All snaps involving canvas should be gone
        let has_canvas_snap = pl.snaps.iter().any(|s| {
            s.pane == canvas_id || matches!(s.target, SnapTarget::Pane(pid, _) if pid == canvas_id)
        });
        assert!(!has_canvas_snap);
        assert!(pl.snaps.len() < snaps_before);
    }

    #[test]
    fn resize_pane_clamps_min_toolbar() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let id = pl.pane_by_kind(PaneKind::Toolbar).unwrap().id;
        pl.resize_pane(id, 10.0, 10.0);
        let p = pl.pane(id).unwrap();
        assert_eq!(p.width, MIN_TOOLBAR_WIDTH);
        assert_eq!(p.height, MIN_TOOLBAR_HEIGHT);
    }

    #[test]
    fn resize_pane_clamps_min_canvas() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        pl.resize_pane(id, 10.0, 10.0);
        let p = pl.pane(id).unwrap();
        assert_eq!(p.width, MIN_CANVAS_WIDTH);
        assert_eq!(p.height, MIN_CANVAS_HEIGHT);
    }

    #[test]
    fn resize_pane_clamps_min_dock() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let id = pl.pane_by_kind(PaneKind::Dock).unwrap().id;
        pl.resize_pane(id, 10.0, 10.0);
        let p = pl.pane(id).unwrap();
        assert_eq!(p.width, MIN_PANE_DOCK_WIDTH);
        assert_eq!(p.height, MIN_PANE_DOCK_HEIGHT);
    }

    #[test]
    fn resize_pane_accepts_large_values() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        pl.resize_pane(id, 800.0, 600.0);
        let p = pl.pane(id).unwrap();
        assert_eq!(p.width, 800.0);
        assert_eq!(p.height, 600.0);
    }

    #[test]
    fn detect_snaps_near_window_edge() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let canvas_id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        // Move canvas to near the left window edge
        pl.set_pane_position(canvas_id, 5.0, 0.0);
        let snaps = pl.detect_snaps(canvas_id, 1000.0, 700.0);
        // Should detect left edge snap to window
        assert!(snaps.iter().any(|s|
            s.pane == canvas_id
            && s.edge == EdgeSide::Left
            && s.target == SnapTarget::Window(EdgeSide::Left)
        ));
    }

    #[test]
    fn detect_snaps_near_other_pane() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let canvas_id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        let toolbar = pl.pane_by_kind(PaneKind::Toolbar).unwrap();
        let toolbar_right = toolbar.x + toolbar.width;
        let toolbar_id = toolbar.id;
        // Move canvas so its left edge is near toolbar's right edge
        pl.set_pane_position(canvas_id, toolbar_right + 5.0, 0.0);
        let snaps = pl.detect_snaps(canvas_id, 1000.0, 700.0);
        // Normalized: toolbar.Right -> canvas.Left (canonical Right->Left form)
        assert!(snaps.iter().any(|s|
            s.pane == toolbar_id
            && s.edge == EdgeSide::Right
            && s.target == SnapTarget::Pane(canvas_id, EdgeSide::Left)
        ));
    }

    #[test]
    fn detect_snaps_no_match() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let canvas_id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        // Move canvas far from everything
        pl.set_pane_position(canvas_id, 400.0, 300.0);
        pl.resize_pane(canvas_id, 200.0, 200.0);
        let snaps = pl.detect_snaps(canvas_id, 1000.0, 700.0);
        // Should not snap to any window edges or panes
        assert!(snaps.is_empty());
    }

    #[test]
    fn apply_snaps_aligns_position() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let canvas_id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        // Move canvas slightly off from left window edge
        pl.set_pane_position(canvas_id, 5.0, 3.0);
        let new_snaps = vec![
            SnapConstraint { pane: canvas_id, edge: EdgeSide::Left, target: SnapTarget::Window(EdgeSide::Left) },
            SnapConstraint { pane: canvas_id, edge: EdgeSide::Top, target: SnapTarget::Window(EdgeSide::Top) },
        ];
        pl.apply_snaps(canvas_id, new_snaps, 1000.0, 700.0);
        let p = pl.pane(canvas_id).unwrap();
        assert_eq!(p.x, 0.0); // aligned to left
        assert_eq!(p.y, 0.0); // aligned to top
    }

    #[test]
    fn apply_snaps_aligns_via_normalized_pane_snap() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let canvas_id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        let toolbar_id = pl.pane_by_kind(PaneKind::Toolbar).unwrap().id;
        // Move canvas slightly away from toolbar
        pl.set_pane_position(canvas_id, 80.0, 0.0);
        // Normalized snap: toolbar.Right -> canvas.Left (canvas is in target)
        let new_snaps = vec![
            SnapConstraint { pane: toolbar_id, edge: EdgeSide::Right, target: SnapTarget::Pane(canvas_id, EdgeSide::Left) },
        ];
        pl.apply_snaps(canvas_id, new_snaps, 1000.0, 700.0);
        let p = pl.pane(canvas_id).unwrap();
        // Canvas left edge should align to toolbar's right edge (72px)
        assert!((p.x - 72.0).abs() < 0.001);
    }

    #[test]
    fn drag_canvas_snap_to_toolbar_full_workflow() {
        // Simulate: drag canvas away, then drag it back near toolbar
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let canvas_id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        let toolbar_id = pl.pane_by_kind(PaneKind::Toolbar).unwrap().id;

        // 1. Drag canvas away (clears snaps)
        pl.set_pane_position(canvas_id, 300.0, 100.0);
        assert!(pl.snaps.iter().all(|s| {
            s.pane != canvas_id && !matches!(s.target, SnapTarget::Pane(pid, _) if pid == canvas_id)
        }));

        // 2. Drag canvas back near toolbar's right edge
        pl.set_pane_position(canvas_id, 77.0, 0.0);

        // 3. Detect snaps
        let snaps = pl.detect_snaps(canvas_id, 1000.0, 700.0);
        // Should find toolbar.Right -> canvas.Left (normalized)
        let toolbar_snap = snaps.iter().find(|s|
            s.edge == EdgeSide::Right
            && matches!(s.target, SnapTarget::Pane(pid, EdgeSide::Left) if pid == canvas_id)
        );
        assert!(toolbar_snap.is_some(), "Expected toolbar-canvas snap, got: {:?}", snaps);

        // 4. Apply snaps
        pl.apply_snaps(canvas_id, snaps, 1000.0, 700.0);

        // 5. Canvas should be aligned to toolbar's right edge
        let canvas = pl.pane(canvas_id).unwrap();
        assert!((canvas.x - 72.0).abs() < 0.001, "canvas.x = {}", canvas.x);

        // 6. Shared border should be findable
        let border = pl.shared_border_at(72.0, 350.0, BORDER_HIT_TOLERANCE);
        assert!(border.is_some(), "Shared border not found after re-snap");
    }

    #[test]
    fn apply_snaps_replaces_old() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let canvas_id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        let old_count = pl.snaps.len();
        // Apply a single new snap
        let new_snaps = vec![
            SnapConstraint { pane: canvas_id, edge: EdgeSide::Left, target: SnapTarget::Window(EdgeSide::Left) },
        ];
        pl.apply_snaps(canvas_id, new_snaps, 1000.0, 700.0);
        // Old canvas snaps removed, one new added. Should be fewer total.
        assert!(pl.snaps.len() < old_count);
        // The new snap is present
        assert!(pl.snaps.iter().any(|s|
            s.pane == canvas_id && s.edge == EdgeSide::Left
        ));
    }

    #[test]
    fn shared_border_at_vertical() {
        let pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let toolbar = pl.pane_by_kind(PaneKind::Toolbar).unwrap();
        let border_x = toolbar.x + toolbar.width;
        // Hit the vertical border between toolbar and canvas
        let result = pl.shared_border_at(border_x, 350.0, BORDER_HIT_TOLERANCE);
        assert!(result.is_some());
        let (_, orientation) = result.unwrap();
        assert_eq!(orientation, EdgeSide::Left); // vertical border
    }

    #[test]
    fn shared_border_at_miss() {
        let pl = PaneLayout::default_three_pane(1000.0, 700.0);
        // Click in the middle of the canvas (far from any border)
        let result = pl.shared_border_at(500.0, 350.0, BORDER_HIT_TOLERANCE);
        assert!(result.is_none());
    }

    #[test]
    fn drag_shared_border_widens_left_narrows_right() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        // Use canvas/dock border (toolbar is fixed width)
        let canvas = pl.pane_by_kind(PaneKind::Canvas).unwrap();
        let border_x = canvas.x + canvas.width;
        let (snap_idx, _) = pl.shared_border_at(border_x, 350.0, BORDER_HIT_TOLERANCE).unwrap();

        let canvas_w_before = pl.pane_by_kind(PaneKind::Canvas).unwrap().width;
        let dock_w_before = pl.pane_by_kind(PaneKind::Dock).unwrap().width;
        let dock_x_before = pl.pane_by_kind(PaneKind::Dock).unwrap().x;

        pl.drag_shared_border(snap_idx, 30.0);

        let canvas_w_after = pl.pane_by_kind(PaneKind::Canvas).unwrap().width;
        let dock_w_after = pl.pane_by_kind(PaneKind::Dock).unwrap().width;
        let dock_x_after = pl.pane_by_kind(PaneKind::Dock).unwrap().x;

        assert!((canvas_w_after - (canvas_w_before + 30.0)).abs() < 0.001);
        assert!((dock_w_after - (dock_w_before - 30.0)).abs() < 0.001);
        assert!((dock_x_after - (dock_x_before + 30.0)).abs() < 0.001);
    }

    #[test]
    fn drag_shared_border_toolbar_is_fixed() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let toolbar = pl.pane_by_kind(PaneKind::Toolbar).unwrap();
        let border_x = toolbar.x + toolbar.width;
        // Toolbar/canvas border exists but toolbar is fixed
        let result = pl.shared_border_at(border_x, 350.0, BORDER_HIT_TOLERANCE);
        assert!(result.is_some()); // snap exists
        let (snap_idx, _) = result.unwrap();
        let toolbar_w_before = pl.pane_by_kind(PaneKind::Toolbar).unwrap().width;
        pl.drag_shared_border(snap_idx, 30.0);
        let toolbar_w_after = pl.pane_by_kind(PaneKind::Toolbar).unwrap().width;
        // Toolbar width unchanged
        assert!((toolbar_w_after - toolbar_w_before).abs() < 0.001);
    }

    #[test]
    fn drag_shared_border_respects_min_size() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let toolbar = pl.pane_by_kind(PaneKind::Toolbar).unwrap();
        let border_x = toolbar.x + toolbar.width;
        let (snap_idx, _) = pl.shared_border_at(border_x, 350.0, BORDER_HIT_TOLERANCE).unwrap();

        // Try to shrink toolbar below min width (drag left by a huge amount)
        pl.drag_shared_border(snap_idx, -5000.0);

        let toolbar = pl.pane_by_kind(PaneKind::Toolbar).unwrap();
        assert!(toolbar.width >= MIN_TOOLBAR_WIDTH);
    }

    #[test]
    fn drag_shared_border_propagates_to_chained_pane() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let toolbar = pl.pane_by_kind(PaneKind::Toolbar).unwrap();
        let border_x = toolbar.x + toolbar.width;
        let (snap_idx, _) = pl.shared_border_at(border_x, 350.0, BORDER_HIT_TOLERANCE).unwrap();

        let dock_x_before = pl.pane_by_kind(PaneKind::Dock).unwrap().x;

        // Drag toolbar/canvas border right by 30px
        pl.drag_shared_border(snap_idx, 30.0);

        // Canvas shrinks and shifts right, dock should also shift right
        let canvas = pl.pane_by_kind(PaneKind::Canvas).unwrap();
        let dock = pl.pane_by_kind(PaneKind::Dock).unwrap();
        // Canvas right edge should still meet dock left edge
        assert!((canvas.x + canvas.width - dock.x).abs() < 0.001,
            "canvas right ({}) != dock left ({})", canvas.x + canvas.width, dock.x);
    }

    #[test]
    fn bring_pane_to_front() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let toolbar_id = pl.pane_by_kind(PaneKind::Toolbar).unwrap().id;
        let dock_id = pl.pane_by_kind(PaneKind::Dock).unwrap().id;
        // Dock is last in z_order by default
        assert_eq!(*pl.z_order.last().unwrap(), dock_id);
        // Bring toolbar to front
        pl.bring_pane_to_front(toolbar_id);
        assert_eq!(*pl.z_order.last().unwrap(), toolbar_id);
    }

    #[test]
    fn pane_z_index_ordering() {
        let pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let canvas_id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        let toolbar_id = pl.pane_by_kind(PaneKind::Toolbar).unwrap().id;
        let dock_id = pl.pane_by_kind(PaneKind::Dock).unwrap().id;
        // Default order: canvas(back), toolbar, dock(front)
        assert!(pl.pane_z_index(canvas_id) < pl.pane_z_index(toolbar_id));
        assert!(pl.pane_z_index(toolbar_id) < pl.pane_z_index(dock_id));
    }

    #[test]
    fn on_viewport_resize_proportional() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let canvas_w_before = pl.pane_by_kind(PaneKind::Canvas).unwrap().width;
        // Double the viewport width
        pl.on_viewport_resize(2000.0, 700.0);
        let canvas_w_after = pl.pane_by_kind(PaneKind::Canvas).unwrap().width;
        // Canvas should roughly double in width
        assert!((canvas_w_after - canvas_w_before * 2.0).abs() < 1.0);
    }

    #[test]
    fn on_viewport_resize_clamps_min() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        // Shrink to very small viewport
        pl.on_viewport_resize(100.0, 100.0);
        // All panes should still meet minimum sizes
        for p in &pl.panes {
            let (min_w, min_h) = (p.config.min_width, p.config.min_height);
            assert!(p.width >= min_w);
            assert!(p.height >= min_h);
        }
    }

    #[test]
    fn clamp_panes_offscreen() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        // Push canvas way off screen
        pl.set_pane_position(id, 5000.0, 5000.0);
        pl.clamp_panes(1000.0, 700.0);
        let p = pl.pane(id).unwrap();
        // Should be clamped so at least 50px is visible
        assert!(p.x <= 1000.0 - MIN_PANE_VISIBLE);
        assert!(p.y <= 700.0 - MIN_PANE_VISIBLE);
    }

    #[test]
    fn pane_config_defaults() {
        let tc = PaneConfig::for_kind(PaneKind::Toolbar);
        assert_eq!(tc.min_width, MIN_TOOLBAR_WIDTH);
        assert!(tc.fixed_width);
        assert_eq!(tc.double_click_action, DoubleClickAction::None);

        let cc = PaneConfig::for_kind(PaneKind::Canvas);
        assert_eq!(cc.min_width, MIN_CANVAS_WIDTH);
        assert!(!cc.fixed_width);
        assert_eq!(cc.double_click_action, DoubleClickAction::Maximize);

        let dc = PaneConfig::for_kind(PaneKind::Dock);
        assert_eq!(dc.min_width, MIN_PANE_DOCK_WIDTH);
        assert!(!dc.fixed_width);
        assert_eq!(dc.double_click_action, DoubleClickAction::Redock);

        // collapsed_width drives collapsibility
        assert!(tc.collapsed_width.is_none());
        assert!(cc.collapsed_width.is_none());
        assert_eq!(dc.collapsed_width, Some(36.0));
    }


    // -----------------------------------------------------------------------
    // tile_panes
    // -----------------------------------------------------------------------

    #[test]
    fn tile_panes_fills_viewport() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        pl.tile_panes(None);
        let t = pl.pane_by_kind(PaneKind::Toolbar).unwrap();
        let c = pl.pane_by_kind(PaneKind::Canvas).unwrap();
        let d = pl.pane_by_kind(PaneKind::Dock).unwrap();
        // Positions are left-to-right
        assert_eq!(t.x, 0.0);
        assert_eq!(c.x, t.x + t.width);
        assert_eq!(d.x, c.x + c.width);
        // Widths sum to viewport
        assert!((t.width + c.width + d.width - 1000.0).abs() < 0.001);
        // All full height
        assert_eq!(t.height, 700.0);
        assert_eq!(c.height, 700.0);
        assert_eq!(d.height, 700.0);
        // Toolbar keeps default width
        assert_eq!(t.width, DEFAULT_TOOLBAR_WIDTH);
    }

    #[test]
    fn tile_panes_collapsed_dock() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let dock_id = pl.pane_by_kind(PaneKind::Dock).unwrap().id;
        pl.tile_panes(Some((dock_id, 36.0)));
        let d = pl.pane_by_kind(PaneKind::Dock).unwrap();
        let c = pl.pane_by_kind(PaneKind::Canvas).unwrap();
        assert_eq!(d.width, 36.0);
        // Canvas fills the rest
        assert!((c.width - (1000.0 - DEFAULT_TOOLBAR_WIDTH - 36.0)).abs() < 0.001);
        // Dock right edge at viewport
        assert!((d.x + d.width - 1000.0).abs() < 0.001);
    }

    #[test]
    fn tile_panes_clears_hidden() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        pl.hide_pane(PaneKind::Toolbar);
        pl.hide_pane(PaneKind::Dock);
        assert_eq!(pl.hidden_panes.len(), 2);
        pl.tile_panes(None);
        assert!(pl.hidden_panes.is_empty());
    }

    #[test]
    fn tile_panes_rebuilds_snaps() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        pl.snaps.clear();
        pl.tile_panes(None);
        // Should have pane-to-pane + window snaps
        assert!(!pl.snaps.is_empty());
        // Toolbar-canvas pane snap
        let toolbar_id = pl.pane_by_kind(PaneKind::Toolbar).unwrap().id;
        let canvas_id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        assert!(pl.snaps.iter().any(|s|
            s.pane == toolbar_id && s.edge == EdgeSide::Right
            && s.target == SnapTarget::Pane(canvas_id, EdgeSide::Left)
        ));
    }

    // -----------------------------------------------------------------------
    // hide_pane / show_pane / is_pane_visible
    // -----------------------------------------------------------------------

    #[test]
    fn hide_show_pane_round_trip() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        assert!(pl.is_pane_visible(PaneKind::Toolbar));
        pl.hide_pane(PaneKind::Toolbar);
        assert!(!pl.is_pane_visible(PaneKind::Toolbar));
        pl.show_pane(PaneKind::Toolbar);
        assert!(pl.is_pane_visible(PaneKind::Toolbar));
    }

    #[test]
    fn hide_pane_idempotent() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        pl.hide_pane(PaneKind::Dock);
        pl.hide_pane(PaneKind::Dock);
        assert_eq!(pl.hidden_panes.len(), 1);
    }

    #[test]
    fn show_pane_not_hidden_is_noop() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let count_before = pl.hidden_panes.len();
        pl.show_pane(PaneKind::Canvas);
        assert_eq!(pl.hidden_panes.len(), count_before);
    }

    // -----------------------------------------------------------------------
    // toggle_canvas_maximized
    // -----------------------------------------------------------------------

    #[test]
    fn toggle_canvas_maximized() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        assert!(!pl.canvas_maximized);
        pl.toggle_canvas_maximized();
        assert!(pl.canvas_maximized);
        pl.toggle_canvas_maximized();
        assert!(!pl.canvas_maximized);
    }

    // -----------------------------------------------------------------------
    // align_to_snaps
    // -----------------------------------------------------------------------

    #[test]
    fn align_to_snaps_does_not_modify_snap_list() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let canvas_id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        let toolbar_id = pl.pane_by_kind(PaneKind::Toolbar).unwrap().id;
        pl.set_pane_position(canvas_id, 80.0, 5.0);
        let snaps_before = pl.snaps.len();
        let new_snaps = vec![
            SnapConstraint { pane: toolbar_id, edge: EdgeSide::Right, target: SnapTarget::Pane(canvas_id, EdgeSide::Left) },
            SnapConstraint { pane: canvas_id, edge: EdgeSide::Top, target: SnapTarget::Window(EdgeSide::Top) },
        ];
        pl.align_to_snaps(canvas_id, &new_snaps, 1000.0, 700.0);
        // Snap list unchanged
        assert_eq!(pl.snaps.len(), snaps_before);
        // But pane position aligned
        let p = pl.pane(canvas_id).unwrap();
        assert!((p.x - 72.0).abs() < 0.001);
        assert_eq!(p.y, 0.0);
    }

    // -----------------------------------------------------------------------
    // repair_snaps
    // -----------------------------------------------------------------------

    #[test]
    fn repair_snaps_adds_missing() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        pl.snaps.clear();
        pl.repair_snaps(1000.0, 700.0);
        // Should have re-established toolbar-canvas and canvas-dock snaps
        let toolbar_id = pl.pane_by_kind(PaneKind::Toolbar).unwrap().id;
        let canvas_id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        assert!(pl.snaps.iter().any(|s|
            s.pane == toolbar_id && s.edge == EdgeSide::Right
            && s.target == SnapTarget::Pane(canvas_id, EdgeSide::Left)
        ));
    }

    #[test]
    fn repair_snaps_no_duplicates() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let count_before = pl.snaps.len();
        pl.repair_snaps(1000.0, 700.0);
        // Should not add duplicates
        assert_eq!(pl.snaps.len(), count_before);
    }

    // -----------------------------------------------------------------------
    // show_pane brings to front
    // -----------------------------------------------------------------------

    #[test]
    fn show_pane_brings_to_front() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let toolbar_id = pl.pane_by_kind(PaneKind::Toolbar).unwrap().id;
        pl.hide_pane(PaneKind::Toolbar);
        pl.show_pane(PaneKind::Toolbar);
        assert_eq!(*pl.z_order.last().unwrap(), toolbar_id);
    }

    // -----------------------------------------------------------------------
    // hide_pane unmaximizes
    // -----------------------------------------------------------------------

    #[test]
    fn hide_maximized_pane_unmaximizes() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        pl.toggle_canvas_maximized();
        assert!(pl.canvas_maximized);
        pl.hide_pane(PaneKind::Canvas);
        assert!(!pl.canvas_maximized);
    }

    #[test]
    fn hide_non_maximizable_pane_preserves_maximized() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        pl.toggle_canvas_maximized();
        assert!(pl.canvas_maximized);
        pl.hide_pane(PaneKind::Toolbar);
        assert!(pl.canvas_maximized);
    }

    // -----------------------------------------------------------------------
    // fixed-width border drag resizes non-fixed pane
    // -----------------------------------------------------------------------

    #[test]
    fn drag_shared_border_fixed_width_resizes_canvas() {
        let mut pl = PaneLayout::default_three_pane(1000.0, 700.0);
        let toolbar_id = pl.pane_by_kind(PaneKind::Toolbar).unwrap().id;
        let canvas_id = pl.pane_by_kind(PaneKind::Canvas).unwrap().id;
        let canvas_w_before = pl.pane(canvas_id).unwrap().width;
        let toolbar_w_before = pl.pane(toolbar_id).unwrap().width;
        let snap_idx = pl.snaps.iter().position(|s|
            s.pane == toolbar_id && s.edge == EdgeSide::Right
            && s.target == SnapTarget::Pane(canvas_id, EdgeSide::Left)
        ).expect("toolbar-canvas snap should exist");
        // Drag the border right (toolbar is fixed-width, canvas is not)
        pl.drag_shared_border(snap_idx, 30.0);
        // Toolbar width unchanged (fixed), canvas narrowed
        assert_eq!(pl.pane(toolbar_id).unwrap().width, toolbar_w_before);
        assert!((pl.pane(canvas_id).unwrap().width - (canvas_w_before - 30.0)).abs() < 0.001);
    }
}
