//! Rectangle tool — press-drag-release to create rectangles.

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::model::Model;
use crate::geometry::element::{
    Color, CommonProps, Element, Fill, RectElem, Stroke,
};

use super::tool::CanvasTool;

#[derive(Debug, Clone, Copy)]
enum State {
    Idle,
    Drawing { start_x: f64, start_y: f64, cur_x: f64, cur_y: f64 },
}

pub struct RectTool {
    state: State,
}

impl RectTool {
    pub fn new() -> Self {
        Self { state: State::Idle }
    }
}

impl CanvasTool for RectTool {
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
            let rx = start_x.min(x);
            let ry = start_y.min(y);
            let rw = (x - start_x).abs();
            let rh = (y - start_y).abs();
            if rw > 1.0 && rh > 1.0 {
                let elem = Element::Rect(RectElem {
                    x: rx,
                    y: ry,
                    width: rw,
                    height: rh,
                    rx: 0.0,
                    ry: 0.0,
                    fill: Some(Fill::new(Color::WHITE)),
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
            let rx = start_x.min(cur_x);
            let ry = start_y.min(cur_y);
            let rw = (cur_x - start_x).abs();
            let rh = (cur_y - start_y).abs();
            ctx.set_stroke_style_str("rgba(0, 0, 0, 0.5)");
            ctx.set_line_width(1.0);
            ctx.set_line_dash(&wasm_bindgen::JsValue::from(
                js_sys::Array::of2(&4.0.into(), &4.0.into()),
            ))
            .ok();
            ctx.stroke_rect(rx, ry, rw, rh);
            ctx.set_line_dash(&wasm_bindgen::JsValue::from(js_sys::Array::new())).ok();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::model::Model;
    use crate::geometry::element::Element;

    #[test]
    fn draw_rect() {
        let mut tool = RectTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_release(&mut model, 110.0, 70.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Rect(r) = &*children[0] {
            assert_eq!(r.x, 10.0);
            assert_eq!(r.y, 20.0);
            assert_eq!(r.width, 100.0);
            assert_eq!(r.height, 50.0);
        } else {
            panic!("expected Rect element");
        }
    }

    #[test]
    fn zero_size_rect_not_created() {
        let mut tool = RectTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_release(&mut model, 10.0, 20.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 0);
    }

    #[test]
    fn negative_drag_normalizes() {
        let mut tool = RectTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 100.0, 80.0, false, false);
        tool.on_release(&mut model, 10.0, 20.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Rect(r) = &*children[0] {
            assert_eq!(r.x, 10.0);
            assert_eq!(r.y, 20.0);
            assert_eq!(r.width, 90.0);
            assert_eq!(r.height, 60.0);
        } else {
            panic!("expected Rect element");
        }
    }
}
