//! Text tool for placing and editing text elements.
//!
//! - Click to place point text
//! - Drag to create area text (with width/height bounding box)
//! - Double-click on existing text to edit (opens a browser prompt)

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::model::Model;
use crate::geometry::element::{Color, CommonProps, Element, Fill, TextElem};

use super::tool::{CanvasTool, DRAG_THRESHOLD};

#[derive(Debug, Clone, Copy)]
enum State {
    Idle,
    Dragging {
        start_x: f64,
        start_y: f64,
        cur_x: f64,
        cur_y: f64,
    },
}

pub struct TextTool {
    state: State,
}

impl TextTool {
    pub fn new() -> Self {
        Self { state: State::Idle }
    }
}

fn default_text_elem(x: f64, y: f64, width: f64, height: f64, content: &str) -> Element {
    Element::Text(TextElem {
        x,
        y,
        content: content.to_string(),
        font_family: "sans-serif".to_string(),
        font_size: 16.0,
        font_weight: "normal".to_string(),
        font_style: "normal".to_string(),
        text_decoration: "none".to_string(),
        width,
        height,
        fill: Some(Fill::new(Color::BLACK)),
        stroke: None,
        common: CommonProps::default(),
    })
}

/// Prompt the user for text content via the browser's window.prompt().
fn prompt_text(default: &str) -> Option<String> {
    let window = web_sys::window()?;
    let result = window.prompt_with_message_and_default("Enter text:", default).ok()??;
    if result.is_empty() {
        None
    } else {
        Some(result)
    }
}

impl CanvasTool for TextTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        model.snapshot();
        self.state = State::Dragging {
            start_x: x,
            start_y: y,
            cur_x: x,
            cur_y: y,
        };
    }

    fn on_move(&mut self, _model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool, _dragging: bool) {
        if let State::Dragging {
            start_x, start_y, ..
        } = self.state
        {
            self.state = State::Dragging {
                start_x,
                start_y,
                cur_x: x,
                cur_y: y,
            };
        }
    }

    fn on_release(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        if let State::Dragging {
            start_x, start_y, ..
        } = self.state
        {
            let w = (x - start_x).abs();
            let h = (y - start_y).abs();
            if w > DRAG_THRESHOLD || h > DRAG_THRESHOLD {
                // Area text
                let bx = start_x.min(x);
                let by = start_y.min(y);
                if let Some(content) = prompt_text("Lorem Ipsum") {
                    let elem = default_text_elem(bx, by, w, h, &content);
                    Controller::add_element(model, elem);
                }
            } else {
                // Point text
                if let Some(content) = prompt_text("Lorem Ipsum") {
                    let elem = default_text_elem(start_x, start_y, 0.0, 0.0, &content);
                    Controller::add_element(model, elem);
                }
            }
        }
        self.state = State::Idle;
    }

    fn on_double_click(&mut self, model: &mut Model, x: f64, y: f64) {
        // Find text element under cursor and edit it
        let doc = model.document();
        for (li, layer) in doc.layers.iter().enumerate() {
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate().rev() {
                    if let Element::Text(te) = &**child {
                        let (bx, by, bw, bh) = child.bounds();
                        if x >= bx && x <= bx + bw && y >= by && y <= by + bh {
                            if let Some(new_content) = prompt_text(&te.content) {
                                let path = vec![li, ci];
                                let mut new_te = te.clone();
                                new_te.content = new_content;
                                model.snapshot();
                                let new_doc =
                                    model.document().replace_element(&path, Element::Text(new_te));
                                model.set_document(new_doc);
                            }
                            return;
                        }
                    }
                }
            }
        }
    }

    fn draw_overlay(&self, _model: &Model, ctx: &CanvasRenderingContext2d) {
        if let State::Dragging {
            start_x,
            start_y,
            cur_x,
            cur_y,
        } = self.state
        {
            let rx = start_x.min(cur_x);
            let ry = start_y.min(cur_y);
            let rw = (cur_x - start_x).abs();
            let rh = (cur_y - start_y).abs();
            ctx.set_stroke_style_str("rgb(100,100,100)");
            ctx.set_line_width(1.0);
            ctx.set_line_dash(&js_sys::Array::of2(&4.0.into(), &4.0.into()).into())
                .ok();
            ctx.stroke_rect(rx, ry, rw, rh);
            ctx.set_line_dash(&js_sys::Array::new().into()).ok();
        }
    }
}
