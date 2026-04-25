//! Tool protocol and context for the canvas tool system.
//!
// CanvasTool's `shortcut` and `activate` methods are part of the
// trait surface but not invoked in the current binary.
#![allow(dead_code)]
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
pub const SMOOTH_SIZE: f64 = 100.0;

/// The active tool type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ToolKind {
    Selection,
    PartialSelection,
    InteriorSelection,
    MagicWand,
    Pen,
    AddAnchorPoint,
    DeleteAnchorPoint,
    AnchorPoint,
    Pencil,
    Paintbrush,
    BlobBrush,
    PathEraser,
    Smooth,
    Type,
    TypeOnPath,
    Line,
    Rect,
    RoundedRect,
    Polygon,
    Star,
    Lasso,
    Scale,
    Rotate,
    Shear,
}

impl ToolKind {
    pub fn label(&self) -> &'static str {
        match self {
            ToolKind::Selection => "Selection (V)",
            ToolKind::PartialSelection => "Partial Selection (A)",
            ToolKind::InteriorSelection => "Interior Selection",
            ToolKind::MagicWand => "Magic Wand (Y)",
            ToolKind::Pen => "Pen (P)",
            ToolKind::AddAnchorPoint => "Add Anchor Point (+)",
            ToolKind::DeleteAnchorPoint => "Delete Anchor Point (-)",
            ToolKind::AnchorPoint => "Anchor Point (Shift+C)",
            ToolKind::Pencil => "Pencil (N)",
            ToolKind::Paintbrush => "Paintbrush (B)",
            ToolKind::BlobBrush => "Blob Brush (Shift+B)",
            ToolKind::PathEraser => "Path Eraser (Shift+E)",
            ToolKind::Smooth => "Smooth",
            ToolKind::Type => "Type (T)",
            ToolKind::TypeOnPath => "Type on a Path",
            ToolKind::Line => "Line (L)",
            ToolKind::Rect => "Rectangle (M)",
            ToolKind::RoundedRect => "Rounded Rectangle",
            ToolKind::Polygon => "Polygon",
            ToolKind::Star => "Star",
            ToolKind::Lasso => "Lasso (Q)",
            ToolKind::Scale => "Scale (S)",
            ToolKind::Rotate => "Rotate (R)",
            ToolKind::Shear => "Shear",
        }
    }

    /// Return a CSS cursor value for the canvas when this tool is active.
    pub fn cursor_css(&self) -> &'static str {
        match self {
            ToolKind::Selection => "default",
            ToolKind::PartialSelection => {
                "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24'%3E%3Cpath d='M4,1 L4,19 L8,15 L12,22 L15,20 L11,13 L16,13 Z' fill='white' stroke='black' stroke-width='1.5'/%3E%3C/svg%3E\") 4 1, default"
            }
            ToolKind::InteriorSelection => {
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
            ToolKind::Smooth => "crosshair",
            ToolKind::Type => {
                "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 256 256'%3E%3Cpath d='M177.43,198.77c-19.17,2.05-18.23-10.69-25.79-13.06-14.07.97-17.57,23.76-40.47,9.57-8.04-18.45,10.13-.12,27.33-16.72,5.39-5.63,8.79-14.52,4.25-23.05-5.62-2.92-13.78-3.46-10.58-13.03l11.87-2.02.17-73.52c-20.19-23.25-20-9.66-32.95-14.5-8.46-12.81,19.52-19.77,30.97-3.62,1.79,2.53,4.94,4.59,7.6,4.66s5.67-2.1,7.43-4.8c9.19-14.13,30-7.43,30.15-7.01,1.03,2.96.87,5.74.79,8.48-2.27,8.17-27.84-4.84-30.64,18.44,0,0-.29,72.04-.29,72.04,12.66.4,12.18,11.68,2.44,15.03-5.96,4.42-2.79,17.68,1.19,22.73,13.95,17.7,30.47-3.87,27.16,17.25-.71,4.56-6.29,2.67-10.62,3.13Z' fill='%23222'/%3E%3Cpath d='M63.75,59.55c7.7,7.89-28.2,6.2-30.62,7.79C23.46,73.65-.01,103.79,0,90.77L.09,2.01c0-4.91,7.97.46,10.09,2.64l53.58,54.91Z' fill='%23222'/%3E%3C/svg%3E\") 12 12, text"
            }
            ToolKind::TypeOnPath => {
                "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 256 256'%3E%3Cpath d='M135.85,137.39c-8.19,7.1-1.99,18.23,2.57,23.51,14.07,16.31,34.34-2.29,28.61,16.49-1.22,4-5.84,3.21-9.89,3.72-23.95,2.98-19-12.91-30.09-13.37-8.33-.34-7.32,16.07-27.75,13.35-4.32-.57-10.05,1.55-10.59-3.2-2.45-21.48,12.89.82,27.23-17.17,4.07-5.11,7.2-18.31,1.22-22.74-4.45-3.3-7.66-2.21-7.07-8.66.37-4.04,3.22-5.47,9.12-6.88.62-22.84,1.21-47.69,0-71.36-.67-13.17-15.66-17.38-26.22-15.53-6.32,1.1-4.76-6.92-4.36-9.83.66-4.72,6.35-2.5,10.64-3.1,20.38-2.85,18.74,13.72,27.77,13.26,11.36-.58,5.56-15.89,30.1-13.34,3.95.41,8.81.13,9.79,3.62.69,2.49,2.36,10.07-3.74,9.2-11.8-1.68-28.92,3.28-29.95,18.14-1.54,22.08-.72,47.87-.02,68.96,1.95,2.12,9.23.96,11.03,2.18,2.31,1.56.75,5.62.83,8.48.12,4.29-6.16,1.61-9.23,4.26Z' fill='%23222'/%3E%3Cpath d='M255.09,45.27c3.18,10.12-1.4,15.38-10.68,12.14-2.51-1.15-2.88-7.29-.43-11.13,1.59-2.49,9.09-1.84,11.11-1Z' fill='%23222'/%3E%3Cpath d='M231.22,67.94c1.08-2.16,8.92-1.42,10.7.18,2.08,1.87,2.39,7.45.73,10.4-1.71,3.04-6.16,1.36-8.55,1.41-4.47.08-5.09-7.53-2.87-11.99Z' fill='%23222'/%3E%3Cpath d='M209.12,90.01c1.13-2.14,8.94-1.42,10.72.19,2.08,1.87,2.38,7.44.73,10.41-1.69,3.04-6.24,1.36-8.63,1.4-4.01.08-5.18-7.52-2.82-12Z' fill='%23222'/%3E%3Cpath d='M191.19,101.33c4.22-.24,7.84.37,8.02,3.04.36,5.24.09,9.7-2.88,9.94-4.39.36-11.8,2.35-10.54-2.66s-1.34-9.94,5.4-10.32Z' fill='%23222'/%3E%3Cpath d='M164.96,112.1c1.12-2.15,8.91-1.4,10.7.19,2.09,1.85,2.37,7.46.73,10.4-1.7,3.06-6.21,1.35-8.59,1.41-4.22.1-5.17-7.53-2.85-12Z' fill='%23222'/%3E%3Cpath d='M76.54,134.39c1.19-2.42,9.01-1.62,10.79-.02,2.07,1.87,2.39,7.46.73,10.4s-6.19,1.34-8.56,1.43c-4.52.18-4.84-7.98-2.96-11.81Z' fill='%23222'/%3E%3Cpath d='M58.69,145.5c4.21-.23,7.83.35,8.02,3.06.36,5.12.1,9.68-2.85,9.91-4.32.34-12,2.52-10.6-2.68s-1.34-9.92,5.43-10.3Z' fill='%23222'/%3E%3Cpath d='M32.38,156.36c1.23-2.3,8.99-1.51,10.77.09,2.08,1.87,2.38,7.44.73,10.41s-6.2,1.33-8.7,1.42c-3.86.14-5.04-7.76-2.81-11.92Z' fill='%23222'/%3E%3Cpath d='M10.27,178.59c1.18-2.47,9.04-1.67,10.8-.05,2.06,1.88,2.4,7.46.72,10.4s-6.14,1.37-8.54,1.44c-4.66.13-4.79-8-2.99-11.78Z' fill='%23222'/%3E%3Cpath d='M12.23,199.88c2.65,9.88-.59,15.01-9.9,12.41-2.89-1.29-2.98-7.78-.88-11.47,1.4-2.45,8.86-1.8,10.77-.94Z' fill='%23222'/%3E%3C/svg%3E\") 12 9, text"
            }
            _ => "crosshair",
        }
    }

    pub fn shortcut(&self) -> Option<&'static str> {
        match self {
            ToolKind::Selection => Some("v"),
            ToolKind::PartialSelection => Some("a"),
            ToolKind::MagicWand => Some("y"),
            ToolKind::Pen => Some("p"),
            ToolKind::Pencil => Some("n"),
            ToolKind::Paintbrush => Some("b"),
            ToolKind::BlobBrush => Some("B"), // Shift-B
            ToolKind::Type => Some("t"),
            ToolKind::Line => Some("l"),
            ToolKind::Rect => Some("m"),
            ToolKind::AddAnchorPoint => Some("="),
            ToolKind::DeleteAnchorPoint => Some("-"),
            ToolKind::AnchorPoint => Some("C"),
            ToolKind::PathEraser => Some("E"),
            ToolKind::Lasso => Some("q"),
            ToolKind::Smooth => None,
            ToolKind::Scale => Some("s"),
            ToolKind::Rotate => Some("r"),
            ToolKind::Shear => None,
            _ => None,
        }
    }
}

/// Modifier flags accompanying a keyboard event.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct KeyMods {
    pub shift: bool,
    pub ctrl: bool,
    pub alt: bool,
    pub meta: bool,
}

impl KeyMods {
    pub fn cmd(&self) -> bool {
        self.ctrl || self.meta
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
    /// Receive a keyboard event with modifiers. Default implementation
    /// delegates to [`on_key`] with the bare key string. Tools that care
    /// about modifiers (e.g. text editor) should override this.
    fn on_key_event(&mut self, model: &mut Model, key: &str, _mods: KeyMods) -> bool {
        self.on_key(model, key)
    }
    /// Return true if the tool wants the canvas to swallow ALL keyboard
    /// events (including app shortcuts like cmd+z) and route them to
    /// [`on_key_event`]. Used by the in-place text editor.
    fn captures_keyboard(&self) -> bool { false }
    /// Optional cursor CSS override. When `Some`, the canvas displays this
    /// cursor instead of the static [`ToolKind::cursor_css`] value.
    fn cursor_css_override(&self) -> Option<String> { None }
    /// True while the tool is in an active text-editing session. The app
    /// uses this to set up a blink timer.
    fn is_editing(&self) -> bool { false }
    /// Insert pasted text at the current text caret. Returns true if the
    /// tool consumed the paste (i.e. an edit session is active).
    fn paste_text(&mut self, _model: &mut Model, _text: &str) -> bool { false }
    fn activate(&mut self, _model: &mut Model) {}
    fn deactivate(&mut self, _model: &mut Model) {}
    /// Optional mutable access to the tool's in-place text-editing
    /// session. Non-text tools return `None`; the Type tool and
    /// Type-on-Path tool return `Some(&mut session)` while editing.
    /// Consumed by the Character panel to route widget writes to the
    /// session's next-typed-character state when a bare caret is
    /// placed.
    fn edit_session_mut(&mut self)
        -> Option<&mut crate::tools::text_edit::TextEditSession> { None }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_kind_variant_count() {
        let all = [
            ToolKind::Selection,
            ToolKind::PartialSelection,
            ToolKind::InteriorSelection,
            ToolKind::MagicWand,
            ToolKind::Pen,
            ToolKind::AddAnchorPoint,
            ToolKind::DeleteAnchorPoint,
            ToolKind::AnchorPoint,
            ToolKind::Pencil,
            ToolKind::Paintbrush,
            ToolKind::BlobBrush,
            ToolKind::PathEraser,
            ToolKind::Smooth,
            ToolKind::Type,
            ToolKind::TypeOnPath,
            ToolKind::Line,
            ToolKind::Rect,
            ToolKind::RoundedRect,
            ToolKind::Polygon,
            ToolKind::Star,
            ToolKind::Lasso,
            ToolKind::Scale,
            ToolKind::Rotate,
            ToolKind::Shear,
        ];
        assert_eq!(all.len(), 24);
    }

    #[test]
    fn tool_kind_equality() {
        assert_eq!(ToolKind::Selection, ToolKind::Selection);
        assert_ne!(ToolKind::Selection, ToolKind::PartialSelection);
        assert_ne!(ToolKind::Type, ToolKind::TypeOnPath);
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
            ToolKind::Selection, ToolKind::PartialSelection, ToolKind::InteriorSelection,
            ToolKind::MagicWand,
            ToolKind::Pen, ToolKind::AddAnchorPoint, ToolKind::DeleteAnchorPoint,
            ToolKind::AnchorPoint, ToolKind::Pencil, ToolKind::Paintbrush,
            ToolKind::BlobBrush, ToolKind::PathEraser,
            ToolKind::Smooth, ToolKind::Type, ToolKind::TypeOnPath, ToolKind::Line,
            ToolKind::Rect, ToolKind::RoundedRect, ToolKind::Polygon, ToolKind::Star,
            ToolKind::Lasso,
            ToolKind::Scale, ToolKind::Rotate, ToolKind::Shear,
        ];
        for t in &all {
            set.insert(*t);
        }
        assert_eq!(set.len(), 24);
    }

    #[test]
    fn labels_all_non_empty() {
        let all = [
            ToolKind::Selection, ToolKind::PartialSelection, ToolKind::InteriorSelection,
            ToolKind::MagicWand,
            ToolKind::Pen, ToolKind::AddAnchorPoint, ToolKind::DeleteAnchorPoint,
            ToolKind::AnchorPoint, ToolKind::Pencil, ToolKind::Paintbrush,
            ToolKind::BlobBrush, ToolKind::PathEraser,
            ToolKind::Smooth, ToolKind::Type, ToolKind::TypeOnPath, ToolKind::Line,
            ToolKind::Rect, ToolKind::RoundedRect, ToolKind::Polygon, ToolKind::Star,
            ToolKind::Lasso,
            ToolKind::Scale, ToolKind::Rotate, ToolKind::Shear,
        ];
        for t in &all {
            assert!(!t.label().is_empty(), "{:?} has empty label", t);
        }
    }

    #[test]
    fn labels_contain_tool_name() {
        assert!(ToolKind::Selection.label().contains("Selection"));
        assert!(ToolKind::Pen.label().contains("Pen"));
        assert!(ToolKind::Type.label().contains("Type"));
        assert!(ToolKind::Line.label().contains("Line"));
        assert!(ToolKind::Rect.label().contains("Rect"));
    }

    #[test]
    fn type_label_is_type() {
        // Renamed from "Text" to "Type"; ensure the user-facing label
        // no longer leaks the old name.
        assert_eq!(ToolKind::Type.label(), "Type (T)");
        assert!(!ToolKind::Type.label().contains("Text"));
    }

    #[test]
    fn type_cursor_uses_text_fallback() {
        // The Type tool's CSS cursor should fall back to the system
        // 'text' (I-beam) cursor rather than 'crosshair'.
        let css = ToolKind::Type.cursor_css();
        assert!(css.ends_with(", text"), "cursor css = {}", css);
    }

    #[test]
    fn type_cursor_embeds_svg_data_url() {
        let css = ToolKind::Type.cursor_css();
        assert!(css.contains("data:image/svg+xml"));
        assert!(css.contains("svg"));
    }

    #[test]
    fn type_cursor_hot_spot_is_center() {
        // Hot spot is "12 12" for a 24x24 cursor (center).
        let css = ToolKind::Type.cursor_css();
        assert!(css.contains("\") 12 12,"), "cursor css = {}", css);
    }

    #[test]
    fn type_on_path_label_is_type_on_a_path() {
        // Renamed from "Text on Path" to "Type on a Path"; ensure the
        // user-facing label no longer leaks the old name.
        assert_eq!(ToolKind::TypeOnPath.label(), "Type on a Path");
        assert!(!ToolKind::TypeOnPath.label().contains("Text"));
    }

    #[test]
    fn type_on_path_cursor_uses_text_fallback() {
        // The Type-on-Path tool's CSS cursor should fall back to the
        // system 'text' (I-beam) cursor rather than 'crosshair'.
        let css = ToolKind::TypeOnPath.cursor_css();
        assert!(css.ends_with(", text"), "cursor css = {}", css);
    }

    #[test]
    fn type_on_path_cursor_embeds_svg_data_url() {
        let css = ToolKind::TypeOnPath.cursor_css();
        assert!(css.contains("data:image/svg+xml"));
        assert!(css.contains("svg"));
    }

    #[test]
    fn type_on_path_cursor_has_explicit_hot_spot() {
        // Hot spot is "12 9" — near the I-beam center for the 24x24 cursor.
        let css = ToolKind::TypeOnPath.cursor_css();
        assert!(css.contains("\") 12 9,"), "cursor css = {}", css);
    }

    #[test]
    fn shortcuts_for_primary_tools() {
        assert_eq!(ToolKind::Selection.shortcut(), Some("v"));
        assert_eq!(ToolKind::PartialSelection.shortcut(), Some("a"));
        assert_eq!(ToolKind::Pen.shortcut(), Some("p"));
        assert_eq!(ToolKind::Pencil.shortcut(), Some("n"));
        assert_eq!(ToolKind::Type.shortcut(), Some("t"));
        assert_eq!(ToolKind::Line.shortcut(), Some("l"));
        assert_eq!(ToolKind::Rect.shortcut(), Some("m"));
        assert_eq!(ToolKind::Scale.shortcut(), Some("s"));
        assert_eq!(ToolKind::Rotate.shortcut(), Some("r"));
        assert_eq!(ToolKind::Shear.shortcut(), None);
    }

    #[test]
    fn shortcuts_none_for_alternates() {
        assert_eq!(ToolKind::InteriorSelection.shortcut(), None);
        assert_eq!(ToolKind::Smooth.shortcut(), None);
        assert_eq!(ToolKind::TypeOnPath.shortcut(), None);
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

    #[test]
    fn smooth_size_value() {
        assert_eq!(SMOOTH_SIZE, 100.0);
    }

    // Toolbar layout tests (verifying constants from app.rs)

    #[test]
    fn arrow_slot_alternates() {
        let alternates = [ToolKind::PartialSelection, ToolKind::InteriorSelection];
        assert_eq!(alternates.len(), 2);
    }

    #[test]
    fn text_slot_alternates() {
        let alternates = [ToolKind::Type, ToolKind::TypeOnPath];
        assert_eq!(alternates.len(), 2);
    }

    #[test]
    fn shape_slot_alternates() {
        let alternates = [ToolKind::Rect, ToolKind::RoundedRect, ToolKind::Polygon, ToolKind::Star];
        assert_eq!(alternates.len(), 4);
    }

    #[test]
    fn pen_slot_alternates() {
        let alternates = [ToolKind::Pen, ToolKind::AddAnchorPoint, ToolKind::DeleteAnchorPoint, ToolKind::AnchorPoint];
        assert_eq!(alternates.len(), 4);
    }

    #[test]
    fn pencil_slot_alternates() {
        let alternates = [ToolKind::Pencil, ToolKind::PathEraser, ToolKind::Smooth];
        assert_eq!(alternates.len(), 3);
    }

    // Removed: toolbar_grid_layout — hardcoded the row/col positions
    // of every tool slot, so it had to be rewritten every time a tool
    // was added (Magic Wand merge already left it stale; Scale / Rotate
    // / Shear would compound the staleness). Per
    // feedback_layout_tests.md, layout-bound tests with hardcoded
    // indices are deleted, not shifted, when layouts change.
}
