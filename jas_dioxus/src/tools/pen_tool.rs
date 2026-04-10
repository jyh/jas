//! Pen tool for constructing Bezier paths.
//!
//! State machine:
//!   IDLE     — no points placed yet
//!   PLACING  — points placed, waiting for next click
//!   DRAGGING — dragging a handle after placing a point

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::model::Model;
use crate::geometry::element::{
    Color, CommonProps, Element, PathCommand, PathElem, Stroke,
};

use super::tool::{CanvasTool, HANDLE_DRAW_SIZE, HIT_RADIUS};

const PEN_CLOSE_RADIUS: f64 = HIT_RADIUS;

#[derive(Debug, Clone, Copy, PartialEq)]
enum State {
    Idle,
    Placing,
    Dragging,
}

/// A control point in the pen tool's in-progress path.
#[derive(Debug, Clone)]
struct PenPoint {
    x: f64,
    y: f64,
    hx_in: f64,
    hy_in: f64,
    hx_out: f64,
    hy_out: f64,
    smooth: bool,
}

impl PenPoint {
    fn new(x: f64, y: f64) -> Self {
        Self {
            x,
            y,
            hx_in: x,
            hy_in: y,
            hx_out: x,
            hy_out: y,
            smooth: false,
        }
    }
}

pub struct PenTool {
    points: Vec<PenPoint>,
    state: State,
    mouse_x: f64,
    mouse_y: f64,
}

impl PenTool {
    pub fn new() -> Self {
        Self {
            points: Vec::new(),
            state: State::Idle,
            mouse_x: 0.0,
            mouse_y: 0.0,
        }
    }

    fn finish(&mut self, model: &mut Model, close: bool) {
        if self.points.len() < 2 {
            self.points.clear();
            self.state = State::Idle;
            return;
        }

        let p0 = &self.points[0];
        let mut do_close = close;

        // Auto-close if last point is near first
        if !do_close && self.points.len() >= 3 {
            let pn = self.points.last().unwrap();
            if hypot(pn.x - p0.x, pn.y - p0.y) <= PEN_CLOSE_RADIUS {
                do_close = true;
            }
        }

        let mut cmds: Vec<PathCommand> = Vec::new();
        cmds.push(PathCommand::MoveTo {
            x: p0.x,
            y: p0.y,
        });

        // Determine how many points to use (skip last if it overlaps first on close)
        let mut n = self.points.len();
        if do_close && n >= 3 {
            let pn = &self.points[n - 1];
            if hypot(pn.x - p0.x, pn.y - p0.y) <= PEN_CLOSE_RADIUS {
                n -= 1;
            }
        }

        for i in 1..n {
            let prev = &self.points[i - 1];
            let curr = &self.points[i];
            cmds.push(PathCommand::CurveTo {
                x1: prev.hx_out,
                y1: prev.hy_out,
                x2: curr.hx_in,
                y2: curr.hy_in,
                x: curr.x,
                y: curr.y,
            });
        }

        if do_close {
            let last = &self.points[n - 1];
            let p0 = &self.points[0];
            cmds.push(PathCommand::CurveTo {
                x1: last.hx_out,
                y1: last.hy_out,
                x2: p0.hx_in,
                y2: p0.hy_in,
                x: p0.x,
                y: p0.y,
            });
            cmds.push(PathCommand::ClosePath);
        }

        let elem = Element::Path(PathElem {
            d: cmds,
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            common: CommonProps::default(),
        });
        Controller::add_element(model, elem);
        self.points.clear();
        self.state = State::Idle;
    }
}

fn hypot(dx: f64, dy: f64) -> f64 {
    (dx * dx + dy * dy).sqrt()
}

impl CanvasTool for PenTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        model.snapshot();

        // Check if clicking near the first point to close the path
        if self.points.len() >= 2 {
            let p0 = &self.points[0];
            if hypot(x - p0.x, y - p0.y) <= PEN_CLOSE_RADIUS {
                self.finish(model, true);
                return;
            }
        }

        self.state = State::Dragging;
        self.points.push(PenPoint::new(x, y));
    }

    fn on_move(&mut self, _model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool, _dragging: bool) {
        self.mouse_x = x;
        self.mouse_y = y;

        if self.state == State::Dragging
            && let Some(pt) = self.points.last_mut() {
                pt.hx_out = x;
                pt.hy_out = y;
                // Mirror the incoming handle
                pt.hx_in = 2.0 * pt.x - x;
                pt.hy_in = 2.0 * pt.y - y;
                pt.smooth = true;
            }
    }

    fn on_release(&mut self, _model: &mut Model, _x: f64, _y: f64, _shift: bool, _alt: bool) {
        if self.state == State::Dragging {
            self.state = State::Placing;
        }
    }

    fn on_double_click(&mut self, model: &mut Model, _x: f64, _y: f64) {
        if !self.points.is_empty() {
            self.points.pop();
        }
        self.finish(model, false);
    }

    fn on_key(&mut self, model: &mut Model, key: &str) -> bool {
        if !self.points.is_empty() && matches!(key, "Escape" | "Enter") {
            self.finish(model, false);
            return true;
        }
        false
    }

    fn deactivate(&mut self, model: &mut Model) {
        if !self.points.is_empty() {
            self.finish(model, false);
        }
    }

    fn draw_overlay(&self, _model: &Model, ctx: &CanvasRenderingContext2d) {
        if self.points.is_empty() {
            return;
        }

        // Draw committed curve segments
        if self.points.len() >= 2 {
            ctx.set_stroke_style_str("black");
            ctx.set_line_width(1.0);
            ctx.begin_path();
            let p0 = &self.points[0];
            ctx.move_to(p0.x, p0.y);
            for i in 1..self.points.len() {
                let prev = &self.points[i - 1];
                let curr = &self.points[i];
                ctx.bezier_curve_to(
                    prev.hx_out,
                    prev.hy_out,
                    curr.hx_in,
                    curr.hy_in,
                    curr.x,
                    curr.y,
                );
            }
            ctx.stroke();
        }

        // Draw preview curve from last point to mouse
        if self.state != State::Dragging {
            let last = self.points.last().unwrap();
            let mx = self.mouse_x;
            let my = self.mouse_y;
            let p0 = &self.points[0];
            let near_start =
                self.points.len() >= 2 && hypot(mx - p0.x, my - p0.y) <= PEN_CLOSE_RADIUS;

            ctx.set_stroke_style_str("rgb(100,100,100)");
            ctx.set_line_width(1.0);
            ctx.set_line_dash(&js_sys::Array::of2(&4.0.into(), &4.0.into()).into()).ok();

            ctx.begin_path();
            ctx.move_to(last.x, last.y);
            if near_start {
                ctx.bezier_curve_to(
                    last.hx_out,
                    last.hy_out,
                    p0.hx_in,
                    p0.hy_in,
                    p0.x,
                    p0.y,
                );
            } else {
                ctx.bezier_curve_to(last.hx_out, last.hy_out, mx, my, mx, my);
            }
            ctx.stroke();

            // Reset dash
            ctx.set_line_dash(&js_sys::Array::new().into()).ok();
        }

        // Draw handle lines and anchor points
        let sel_color = "rgb(0,120,255)";
        for pt in &self.points {
            if pt.smooth {
                // Handle line
                ctx.set_stroke_style_str(sel_color);
                ctx.set_line_width(1.0);
                ctx.begin_path();
                ctx.move_to(pt.hx_in, pt.hy_in);
                ctx.line_to(pt.hx_out, pt.hy_out);
                ctx.stroke();

                // Handle circles
                ctx.set_fill_style_str("white");
                ctx.set_stroke_style_str(sel_color);
                let r = 3.0;
                ctx.begin_path();
                ctx.arc(pt.hx_in, pt.hy_in, r, 0.0, std::f64::consts::TAU).ok();
                ctx.fill();
                ctx.stroke();
                ctx.begin_path();
                ctx.arc(pt.hx_out, pt.hy_out, r, 0.0, std::f64::consts::TAU).ok();
                ctx.fill();
                ctx.stroke();
            }

            // Anchor point square
            let half = HANDLE_DRAW_SIZE / 2.0;
            ctx.set_fill_style_str(sel_color);
            ctx.set_stroke_style_str(sel_color);
            ctx.fill_rect(pt.x - half, pt.y - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE);
            ctx.stroke_rect(pt.x - half, pt.y - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE);
        }

        // Close indicator: highlight first point when mouse is near
        if self.points.len() >= 2 {
            let p0 = &self.points[0];
            if hypot(self.mouse_x - p0.x, self.mouse_y - p0.y) <= PEN_CLOSE_RADIUS {
                ctx.set_stroke_style_str("rgb(0,200,0)");
                ctx.set_line_width(2.0);
                let r = HANDLE_DRAW_SIZE / 2.0 + 2.0;
                ctx.begin_path();
                ctx.arc(p0.x, p0.y, r, 0.0, std::f64::consts::TAU).ok();
                ctx.stroke();
            }
        }
    }
}
