//! Polygon tool — press-drag-release to create regular polygons.

use std::f64::consts::PI;

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::model::Model;
use crate::geometry::element::{Color, CommonProps, Element, PolygonElem, Stroke};

use super::tool::{CanvasTool, POLYGON_SIDES};

#[derive(Debug, Clone, Copy)]
enum State {
    Idle,
    Drawing {
        start_x: f64,
        start_y: f64,
        cur_x: f64,
        cur_y: f64,
    },
}

pub struct PolygonTool {
    state: State,
}

impl PolygonTool {
    pub fn new() -> Self {
        Self { state: State::Idle }
    }
}

/// Compute vertices of a regular N-gon where the first edge runs from (x1,y1) to (x2,y2).
fn regular_polygon_points(
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    n: usize,
) -> Vec<(f64, f64)> {
    let ex = x2 - x1;
    let ey = y2 - y1;
    let s = (ex * ex + ey * ey).sqrt();
    if s == 0.0 {
        return vec![(x1, y1); n];
    }
    let mx = (x1 + x2) / 2.0;
    let my = (y1 + y2) / 2.0;
    let px = -ey / s;
    let py = ex / s;
    let d = s / (2.0 * (PI / n as f64).tan());
    let cx = mx + d * px;
    let cy = my + d * py;
    let r = s / (2.0 * (PI / n as f64).sin());
    let theta0 = (y1 - cy).atan2(x1 - cx);
    (0..n)
        .map(|k| {
            let angle = theta0 + 2.0 * PI * k as f64 / n as f64;
            (cx + r * angle.cos(), cy + r * angle.sin())
        })
        .collect()
}

fn draw_polygon_preview(ctx: &CanvasRenderingContext2d, pts: &[(f64, f64)]) {
    if pts.is_empty() {
        return;
    }
    ctx.begin_path();
    ctx.move_to(pts[0].0, pts[0].1);
    for &(x, y) in &pts[1..] {
        ctx.line_to(x, y);
    }
    ctx.close_path();
    ctx.stroke();
}

impl CanvasTool for PolygonTool {
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
        if let State::Drawing {
            start_x, start_y, ..
        } = self.state
        {
            self.state = State::Drawing {
                start_x,
                start_y,
                cur_x: x,
                cur_y: y,
            };
        }
    }

    fn on_release(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        if let State::Drawing {
            start_x, start_y, ..
        } = self.state
        {
            let dist = ((x - start_x).powi(2) + (y - start_y).powi(2)).sqrt();
            if dist > 2.0 {
                let pts = regular_polygon_points(start_x, start_y, x, y, POLYGON_SIDES);
                let elem = Element::Polygon(PolygonElem {
                    points: pts,
                    fill: None,
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
            let pts = regular_polygon_points(start_x, start_y, cur_x, cur_y, POLYGON_SIDES);
            ctx.set_stroke_style_str("rgb(100,100,100)");
            ctx.set_line_width(1.0);
            ctx.set_line_dash(&js_sys::Array::of2(&4.0.into(), &4.0.into()).into()).ok();
            draw_polygon_preview(ctx, &pts);
            ctx.set_line_dash(&js_sys::Array::new().into()).ok();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::model::Model;
    use crate::geometry::element::Element;

    #[test]
    fn draw_polygon() {
        let mut tool = PolygonTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_release(&mut model, 100.0, 50.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Polygon(p) = &*children[0] {
            assert_eq!(p.points.len(), POLYGON_SIDES);
        } else {
            panic!("expected Polygon element");
        }
    }

    #[test]
    fn short_drag_no_polygon() {
        let mut tool = PolygonTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_release(&mut model, 50.0, 50.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 0);
    }
}
