//! Text-on-path tool for placing text along a curve.
//!
//! Supports three modes:
//! 1. Drag to create a new text-on-path element with an auto-generated curve.
//! 2. Click on an existing Path element to convert it to a TextPath.
//! 3. Drag the start-offset handle to reposition text along the path.

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::model::Model;
use crate::geometry::element::{
    Color, CommonProps, Element, Fill, PathCommand, TextPathElem,
};
use crate::geometry::measure::{path_closest_offset, path_distance_to_point, path_point_at_offset};

use super::tool::{CanvasTool, DRAG_THRESHOLD, HIT_RADIUS};

const OFFSET_HANDLE_RADIUS: f64 = 5.0;

#[derive(Debug, Clone)]
enum State {
    Idle,
    DragCreate {
        start_x: f64,
        start_y: f64,
        cur_x: f64,
        cur_y: f64,
        control: Option<(f64, f64)>,
    },
    OffsetDrag {
        path: Vec<usize>,
        preview: Option<f64>,
    },
}

pub struct TextPathTool {
    state: State,
}

impl TextPathTool {
    pub fn new() -> Self {
        Self { state: State::Idle }
    }

    /// Check if (x, y) is near the start-offset handle of a selected TextPath.
    fn find_offset_handle(model: &Model, x: f64, y: f64) -> Option<(Vec<usize>, f64)> {
        let doc = model.document();
        for es in &doc.selection {
            if let Some(Element::TextPath(e)) = doc.get_element(&es.path) {
                if !e.d.is_empty() {
                    let (hx, hy) = path_point_at_offset(&e.d, e.start_offset);
                    if (x - hx).abs() <= OFFSET_HANDLE_RADIUS + 2.0
                        && (y - hy).abs() <= OFFSET_HANDLE_RADIUS + 2.0
                    {
                        return Some((es.path.clone(), e.start_offset));
                    }
                }
            }
        }
        None
    }

    /// Hit-test Path or TextPath curves in the document.
    fn hit_test_path_curve(model: &Model, x: f64, y: f64) -> Option<(Vec<usize>, Element)> {
        let doc = model.document();
        let threshold = HIT_RADIUS + 2.0;
        for (li, layer) in doc.layers.iter().enumerate() {
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate() {
                    match &**child {
                        Element::Path(e) => {
                            let dist = path_distance_to_point(&e.d, x, y);
                            if dist <= threshold {
                                return Some((vec![li, ci], (**child).clone()));
                            }
                        }
                        Element::TextPath(e) => {
                            let dist = path_distance_to_point(&e.d, x, y);
                            if dist <= threshold {
                                return Some((vec![li, ci], (**child).clone()));
                            }
                        }
                        Element::Group(g) if !child.common().locked => {
                            for (gi, gc) in g.children.iter().enumerate() {
                                match &**gc {
                                    Element::Path(e) => {
                                        let dist = path_distance_to_point(&e.d, x, y);
                                        if dist <= threshold {
                                            return Some((vec![li, ci, gi], (**gc).clone()));
                                        }
                                    }
                                    Element::TextPath(e) => {
                                        let dist = path_distance_to_point(&e.d, x, y);
                                        if dist <= threshold {
                                            return Some((vec![li, ci, gi], (**gc).clone()));
                                        }
                                    }
                                    _ => {}
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
        None
    }
}

/// Prompt the user for text content via the browser's window.prompt().
fn prompt_text(default: &str) -> Option<String> {
    let window = web_sys::window()?;
    let result = window
        .prompt_with_message_and_default("Enter text:", default)
        .ok()??;
    if result.is_empty() {
        None
    } else {
        Some(result)
    }
}

impl CanvasTool for TextPathTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        model.snapshot();

        // 1) Check offset handle drag on selected TextPath
        if let Some((path, _)) = Self::find_offset_handle(model, x, y) {
            self.state = State::OffsetDrag {
                path,
                preview: None,
            };
            return;
        }

        // 2) Start drag-create
        self.state = State::DragCreate {
            start_x: x,
            start_y: y,
            cur_x: x,
            cur_y: y,
            control: None,
        };
    }

    fn on_move(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _dragging: bool) {
        match &mut self.state {
            State::OffsetDrag { path, preview } => {
                if let Some(Element::TextPath(e)) = model.document().get_element(path) {
                    if !e.d.is_empty() {
                        *preview = Some(path_closest_offset(&e.d, x, y));
                    }
                }
            }
            State::DragCreate {
                start_x,
                start_y,
                cur_x,
                cur_y,
                control,
            } => {
                *cur_x = x;
                *cur_y = y;
                let sx = *start_x;
                let sy = *start_y;
                let dx = x - sx;
                let dy = y - sy;
                let dist = (dx * dx + dy * dy).sqrt();
                if dist > DRAG_THRESHOLD {
                    // Perpendicular control point for a nice curve
                    let nx = -dy / dist;
                    let ny = dx / dist;
                    let mx = (sx + x) / 2.0;
                    let my = (sy + y) / 2.0;
                    *control = Some((mx + nx * dist * 0.3, my + ny * dist * 0.3));
                }
            }
            State::Idle => {}
        }
    }

    fn on_release(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        let state = std::mem::replace(&mut self.state, State::Idle);
        match state {
            State::OffsetDrag { path, preview } => {
                if let Some(new_offset) = preview {
                    if let Some(Element::TextPath(e)) = model.document().get_element(&path) {
                        let mut new_e = e.clone();
                        new_e.start_offset = new_offset;
                        let new_doc =
                            model.document().replace_element(&path, Element::TextPath(new_e));
                        model.set_document(new_doc);
                    }
                }
            }
            State::DragCreate {
                start_x,
                start_y,
                control,
                ..
            } => {
                let w = (x - start_x).abs();
                let h = (y - start_y).abs();

                if w <= DRAG_THRESHOLD && h <= DRAG_THRESHOLD {
                    // Click (not drag): check if we hit a Path to convert
                    if let Some((path, elem)) = Self::hit_test_path_curve(model, x, y) {
                        match &elem {
                            Element::Path(pe) => {
                                // Convert Path to TextPath
                                let offset = path_closest_offset(&pe.d, x, y);
                                if let Some(content) = prompt_text("") {
                                    let tp = Element::TextPath(TextPathElem {
                                        d: pe.d.clone(),
                                        content,
                                        start_offset: offset,
                                        font_family: "sans-serif".to_string(),
                                        font_size: 16.0,
                                        font_weight: "normal".to_string(),
                                        font_style: "normal".to_string(),
                                        text_decoration: "none".to_string(),
                                        fill: Some(Fill::new(Color::BLACK)),
                                        stroke: None,
                                        common: CommonProps::default(),
                                    });
                                    let new_doc = model.document().replace_element(&path, tp);
                                    model.set_document(new_doc);
                                    Controller::select_element(model, &path);
                                }
                            }
                            Element::TextPath(te) => {
                                // Click on existing TextPath: edit text
                                Controller::select_element(model, &path);
                                if let Some(content) = prompt_text(&te.content) {
                                    let mut new_e = te.clone();
                                    new_e.content = content;
                                    let new_doc = model
                                        .document()
                                        .replace_element(&path, Element::TextPath(new_e));
                                    model.set_document(new_doc);
                                }
                            }
                            _ => {}
                        }
                    }
                } else {
                    // Drag: create a new text-on-path element
                    let d = if let Some((cx, cy)) = control {
                        vec![
                            PathCommand::MoveTo { x: start_x, y: start_y },
                            PathCommand::CurveTo { x1: cx, y1: cy, x2: cx, y2: cy, x, y },
                        ]
                    } else {
                        vec![
                            PathCommand::MoveTo { x: start_x, y: start_y },
                            PathCommand::LineTo { x, y },
                        ]
                    };
                    if let Some(content) = prompt_text("Lorem Ipsum") {
                        let elem = Element::TextPath(TextPathElem {
                            d,
                            content,
                            start_offset: 0.0,
                            font_family: "sans-serif".to_string(),
                            font_size: 16.0,
                            font_weight: "normal".to_string(),
                            font_style: "normal".to_string(),
                            text_decoration: "none".to_string(),
                            fill: Some(Fill::new(Color::BLACK)),
                            stroke: None,
                            common: CommonProps::default(),
                        });
                        Controller::add_element(model, elem);
                        // Select the newly created element
                        let doc = model.document();
                        let li = doc.selected_layer;
                        let ci = doc.layers[li].children().map_or(0, |c| c.len() - 1);
                        let path = vec![li, ci];
                        Controller::select_element(model, &path);
                    }
                }
            }
            State::Idle => {}
        }
    }

    fn on_double_click(&mut self, model: &mut Model, x: f64, y: f64) {
        if let Some((path, elem)) = Self::hit_test_path_curve(model, x, y) {
            if let Element::TextPath(te) = &elem {
                Controller::select_element(model, &path);
                if let Some(content) = prompt_text(&te.content) {
                    model.snapshot();
                    let mut new_e = te.clone();
                    new_e.content = content;
                    let new_doc = model
                        .document()
                        .replace_element(&path, Element::TextPath(new_e));
                    model.set_document(new_doc);
                }
            }
        }
    }

    fn draw_overlay(&self, model: &Model, ctx: &CanvasRenderingContext2d) {
        // Draw drag-create preview curve
        if let State::DragCreate {
            start_x,
            start_y,
            cur_x,
            cur_y,
            control,
        } = &self.state
        {
            ctx.set_stroke_style_str("rgb(100,100,100)");
            ctx.set_line_width(1.0);
            ctx.set_line_dash(&js_sys::Array::of2(&4.0.into(), &4.0.into()).into())
                .ok();
            ctx.begin_path();
            ctx.move_to(*start_x, *start_y);
            if let Some((cx, cy)) = control {
                ctx.bezier_curve_to(*cx, *cy, *cx, *cy, *cur_x, *cur_y);
            } else {
                ctx.line_to(*cur_x, *cur_y);
            }
            ctx.stroke();
            ctx.set_line_dash(&js_sys::Array::new().into()).ok();
        }

        // Draw offset handle for selected TextPath elements
        let doc = model.document();
        for es in &doc.selection {
            if let Some(Element::TextPath(e)) = doc.get_element(&es.path) {
                if e.d.is_empty() {
                    continue;
                }
                let offset = if let State::OffsetDrag { path, preview } = &self.state {
                    if path == &es.path {
                        preview.unwrap_or(e.start_offset)
                    } else {
                        e.start_offset
                    }
                } else {
                    e.start_offset
                };
                let (hx, hy) = path_point_at_offset(&e.d, offset);
                let r = OFFSET_HANDLE_RADIUS;

                // Diamond shape
                ctx.set_stroke_style_str("rgb(255,140,0)");
                ctx.set_line_width(1.5);
                ctx.set_fill_style_str("rgb(255,200,80)");
                ctx.begin_path();
                ctx.move_to(hx, hy - r);
                ctx.line_to(hx + r, hy);
                ctx.line_to(hx, hy + r);
                ctx.line_to(hx - r, hy);
                ctx.close_path();
                ctx.fill();
                ctx.stroke();
            }
        }
    }
}
