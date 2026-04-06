//! Group Selection tool — selects individual elements inside groups.
//!
//! Like the Selection tool but traverses into groups, so elements
//! inside groups can be individually selected and moved.

use std::collections::HashSet;

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::document::{ElementPath, ElementSelection};
use crate::document::model::Model;
use crate::geometry::element::{control_point_count, control_points, move_control_points, Element};

use super::tool::{CanvasTool, DRAG_THRESHOLD, HIT_RADIUS};

#[derive(Debug, Clone, PartialEq)]
enum State {
    Idle,
    PendingDrag { start_x: f64, start_y: f64 },
    Marquee { start_x: f64, start_y: f64, cur_x: f64, cur_y: f64 },
    Moving { start_x: f64, start_y: f64, cur_x: f64, cur_y: f64, copied: bool },
}

pub struct GroupSelectionTool {
    state: State,
}

impl GroupSelectionTool {
    pub fn new() -> Self {
        Self { state: State::Idle }
    }

    /// Hit-test any element, traversing into groups.
    fn hit_test_any(model: &Model, x: f64, y: f64) -> Option<ElementPath> {
        let doc = model.document();
        for (li, layer) in doc.layers.iter().enumerate() {
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate().rev() {
                    if child.locked() {
                        continue;
                    }
                    if let Some(path) = hit_recursive(child, &vec![li, ci], x, y) {
                        return Some(path);
                    }
                }
            }
        }
        None
    }

    /// Check if click is on an already-selected element.
    fn hit_test_selection(model: &Model, x: f64, y: f64) -> bool {
        let doc = model.document();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                let (bx, by, bw, bh) = elem.bounds();
                if x >= bx && x <= bx + bw && y >= by && y <= by + bh {
                    return true;
                }
            }
        }
        false
    }
}

/// Recursively hit-test into groups, returning the deepest leaf element path.
fn hit_recursive(elem: &Element, path: &ElementPath, x: f64, y: f64) -> Option<ElementPath> {
    if elem.is_group_or_layer() {
        if let Some(children) = elem.children() {
            for (i, child) in children.iter().enumerate().rev() {
                if child.locked() {
                    continue;
                }
                let mut child_path = path.clone();
                child_path.push(i);
                if let Some(result) = hit_recursive(child, &child_path, x, y) {
                    return Some(result);
                }
            }
        }
        return None;
    }
    let (bx, by, bw, bh) = elem.bounds();
    if x >= bx && x <= bx + bw && y >= by && y <= by + bh {
        Some(path.clone())
    } else {
        None
    }
}

impl CanvasTool for GroupSelectionTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, alt: bool) {
        // Clicking on selected element -> prepare to drag
        if Self::hit_test_selection(model, x, y) {
            self.state = State::PendingDrag { start_x: x, start_y: y };
            return;
        }

        // Click on any element (traversing into groups)
        if let Some(path) = Self::hit_test_any(model, x, y) {
            model.snapshot();
            if shift {
                let doc = model.document();
                let mut sel = doc.selection.clone();
                if let Some(pos) = sel.iter().position(|es| es.path == path) {
                    sel.remove(pos);
                } else if let Some(elem) = doc.get_element(&path) {
                    let n = control_point_count(elem);
                    sel.push(ElementSelection {
                        path: path.clone(),
                        control_points: (0..n).collect(),
                    });
                }
                Controller::set_selection(model, sel);
            } else if let Some(elem) = model.document().get_element(&path) {
                let n = control_point_count(elem);
                Controller::set_selection(model, vec![ElementSelection {
                    path: path.clone(),
                    control_points: (0..n).collect(),
                }]);
            }
            self.state = State::PendingDrag { start_x: x, start_y: y };
            return;
        }

        // Empty space -> start marquee
        self.state = State::Marquee { start_x: x, start_y: y, cur_x: x, cur_y: y };
    }

    fn on_move(&mut self, _model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool, _dragging: bool) {
        match &mut self.state {
            State::PendingDrag { start_x, start_y } => {
                let dist = ((x - *start_x).powi(2) + (y - *start_y).powi(2)).sqrt();
                if dist > DRAG_THRESHOLD {
                    self.state = State::Moving {
                        start_x: *start_x,
                        start_y: *start_y,
                        cur_x: x,
                        cur_y: y,
                        copied: false,
                    };
                }
            }
            State::Moving { cur_x, cur_y, .. } => {
                *cur_x = x;
                *cur_y = y;
            }
            State::Marquee { cur_x, cur_y, .. } => {
                *cur_x = x;
                *cur_y = y;
            }
            State::Idle => {}
        }
    }

    fn on_release(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, alt: bool) {
        let state = std::mem::replace(&mut self.state, State::Idle);
        match state {
            State::Moving { start_x, start_y, copied, .. } => {
                let dx = x - start_x;
                let dy = y - start_y;
                if dx.abs() > 1.0 || dy.abs() > 1.0 {
                    model.snapshot();
                    if alt {
                        Controller::copy_selection(model, dx, dy);
                    } else {
                        Controller::move_selection(model, dx, dy);
                    }
                }
            }
            State::Marquee { start_x, start_y, .. } => {
                let rx = start_x.min(x);
                let ry = start_y.min(y);
                let rw = (x - start_x).abs();
                let rh = (y - start_y).abs();
                if rw > 1.0 || rh > 1.0 {
                    model.snapshot();
                    // Use group_select_rect which traverses into groups
                    // For now reuse direct_select_rect with all CPs
                    Controller::direct_select_rect(model, rx, ry, rw, rh, shift);
                } else if !shift {
                    Controller::set_selection(model, Vec::new());
                }
            }
            State::PendingDrag { .. } => {
                // Click without drag — selection already happened in on_press
            }
            State::Idle => {}
        }
    }

    fn draw_overlay(&self, model: &Model, ctx: &CanvasRenderingContext2d) {
        match &self.state {
            State::Marquee { start_x, start_y, cur_x, cur_y } => {
                let rx = start_x.min(*cur_x);
                let ry = start_y.min(*cur_y);
                let rw = (cur_x - start_x).abs();
                let rh = (cur_y - start_y).abs();
                ctx.set_stroke_style_str("rgba(0, 120, 215, 0.8)");
                ctx.set_fill_style_str("rgba(0, 120, 215, 0.1)");
                ctx.set_line_width(1.0);
                ctx.fill_rect(rx, ry, rw, rh);
                ctx.stroke_rect(rx, ry, rw, rh);
            }
            State::Moving { start_x, start_y, cur_x, cur_y, .. } => {
                let dx = cur_x - start_x;
                let dy = cur_y - start_y;
                if dx.abs() > 1.0 || dy.abs() > 1.0 {
                    let doc = model.document();
                    ctx.set_stroke_style_str("rgba(0, 120, 215, 0.5)");
                    ctx.set_line_width(1.0);
                    ctx.set_line_dash(&js_sys::Array::of2(&4.0.into(), &4.0.into()).into()).ok();
                    for es in &doc.selection {
                        if let Some(elem) = doc.get_element(&es.path) {
                            let moved = move_control_points(elem, &es.control_points, dx, dy);
                            let (bx, by, bw, bh) = moved.bounds();
                            ctx.stroke_rect(bx, by, bw, bh);
                        }
                    }
                    ctx.set_line_dash(&js_sys::Array::new().into()).ok();
                }
            }
            _ => {}
        }
    }
}
