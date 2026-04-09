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
    /// Add a panel to an existing group's tab bar at a position.
    TabBar { group: GroupAddr, index: usize },
    /// Snap to a screen edge (create or merge into anchored dock).
    Edge(DockEdge),
}

// ---------------------------------------------------------------------------
// DockLayout
// ---------------------------------------------------------------------------

/// Current layout format version. Saved layouts with a different version
/// are rejected and replaced with the default layout.
pub const LAYOUT_VERSION: u32 = 1;

/// Top-level layout: anchored docks on screen edges + floating docks.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DockLayout {
    /// Format version. Must match LAYOUT_VERSION or the layout is rejected.
    #[serde(default)]
    pub version: u32,
    pub name: String,
    pub anchored: Vec<(DockEdge, Dock)>,
    pub floating: Vec<FloatingDock>,
    pub hidden_panels: Vec<PanelKind>,
    pub z_order: Vec<DockId>,
    pub focused_panel: Option<PanelAddr>,
    /// Floating pane positions for toolbar/canvas/dock. `None` for legacy layouts.
    #[serde(default)]
    pub pane_layout: Option<PaneLayout>,
    next_id: usize,
    /// Incremented on every mutation. Used to detect when a save is needed.
    #[serde(skip)]
    generation: u64,
    /// The generation at which we last saved.
    #[serde(skip)]
    saved_generation: u64,
}

/// Application configuration, saved separately from dock layouts.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    /// Name of the active dock layout.
    pub active_layout: String,
    /// Names of all saved dock layouts, in display order.
    pub saved_layouts: Vec<String>,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            active_layout: DEFAULT_LAYOUT_NAME.to_string(),
            saved_layouts: vec![DEFAULT_LAYOUT_NAME.to_string()],
        }
    }
}

impl AppConfig {
    pub const STORAGE_KEY: &'static str = "jas_app_config";

    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }

    pub fn from_json(json: &str) -> Self {
        serde_json::from_str(json).unwrap_or_default()
    }

    /// Ensure a layout name is in the saved list.
    pub fn register_layout(&mut self, name: &str) {
        if !self.saved_layouts.iter().any(|n| n == name) {
            self.saved_layouts.push(name.to_string());
        }
    }
}

/// Default layout name.
pub const DEFAULT_LAYOUT_NAME: &str = "Default";

impl DockLayout {
    // -----------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------

    /// Create the default layout: one Right-anchored dock with two groups.
    pub fn default_layout() -> Self {
        Self::named(DEFAULT_LAYOUT_NAME)
    }

    /// Create the default layout with a custom name.
    pub fn named(name: &str) -> Self {
        Self {
            version: LAYOUT_VERSION,
            name: name.to_string(),
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
            pane_layout: None,
            next_id: 1,
            generation: 0,
            saved_generation: 0,
        }
    }

    /// Bump the generation counter. Call after every layout mutation.
    fn bump(&mut self) {
        self.generation += 1;
    }

    /// True if the layout has been modified since the last save.
    pub fn needs_save(&self) -> bool {
        self.generation != self.saved_generation
    }

    /// Mark the layout as saved (call after writing to storage).
    pub fn mark_saved(&mut self) {
        self.saved_generation = self.generation;
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
        self.bump();
    }

    /// Toggle a group's collapsed state.
    pub fn toggle_group_collapsed(&mut self, addr: GroupAddr) {
        if let Some(d) = self.dock_mut(addr.dock_id) {
            if let Some(g) = d.groups.get_mut(addr.group_idx) {
                g.collapsed = !g.collapsed;
            }
        }
        self.bump();
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
        self.bump();
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
        self.bump();
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
        self.bump();
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
        self.bump();
        Some(id)
    }

    // -----------------------------------------------------------------------
    // Reorder panel within a group
    // -----------------------------------------------------------------------

    /// Reorder a panel within its group. Removes the panel at `from` and
    /// re-inserts at `to` (clamped). Sets `active` to the new position.
    pub fn reorder_panel(&mut self, group: GroupAddr, from: usize, to: usize) {
        if let Some(d) = self.dock_mut(group.dock_id) {
            if let Some(g) = d.groups.get_mut(group.group_idx) {
                if from >= g.panels.len() {
                    return;
                }
                let panel = g.panels.remove(from);
                let to = to.min(g.panels.len());
                g.panels.insert(to, panel);
                g.active = to;
            }
        }
        self.bump();
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
        self.bump();
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
        self.bump();
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
        self.bump();
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
        self.bump();
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
        self.bump();
    }

    /// Set a dock's width. Clamped to [min_width, MAX_DOCK_WIDTH].
    pub fn set_dock_width(&mut self, id: DockId, width: f64) {
        if let Some(d) = self.dock_mut(id) {
            let min = d.min_width;
            d.width = width.clamp(min, MAX_DOCK_WIDTH);
        }
        self.bump();
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
        self.bump();
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
        self.bump();
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
        self.bump();
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
        self.bump();
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
        self.bump();
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
        self.bump();
        Some(fid)
    }

    // -----------------------------------------------------------------------
    // Persistence
    // -----------------------------------------------------------------------

    /// Reset to the default layout, preserving the name.
    pub fn reset_to_default(&mut self) {
        let name = self.name.clone();
        *self = Self::named(&name);
        self.bump();
    }

    /// Serialize the layout to a JSON string.
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }

    /// Deserialize a layout from a JSON string. Returns the default
    /// layout if the JSON is invalid or the version doesn't match.
    pub fn from_json(json: &str) -> Self {
        match serde_json::from_str::<Self>(json) {
            Ok(layout) if layout.version == LAYOUT_VERSION => layout,
            _ => Self::default_layout(),
        }
    }

    /// localStorage key prefix for dock layouts.
    const STORAGE_PREFIX: &'static str = "jas_layout:";

    /// Return the localStorage key for this layout.
    pub fn storage_key(&self) -> String {
        format!("{}{}", Self::STORAGE_PREFIX, self.name)
    }

    /// Return the localStorage key for a named layout.
    pub fn storage_key_for(name: &str) -> String {
        format!("{}{}", Self::STORAGE_PREFIX, name)
    }

    // -----------------------------------------------------------------------
    // Focus & keyboard navigation
    // -----------------------------------------------------------------------

    /// Set the focused panel.
    pub fn set_focused_panel(&mut self, addr: Option<PanelAddr>) {
        self.focused_panel = addr;
    }

    /// Return the focused panel.
    pub fn focused_panel(&self) -> Option<PanelAddr> {
        self.focused_panel
    }

    /// Collect all valid PanelAddrs in a stable order (anchored docks
    /// then floating, by group then panel index).
    fn all_panel_addrs(&self) -> Vec<PanelAddr> {
        let mut addrs = Vec::new();
        for (_, dock) in &self.anchored {
            for (gi, group) in dock.groups.iter().enumerate() {
                for pi in 0..group.panels.len() {
                    addrs.push(PanelAddr {
                        group: GroupAddr { dock_id: dock.id, group_idx: gi },
                        panel_idx: pi,
                    });
                }
            }
        }
        for fd in &self.floating {
            for (gi, group) in fd.dock.groups.iter().enumerate() {
                for pi in 0..group.panels.len() {
                    addrs.push(PanelAddr {
                        group: GroupAddr { dock_id: fd.dock.id, group_idx: gi },
                        panel_idx: pi,
                    });
                }
            }
        }
        addrs
    }

    /// Move focus to the next panel (wraps around).
    pub fn focus_next_panel(&mut self) {
        let addrs = self.all_panel_addrs();
        if addrs.is_empty() {
            self.focused_panel = None;
            return;
        }
        let cur_idx = self.focused_panel
            .and_then(|fp| addrs.iter().position(|a| *a == fp));
        let next = match cur_idx {
            Some(i) => (i + 1) % addrs.len(),
            None => 0,
        };
        self.focused_panel = Some(addrs[next]);
    }

    /// Move focus to the previous panel (wraps around).
    pub fn focus_prev_panel(&mut self) {
        let addrs = self.all_panel_addrs();
        if addrs.is_empty() {
            self.focused_panel = None;
            return;
        }
        let cur_idx = self.focused_panel
            .and_then(|fp| addrs.iter().position(|a| *a == fp));
        let prev = match cur_idx {
            Some(0) => addrs.len() - 1,
            Some(i) => i - 1,
            None => addrs.len() - 1,
        };
        self.focused_panel = Some(addrs[prev]);
    }

    // -----------------------------------------------------------------------
    // Context-sensitive panels
    // -----------------------------------------------------------------------

    /// Suggest which panels are relevant for the current selection.
    /// Always includes Layers; includes Properties when anything is
    /// selected; includes Stroke/Color for shapes; all four for text.
    pub fn panels_for_selection(has_selection: bool, has_text: bool) -> Vec<PanelKind> {
        let mut panels = vec![PanelKind::Layers];
        if has_selection {
            panels.push(PanelKind::Properties);
            panels.push(PanelKind::Color);
            panels.push(PanelKind::Stroke);
        }
        if has_text {
            // All panels relevant for text (already included above)
        }
        panels
    }

    // -----------------------------------------------------------------------
    // Safety
    // -----------------------------------------------------------------------

    /// Clamp all floating docks and panes to be within the viewport.
    pub fn clamp_floating_docks(&mut self, viewport_w: f64, viewport_h: f64) {
        for fd in &mut self.floating {
            let min_visible = 50.0;
            fd.x = fd.x.clamp(-fd.dock.width + min_visible, viewport_w - min_visible);
            fd.y = fd.y.clamp(0.0, viewport_h - min_visible);
        }
        if let Some(ref mut pl) = self.pane_layout {
            pl.clamp_panes(viewport_w, viewport_h);
        }
        self.bump();
    }

    /// Ensure a PaneLayout exists, creating the default if absent.
    pub fn ensure_pane_layout(&mut self, viewport_w: f64, viewport_h: f64) {
        if self.pane_layout.is_none() {
            self.pane_layout = Some(PaneLayout::default_three_pane(viewport_w, viewport_h));
            self.bump();
        }
        // Ensure each pane's config matches its kind (fixes layouts
        // deserialized from old JSON without config fields).
        if let Some(ref mut pl) = self.pane_layout {
            for p in &mut pl.panes {
                let expected = PaneConfig::for_kind(p.kind);
                if p.config.label != expected.label {
                    p.config = expected;
                }
            }
        }
    }

    /// Shorthand access to the pane layout.
    pub fn panes(&self) -> Option<&PaneLayout> {
        self.pane_layout.as_ref()
    }

    /// Mutable access to the pane layout. Marks the layout as dirty
    /// so changes are persisted.
    pub fn panes_mut(&mut self) -> Option<&mut PaneLayout> {
        if self.pane_layout.is_some() {
            self.bump();
        }
        self.pane_layout.as_mut()
    }

    /// Set auto-hide for a dock.
    pub fn set_auto_hide(&mut self, id: DockId, auto_hide: bool) {
        if let Some(d) = self.dock_mut(id) {
            d.auto_hide = auto_hide;
        }
        self.bump();
    }

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
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum TileWidth {
    /// Always this exact width (e.g., Toolbar at 72px).
    Fixed(f64),
    /// Keep the pane's current width (e.g., Dock).
    KeepCurrent,
    /// Fill all remaining space (e.g., Canvas).
    Flex,
}

/// Configuration that drives generic pane management behavior.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaneConfig {
    pub label: String,
    pub min_width: f64,
    pub min_height: f64,
    pub fixed_width: bool,
    pub closable: bool,
    pub collapsible: bool,
    pub maximizable: bool,
    pub tile_order: usize,
    pub tile_width: TileWidth,
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
                closable: true,
                collapsible: false,
                maximizable: false,
                tile_order: 0,
                tile_width: TileWidth::Fixed(DEFAULT_TOOLBAR_WIDTH),
            },
            PaneKind::Canvas => Self {
                label: "Canvas".into(),
                min_width: MIN_CANVAS_WIDTH,
                min_height: MIN_CANVAS_HEIGHT,
                fixed_width: false,
                closable: false,
                collapsible: false,
                maximizable: true,
                tile_order: 1,
                tile_width: TileWidth::Flex,
            },
            PaneKind::Dock => Self {
                label: "Panels".into(),
                min_width: MIN_PANE_DOCK_WIDTH,
                min_height: MIN_PANE_DOCK_HEIGHT,
                fixed_width: false,
                closable: true,
                collapsible: true,
                maximizable: false,
                tile_order: 2,
                tile_width: TileWidth::KeepCurrent,
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
            } else if let SnapTarget::Pane(target_pid, target_edge) = snap.target {
                if target_pid == pane_id {
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

            if !a_fixed {
                if let Some(a) = self.pane_mut(snap.pane) {
                    a.width += clamped;
                }
            }
            if !b_fixed {
                if let Some(b) = self.pane_mut(other_id) {
                    b.x = b_x + clamped;
                    b.width -= clamped;
                }
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

            if !a_fixed {
                if let Some(a) = self.pane_mut(snap.pane) {
                    a.height += clamped;
                }
            }
            if !b_fixed {
                if let Some(b) = self.pane_mut(other_id) {
                    b.y = b_y + clamped;
                    b.height -= clamped;
                }
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
            if s.pane == source_pane && s.edge == source_edge {
                if let SnapTarget::Pane(pid, pe) = s.target {
                    return Some((pid, pe));
                }
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

        // Show all panes and sort by tile_order.
        self.hidden_panes.clear();
        let mut visible: Vec<(PaneId, TileWidth, f64)> = self.panes.iter()
            .map(|p| {
                let current_w = p.width;
                (p.id, p.config.tile_width, current_w)
            })
            .collect();
        // Sort by tile_order from config
        visible.sort_by_key(|&(id, _, _)| {
            self.pane(id).map(|p| p.config.tile_order).unwrap_or(0)
        });
        if visible.is_empty() {
            return;
        }

        // Compute widths: Fixed and KeepCurrent are allocated first, Flex gets the rest.
        let mut fixed_total = 0.0;
        let mut flex_count = 0;
        let widths: Vec<f64> = visible.iter().map(|&(id, tile_w, current_w)| {
            match tile_w {
                TileWidth::Fixed(w) => { fixed_total += w; w }
                TileWidth::KeepCurrent => {
                    let w = collapsed_override
                        .filter(|&(oid, _)| oid == id)
                        .map(|(_, cw)| cw)
                        .unwrap_or(current_w);
                    fixed_total += w;
                    w
                }
                TileWidth::Flex => { flex_count += 1; 0.0 }
            }
        }).collect();
        let flex_each = if flex_count > 0 {
            let min_flex = self.panes.iter()
                .filter(|p| p.config.tile_width == TileWidth::Flex)
                .map(|p| p.config.min_width)
                .fold(0.0_f64, f64::max);
            ((vw - fixed_total) / flex_count as f64).max(min_flex)
        } else {
            0.0
        };
        let widths: Vec<f64> = visible.iter().zip(&widths).map(|(&(_, tile_w, _), &w)| {
            if tile_w == TileWidth::Flex { flex_each } else { w }
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
        for (i, &(id, _, _)) in visible.iter().enumerate() {
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

    /// Hide a pane (close it).
    pub fn hide_pane(&mut self, kind: PaneKind) {
        if !self.hidden_panes.contains(&kind) {
            self.hidden_panes.push(kind);
        }
    }

    /// Show a hidden pane.
    pub fn show_pane(&mut self, kind: PaneKind) {
        self.hidden_panes.retain(|&k| k != kind);
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
            p.width = (p.width * sx).max(min_w);
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
                if (Self::pane_edge_coord(a, EdgeSide::Bottom) - Self::pane_edge_coord(b, EdgeSide::Top)).abs() <= tolerance {
                    if a.x < b.x + b.width && a.x + a.width > b.x {
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

    // -----------------------------------------------------------------------
    // Phase 5: Focus & keyboard navigation
    // -----------------------------------------------------------------------

    #[test]
    fn set_focused_panel() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let addr = pa(id.0, 1, 2);
        l.set_focused_panel(Some(addr));
        assert_eq!(l.focused_panel(), Some(addr));
        l.set_focused_panel(None);
        assert_eq!(l.focused_panel(), None);
    }

    #[test]
    fn focus_next_wraps() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        // Default: 2 groups, [Layers] and [Color, Stroke, Properties] = 4 panels total
        l.set_focused_panel(None);
        l.focus_next_panel();
        // Should focus the first panel (Layers)
        assert_eq!(l.focused_panel(), Some(pa(id.0, 0, 0)));
        // Advance through all 4
        l.focus_next_panel(); // Color
        l.focus_next_panel(); // Stroke
        l.focus_next_panel(); // Properties
        assert_eq!(l.focused_panel(), Some(pa(id.0, 1, 2)));
        // Next should wrap to Layers
        l.focus_next_panel();
        assert_eq!(l.focused_panel(), Some(pa(id.0, 0, 0)));
    }

    #[test]
    fn focus_prev_wraps() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.set_focused_panel(None);
        l.focus_prev_panel();
        // Should focus the last panel (Properties)
        assert_eq!(l.focused_panel(), Some(pa(id.0, 1, 2)));
        l.focus_prev_panel(); // Stroke
        l.focus_prev_panel(); // Color
        l.focus_prev_panel(); // Layers
        assert_eq!(l.focused_panel(), Some(pa(id.0, 0, 0)));
        // Prev should wrap to Properties
        l.focus_prev_panel();
        assert_eq!(l.focused_panel(), Some(pa(id.0, 1, 2)));
    }

    // -----------------------------------------------------------------------
    // Phase 5: Safety
    // -----------------------------------------------------------------------

    #[test]
    fn clamp_floating_within_viewport() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 2000.0, 1500.0).unwrap();
        l.clamp_floating_docks(1000.0, 800.0);
        let fd = l.floating_dock(fid).unwrap();
        assert!(fd.x <= 1000.0 - 50.0);
        assert!(fd.y <= 800.0 - 50.0);
    }

    #[test]
    fn clamp_floating_partially_offscreen() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), -500.0, -100.0).unwrap();
        l.clamp_floating_docks(1000.0, 800.0);
        let fd = l.floating_dock(fid).unwrap();
        // x should be clamped so at least 50px is visible
        let dock_width = fd.dock.width;
        assert!(fd.x >= -dock_width + 50.0);
        assert!(fd.y >= 0.0);
    }

    #[test]
    fn set_auto_hide() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        assert!(!l.dock(id).unwrap().auto_hide);
        l.set_auto_hide(id, true);
        assert!(l.dock(id).unwrap().auto_hide);
        l.set_auto_hide(id, false);
        assert!(!l.dock(id).unwrap().auto_hide);
    }

    // -----------------------------------------------------------------------
    // Reorder panels within a group
    // -----------------------------------------------------------------------

    #[test]
    fn reorder_panel_forward() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        // Group 1: [Color, Stroke, Properties] → move Color to position 2
        l.reorder_panel(ga(id.0, 1), 0, 2);
        let g = &l.dock(id).unwrap().groups[1];
        assert_eq!(g.panels, vec![PanelKind::Stroke, PanelKind::Properties, PanelKind::Color]);
        assert_eq!(g.active, 2); // active follows the moved panel
    }

    #[test]
    fn reorder_panel_backward() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        // Group 1: [Color, Stroke, Properties] → move Properties to position 0
        l.reorder_panel(ga(id.0, 1), 2, 0);
        let g = &l.dock(id).unwrap().groups[1];
        assert_eq!(g.panels, vec![PanelKind::Properties, PanelKind::Color, PanelKind::Stroke]);
        assert_eq!(g.active, 0);
    }

    #[test]
    fn reorder_panel_same_position() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.reorder_panel(ga(id.0, 1), 1, 1);
        let g = &l.dock(id).unwrap().groups[1];
        assert_eq!(g.panels, vec![PanelKind::Color, PanelKind::Stroke, PanelKind::Properties]);
    }

    #[test]
    fn reorder_panel_clamped() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.reorder_panel(ga(id.0, 1), 0, 99);
        let g = &l.dock(id).unwrap().groups[1];
        assert_eq!(g.panels[2], PanelKind::Color); // moved to end
    }

    #[test]
    fn reorder_panel_out_of_bounds() {
        let mut l = DockLayout::default_layout();
        let id = right_dock_id(&l);
        l.reorder_panel(ga(id.0, 1), 99, 0); // no panic
        l.reorder_panel(ga(99, 0), 0, 1);     // no panic
    }

    // -----------------------------------------------------------------------
    // Named layouts & AppConfig
    // -----------------------------------------------------------------------

    #[test]
    fn default_layout_name() {
        let l = DockLayout::default_layout();
        assert_eq!(l.name, "Default");
    }

    #[test]
    fn named_layout() {
        let l = DockLayout::named("My Workspace");
        assert_eq!(l.name, "My Workspace");
        assert_eq!(l.anchored.len(), 1); // same structure as default
    }

    #[test]
    fn storage_key_includes_name() {
        let l = DockLayout::named("Editing");
        assert_eq!(l.storage_key(), "jas_layout:Editing");
    }

    #[test]
    fn storage_key_for_static() {
        assert_eq!(DockLayout::storage_key_for("Drawing"), "jas_layout:Drawing");
    }

    #[test]
    fn reset_preserves_name() {
        let mut l = DockLayout::named("Custom");
        let id = right_dock_id(&l);
        l.detach_group(ga(id.0, 0), 50.0, 50.0);
        assert!(!l.floating.is_empty());
        l.reset_to_default();
        assert_eq!(l.name, "Custom"); // name preserved
        assert!(l.floating.is_empty());
    }

    #[test]
    fn json_round_trip_preserves_name() {
        let l = DockLayout::named("Test Layout");
        let json = l.to_json().unwrap();
        let l2 = DockLayout::from_json(&json);
        assert_eq!(l2.name, "Test Layout");
    }

    #[test]
    fn app_config_default() {
        let c = AppConfig::default();
        assert_eq!(c.active_layout, "Default");
    }

    #[test]
    fn app_config_round_trip() {
        let c = AppConfig { active_layout: "My Layout".to_string(), saved_layouts: vec!["My Layout".to_string()] };
        let json = c.to_json().unwrap();
        let c2 = AppConfig::from_json(&json);
        assert_eq!(c2.active_layout, "My Layout");
    }

    #[test]
    fn app_config_invalid_json() {
        let c = AppConfig::from_json("garbage{{{");
        assert_eq!(c.active_layout, "Default"); // falls back to default
    }

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
        assert!(tc.closable);
        assert!(!tc.maximizable);

        let cc = PaneConfig::for_kind(PaneKind::Canvas);
        assert_eq!(cc.min_width, MIN_CANVAS_WIDTH);
        assert!(!cc.fixed_width);
        assert!(!cc.closable);
        assert!(cc.maximizable);

        let dc = PaneConfig::for_kind(PaneKind::Dock);
        assert_eq!(dc.min_width, MIN_PANE_DOCK_WIDTH);
        assert!(!dc.fixed_width);
        assert!(dc.closable);
        assert!(dc.collapsible);
    }

    // -----------------------------------------------------------------------
    // DockLayout + PaneLayout integration
    // -----------------------------------------------------------------------

    #[test]
    fn dock_layout_default_has_no_pane_layout() {
        let l = DockLayout::default_layout();
        assert!(l.pane_layout.is_none());
    }

    #[test]
    fn ensure_pane_layout_creates_if_none() {
        let mut l = DockLayout::default_layout();
        assert!(l.pane_layout.is_none());
        l.ensure_pane_layout(1000.0, 700.0);
        assert!(l.pane_layout.is_some());
        assert_eq!(l.panes().unwrap().panes.len(), 3);
    }

    #[test]
    fn ensure_pane_layout_noop_if_present() {
        let mut l = DockLayout::default_layout();
        l.ensure_pane_layout(1000.0, 700.0);
        let gen_before = l.generation;
        l.ensure_pane_layout(1000.0, 700.0);
        // Should not bump generation again
        assert_eq!(l.generation, gen_before);
    }

    #[test]
    fn reset_to_default_clears_pane_layout() {
        let mut l = DockLayout::default_layout();
        l.ensure_pane_layout(1000.0, 700.0);
        assert!(l.pane_layout.is_some());
        l.reset_to_default();
        assert!(l.pane_layout.is_none());
    }

    #[test]
    fn panes_accessors() {
        let mut l = DockLayout::default_layout();
        assert!(l.panes().is_none());
        assert!(l.panes_mut().is_none());
        l.ensure_pane_layout(1000.0, 700.0);
        assert!(l.panes().is_some());
        assert!(l.panes_mut().is_some());
    }

    #[test]
    fn serde_backwards_compat_no_pane_layout() {
        // Simulate old JSON without pane_layout field
        let mut l = DockLayout::default_layout();
        l.ensure_pane_layout(1000.0, 700.0);
        let json = l.to_json().unwrap();
        // Remove pane_layout from JSON to simulate old format
        let mut val: serde_json::Value = serde_json::from_str(&json).unwrap();
        val.as_object_mut().unwrap().remove("pane_layout");
        let old_json = serde_json::to_string(&val).unwrap();
        let restored = DockLayout::from_json(&old_json);
        assert!(restored.pane_layout.is_none());
    }

    #[test]
    fn serde_round_trip_with_pane_layout() {
        let mut l = DockLayout::default_layout();
        l.ensure_pane_layout(1000.0, 700.0);
        let json = l.to_json().unwrap();
        let restored = DockLayout::from_json(&json);
        assert!(restored.pane_layout.is_some());
        let pl = restored.pane_layout.unwrap();
        assert_eq!(pl.panes.len(), 3);
        assert_eq!(pl.snaps.len(), 10);
        assert!((pl.viewport_width - 1000.0).abs() < 0.001);
        // Config should round-trip
        let toolbar = pl.pane_by_kind(PaneKind::Toolbar).unwrap();
        assert!(toolbar.config.fixed_width);
        assert_eq!(toolbar.config.label, "Tools");
    }

    #[test]
    fn serde_pane_config_backwards_compat() {
        // Simulate old JSON without config field on panes
        let mut l = DockLayout::default_layout();
        l.ensure_pane_layout(1000.0, 700.0);
        let json = l.to_json().unwrap();
        // Remove config fields from panes to simulate old format
        let mut val: serde_json::Value = serde_json::from_str(&json).unwrap();
        if let Some(pl) = val.get_mut("pane_layout").and_then(|v| v.as_object_mut()) {
            if let Some(panes) = pl.get_mut("panes").and_then(|v| v.as_array_mut()) {
                for pane in panes {
                    pane.as_object_mut().unwrap().remove("config");
                }
            }
        }
        let old_json = serde_json::to_string(&val).unwrap();
        let restored = DockLayout::from_json(&old_json);
        let pl = restored.pane_layout.unwrap();
        // Panes should deserialize with default config (Canvas defaults)
        assert_eq!(pl.panes.len(), 3);
        // Default config is Canvas — check it applied
        let toolbar = pl.pane_by_kind(PaneKind::Toolbar).unwrap();
        assert_eq!(toolbar.config.label, "Canvas"); // default, not "Tools"
    }

    #[test]
    fn clamp_floating_docks_also_clamps_panes() {
        let mut l = DockLayout::default_layout();
        l.ensure_pane_layout(1000.0, 700.0);
        // Push a pane off-screen
        let canvas_id = l.panes().unwrap().pane_by_kind(PaneKind::Canvas).unwrap().id;
        l.panes_mut().unwrap().set_pane_position(canvas_id, 5000.0, 5000.0);
        l.clamp_floating_docks(1000.0, 700.0);
        let p = l.panes().unwrap().pane(canvas_id).unwrap();
        assert!(p.x <= 1000.0 - MIN_PANE_VISIBLE);
        assert!(p.y <= 700.0 - MIN_PANE_VISIBLE);
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
}
