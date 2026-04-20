//! Selection tool — marquee select, drag-to-move, Alt+drag copies.

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::document::{ElementPath, ElementSelection};
use crate::document::model::Model;
use crate::geometry::element::control_points;

use super::tool::{CanvasTool, DRAG_THRESHOLD, HIT_RADIUS};

#[derive(Debug, Clone, Copy, PartialEq)]
enum State {
    Idle,
    PendingDrag { start_x: f64, start_y: f64 },
    Marquee { start_x: f64, start_y: f64, cur_x: f64, cur_y: f64 },
    Moving { last_x: f64, last_y: f64, copied: bool },
}

pub struct SelectionTool {
    state: State,
    shift_held: bool,
    alt_held: bool,
}

impl SelectionTool {
    pub fn new() -> Self {
        Self {
            state: State::Idle,
            shift_held: false,
            alt_held: false,
        }
    }

    fn hit_test_selection(model: &Model, x: f64, y: f64) -> Option<ElementPath> {
        let doc = model.document();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                let cps = control_points(elem);
                for (px, py) in cps.iter() {
                    let dx = x - px;
                    let dy = y - py;
                    if (dx * dx + dy * dy).sqrt() < HIT_RADIUS {
                        return Some(es.path.clone());
                    }
                }
                // Also check bounding box
                let (bx, by, bw, bh) = elem.bounds();
                if x >= bx && x <= bx + bw && y >= by && y <= by + bh {
                    return Some(es.path.clone());
                }
            }
        }
        None
    }

    fn hit_test_any(model: &Model, x: f64, y: f64) -> Option<ElementPath> {
        use crate::geometry::element::Visibility;
        let doc = model.document();
        for (li, layer) in doc.layers.iter().enumerate() {
            let layer_vis = layer.visibility();
            if layer_vis == Visibility::Invisible {
                continue;
            }
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate().rev() {
                    if child.locked() {
                        continue;
                    }
                    if std::cmp::min(layer_vis, child.visibility()) == Visibility::Invisible {
                        continue;
                    }
                    let (bx, by, bw, bh) = child.bounds();
                    if x >= bx && x <= bx + bw && y >= by && y <= by + bh {
                        return Some(vec![li, ci]);
                    }
                }
            }
        }
        None
    }
}

impl CanvasTool for SelectionTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, alt: bool) {
        self.shift_held = shift;
        self.alt_held = alt;

        // Check if clicking on already-selected element
        if Self::hit_test_selection(model, x, y).is_some() {
            self.state = State::PendingDrag {
                start_x: x,
                start_y: y,
            };
            return;
        }

        // Check if clicking on any element
        if let Some(path) = Self::hit_test_any(model, x, y) {
            model.snapshot();
            if shift {
                // Toggle in selection
                let doc = model.document();
                let Some(_elem) = doc.get_element(&path) else { return; };
                let mut sel = doc.selection.clone();
                if let Some(pos) = sel.iter().position(|es| es.path == path) {
                    sel.remove(pos);
                } else {
                    sel.push(ElementSelection::all(path.clone()));
                }
                Controller::set_selection(model, sel);
            } else {
                Controller::select_element(model, &path);
            }
            self.state = State::PendingDrag {
                start_x: x,
                start_y: y,
            };
            return;
        }

        // Start marquee
        self.state = State::Marquee {
            start_x: x,
            start_y: y,
            cur_x: x,
            cur_y: y,
        };
    }

    fn on_move(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, _alt: bool, _dragging: bool) {
        self.shift_held = shift;
        match self.state {
            State::PendingDrag { start_x, start_y } => {
                let dist = ((x - start_x).powi(2) + (y - start_y).powi(2)).sqrt();
                if dist > DRAG_THRESHOLD {
                    model.snapshot();
                    self.state = State::Moving {
                        last_x: start_x,
                        last_y: start_y,
                        copied: false,
                    };
                }
            }
            State::Moving {
                last_x,
                last_y,
                ref mut copied,
            } => {
                let dx = x - last_x;
                let dy = y - last_y;
                if self.alt_held && !*copied {
                    Controller::copy_selection(model, dx, dy);
                    *copied = true;
                } else {
                    Controller::move_selection(model, dx, dy);
                }
                self.state = State::Moving {
                    last_x: x,
                    last_y: y,
                    copied: *copied,
                };
            }
            State::Marquee {
                start_x, start_y, ..
            } => {
                self.state = State::Marquee {
                    start_x,
                    start_y,
                    cur_x: x,
                    cur_y: y,
                };
            }
            State::Idle => {}
        }
    }

    fn on_release(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, _alt: bool) {
        match self.state {
            State::Marquee {
                start_x, start_y, ..
            } => {
                let rx = start_x.min(x);
                let ry = start_y.min(y);
                let rw = (x - start_x).abs();
                let rh = (y - start_y).abs();
                if rw > 1.0 || rh > 1.0 {
                    model.snapshot();
                    Controller::select_rect(model, rx, ry, rw, rh, shift);
                } else if !shift {
                    // Click on empty space — clear selection
                    Controller::set_selection(model, Vec::new());
                }
            }
            State::PendingDrag { .. } => {
                // Was a click, not a drag — selection already happened in on_press
            }
            _ => {}
        }
        self.state = State::Idle;
    }

    fn draw_overlay(&self, _model: &Model, ctx: &CanvasRenderingContext2d) {
        if let State::Marquee {
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
            ctx.set_stroke_style_str("rgba(0, 120, 215, 0.8)");
            ctx.set_fill_style_str("rgba(0, 120, 215, 0.1)");
            ctx.set_line_width(1.0);
            ctx.fill_rect(rx, ry, rw, rh);
            ctx.stroke_rect(rx, ry, rw, rh);
        }
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
    fn marquee_select() {
        let mut tool = SelectionTool::new();
        let mut model = make_model_with_rect();
        // Marquee covering the rect
        tool.on_press(&mut model, 45.0, 45.0, false, false);
        tool.on_release(&mut model, 75.0, 75.0, false, false);
        assert!(!model.document().selection.is_empty());
    }

    #[test]
    fn marquee_miss() {
        let mut tool = SelectionTool::new();
        let mut model = make_model_with_rect();
        // Marquee away from rect
        tool.on_press(&mut model, 0.0, 0.0, false, false);
        tool.on_release(&mut model, 10.0, 10.0, false, false);
        assert!(model.document().selection.is_empty());
    }

    #[test]
    fn click_selects_element() {
        let mut tool = SelectionTool::new();
        let mut model = make_model_with_rect();
        // Click inside the rect's bounds
        tool.on_press(&mut model, 55.0, 55.0, false, false);
        tool.on_release(&mut model, 55.0, 55.0, false, false);
        assert!(!model.document().selection.is_empty());
    }

    #[test]
    fn click_on_empty_canvas_clears_selection() {
        let mut tool = SelectionTool::new();
        let mut model = make_model_with_rect();
        // Pre-select the rect.
        Controller::select_element(&mut model, &vec![0, 0]);
        assert!(!model.document().selection.is_empty());
        // Click (press+release at same point) on empty canvas, no shift.
        tool.on_press(&mut model, 5.0, 5.0, false, false);
        tool.on_release(&mut model, 5.0, 5.0, false, false);
        assert!(
            model.document().selection.is_empty(),
            "selection should be cleared after click on empty canvas"
        );
    }

    #[test]
    fn shift_click_on_empty_canvas_keeps_selection() {
        let mut tool = SelectionTool::new();
        let mut model = make_model_with_rect();
        Controller::select_element(&mut model, &vec![0, 0]);
        assert!(!model.document().selection.is_empty());
        // Shift+click on empty canvas — selection is preserved.
        tool.on_press(&mut model, 5.0, 5.0, true, false);
        tool.on_release(&mut model, 5.0, 5.0, true, false);
        assert!(
            !model.document().selection.is_empty(),
            "shift-click on empty canvas should not clear the selection"
        );
    }

    #[test]
    fn move_selection() {
        let mut tool = SelectionTool::new();
        let mut model = make_model_with_rect();
        // First select the element
        Controller::select_element(&mut model, &vec![0, 0]);
        assert!(!model.document().selection.is_empty());
        // Press on it, first move triggers drag threshold, second move applies delta
        tool.on_press(&mut model, 60.0, 60.0, false, false);
        tool.on_move(&mut model, 65.0, 65.0, false, false, true); // exceeds threshold, transitions to Moving
        tool.on_move(&mut model, 70.0, 70.0, false, false, true); // applies dx=5, dy=5
        tool.on_release(&mut model, 70.0, 70.0, false, false);
        let elem = &model.document().layers[0].children().unwrap()[0];
        if let Element::Rect(r) = &**elem {
            assert_eq!(r.x, 60.0);
            assert_eq!(r.y, 60.0);
        } else {
            panic!("expected Rect element");
        }
    }
}
