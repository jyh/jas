//! Dock and panel infrastructure.
//!
//! A [`DockState`] holds a vertical list of [`PanelGroup`]s. Each group
//! contains a set of [`PanelKind`] tabs, one of which is active at a time.
//! Both the dock as a whole and individual groups can be collapsed.
//!
//! This module contains only pure data types and state operations — no
//! rendering code. Panel content implementations will be added later.

/// Identifies a panel type. Each variant maps to a distinct panel UI
/// that will be implemented in a later phase.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PanelKind {
    Layers,
    Color,
    Stroke,
    Properties,
}

/// Default dock width in pixels.
const DEFAULT_DOCK_WIDTH: f64 = 240.0;

/// A group of panels sharing a tab bar. One panel is active (visible) at
/// a time. The group can be collapsed to show only the tab bar.
#[derive(Debug, Clone)]
pub struct PanelGroup {
    pub panels: Vec<PanelKind>,
    pub active: usize,
    pub collapsed: bool,
}

impl PanelGroup {
    pub fn new(panels: Vec<PanelKind>) -> Self {
        Self {
            panels,
            active: 0,
            collapsed: false,
        }
    }

    /// Return the active panel kind, or `None` if the group is empty.
    pub fn active_panel(&self) -> Option<PanelKind> {
        self.panels.get(self.active).copied()
    }
}

/// The dock: a vertical strip of panel groups anchored to the right of
/// the canvas. Can be collapsed to a narrow icon strip.
#[derive(Debug, Clone)]
pub struct DockState {
    pub groups: Vec<PanelGroup>,
    pub collapsed: bool,
    pub width: f64,
}

impl DockState {
    /// Create the default two-group layout.
    pub fn default_layout() -> Self {
        Self {
            groups: vec![
                PanelGroup::new(vec![PanelKind::Layers]),
                PanelGroup::new(vec![
                    PanelKind::Color,
                    PanelKind::Stroke,
                    PanelKind::Properties,
                ]),
            ],
            collapsed: false,
            width: DEFAULT_DOCK_WIDTH,
        }
    }

    /// Toggle the entire dock between expanded and collapsed.
    pub fn toggle_dock_collapsed(&mut self) {
        self.collapsed = !self.collapsed;
    }

    /// Toggle a specific panel group between expanded and collapsed.
    /// Out-of-bounds indices are silently ignored.
    pub fn toggle_group_collapsed(&mut self, group_idx: usize) {
        if let Some(group) = self.groups.get_mut(group_idx) {
            group.collapsed = !group.collapsed;
        }
    }

    /// Switch the active tab within a panel group.
    /// Out-of-bounds group or panel indices are silently ignored.
    pub fn set_active_panel(&mut self, group_idx: usize, panel_idx: usize) {
        if let Some(group) = self.groups.get_mut(group_idx) {
            if panel_idx < group.panels.len() {
                group.active = panel_idx;
            }
        }
    }

    /// Human-readable label for a panel kind.
    pub fn panel_label(kind: PanelKind) -> &'static str {
        match kind {
            PanelKind::Layers => "Layers",
            PanelKind::Color => "Color",
            PanelKind::Stroke => "Stroke",
            PanelKind::Properties => "Properties",
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -- DockState structural tests --

    #[test]
    fn default_layout_has_two_groups() {
        let dock = DockState::default_layout();
        assert_eq!(dock.groups.len(), 2);
        assert_eq!(dock.groups[0].panels, vec![PanelKind::Layers]);
        assert_eq!(
            dock.groups[1].panels,
            vec![PanelKind::Color, PanelKind::Stroke, PanelKind::Properties]
        );
    }

    #[test]
    fn default_layout_not_collapsed() {
        let dock = DockState::default_layout();
        assert!(!dock.collapsed);
        for group in &dock.groups {
            assert!(!group.collapsed);
        }
    }

    #[test]
    fn default_dock_width() {
        let dock = DockState::default_layout();
        assert_eq!(dock.width, 240.0);
    }

    #[test]
    fn toggle_dock_collapsed() {
        let mut dock = DockState::default_layout();
        assert!(!dock.collapsed);
        dock.toggle_dock_collapsed();
        assert!(dock.collapsed);
        dock.toggle_dock_collapsed();
        assert!(!dock.collapsed);
    }

    #[test]
    fn toggle_group_collapsed() {
        let mut dock = DockState::default_layout();
        dock.toggle_group_collapsed(0);
        assert!(dock.groups[0].collapsed);
        assert!(!dock.groups[1].collapsed);
        dock.toggle_group_collapsed(0);
        assert!(!dock.groups[0].collapsed);
    }

    #[test]
    fn toggle_group_out_of_bounds() {
        let mut dock = DockState::default_layout();
        let before = dock.clone();
        dock.toggle_group_collapsed(99);
        assert_eq!(dock.groups.len(), before.groups.len());
        assert_eq!(dock.collapsed, before.collapsed);
    }

    #[test]
    fn set_active_panel() {
        let mut dock = DockState::default_layout();
        assert_eq!(dock.groups[1].active, 0);
        dock.set_active_panel(1, 2);
        assert_eq!(dock.groups[1].active, 2);
    }

    #[test]
    fn set_active_panel_out_of_bounds() {
        let mut dock = DockState::default_layout();
        dock.set_active_panel(1, 99);
        assert_eq!(dock.groups[1].active, 0); // unchanged
        dock.set_active_panel(99, 0); // invalid group — no panic
    }

    // -- PanelGroup tests --

    #[test]
    fn panel_group_active_panel() {
        let group = PanelGroup::new(vec![PanelKind::Color, PanelKind::Stroke]);
        assert_eq!(group.active_panel(), Some(PanelKind::Color));
    }

    #[test]
    fn panel_group_active_panel_empty() {
        let group = PanelGroup {
            panels: vec![],
            active: 0,
            collapsed: false,
        };
        assert_eq!(group.active_panel(), None);
    }

    #[test]
    fn panel_label_values() {
        assert_eq!(DockState::panel_label(PanelKind::Layers), "Layers");
        assert_eq!(DockState::panel_label(PanelKind::Color), "Color");
        assert_eq!(DockState::panel_label(PanelKind::Stroke), "Stroke");
        assert_eq!(DockState::panel_label(PanelKind::Properties), "Properties");
    }
}
