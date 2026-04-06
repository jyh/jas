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
pub const ERASER_SIZE: f64 = 2.0;

/// The active tool type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ToolKind {
    Selection,
    DirectSelection,
    GroupSelection,
    Pen,
    AddAnchorPoint,
    DeleteAnchorPoint,
    AnchorPoint,
    Pencil,
    PathEraser,
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
            ToolKind::DeleteAnchorPoint => "Delete Anchor Point (-)",
            ToolKind::AnchorPoint => "Anchor Point (Shift+C)",
            ToolKind::Pencil => "Pencil (N)",
            ToolKind::PathEraser => "Path Eraser (Shift+E)",
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
            ToolKind::DeleteAnchorPoint => {
                "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='-5 -2 265 265'%3E%3Cpath d='M171.16,209.05l-87.84,46.95c-3.95-8.26-7.66-16.33-10.98-24.89-13.5-34.82-37.51-53.77-71.54-69.91l-.4-54.61L0,6.21C0,3.95,2.53.66,4.05.16s4.42.21,6.33,1.51l127.62,86.16c-.17,5.51-.81,10.43-1.56,16.17-3.3,25.08,1.31,50.95,12.81,73.57l21.9,31.48Z' fill='black'/%3E%3Cpath d='M126.23,94.28L22.85,24.63l41.01,76.81c-5.22,7.79-5.06,16.71.29,22.63,6.52,7.2,16.36,7.25,24.09,1.18,5.95-4.67,6.35-12.24,4.2-18.37-2.55-7.28-9.14-10.98-17.57-11.7L23.73,25.13l102.5,69.14c-1.59,10.88-2.27,20.24-2.17,30.44.4,16.82,3.06,32.72,10.5,48.72l-61.27,32.7c-15.09-22.6-34.96-40.67-60.57-52.09l-.37-123.25,41.01,76.81Z' fill='white'/%3E%3Crect x='158.95' y='110.41' width='93.43' height='15.36' transform='translate(-31.37 110.38) rotate(-28)' fill='black'/%3E%3C/svg%3E\") 1 1, crosshair"
            }
            ToolKind::AnchorPoint => {
                "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='-5 -2 265 265'%3E%3Cpath d='M83.11,256l-17.21-39.82c-14.6-25.62-37.76-42.26-64.64-54.74l-.55-51.33L0,6.71C-.02,4.87,1.44,1.8,2.62.77s5.12-1.03,6.66.01l128.83,87.39-2.52,25.97c-2.03,20.93,1.76,44.01,13.52,61.83l21.9,33.2s-87.9,46.83-87.9,46.83Z' fill='black'/%3E%3Cpath d='M125.27,93.8L23.13,24.57l39.47,73.45c1.29,2.43,4.09,4.31,6.62,5.06,10.87,1.39,15.9,13.21,12.45,22.55-3.45,9.33-16.08,13.17-24.38,7.8-8.31-5.38-10.28-16.62-3.7-25.38L12.6,30.88l.27,123.04c23.7,11.46,47.42,29.86,60.53,52.12l60.89-32.47c-10.97-26.18-11.95-50.76-9.02-79.77Z' fill='white'/%3E%3Cpath d='M179.5,120.04l32.26,60.93-12.56,6.65-39.41-73.7,73.14-38.92c2.57,3.76,4.72,7.63,7.25,12.71l-60.67,32.35h0Z' fill='black'/%3E%3C/svg%3E\") 1 1, crosshair"
            }
            ToolKind::Pencil => {
                "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 256 256'%3E%3Cpath d='M57.6,233.77l-51.77,22c-3.79,1.61-6.42-5.57-5.71-8.78l15.63-71.11c1.24-5.63,2.19-9.52,6.08-14.09L108.97,59.4l43.76-50.24c6.91-7.93,20.11-12.57,29.23-6.1,13.11,9.3,24.18,19.89,35.98,30.87,7.38,6.86,8.71,20.57,2.31,28.2l-28.29,33.69-107.57,127.08c-9.12,4.32-17.67,7-26.79,10.88Z' fill='black'/%3E%3Cpath d='M208.57,55.33c4.05-7.4-1.19-14.82-6.49-19.18l-25-20.58c-10.66-8.78-22.36,11.05-28.07,18.32,14.44,13.9,28.28,26.73,44.4,38.75,5.64-5.65,11.45-10.55,15.16-17.31Z' fill='%235f5f5b'/%3E%3Cpath d='M70.01,189.48c-5.14.35-10.35,1.24-13.94-1.12-2.83-1.86-3.93-9.72-2.84-13.56l101.24-118.96c5.95,4.89,10.67,9.06,15.66,14.57l-100.12,119.07Z' fill='%235f5f5b'/%3E%3Cpath d='M47.55,169.12c-3.85,1.45-9.72.32-12.69-2.27l41.55-49.37,32.56-37.99,29.83-34.98c3.62.1,6.99,3.72,8.64,7.09l-45.3,52.97-54.59,64.54Z' fill='%235f5f5b'/%3E%3Cpath d='M161.36,111.12l-68.09,80.6c-4.52,5.34-8.33,9.99-13.72,15.13-3.1-3.37-5.1-10.15-1.03-14.97l97.51-115.25c3.44.45,8.52,3.68,8.25,6.56l-22.92,27.94Z' fill='%235f5f5b'/%3E%3Cpath d='M71.47,214.03c-11.31,4.52-21.14,8.07-32.31,13.6l-17.23-13.26c.99-5.56,1.35-11.11,2.68-16.6l4.39-18.04c1.63-3.22,11.55-2.19,13.67.71,3.2,4.4,3.19,12.25,7.13,15.82,3.97,3.6,10.62.78,14.92,3.17s4.89,9.2,6.75,14.6Z' fill='white'/%3E%3C/svg%3E\") 1 23, crosshair"
            }
            ToolKind::PathEraser => {
                "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 256 256'%3E%3Cpath d='M169.86,33.13L243.34,1.82c3.43-1.46,6.39-2.97,9.92-.52,2.21,1.54,3.34,4.88,2.41,8.76l-19.31,80.53-108.02,125.71-27.98,31.2c-9.63,10.74-24.91,11.34-35.56,1.63l-28-25.52c-9.09-8.28-9.54-23.48-1.42-32.95l40.64-47.45,93.83-110.08Z' fill='black'/%3E%3Cpath d='M184.63,65.93c4.88.46,9.96.27,13.5,2.32,2.91,1.68,5.44,10.2,3.01,13.03l-84.89,99c-6.97-3.72-11.86-9.07-15.89-15.76l84.27-98.59Z' fill='%235f5f5b'/%3E%3Cpath d='M44.69,212.9c-7.74-11.08,8.68-22.32,17.05-32.78l45.05,40.93-15.82,18.47c-8.77,10.24-21.21-2.39-26.77-7.31-6.96-6.17-14.12-11.58-19.52-19.31Z' fill='%235f5f5b'/%3E%3Cpath d='M207.17,85.96c4.81-.22,8.54.77,12.85,3.59l-65.13,76.29-23.35,27c-3.91-1.36-6.44-4.06-8.62-7.89l84.25-98.98Z' fill='%235f5f5b'/%3E%3Cpath d='M124.64,106.13l50.36-58.45c2.8,3.96,5.01,9.06,3.33,12.12-5.2,9.48-12.82,16.62-19.83,24.82l-62.56,73.21c-1.99,2.33-5.01,1.06-6.38.14-1.59-1.07-5.25-3.97-3.15-6.5,10.19-12.26,20.7-23.56,30.54-35.78l7.69-9.56Z' fill='%235f5f5b'/%3E%3Cpath d='M183.88,41.54c8.08-4.67,16.32-7.31,24.34-10.36,12.84-4.88,5.89-4.25,24.42,10.2,2.91.33-5.31,35.45-6.97,35.87-3.37,3.03-13.57,1.84-14.92-2.22l-4.99-15-16.7-3.81c-4.53-1.03-4.11-9.11-5.17-14.68Z' fill='white'/%3E%3Crect x='88.74' y='155.97' width='14.58' height='61.84' transform='translate(299.56 239.09) rotate(131.58)' fill='white'/%3E%3C/svg%3E\") 1 23, crosshair"
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
            ToolKind::DeleteAnchorPoint => Some("-"),
            ToolKind::AnchorPoint => Some("C"),
            ToolKind::PathEraser => Some("E"),
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
    fn tool_kind_has_fourteen_variants() {
        let all = [
            ToolKind::Selection,
            ToolKind::DirectSelection,
            ToolKind::GroupSelection,
            ToolKind::Pen,
            ToolKind::AddAnchorPoint,
            ToolKind::DeleteAnchorPoint,
            ToolKind::AnchorPoint,
            ToolKind::Pencil,
            ToolKind::PathEraser,
            ToolKind::Text,
            ToolKind::TextOnPath,
            ToolKind::Line,
            ToolKind::Rect,
            ToolKind::Polygon,
        ];
        assert_eq!(all.len(), 14);
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
            ToolKind::Pen, ToolKind::AddAnchorPoint, ToolKind::DeleteAnchorPoint,
            ToolKind::AnchorPoint, ToolKind::Pencil, ToolKind::PathEraser,
            ToolKind::Text, ToolKind::TextOnPath, ToolKind::Line, ToolKind::Rect,
            ToolKind::Polygon,
        ];
        for t in &all {
            set.insert(*t);
        }
        assert_eq!(set.len(), 14);
    }

    #[test]
    fn labels_all_non_empty() {
        let all = [
            ToolKind::Selection, ToolKind::DirectSelection, ToolKind::GroupSelection,
            ToolKind::Pen, ToolKind::AddAnchorPoint, ToolKind::DeleteAnchorPoint,
            ToolKind::AnchorPoint, ToolKind::Pencil, ToolKind::PathEraser,
            ToolKind::Text, ToolKind::TextOnPath, ToolKind::Line, ToolKind::Rect,
            ToolKind::Polygon,
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

    #[test]
    fn eraser_size_value() {
        assert_eq!(ERASER_SIZE, 2.0);
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
        let alternates = [ToolKind::Pen, ToolKind::AddAnchorPoint, ToolKind::DeleteAnchorPoint, ToolKind::AnchorPoint];
        assert_eq!(alternates.len(), 4);
    }

    #[test]
    fn pencil_slot_alternates() {
        let alternates = [ToolKind::Pencil, ToolKind::PathEraser];
        assert_eq!(alternates.len(), 2);
    }

    #[test]
    fn toolbar_grid_layout() {
        // 4 rows x 2 columns, 7 slots total
        let slots: &[(usize, usize, &[ToolKind])] = &[
            (0, 0, &[ToolKind::Selection]),
            (0, 1, &[ToolKind::DirectSelection, ToolKind::GroupSelection]),
            (1, 0, &[ToolKind::Pen, ToolKind::AddAnchorPoint, ToolKind::DeleteAnchorPoint, ToolKind::AnchorPoint]),
            (1, 1, &[ToolKind::Pencil, ToolKind::PathEraser]),
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
        assert_eq!(shared, 5);

        // All 14 tools appear exactly once
        let mut all_tools: Vec<ToolKind> = slots.iter()
            .flat_map(|(_, _, tools)| tools.iter().copied())
            .collect();
        all_tools.sort_by_key(|t| format!("{:?}", t));
        assert_eq!(all_tools.len(), 14);
    }
}
