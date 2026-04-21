//! Lasso tool — freehand polygon selection.

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::model::Model;

use super::tool::CanvasTool;

/// Minimum distance between consecutive lasso points (pixels).
const MIN_POINT_DIST: f64 = 2.0;

#[derive(Debug, Clone, PartialEq)]
enum State {
    Idle,
    Drawing {
        points: Vec<(f64, f64)>,
        shift: bool,
    },
}

pub struct LassoTool {
    state: State,
}

impl LassoTool {
    pub fn new() -> Self {
        Self { state: State::Idle }
    }
}

impl CanvasTool for LassoTool {
    fn on_press(&mut self, _model: &mut Model, x: f64, y: f64, shift: bool, _alt: bool) {
        self.state = State::Drawing {
            points: vec![(x, y)],
            shift,
        };
    }

    fn on_move(&mut self, _model: &mut Model, x: f64, y: f64, shift: bool, _alt: bool, _dragging: bool) {
        if let State::Drawing { ref mut points, shift: ref mut s } = self.state {
            *s = shift;
            if let Some(&(lx, ly)) = points.last() {
                let dist = ((x - lx).powi(2) + (y - ly).powi(2)).sqrt();
                if dist >= MIN_POINT_DIST {
                    points.push((x, y));
                }
            }
        }
    }

    fn on_release(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, _alt: bool) {
        if let State::Drawing { ref points, shift: s } = self.state {
            let extend = s || shift;
            if points.len() >= 3 {
                model.snapshot();
                Controller::select_polygon(model, points, extend);
            } else if !extend {
                // Fewer than 3 points: treat as click — clear selection.
                Controller::set_selection(model, Vec::new());
            }
            let _ = (x, y); // suppress unused warnings
        }
        self.state = State::Idle;
    }

    fn draw_overlay(&self, _model: &Model, ctx: &CanvasRenderingContext2d) {
        if let State::Drawing { ref points, .. } = self.state {
            if points.len() < 2 {
                return;
            }
            ctx.set_stroke_style_str("rgba(0, 120, 215, 0.8)");
            ctx.set_fill_style_str("rgba(0, 120, 215, 0.1)");
            ctx.set_line_width(1.0);
            ctx.begin_path();
            ctx.move_to(points[0].0, points[0].1);
            for &(px, py) in &points[1..] {
                ctx.line_to(px, py);
            }
            ctx.close_path();
            ctx.fill();
            ctx.stroke();
        }
    }

    fn activate(&mut self, _model: &mut Model) {
        self.state = State::Idle;
    }

    fn deactivate(&mut self, _model: &mut Model) {
        self.state = State::Idle;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::controller::Controller;
    use crate::document::document::Document;
    use crate::document::model::Model;
    use crate::geometry::element::{Color, CommonProps, Element, Fill, LayerElem, RectElem};

    fn make_model_with_rect() -> Model {
        let rect = Element::Rect(RectElem {
            x: 50.0,
            y: 50.0,
            width: 20.0,
            height: 20.0,
            rx: 0.0,
            ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
        });
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(rect)],
            common: CommonProps::default(),
        });
        let doc = Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: Vec::new(),
         ..Document::default()};
        Model::new(doc, None)
    }

    #[test]
    fn lasso_select() {
        let mut tool = LassoTool::new();
        let mut model = make_model_with_rect();
        // Draw a polygon enclosing the rect at (50,50)-(70,70)
        tool.on_press(&mut model, 40.0, 40.0, false, false);
        tool.on_move(&mut model, 80.0, 40.0, false, false, true);
        tool.on_move(&mut model, 80.0, 80.0, false, false, true);
        tool.on_move(&mut model, 40.0, 80.0, false, false, true);
        tool.on_release(&mut model, 40.0, 80.0, false, false);
        assert!(!model.document().selection.is_empty());
    }

    #[test]
    fn lasso_miss() {
        let mut tool = LassoTool::new();
        let mut model = make_model_with_rect();
        // Draw a polygon away from the rect
        tool.on_press(&mut model, 0.0, 0.0, false, false);
        tool.on_move(&mut model, 10.0, 0.0, false, false, true);
        tool.on_move(&mut model, 10.0, 10.0, false, false, true);
        tool.on_move(&mut model, 0.0, 10.0, false, false, true);
        tool.on_release(&mut model, 0.0, 10.0, false, false);
        assert!(model.document().selection.is_empty());
    }

    #[test]
    fn lasso_shift_extend() {
        let mut tool = LassoTool::new();
        let mut model = make_model_with_rect();
        // First select via controller
        Controller::select_element(&mut model, &vec![0, 0]);
        assert!(!model.document().selection.is_empty());
        // Lasso with shift on empty area — selection preserved
        tool.on_press(&mut model, 0.0, 0.0, true, false);
        tool.on_move(&mut model, 10.0, 0.0, true, false, true);
        tool.on_move(&mut model, 10.0, 10.0, true, false, true);
        tool.on_move(&mut model, 0.0, 10.0, true, false, true);
        tool.on_release(&mut model, 0.0, 10.0, true, false);
        // Selection should still include the original element (toggle with empty = no change)
        assert!(!model.document().selection.is_empty());
    }

    #[test]
    fn click_without_drag_clears() {
        let mut tool = LassoTool::new();
        let mut model = make_model_with_rect();
        Controller::select_element(&mut model, &vec![0, 0]);
        assert!(!model.document().selection.is_empty());
        // Press and release at same point (no drag)
        tool.on_press(&mut model, 5.0, 5.0, false, false);
        tool.on_release(&mut model, 5.0, 5.0, false, false);
        assert!(model.document().selection.is_empty());
    }

    #[test]
    fn click_without_drag_shift_preserves() {
        let mut tool = LassoTool::new();
        let mut model = make_model_with_rect();
        Controller::select_element(&mut model, &vec![0, 0]);
        assert!(!model.document().selection.is_empty());
        // Press and release with shift — selection preserved
        tool.on_press(&mut model, 5.0, 5.0, true, false);
        tool.on_release(&mut model, 5.0, 5.0, true, false);
        assert!(!model.document().selection.is_empty());
    }

    #[test]
    fn state_transitions() {
        let mut tool = LassoTool::new();
        let mut model = make_model_with_rect();
        assert_eq!(tool.state, State::Idle);
        tool.on_press(&mut model, 10.0, 10.0, false, false);
        assert!(matches!(tool.state, State::Drawing { .. }));
        tool.on_release(&mut model, 10.0, 10.0, false, false);
        assert_eq!(tool.state, State::Idle);
    }
}
