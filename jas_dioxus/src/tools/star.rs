//! Star tool — press-drag-release to create stars within a bounding box.

use std::f64::consts::PI;

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::model::Model;
use crate::geometry::element::{Color, CommonProps, Element, PolygonElem, Stroke};

use super::tool::CanvasTool;

/// Default number of points (outer vertices) for new stars.
pub const STAR_POINTS: usize = 5;

/// Ratio of inner radius to outer radius.
const INNER_RATIO: f64 = 0.4;

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

pub struct StarTool {
    state: State,
}

impl StarTool {
    pub fn new() -> Self {
        Self { state: State::Idle }
    }
}

/// Compute vertices of a star inscribed in the given bounding box. The star
/// has `points` outer vertices, alternating with `points` inner vertices, for
/// 2 * points total. The first outer point is placed at the top of the box.
fn star_points(sx: f64, sy: f64, ex: f64, ey: f64, points: usize) -> Vec<(f64, f64)> {
    let cx = (sx + ex) / 2.0;
    let cy = (sy + ey) / 2.0;
    let rx_outer = (ex - sx).abs() / 2.0;
    let ry_outer = (ey - sy).abs() / 2.0;
    let rx_inner = rx_outer * INNER_RATIO;
    let ry_inner = ry_outer * INNER_RATIO;
    let n = points * 2;
    let theta0 = -PI / 2.0;
    (0..n)
        .map(|k| {
            let angle = theta0 + PI * k as f64 / points as f64;
            let (rx, ry) = if k % 2 == 0 {
                (rx_outer, ry_outer)
            } else {
                (rx_inner, ry_inner)
            };
            (cx + rx * angle.cos(), cy + ry * angle.sin())
        })
        .collect()
}

fn draw_star_preview(ctx: &CanvasRenderingContext2d, pts: &[(f64, f64)]) {
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

impl CanvasTool for StarTool {
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
            let rw = (x - start_x).abs();
            let rh = (y - start_y).abs();
            if rw > 1.0 && rh > 1.0 {
                let pts = star_points(start_x, start_y, x, y, STAR_POINTS);
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
            let pts = star_points(start_x, start_y, cur_x, cur_y, STAR_POINTS);
            ctx.set_stroke_style_str("rgb(100,100,100)");
            ctx.set_line_width(1.0);
            ctx.set_line_dash(&js_sys::Array::of2(&4.0.into(), &4.0.into()).into()).ok();
            draw_star_preview(ctx, &pts);
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
    fn star_points_default_is_five() {
        assert_eq!(STAR_POINTS, 5);
    }

    #[test]
    fn star_points_count_is_double_outer() {
        let pts = star_points(0.0, 0.0, 100.0, 100.0, 5);
        assert_eq!(pts.len(), 10);
    }

    #[test]
    fn star_points_first_at_top() {
        let pts = star_points(0.0, 0.0, 100.0, 100.0, 5);
        // First outer point should be directly above center.
        assert!((pts[0].0 - 50.0).abs() < 1e-9);
        assert!((pts[0].1 - 0.0).abs() < 1e-9);
    }

    #[test]
    fn star_points_alternate_inner_outer() {
        // For a square bounding box, outer radius is 50, inner is 50 * 0.4 = 20.
        let pts = star_points(0.0, 0.0, 100.0, 100.0, 5);
        let center = (50.0, 50.0);
        for (i, (x, y)) in pts.iter().enumerate() {
            let dx = x - center.0;
            let dy = y - center.1;
            let r = (dx * dx + dy * dy).sqrt();
            let expected = if i % 2 == 0 { 50.0 } else { 20.0 };
            assert!((r - expected).abs() < 1e-9, "point {} radius {} != {}", i, r, expected);
        }
    }

    #[test]
    fn draw_star() {
        let mut tool = StarTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_release(&mut model, 110.0, 120.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Polygon(p) = &*children[0] {
            assert_eq!(p.points.len(), STAR_POINTS * 2);
        } else {
            panic!("expected Polygon element");
        }
    }

    #[test]
    fn zero_size_not_created() {
        let mut tool = StarTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_release(&mut model, 10.0, 20.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 0);
    }

    #[test]
    fn negative_drag_normalizes() {
        let mut tool = StarTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 100.0, 100.0, false, false);
        tool.on_release(&mut model, 0.0, 0.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Polygon(p) = &*children[0] {
            // Should still produce 10 points.
            assert_eq!(p.points.len(), 10);
            // First point should be at top of bounding box (center.x, top).
            assert!((p.points[0].0 - 50.0).abs() < 1e-9);
            assert!((p.points[0].1 - 0.0).abs() < 1e-9);
        } else {
            panic!("expected Polygon element");
        }
    }
}
