//! Rounded Rectangle tool — press-drag-release to create rectangles with rounded corners.

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::model::Model;
use crate::geometry::element::{
    Color, CommonProps, Element, Fill, RectElem, Stroke,
};

use super::tool::CanvasTool;

/// Default corner radius (in points) for new rounded rectangles.
pub const ROUNDED_RECT_RADIUS: f64 = 10.0;

#[derive(Debug, Clone, Copy)]
enum State {
    Idle,
    Drawing { start_x: f64, start_y: f64, cur_x: f64, cur_y: f64 },
}

pub struct RoundedRectTool {
    state: State,
}

impl RoundedRectTool {
    pub fn new() -> Self {
        Self { state: State::Idle }
    }
}

impl CanvasTool for RoundedRectTool {
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
                    rx: ROUNDED_RECT_RADIUS,
                    ry: ROUNDED_RECT_RADIUS,
                    fill: model.default_fill,
                    stroke: model.default_stroke,
                    common: CommonProps::default(),
                                    fill_gradient: None,
                    stroke_gradient: None,
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
            // Draw a rounded-rect overlay using arcs.
            let r = ROUNDED_RECT_RADIUS.min(rw / 2.0).min(rh / 2.0);
            ctx.begin_path();
            ctx.move_to(rx + r, ry);
            ctx.line_to(rx + rw - r, ry);
            ctx.quadratic_curve_to(rx + rw, ry, rx + rw, ry + r);
            ctx.line_to(rx + rw, ry + rh - r);
            ctx.quadratic_curve_to(rx + rw, ry + rh, rx + rw - r, ry + rh);
            ctx.line_to(rx + r, ry + rh);
            ctx.quadratic_curve_to(rx, ry + rh, rx, ry + rh - r);
            ctx.line_to(rx, ry + r);
            ctx.quadratic_curve_to(rx, ry, rx + r, ry);
            ctx.close_path();
            ctx.stroke();
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
    fn draw_rounded_rect() {
        let mut tool = RoundedRectTool::new();
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
            assert_eq!(r.rx, ROUNDED_RECT_RADIUS);
            assert_eq!(r.ry, ROUNDED_RECT_RADIUS);
        } else {
            panic!("expected Rect element");
        }
    }

    #[test]
    fn zero_size_not_created() {
        let mut tool = RoundedRectTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_release(&mut model, 10.0, 20.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 0);
    }

    #[test]
    fn negative_drag_normalizes() {
        let mut tool = RoundedRectTool::new();
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
            assert_eq!(r.rx, ROUNDED_RECT_RADIUS);
        } else {
            panic!("expected Rect element");
        }
    }

    #[test]
    fn radius_default_is_ten() {
        assert_eq!(ROUNDED_RECT_RADIUS, 10.0);
    }
}
