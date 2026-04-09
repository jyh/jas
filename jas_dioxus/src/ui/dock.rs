//! Dock and panel infrastructure.
//!
//! A [`DockLayout`] manages multiple docks: anchored docks snapped to screen
//! edges and floating docks at arbitrary positions. Each [`Dock`] contains a
//! vertical list of [`PanelGroup`]s. Each group has tabbed [`PanelKind`]
//! entries, one of which is active at a time.
//!
//! This module contains only pure data types and state operations — no
//! rendering code.

use serde::{Serialize, Deserialize};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const MIN_DOCK_WIDTH: f64 = 150.0;
pub const MAX_DOCK_WIDTH: f64 = 500.0;
pub const MIN_GROUP_HEIGHT: f64 = 40.0;
pub const MIN_CANVAS_WIDTH: f64 = 200.0;
pub const DEFAULT_DOCK_WIDTH: f64 = 240.0;
pub const DEFAULT_FLOATING_WIDTH: f64 = 220.0;
pub const SNAP_DISTANCE: f64 = 20.0;

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

/// Stable identifier for a dock.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct DockId(pub usize);

/// Which screen edge an anchored dock is attached to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DockEdge {
    Left,
    Right,
    Bottom,
}

/// Identifies a panel type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum PanelKind {
    Layers,
    Color,
    Stroke,
    Properties,
}

/// A group of panels sharing a tab bar.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PanelGroup {
    pub panels: Vec<PanelKind>,
    pub active: usize,
    pub collapsed: bool,
    /// Pixel height of the panel body. `None` means flex:1 (share space).
    pub height: Option<f64>,
}

impl PanelGroup {
    pub fn new(panels: Vec<PanelKind>) -> Self {
        Self {
            panels,
            active: 0,
            collapsed: false,
            height: None,
        }
    }

    /// Return the active panel kind, or `None` if the group is empty.
    pub fn active_panel(&self) -> Option<PanelKind> {
        self.panels.get(self.active).copied()
    }
}

/// A single dock: a vertical stack of panel groups.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Dock {
    pub id: DockId,
    pub groups: Vec<PanelGroup>,
    pub collapsed: bool,
    pub auto_hide: bool,
    pub width: f64,
    pub min_width: f64,
}

impl Dock {
    fn new(id: DockId, groups: Vec<PanelGroup>, width: f64) -> Self {
        Self {
            id,
            groups,
            collapsed: false,
            auto_hide: false,
            width,
            min_width: MIN_DOCK_WIDTH,
        }
    }
}

/// A floating dock: a [`Dock`] plus screen position.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FloatingDock {
    pub dock: Dock,
    pub x: f64,
    pub y: f64,
}

// ---------------------------------------------------------------------------
// Addressing
// ---------------------------------------------------------------------------

/// Locates a panel group: which dock and which group index within it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroupAddr {
    pub dock_id: DockId,
    pub group_idx: usize,
}

/// Locates a single panel tab.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PanelAddr {
    pub group: GroupAddr,
    pub panel_idx: usize,
}

// ---------------------------------------------------------------------------
// Drag state types (pure data, used by UI signals)
// ---------------------------------------------------------------------------

/// What is currently being dragged.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DragPayload {
    Group(GroupAddr),
    Panel(PanelAddr),
}

/// Where the dragged item would land if dropped now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DropTarget {
    /// Insert a group at this position within a dock.
    GroupSlot { dock_id: DockId, group_idx: usize },
    /// Add a panel to an existing group's tab bar.
    TabBar(GroupAddr),
    /// Snap to a screen edge (create or merge into anchored dock).
    Edge(DockEdge),
}

// ---------------------------------------------------------------------------
// DockLayout
// ---------------------------------------------------------------------------

/// Top-level layout: anchored docks on screen edges + floating docks.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DockLayout {
    pub anchored: Vec<(DockEdge, Dock)>,
    pub floating: Vec<FloatingDock>,
    pub hidden_panels: Vec<PanelKind>,
    pub z_order: Vec<DockId>,
    pub focused_panel: Option<PanelAddr>,
    next_id: usize,
}

impl DockLayout {
    // -----------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------

    /// Create the default layout: one Right-anchored dock with two groups.
    pub fn default_layout() -> Self {
        Self {
            anchored: vec![(
                DockEdge::Right,
                Dock::new(
                    DockId(0),
                    vec![
                        PanelGroup::new(vec![PanelKind::Layers]),
                        PanelGroup::new(vec![
                            PanelKind::Color,
                            PanelKind::Stroke,
                            PanelKind::Properties,
                        ]),
                    ],
                    DEFAULT_DOCK_WIDTH,
                ),
            )],
            floating: vec![],
            hidden_panels: vec![],
            z_order: vec![],
            focused_panel: None,
            next_id: 1,
        }
    }

    fn next_dock_id(&mut self) -> DockId {
        let id = DockId(self.next_id);
        self.next_id += 1;
        id
    }

    // -----------------------------------------------------------------------
    // Dock lookup
    // -----------------------------------------------------------------------

    /// Return a reference to the dock with the given id.
    pub fn dock(&self, id: DockId) -> Option<&Dock> {
        for (_, d) in &self.anchored {
            if d.id == id {
                return Some(d);
            }
        }
        for fd in &self.floating {
            if fd.dock.id == id {
                return Some(&fd.dock);
            }
        }
        None
    }

    /// Return a mutable reference to the dock with the given id.
    pub fn dock_mut(&mut self, id: DockId) -> Option<&mut Dock> {
        for (_, d) in &mut self.anchored {
            if d.id == id {
                return Some(d);
            }
        }
        for fd in &mut self.floating {
            if fd.dock.id == id {
                return Some(&mut fd.dock);
            }
        }
        None
    }

    /// Return the anchored dock at a given edge.
    pub fn anchored_dock(&self, edge: DockEdge) -> Option<&Dock> {
        self.anchored.iter().find(|(e, _)| *e == edge).map(|(_, d)| d)
    }

    /// Return a reference to a floating dock by id.
    pub fn floating_dock(&self, id: DockId) -> Option<&FloatingDock> {
        self.floating.iter().find(|fd| fd.dock.id == id)
    }

    /// Return all floating docks.
    pub fn floating_docks(&self) -> &[FloatingDock] {
        &self.floating
    }

    /// Is the given id an anchored dock?
    fn is_anchored(&self, id: DockId) -> bool {
        self.anchored.iter().any(|(_, d)| d.id == id)
    }

    // -----------------------------------------------------------------------
    // Collapse
    // -----------------------------------------------------------------------

    /// Toggle collapsed state for a dock by id.
    pub fn toggle_dock_collapsed(&mut self, id: DockId) {
        if let Some(d) = self.dock_mut(id) {
            d.collapsed = !d.collapsed;
        }
    }

    /// Toggle a group's collapsed state.
    pub fn toggle_group_collapsed(&mut self, addr: GroupAddr) {
        if let Some(d) = self.dock_mut(addr.dock_id) {
            if let Some(g) = d.groups.get_mut(addr.group_idx) {
                g.collapsed = !g.collapsed;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Active panel
    // -----------------------------------------------------------------------

    /// Set the active tab within a panel group.
    pub fn set_active_panel(&mut self, addr: PanelAddr) {
        if let Some(d) = self.dock_mut(addr.group.dock_id) {
            if let Some(g) = d.groups.get_mut(addr.group.group_idx) {
                if addr.panel_idx < g.panels.len() {
                    g.active = addr.panel_idx;
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Move group within same dock
    // -----------------------------------------------------------------------

    /// Reorder a group within its dock.
    pub fn move_group_within_dock(&mut self, dock_id: DockId, from: usize, to: usize) {
        if let Some(d) = self.dock_mut(dock_id) {
            if from >= d.groups.len() {
                return;
            }
            let group = d.groups.remove(from);
            let to = to.min(d.groups.len());
            d.groups.insert(to, group);
        }
    }

    // -----------------------------------------------------------------------
    // Move group between docks
    // -----------------------------------------------------------------------

    /// Move a group from one dock to another at a given position.
    pub fn move_group_to_dock(&mut self, from: GroupAddr, to_dock: DockId, to_idx: usize) {
        // Extract the group from the source dock.
        let group = {
            let src = match self.dock_mut(from.dock_id) {
                Some(d) if from.group_idx < d.groups.len() => d,
                _ => return,
            };
            src.groups.remove(from.group_idx)
        };
        // Insert into target dock.
        if let Some(dst) = self.dock_mut(to_dock) {
            let idx = to_idx.min(dst.groups.len());
            dst.groups.insert(idx, group);
        } else {
            // Target not found — put it back.
            if let Some(src) = self.dock_mut(from.dock_id) {
                src.groups.insert(from.group_idx.min(src.groups.len()), group);
            }
            return;
        }
        self.cleanup(from.dock_id);
    }

    // -----------------------------------------------------------------------
    // Detach group → floating dock
    // -----------------------------------------------------------------------

    /// Remove a group from its dock and create a new floating dock.
    pub fn detach_group(&mut self, from: GroupAddr, x: f64, y: f64) -> Option<DockId> {
        let group = {
            let src = self.dock_mut(from.dock_id)?;
            if from.group_idx >= src.groups.len() {
                return None;
            }
            src.groups.remove(from.group_idx)
        };
        let id = self.next_dock_id();
        self.floating.push(FloatingDock {
            dock: Dock::new(id, vec![group], DEFAULT_FLOATING_WIDTH),
            x,
            y,
        });
        self.z_order.push(id);
        self.cleanup(from.dock_id);
        Some(id)
    }

    // -----------------------------------------------------------------------
    // Move panel between groups
    // -----------------------------------------------------------------------

    /// Remove a panel from one group and add it to another.
    pub fn move_panel_to_group(&mut self, from: PanelAddr, to: GroupAddr) {
        // Same group — no-op.
        if from.group == to {
            return;
        }
        // Extract the panel from the source group.
        let panel = {
            let src_dock = match self.dock_mut(from.group.dock_id) {
                Some(d) => d,
                None => return,
            };
            let src_group = match src_dock.groups.get_mut(from.group.group_idx) {
                Some(g) if from.panel_idx < g.panels.len() => g,
                _ => return,
            };
            src_group.panels.remove(from.panel_idx)
        };
        // Insert into target group.
        if let Some(dst_dock) = self.dock_mut(to.dock_id) {
            if let Some(dst_group) = dst_dock.groups.get_mut(to.group_idx) {
                dst_group.panels.push(panel);
                dst_group.active = dst_group.panels.len() - 1;
            } else {
                // Target group not found — put panel back.
                if let Some(src_dock) = self.dock_mut(from.group.dock_id) {
                    if let Some(src_group) = src_dock.groups.get_mut(from.group.group_idx) {
                        let idx = from.panel_idx.min(src_group.panels.len());
                        src_group.panels.insert(idx, panel);
                    }
                }
                return;
            }
        } else {
            // Target dock not found — put panel back.
            if let Some(src_dock) = self.dock_mut(from.group.dock_id) {
                if let Some(src_group) = src_dock.groups.get_mut(from.group.group_idx) {
                    let idx = from.panel_idx.min(src_group.panels.len());
                    src_group.panels.insert(idx, panel);
                }
            }
            return;
        }
        self.cleanup(from.group.dock_id);
    }

    // -----------------------------------------------------------------------
    // Insert panel as new group
    // -----------------------------------------------------------------------

    /// Remove a panel from its group and insert it as a new single-panel
    /// group at the given position in the target dock.
    pub fn insert_panel_as_new_group(
        &mut self,
        from: PanelAddr,
        to_dock: DockId,
        at_idx: usize,
    ) {
        // Extract the panel.
        let panel = {
            let src_dock = match self.dock_mut(from.group.dock_id) {
                Some(d) => d,
                None => return,
            };
            let src_group = match src_dock.groups.get_mut(from.group.group_idx) {
                Some(g) if from.panel_idx < g.panels.len() => g,
                _ => return,
            };
            src_group.panels.remove(from.panel_idx)
        };
        // Create new group and insert into target dock.
        let new_group = PanelGroup::new(vec![panel]);
        if let Some(dst) = self.dock_mut(to_dock) {
            let idx = at_idx.min(dst.groups.len());
            dst.groups.insert(idx, new_group);
        } else {
            // Target not found — put panel back.
            if let Some(src_dock) = self.dock_mut(from.group.dock_id) {
                if let Some(src_group) = src_dock.groups.get_mut(from.group.group_idx) {
                    let idx = from.panel_idx.min(src_group.panels.len());
                    src_group.panels.insert(idx, panel);
                }
            }
            return;
        }
        self.cleanup(from.group.dock_id);
    }

    // -----------------------------------------------------------------------
    // Detach panel → floating dock
    // -----------------------------------------------------------------------

    /// Remove a panel and create a new floating dock with it.
    pub fn detach_panel(&mut self, from: PanelAddr, x: f64, y: f64) -> Option<DockId> {
        let panel = {
            let src_dock = self.dock_mut(from.group.dock_id)?;
            let src_group = src_dock.groups.get_mut(from.group.group_idx)?;
            if from.panel_idx >= src_group.panels.len() {
                return None;
            }
            src_group.panels.remove(from.panel_idx)
        };
        let id = self.next_dock_id();
        self.floating.push(FloatingDock {
            dock: Dock::new(id, vec![PanelGroup::new(vec![panel])], DEFAULT_FLOATING_WIDTH),
            x,
            y,
        });
        self.z_order.push(id);
        self.cleanup(from.group.dock_id);
        Some(id)
    }

    // -----------------------------------------------------------------------
    // Floating dock position
    // -----------------------------------------------------------------------

    /// Move a floating dock. Ignored for anchored docks.
    pub fn set_floating_position(&mut self, id: DockId, x: f64, y: f64) {
        if let Some(fd) = self.floating.iter_mut().find(|fd| fd.dock.id == id) {
            fd.x = x;
            fd.y = y;
        }
    }

    // -----------------------------------------------------------------------
    // Resize
    // -----------------------------------------------------------------------

    /// Set a group's height. Clamped to MIN_GROUP_HEIGHT.
    pub fn resize_group(&mut self, addr: GroupAddr, height: f64) {
        if let Some(d) = self.dock_mut(addr.dock_id) {
            if let Some(g) = d.groups.get_mut(addr.group_idx) {
                g.height = Some(height.max(MIN_GROUP_HEIGHT));
            }
        }
    }

    /// Set a dock's width. Clamped to [min_width, MAX_DOCK_WIDTH].
    pub fn set_dock_width(&mut self, id: DockId, width: f64) {
        if let Some(d) = self.dock_mut(id) {
            let min = d.min_width;
            d.width = width.clamp(min, MAX_DOCK_WIDTH);
        }
    }

    // -----------------------------------------------------------------------
    // Labels
    // -----------------------------------------------------------------------

    /// Human-readable label for a panel kind.
    pub fn panel_label(kind: PanelKind) -> &'static str {
        match kind {
            PanelKind::Layers => "Layers",
            PanelKind::Color => "Color",
            PanelKind::Stroke => "Stroke",
            PanelKind::Properties => "Properties",
        }
    }

    // -----------------------------------------------------------------------
    // Close / show panels
    // -----------------------------------------------------------------------

    /// Close a panel: remove it from its group and add to hidden list.
    pub fn close_panel(&mut self, addr: PanelAddr) {
        let panel = {
            let dock = match self.dock_mut(addr.group.dock_id) {
                Some(d) => d,
                None => return,
            };
            let group = match dock.groups.get_mut(addr.group.group_idx) {
                Some(g) if addr.panel_idx < g.panels.len() => g,
                _ => return,
            };
            group.panels.remove(addr.panel_idx)
        };
        if !self.hidden_panels.contains(&panel) {
            self.hidden_panels.push(panel);
        }
        self.cleanup(addr.group.dock_id);
    }

    /// Show a hidden panel: remove from hidden list and add to the first
    /// group of the first anchored dock (or create one if needed).
    pub fn show_panel(&mut self, kind: PanelKind) {
        if let Some(pos) = self.hidden_panels.iter().position(|&k| k == kind) {
            self.hidden_panels.remove(pos);
        } else {
            return; // not hidden
        }
        // Find the first anchored dock and add to its first group.
        if let Some((_, dock)) = self.anchored.first_mut() {
            if let Some(group) = dock.groups.first_mut() {
                group.panels.push(kind);
                group.active = group.panels.len() - 1;
            } else {
                dock.groups.push(PanelGroup::new(vec![kind]));
            }
        }
    }

    /// Return the list of hidden panels.
    pub fn hidden_panels(&self) -> &[PanelKind] {
        &self.hidden_panels
    }

    /// Check if a panel kind is currently visible (not hidden).
    pub fn is_panel_visible(&self, kind: PanelKind) -> bool {
        !self.hidden_panels.contains(&kind)
    }

    /// Return all panel kinds with their visibility, for a Window menu.
    pub fn panel_menu_items(&self) -> Vec<(PanelKind, bool)> {
        let all = [PanelKind::Layers, PanelKind::Color, PanelKind::Stroke, PanelKind::Properties];
        all.iter().map(|&k| (k, self.is_panel_visible(k))).collect()
    }

    // -----------------------------------------------------------------------
    // Z-index management
    // -----------------------------------------------------------------------

    /// Bring a floating dock to the front of the z-order.
    pub fn bring_to_front(&mut self, id: DockId) {
        if let Some(pos) = self.z_order.iter().position(|&zid| zid == id) {
            self.z_order.remove(pos);
            self.z_order.push(id);
        }
    }

    /// Return the z-index position for a floating dock (0 = back).
    pub fn z_index_for(&self, id: DockId) -> usize {
        self.z_order.iter().position(|&zid| zid == id).unwrap_or(0)
    }

    // -----------------------------------------------------------------------
    // Snap & re-dock
    // -----------------------------------------------------------------------

    /// Snap a floating dock to a screen edge, creating or merging into
    /// an anchored dock at that edge. The floating dock is removed.
    pub fn snap_to_edge(&mut self, id: DockId, edge: DockEdge) {
        // Find and remove the floating dock.
        let pos = match self.floating.iter().position(|fd| fd.dock.id == id) {
            Some(p) => p,
            None => return,
        };
        let fdock = self.floating.remove(pos);
        self.z_order.retain(|&zid| zid != id);

        // Merge groups into existing anchored dock at this edge, or create one.
        if let Some((_, dock)) = self.anchored.iter_mut().find(|(e, _)| *e == edge) {
            for group in fdock.dock.groups {
                dock.groups.push(group);
            }
        } else {
            self.anchored.push((edge, fdock.dock));
        }
    }

    /// Re-dock a floating dock by merging it into the Right anchored dock.
    pub fn redock(&mut self, id: DockId) {
        self.snap_to_edge(id, DockEdge::Right);
    }

    /// Detect if a position is near a screen edge. Returns the edge if
    /// within SNAP_DISTANCE pixels.
    pub fn is_near_edge(x: f64, y: f64, viewport_w: f64, viewport_h: f64) -> Option<DockEdge> {
        if x <= SNAP_DISTANCE {
            Some(DockEdge::Left)
        } else if x >= viewport_w - SNAP_DISTANCE {
            Some(DockEdge::Right)
        } else if y >= viewport_h - SNAP_DISTANCE {
            Some(DockEdge::Bottom)
        } else {
            None
        }
    }

    // -----------------------------------------------------------------------
    // Multi-edge anchored docks
    // -----------------------------------------------------------------------

    /// Add a new empty anchored dock at the given edge. Returns its id.
    /// If one already exists at that edge, returns its existing id.
    pub fn add_anchored_dock(&mut self, edge: DockEdge) -> DockId {
        if let Some((_, dock)) = self.anchored.iter().find(|(e, _)| *e == edge) {
            return dock.id;
        }
        let id = self.next_dock_id();
        self.anchored.push((edge, Dock::new(id, vec![], DEFAULT_DOCK_WIDTH)));
        id
    }

    /// Remove an anchored dock at the given edge. Its groups become a
    /// floating dock. Returns None if no dock at that edge.
    pub fn remove_anchored_dock(&mut self, edge: DockEdge) -> Option<DockId> {
        let pos = self.anchored.iter().position(|(e, _)| *e == edge)?;
        let (_, dock) = self.anchored.remove(pos);
        if dock.groups.is_empty() {
            return None;
        }
        let fid = self.next_dock_id();
        self.floating.push(FloatingDock {
            dock: Dock::new(fid, dock.groups, dock.width),
            x: 100.0,
            y: 100.0,
        });
        self.z_order.push(fid);
        Some(fid)
    }

    // -----------------------------------------------------------------------
    // Persistence
    // -----------------------------------------------------------------------

    /// Reset to the default layout, discarding all customizations.
    pub fn reset_to_default(&mut self) {
        *self = Self::default_layout();
    }

    /// Serialize the layout to a JSON string.
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }

    /// Deserialize a layout from a JSON string. Returns the default
    /// layout if the JSON is invalid.
    pub fn from_json(json: &str) -> Self {
        serde_json::from_str(json).unwrap_or_else(|_| Self::default_layout())
    }

    /// Key used for localStorage.
    pub const STORAGE_KEY: &'static str = "jas_dock_layout";

    // -----------------------------------------------------------------------
    // Cleanup
    // -----------------------------------------------------------------------

    /// Remove empty groups, clamp active indices, remove empty floating docks.
    fn cleanup(&mut self, dock_id: DockId) {
        // Helper: clean a dock's groups in place.
        fn clean_groups(dock: &mut Dock) {
            dock.groups.retain(|g| !g.panels.is_empty());
            for g in &mut dock.groups {
                if g.active >= g.panels.len() && !g.panels.is_empty() {
                    g.active = g.panels.len() - 1;
                }
            }
        }

        // Clean the specific dock.
        if let Some(d) = self.dock_mut(dock_id) {
            clean_groups(d);
        }

        // Remove empty floating docks.
        let removed: Vec<DockId> = self
            .floating
            .iter()
            .filter(|fd| fd.dock.groups.is_empty())
            .map(|fd| fd.dock.id)
            .collect();
        self.floating.retain(|fd| !fd.dock.groups.is_empty());
        self.z_order.retain(|id| !removed.contains(id));
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // Helpers
    fn ga(dock_id: usize, group_idx: usize) -> GroupAddr {
        GroupAddr { dock_id: DockId(dock_id), group_idx }
    }

    fn pa(dock_id: usize, group_idx: usize, panel_idx: usize) -> PanelAddr {
        PanelAddr { group: ga(dock_id, group_idx), panel_idx }
    }

    fn right_dock_id(layout: &DockLayout) -> DockId {
        layout.anchored_dock(DockEdge::Right).unwrap().id
    }

    // -----------------------------------------------------------------------
    // Layout & lookup
    // -----------------------------------------------------------------------

    #[test]
    fn default_layout_one_anchored_right() {
        let l = DockLayout::default_layout();
        assert_eq!(l.anchored.len(), 1);
        assert_eq!(l.anchored[0].0, DockEdge::Right);
        assert!(l.floating.is_empty());
    }

    #[test]
    fn default_layout_two_groups() {
        let l = DockLayout::default_layout();
        let d = l.anchored_dock(DockEdge::Right).unwrap();
        assert_eq!(d.groups.len(), 2);
        assert_eq!(d.groups[0].panels, vec![PanelKind::Layers]);
        assert_eq!(d.groups[1].panels, vec![PanelKind::Color, PanelKind::Stroke, PanelKind::Properties]);
    }

    #[test]
    fn default_not_collapsed() {
        let l = DockLayout::default_layout();
        let d = l.anchored_dock(DockEdge::Right).unwrap();
        assert!(!d.collapsed);
        for g in &d.groups {
            assert!(!g.collapsed);
        }
    }

    #[test]
    fn default_dock_width() {
        let l = DockLayout::default_layout();
        let d = l.anchored_dock(DockEdge::Right).unwrap();
        assert_eq!(d.width, DEFAULT_DOCK_WIDTH);
    }

    #[test]
    fn dock_lookup_anchored() {
        let l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        assert!(l.dock(id).is_some());
    }

    #[test]
    fn dock_lookup_floating() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 100.0, 100.0).unwrap();
        assert!(l.dock(fid).is_some());
        assert!(l.floating_dock(fid).is_some());
    }

    #[test]
    fn dock_lookup_invalid() {
        let l = DockLayout::default_layout();
        assert!(l.dock(DockId(99)).is_none());
    }

    #[test]
    fn anchored_dock_by_edge() {
        let l = DockLayout::default_layout();
        assert!(l.anchored_dock(DockEdge::Right).is_some());
        assert!(l.anchored_dock(DockEdge::Left).is_none());
        assert!(l.anchored_dock(DockEdge::Bottom).is_none());
    }

    // -----------------------------------------------------------------------
    // Toggle / active
    // -----------------------------------------------------------------------

    #[test]
    fn toggle_dock_collapsed() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        assert!(!l.dock(id).unwrap().collapsed);
        l.toggle_dock_collapsed(id);
        assert!(l.dock(id).unwrap().collapsed);
        l.toggle_dock_collapsed(id);
        assert!(!l.dock(id).unwrap().collapsed);
    }

    #[test]
    fn toggle_group_collapsed() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.toggle_group_collapsed(ga(id.0, 0));
        assert!(l.dock(id).unwrap().groups[0].collapsed);
        assert!(!l.dock(id).unwrap().groups[1].collapsed);
        l.toggle_group_collapsed(ga(id.0, 0));
        assert!(!l.dock(id).unwrap().groups[0].collapsed);
    }

    #[test]
    fn toggle_group_out_of_bounds() {
        let mut l = DockLayout::default_layout();
        l.toggle_group_collapsed(ga(0, 99)); // no panic
        l.toggle_group_collapsed(ga(99, 0)); // no panic
    }

    #[test]
    fn set_active_panel() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.set_active_panel(pa(id.0, 1, 2));
        assert_eq!(l.dock(id).unwrap().groups[1].active, 2);
    }

    #[test]
    fn set_active_panel_out_of_bounds() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.set_active_panel(pa(id.0, 1, 99)); // invalid panel
        assert_eq!(l.dock(id).unwrap().groups[1].active, 0);
        l.set_active_panel(pa(id.0, 99, 0)); // invalid group
        l.set_active_panel(pa(99, 0, 0));     // invalid dock
    }

    // -----------------------------------------------------------------------
    // Move group within dock
    // -----------------------------------------------------------------------

    #[test]
    fn move_group_forward() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.move_group_within_dock(id, 0, 1);
        let d = l.dock(id).unwrap();
        assert_eq!(d.groups[0].panels, vec![PanelKind::Color, PanelKind::Stroke, PanelKind::Properties]);
        assert_eq!(d.groups[1].panels, vec![PanelKind::Layers]);
    }

    #[test]
    fn move_group_backward() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.move_group_within_dock(id, 1, 0);
        let d = l.dock(id).unwrap();
        assert_eq!(d.groups[0].panels, vec![PanelKind::Color, PanelKind::Stroke, PanelKind::Properties]);
        assert_eq!(d.groups[1].panels, vec![PanelKind::Layers]);
    }

    #[test]
    fn move_group_same_position() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.move_group_within_dock(id, 0, 0);
        assert_eq!(l.dock(id).unwrap().groups[0].panels, vec![PanelKind::Layers]);
    }

    #[test]
    fn move_group_clamped() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.move_group_within_dock(id, 0, 99);
        assert_eq!(l.dock(id).unwrap().groups[1].panels, vec![PanelKind::Layers]);
    }

    #[test]
    fn move_group_out_of_bounds() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.move_group_within_dock(id, 99, 0); // no panic
        assert_eq!(l.dock(id).unwrap().groups.len(), 2);
    }

    #[test]
    fn move_group_preserves_state() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.dock_mut(id).unwrap().groups[1].active = 2;
        l.dock_mut(id).unwrap().groups[1].collapsed = true;
        l.move_group_within_dock(id, 1, 0);
        let g = &l.dock(id).unwrap().groups[0];
        assert_eq!(g.active, 2);
        assert!(g.collapsed);
    }

    // -----------------------------------------------------------------------
    // Move group between docks
    // -----------------------------------------------------------------------

    #[test]
    fn move_group_between_docks() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 50.0, 50.0).unwrap();
        // Now move group 0 from anchored (which is now [Color,Stroke,Properties]) to floating
        l.move_group_to_dock(ga(id.0, 0), fid, 1);
        assert!(l.dock(id).unwrap().groups.is_empty());
        assert_eq!(l.dock(fid).unwrap().groups.len(), 2);
    }

    #[test]
    fn move_group_inserts_at_position() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        // Detach both groups to create floating docks
        let f1 = l.detach_group(ga(id.0, 0), 10.0, 10.0).unwrap();
        let f2 = l.detach_group(ga(id.0, 0), 20.0, 20.0).unwrap();
        // f1 has Layers, f2 has Color/Stroke/Properties
        // Move Layers group to f2 at position 0
        l.move_group_to_dock(ga(f1.0, 0), f2, 0);
        let d = l.dock(f2).unwrap();
        assert_eq!(d.groups[0].panels, vec![PanelKind::Layers]);
        assert_eq!(d.groups[1].panels, vec![PanelKind::Color, PanelKind::Stroke, PanelKind::Properties]);
        // f1 should be cleaned up (empty floating dock removed)
        assert!(l.dock(f1).is_none());
    }

    #[test]
    fn move_group_same_dock_is_reorder() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.move_group_to_dock(ga(id.0, 0), id, 1);
        let d = l.dock(id).unwrap();
        assert_eq!(d.groups[0].panels, vec![PanelKind::Color, PanelKind::Stroke, PanelKind::Properties]);
        assert_eq!(d.groups[1].panels, vec![PanelKind::Layers]);
    }

    #[test]
    fn move_group_invalid_source() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.move_group_to_dock(ga(id.0, 99), id, 0); // no panic
        assert_eq!(l.dock(id).unwrap().groups.len(), 2);
    }

    #[test]
    fn move_group_invalid_target() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.move_group_to_dock(ga(id.0, 0), DockId(99), 0);
        // Group should be put back — source still has 2 groups
        assert_eq!(l.dock(id).unwrap().groups.len(), 2);
    }

    // -----------------------------------------------------------------------
    // Detach group
    // -----------------------------------------------------------------------

    #[test]
    fn detach_group_creates_floating() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 100.0, 200.0);
        assert!(fid.is_some());
        let fid = fid.unwrap();
        assert_eq!(l.dock(fid).unwrap().groups[0].panels, vec![PanelKind::Layers]);
        assert_eq!(l.dock(id).unwrap().groups.len(), 1);
    }

    #[test]
    fn detach_group_position() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 100.0, 200.0).unwrap();
        let fd = l.floating_dock(fid).unwrap();
        assert_eq!(fd.x, 100.0);
        assert_eq!(fd.y, 200.0);
    }

    #[test]
    fn detach_group_unique_ids() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let f1 = l.detach_group(ga(id.0, 0), 10.0, 10.0).unwrap();
        let f2 = l.detach_group(ga(id.0, 0), 20.0, 20.0).unwrap();
        assert_ne!(f1, f2);
    }

    #[test]
    fn detach_last_group_floating_removes_dock() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let f1 = l.detach_group(ga(id.0, 0), 10.0, 10.0).unwrap();
        // f1 has one group. Detach it elsewhere.
        let _f2 = l.detach_group(ga(f1.0, 0), 20.0, 20.0).unwrap();
        // f1 should be removed (empty floating dock)
        assert!(l.dock(f1).is_none());
    }

    #[test]
    fn detach_last_group_anchored_keeps_dock() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.detach_group(ga(id.0, 0), 10.0, 10.0);
        l.detach_group(ga(id.0, 0), 20.0, 20.0);
        // Anchored dock should still exist even with no groups
        assert!(l.dock(id).is_some());
        assert!(l.dock(id).unwrap().groups.is_empty());
    }

    // -----------------------------------------------------------------------
    // Move panel
    // -----------------------------------------------------------------------

    #[test]
    fn move_panel_same_dock() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        // Move Stroke (group 1, panel 1) to group 0
        l.move_panel_to_group(pa(id.0, 1, 1), ga(id.0, 0));
        let d = l.dock(id).unwrap();
        assert_eq!(d.groups[0].panels, vec![PanelKind::Layers, PanelKind::Stroke]);
        assert_eq!(d.groups[1].panels, vec![PanelKind::Color, PanelKind::Properties]);
    }

    #[test]
    fn move_panel_becomes_active() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.move_panel_to_group(pa(id.0, 1, 1), ga(id.0, 0));
        assert_eq!(l.dock(id).unwrap().groups[0].active, 1); // newly added panel
    }

    #[test]
    fn move_panel_cross_dock() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 50.0, 50.0).unwrap();
        // Move Color from anchored group 0 (now [Color, Stroke, Properties]) to floating group 0
        l.move_panel_to_group(pa(id.0, 0, 0), ga(fid.0, 0));
        assert_eq!(l.dock(fid).unwrap().groups[0].panels,
                   vec![PanelKind::Layers, PanelKind::Color]);
        assert_eq!(l.dock(id).unwrap().groups[0].panels,
                   vec![PanelKind::Stroke, PanelKind::Properties]);
    }

    #[test]
    fn move_last_panel_removes_group() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        // Move the only panel in group 0 (Layers) to group 1
        l.move_panel_to_group(pa(id.0, 0, 0), ga(id.0, 1));
        let d = l.dock(id).unwrap();
        assert_eq!(d.groups.len(), 1); // group 0 removed
        assert!(d.groups[0].panels.contains(&PanelKind::Layers));
    }

    #[test]
    fn move_last_panel_removes_floating() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 50.0, 50.0).unwrap();
        // Floating has one group with one panel (Layers). Move it to anchored.
        l.move_panel_to_group(pa(fid.0, 0, 0), ga(id.0, 0));
        // Floating dock should be removed
        assert!(l.dock(fid).is_none());
    }

    #[test]
    fn move_panel_clamps_active() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        // Set active to 2 (Properties) in group 1
        l.dock_mut(id).unwrap().groups[1].active = 2;
        // Remove Properties (index 2)
        l.move_panel_to_group(pa(id.0, 1, 2), ga(id.0, 0));
        // Active should be clamped to 1
        assert!(l.dock(id).unwrap().groups[1].active <= 1);
    }

    #[test]
    fn move_panel_invalid_source() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.move_panel_to_group(pa(id.0, 1, 99), ga(id.0, 0)); // no panic
        l.move_panel_to_group(pa(99, 0, 0), ga(id.0, 0));      // no panic
    }

    #[test]
    fn move_panel_invalid_target() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.move_panel_to_group(pa(id.0, 1, 0), ga(99, 0));
        // Panel should be put back — unchanged
        assert_eq!(l.dock(id).unwrap().groups[1].panels.len(), 3);
    }

    // -----------------------------------------------------------------------
    // Insert panel as new group
    // -----------------------------------------------------------------------

    #[test]
    fn insert_panel_creates_group() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        // Insert Stroke as a new group at position 0
        l.insert_panel_as_new_group(pa(id.0, 1, 1), id, 0);
        let d = l.dock(id).unwrap();
        assert_eq!(d.groups.len(), 3);
        assert_eq!(d.groups[0].panels, vec![PanelKind::Stroke]);
    }

    #[test]
    fn insert_panel_cleans_source() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        // Group 0 has only Layers. Insert it as new group at end.
        l.insert_panel_as_new_group(pa(id.0, 0, 0), id, 99);
        let d = l.dock(id).unwrap();
        // Original group 0 (now empty) should be cleaned up.
        // Should have 2 groups: [Color,Stroke,Properties] and [Layers]
        assert_eq!(d.groups.len(), 2);
        assert_eq!(d.groups[1].panels, vec![PanelKind::Layers]);
    }

    #[test]
    fn insert_panel_invalid() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.insert_panel_as_new_group(pa(id.0, 1, 99), id, 0); // no panic
        l.insert_panel_as_new_group(pa(99, 0, 0), id, 0);      // no panic
        assert_eq!(l.dock(id).unwrap().groups.len(), 2);
    }

    // -----------------------------------------------------------------------
    // Detach panel
    // -----------------------------------------------------------------------

    #[test]
    fn detach_panel_creates_floating() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_panel(pa(id.0, 1, 1), 300.0, 150.0);
        assert!(fid.is_some());
        let fid = fid.unwrap();
        assert_eq!(l.dock(fid).unwrap().groups[0].panels, vec![PanelKind::Stroke]);
        assert_eq!(l.dock(id).unwrap().groups[1].panels, vec![PanelKind::Color, PanelKind::Properties]);
    }

    #[test]
    fn detach_panel_position() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_panel(pa(id.0, 1, 0), 300.0, 150.0).unwrap();
        let fd = l.floating_dock(fid).unwrap();
        assert_eq!(fd.x, 300.0);
        assert_eq!(fd.y, 150.0);
    }

    #[test]
    fn detach_panel_last_removes_group() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        // Detach the only panel in group 0
        l.detach_panel(pa(id.0, 0, 0), 50.0, 50.0);
        assert_eq!(l.dock(id).unwrap().groups.len(), 1);
    }

    #[test]
    fn detach_panel_last_removes_floating() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let f1 = l.detach_group(ga(id.0, 0), 50.0, 50.0).unwrap();
        // f1 has one group with one panel (Layers). Detach it.
        let _f2 = l.detach_panel(pa(f1.0, 0, 0), 100.0, 100.0);
        // f1 should be gone
        assert!(l.dock(f1).is_none());
    }

    // -----------------------------------------------------------------------
    // Floating position
    // -----------------------------------------------------------------------

    #[test]
    fn set_floating_position() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 10.0, 10.0).unwrap();
        l.set_floating_position(fid, 200.0, 300.0);
        let fd = l.floating_dock(fid).unwrap();
        assert_eq!(fd.x, 200.0);
        assert_eq!(fd.y, 300.0);
    }

    #[test]
    fn set_position_anchored_ignored() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.set_floating_position(id, 999.0, 999.0); // no-op, no panic
    }

    #[test]
    fn set_position_invalid_id() {
        let mut l = DockLayout::default_layout();
        l.set_floating_position(DockId(99), 0.0, 0.0); // no panic
    }

    // -----------------------------------------------------------------------
    // Resize
    // -----------------------------------------------------------------------

    #[test]
    fn resize_group_sets_height() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.resize_group(ga(id.0, 0), 150.0);
        assert_eq!(l.dock(id).unwrap().groups[0].height, Some(150.0));
    }

    #[test]
    fn resize_group_clamps_min() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.resize_group(ga(id.0, 0), 5.0);
        assert_eq!(l.dock(id).unwrap().groups[0].height, Some(MIN_GROUP_HEIGHT));
    }

    #[test]
    fn resize_group_invalid_addr() {
        let mut l = DockLayout::default_layout();
        l.resize_group(ga(99, 0), 100.0); // no panic
        l.resize_group(ga(0, 99), 100.0); // no panic
    }

    #[test]
    fn default_group_height_is_none() {
        let l = DockLayout::default_layout();
        let d = l.anchored_dock(DockEdge::Right).unwrap();
        for g in &d.groups {
            assert_eq!(g.height, None);
        }
    }

    #[test]
    fn set_dock_width_clamped() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.set_dock_width(id, 50.0);
        assert_eq!(l.dock(id).unwrap().width, MIN_DOCK_WIDTH);
        l.set_dock_width(id, 9999.0);
        assert_eq!(l.dock(id).unwrap().width, MAX_DOCK_WIDTH);
        l.set_dock_width(id, 300.0);
        assert_eq!(l.dock(id).unwrap().width, 300.0);
    }

    // -----------------------------------------------------------------------
    // Cleanup
    // -----------------------------------------------------------------------

    #[test]
    fn cleanup_clamps_active() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        // Set active beyond range, then trigger cleanup via a move
        l.dock_mut(id).unwrap().groups[1].active = 2; // Properties
        l.move_panel_to_group(pa(id.0, 1, 2), ga(id.0, 0)); // remove Properties
        let g = &l.dock(id).unwrap().groups[1];
        assert!(g.active < g.panels.len());
    }

    #[test]
    fn cleanup_multiple_empty_groups() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        // Manually empty both groups
        l.dock_mut(id).unwrap().groups[0].panels.clear();
        l.dock_mut(id).unwrap().groups[1].panels.clear();
        l.cleanup(id);
        assert!(l.dock(id).unwrap().groups.is_empty());
    }

    // -----------------------------------------------------------------------
    // Labels
    // -----------------------------------------------------------------------

    #[test]
    fn panel_label_values() {
        assert_eq!(DockLayout::panel_label(PanelKind::Layers), "Layers");
        assert_eq!(DockLayout::panel_label(PanelKind::Color), "Color");
        assert_eq!(DockLayout::panel_label(PanelKind::Stroke), "Stroke");
        assert_eq!(DockLayout::panel_label(PanelKind::Properties), "Properties");
    }

    #[test]
    fn panel_group_active_panel() {
        let group = PanelGroup::new(vec![PanelKind::Color, PanelKind::Stroke]);
        assert_eq!(group.active_panel(), Some(PanelKind::Color));
    }

    #[test]
    fn panel_group_active_panel_empty() {
        let group = PanelGroup { panels: vec![], active: 0, collapsed: false, height: None };
        assert_eq!(group.active_panel(), None);
    }

    // -----------------------------------------------------------------------
    // Phase 2: Close/show panels
    // -----------------------------------------------------------------------

    #[test]
    fn close_panel_hides_it() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.close_panel(pa(id.0, 1, 1)); // close Stroke
        assert!(l.hidden_panels().contains(&PanelKind::Stroke));
        assert!(!l.is_panel_visible(PanelKind::Stroke));
    }

    #[test]
    fn close_panel_removes_from_group() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.close_panel(pa(id.0, 1, 1)); // close Stroke
        let d = l.dock(id).unwrap();
        assert_eq!(d.groups[1].panels, vec![PanelKind::Color, PanelKind::Properties]);
    }

    #[test]
    fn close_last_panel_removes_group() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.close_panel(pa(id.0, 0, 0)); // close Layers (only panel in group 0)
        let d = l.dock(id).unwrap();
        assert_eq!(d.groups.len(), 1); // group removed
        assert!(l.hidden_panels().contains(&PanelKind::Layers));
    }

    #[test]
    fn show_panel_adds_to_default_group() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.close_panel(pa(id.0, 1, 1)); // close Stroke
        l.show_panel(PanelKind::Stroke);
        assert!(!l.hidden_panels().contains(&PanelKind::Stroke));
        // Stroke should be added to the first group of the anchored dock
        let d = l.dock(id).unwrap();
        assert!(d.groups[0].panels.contains(&PanelKind::Stroke));
    }

    #[test]
    fn show_panel_removes_from_hidden() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.close_panel(pa(id.0, 1, 0)); // close Color
        assert_eq!(l.hidden_panels().len(), 1);
        l.show_panel(PanelKind::Color);
        assert!(l.hidden_panels().is_empty());
    }

    #[test]
    fn hidden_panels_default_empty() {
        let l = DockLayout::default_layout();
        assert!(l.hidden_panels().is_empty());
    }

    #[test]
    fn panel_menu_items_all_visible() {
        let l = DockLayout::default_layout();
        let items = l.panel_menu_items();
        assert_eq!(items.len(), 4);
        for (_, visible) in &items {
            assert!(visible);
        }
    }

    #[test]
    fn panel_menu_items_with_hidden() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.close_panel(pa(id.0, 1, 1)); // close Stroke
        let items = l.panel_menu_items();
        let stroke_item = items.iter().find(|(k, _)| *k == PanelKind::Stroke).unwrap();
        assert!(!stroke_item.1);
        let layers_item = items.iter().find(|(k, _)| *k == PanelKind::Layers).unwrap();
        assert!(layers_item.1);
    }

    // -----------------------------------------------------------------------
    // Phase 2: Z-index management
    // -----------------------------------------------------------------------

    #[test]
    fn bring_to_front_moves_to_end() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let f1 = l.detach_group(ga(id.0, 0), 10.0, 10.0).unwrap();
        let f2 = l.detach_group(ga(id.0, 0), 20.0, 20.0).unwrap();
        // z_order is [f1, f2], bring f1 to front
        l.bring_to_front(f1);
        assert_eq!(*l.z_order.last().unwrap(), f1);
    }

    #[test]
    fn bring_to_front_already_front() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let f1 = l.detach_group(ga(id.0, 0), 10.0, 10.0).unwrap();
        let f2 = l.detach_group(ga(id.0, 0), 20.0, 20.0).unwrap();
        // f2 is already at front
        l.bring_to_front(f2);
        assert_eq!(*l.z_order.last().unwrap(), f2);
        assert_eq!(l.z_order.len(), 2);
    }

    #[test]
    fn z_index_for_ordering() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let f1 = l.detach_group(ga(id.0, 0), 10.0, 10.0).unwrap();
        let f2 = l.detach_group(ga(id.0, 0), 20.0, 20.0).unwrap();
        assert_eq!(l.z_index_for(f1), 0);
        assert_eq!(l.z_index_for(f2), 1);
        l.bring_to_front(f1);
        assert_eq!(l.z_index_for(f1), 1);
        assert_eq!(l.z_index_for(f2), 0);
    }

    // -----------------------------------------------------------------------
    // Phase 3: Snap & re-dock
    // -----------------------------------------------------------------------

    #[test]
    fn snap_to_right_edge() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 50.0, 50.0).unwrap();
        let right_groups_before = l.anchored_dock(DockEdge::Right).unwrap().groups.len();
        l.snap_to_edge(fid, DockEdge::Right);
        // Floating dock removed, groups merged into right anchored
        assert!(l.floating_dock(fid).is_none());
        assert!(l.anchored_dock(DockEdge::Right).unwrap().groups.len() > right_groups_before);
    }

    #[test]
    fn snap_to_left_edge() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 50.0, 50.0).unwrap();
        l.snap_to_edge(fid, DockEdge::Left);
        // Should create a new anchored dock on the left
        assert!(l.anchored_dock(DockEdge::Left).is_some());
        assert!(l.floating_dock(fid).is_none());
    }

    #[test]
    fn snap_creates_anchored_dock() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        assert!(l.anchored_dock(DockEdge::Bottom).is_none());
        let fid = l.detach_group(ga(id.0, 0), 50.0, 50.0).unwrap();
        l.snap_to_edge(fid, DockEdge::Bottom);
        assert!(l.anchored_dock(DockEdge::Bottom).is_some());
        assert_eq!(l.anchored_dock(DockEdge::Bottom).unwrap().groups[0].panels, vec![PanelKind::Layers]);
    }

    #[test]
    fn redock_merges_into_right() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 50.0, 50.0).unwrap();
        l.redock(fid);
        assert!(l.floating.is_empty());
        // Layers group should be back in right dock
        let right = l.anchored_dock(DockEdge::Right).unwrap();
        assert!(right.groups.iter().any(|g| g.panels.contains(&PanelKind::Layers)));
    }

    #[test]
    fn redock_invalid_id() {
        let mut l = DockLayout::default_layout();
        l.redock(DockId(99)); // no panic, no change
        assert_eq!(l.anchored.len(), 1);
    }

    #[test]
    fn is_near_edge_detection() {
        assert_eq!(DockLayout::is_near_edge(5.0, 500.0, 1000.0, 800.0), Some(DockEdge::Left));
        assert_eq!(DockLayout::is_near_edge(990.0, 500.0, 1000.0, 800.0), Some(DockEdge::Right));
        assert_eq!(DockLayout::is_near_edge(500.0, 790.0, 1000.0, 800.0), Some(DockEdge::Bottom));
    }

    #[test]
    fn is_near_edge_not_near() {
        assert_eq!(DockLayout::is_near_edge(500.0, 400.0, 1000.0, 800.0), None);
    }

    // -----------------------------------------------------------------------
    // Phase 3: Multi-edge anchored docks
    // -----------------------------------------------------------------------

    #[test]
    fn add_anchored_left() {
        let mut l = DockLayout::default_layout();
        let id = l.add_anchored_dock(DockEdge::Left);
        assert!(l.anchored_dock(DockEdge::Left).is_some());
        assert_eq!(l.anchored_dock(DockEdge::Left).unwrap().id, id);
    }

    #[test]
    fn add_anchored_existing_returns_id() {
        let mut l = DockLayout::default_layout();
        let id1 = l.add_anchored_dock(DockEdge::Left);
        let id2 = l.add_anchored_dock(DockEdge::Left);
        assert_eq!(id1, id2);
        assert_eq!(l.anchored.len(), 2); // Right + Left, not duplicated
    }

    #[test]
    fn add_anchored_bottom() {
        let mut l = DockLayout::default_layout();
        l.add_anchored_dock(DockEdge::Bottom);
        assert!(l.anchored_dock(DockEdge::Bottom).is_some());
        assert_eq!(l.anchored.len(), 2);
    }

    #[test]
    fn remove_anchored_moves_to_floating() {
        let mut l = DockLayout::default_layout();
        let lid = l.add_anchored_dock(DockEdge::Left);
        // Add a group to it so removal creates a floating dock
        l.dock_mut(lid).unwrap().groups.push(PanelGroup::new(vec![PanelKind::Layers]));
        let fid = l.remove_anchored_dock(DockEdge::Left);
        assert!(fid.is_some());
        assert!(l.anchored_dock(DockEdge::Left).is_none());
        assert!(l.floating_dock(fid.unwrap()).is_some());
    }

    #[test]
    fn remove_anchored_empty_returns_none() {
        let mut l = DockLayout::default_layout();
        l.add_anchored_dock(DockEdge::Left); // empty dock
        let fid = l.remove_anchored_dock(DockEdge::Left);
        assert!(fid.is_none()); // no groups, no floating dock created
    }

    // -----------------------------------------------------------------------
    // Phase 4: Persistence
    // -----------------------------------------------------------------------

    #[test]
    fn to_json_round_trip() {
        let l = DockLayout::default_layout();
        let json = l.to_json().unwrap();
        let l2 = DockLayout::from_json(&json);
        assert_eq!(l2.anchored.len(), 1);
        assert_eq!(l2.anchored[0].0, DockEdge::Right);
        let d = l2.anchored_dock(DockEdge::Right).unwrap();
        assert_eq!(d.groups.len(), 2);
        assert_eq!(d.groups[0].panels, vec![PanelKind::Layers]);
    }

    #[test]
    fn from_json_with_floating() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.detach_group(ga(id.0, 0), 100.0, 200.0);
        let json = l.to_json().unwrap();
        let l2 = DockLayout::from_json(&json);
        assert_eq!(l2.floating.len(), 1);
        assert_eq!(l2.floating[0].x, 100.0);
        assert_eq!(l2.floating[0].y, 200.0);
    }

    #[test]
    fn from_json_invalid_graceful() {
        let l = DockLayout::from_json("not valid json{{{");
        // Should return default layout
        assert_eq!(l.anchored.len(), 1);
        assert_eq!(l.anchored_dock(DockEdge::Right).unwrap().groups.len(), 2);
    }

    #[test]
    fn reset_to_default() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.detach_group(ga(id.0, 0), 50.0, 50.0);
        l.close_panel(pa(id.0, 0, 0));
        assert!(!l.floating.is_empty());
        assert!(!l.hidden_panels.is_empty());
        l.reset_to_default();
        assert!(l.floating.is_empty());
        assert!(l.hidden_panels.is_empty());
        assert_eq!(l.anchored_dock(DockEdge::Right).unwrap().groups.len(), 2);
    }
}
