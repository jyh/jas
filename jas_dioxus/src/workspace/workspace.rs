//! Workspace layout infrastructure.
//!
//! A [`WorkspaceLayout`] manages the overall window layout: pane positions
//! and snap constraints for the toolbar, canvas, and dock panes, plus
//! anchored and floating docks with panel groups. Each [`Dock`] contains
//! a vertical list of [`PanelGroup`]s with tabbed [`PanelKind`] entries.
//!
//! This module contains only pure data types and state operations — no
//! rendering code.

use serde::{Serialize, Deserialize};

pub use super::pane::*;

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
    Swatches,
    Stroke,
    Properties,
    Character,
    Paragraph,
    Artboards,
}

impl PanelKind {
    /// All panel kinds, for iteration.
    pub const ALL: &[PanelKind] = &[
        Self::Layers,
        Self::Color,
        Self::Swatches,
        Self::Stroke,
        Self::Properties,
        Self::Character,
        Self::Paragraph,
        Self::Artboards,
    ];
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

    /// Reconstruct a Dock from all fields (for test JSON deserialization).
    pub fn from_parts(
        id: DockId, groups: Vec<PanelGroup>, collapsed: bool,
        auto_hide: bool, width: f64, min_width: f64,
    ) -> Self {
        Self { id, groups, collapsed, auto_hide, width, min_width }
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
// WorkspaceLayout
// ---------------------------------------------------------------------------

/// Current layout format version. Saved layouts with a different version
/// are rejected and replaced with the default layout.
pub const LAYOUT_VERSION: u32 = 3;

/// Top-level layout: anchored docks on screen edges + floating docks.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceLayout {
    /// Format version. Must match LAYOUT_VERSION or the layout is rejected.
    #[serde(default)]
    pub version: u32,
    pub name: String,
    pub anchored: Vec<(DockEdge, Dock)>,
    pub floating: Vec<FloatingDock>,
    pub hidden_panels: Vec<PanelKind>,
    /// Remembered group address per hidden panel, so reopening restores the
    /// panel to its prior group. Entries are added by `close_panel` and
    /// consumed by `show_panel`.
    #[serde(default)]
    pub hidden_panel_positions: Vec<(PanelKind, GroupAddr)>,
    pub z_order: Vec<DockId>,
    pub focused_panel: Option<PanelAddr>,
    /// Active appearance name (e.g. "dark_gray", "light_gray").
    #[serde(default = "default_appearance")]
    pub appearance: String,
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

/// Default appearance name (serde default function).
fn default_appearance() -> String { "dark_gray".into() }

/// System workspace name — the always-active working copy.
pub const WORKSPACE_LAYOUT_NAME: &str = "Workspace";

impl WorkspaceLayout {
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
                        PanelGroup::new(vec![PanelKind::Color, PanelKind::Swatches]),
                        PanelGroup::new(vec![PanelKind::Character, PanelKind::Paragraph]),
                        PanelGroup::new(vec![PanelKind::Stroke, PanelKind::Properties]),
                        PanelGroup::new(vec![PanelKind::Artboards, PanelKind::Layers]),
                    ],
                    DEFAULT_DOCK_WIDTH,
                ),
            )],
            floating: vec![],
            hidden_panels: vec![],
            hidden_panel_positions: vec![],
            z_order: vec![],
            focused_panel: None,
            appearance: default_appearance(),
            pane_layout: None,
            next_id: 1,
            generation: 0,
            saved_generation: 0,
        }
    }

    /// Return the next dock id counter (for test JSON serialization).
    pub fn next_id(&self) -> usize {
        self.next_id
    }

    /// Reconstruct a WorkspaceLayout from all fields (for test JSON deserialization).
    pub fn from_parts(
        version: u32,
        name: String,
        anchored: Vec<(DockEdge, Dock)>,
        floating: Vec<FloatingDock>,
        hidden_panels: Vec<PanelKind>,
        z_order: Vec<DockId>,
        focused_panel: Option<PanelAddr>,
        appearance: String,
        pane_layout: Option<PaneLayout>,
        next_id: usize,
    ) -> Self {
        Self {
            version, name, anchored, floating, hidden_panels, z_order,
            focused_panel, appearance, pane_layout, next_id,
            hidden_panel_positions: vec![],
            generation: 0, saved_generation: 0,
        }
    }

    /// Bump the generation counter. Call after every layout mutation.
    pub fn bump(&mut self) {
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
        if let Some(d) = self.dock_mut(addr.dock_id)
            && let Some(g) = d.groups.get_mut(addr.group_idx) {
                g.collapsed = !g.collapsed;
            }
        self.bump();
    }

    // -----------------------------------------------------------------------
    // Active panel
    // -----------------------------------------------------------------------

    /// Set the active tab within a panel group.
    pub fn set_active_panel(&mut self, addr: PanelAddr) {
        if let Some(d) = self.dock_mut(addr.group.dock_id)
            && let Some(g) = d.groups.get_mut(addr.group.group_idx)
                && addr.panel_idx < g.panels.len() {
                    g.active = addr.panel_idx;
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
        if let Some(d) = self.dock_mut(group.dock_id)
            && let Some(g) = d.groups.get_mut(group.group_idx) {
                if from >= g.panels.len() {
                    return;
                }
                let panel = g.panels.remove(from);
                let to = to.min(g.panels.len());
                g.panels.insert(to, panel);
                g.active = to;
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
                if let Some(src_dock) = self.dock_mut(from.group.dock_id)
                    && let Some(src_group) = src_dock.groups.get_mut(from.group.group_idx) {
                        let idx = from.panel_idx.min(src_group.panels.len());
                        src_group.panels.insert(idx, panel);
                    }
                return;
            }
        } else {
            // Target dock not found — put panel back.
            if let Some(src_dock) = self.dock_mut(from.group.dock_id)
                && let Some(src_group) = src_dock.groups.get_mut(from.group.group_idx) {
                    let idx = from.panel_idx.min(src_group.panels.len());
                    src_group.panels.insert(idx, panel);
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
            if let Some(src_dock) = self.dock_mut(from.group.dock_id)
                && let Some(src_group) = src_dock.groups.get_mut(from.group.group_idx) {
                    let idx = from.panel_idx.min(src_group.panels.len());
                    src_group.panels.insert(idx, panel);
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
        if let Some(d) = self.dock_mut(addr.dock_id)
            && let Some(g) = d.groups.get_mut(addr.group_idx) {
                g.height = Some(height.max(MIN_GROUP_HEIGHT));
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
        self.hidden_panel_positions.retain(|(k, _)| *k != panel);
        self.hidden_panel_positions.push((panel, addr.group));
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
        // Try to restore to the group the panel was in when it was closed.
        let saved_group = self.hidden_panel_positions
            .iter()
            .position(|(k, _)| *k == kind)
            .map(|i| self.hidden_panel_positions.remove(i).1);
        if let Some(group_addr) = saved_group {
            if let Some(dock) = self.dock_mut(group_addr.dock_id) {
                if let Some(group) = dock.groups.get_mut(group_addr.group_idx) {
                    group.panels.push(kind);
                    group.active = group.panels.len() - 1;
                    self.bump();
                    return;
                }
            }
        }
        // Fallback: first anchored dock's first group.
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
        PanelKind::ALL.iter().map(|&k| (k, self.is_panel_visible(k))).collect()
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

    /// Try to deserialize a layout from a JSON string. Returns None
    /// if the JSON is invalid or the version doesn't match.
    pub fn try_from_json(json: &str) -> Option<Self> {
        match serde_json::from_str::<Self>(json) {
            Ok(layout) if layout.version == LAYOUT_VERSION => Some(layout),
            _ => None,
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
            panels.push(PanelKind::Swatches);
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
        // Always sync PaneConfig to canonical values for each kind.
        if let Some(ref mut pl) = self.pane_layout {
            for p in &mut pl.panes {
                p.config = PaneConfig::for_kind(p.kind);
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

    fn right_dock_id(layout: &WorkspaceLayout) -> DockId {
        layout.anchored_dock(DockEdge::Right).unwrap().id
    }

    /// Find the group index in `dock_id` that contains `kind`, or panic.
    /// Use this instead of hardcoding indices so tests stay robust as
    /// the default layout gains or re-orders panels.
    fn group_of(layout: &WorkspaceLayout, dock_id: DockId, kind: PanelKind) -> usize {
        layout
            .dock(dock_id)
            .expect("dock exists")
            .groups
            .iter()
            .position(|g| g.panels.contains(&kind))
            .unwrap_or_else(|| panic!("no group contains {:?}", kind))
    }

    /// Find the (group_idx, panel_idx) of `kind` in `dock_id`, or panic.
    fn panel_of(
        layout: &WorkspaceLayout,
        dock_id: DockId,
        kind: PanelKind,
    ) -> (usize, usize) {
        let dock = layout.dock(dock_id).expect("dock exists");
        for (gi, g) in dock.groups.iter().enumerate() {
            if let Some(pi) = g.panels.iter().position(|&p| p == kind) {
                return (gi, pi);
            }
        }
        panic!("no panel {:?} found", kind);
    }

    // -----------------------------------------------------------------------
    // Layout & lookup
    // -----------------------------------------------------------------------

    #[test]
    fn default_layout_one_anchored_right() {
        let l = WorkspaceLayout::default_layout();
        assert_eq!(l.anchored.len(), 1);
        assert_eq!(l.anchored[0].0, DockEdge::Right);
        assert!(l.floating.is_empty());
    }

    #[test]
    fn default_layout_contains_each_panel_kind() {
        // Verify the default layout contains each expected panel kind
        // somewhere, without pinning positions (layouts evolve as
        // panels are added).
        let l = WorkspaceLayout::default_layout();
        let d = l.anchored_dock(DockEdge::Right).unwrap();
        let all: Vec<PanelKind> = d.groups.iter().flat_map(|g| g.panels.clone()).collect();
        for &kind in &[
            PanelKind::Color,
            PanelKind::Swatches,
            PanelKind::Character,
            PanelKind::Stroke,
            PanelKind::Properties,
            PanelKind::Layers,
        ] {
            assert!(all.contains(&kind), "default layout missing {:?}", kind);
        }
    }

    #[test]
    fn default_not_collapsed() {
        let l = WorkspaceLayout::default_layout();
        let d = l.anchored_dock(DockEdge::Right).unwrap();
        assert!(!d.collapsed);
        for g in &d.groups {
            assert!(!g.collapsed);
        }
    }

    #[test]
    fn default_dock_width() {
        let l = WorkspaceLayout::default_layout();
        let d = l.anchored_dock(DockEdge::Right).unwrap();
        assert_eq!(d.width, DEFAULT_DOCK_WIDTH);
    }

    #[test]
    fn dock_lookup_anchored() {
        let l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        assert!(l.dock(id).is_some());
    }

    #[test]
    fn dock_lookup_floating() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 100.0, 100.0).unwrap();
        assert!(l.dock(fid).is_some());
        assert!(l.floating_dock(fid).is_some());
    }

    #[test]
    fn dock_lookup_invalid() {
        let l = WorkspaceLayout::default_layout();
        assert!(l.dock(DockId(99)).is_none());
    }

    #[test]
    fn anchored_dock_by_edge() {
        let l = WorkspaceLayout::default_layout();
        assert!(l.anchored_dock(DockEdge::Right).is_some());
        assert!(l.anchored_dock(DockEdge::Left).is_none());
        assert!(l.anchored_dock(DockEdge::Bottom).is_none());
    }

    // -----------------------------------------------------------------------
    // Toggle / active
    // -----------------------------------------------------------------------

    #[test]
    fn toggle_dock_collapsed() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        assert!(!l.dock(id).unwrap().collapsed);
        l.toggle_dock_collapsed(id);
        assert!(l.dock(id).unwrap().collapsed);
        l.toggle_dock_collapsed(id);
        assert!(!l.dock(id).unwrap().collapsed);
    }

    #[test]
    fn toggle_group_collapsed() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        l.toggle_group_collapsed(ga(id.0, 0));
        assert!(l.dock(id).unwrap().groups[0].collapsed);
        assert!(!l.dock(id).unwrap().groups[1].collapsed);
        l.toggle_group_collapsed(ga(id.0, 0));
        assert!(!l.dock(id).unwrap().groups[0].collapsed);
    }

    #[test]
    fn toggle_group_out_of_bounds() {
        let mut l = WorkspaceLayout::default_layout();
        l.toggle_group_collapsed(ga(0, 99)); // no panic
        l.toggle_group_collapsed(ga(99, 0)); // no panic
    }

    #[test]
    fn set_active_panel() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        // Use any 2-panel group; Swatches shares its group with Color.
        let g = group_of(&l, id, PanelKind::Swatches);
        l.set_active_panel(pa(id.0, g, 1));
        assert_eq!(l.dock(id).unwrap().groups[g].active, 1);
    }

    #[test]
    fn set_active_panel_out_of_bounds() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let g = group_of(&l, id, PanelKind::Swatches);
        l.set_active_panel(pa(id.0, g, 99)); // invalid panel
        assert_eq!(l.dock(id).unwrap().groups[g].active, 0);
        l.set_active_panel(pa(id.0, 99, 0)); // invalid group
        l.set_active_panel(pa(99, 0, 0));     // invalid dock
    }

    // -----------------------------------------------------------------------
    // Move group within dock
    //
    // Earlier tests pinned post-move panel contents at specific group
    // indices (`groups[0].panels == [Stroke, Properties]` etc.); that
    // was brittle to every default-layout addition. The behavior is
    // now covered via reordering/preserving-state assertions that
    // don't hardcode the initial order.
    // -----------------------------------------------------------------------

    #[test]
    fn move_group_swap_preserves_all_panels() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let before: Vec<PanelKind> = l.dock(id).unwrap().groups.iter()
            .flat_map(|g| g.panels.clone()).collect();
        l.move_group_within_dock(id, 0, 1);
        let after: Vec<PanelKind> = l.dock(id).unwrap().groups.iter()
            .flat_map(|g| g.panels.clone()).collect();
        // Same panel set; reordering shuffles positions but no panel vanishes.
        let mut b = before.clone(); b.sort_by_key(|k| format!("{:?}", k));
        let mut a = after.clone(); a.sort_by_key(|k| format!("{:?}", k));
        assert_eq!(b, a);
    }

    #[test]
    fn move_group_out_of_bounds() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let before_len = l.dock(id).unwrap().groups.len();
        l.move_group_within_dock(id, 99, 0); // no panic
        assert_eq!(l.dock(id).unwrap().groups.len(), before_len);
    }

    #[test]
    fn move_group_preserves_state() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        // Use the Properties group by kind; mark it active=1 (Properties)
        // and collapsed, then move it to position 0, and verify state
        // travels with it.
        let g_prop = group_of(&l, id, PanelKind::Properties);
        l.dock_mut(id).unwrap().groups[g_prop].active = 1;
        l.dock_mut(id).unwrap().groups[g_prop].collapsed = true;
        l.move_group_within_dock(id, g_prop, 0);
        let g0 = &l.dock(id).unwrap().groups[0];
        assert!(g0.panels.contains(&PanelKind::Properties));
        assert_eq!(g0.active, 1);
        assert!(g0.collapsed);
    }

    // -----------------------------------------------------------------------
    // Move group between docks
    // -----------------------------------------------------------------------

    #[test]
    fn move_group_between_docks() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let before = l.dock(id).unwrap().groups.len();
        let fid = l.detach_group(ga(id.0, 0), 50.0, 50.0).unwrap();
        // After detach, anchored lost one group. Move another group
        // from anchored to the floating dock.
        let anchored_after_detach = l.dock(id).unwrap().groups.len();
        assert_eq!(anchored_after_detach, before - 1);
        l.move_group_to_dock(ga(id.0, 0), fid, 1);
        assert_eq!(l.dock(id).unwrap().groups.len(), anchored_after_detach - 1);
        assert_eq!(l.dock(fid).unwrap().groups.len(), 2);
    }

    #[test]
    fn move_group_inserts_at_position() {
        // Detach two groups so the floating dock f2 has a known shape
        // (the second-detached group). Then move f1's sole group to
        // f2 at position 0 and verify it goes BEFORE f2's original
        // group.
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let f1 = l.detach_group(ga(id.0, 0), 10.0, 10.0).unwrap();
        let f2 = l.detach_group(ga(id.0, 0), 20.0, 20.0).unwrap();
        let f1_panels = l.dock(f1).unwrap().groups[0].panels.clone();
        let f2_panels = l.dock(f2).unwrap().groups[0].panels.clone();
        l.move_group_to_dock(ga(f1.0, 0), f2, 0);
        let d = l.dock(f2).unwrap();
        assert_eq!(d.groups[0].panels, f1_panels);
        assert_eq!(d.groups[1].panels, f2_panels);
        assert!(l.dock(f1).is_none());
    }

    #[test]
    fn move_group_same_dock_is_reorder() {
        // Moving a group to a later position swaps its panels with
        // whichever group was there, without losing panels from the
        // dock as a whole.
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let all_panels_before: Vec<PanelKind> = l.dock(id).unwrap().groups.iter()
            .flat_map(|g| g.panels.clone()).collect();
        let g0_panels_before = l.dock(id).unwrap().groups[0].panels.clone();
        let g1_panels_before = l.dock(id).unwrap().groups[1].panels.clone();
        l.move_group_to_dock(ga(id.0, 0), id, 1);
        let d = l.dock(id).unwrap();
        assert_eq!(d.groups[0].panels, g1_panels_before);
        assert_eq!(d.groups[1].panels, g0_panels_before);
        let all_panels_after: Vec<PanelKind> = d.groups.iter()
            .flat_map(|g| g.panels.clone()).collect();
        let mut a = all_panels_before.clone(); a.sort_by_key(|k| format!("{:?}", k));
        let mut b = all_panels_after.clone(); b.sort_by_key(|k| format!("{:?}", k));
        assert_eq!(a, b);
    }

    #[test]
    fn move_group_invalid_source() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let before = l.dock(id).unwrap().groups.len();
        l.move_group_to_dock(ga(id.0, 99), id, 0); // no panic
        assert_eq!(l.dock(id).unwrap().groups.len(), before);
    }

    #[test]
    fn move_group_invalid_target() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let before = l.dock(id).unwrap().groups.len();
        l.move_group_to_dock(ga(id.0, 0), DockId(99), 0);
        // Group should be put back — source unchanged.
        assert_eq!(l.dock(id).unwrap().groups.len(), before);
    }

    // -----------------------------------------------------------------------
    // Detach group
    // -----------------------------------------------------------------------

    #[test]
    fn detach_group_creates_floating() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let before_len = l.dock(id).unwrap().groups.len();
        let detached_panels = l.dock(id).unwrap().groups[0].panels.clone();
        let fid = l.detach_group(ga(id.0, 0), 100.0, 200.0).unwrap();
        assert_eq!(l.dock(fid).unwrap().groups[0].panels, detached_panels);
        assert_eq!(l.dock(id).unwrap().groups.len(), before_len - 1);
    }

    #[test]
    fn detach_group_position() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 100.0, 200.0).unwrap();
        let fd = l.floating_dock(fid).unwrap();
        assert_eq!(fd.x, 100.0);
        assert_eq!(fd.y, 200.0);
    }

    #[test]
    fn detach_group_unique_ids() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let f1 = l.detach_group(ga(id.0, 0), 10.0, 10.0).unwrap();
        let f2 = l.detach_group(ga(id.0, 0), 20.0, 20.0).unwrap();
        assert_ne!(f1, f2);
    }

    #[test]
    fn detach_last_group_floating_removes_dock() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let f1 = l.detach_group(ga(id.0, 0), 10.0, 10.0).unwrap();
        // f1 has one group. Detach it elsewhere.
        let _f2 = l.detach_group(ga(f1.0, 0), 20.0, 20.0).unwrap();
        // f1 should be removed (empty floating dock)
        assert!(l.dock(f1).is_none());
    }

    #[test]
    fn detach_last_group_anchored_keeps_dock() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        // Repeatedly detach group 0 until the anchored dock is empty.
        while !l.dock(id).unwrap().groups.is_empty() {
            l.detach_group(ga(id.0, 0), 10.0, 10.0);
        }
        // Anchored dock should still exist even with no groups
        assert!(l.dock(id).is_some());
        assert!(l.dock(id).unwrap().groups.is_empty());
    }

    // -----------------------------------------------------------------------
    // Move panel
    // -----------------------------------------------------------------------

    #[test]
    fn move_panel_same_dock() {
        // Move Stroke (in whatever group hosts it) into the Color group;
        // verify Stroke ends up in the Color group and is no longer in
        // its source group.
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let (sg, spi) = panel_of(&l, id, PanelKind::Stroke);
        let cg = group_of(&l, id, PanelKind::Color);
        l.move_panel_to_group(pa(id.0, sg, spi), ga(id.0, cg));
        let d = l.dock(id).unwrap();
        assert!(d.groups[cg].panels.contains(&PanelKind::Stroke));
        // Source group either lost Stroke or was removed entirely if it
        // was Stroke's only panel.
        if d.groups.len() > sg {
            assert!(!d.groups[sg].panels.contains(&PanelKind::Stroke));
        }
    }

    #[test]
    fn move_panel_becomes_active() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let (sg, spi) = panel_of(&l, id, PanelKind::Stroke);
        let cg = group_of(&l, id, PanelKind::Color);
        let cg_len_before = l.dock(id).unwrap().groups[cg].panels.len();
        l.move_panel_to_group(pa(id.0, sg, spi), ga(id.0, cg));
        // Destination's active should point at the newly added panel
        // (which sits at the end of the group's panel list).
        let cg_now = group_of(&l, id, PanelKind::Stroke);
        assert_eq!(l.dock(id).unwrap().groups[cg_now].active, cg_len_before);
    }

    #[test]
    fn move_panel_cross_dock() {
        // Detach Color's group to create a floating dock, then move
        // Stroke from the anchored dock into the floating group.
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let color_g = group_of(&l, id, PanelKind::Color);
        let fid = l.detach_group(ga(id.0, color_g), 50.0, 50.0).unwrap();
        let (sg, spi) = panel_of(&l, id, PanelKind::Stroke);
        l.move_panel_to_group(pa(id.0, sg, spi), ga(fid.0, 0));
        assert!(l.dock(fid).unwrap().groups[0].panels.contains(&PanelKind::Stroke));
        // Anchored no longer has Stroke anywhere
        let anchored_has_stroke = l.dock(id).unwrap().groups.iter()
            .any(|g| g.panels.contains(&PanelKind::Stroke));
        assert!(!anchored_has_stroke);
    }

    #[test]
    fn move_last_panel_removes_group() {
        // Isolate Layers into its own group (by pulling out its group-
        // mate Artboards first), then move Layers to the Color group
        // and verify the now-empty source group is removed.
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let (ag, api) = panel_of(&l, id, PanelKind::Artboards);
        l.detach_panel(pa(id.0, ag, api), 0.0, 0.0);
        let before = l.dock(id).unwrap().groups.len();
        let (lg, lpi) = panel_of(&l, id, PanelKind::Layers);
        let cg = group_of(&l, id, PanelKind::Color);
        l.move_panel_to_group(pa(id.0, lg, lpi), ga(id.0, cg));
        let d = l.dock(id).unwrap();
        assert_eq!(d.groups.len(), before - 1);
        let layers_still_present = d.groups.iter()
            .any(|g| g.panels.contains(&PanelKind::Layers));
        assert!(layers_still_present);
    }

    #[test]
    fn move_last_panel_removes_floating() {
        // Detach any group into a floating dock, reduce it to a single
        // panel, then move that panel back; the empty floating dock is
        // removed.
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 50.0, 50.0).unwrap();
        while l.dock(fid).unwrap().groups[0].panels.len() > 1 {
            l.detach_panel(pa(fid.0, 0, 0), 0.0, 0.0);
        }
        // Destination: any surviving anchored group (Stroke is still
        // in the anchored dock after we detached group 0).
        let sg = group_of(&l, id, PanelKind::Stroke);
        l.move_panel_to_group(pa(fid.0, 0, 0), ga(id.0, sg));
        assert!(l.dock(fid).is_none());
    }

    #[test]
    fn move_panel_clamps_active() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        // Use the Properties group (2 panels, Stroke+Properties) and
        // mark active=1 (Properties). Remove Properties and observe
        // active clamps to 0.
        let pg = group_of(&l, id, PanelKind::Properties);
        let cg = group_of(&l, id, PanelKind::Color);
        l.dock_mut(id).unwrap().groups[pg].active = 1;
        let (_, ppi) = panel_of(&l, id, PanelKind::Properties);
        l.move_panel_to_group(pa(id.0, pg, ppi), ga(id.0, cg));
        assert!(l.dock(id).unwrap().groups[pg].active == 0);
    }

    #[test]
    fn move_panel_invalid_source() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        l.move_panel_to_group(pa(id.0, 0, 99), ga(id.0, 0)); // no panic
        l.move_panel_to_group(pa(99, 0, 0), ga(id.0, 0));    // no panic
    }

    #[test]
    fn move_panel_invalid_target() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let pg = group_of(&l, id, PanelKind::Properties);
        let before = l.dock(id).unwrap().groups[pg].panels.len();
        l.move_panel_to_group(pa(id.0, pg, 0), ga(99, 0));
        // Panel should be put back — group unchanged.
        assert_eq!(l.dock(id).unwrap().groups[pg].panels.len(), before);
    }

    // -----------------------------------------------------------------------
    // Insert panel as new group
    // -----------------------------------------------------------------------

    #[test]
    fn insert_panel_creates_group() {
        // Pull Stroke out into a brand-new group at position 0, leaving
        // a dock whose Stroke appears alone at index 0 and whose total
        // group count is unchanged (source group still has Properties).
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let before = l.dock(id).unwrap().groups.len();
        let (sg, spi) = panel_of(&l, id, PanelKind::Stroke);
        l.insert_panel_as_new_group(pa(id.0, sg, spi), id, 0);
        let d = l.dock(id).unwrap();
        assert_eq!(d.groups.len(), before + 1);
        assert_eq!(d.groups[0].panels, vec![PanelKind::Stroke]);
    }

    #[test]
    fn insert_panel_cleans_source() {
        // Isolate Layers into a single-panel group (by pulling its
        // group-mate Artboards out first). Then insert Layers as its
        // own new group at the end — the original single-panel group
        // should be cleaned up (net count unchanged) and Layers should
        // sit in the last group by itself.
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let (ag, api) = panel_of(&l, id, PanelKind::Artboards);
        l.detach_panel(pa(id.0, ag, api), 0.0, 0.0);
        let before = l.dock(id).unwrap().groups.len();
        let (lg, lpi) = panel_of(&l, id, PanelKind::Layers);
        l.insert_panel_as_new_group(pa(id.0, lg, lpi), id, 99);
        let d = l.dock(id).unwrap();
        assert_eq!(d.groups.len(), before);
        assert_eq!(d.groups[before - 1].panels, vec![PanelKind::Layers]);
    }

    #[test]
    fn insert_panel_invalid() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let before = l.dock(id).unwrap().groups.len();
        l.insert_panel_as_new_group(pa(id.0, 0, 99), id, 0); // no panic
        l.insert_panel_as_new_group(pa(99, 0, 0), id, 0);    // no panic
        assert_eq!(l.dock(id).unwrap().groups.len(), before);
    }

    // -----------------------------------------------------------------------
    // Detach panel
    // -----------------------------------------------------------------------

    #[test]
    fn detach_panel_creates_floating() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let (sg, spi) = panel_of(&l, id, PanelKind::Stroke);
        let fid = l.detach_panel(pa(id.0, sg, spi), 300.0, 150.0).unwrap();
        assert_eq!(l.dock(fid).unwrap().groups[0].panels, vec![PanelKind::Stroke]);
        // Source group still has Properties but no longer Stroke.
        let sg_now = group_of(&l, id, PanelKind::Properties);
        assert!(!l.dock(id).unwrap().groups[sg_now].panels.contains(&PanelKind::Stroke));
    }

    #[test]
    fn detach_panel_position() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let (sg, spi) = panel_of(&l, id, PanelKind::Stroke);
        let fid = l.detach_panel(pa(id.0, sg, spi), 300.0, 150.0).unwrap();
        let fd = l.floating_dock(fid).unwrap();
        assert_eq!(fd.x, 300.0);
        assert_eq!(fd.y, 150.0);
    }

    #[test]
    fn detach_panel_last_removes_group() {
        // Isolate any anchored group to a single panel by pulling the
        // others off, then detach that last panel: the group should
        // disappear.
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        // Pull Artboards out first so Layers stands alone in its group.
        let (ag, api) = panel_of(&l, id, PanelKind::Artboards);
        l.detach_panel(pa(id.0, ag, api), 0.0, 0.0);
        let before = l.dock(id).unwrap().groups.len();
        let (lg, lpi) = panel_of(&l, id, PanelKind::Layers);
        l.detach_panel(pa(id.0, lg, lpi), 50.0, 50.0);
        assert_eq!(l.dock(id).unwrap().groups.len(), before - 1);
    }

    #[test]
    fn detach_panel_last_removes_floating() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        // Detach any group into a floating dock; then reduce it to a
        // single panel; detaching that panel should remove the floating
        // dock entirely.
        let fid = l.detach_group(ga(id.0, 0), 50.0, 50.0).unwrap();
        while l.dock(fid).unwrap().groups[0].panels.len() > 1 {
            l.detach_panel(pa(fid.0, 0, 0), 0.0, 0.0);
        }
        let _f2 = l.detach_panel(pa(fid.0, 0, 0), 100.0, 100.0);
        assert!(l.dock(fid).is_none());
    }

    // -----------------------------------------------------------------------
    // Floating position
    // -----------------------------------------------------------------------

    #[test]
    fn set_floating_position() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 10.0, 10.0).unwrap();
        l.set_floating_position(fid, 200.0, 300.0);
        let fd = l.floating_dock(fid).unwrap();
        assert_eq!(fd.x, 200.0);
        assert_eq!(fd.y, 300.0);
    }

    #[test]
    fn set_position_anchored_ignored() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        l.set_floating_position(id, 999.0, 999.0); // no-op, no panic
    }

    #[test]
    fn set_position_invalid_id() {
        let mut l = WorkspaceLayout::default_layout();
        l.set_floating_position(DockId(99), 0.0, 0.0); // no panic
    }

    // -----------------------------------------------------------------------
    // Resize
    // -----------------------------------------------------------------------

    #[test]
    fn resize_group_sets_height() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        l.resize_group(ga(id.0, 0), 150.0);
        assert_eq!(l.dock(id).unwrap().groups[0].height, Some(150.0));
    }

    #[test]
    fn resize_group_clamps_min() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        l.resize_group(ga(id.0, 0), 5.0);
        assert_eq!(l.dock(id).unwrap().groups[0].height, Some(MIN_GROUP_HEIGHT));
    }

    #[test]
    fn resize_group_invalid_addr() {
        let mut l = WorkspaceLayout::default_layout();
        l.resize_group(ga(99, 0), 100.0); // no panic
        l.resize_group(ga(0, 99), 100.0); // no panic
    }

    #[test]
    fn default_group_height_is_none() {
        let l = WorkspaceLayout::default_layout();
        let d = l.anchored_dock(DockEdge::Right).unwrap();
        for g in &d.groups {
            assert_eq!(g.height, None);
        }
    }

    #[test]
    fn set_dock_width_clamped() {
        let mut l = WorkspaceLayout::default_layout();
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
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        // Set active beyond range in Properties group, then trigger
        // cleanup via a move that removes Properties.
        let pg = group_of(&l, id, PanelKind::Properties);
        let cg = group_of(&l, id, PanelKind::Color);
        l.dock_mut(id).unwrap().groups[pg].active = 1;
        let (_, ppi) = panel_of(&l, id, PanelKind::Properties);
        l.move_panel_to_group(pa(id.0, pg, ppi), ga(id.0, cg));
        let g = &l.dock(id).unwrap().groups[pg];
        assert!(g.active < g.panels.len());
    }

    #[test]
    fn cleanup_multiple_empty_groups() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        // Empty every group, then cleanup should drop them all.
        let n = l.dock(id).unwrap().groups.len();
        for i in 0..n {
            l.dock_mut(id).unwrap().groups[i].panels.clear();
        }
        l.cleanup(id);
        assert!(l.dock(id).unwrap().groups.is_empty());
    }

    // -----------------------------------------------------------------------
    // PanelKind::ALL and label
    // -----------------------------------------------------------------------

    #[test]
    fn panel_kind_all_count() {
        assert_eq!(PanelKind::ALL.len(), 8);
    }

    #[test]
    fn panel_kind_all_contains_all_variants() {
        assert!(PanelKind::ALL.contains(&PanelKind::Layers));
        assert!(PanelKind::ALL.contains(&PanelKind::Color));
        assert!(PanelKind::ALL.contains(&PanelKind::Swatches));
        assert!(PanelKind::ALL.contains(&PanelKind::Stroke));
        assert!(PanelKind::ALL.contains(&PanelKind::Properties));
        assert!(PanelKind::ALL.contains(&PanelKind::Character));
        assert!(PanelKind::ALL.contains(&PanelKind::Paragraph));
        assert!(PanelKind::ALL.contains(&PanelKind::Artboards));
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
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let (sg, spi) = panel_of(&l, id, PanelKind::Stroke);
        l.close_panel(pa(id.0, sg, spi));
        assert!(l.hidden_panels().contains(&PanelKind::Stroke));
        assert!(!l.is_panel_visible(PanelKind::Stroke));
    }

    #[test]
    fn close_panel_removes_from_group() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let (sg, spi) = panel_of(&l, id, PanelKind::Stroke);
        l.close_panel(pa(id.0, sg, spi));
        // Stroke should no longer appear anywhere in the anchored dock.
        let has_stroke = l.dock(id).unwrap().groups.iter()
            .any(|g| g.panels.contains(&PanelKind::Stroke));
        assert!(!has_stroke);
    }

    #[test]
    fn close_last_panel_removes_group() {
        // Isolate Layers into a single-panel group first, then close
        // that sole panel: the group is removed and the panel marked
        // hidden.
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let (ag, api) = panel_of(&l, id, PanelKind::Artboards);
        l.detach_panel(pa(id.0, ag, api), 0.0, 0.0);
        let before = l.dock(id).unwrap().groups.len();
        let (lg, lpi) = panel_of(&l, id, PanelKind::Layers);
        l.close_panel(pa(id.0, lg, lpi));
        let d = l.dock(id).unwrap();
        assert_eq!(d.groups.len(), before - 1);
        assert!(l.hidden_panels().contains(&PanelKind::Layers));
    }

    #[test]
    fn show_panel_adds_to_default_group() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let (sg, spi) = panel_of(&l, id, PanelKind::Stroke);
        l.close_panel(pa(id.0, sg, spi));
        l.show_panel(PanelKind::Stroke);
        assert!(!l.hidden_panels().contains(&PanelKind::Stroke));
        // Stroke is added back somewhere in the dock.
        let has_stroke = l.dock(id).unwrap().groups.iter()
            .any(|g| g.panels.contains(&PanelKind::Stroke));
        assert!(has_stroke);
    }

    #[test]
    fn show_panel_removes_from_hidden() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        l.close_panel(pa(id.0, 0, 0)); // close Color
        assert_eq!(l.hidden_panels().len(), 1);
        l.show_panel(PanelKind::Color);
        assert!(l.hidden_panels().is_empty());
    }

    #[test]
    fn hidden_panels_default_empty() {
        let l = WorkspaceLayout::default_layout();
        assert!(l.hidden_panels().is_empty());
    }

    #[test]
    fn show_panel_restores_to_prior_group() {
        // Character is in group 1 of the default layout (Color+Swatches
        // = 0, Character+Paragraph = 1). Close then reopen it, verify it
        // lands back in group 1 rather than the default group 0.
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let (cg, cpi) = panel_of(&l, id, PanelKind::Character);
        assert_eq!(cg, 1);
        l.close_panel(pa(id.0, cg, cpi));
        l.show_panel(PanelKind::Character);
        let (cg2, _) = panel_of(&l, id, PanelKind::Character);
        assert_eq!(cg2, 1, "reopened panel should be in the same group");
    }

    #[test]
    fn show_panel_falls_back_when_prior_group_gone() {
        // Detach Artboards to isolate Layers in its own group, close
        // Layers (which removes that group), then reopen. The prior
        // group no longer exists; fall back to first group.
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let (ag, api) = panel_of(&l, id, PanelKind::Artboards);
        l.detach_panel(pa(id.0, ag, api), 0.0, 0.0);
        let (lg, lpi) = panel_of(&l, id, PanelKind::Layers);
        l.close_panel(pa(id.0, lg, lpi));
        // Group containing Layers no longer exists. Reopen should not panic.
        l.show_panel(PanelKind::Layers);
        let has_layers = l.dock(id).unwrap().groups.iter()
            .any(|g| g.panels.contains(&PanelKind::Layers));
        assert!(has_layers, "panel must be restored somewhere");
    }

    #[test]
    fn panel_menu_items_all_visible() {
        let l = WorkspaceLayout::default_layout();
        let items = l.panel_menu_items();
        assert_eq!(items.len(), PanelKind::ALL.len());
        // `is_panel_visible` is defined as "not in hidden_panels", so a
        // panel that is defined but not in any group still reports
        // visible by default — matches the pre-Character behavior.
        for (_, visible) in &items {
            assert!(visible);
        }
    }

    #[test]
    fn panel_menu_items_with_hidden() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let (sg, spi) = panel_of(&l, id, PanelKind::Stroke);
        l.close_panel(pa(id.0, sg, spi));
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
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let f1 = l.detach_group(ga(id.0, 0), 10.0, 10.0).unwrap();
        let f2 = l.detach_group(ga(id.0, 0), 20.0, 20.0).unwrap();
        // z_order is [f1, f2], bring f1 to front
        l.bring_to_front(f1);
        assert_eq!(*l.z_order.last().unwrap(), f1);
    }

    #[test]
    fn bring_to_front_already_front() {
        let mut l = WorkspaceLayout::default_layout();
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
        let mut l = WorkspaceLayout::default_layout();
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
        let mut l = WorkspaceLayout::default_layout();
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
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 50.0, 50.0).unwrap();
        l.snap_to_edge(fid, DockEdge::Left);
        // Should create a new anchored dock on the left
        assert!(l.anchored_dock(DockEdge::Left).is_some());
        assert!(l.floating_dock(fid).is_none());
    }

    #[test]
    fn snap_creates_anchored_dock() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        assert!(l.anchored_dock(DockEdge::Bottom).is_none());
        let fid = l.detach_group(ga(id.0, 0), 50.0, 50.0).unwrap();
        l.snap_to_edge(fid, DockEdge::Bottom);
        assert!(l.anchored_dock(DockEdge::Bottom).is_some());
        assert_eq!(l.anchored_dock(DockEdge::Bottom).unwrap().groups[0].panels, vec![PanelKind::Color, PanelKind::Swatches]);
    }

    #[test]
    fn redock_merges_into_right() {
        let mut l = WorkspaceLayout::default_layout();
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
        let mut l = WorkspaceLayout::default_layout();
        l.redock(DockId(99)); // no panic, no change
        assert_eq!(l.anchored.len(), 1);
    }

    #[test]
    fn is_near_edge_detection() {
        assert_eq!(WorkspaceLayout::is_near_edge(5.0, 500.0, 1000.0, 800.0), Some(DockEdge::Left));
        assert_eq!(WorkspaceLayout::is_near_edge(990.0, 500.0, 1000.0, 800.0), Some(DockEdge::Right));
        assert_eq!(WorkspaceLayout::is_near_edge(500.0, 790.0, 1000.0, 800.0), Some(DockEdge::Bottom));
    }

    #[test]
    fn is_near_edge_not_near() {
        assert_eq!(WorkspaceLayout::is_near_edge(500.0, 400.0, 1000.0, 800.0), None);
    }

    // -----------------------------------------------------------------------
    // Phase 3: Multi-edge anchored docks
    // -----------------------------------------------------------------------

    #[test]
    fn add_anchored_left() {
        let mut l = WorkspaceLayout::default_layout();
        let id = l.add_anchored_dock(DockEdge::Left);
        assert!(l.anchored_dock(DockEdge::Left).is_some());
        assert_eq!(l.anchored_dock(DockEdge::Left).unwrap().id, id);
    }

    #[test]
    fn add_anchored_existing_returns_id() {
        let mut l = WorkspaceLayout::default_layout();
        let id1 = l.add_anchored_dock(DockEdge::Left);
        let id2 = l.add_anchored_dock(DockEdge::Left);
        assert_eq!(id1, id2);
        assert_eq!(l.anchored.len(), 2); // Right + Left, not duplicated
    }

    #[test]
    fn add_anchored_bottom() {
        let mut l = WorkspaceLayout::default_layout();
        l.add_anchored_dock(DockEdge::Bottom);
        assert!(l.anchored_dock(DockEdge::Bottom).is_some());
        assert_eq!(l.anchored.len(), 2);
    }

    #[test]
    fn remove_anchored_moves_to_floating() {
        let mut l = WorkspaceLayout::default_layout();
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
        let mut l = WorkspaceLayout::default_layout();
        l.add_anchored_dock(DockEdge::Left); // empty dock
        let fid = l.remove_anchored_dock(DockEdge::Left);
        assert!(fid.is_none()); // no groups, no floating dock created
    }

    // -----------------------------------------------------------------------
    // Phase 4: Persistence
    // -----------------------------------------------------------------------

    #[test]
    fn to_json_round_trip() {
        let l = WorkspaceLayout::default_layout();
        let json = l.to_json().unwrap();
        let l2 = WorkspaceLayout::from_json(&json);
        assert_eq!(l2.anchored.len(), 1);
        assert_eq!(l2.anchored[0].0, DockEdge::Right);
        // Round-trip preserves group count and membership, without
        // pinning specific positions.
        let d1 = l.anchored_dock(DockEdge::Right).unwrap();
        let d2 = l2.anchored_dock(DockEdge::Right).unwrap();
        assert_eq!(d2.groups.len(), d1.groups.len());
        assert_eq!(
            d2.groups.iter().flat_map(|g| g.panels.clone()).collect::<Vec<_>>(),
            d1.groups.iter().flat_map(|g| g.panels.clone()).collect::<Vec<_>>(),
        );
    }

    #[test]
    fn from_json_with_floating() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        l.detach_group(ga(id.0, 0), 100.0, 200.0);
        let json = l.to_json().unwrap();
        let l2 = WorkspaceLayout::from_json(&json);
        assert_eq!(l2.floating.len(), 1);
        assert_eq!(l2.floating[0].x, 100.0);
        assert_eq!(l2.floating[0].y, 200.0);
    }

    #[test]
    fn from_json_invalid_graceful() {
        let l = WorkspaceLayout::from_json("not valid json{{{");
        // Should return a non-empty default layout rather than panic.
        assert_eq!(l.anchored.len(), 1);
        let default_len = WorkspaceLayout::default_layout()
            .anchored_dock(DockEdge::Right).unwrap().groups.len();
        assert_eq!(l.anchored_dock(DockEdge::Right).unwrap().groups.len(), default_len);
    }

    #[test]
    fn reset_to_default() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let default_len = l.anchored_dock(DockEdge::Right).unwrap().groups.len();
        l.detach_group(ga(id.0, 0), 50.0, 50.0);
        l.close_panel(pa(id.0, 0, 0));
        assert!(!l.floating.is_empty());
        assert!(!l.hidden_panels.is_empty());
        l.reset_to_default();
        assert!(l.floating.is_empty());
        assert!(l.hidden_panels.is_empty());
        assert_eq!(l.anchored_dock(DockEdge::Right).unwrap().groups.len(), default_len);
    }

    // -----------------------------------------------------------------------
    // Phase 5: Focus & keyboard navigation
    // -----------------------------------------------------------------------

    #[test]
    fn set_focused_panel() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let addr = pa(id.0, 1, 2);
        l.set_focused_panel(Some(addr));
        assert_eq!(l.focused_panel(), Some(addr));
        l.set_focused_panel(None);
        assert_eq!(l.focused_panel(), None);
    }

    #[test]
    fn focus_next_wraps() {
        // After advancing past every panel, focus_next should wrap
        // back to the first. Doesn't hardcode positions — just counts
        // how many panels exist and verifies wrap-around.
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let total_panels: usize = l.dock(id).unwrap().groups.iter()
            .map(|g| g.panels.len()).sum();
        l.set_focused_panel(None);
        l.focus_next_panel();
        let first = l.focused_panel();
        // Advance through the rest and wrap back.
        for _ in 0..total_panels {
            l.focus_next_panel();
        }
        assert_eq!(l.focused_panel(), first);
    }

    #[test]
    fn focus_prev_wraps() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let total_panels: usize = l.dock(id).unwrap().groups.iter()
            .map(|g| g.panels.len()).sum();
        l.set_focused_panel(None);
        l.focus_prev_panel();
        let last = l.focused_panel();
        for _ in 0..total_panels {
            l.focus_prev_panel();
        }
        assert_eq!(l.focused_panel(), last);
    }

    // -----------------------------------------------------------------------
    // Phase 5: Safety
    // -----------------------------------------------------------------------

    #[test]
    fn clamp_floating_within_viewport() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let fid = l.detach_group(ga(id.0, 0), 2000.0, 1500.0).unwrap();
        l.clamp_floating_docks(1000.0, 800.0);
        let fd = l.floating_dock(fid).unwrap();
        assert!(fd.x <= 1000.0 - 50.0);
        assert!(fd.y <= 800.0 - 50.0);
    }

    #[test]
    fn clamp_floating_partially_offscreen() {
        let mut l = WorkspaceLayout::default_layout();
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
        let mut l = WorkspaceLayout::default_layout();
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
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        // Reorder within the Color group ([Color, Swatches]).
        let g_color = group_of(&l, id, PanelKind::Color);
        l.reorder_panel(ga(id.0, g_color), 0, 1);
        let g = &l.dock(id).unwrap().groups[g_color];
        assert_eq!(g.panels, vec![PanelKind::Swatches, PanelKind::Color]);
        assert_eq!(g.active, 1);
    }

    #[test]
    fn reorder_panel_backward() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let g_stroke = group_of(&l, id, PanelKind::Stroke);
        l.reorder_panel(ga(id.0, g_stroke), 1, 0);
        let g = &l.dock(id).unwrap().groups[g_stroke];
        assert_eq!(g.panels, vec![PanelKind::Properties, PanelKind::Stroke]);
        assert_eq!(g.active, 0);
    }

    #[test]
    fn reorder_panel_same_position() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let g_stroke = group_of(&l, id, PanelKind::Stroke);
        let before = l.dock(id).unwrap().groups[g_stroke].panels.clone();
        l.reorder_panel(ga(id.0, g_stroke), 1, 1);
        assert_eq!(l.dock(id).unwrap().groups[g_stroke].panels, before);
    }

    #[test]
    fn reorder_panel_clamped() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        let g_stroke = group_of(&l, id, PanelKind::Stroke);
        l.reorder_panel(ga(id.0, g_stroke), 0, 99);
        let g = &l.dock(id).unwrap().groups[g_stroke];
        assert_eq!(g.panels[1], PanelKind::Stroke);
    }

    #[test]
    fn reorder_panel_out_of_bounds() {
        let mut l = WorkspaceLayout::default_layout();
        let id = right_dock_id(&l);
        l.reorder_panel(ga(id.0, 1), 99, 0); // no panic
        l.reorder_panel(ga(99, 0), 0, 1);     // no panic
    }

    // -----------------------------------------------------------------------
    // Named layouts & AppConfig
    // -----------------------------------------------------------------------

    #[test]
    fn default_layout_name() {
        let l = WorkspaceLayout::default_layout();
        assert_eq!(l.name, "Default");
    }

    #[test]
    fn named_layout() {
        let l = WorkspaceLayout::named("My Workspace");
        assert_eq!(l.name, "My Workspace");
        assert_eq!(l.anchored.len(), 1); // same structure as default
    }

    #[test]
    fn storage_key_includes_name() {
        let l = WorkspaceLayout::named("Editing");
        assert_eq!(l.storage_key(), "jas_layout:Editing");
    }

    #[test]
    fn storage_key_for_static() {
        assert_eq!(WorkspaceLayout::storage_key_for("Drawing"), "jas_layout:Drawing");
    }

    #[test]
    fn reset_preserves_name() {
        let mut l = WorkspaceLayout::named("Custom");
        let id = right_dock_id(&l);
        l.detach_group(ga(id.0, 0), 50.0, 50.0);
        assert!(!l.floating.is_empty());
        l.reset_to_default();
        assert_eq!(l.name, "Custom"); // name preserved
        assert!(l.floating.is_empty());
    }

    #[test]
    fn json_round_trip_preserves_name() {
        let l = WorkspaceLayout::named("Test Layout");
        let json = l.to_json().unwrap();
        let l2 = WorkspaceLayout::from_json(&json);
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
    // WorkspaceLayout + PaneLayout integration
    // -----------------------------------------------------------------------

    #[test]
    fn dock_layout_default_has_no_pane_layout() {
        let l = WorkspaceLayout::default_layout();
        assert!(l.pane_layout.is_none());
    }

    #[test]
    fn ensure_pane_layout_creates_if_none() {
        let mut l = WorkspaceLayout::default_layout();
        assert!(l.pane_layout.is_none());
        l.ensure_pane_layout(1000.0, 700.0);
        assert!(l.pane_layout.is_some());
        assert_eq!(l.panes().unwrap().panes.len(), 3);
    }

    #[test]
    fn ensure_pane_layout_noop_if_present() {
        let mut l = WorkspaceLayout::default_layout();
        l.ensure_pane_layout(1000.0, 700.0);
        let gen_before = l.generation;
        l.ensure_pane_layout(1000.0, 700.0);
        // Should not bump generation again
        assert_eq!(l.generation, gen_before);
    }

    #[test]
    fn reset_to_default_clears_pane_layout() {
        let mut l = WorkspaceLayout::default_layout();
        l.ensure_pane_layout(1000.0, 700.0);
        assert!(l.pane_layout.is_some());
        l.reset_to_default();
        assert!(l.pane_layout.is_none());
    }

    #[test]
    fn panes_accessors() {
        let mut l = WorkspaceLayout::default_layout();
        assert!(l.panes().is_none());
        assert!(l.panes_mut().is_none());
        l.ensure_pane_layout(1000.0, 700.0);
        assert!(l.panes().is_some());
        assert!(l.panes_mut().is_some());
    }

    #[test]
    fn serde_backwards_compat_no_pane_layout() {
        // Simulate old JSON without pane_layout field
        let mut l = WorkspaceLayout::default_layout();
        l.ensure_pane_layout(1000.0, 700.0);
        let json = l.to_json().unwrap();
        // Remove pane_layout from JSON to simulate old format
        let mut val: serde_json::Value = serde_json::from_str(&json).unwrap();
        val.as_object_mut().unwrap().remove("pane_layout");
        let old_json = serde_json::to_string(&val).unwrap();
        let restored = WorkspaceLayout::from_json(&old_json);
        assert!(restored.pane_layout.is_none());
    }

    #[test]
    fn serde_round_trip_with_pane_layout() {
        let mut l = WorkspaceLayout::default_layout();
        l.ensure_pane_layout(1000.0, 700.0);
        let json = l.to_json().unwrap();
        let restored = WorkspaceLayout::from_json(&json);
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
        let mut l = WorkspaceLayout::default_layout();
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
        let restored = WorkspaceLayout::from_json(&old_json);
        let pl = restored.pane_layout.unwrap();
        // Panes should deserialize with default config (Canvas defaults)
        assert_eq!(pl.panes.len(), 3);
        // Default config is Canvas — check it applied
        let toolbar = pl.pane_by_kind(PaneKind::Toolbar).unwrap();
        assert_eq!(toolbar.config.label, "Canvas"); // default, not "Tools"
    }

    #[test]
    fn clamp_floating_docks_also_clamps_panes() {
        let mut l = WorkspaceLayout::default_layout();
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
    // Workspace working-copy pattern
    // -----------------------------------------------------------------------

    #[test]
    fn workspace_layout_name_constant() {
        assert_eq!(WORKSPACE_LAYOUT_NAME, "Workspace");
    }

    #[test]
    fn named_creates_layout_with_given_name() {
        let l = WorkspaceLayout::named("MyLayout");
        assert_eq!(l.name, "MyLayout");
        assert_eq!(l.version, LAYOUT_VERSION);
        assert_eq!(l.anchored.len(), 1);
    }

    #[test]
    fn generation_tracking() {
        let mut l = WorkspaceLayout::default_layout();
        assert!(!l.needs_save());
        l.bump();
        assert!(l.needs_save());
        l.mark_saved();
        assert!(!l.needs_save());
    }

    #[test]
    fn reset_to_default_preserves_name() {
        let mut l = WorkspaceLayout::named(WORKSPACE_LAYOUT_NAME);
        // Mutate it
        l.hidden_panels.push(PanelKind::Layers);
        l.bump();
        assert!(!l.hidden_panels.is_empty());
        l.reset_to_default();
        assert!(l.hidden_panels.is_empty());
        assert_eq!(l.name, WORKSPACE_LAYOUT_NAME);
        assert!(l.needs_save());
    }

    #[test]
    fn json_round_trip_preserves_layout() {
        let l = WorkspaceLayout::named("Test");
        let json = l.to_json().unwrap();
        let loaded = WorkspaceLayout::from_json(&json);
        assert_eq!(loaded.name, "Test");
        assert_eq!(loaded.version, LAYOUT_VERSION);
        assert_eq!(loaded.anchored.len(), l.anchored.len());
    }

    #[test]
    fn try_from_json_returns_none_for_bad_version() {
        let json = r#"{"version":0,"name":"Old","anchored":[],"floating":[],"hidden_panels":[],"z_order":[],"focused_panel":null,"next_id":1}"#;
        assert!(WorkspaceLayout::try_from_json(json).is_none());
    }

    #[test]
    fn try_from_json_returns_none_for_invalid_json() {
        assert!(WorkspaceLayout::try_from_json("not json").is_none());
    }

    #[test]
    fn try_from_json_returns_some_for_valid() {
        let l = WorkspaceLayout::named("Valid");
        let json = l.to_json().unwrap();
        let result = WorkspaceLayout::try_from_json(&json);
        assert!(result.is_some());
        assert_eq!(result.unwrap().name, "Valid");
    }

    #[test]
    fn storage_key_uses_prefix_and_name() {
        let l = WorkspaceLayout::named("Foo");
        assert_eq!(l.storage_key(), "jas_layout:Foo");
        assert_eq!(WorkspaceLayout::storage_key_for("Bar"), "jas_layout:Bar");
    }

    #[test]
    fn app_config_register_layout_idempotent() {
        let mut c = AppConfig::default();
        c.register_layout("Custom");
        assert_eq!(c.saved_layouts.len(), 2);
        assert!(c.saved_layouts.contains(&"Custom".to_string()));
        // Registering again is a no-op
        c.register_layout("Custom");
        assert_eq!(c.saved_layouts.len(), 2);
    }
}
