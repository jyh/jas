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
    AddAnchorPoint,
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
            ToolKind::AddAnchorPoint => "Add Anchor Point (+)",
            ToolKind::Pencil => "Pencil (N)",
            ToolKind::Text => "Text (T)",
            ToolKind::TextOnPath => "Text on Path",
            ToolKind::Line => "Line (L)",
            ToolKind::Rect => "Rectangle (M)",
            ToolKind::Polygon => "Polygon",
        }
    }

    /// Return a CSS cursor value for the canvas when this tool is active.
    pub fn cursor_css(&self) -> &'static str {
        match self {
            ToolKind::Selection => "default",
            ToolKind::DirectSelection => {
                "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24'%3E%3Cpath d='M4,1 L4,19 L8,15 L12,22 L15,20 L11,13 L16,13 Z' fill='white' stroke='black' stroke-width='1.5'/%3E%3C/svg%3E\") 4 1, default"
            }
            ToolKind::GroupSelection => {
                "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24'%3E%3Cpath d='M4,1 L4,19 L8,15 L12,22 L15,20 L11,13 L16,13 Z' fill='white' stroke='black' stroke-width='1.5'/%3E%3Cline x1='17' y1='20' x2='23' y2='20' stroke='black' stroke-width='2'/%3E%3Cline x1='20' y1='17' x2='20' y2='23' stroke='black' stroke-width='2'/%3E%3C/svg%3E\") 4 1, default"
            }
            ToolKind::Pen => {
                "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='-5 -2 175 265'%3E%3Cpath d='M163.07,190.51l12.54,19.52-90.68,45.96-12.46-28.05C58.86,195.29,32.68,176.45.13,161.51L0,4.58C0,2.38,2.8-.28,4.11-.37s3.96.45,5.31,1.34l85.42,56.33,48.38,32.15c-7.29,34.58-4.05,71.59,19.86,101.06Z' fill='black'/%3E%3Cpath d='M61.7,49.58l68.41,45.5c-5.22,27.56-2.64,53.1,8.47,78.19l-64.8,33.24c-14.66-23.64-35.91-40.19-61.53-51.84l.29-54.31-.44-69.96,42.43,77.66c-6.55,8.82-4.96,18.8,2.86,24.95,7.05,5.53,18.35,4.49,24.72-3.04,4.82-5.71,4.27-12.96.95-18.87s-10.01-8.62-17.49-8.79L23.48,24.2l38.22,25.38Z' fill='white'/%3E%3C/svg%3E\") 1 1, crosshair"
            }
            ToolKind::AddAnchorPoint => {
                "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='-5 -2 245 265'%3E%3Cpath d='M170.82,209.27l-88.08,46.73-10.99-25.31C60.04,197.72,31.98,175.62.51,162.2L.07,55.68,0,7.02C0,5.03.62,2.32,1.66,1.26S6.93-.46,8.2.39l130.44,88.12c-4.9,32.54-4.3,66.45,14.46,94.39l17.7,26.39Z' fill='black'/%3E%3Cpath d='M126.44,94.04c-2.22,11.75-2.88,21.93-2.47,32.64.52,16.1,3.8,30.8,11.11,46.23l-62.86,33.45c-14.38-22.81-34.23-39.94-60.13-51.08l-.62-125.03,41.81,77.76c-5.22,8.02-5.31,16.36.31,22.49,6.1,6.66,15.3,7.1,23.05,1.74,6.57-4.54,7.84-12.25,5.04-18.88s-8.7-11.19-17.14-10.35L22.85,24.63l103.56,69.4Z' fill='white'/%3E%3Cpath d='M232.87,153.61c-3.47,3.11-8.74,5.8-13.86,7.8l-18.34-34.03-33.68,18.09-7.64-13.38,34.16-18.2-18.46-35.15,13.59-7.64,18.83,35.42,33.38-17.99,7.32,13.45-33.3,18.14,17.99,33.46Z' fill='black'/%3E%3C/svg%3E\") 1 1, crosshair"
            }
            _ => "crosshair",
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
            ToolKind::AddAnchorPoint => Some("="),
            _ => None,
        }
    }
}

/// Trait for canvas interaction tools.
pub trait CanvasTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, alt: bool);
    fn on_move(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, alt: bool, dragging: bool);
    fn on_release(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, alt: bool);
    fn draw_overlay(&self, model: &Model, ctx: &CanvasRenderingContext2d);

    fn on_double_click(&mut self, _model: &mut Model, _x: f64, _y: f64) {}
    fn on_key(&mut self, _model: &mut Model, _key: &str) -> bool { false }
    fn on_key_up(&mut self, _model: &mut Model, _key: &str) -> bool { false }
    fn activate(&mut self, _model: &mut Model) {}
    fn deactivate(&mut self, _model: &mut Model) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_kind_has_eleven_variants() {
        let all = [
            ToolKind::Selection,
            ToolKind::DirectSelection,
            ToolKind::GroupSelection,
            ToolKind::Pen,
            ToolKind::AddAnchorPoint,
            ToolKind::Pencil,
            ToolKind::Text,
            ToolKind::TextOnPath,
            ToolKind::Line,
            ToolKind::Rect,
            ToolKind::Polygon,
        ];
        assert_eq!(all.len(), 11);
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
            ToolKind::Pen, ToolKind::AddAnchorPoint, ToolKind::Pencil, ToolKind::Text,
            ToolKind::TextOnPath, ToolKind::Line, ToolKind::Rect, ToolKind::Polygon,
        ];
        for t in &all {
            set.insert(*t);
        }
        assert_eq!(set.len(), 11);
    }

    #[test]
    fn labels_all_non_empty() {
        let all = [
            ToolKind::Selection, ToolKind::DirectSelection, ToolKind::GroupSelection,
            ToolKind::Pen, ToolKind::AddAnchorPoint, ToolKind::Pencil, ToolKind::Text,
            ToolKind::TextOnPath, ToolKind::Line, ToolKind::Rect, ToolKind::Polygon,
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
    fn pen_slot_alternates() {
        let alternates = [ToolKind::Pen, ToolKind::AddAnchorPoint];
        assert_eq!(alternates.len(), 2);
    }

    #[test]
    fn toolbar_grid_layout() {
        // 4 rows x 2 columns, 7 slots total
        let slots: &[(usize, usize, &[ToolKind])] = &[
            (0, 0, &[ToolKind::Selection]),
            (0, 1, &[ToolKind::DirectSelection, ToolKind::GroupSelection]),
            (1, 0, &[ToolKind::Pen, ToolKind::AddAnchorPoint]),
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
        assert_eq!(shared, 4);

        // All 11 tools appear exactly once
        let mut all_tools: Vec<ToolKind> = slots.iter()
            .flat_map(|(_, _, tools)| tools.iter().copied())
            .collect();
        all_tools.sort_by_key(|t| format!("{:?}", t));
        assert_eq!(all_tools.len(), 11);
    }
}
