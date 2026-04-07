//! Add Anchor Point tool.
//!
//! Clicking on a path inserts a new smooth anchor point at that location,
//! splitting the clicked bezier segment into two while preserving the
//! curve shape (de Casteljau subdivision).

use wasm_bindgen::prelude::*;
use web_sys::CanvasRenderingContext2d;

use std::collections::HashSet;

use crate::document::document::ElementSelection;
use crate::document::model::Model;
use crate::geometry::element::{Element, PathCommand, PathElem};
use crate::geometry::measure::path_distance_to_point;

use super::tool::{CanvasTool, HANDLE_DRAW_SIZE, HIT_RADIUS};

// JavaScript snippet that tracks spacebar state on the window object.
// We use a global flag because keyboard events may not reliably reach the
// Dioxus element during mouse drags.
fn is_space_held() -> bool {
    thread_local! {
        static INSTALLED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    }
    INSTALLED.with(|installed| {
        if !installed.get() {
            installed.set(true);
            install_space_tracker();
        }
    });
    get_space_flag()
}

fn install_space_tracker() {
    let window = match web_sys::window() {
        Some(w) => w,
        None => return,
    };
    let keydown = Closure::<dyn FnMut(web_sys::KeyboardEvent)>::new(move |e: web_sys::KeyboardEvent| {
        if e.code() == "Space" {
            js_sys::Reflect::set(
                &js_sys::global(),
                &JsValue::from_str("__jas_space_held"),
                &JsValue::TRUE,
            ).ok();
        }
    });
    let keyup = Closure::<dyn FnMut(web_sys::KeyboardEvent)>::new(move |e: web_sys::KeyboardEvent| {
        if e.code() == "Space" {
            js_sys::Reflect::set(
                &js_sys::global(),
                &JsValue::from_str("__jas_space_held"),
                &JsValue::FALSE,
            ).ok();
        }
    });
    window.add_event_listener_with_callback("keydown", keydown.as_ref().unchecked_ref()).ok();
    window.add_event_listener_with_callback("keyup", keyup.as_ref().unchecked_ref()).ok();
    keydown.forget();
    keyup.forget();
}

fn get_space_flag() -> bool {
    js_sys::Reflect::get(
        &js_sys::global(),
        &JsValue::from_str("__jas_space_held"),
    )
    .map(|v| v.as_bool().unwrap_or(false))
    .unwrap_or(false)
}

const ADD_POINT_THRESHOLD: f64 = HIT_RADIUS + 2.0;

/// State for an in-progress drag after inserting an anchor point.
struct DragState {
    /// Path to the element in the document tree.
    elem_path: Vec<usize>,
    /// Index of the first of the two new CurveTo commands (the new anchor
    /// point is at the endpoint of this command).
    first_cmd_idx: usize,
    /// The anchor point position (updated when repositioning with Space).
    anchor_x: f64,
    anchor_y: f64,
    /// Last mouse position, used for computing delta when repositioning.
    last_x: f64,
    last_y: f64,
}

pub struct AddAnchorPointTool {
    drag: Option<DragState>,
}

impl AddAnchorPointTool {
    pub fn new() -> Self {
        Self { drag: None }
    }

    /// Find the closest path element in the document to (x, y).
    /// Returns (element_path, path_elem) if within threshold.
    fn hit_test_path(model: &Model, x: f64, y: f64) -> Option<(Vec<usize>, PathElem)> {
        let doc = model.document();
        for (li, layer) in doc.layers.iter().enumerate() {
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate() {
                    match &**child {
                        Element::Path(pe) => {
                            let dist = path_distance_to_point(&pe.d, x, y);
                            if dist <= ADD_POINT_THRESHOLD {
                                return Some((vec![li, ci], pe.clone()));
                            }
                        }
                        Element::Group(g) if !child.common().locked => {
                            for (gi, gc) in g.children.iter().enumerate() {
                                if let Element::Path(pe) = &**gc {
                                    let dist = path_distance_to_point(&pe.d, x, y);
                                    if dist <= ADD_POINT_THRESHOLD {
                                        return Some((vec![li, ci, gi], pe.clone()));
                                    }
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
        None
    }
}

/// Split a cubic bezier at parameter t using de Casteljau's algorithm.
/// Returns two sets of control points: (first curve, second curve).
/// Input: P0=(x0,y0), P1=(x1,y1), P2=(x2,y2), P3=(x3,y3)
/// Output: ((cp1x, cp1y, cp2x, cp2y, mx, my), (cp3x, cp3y, cp4x, cp4y, x3, y3))
fn split_cubic(
    x0: f64, y0: f64,
    x1: f64, y1: f64,
    x2: f64, y2: f64,
    x3: f64, y3: f64,
    t: f64,
) -> ((f64, f64, f64, f64, f64, f64), (f64, f64, f64, f64, f64, f64)) {
    // Level 1
    let a1x = lerp(x0, x1, t);
    let a1y = lerp(y0, y1, t);
    let a2x = lerp(x1, x2, t);
    let a2y = lerp(y1, y2, t);
    let a3x = lerp(x2, x3, t);
    let a3y = lerp(y2, y3, t);
    // Level 2
    let b1x = lerp(a1x, a2x, t);
    let b1y = lerp(a1y, a2y, t);
    let b2x = lerp(a2x, a3x, t);
    let b2y = lerp(a2y, a3y, t);
    // Level 3 (the split point)
    let mx = lerp(b1x, b2x, t);
    let my = lerp(b1y, b2y, t);

    // First half: P0, a1, b1, m
    // Second half: m, b2, a3, P3
    (
        (a1x, a1y, b1x, b1y, mx, my),
        (b2x, b2y, a3x, a3y, x3, y3),
    )
}

fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + t * (b - a)
}

/// Find which segment of the path the point (px, py) is closest to,
/// and the parameter t on that segment. Returns (segment_index, t).
/// segment_index refers to the index in the path commands list (after MoveTo).
fn closest_segment_and_t(d: &[PathCommand], px: f64, py: f64) -> Option<(usize, f64)> {
    let mut best_dist = f64::INFINITY;
    let mut best_seg: usize = 0;
    let mut best_t: f64 = 0.0;
    let mut cx = 0.0_f64;
    let mut cy = 0.0_f64;

    for (cmd_idx, cmd) in d.iter().enumerate() {
        match cmd {
            PathCommand::MoveTo { x, y } => {
                cx = *x;
                cy = *y;
            }
            PathCommand::LineTo { x, y } => {
                let (dist, t) = closest_on_line(cx, cy, *x, *y, px, py);
                if dist < best_dist {
                    best_dist = dist;
                    best_seg = cmd_idx;
                    best_t = t;
                }
                cx = *x;
                cy = *y;
            }
            PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                let (dist, t) = closest_on_cubic(cx, cy, *x1, *y1, *x2, *y2, *x, *y, px, py);
                if dist < best_dist {
                    best_dist = dist;
                    best_seg = cmd_idx;
                    best_t = t;
                }
                cx = *x;
                cy = *y;
            }
            PathCommand::ClosePath => {}
            _ => {
                // For other commands, skip
            }
        }
    }

    if best_dist < f64::INFINITY {
        Some((best_seg, best_t))
    } else {
        None
    }
}

/// Find closest point on a line segment, return (distance, t).
fn closest_on_line(x0: f64, y0: f64, x1: f64, y1: f64, px: f64, py: f64) -> (f64, f64) {
    let dx = x1 - x0;
    let dy = y1 - y0;
    let len_sq = dx * dx + dy * dy;
    if len_sq == 0.0 {
        let d = ((px - x0).powi(2) + (py - y0).powi(2)).sqrt();
        return (d, 0.0);
    }
    let t = ((px - x0) * dx + (py - y0) * dy) / len_sq;
    let t = t.clamp(0.0, 1.0);
    let qx = x0 + t * dx;
    let qy = y0 + t * dy;
    let d = ((px - qx).powi(2) + (py - qy).powi(2)).sqrt();
    (d, t)
}

/// Find closest point on a cubic bezier by sampling, return (distance, t).
fn closest_on_cubic(
    x0: f64, y0: f64,
    x1: f64, y1: f64,
    x2: f64, y2: f64,
    x3: f64, y3: f64,
    px: f64, py: f64,
) -> (f64, f64) {
    // Coarse pass: sample at 50 points
    let steps = 50;
    let mut best_dist = f64::INFINITY;
    let mut best_t = 0.0;
    for i in 0..=steps {
        let t = i as f64 / steps as f64;
        let (bx, by) = eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, t);
        let d = ((px - bx).powi(2) + (py - by).powi(2)).sqrt();
        if d < best_dist {
            best_dist = d;
            best_t = t;
        }
    }
    // Refine: binary-search style narrowing
    let mut lo = (best_t - 1.0 / steps as f64).max(0.0);
    let mut hi = (best_t + 1.0 / steps as f64).min(1.0);
    for _ in 0..20 {
        let t1 = lo + (hi - lo) / 3.0;
        let t2 = hi - (hi - lo) / 3.0;
        let (bx1, by1) = eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, t1);
        let (bx2, by2) = eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, t2);
        let d1 = ((px - bx1).powi(2) + (py - by1).powi(2)).sqrt();
        let d2 = ((px - bx2).powi(2) + (py - by2).powi(2)).sqrt();
        if d1 < d2 {
            hi = t2;
        } else {
            lo = t1;
        }
    }
    best_t = (lo + hi) / 2.0;
    let (bx, by) = eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, best_t);
    best_dist = ((px - bx).powi(2) + (py - by).powi(2)).sqrt();
    (best_dist, best_t)
}

/// Evaluate a cubic bezier at parameter t.
fn eval_cubic(
    x0: f64, y0: f64,
    x1: f64, y1: f64,
    x2: f64, y2: f64,
    x3: f64, y3: f64,
    t: f64,
) -> (f64, f64) {
    let mt = 1.0 - t;
    let x = mt.powi(3) * x0
        + 3.0 * mt.powi(2) * t * x1
        + 3.0 * mt * t.powi(2) * x2
        + t.powi(3) * x3;
    let y = mt.powi(3) * y0
        + 3.0 * mt.powi(2) * t * y1
        + 3.0 * mt * t.powi(2) * y2
        + t.powi(3) * y3;
    (x, y)
}

/// Result of inserting a point: new commands, index of first new cmd, anchor pos.
struct InsertResult {
    commands: Vec<PathCommand>,
    /// Index in the new commands list of the first of the two split commands.
    first_new_idx: usize,
    /// The new anchor point position.
    anchor_x: f64,
    anchor_y: f64,
}

/// Insert a new anchor point into the path commands at the given segment
/// and parameter t. Returns the new command list, the index of the first
/// new command, and the anchor position.
fn insert_point_in_path(d: &[PathCommand], seg_idx: usize, t: f64) -> InsertResult {
    let mut result = Vec::new();
    let mut cx = 0.0_f64;
    let mut cy = 0.0_f64;
    let mut first_new_idx = 0;
    let mut anchor_x = 0.0;
    let mut anchor_y = 0.0;

    for (i, cmd) in d.iter().enumerate() {
        if i == seg_idx {
            match cmd {
                PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                    let ((a1x, a1y, b1x, b1y, mx, my), (b2x, b2y, a3x, a3y, ex, ey)) =
                        split_cubic(cx, cy, *x1, *y1, *x2, *y2, *x, *y, t);
                    first_new_idx = result.len();
                    anchor_x = mx;
                    anchor_y = my;
                    result.push(PathCommand::CurveTo {
                        x1: a1x, y1: a1y, x2: b1x, y2: b1y, x: mx, y: my,
                    });
                    result.push(PathCommand::CurveTo {
                        x1: b2x, y1: b2y, x2: a3x, y2: a3y, x: ex, y: ey,
                    });
                    cx = *x;
                    cy = *y;
                    continue;
                }
                PathCommand::LineTo { x, y } => {
                    let mx = lerp(cx, *x, t);
                    let my = lerp(cy, *y, t);
                    first_new_idx = result.len();
                    anchor_x = mx;
                    anchor_y = my;
                    result.push(PathCommand::LineTo { x: mx, y: my });
                    result.push(PathCommand::LineTo { x: *x, y: *y });
                    cx = *x;
                    cy = *y;
                    continue;
                }
                _ => {}
            }
        }

        match cmd {
            PathCommand::MoveTo { x, y } => {
                cx = *x;
                cy = *y;
            }
            PathCommand::LineTo { x, y } | PathCommand::CurveTo { x, y, .. } => {
                cx = *x;
                cy = *y;
            }
            _ => {}
        }
        result.push(*cmd);
    }
    InsertResult { commands: result, first_new_idx, anchor_x, anchor_y }
}

/// Update the handles of the newly inserted anchor point.
/// `first_cmd_idx` is the index of the first CurveTo of the split pair.
/// The anchor is at the endpoint of cmds[first_cmd_idx].
/// The incoming handle is x2,y2 of cmds[first_cmd_idx].
/// The outgoing handle is x1,y1 of cmds[first_cmd_idx + 1].
///
/// If `cusp` is false (smooth), outgoing = drag position and incoming = mirror.
/// If `cusp` is true, only the outgoing handle moves (independent handles).
fn update_handles(
    cmds: &mut [PathCommand],
    first_cmd_idx: usize,
    anchor_x: f64,
    anchor_y: f64,
    drag_x: f64,
    drag_y: f64,
    cusp: bool,
) {
    // Outgoing handle = drag position
    if let PathCommand::CurveTo { x1, y1, .. } = &mut cmds[first_cmd_idx + 1] {
        *x1 = drag_x;
        *y1 = drag_y;
    }
    // Incoming handle: mirror (smooth) or leave unchanged (cusp)
    if !cusp {
        if let PathCommand::CurveTo { x2, y2, .. } = &mut cmds[first_cmd_idx] {
            *x2 = 2.0 * anchor_x - drag_x;
            *y2 = 2.0 * anchor_y - drag_y;
        }
    }
}

/// Find an existing anchor point on any path near (px, py).
/// Returns (element_path, cmd_index_of_anchor) where cmd_index is the
/// command whose endpoint is the anchor. For MoveTo, it's the MoveTo itself.
/// For CurveTo/LineTo, it's the command whose (x, y) endpoint matches.
fn hit_test_anchor(
    model: &Model, px: f64, py: f64,
) -> Option<(Vec<usize>, PathElem, usize)> {
    let doc = model.document();
    let threshold = HIT_RADIUS;
    for (li, layer) in doc.layers.iter().enumerate() {
        if let Some(children) = layer.children() {
            for (ci, child) in children.iter().enumerate() {
                if let Element::Path(pe) = &**child {
                    if let Some(idx) = find_anchor_at(pe, px, py, threshold) {
                        return Some((vec![li, ci], pe.clone(), idx));
                    }
                }
                if let Element::Group(g) = &**child {
                    if child.common().locked { continue; }
                    for (gi, gc) in g.children.iter().enumerate() {
                        if let Element::Path(pe) = &**gc {
                            if let Some(idx) = find_anchor_at(pe, px, py, threshold) {
                                return Some((vec![li, ci, gi], pe.clone(), idx));
                            }
                        }
                    }
                }
            }
        }
    }
    None
}

/// Find the command index of an anchor point near (px, py) in a path.
fn find_anchor_at(pe: &PathElem, px: f64, py: f64, threshold: f64) -> Option<usize> {
    for (i, cmd) in pe.d.iter().enumerate() {
        let (ax, ay) = match cmd {
            PathCommand::MoveTo { x, y } => (*x, *y),
            PathCommand::LineTo { x, y } => (*x, *y),
            PathCommand::CurveTo { x, y, .. } => (*x, *y),
            _ => continue,
        };
        let dist = ((px - ax).powi(2) + (py - ay).powi(2)).sqrt();
        if dist <= threshold {
            return Some(i);
        }
    }
    None
}

/// Toggle a point between smooth and corner.
/// A corner point has handles collapsed to the anchor position.
/// A smooth point has handles extended (we restore them symmetrically).
fn toggle_smooth_corner(cmds: &mut Vec<PathCommand>, anchor_idx: usize) {
    let (ax, ay) = match cmds[anchor_idx] {
        PathCommand::MoveTo { x, y } => (x, y),
        PathCommand::LineTo { x, y } => (x, y),
        PathCommand::CurveTo { x, y, .. } => (x, y),
        _ => return,
    };

    // Check if it's currently a corner (handles at anchor position).
    // Incoming handle = x2,y2 of cmds[anchor_idx] (if CurveTo)
    // Outgoing handle = x1,y1 of cmds[anchor_idx + 1] (if CurveTo)
    let in_at_anchor = match cmds[anchor_idx] {
        PathCommand::CurveTo { x2, y2, .. } => {
            (x2 - ax).abs() < 0.5 && (y2 - ay).abs() < 0.5
        }
        _ => true, // MoveTo/LineTo have no incoming handle
    };
    let out_at_anchor = if anchor_idx + 1 < cmds.len() {
        match cmds[anchor_idx + 1] {
            PathCommand::CurveTo { x1, y1, .. } => {
                (x1 - ax).abs() < 0.5 && (y1 - ay).abs() < 0.5
            }
            _ => true,
        }
    } else {
        true
    };

    let is_corner = in_at_anchor && out_at_anchor;

    if is_corner {
        // Convert corner to smooth: extend handles along the direction
        // between the previous and next anchor points.
        let prev_anchor = find_prev_anchor(cmds, anchor_idx);
        let next_anchor = find_next_anchor(cmds, anchor_idx);
        if let (Some((px_, py_)), Some((nx, ny))) = (prev_anchor, next_anchor) {
            // Direction from prev to next
            let dx = nx - px_;
            let dy = ny - py_;
            let len = (dx * dx + dy * dy).sqrt();
            if len > 0.0 {
                // Handle length = 1/3 distance to neighbors
                let prev_dist = ((ax - px_).powi(2) + (ay - py_).powi(2)).sqrt();
                let next_dist = ((nx - ax).powi(2) + (ny - ay).powi(2)).sqrt();
                let ux = dx / len;
                let uy = dy / len;
                let in_len = prev_dist / 3.0;
                let out_len = next_dist / 3.0;
                // Set incoming handle
                if let PathCommand::CurveTo { x2, y2, .. } = &mut cmds[anchor_idx] {
                    *x2 = ax - ux * in_len;
                    *y2 = ay - uy * in_len;
                }
                // Set outgoing handle
                if anchor_idx + 1 < cmds.len() {
                    if let PathCommand::CurveTo { x1, y1, .. } = &mut cmds[anchor_idx + 1] {
                        *x1 = ax + ux * out_len;
                        *y1 = ay + uy * out_len;
                    }
                }
            }
        }
    } else {
        // Convert smooth to corner: collapse handles to anchor position
        if let PathCommand::CurveTo { x2, y2, .. } = &mut cmds[anchor_idx] {
            *x2 = ax;
            *y2 = ay;
        }
        if anchor_idx + 1 < cmds.len() {
            if let PathCommand::CurveTo { x1, y1, .. } = &mut cmds[anchor_idx + 1] {
                *x1 = ax;
                *y1 = ay;
            }
        }
    }
}

/// Find the anchor position before the given command index.
fn find_prev_anchor(cmds: &[PathCommand], idx: usize) -> Option<(f64, f64)> {
    for i in (0..idx).rev() {
        match cmds[i] {
            PathCommand::MoveTo { x, y }
            | PathCommand::LineTo { x, y }
            | PathCommand::CurveTo { x, y, .. } => return Some((x, y)),
            _ => {}
        }
    }
    None
}

/// Find the anchor position after the given command index.
fn find_next_anchor(cmds: &[PathCommand], idx: usize) -> Option<(f64, f64)> {
    for i in (idx + 1)..cmds.len() {
        match cmds[i] {
            PathCommand::MoveTo { x, y }
            | PathCommand::LineTo { x, y }
            | PathCommand::CurveTo { x, y, .. } => return Some((x, y)),
            _ => {}
        }
    }
    None
}

/// Reposition the anchor point at `first_cmd_idx` to (new_ax, new_ay),
/// moving both handles by the same delta (dx, dy) to preserve their
/// relative positions.
fn reposition_anchor(
    cmds: &mut [PathCommand],
    first_cmd_idx: usize,
    new_ax: f64,
    new_ay: f64,
    dx: f64,
    dy: f64,
) {
    // Move the anchor (endpoint of first_cmd_idx)
    if let PathCommand::CurveTo { x, y, x2, y2, .. } = &mut cmds[first_cmd_idx] {
        *x = new_ax;
        *y = new_ay;
        // Move incoming handle by same delta
        *x2 += dx;
        *y2 += dy;
    }
    // Move outgoing handle by same delta
    if first_cmd_idx + 1 < cmds.len() {
        if let PathCommand::CurveTo { x1, y1, .. } = &mut cmds[first_cmd_idx + 1] {
            *x1 += dx;
            *y1 += dy;
        }
    }
}

impl CanvasTool for AddAnchorPointTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, alt: bool) {
        self.drag = None;

        // Alt+click on existing anchor: toggle smooth/corner
        if alt {
            if let Some((path, pe, anchor_idx)) = hit_test_anchor(model, x, y) {
                model.snapshot();
                let mut new_cmds = pe.d.clone();
                toggle_smooth_corner(&mut new_cmds, anchor_idx);
                let new_elem = Element::Path(PathElem {
                    d: new_cmds,
                    fill: pe.fill.clone(),
                    stroke: pe.stroke.clone(),
                    common: pe.common.clone(),
                });
                let doc = model.document().replace_element(&path, new_elem);
                model.set_document(doc);
                return;
            }
        }

        if let Some((path, pe)) = Self::hit_test_path(model, x, y) {
            if let Some((seg_idx, t)) = closest_segment_and_t(&pe.d, x, y) {
                model.snapshot();
                let ins = insert_point_in_path(&pe.d, seg_idx, t);
                let new_elem = Element::Path(PathElem {
                    d: ins.commands.clone(),
                    fill: pe.fill.clone(),
                    stroke: pe.stroke.clone(),
                    common: pe.common.clone(),
                });
                let mut doc = model.document().replace_element(&path, new_elem);

                // Update selection: shift CP indices after the insertion
                // point and add the new anchor. If the previous selection
                // was `All`, the new anchor is automatically included.
                let new_anchor_idx = ins.first_new_idx;
                if let Some(old_sel) = model.document().get_element_selection(&path) {
                    let new_kind = match &old_sel.kind {
                        crate::document::document::SelectionKind::All =>
                            crate::document::document::SelectionKind::All,
                        crate::document::document::SelectionKind::Partial(s) => {
                            let shifted: Vec<usize> = s.iter()
                                .map(|cp| if cp >= new_anchor_idx { cp + 1 } else { cp })
                                .chain(std::iter::once(new_anchor_idx))
                                .collect();
                            crate::document::document::SelectionKind::Partial(
                                crate::document::document::SortedCps::from_iter(shifted))
                        }
                    };
                    let new_sel_entry = ElementSelection {
                        path: path.clone(),
                        kind: new_kind,
                    };
                    doc.selection.retain(|es| es.path != path);
                    doc.selection.push(new_sel_entry);
                }
                model.set_document(doc);

                // Only allow handle dragging if the split produced CurveTo pairs
                if ins.first_new_idx + 1 < ins.commands.len()
                    && matches!(ins.commands[ins.first_new_idx], PathCommand::CurveTo { .. })
                    && matches!(ins.commands[ins.first_new_idx + 1], PathCommand::CurveTo { .. })
                {
                    self.drag = Some(DragState {
                        elem_path: path,
                        first_cmd_idx: ins.first_new_idx,
                        anchor_x: ins.anchor_x,
                        anchor_y: ins.anchor_y,
                        last_x: x,
                        last_y: y,
                    });
                }
            }
        }
    }

    fn on_move(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, alt: bool, dragging: bool) {
        if !dragging {
            return;
        }
        let drag = match &mut self.drag {
            Some(d) => d,
            None => return,
        };

        if is_space_held() {
            // Space held: reposition the anchor point by the mouse delta.
            let dx = x - drag.last_x;
            let dy = y - drag.last_y;
            drag.last_x = x;
            drag.last_y = y;
            drag.anchor_x += dx;
            drag.anchor_y += dy;

            let elem_path = drag.elem_path.clone();
            let idx = drag.first_cmd_idx;
            let new_ax = drag.anchor_x;
            let new_ay = drag.anchor_y;

            let doc = model.document();
            if let Some(elem) = doc.get_element(&elem_path) {
                if let Element::Path(pe) = elem {
                    let mut new_cmds = pe.d.clone();
                    reposition_anchor(&mut new_cmds, idx, new_ax, new_ay, dx, dy);
                    let new_elem = Element::Path(PathElem {
                        d: new_cmds,
                        fill: pe.fill.clone(),
                        stroke: pe.stroke.clone(),
                        common: pe.common.clone(),
                    });
                    let new_doc = doc.replace_element(&elem_path, new_elem);
                    model.set_document(new_doc);
                }
            }
        } else {
            // Normal drag: update handles
            drag.last_x = x;
            drag.last_y = y;

            let elem_path = drag.elem_path.clone();
            let idx = drag.first_cmd_idx;
            let ax = drag.anchor_x;
            let ay = drag.anchor_y;

            let doc = model.document();
            if let Some(elem) = doc.get_element(&elem_path) {
                if let Element::Path(pe) = elem {
                    let mut new_cmds = pe.d.clone();
                    update_handles(&mut new_cmds, idx, ax, ay, x, y, alt);
                    let new_elem = Element::Path(PathElem {
                        d: new_cmds,
                        fill: pe.fill.clone(),
                        stroke: pe.stroke.clone(),
                        common: pe.common.clone(),
                    });
                    let new_doc = doc.replace_element(&elem_path, new_elem);
                    model.set_document(new_doc);
                }
            }
        }
    }

    fn on_release(&mut self, _model: &mut Model, _x: f64, _y: f64, _shift: bool, _alt: bool) {
        self.drag = None;
    }


    fn draw_overlay(&self, model: &Model, ctx: &CanvasRenderingContext2d) {
        // While dragging, draw the handle lines and circles for the new point.
        let drag = match &self.drag {
            Some(d) => d,
            None => return,
        };
        let doc = model.document();
        let elem = match doc.get_element(&drag.elem_path) {
            Some(e) => e,
            None => return,
        };
        let pe = match elem {
            Element::Path(pe) => pe,
            _ => return,
        };
        let idx = drag.first_cmd_idx;
        if idx + 1 >= pe.d.len() {
            return;
        }

        // Extract handle positions
        let (in_x, in_y) = match pe.d[idx] {
            PathCommand::CurveTo { x2, y2, .. } => (x2, y2),
            _ => return,
        };
        let (out_x, out_y) = match pe.d[idx + 1] {
            PathCommand::CurveTo { x1, y1, .. } => (x1, y1),
            _ => return,
        };

        let ax = drag.anchor_x;
        let ay = drag.anchor_y;
        let sel_color = "rgb(0,120,255)";

        // Determine if this is a cusp point (handles not collinear through anchor).
        // For a smooth point, in–anchor–out are collinear so we draw one line.
        // For a cusp, we draw two separate lines from the anchor.
        let is_cusp = {
            let d_in_x = in_x - ax;
            let d_in_y = in_y - ay;
            let d_out_x = out_x - ax;
            let d_out_y = out_y - ay;
            let cross = d_in_x * d_out_y - d_in_y * d_out_x;
            let dot = d_in_x * d_out_x + d_in_y * d_out_y;
            // Cusp if handles aren't opposite (dot > 0 means same side)
            // or cross product is large relative to lengths
            let in_len = (d_in_x * d_in_x + d_in_y * d_in_y).sqrt();
            let out_len = (d_out_x * d_out_x + d_out_y * d_out_y).sqrt();
            let max_len = in_len.max(out_len);
            max_len > 0.5 && (cross.abs() > max_len * 0.01 || dot > 0.0)
        };

        ctx.set_stroke_style_str(sel_color);
        ctx.set_line_width(1.0);
        if is_cusp {
            // Draw two separate lines: anchor→in, anchor→out
            ctx.begin_path();
            ctx.move_to(ax, ay);
            ctx.line_to(in_x, in_y);
            ctx.stroke();
            ctx.begin_path();
            ctx.move_to(ax, ay);
            ctx.line_to(out_x, out_y);
            ctx.stroke();
        } else {
            // Smooth: draw one line through anchor
            ctx.begin_path();
            ctx.move_to(in_x, in_y);
            ctx.line_to(out_x, out_y);
            ctx.stroke();
        }

        // Handle circles
        ctx.set_fill_style_str("white");
        ctx.set_stroke_style_str(sel_color);
        let r = 3.0;
        for (hx, hy) in [(in_x, in_y), (out_x, out_y)] {
            ctx.begin_path();
            ctx.arc(hx, hy, r, 0.0, std::f64::consts::TAU).ok();
            ctx.fill();
            ctx.stroke();
        }

        // Anchor point square
        let half = HANDLE_DRAW_SIZE / 2.0;
        ctx.set_fill_style_str(sel_color);
        ctx.fill_rect(ax - half, ay - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_cubic_at_midpoint() {
        // Straight line as cubic: (0,0) -> (100,0)
        let ((a1x, _a1y, b1x, _b1y, mx, my), (b2x, _b2y, a3x, _a3y, ex, _ey)) =
            split_cubic(0.0, 0.0, 33.33, 0.0, 66.67, 0.0, 100.0, 0.0, 0.5);
        assert!((mx - 50.0).abs() < 0.1);
        assert!(my.abs() < 0.01);
        assert!((ex - 100.0).abs() < 0.01);
        assert!(a1x < b1x);
        assert!(b2x < a3x);
    }

    #[test]
    fn split_cubic_at_zero() {
        let ((_, _, _, _, mx, my), _) =
            split_cubic(0.0, 0.0, 10.0, 20.0, 90.0, 80.0, 100.0, 100.0, 0.0);
        assert!(mx.abs() < 0.01);
        assert!(my.abs() < 0.01);
    }

    #[test]
    fn split_cubic_at_one() {
        let (_, (_, _, _, _, ex, ey)) =
            split_cubic(0.0, 0.0, 10.0, 20.0, 90.0, 80.0, 100.0, 100.0, 1.0);
        assert!((ex - 100.0).abs() < 0.01);
        assert!((ey - 100.0).abs() < 0.01);
    }

    #[test]
    fn insert_point_splits_curve() {
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::CurveTo {
                x1: 33.0, y1: 0.0, x2: 67.0, y2: 0.0, x: 100.0, y: 0.0,
            },
        ];
        let ins = insert_point_in_path(&cmds, 1, 0.5);
        let result = &ins.commands;
        assert_eq!(result.len(), 3); // MoveTo + 2 CurveTos
        assert!(matches!(result[0], PathCommand::MoveTo { .. }));
        assert!(matches!(result[1], PathCommand::CurveTo { .. }));
        assert!(matches!(result[2], PathCommand::CurveTo { .. }));

        // The midpoint of the first new curve should be at ~50
        if let PathCommand::CurveTo { x, .. } = result[1] {
            assert!((x - 50.0).abs() < 1.0);
        }
        // The endpoint of the second curve should be 100
        if let PathCommand::CurveTo { x, .. } = result[2] {
            assert!((x - 100.0).abs() < 0.01);
        }
        // Anchor position
        assert!((ins.anchor_x - 50.0).abs() < 1.0);
        assert_eq!(ins.first_new_idx, 1);
    }

    #[test]
    fn insert_point_splits_line() {
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 0.0 },
        ];
        let ins = insert_point_in_path(&cmds, 1, 0.5);
        let result = &ins.commands;
        assert_eq!(result.len(), 3); // MoveTo + 2 LineTos
        if let PathCommand::LineTo { x, .. } = result[1] {
            assert!((x - 50.0).abs() < 0.01);
        }
    }

    #[test]
    fn update_handles_smooth_mirrors() {
        let mut cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::CurveTo {
                x1: 10.0, y1: 0.0, x2: 40.0, y2: 0.0, x: 50.0, y: 0.0,
            },
            PathCommand::CurveTo {
                x1: 60.0, y1: 0.0, x2: 90.0, y2: 0.0, x: 100.0, y: 0.0,
            },
        ];
        // Smooth drag (cusp=false): outgoing to (70, 20), incoming mirrors
        update_handles(&mut cmds, 1, 50.0, 0.0, 70.0, 20.0, false);
        if let PathCommand::CurveTo { x1, y1, .. } = cmds[2] {
            assert!((x1 - 70.0).abs() < 0.01);
            assert!((y1 - 20.0).abs() < 0.01);
        }
        if let PathCommand::CurveTo { x2, y2, .. } = cmds[1] {
            assert!((x2 - 30.0).abs() < 0.01);
            assert!((y2 - (-20.0)).abs() < 0.01);
        }
    }

    #[test]
    fn update_handles_cusp_independent() {
        let mut cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::CurveTo {
                x1: 10.0, y1: 0.0, x2: 40.0, y2: 0.0, x: 50.0, y: 0.0,
            },
            PathCommand::CurveTo {
                x1: 60.0, y1: 0.0, x2: 90.0, y2: 0.0, x: 100.0, y: 0.0,
            },
        ];
        // Cusp drag (cusp=true): only outgoing moves, incoming unchanged
        update_handles(&mut cmds, 1, 50.0, 0.0, 70.0, 20.0, true);
        if let PathCommand::CurveTo { x1, y1, .. } = cmds[2] {
            assert!((x1 - 70.0).abs() < 0.01);
            assert!((y1 - 20.0).abs() < 0.01);
        }
        // Incoming handle should be unchanged (40, 0)
        if let PathCommand::CurveTo { x2, y2, .. } = cmds[1] {
            assert!((x2 - 40.0).abs() < 0.01);
            assert!((y2 - 0.0).abs() < 0.01);
        }
    }

    #[test]
    fn toggle_corner_to_smooth() {
        // Corner point: handles at anchor
        let mut cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::CurveTo {
                x1: 10.0, y1: 0.0, x2: 50.0, y2: 0.0, x: 50.0, y: 0.0,
            },
            PathCommand::CurveTo {
                x1: 50.0, y1: 0.0, x2: 90.0, y2: 0.0, x: 100.0, y: 0.0,
            },
        ];
        toggle_smooth_corner(&mut cmds, 1);
        // After toggle, handles should be extended away from anchor
        if let PathCommand::CurveTo { x2, y2, .. } = cmds[1] {
            // Incoming handle should be pulled towards prev anchor
            assert!((x2 - 50.0).abs() > 1.0 || (y2 - 0.0).abs() > 1.0,
                "incoming handle should have moved from anchor");
        }
        if let PathCommand::CurveTo { x1, y1, .. } = cmds[2] {
            // Outgoing handle should be pulled towards next anchor
            assert!((x1 - 50.0).abs() > 1.0 || (y1 - 0.0).abs() > 1.0,
                "outgoing handle should have moved from anchor");
        }
    }

    #[test]
    fn toggle_smooth_to_corner() {
        // Smooth point: handles extended
        let mut cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::CurveTo {
                x1: 10.0, y1: 0.0, x2: 30.0, y2: 0.0, x: 50.0, y: 0.0,
            },
            PathCommand::CurveTo {
                x1: 70.0, y1: 0.0, x2: 90.0, y2: 0.0, x: 100.0, y: 0.0,
            },
        ];
        toggle_smooth_corner(&mut cmds, 1);
        // After toggle, handles should be collapsed to anchor
        if let PathCommand::CurveTo { x2, y2, .. } = cmds[1] {
            assert!((x2 - 50.0).abs() < 0.5);
            assert!((y2 - 0.0).abs() < 0.5);
        }
        if let PathCommand::CurveTo { x1, y1, .. } = cmds[2] {
            assert!((x1 - 50.0).abs() < 0.5);
            assert!((y1 - 0.0).abs() < 0.5);
        }
    }

    #[test]
    fn closest_on_straight_cubic() {
        let (dist, t) = closest_on_cubic(
            0.0, 0.0, 33.0, 0.0, 67.0, 0.0, 100.0, 0.0,
            50.0, 5.0,
        );
        assert!((t - 0.5).abs() < 0.02);
        assert!((dist - 5.0).abs() < 0.5);
    }

    #[test]
    fn closest_segment_finds_correct_segment() {
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 100.0 },
        ];
        // Point near second segment
        let result = closest_segment_and_t(&cmds, 100.0, 50.0);
        assert!(result.is_some());
        let (seg, t) = result.unwrap();
        assert_eq!(seg, 2);
        assert!((t - 0.5).abs() < 0.02);
    }

    #[test]
    fn reposition_anchor_moves_point_and_handles() {
        // Insert a point into a straight cubic, then reposition it
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::CurveTo { x1: 33.0, y1: 0.0, x2: 67.0, y2: 0.0, x: 100.0, y: 0.0 },
        ];
        let ins = insert_point_in_path(&cmds, 1, 0.5);
        let mut new_cmds = ins.commands.clone();
        let idx = ins.first_new_idx;
        let ax = ins.anchor_x;
        let ay = ins.anchor_y;

        // Record the incoming handle (x2 of cmd at idx) before reposition
        let old_in_h = if let PathCommand::CurveTo { x2, y2, .. } = new_cmds[idx] {
            (x2, y2)
        } else { panic!("expected CurveTo") };
        // Record the outgoing handle (x1 of cmd at idx+1) before reposition
        let old_out_h = if let PathCommand::CurveTo { x1, y1, .. } = new_cmds[idx + 1] {
            (x1, y1)
        } else { panic!("expected CurveTo") };

        // Reposition anchor by (10, 5)
        let dx = 10.0;
        let dy = 5.0;
        reposition_anchor(&mut new_cmds, idx, ax + dx, ay + dy, dx, dy);

        // Anchor endpoint should have moved
        if let PathCommand::CurveTo { x, y, .. } = new_cmds[idx] {
            assert!((x - (ax + dx)).abs() < 0.01);
            assert!((y - (ay + dy)).abs() < 0.01);
        } else { panic!("expected CurveTo") }

        // Incoming handle should have shifted by same delta
        if let PathCommand::CurveTo { x2, y2, .. } = new_cmds[idx] {
            assert!((x2 - (old_in_h.0 + dx)).abs() < 0.01);
            assert!((y2 - (old_in_h.1 + dy)).abs() < 0.01);
        }

        // Outgoing handle should have shifted by same delta
        if let PathCommand::CurveTo { x1, y1, .. } = new_cmds[idx + 1] {
            assert!((x1 - (old_out_h.0 + dx)).abs() < 0.01);
            assert!((y1 - (old_out_h.1 + dy)).abs() < 0.01);
        }

        // Endpoints of first and last commands should be unchanged
        if let PathCommand::CurveTo { x, y, .. } = new_cmds[idx + 1] {
            assert!((x - 100.0).abs() < 0.01);
            assert!((y - 0.0).abs() < 0.01);
        }
    }
}
