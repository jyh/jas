//! Path Eraser tool for splitting and removing path segments.
//!
//! # Algorithm
//!
//! The eraser sweeps a rectangular region (derived from the cursor position and
//! `ERASER_SIZE`) across the canvas. For each path that intersects this region:
//!
//! 1. **Flatten** — The path's commands (LineTo, CurveTo, QuadTo, etc.) are
//!    flattened into a polyline of straight segments. Bezier curves are
//!    approximated with `FLATTEN_STEPS` (20) line segments each.
//!
//! 2. **Hit detection** — Walk the flattened segments to find the first and
//!    last segments that intersect the eraser rectangle (using Liang-Barsky
//!    line-rectangle clipping). This gives the contiguous "hit range."
//!
//! 3. **Boundary intersection** — Compute the exact entry and exit points
//!    where the path crosses the eraser boundary. Liang-Barsky gives t_min
//!    (entry) and t_max (exit) parameters on the first/last hit flat segments.
//!
//! 4. **Map back to original commands** — `flat_index_to_cmd_and_t` converts
//!    each flat segment index + t-on-segment into a (command index, t) pair.
//!    For a CurveTo with N flatten steps, flat segment j spans
//!    t = [j/N, (j+1)/N], so command-level t = (j + t_seg) / N.
//!
//! 5. **Curve-preserving split** — De Casteljau's algorithm splits Bezier
//!    curves at the entry/exit t parameters, producing two sub-curves that
//!    exactly reconstruct the original. This avoids the loss of shape that
//!    would occur if curves were replaced with straight lines.
//!    - `split_cubic_at(p0, cp1, cp2, end, t)` → two CurveTo commands
//!    - `split_quad_at(p0, cp, end, t)` → two QuadTo commands
//!
//! 6. **Reassembly** — For open paths, the result is two sub-paths: one from
//!    the original start to the entry point, and one from the exit point to the
//!    original end. For closed paths, the path is "unwrapped" into a single
//!    open path that runs from the exit point around the non-erased portion
//!    back to the entry point.
//!
//! Paths whose bounding box is smaller than the eraser are deleted entirely.

use std::rc::Rc;

use web_sys::CanvasRenderingContext2d;

use crate::document::model::Model;
use crate::geometry::element::{
    flatten_path_commands, CommonProps, Element, PathCommand, PathElem,
};

use super::tool::{CanvasTool, ERASER_SIZE};

pub struct PathEraserTool {
    erasing: bool,
    last_pos: (f64, f64),
}

impl PathEraserTool {
    pub fn new() -> Self {
        Self {
            erasing: false,
            last_pos: (0.0, 0.0),
        }
    }

    /// Process eraser at the given position, modifying the document.
    fn erase_at(&self, model: &mut Model, x: f64, y: f64) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        let half = ERASER_SIZE;

        // Build the eraser rectangle from last_pos to (x,y).
        let eraser_min_x = self.last_pos.0.min(x) - half;
        let eraser_min_y = self.last_pos.1.min(y) - half;
        let eraser_max_x = self.last_pos.0.max(x) + half;
        let eraser_max_y = self.last_pos.1.max(y) + half;

        let mut changed = false;

        for (li, layer) in doc.layers.iter().enumerate() {
            let children = match layer.children() {
                Some(c) => c,
                None => continue,
            };
            // Process in reverse order so index removal is stable.
            for ci in (0..children.len()).rev() {
                let child = &children[ci];
                let path_elem = match child.as_ref() {
                    Element::Path(pe) => pe,
                    _ => continue,
                };
                if child.locked() {
                    continue;
                }

                // Check if the path's flattened segments intersect the eraser area.
                let flat = flatten_path_commands(&path_elem.d);
                if flat.len() < 2 {
                    continue;
                }

                let hit = find_eraser_hit(&flat, eraser_min_x, eraser_min_y, eraser_max_x, eraser_max_y);
                let hit = match hit {
                    Some(h) => h,
                    None => continue,
                };

                // Check if the path's bounding box is smaller than the eraser.
                let bounds = child.bounds();
                if bounds.2 <= ERASER_SIZE * 2.0 && bounds.3 <= ERASER_SIZE * 2.0 {
                    // Delete the entire path.
                    if let Some(layer_children) = new_doc.layers[li].children_mut() {
                        layer_children.remove(ci);
                        changed = true;
                    }
                    continue;
                }

                // Determine if the path is closed.
                let is_closed = path_elem.d.iter().any(|c| matches!(c, PathCommand::ClosePath));

                // Split the path at the eraser, with endpoints hugging the boundary.
                let results = split_path_at_eraser(&path_elem.d, &hit, is_closed);

                if let Some(layer_children) = new_doc.layers[li].children_mut() {
                    layer_children.remove(ci);
                    for cmds in results.into_iter().rev() {
                        if cmds.len() >= 2 {
                            let new_path = Element::Path(PathElem {
                                d: cmds,
                                fill: path_elem.fill,
                                stroke: path_elem.stroke,
                                width_points: path_elem.width_points.clone(),
                                common: CommonProps::default(),
                                                            fill_gradient: None,
                                stroke_gradient: None,
                            });
                            layer_children.insert(ci, Rc::new(new_path));
                        }
                    }
                    changed = true;
                }
            }
        }

        if changed {
            new_doc.selection.clear();
            model.set_document(new_doc);
        }
    }
}

/// Result of finding the eraser hit range on a flattened path.
struct EraserHit {
    first_flat_idx: usize,
    last_flat_idx: usize,
    /// Liang-Barsky t on the first hit flat segment (entry).
    entry_t_seg: f64,
    entry: (f64, f64),
    /// Liang-Barsky t on the last hit flat segment (exit).
    exit_t_seg: f64,
    exit: (f64, f64),
}

/// Find the range of flattened segments that intersect the eraser rectangle,
/// and compute the entry/exit points where the path crosses the eraser boundary.
fn find_eraser_hit(
    flat: &[(f64, f64)],
    min_x: f64, min_y: f64, max_x: f64, max_y: f64,
) -> Option<EraserHit> {
    let mut first_hit: Option<usize> = None;
    let mut last_hit: Option<usize> = None;

    for i in 0..flat.len() - 1 {
        let (x1, y1) = flat[i];
        let (x2, y2) = flat[i + 1];
        if line_segment_intersects_rect(x1, y1, x2, y2, min_x, min_y, max_x, max_y) {
            if first_hit.is_none() {
                first_hit = Some(i);
            }
            last_hit = Some(i);
        } else if first_hit.is_some() {
            break;
        }
    }

    let first = first_hit?;
    let last = last_hit.unwrap();

    let (x1, y1) = flat[first];
    let (x2, y2) = flat[first + 1];
    let entry_t_seg = if x1 >= min_x && x1 <= max_x && y1 >= min_y && y1 <= max_y {
        0.0
    } else {
        liang_barsky_t_min(x1, y1, x2, y2, min_x, min_y, max_x, max_y)
    };
    let entry = (x1 + entry_t_seg * (x2 - x1), y1 + entry_t_seg * (y2 - y1));

    let (x1, y1) = flat[last];
    let (x2, y2) = flat[last + 1];
    let exit_t_seg = if x2 >= min_x && x2 <= max_x && y2 >= min_y && y2 <= max_y {
        1.0
    } else {
        liang_barsky_t_max(x1, y1, x2, y2, min_x, min_y, max_x, max_y)
    };
    let exit = (x1 + exit_t_seg * (x2 - x1), y1 + exit_t_seg * (y2 - y1));

    Some(EraserHit { first_flat_idx: first, last_flat_idx: last, entry_t_seg, entry, exit_t_seg, exit })
}

/// Return the Liang-Barsky t_min (entry parameter) for a line segment vs rectangle.
fn liang_barsky_t_min(
    x1: f64, y1: f64, x2: f64, y2: f64,
    min_x: f64, min_y: f64, max_x: f64, max_y: f64,
) -> f64 {
    let dx = x2 - x1;
    let dy = y2 - y1;
    let mut t_min = 0.0_f64;
    for &(p, q) in &[
        (-dx, x1 - min_x), (dx, max_x - x1),
        (-dy, y1 - min_y), (dy, max_y - y1),
    ] {
        if p.abs() >= 1e-12 && p < 0.0 {
            t_min = t_min.max(q / p);
        }
    }
    t_min.clamp(0.0, 1.0)
}

/// Return the Liang-Barsky t_max (exit parameter) for a line segment vs rectangle.
fn liang_barsky_t_max(
    x1: f64, y1: f64, x2: f64, y2: f64,
    min_x: f64, min_y: f64, max_x: f64, max_y: f64,
) -> f64 {
    let dx = x2 - x1;
    let dy = y2 - y1;
    let mut t_max = 1.0_f64;
    for &(p, q) in &[
        (-dx, x1 - min_x), (dx, max_x - x1),
        (-dy, y1 - min_y), (dy, max_y - y1),
    ] {
        if p.abs() >= 1e-12 && p > 0.0 {
            t_max = t_max.min(q / p);
        }
    }
    t_max.clamp(0.0, 1.0)
}

/// Check if a line segment (x1,y1)-(x2,y2) intersects an axis-aligned rectangle.
fn line_segment_intersects_rect(
    x1: f64, y1: f64, x2: f64, y2: f64,
    min_x: f64, min_y: f64, max_x: f64, max_y: f64,
) -> bool {
    if x1 >= min_x && x1 <= max_x && y1 >= min_y && y1 <= max_y {
        return true;
    }
    if x2 >= min_x && x2 <= max_x && y2 >= min_y && y2 <= max_y {
        return true;
    }
    let mut t_min = 0.0_f64;
    let mut t_max = 1.0_f64;
    let dx = x2 - x1;
    let dy = y2 - y1;
    for &(p, q) in &[
        (-dx, x1 - min_x), (dx, max_x - x1),
        (-dy, y1 - min_y), (dy, max_y - y1),
    ] {
        if p.abs() < 1e-12 {
            if q < 0.0 { return false; }
        } else {
            let t = q / p;
            if p < 0.0 { t_min = t_min.max(t); }
            else { t_max = t_max.min(t); }
            if t_min > t_max { return false; }
        }
    }
    true
}

/// Map a flattened-segment index + t on that segment to (command index, t within command).
fn flat_index_to_cmd_and_t(cmds: &[PathCommand], flat_idx: usize, t_on_seg: f64) -> (usize, f64) {
    use crate::geometry::element::FLATTEN_STEPS;
    let mut flat_count = 0usize;
    for (cmd_idx, cmd) in cmds.iter().enumerate() {
        let segs = match cmd {
            PathCommand::MoveTo { .. } => 0,
            PathCommand::LineTo { .. } => 1,
            PathCommand::CurveTo { .. } | PathCommand::QuadTo { .. } => FLATTEN_STEPS,
            PathCommand::ClosePath => 1,
            _ => 1,
        };
        if segs > 0 && flat_idx < flat_count + segs {
            let local = flat_idx - flat_count;
            let t = (local as f64 + t_on_seg) / segs as f64;
            return (cmd_idx, t.clamp(0.0, 1.0));
        }
        flat_count += segs;
    }
    (cmds.len().saturating_sub(1), 1.0)
}

/// Split a cubic Bezier at parameter t using De Casteljau's algorithm.
/// Returns (first_half, second_half) as CurveTo commands.
/// `p0` is the start point of the curve (previous command's endpoint).
fn split_cubic_at(
    p0: (f64, f64),
    x1: f64, y1: f64, x2: f64, y2: f64, x: f64, y: f64,
    t: f64,
) -> (PathCommand, PathCommand) {
    let lerp = |a: f64, b: f64| a + t * (b - a);
    // Level 1
    let ax = lerp(p0.0, x1); let ay = lerp(p0.1, y1);
    let bx = lerp(x1, x2);   let by = lerp(y1, y2);
    let cx = lerp(x2, x);    let cy = lerp(y2, y);
    // Level 2
    let dx = lerp(ax, bx);   let dy = lerp(ay, by);
    let ex = lerp(bx, cx);   let ey = lerp(by, cy);
    // Level 3 — point on curve
    let fx = lerp(dx, ex);   let fy = lerp(dy, ey);

    let first = PathCommand::CurveTo { x1: ax, y1: ay, x2: dx, y2: dy, x: fx, y: fy };
    let second = PathCommand::CurveTo { x1: ex, y1: ey, x2: cx, y2: cy, x, y };
    (first, second)
}

/// Split a quadratic Bezier at parameter t using De Casteljau's algorithm.
fn split_quad_at(
    p0: (f64, f64),
    qx1: f64, qy1: f64, x: f64, y: f64,
    t: f64,
) -> (PathCommand, PathCommand) {
    let lerp = |a: f64, b: f64| a + t * (b - a);
    let ax = lerp(p0.0, qx1); let ay = lerp(p0.1, qy1);
    let bx = lerp(qx1, x);    let by = lerp(qy1, y);
    let cx = lerp(ax, bx);    let cy = lerp(ay, by);

    let first = PathCommand::QuadTo { x1: ax, y1: ay, x: cx, y: cy };
    let second = PathCommand::QuadTo { x1: bx, y1: by, x, y };
    (first, second)
}

/// Build the command start points array (the current point before each command).
fn cmd_start_points(cmds: &[PathCommand]) -> Vec<(f64, f64)> {
    let mut starts = vec![(0.0, 0.0); cmds.len()];
    let mut cur = (0.0, 0.0);
    for (i, cmd) in cmds.iter().enumerate() {
        starts[i] = cur;
        if let Some(pt) = cmd_endpoint(cmd) {
            cur = pt;
        }
    }
    starts
}

/// Generate the "first half" command that ends at the entry point, preserving curves.
fn entry_cmd(cmd: &PathCommand, start: (f64, f64), t: f64) -> PathCommand {
    match cmd {
        PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
            split_cubic_at(start, *x1, *y1, *x2, *y2, *x, *y, t).0
        }
        PathCommand::QuadTo { x1, y1, x, y } => {
            split_quad_at(start, *x1, *y1, *x, *y, t).0
        }
        _ => {
            // LineTo, ClosePath, etc: linear interpolation.
            let end = cmd_endpoint(cmd).unwrap_or(start);
            PathCommand::LineTo {
                x: start.0 + t * (end.0 - start.0),
                y: start.1 + t * (end.1 - start.1),
            }
        }
    }
}

/// Generate the "second half" command that starts from the exit point, preserving curves.
fn exit_cmd(cmd: &PathCommand, start: (f64, f64), t: f64) -> PathCommand {
    match cmd {
        PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
            split_cubic_at(start, *x1, *y1, *x2, *y2, *x, *y, t).1
        }
        PathCommand::QuadTo { x1, y1, x, y } => {
            split_quad_at(start, *x1, *y1, *x, *y, t).1
        }
        _ => {
            // LineTo, etc: just go to the original endpoint.
            let end = cmd_endpoint(cmd).unwrap_or(start);
            PathCommand::LineTo { x: end.0, y: end.1 }
        }
    }
}

/// Split a path at the eraser hit, with endpoints hugging the eraser boundary
/// and curves preserved via De Casteljau splitting.
fn split_path_at_eraser(
    cmds: &[PathCommand],
    hit: &EraserHit,
    is_closed: bool,
) -> Vec<Vec<PathCommand>> {
    let (entry_cmd_idx, entry_t) = flat_index_to_cmd_and_t(cmds, hit.first_flat_idx, hit.entry_t_seg);
    let (exit_cmd_idx, exit_t) = flat_index_to_cmd_and_t(cmds, hit.last_flat_idx, hit.exit_t_seg);
    let starts = cmd_start_points(cmds);

    if is_closed {
        let drawing_cmds: Vec<(usize, &PathCommand)> = cmds.iter().enumerate()
            .filter(|(_, c)| !matches!(c, PathCommand::ClosePath))
            .collect();

        if drawing_cmds.is_empty() {
            return vec![];
        }

        let _n = drawing_cmds.len();
        let mut open_cmds: Vec<PathCommand> = Vec::new();

        // Start at the exit point.
        open_cmds.push(PathCommand::MoveTo { x: hit.exit.0, y: hit.exit.1 });

        // If the exit command has a remaining portion, add it as a curve.
        if exit_t < 1.0 - 1e-9 {
            let (orig_idx, cmd) = drawing_cmds.iter()
                .find(|(i, _)| *i == exit_cmd_idx).unwrap();
            open_cmds.push(exit_cmd(cmd, starts[*orig_idx], exit_t));
        }

        // Commands after the last erased command.
        let resume_from = exit_cmd_idx + 1;
        for (orig_idx, cmd) in &drawing_cmds {
            if *orig_idx >= resume_from && *orig_idx < cmds.len() {
                open_cmds.push(**cmd);
            }
        }

        // Wrap around: line to original start, then commands before the erased region.
        if let Some((_, PathCommand::MoveTo { x, y })) = drawing_cmds.first() {
            open_cmds.push(PathCommand::LineTo { x: *x, y: *y });
        }
        for (orig_idx, cmd) in &drawing_cmds {
            if *orig_idx >= 1 && *orig_idx < entry_cmd_idx {
                open_cmds.push(**cmd);
            }
        }

        // End with the entry portion of the entry command.
        if entry_t > 1e-9 {
            open_cmds.push(entry_cmd(&cmds[entry_cmd_idx], starts[entry_cmd_idx], entry_t));
        } else {
            // Entry is at the very start of the command — end at the command's start point.
            open_cmds.push(PathCommand::LineTo { x: hit.entry.0, y: hit.entry.1 });
        }

        if open_cmds.len() >= 2 { vec![open_cmds] } else { vec![] }
    } else {
        let mut part1: Vec<PathCommand> = Vec::new();
        let mut part2: Vec<PathCommand> = Vec::new();

        // Part 1: commands before entry, plus the first portion of the entry command.
        for cmd in &cmds[..entry_cmd_idx] {
            part1.push(*cmd);
        }
        if entry_t > 1e-9 {
            part1.push(entry_cmd(&cmds[entry_cmd_idx], starts[entry_cmd_idx], entry_t));
        } else {
            part1.push(PathCommand::LineTo { x: hit.entry.0, y: hit.entry.1 });
        }

        // Part 2: start at exit point, add remaining portion of exit command, then rest.
        part2.push(PathCommand::MoveTo { x: hit.exit.0, y: hit.exit.1 });
        if exit_t < 1.0 - 1e-9 {
            part2.push(exit_cmd(&cmds[exit_cmd_idx], starts[exit_cmd_idx], exit_t));
        }
        for cmd in &cmds[exit_cmd_idx + 1..] {
            if !matches!(cmd, PathCommand::ClosePath) {
                part2.push(*cmd);
            }
        }

        let mut result = Vec::new();
        if part1.len() >= 2 && part1.iter().any(|c| !matches!(c, PathCommand::MoveTo { .. })) {
            result.push(part1);
        }
        if part2.len() >= 2 {
            result.push(part2);
        }
        result
    }
}

/// Get the endpoint of a path command (the point the pen moves to).
fn cmd_endpoint(cmd: &PathCommand) -> Option<(f64, f64)> {
    match cmd {
        PathCommand::MoveTo { x, y }
        | PathCommand::LineTo { x, y }
        | PathCommand::SmoothQuadTo { x, y } => Some((*x, *y)),
        PathCommand::CurveTo { x, y, .. }
        | PathCommand::SmoothCurveTo { x, y, .. }
        | PathCommand::QuadTo { x, y, .. }
        | PathCommand::ArcTo { x, y, .. } => Some((*x, *y)),
        PathCommand::ClosePath => None,
    }
}

impl CanvasTool for PathEraserTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        model.snapshot();
        self.erasing = true;
        self.last_pos = (x, y);
        self.erase_at(model, x, y);
    }

    fn on_move(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool, _dragging: bool) {
        if self.erasing {
            self.erase_at(model, x, y);
        }
        self.last_pos = (x, y);
    }

    fn on_release(&mut self, _model: &mut Model, _x: f64, _y: f64, _shift: bool, _alt: bool) {
        self.erasing = false;
    }

    fn draw_overlay(&self, _model: &Model, ctx: &CanvasRenderingContext2d) {
        // Draw eraser circle at current position.
        let (x, y) = self.last_pos;
        ctx.set_stroke_style_str("rgba(255, 0, 0, 0.5)");
        ctx.set_line_width(1.0);
        ctx.begin_path();
        let _ = ctx.arc(x, y, ERASER_SIZE, 0.0, std::f64::consts::TAU);
        ctx.stroke();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::{Color, Fill, Stroke};

    fn make_line_path(x1: f64, y1: f64, x2: f64, y2: f64) -> Element {
        Element::Path(PathElem {
            d: vec![
                PathCommand::MoveTo { x: x1, y: y1 },
                PathCommand::LineTo { x: x2, y: y2 },
            ],
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: Vec::new(),
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })
    }

    fn make_long_path() -> Element {
        Element::Path(PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: 50.0, y: 0.0 },
                PathCommand::LineTo { x: 100.0, y: 0.0 },
                PathCommand::LineTo { x: 150.0, y: 0.0 },
            ],
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: Vec::new(),
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })
    }

    fn make_closed_path() -> Element {
        Element::Path(PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: 100.0, y: 0.0 },
                PathCommand::LineTo { x: 100.0, y: 100.0 },
                PathCommand::LineTo { x: 0.0, y: 100.0 },
                PathCommand::ClosePath,
            ],
            fill: Some(Fill::new(Color::BLACK)),
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: Vec::new(),
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })
    }

    fn layer_children(model: &Model) -> &[Rc<Element>] {
        model.document().layers[0].children().unwrap()
    }

    #[test]
    fn erase_deletes_small_path() {
        let mut tool = PathEraserTool::new();
        let mut model = Model::default();
        // A very small path (bbox < eraser size).
        let small = make_line_path(0.0, 0.0, 1.0, 1.0);
        crate::document::controller::Controller::add_element(&mut model, small);
        assert_eq!(layer_children(&model).len(), 1);

        tool.on_press(&mut model, 0.5, 0.5, false, false);
        tool.on_release(&mut model, 0.5, 0.5, false, false);
        assert_eq!(layer_children(&model).len(), 0);
    }

    #[test]
    fn erase_splits_open_path() {
        let mut tool = PathEraserTool::new();
        let mut model = Model::default();
        let path = make_long_path();
        crate::document::controller::Controller::add_element(&mut model, path);
        assert_eq!(layer_children(&model).len(), 1);

        // Erase at the middle segment (around x=75).
        tool.on_press(&mut model, 75.0, 0.0, false, false);
        tool.on_release(&mut model, 75.0, 0.0, false, false);

        // Should have been split into two paths.
        let children = layer_children(&model);
        assert_eq!(children.len(), 2, "open path should split into 2 parts");
    }

    #[test]
    fn erase_opens_closed_path() {
        let mut tool = PathEraserTool::new();
        let mut model = Model::default();
        let path = make_closed_path();
        crate::document::controller::Controller::add_element(&mut model, path);
        assert_eq!(layer_children(&model).len(), 1);

        // Erase at the top edge (y=0, around x=50).
        tool.on_press(&mut model, 50.0, 0.0, false, false);
        tool.on_release(&mut model, 50.0, 0.0, false, false);

        // Closed path becomes one open path.
        let children = layer_children(&model);
        assert_eq!(children.len(), 1, "closed path should become one open path");
        if let Element::Path(pe) = children[0].as_ref() {
            assert!(!pe.d.iter().any(|c| matches!(c, PathCommand::ClosePath)),
                "result should not be closed");
        }
    }

    #[test]
    fn erase_miss_does_nothing() {
        let mut tool = PathEraserTool::new();
        let mut model = Model::default();
        let path = make_long_path();
        crate::document::controller::Controller::add_element(&mut model, path);

        // Erase far from the path.
        tool.on_press(&mut model, 75.0, 50.0, false, false);
        tool.on_release(&mut model, 75.0, 50.0, false, false);

        assert_eq!(layer_children(&model).len(), 1);
    }

    #[test]
    fn release_without_press_is_noop() {
        let mut tool = PathEraserTool::new();
        let mut model = Model::default();
        let path = make_long_path();
        crate::document::controller::Controller::add_element(&mut model, path);

        tool.on_release(&mut model, 75.0, 0.0, false, false);
        assert_eq!(layer_children(&model).len(), 1);
    }

    #[test]
    fn move_without_press_is_noop() {
        let mut tool = PathEraserTool::new();
        let mut model = Model::default();
        let path = make_long_path();
        crate::document::controller::Controller::add_element(&mut model, path);

        tool.on_move(&mut model, 75.0, 0.0, false, false, true);
        assert_eq!(layer_children(&model).len(), 1);
    }

    #[test]
    fn erasing_state_transitions() {
        let mut tool = PathEraserTool::new();
        let mut model = Model::default();
        assert!(!tool.erasing);
        tool.on_press(&mut model, 0.0, 0.0, false, false);
        assert!(tool.erasing);
        tool.on_release(&mut model, 0.0, 0.0, false, false);
        assert!(!tool.erasing);
    }

    #[test]
    fn locked_path_not_erased() {
        let mut tool = PathEraserTool::new();
        let mut model = Model::default();
        let mut path_elem = make_line_path(0.0, 0.0, 1.0, 1.0);
        path_elem.common_mut().locked = true;
        crate::document::controller::Controller::add_element(&mut model, path_elem);

        tool.on_press(&mut model, 0.5, 0.5, false, false);
        tool.on_release(&mut model, 0.5, 0.5, false, false);
        assert_eq!(layer_children(&model).len(), 1, "locked path should not be erased");
    }

    #[test]
    fn split_endpoints_hug_eraser() {
        // A horizontal path (0,0)→(100,0)→(200,0).
        // Erase at x=50 with ERASER_SIZE=2 => eraser rect x=[48,52].
        // Part1 should end near x=48, part2 should start near x=52.
        let mut tool = PathEraserTool::new();
        let mut model = Model::default();
        let path = Element::Path(PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: 100.0, y: 0.0 },
                PathCommand::LineTo { x: 200.0, y: 0.0 },
            ],
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: Vec::new(),
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        });
        crate::document::controller::Controller::add_element(&mut model, path);

        tool.on_press(&mut model, 50.0, 0.0, false, false);
        tool.on_release(&mut model, 50.0, 0.0, false, false);

        let children = layer_children(&model);
        assert_eq!(children.len(), 2, "should split into 2 parts");

        // Part 1 ends at the entry point (x ≈ 48).
        if let Element::Path(pe) = children[0].as_ref() {
            let last_cmd = pe.d.last().unwrap();
            let end = cmd_endpoint(last_cmd).unwrap();
            assert!((end.0 - 48.0).abs() < 0.5, "part1 end x={} should be near 48, got {}", end.0, end.0);
        }

        // Part 2 starts at the exit point (x ≈ 52).
        if let Element::Path(pe) = children[1].as_ref() {
            let first_cmd = &pe.d[0];
            if let PathCommand::MoveTo { x, .. } = first_cmd {
                assert!((*x - 52.0).abs() < 0.5, "part2 start x={} should be near 52, got {}", x, x);
            }
        }
    }

    #[test]
    fn split_preserves_curves() {
        // A cubic curve from (0,0) to (200,0) with control points pulling upward.
        // Erasing at the midpoint should produce CurveTo commands, not LineTo.
        let mut tool = PathEraserTool::new();
        let mut model = Model::default();
        let path = Element::Path(PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::CurveTo { x1: 50.0, y1: -100.0, x2: 150.0, y2: -100.0, x: 200.0, y: 0.0 },
            ],
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: Vec::new(),
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        });
        crate::document::controller::Controller::add_element(&mut model, path);

        // Erase near the top of the arc (midpoint of the curve).
        tool.on_press(&mut model, 100.0, -75.0, false, false);
        tool.on_release(&mut model, 100.0, -75.0, false, false);

        let children = layer_children(&model);
        assert_eq!(children.len(), 2, "should split into 2 parts");

        // Both parts should contain CurveTo commands (not LineTo).
        if let Element::Path(pe) = children[0].as_ref() {
            let last = pe.d.last().unwrap();
            assert!(matches!(last, PathCommand::CurveTo { .. }),
                "part1 should end with CurveTo, got {:?}", last);
        }
        if let Element::Path(pe) = children[1].as_ref() {
            assert!(pe.d.len() >= 2, "part2 should have at least 2 commands");
            let second = &pe.d[1];
            assert!(matches!(second, PathCommand::CurveTo { .. }),
                "part2 should contain CurveTo, got {:?}", second);
            // The CurveTo should end at the original endpoint (200, 0).
            if let PathCommand::CurveTo { x, y, .. } = second {
                assert!((*x - 200.0).abs() < 0.01, "curve should end at x=200, got {}", x);
                assert!((*y - 0.0).abs() < 0.01, "curve should end at y=0, got {}", y);
            }
        }
    }

    #[test]
    fn de_casteljau_split_exact() {
        // Splitting at t=0.5 on a symmetric curve should give the midpoint.
        let (first, second) = split_cubic_at(
            (0.0, 0.0), 0.0, 100.0, 100.0, 100.0, 100.0, 0.0, 0.5
        );
        if let PathCommand::CurveTo { x, y, .. } = first {
            assert!((x - 50.0).abs() < 0.01, "first half endpoint x={}", x);
            assert!((y - 75.0).abs() < 0.01, "first half endpoint y={}", y);
        }
        if let PathCommand::CurveTo { x, y, .. } = second {
            assert!((x - 100.0).abs() < 0.01, "second half endpoint x={}", x);
            assert!((y - 0.0).abs() < 0.01, "second half endpoint y={}", y);
        }
    }
}
