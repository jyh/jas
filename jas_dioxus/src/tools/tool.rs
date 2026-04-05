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
