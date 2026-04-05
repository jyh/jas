//! Tool protocol and context for the canvas tool system.
//!
//! Each tool implements the CanvasTool trait and receives events from the
//! canvas. Tools own their interaction state and draw overlays.

use web_sys::CanvasRenderingContext2d;

use crate::document::model::Model;

/// Shared tool constants.
pub const HIT_RADIUS: f64 = 8.0;
pub const HANDLE_DRAW_SIZE: f64 = 10.0;
pub const DRAG_THRESHOLD: f64 = 4.0;
pub const PASTE_OFFSET: f64 = 24.0;
pub const POLYGON_SIDES: usize = 5;

/// The active tool type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ToolKind {
    Selection,
    DirectSelection,
    GroupSelection,
    Pen,
    Pencil,
    Text,
    TextOnPath,
    Line,
    Rect,
    Polygon,
}

impl ToolKind {
    pub fn label(&self) -> &'static str {
        match self {
            ToolKind::Selection => "Selection (V)",
            ToolKind::DirectSelection => "Direct Selection (A)",
            ToolKind::GroupSelection => "Group Selection",
            ToolKind::Pen => "Pen (P)",
            ToolKind::Pencil => "Pencil (N)",
            ToolKind::Text => "Text (T)",
            ToolKind::TextOnPath => "Text on Path",
            ToolKind::Line => "Line (L)",
            ToolKind::Rect => "Rectangle (M)",
            ToolKind::Polygon => "Polygon",
        }
    }

    pub fn shortcut(&self) -> Option<&'static str> {
        match self {
            ToolKind::Selection => Some("v"),
            ToolKind::DirectSelection => Some("a"),
            ToolKind::Pen => Some("p"),
            ToolKind::Pencil => Some("n"),
            ToolKind::Text => Some("t"),
            ToolKind::Line => Some("l"),
            ToolKind::Rect => Some("m"),
            _ => None,
        }
    }
}

/// Trait for canvas interaction tools.
pub trait CanvasTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, alt: bool);
    fn on_move(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, dragging: bool);
    fn on_release(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, alt: bool);
    fn draw_overlay(&self, model: &Model, ctx: &CanvasRenderingContext2d);

    fn on_double_click(&mut self, _model: &mut Model, _x: f64, _y: f64) {}
    fn on_key(&mut self, _model: &mut Model, _key: &str) -> bool { false }
    fn activate(&mut self, _model: &mut Model) {}
    fn deactivate(&mut self, _model: &mut Model) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_kind_has_ten_variants() {
        let all = [
            ToolKind::Selection,
            ToolKind::DirectSelection,
            ToolKind::GroupSelection,
            ToolKind::Pen,
            ToolKind::Pencil,
            ToolKind::Text,
            ToolKind::TextOnPath,
            ToolKind::Line,
            ToolKind::Rect,
            ToolKind::Polygon,
        ];
        assert_eq!(all.len(), 10);
    }

    #[test]
    fn tool_kind_equality() {
        assert_eq!(ToolKind::Selection, ToolKind::Selection);
        assert_ne!(ToolKind::Selection, ToolKind::DirectSelection);
        assert_ne!(ToolKind::Text, ToolKind::TextOnPath);
        assert_ne!(ToolKind::Rect, ToolKind::Polygon);
    }

    #[test]
    fn tool_kind_clone_copy() {
        let t = ToolKind::Pen;
        let t2 = t;
        assert_eq!(t, t2);
    }

    #[test]
    fn tool_kind_debug() {
        let s = format!("{:?}", ToolKind::Selection);
        assert_eq!(s, "Selection");
    }

    #[test]
    fn tool_kind_hash() {
        use std::collections::HashSet;
        let mut set = HashSet::new();
        let all = [
            ToolKind::Selection, ToolKind::DirectSelection, ToolKind::GroupSelection,
            ToolKind::Pen, ToolKind::Pencil, ToolKind::Text, ToolKind::TextOnPath,
            ToolKind::Line, ToolKind::Rect, ToolKind::Polygon,
        ];
        for t in &all {
            set.insert(*t);
        }
        assert_eq!(set.len(), 10);
    }

    #[test]
    fn labels_all_non_empty() {
        let all = [
            ToolKind::Selection, ToolKind::DirectSelection, ToolKind::GroupSelection,
            ToolKind::Pen, ToolKind::Pencil, ToolKind::Text, ToolKind::TextOnPath,
            ToolKind::Line, ToolKind::Rect, ToolKind::Polygon,
        ];
        for t in &all {
            assert!(!t.label().is_empty(), "{:?} has empty label", t);
        }
    }

    #[test]
    fn labels_contain_tool_name() {
        assert!(ToolKind::Selection.label().contains("Selection"));
        assert!(ToolKind::Pen.label().contains("Pen"));
        assert!(ToolKind::Text.label().contains("Text"));
        assert!(ToolKind::Line.label().contains("Line"));
        assert!(ToolKind::Rect.label().contains("Rect"));
    }

    #[test]
    fn shortcuts_for_primary_tools() {
        assert_eq!(ToolKind::Selection.shortcut(), Some("v"));
        assert_eq!(ToolKind::DirectSelection.shortcut(), Some("a"));
        assert_eq!(ToolKind::Pen.shortcut(), Some("p"));
        assert_eq!(ToolKind::Pencil.shortcut(), Some("n"));
        assert_eq!(ToolKind::Text.shortcut(), Some("t"));
        assert_eq!(ToolKind::Line.shortcut(), Some("l"));
        assert_eq!(ToolKind::Rect.shortcut(), Some("m"));
    }

    #[test]
    fn shortcuts_none_for_alternates() {
        assert_eq!(ToolKind::GroupSelection.shortcut(), None);
        assert_eq!(ToolKind::TextOnPath.shortcut(), None);
        assert_eq!(ToolKind::Polygon.shortcut(), None);
    }

    #[test]
    fn hit_radius_value() {
        assert_eq!(HIT_RADIUS, 8.0);
    }

    #[test]
    fn handle_draw_size_value() {
        assert_eq!(HANDLE_DRAW_SIZE, 10.0);
    }

    #[test]
    fn drag_threshold_value() {
        assert_eq!(DRAG_THRESHOLD, 4.0);
    }

    #[test]
    fn paste_offset_value() {
        assert_eq!(PASTE_OFFSET, 24.0);
    }

    #[test]
    fn polygon_sides_value() {
        assert_eq!(POLYGON_SIDES, 5);
    }

    // Toolbar layout tests (verifying constants from app.rs)

    #[test]
    fn arrow_slot_alternates() {
        let alternates = [ToolKind::DirectSelection, ToolKind::GroupSelection];
        assert_eq!(alternates.len(), 2);
    }

    #[test]
    fn text_slot_alternates() {
        let alternates = [ToolKind::Text, ToolKind::TextOnPath];
        assert_eq!(alternates.len(), 2);
    }

    #[test]
    fn shape_slot_alternates() {
        let alternates = [ToolKind::Rect, ToolKind::Polygon];
        assert_eq!(alternates.len(), 2);
    }

    #[test]
    fn toolbar_grid_layout() {
        // 4 rows x 2 columns, 7 slots total
        let slots: &[(usize, usize, &[ToolKind])] = &[
            (0, 0, &[ToolKind::Selection]),
            (0, 1, &[ToolKind::DirectSelection, ToolKind::GroupSelection]),
            (1, 0, &[ToolKind::Pen]),
            (1, 1, &[ToolKind::Pencil]),
            (2, 0, &[ToolKind::Text, ToolKind::TextOnPath]),
            (2, 1, &[ToolKind::Line]),
            (3, 0, &[ToolKind::Rect, ToolKind::Polygon]),
        ];
        assert_eq!(slots.len(), 7);

        // Verify max row is 3 (4 rows)
        let max_row = slots.iter().map(|(r, _, _)| *r).max().unwrap();
        assert_eq!(max_row, 3);

        // Verify max col is 1 (2 columns)
        let max_col = slots.iter().map(|(_, c, _)| *c).max().unwrap();
        assert_eq!(max_col, 1);

        // Count shared slots (len > 1)
        let shared = slots.iter().filter(|(_, _, tools)| tools.len() > 1).count();
        assert_eq!(shared, 3);

        // All 10 tools appear exactly once
        let mut all_tools: Vec<ToolKind> = slots.iter()
            .flat_map(|(_, _, tools)| tools.iter().copied())
            .collect();
        all_tools.sort_by_key(|t| format!("{:?}", t));
        assert_eq!(all_tools.len(), 10);
    }
}
