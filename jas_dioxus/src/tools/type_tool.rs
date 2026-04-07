//! Type tool for placing and editing text elements.
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

pub struct TypeTool {
    state: State,
}

impl TypeTool {
    pub fn new() -> Self {
        Self { state: State::Idle }
    }

    #[cfg(test)]
    fn is_idle(&self) -> bool {
        matches!(self.state, State::Idle)
    }

    #[cfg(test)]
    fn drag_extent(&self) -> Option<(f64, f64, f64, f64)> {
        if let State::Dragging { start_x, start_y, cur_x, cur_y } = self.state {
            Some((start_x, start_y, cur_x, cur_y))
        } else {
            None
        }
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

impl CanvasTool for TypeTool {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::model::Model;

    #[test]
    fn new_tool_is_idle() {
        let tool = TypeTool::new();
        assert!(tool.is_idle());
    }

    #[test]
    fn press_transitions_to_dragging() {
        let mut tool = TypeTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 12.0, 34.0, false, false);
        assert!(!tool.is_idle());
        assert_eq!(tool.drag_extent(), Some((12.0, 34.0, 12.0, 34.0)));
    }

    #[test]
    fn move_after_press_updates_cursor() {
        let mut tool = TypeTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_move(&mut model, 50.0, 60.0, false, false, true);
        assert_eq!(tool.drag_extent(), Some((10.0, 20.0, 50.0, 60.0)));
    }

    #[test]
    fn move_without_press_is_noop() {
        let mut tool = TypeTool::new();
        let mut model = Model::default();
        tool.on_move(&mut model, 50.0, 60.0, false, false, true);
        assert!(tool.is_idle());
        assert_eq!(tool.drag_extent(), None);
    }

    #[test]
    fn press_takes_snapshot() {
        let mut tool = TypeTool::new();
        let mut model = Model::default();
        let initial_can_undo = model.can_undo();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        assert!(model.can_undo() && !initial_can_undo,
            "press should record an undo snapshot");
    }

    #[test]
    fn default_text_elem_uses_supplied_geometry() {
        let elem = default_text_elem(10.0, 20.0, 100.0, 50.0, "hello");
        if let Element::Text(t) = elem {
            assert_eq!(t.x, 10.0);
            assert_eq!(t.y, 20.0);
            assert_eq!(t.width, 100.0);
            assert_eq!(t.height, 50.0);
            assert_eq!(t.content, "hello");
            assert_eq!(t.font_family, "sans-serif");
            assert_eq!(t.font_size, 16.0);
            assert!(t.fill.is_some());
            assert!(t.stroke.is_none());
        } else {
            panic!("expected Text element");
        }
    }

    #[test]
    fn default_text_elem_supports_point_text() {
        // Point text uses width=0, height=0
        let elem = default_text_elem(5.0, 5.0, 0.0, 0.0, "x");
        if let Element::Text(t) = elem {
            assert_eq!(t.width, 0.0);
            assert_eq!(t.height, 0.0);
        } else {
            panic!("expected Text element");
        }
    }
}
