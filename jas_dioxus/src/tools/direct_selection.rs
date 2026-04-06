//! Direct Selection tool — select individual control points and drag Bezier handles.
//!
//! State machine:
//!   IDLE     — waiting for input
//!   MARQUEE  — rubber-band selection rectangle
//!   MOVING   — dragging selected control points
//!   HANDLE   — dragging a Bezier handle

use std::collections::HashSet;

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::document::{ElementPath, ElementSelection};
use crate::document::model::Model;
use crate::geometry::element::{
    control_points, move_control_points, move_path_handle, path_handle_positions, Element,
    PathElem,
};

use super::tool::{CanvasTool, DRAG_THRESHOLD, HANDLE_DRAW_SIZE, HIT_RADIUS};

#[derive(Debug, Clone, PartialEq)]
enum State {
    Idle,
    Marquee {
        start_x: f64,
        start_y: f64,
        cur_x: f64,
        cur_y: f64,
    },
    Moving {
        start_x: f64,
        start_y: f64,
        cur_x: f64,
        cur_y: f64,
    },
    Handle {
        start_x: f64,
        start_y: f64,
        cur_x: f64,
        cur_y: f64,
        path: ElementPath,
        anchor_idx: usize,
        handle_type: String, // "in" or "out"
    },
}

pub struct DirectSelectionTool {
    state: State,
}

impl DirectSelectionTool {
    pub fn new() -> Self {
        Self { state: State::Idle }
    }

    /// Hit-test Bezier handles on selected path elements.
    /// Returns (path, anchor_idx, "in"/"out") if a handle is hit.
    fn hit_test_handle(
        model: &Model,
        x: f64,
        y: f64,
    ) -> Option<(ElementPath, usize, String)> {
        let doc = model.document();
        for es in &doc.selection {
            if let Some(Element::Path(pe)) = doc.get_element(&es.path) {
                let anchors = control_points(&Element::Path(pe.clone()));
                for (ai, _) in anchors.iter().enumerate() {
                    let (h_in, h_out) = path_handle_positions(&pe.d, ai);
                    if let Some((hx, hy)) = h_in {
                        if ((x - hx).powi(2) + (y - hy).powi(2)).sqrt() < HIT_RADIUS {
                            return Some((es.path.clone(), ai, "in".to_string()));
                        }
                    }
                    if let Some((hx, hy)) = h_out {
                        if ((x - hx).powi(2) + (y - hy).powi(2)).sqrt() < HIT_RADIUS {
                            return Some((es.path.clone(), ai, "out".to_string()));
                        }
                    }
                }
            }
        }
        None
    }

    /// Hit-test individual control points on all elements.
    /// Returns (path, cp_index) if hit.
    fn hit_test_control_point(model: &Model, x: f64, y: f64) -> Option<(ElementPath, usize)> {
        let doc = model.document();
        for (li, layer) in doc.layers.iter().enumerate() {
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate().rev() {
                    if child.locked() {
                        continue;
                    }
                    let path = vec![li, ci];
                    // Check inside groups too
                    if let Some(result) = hit_test_cp_recursive(child, &path, x, y) {
                        return Some(result);
                    }
                }
            }
        }
        None
    }

    /// Check if (x,y) is within the bounding box of any selected element.
    fn hit_test_selected_bounds(model: &Model, x: f64, y: f64) -> bool {
        let doc = model.document();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                let cps = control_points(elem);
                for &(px, py) in &cps {
                    if ((x - px).powi(2) + (y - py).powi(2)).sqrt() < HIT_RADIUS {
                        return true;
                    }
                }
                let (bx, by, bw, bh) = elem.bounds();
                if x >= bx && x <= bx + bw && y >= by && y <= by + bh {
                    return true;
                }
            }
        }
        false
    }
}

fn hit_test_cp_recursive(
    elem: &Element,
    path: &ElementPath,
    x: f64,
    y: f64,
) -> Option<(ElementPath, usize)> {
    if elem.is_group_or_layer() {
        if let Some(children) = elem.children() {
            for (i, child) in children.iter().enumerate().rev() {
                if child.locked() {
                    continue;
                }
                let mut child_path = path.clone();
                child_path.push(i);
                if let Some(result) = hit_test_cp_recursive(child, &child_path, x, y) {
                    return Some(result);
                }
            }
        }
        return None;
    }
    let cps = control_points(elem);
    for (i, &(px, py)) in cps.iter().enumerate() {
        if ((x - px).powi(2) + (y - py).powi(2)).sqrt() < HIT_RADIUS {
            return Some((path.clone(), i));
        }
    }
    None
}

impl CanvasTool for DirectSelectionTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, _alt: bool) {
        // 1. Check handle hit first
        if let Some((path, anchor_idx, handle_type)) = Self::hit_test_handle(model, x, y) {
            self.state = State::Handle {
                start_x: x,
                start_y: y,
                cur_x: x,
                cur_y: y,
                path,
                anchor_idx,
                handle_type,
            };
            return;
        }

        // 2. Check if clicking on a selected element's control point or bounds
        if Self::hit_test_selected_bounds(model, x, y) {
            self.state = State::Moving {
                start_x: x,
                start_y: y,
                cur_x: x,
                cur_y: y,
            };
            return;
        }

        // 3. Check if clicking on any element's control point
        if let Some((path, cp_idx)) = Self::hit_test_control_point(model, x, y) {
            model.snapshot();
            if shift {
                // Toggle this CP in selection
                let doc = model.document();
                let mut sel = doc.selection.clone();
                if let Some(pos) = sel.iter().position(|es| es.path == path) {
                    let es = &sel[pos];
                    let mut cps = es.control_points.clone();
                    if cps.contains(&cp_idx) {
                        cps.remove(&cp_idx);
                    } else {
                        cps.insert(cp_idx);
                    }
                    if cps.is_empty() {
                        sel.remove(pos);
                    } else {
                        sel[pos] = ElementSelection {
                            path: path.clone(),
                            control_points: cps,
                        };
                    }
                } else {
                    sel.push(ElementSelection {
                        path: path.clone(),
                        control_points: [cp_idx].into_iter().collect(),
                    });
                }
                Controller::set_selection(model, sel);
            } else {
                Controller::select_control_point(model, &path, cp_idx);
            }
            self.state = State::Moving {
                start_x: x,
                start_y: y,
                cur_x: x,
                cur_y: y,
            };
            return;
        }

        // 4. Start marquee
        self.state = State::Marquee {
            start_x: x,
            start_y: y,
            cur_x: x,
            cur_y: y,
        };
    }

    fn on_move(&mut self, _model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool, _dragging: bool) {
        match &mut self.state {
            State::Marquee { cur_x, cur_y, .. } => {
                *cur_x = x;
                *cur_y = y;
            }
            State::Moving { cur_x, cur_y, .. } => {
                *cur_x = x;
                *cur_y = y;
            }
            State::Handle { cur_x, cur_y, .. } => {
                *cur_x = x;
                *cur_y = y;
            }
            State::Idle => {}
        }
    }

    fn on_release(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, alt: bool) {
        let state = std::mem::replace(&mut self.state, State::Idle);
        match state {
            State::Marquee {
                start_x, start_y, ..
            } => {
                let rx = start_x.min(x);
                let ry = start_y.min(y);
                let rw = (x - start_x).abs();
                let rh = (y - start_y).abs();
                if rw > 1.0 || rh > 1.0 {
                    model.snapshot();
                    Controller::direct_select_rect(model, rx, ry, rw, rh, shift);
                } else if !shift {
                    Controller::set_selection(model, Vec::new());
                }
            }
            State::Moving {
                start_x, start_y, ..
            } => {
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
            State::Handle {
                start_x,
                start_y,
                path,
                anchor_idx,
                handle_type,
                ..
            } => {
                let dx = x - start_x;
                let dy = y - start_y;
                if dx.abs() > 0.5 || dy.abs() > 0.5 {
                    model.snapshot();
                    Controller::move_path_handle(model, &path, anchor_idx, &handle_type, dx, dy);
                }
            }
            State::Idle => {}
        }
    }

    fn draw_overlay(&self, model: &Model, ctx: &CanvasRenderingContext2d) {
        let doc = model.document();

        // Draw Bezier handles for selected path elements
        let sel_color = "rgb(0,120,255)";
        for es in &doc.selection {
            if let Some(Element::Path(pe)) = doc.get_element(&es.path) {
                let anchors = control_points(&Element::Path(pe.clone()));
                for (ai, &(ax, ay)) in anchors.iter().enumerate() {
                    let (h_in, h_out) = path_handle_positions(&pe.d, ai);
                    // Draw handle lines and circles
                    for h in [h_in, h_out].iter().flatten() {
                        ctx.set_stroke_style_str(sel_color);
                        ctx.set_line_width(1.0);
                        ctx.begin_path();
                        ctx.move_to(ax, ay);
                        ctx.line_to(h.0, h.1);
                        ctx.stroke();

                        ctx.set_fill_style_str("white");
                        ctx.set_stroke_style_str(sel_color);
                        ctx.begin_path();
                        ctx.arc(h.0, h.1, 3.0, 0.0, std::f64::consts::TAU).ok();
                        ctx.fill();
                        ctx.stroke();
                    }
                }
            }
        }

        // Draw state-specific overlays
        match &self.state {
            State::Marquee {
                start_x,
                start_y,
                cur_x,
                cur_y,
            } => {
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
            State::Moving {
                start_x,
                start_y,
                cur_x,
                cur_y,
            } => {
                let dx = cur_x - start_x;
                let dy = cur_y - start_y;
                if dx.abs() > 1.0 || dy.abs() > 1.0 {
                    // Draw ghost of moved elements
                    ctx.set_stroke_style_str("rgba(0, 120, 215, 0.5)");
                    ctx.set_line_width(1.0);
                    ctx.set_line_dash(&js_sys::Array::of2(&4.0.into(), &4.0.into()).into())
                        .ok();
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
            State::Handle {
                start_x,
                start_y,
                cur_x,
                cur_y,
                path,
                anchor_idx,
                handle_type,
            } => {
                let dx = cur_x - start_x;
                let dy = cur_y - start_y;
                if let Some(Element::Path(pe)) = doc.get_element(path) {
                    let moved_pe = move_path_handle(pe, *anchor_idx, handle_type, dx, dy);
                    // Draw the preview path
                    ctx.set_stroke_style_str("rgba(0, 120, 215, 0.5)");
                    ctx.set_line_width(1.0);
                    ctx.set_line_dash(&js_sys::Array::of2(&4.0.into(), &4.0.into()).into())
                        .ok();
                    ctx.begin_path();
                    for cmd in &moved_pe.d {
                        match cmd {
                            crate::geometry::element::PathCommand::MoveTo { x, y } => {
                                ctx.move_to(*x, *y)
                            }
                            crate::geometry::element::PathCommand::LineTo { x, y } => {
                                ctx.line_to(*x, *y)
                            }
                            crate::geometry::element::PathCommand::CurveTo {
                                x1, y1, x2, y2, x, y,
                            } => ctx.bezier_curve_to(*x1, *y1, *x2, *y2, *x, *y),
                            crate::geometry::element::PathCommand::ClosePath => ctx.close_path(),
                            _ => {}
                        }
                    }
                    ctx.stroke();
                    ctx.set_line_dash(&js_sys::Array::new().into()).ok();

                    // Draw moved handle positions
                    let anchors = control_points(&Element::Path(moved_pe.clone()));
                    if let Some(&(ax, ay)) = anchors.get(*anchor_idx) {
                        let (h_in, h_out) = path_handle_positions(&moved_pe.d, *anchor_idx);
                        for h in [h_in, h_out].iter().flatten() {
                            ctx.set_stroke_style_str("rgba(0,120,255,0.8)");
                            ctx.set_line_width(1.0);
                            ctx.begin_path();
                            ctx.move_to(ax, ay);
                            ctx.line_to(h.0, h.1);
                            ctx.stroke();

                            ctx.set_fill_style_str("white");
                            ctx.begin_path();
                            ctx.arc(h.0, h.1, 3.0, 0.0, std::f64::consts::TAU).ok();
                            ctx.fill();
                            ctx.stroke();
                        }
                    }
                }
            }
            State::Idle => {}
        }
    }
}
