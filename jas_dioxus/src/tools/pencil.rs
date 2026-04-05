//! Pencil tool for freehand drawing with automatic Bezier curve fitting.

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::model::Model;
use crate::geometry::element::{Color, CommonProps, Element, PathCommand, PathElem, Stroke};
use crate::geometry::fit_curve::fit_curve;

use super::tool::CanvasTool;

const FIT_ERROR: f64 = 4.0;

pub struct PencilTool {
    points: Vec<(f64, f64)>,
    drawing: bool,
}

impl PencilTool {
    pub fn new() -> Self {
        Self {
            points: Vec::new(),
            drawing: false,
        }
    }

    fn finish(&mut self, model: &mut Model) {
        if self.points.len() < 2 {
            self.points.clear();
            return;
        }
        let segments = fit_curve(&self.points, FIT_ERROR);
        if segments.is_empty() {
            self.points.clear();
            return;
        }

        let mut cmds: Vec<PathCommand> = Vec::new();
        let seg0 = &segments[0];
        cmds.push(PathCommand::MoveTo {
            x: seg0.0,
            y: seg0.1,
        });
        for seg in &segments {
            cmds.push(PathCommand::CurveTo {
                x1: seg.2,
                y1: seg.3,
                x2: seg.4,
                y2: seg.5,
                x: seg.6,
                y: seg.7,
            });
        }

        let elem = Element::Path(PathElem {
            d: cmds,
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            common: CommonProps::default(),
        });
        Controller::add_element(model, elem);
        self.points.clear();
    }
}

impl CanvasTool for PencilTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        model.snapshot();
        self.drawing = true;
        self.points = vec![(x, y)];
    }

    fn on_move(&mut self, _model: &mut Model, x: f64, y: f64, _shift: bool, _dragging: bool) {
        if self.drawing {
            self.points.push((x, y));
        }
    }

    fn on_release(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        if !self.drawing {
            return;
        }
        self.drawing = false;
        self.points.push((x, y));
        self.finish(model);
    }

    fn draw_overlay(&self, _model: &Model, ctx: &CanvasRenderingContext2d) {
        if !self.drawing || self.points.len() < 2 {
            return;
        }
        ctx.set_stroke_style_str("black");
        ctx.set_line_width(1.0);
        ctx.begin_path();
        ctx.move_to(self.points[0].0, self.points[0].1);
        for &(x, y) in &self.points[1..] {
            ctx.line_to(x, y);
        }
        ctx.stroke();
    }
}
