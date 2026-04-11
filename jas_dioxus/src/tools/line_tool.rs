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

/// Check whether the tool is currently idle.
#[cfg(test)]
impl LineTool {
    fn is_idle(&self) -> bool {
        matches!(self.state, State::Idle)
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

    fn on_move(&mut self, _model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool, _dragging: bool) {
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
                    stroke: model.default_stroke,
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::model::Model;
    use crate::geometry::element::Element;

    #[test]
    fn draw_line() {
        let mut tool = LineTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_move(&mut model, 30.0, 40.0, false, false, true);
        tool.on_release(&mut model, 50.0, 60.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Line(line) = &*children[0] {
            assert_eq!(line.x1, 10.0);
            assert_eq!(line.y1, 20.0);
            assert_eq!(line.x2, 50.0);
            assert_eq!(line.y2, 60.0);
        } else {
            panic!("expected Line element");
        }
    }

    #[test]
    fn short_line_not_created() {
        let mut tool = LineTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_release(&mut model, 10.0, 20.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 0);
    }

    #[test]
    fn idle_after_release() {
        let mut tool = LineTool::new();
        let mut model = Model::default();
        assert!(tool.is_idle());
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        assert!(!tool.is_idle());
        tool.on_release(&mut model, 50.0, 60.0, false, false);
        assert!(tool.is_idle());
    }

    #[test]
    fn move_without_press_is_noop() {
        let mut tool = LineTool::new();
        let mut model = Model::default();
        tool.on_move(&mut model, 50.0, 60.0, false, false, true);
        assert!(tool.is_idle());
    }
}
