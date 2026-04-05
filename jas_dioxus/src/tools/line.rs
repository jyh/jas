//! Line tool — press-drag-release to create line segments.

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::model::Model;
use crate::geometry::element::{Color, CommonProps, Element, LineElem, Stroke};

use super::tool::CanvasTool;

#[derive(Debug, Clone, Copy)]
enum State {
    Idle,
    Drawing { start_x: f64, start_y: f64, cur_x: f64, cur_y: f64 },
}

pub struct LineTool {
    state: State,
}

impl LineTool {
    pub fn new() -> Self {
        Self { state: State::Idle }
    }
}

impl CanvasTool for LineTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        model.snapshot();
        self.state = State::Drawing {
            start_x: x,
            start_y: y,
            cur_x: x,
            cur_y: y,
        };
    }

    fn on_move(&mut self, _model: &mut Model, x: f64, y: f64, _shift: bool, _dragging: bool) {
        if let State::Drawing { start_x, start_y, .. } = self.state {
            self.state = State::Drawing {
                start_x,
                start_y,
                cur_x: x,
                cur_y: y,
            };
        }
    }

    fn on_release(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        if let State::Drawing { start_x, start_y, .. } = self.state {
            let dist = ((x - start_x).powi(2) + (y - start_y).powi(2)).sqrt();
            if dist > 2.0 {
                let elem = Element::Line(LineElem {
                    x1: start_x,
                    y1: start_y,
                    x2: x,
                    y2: y,
                    stroke: Some(Stroke::new(Color::BLACK, 1.0)),
                    common: CommonProps::default(),
                });
                Controller::add_element(model, elem);
            }
        }
        self.state = State::Idle;
    }

    fn draw_overlay(&self, _model: &Model, ctx: &CanvasRenderingContext2d) {
        if let State::Drawing {
            start_x,
            start_y,
            cur_x,
            cur_y,
        } = self.state
        {
            ctx.set_stroke_style_str("rgba(0, 0, 0, 0.5)");
            ctx.set_line_width(1.0);
            ctx.begin_path();
            ctx.move_to(start_x, start_y);
            ctx.line_to(cur_x, cur_y);
            ctx.stroke();
        }
    }
}
