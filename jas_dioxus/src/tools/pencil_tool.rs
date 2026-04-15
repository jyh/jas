//! Pencil tool for freehand drawing with automatic Bezier curve fitting.

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::model::Model;
use crate::geometry::element::{Color, CommonProps, Element, PathCommand, PathElem, Stroke};
use crate::algorithms::fit_curve::fit_curve;

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
            fill: model.default_fill,
            stroke: model.default_stroke,
            width_points: vec![],
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

    fn on_move(&mut self, _model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool, _dragging: bool) {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::{Element, PathCommand};

    #[test]
    fn freehand_draw_creates_path() {
        let mut tool = PencilTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 0.0, 0.0, false, false);
        for i in 1..=20 {
            let x = i as f64 * 5.0;
            let y = (i as f64 * 0.1).sin() * 20.0;
            tool.on_move(&mut model, x, y, false, false, true);
        }
        tool.on_release(&mut model, 100.0, 0.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        match &*children[0] {
            Element::Path(pe) => {
                assert!(pe.d.len() >= 2, "path should have MoveTo + at least one CurveTo");
                assert!(matches!(pe.d[0], PathCommand::MoveTo { .. }));
                for cmd in &pe.d[1..] {
                    assert!(matches!(cmd, PathCommand::CurveTo { .. }));
                }
            }
            _ => panic!("expected Path element"),
        }
    }

    #[test]
    fn click_without_drag_creates_degenerate_path() {
        // Press+release at same point still produces a path (2 identical points → fit_curve runs)
        let mut tool = PencilTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_release(&mut model, 10.0, 20.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
    }

    #[test]
    fn path_has_stroke() {
        let mut tool = PencilTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 0.0, 0.0, false, false);
        tool.on_move(&mut model, 50.0, 50.0, false, false, true);
        tool.on_release(&mut model, 100.0, 0.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Path(pe) = &*children[0] {
            assert!(pe.stroke.is_some(), "pencil path should have a stroke");
            assert!(pe.fill.is_none(), "pencil path should have no fill");
        } else {
            panic!("expected Path element");
        }
    }

    #[test]
    fn move_without_press_is_noop() {
        let mut tool = PencilTool::new();
        let mut model = Model::default();
        tool.on_move(&mut model, 50.0, 60.0, false, false, true);
        assert!(!tool.drawing);
        assert!(tool.points.is_empty());
    }

    #[test]
    fn release_without_press_is_noop() {
        let mut tool = PencilTool::new();
        let mut model = Model::default();
        tool.on_release(&mut model, 50.0, 60.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 0);
    }

    #[test]
    fn drawing_state_transitions() {
        let mut tool = PencilTool::new();
        let mut model = Model::default();
        assert!(!tool.drawing);
        tool.on_press(&mut model, 0.0, 0.0, false, false);
        assert!(tool.drawing);
        tool.on_move(&mut model, 50.0, 50.0, false, false, true);
        assert!(tool.drawing);
        tool.on_release(&mut model, 100.0, 0.0, false, false);
        assert!(!tool.drawing);
    }

    #[test]
    fn points_accumulate_during_draw() {
        let mut tool = PencilTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 0.0, 0.0, false, false);
        assert_eq!(tool.points.len(), 1);
        tool.on_move(&mut model, 10.0, 10.0, false, false, true);
        assert_eq!(tool.points.len(), 2);
        tool.on_move(&mut model, 20.0, 20.0, false, false, true);
        assert_eq!(tool.points.len(), 3);
        tool.on_release(&mut model, 30.0, 30.0, false, false);
        // Points cleared after finish
        assert!(tool.points.is_empty());
    }

    #[test]
    fn path_starts_at_press_point() {
        let mut tool = PencilTool::new();
        let mut model = Model::default();
        tool.on_press(&mut model, 15.0, 25.0, false, false);
        tool.on_move(&mut model, 50.0, 50.0, false, false, true);
        tool.on_release(&mut model, 100.0, 0.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        if let Element::Path(pe) = &*children[0] {
            if let PathCommand::MoveTo { x, y } = pe.d[0] {
                assert_eq!(x, 15.0);
                assert_eq!(y, 25.0);
            } else {
                panic!("first command should be MoveTo");
            }
        }
    }
}
