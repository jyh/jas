//! Selection tool — marquee select, drag-to-move, Alt+drag copies.

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::document::{ElementPath, ElementSelection};
use crate::document::model::Model;
use crate::geometry::element::{control_point_count, control_points};

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
                for (_, (px, py)) in cps.iter().enumerate() {
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
        let doc = model.document();
        for (li, layer) in doc.layers.iter().enumerate() {
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate().rev() {
                    if child.locked() {
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
                let elem = doc.get_element(&path).unwrap();
                let mut sel = doc.selection.clone();
                if let Some(pos) = sel.iter().position(|es| es.path == path) {
                    sel.remove(pos);
                } else {
                    let n = control_point_count(elem);
                    sel.push(ElementSelection {
                        path: path.clone(),
                        control_points: (0..n).collect(),
                    });
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

    fn on_move(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, dragging: bool) {
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
