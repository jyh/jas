//! Path Eraser tool for splitting and removing path segments.
//!
//! When dragged over a path, the eraser splits the path at the drag area,
//! creating two endpoints on either side. Closed paths become open; open paths
//! become two separate paths. Paths with bounding boxes smaller than the eraser
//! size are deleted entirely.

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

                let hit_segment = find_hit_segment(&flat, eraser_min_x, eraser_min_y, eraser_max_x, eraser_max_y);
                if hit_segment.is_none() {
                    continue;
                }
                let hit_idx = hit_segment.unwrap();

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

                // Split the path at the hit segment.
                let results = split_path_at_segment(&path_elem.d, hit_idx, is_closed);

                if let Some(layer_children) = new_doc.layers[li].children_mut() {
                    layer_children.remove(ci);
                    for cmds in results.into_iter().rev() {
                        if cmds.len() >= 2 {
                            let new_path = Element::Path(PathElem {
                                d: cmds,
                                fill: path_elem.fill,
                                stroke: path_elem.stroke,
                                common: CommonProps::default(),
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

/// Find the index of the first flattened segment (between flat[i] and flat[i+1])
/// that intersects the eraser rectangle.
fn find_hit_segment(
    flat: &[(f64, f64)],
    min_x: f64, min_y: f64, max_x: f64, max_y: f64,
) -> Option<usize> {
    for i in 0..flat.len() - 1 {
        let (x1, y1) = flat[i];
        let (x2, y2) = flat[i + 1];
        if line_segment_intersects_rect(x1, y1, x2, y2, min_x, min_y, max_x, max_y) {
            return Some(i);
        }
    }
    None
}

/// Check if a line segment (x1,y1)-(x2,y2) intersects an axis-aligned rectangle.
fn line_segment_intersects_rect(
    x1: f64, y1: f64, x2: f64, y2: f64,
    min_x: f64, min_y: f64, max_x: f64, max_y: f64,
) -> bool {
    // If either endpoint is inside the rectangle.
    if x1 >= min_x && x1 <= max_x && y1 >= min_y && y1 <= max_y {
        return true;
    }
    if x2 >= min_x && x2 <= max_x && y2 >= min_y && y2 <= max_y {
        return true;
    }

    // Cohen-Sutherland style clipping check.
    let mut t_min = 0.0_f64;
    let mut t_max = 1.0_f64;
    let dx = x2 - x1;
    let dy = y2 - y1;

    for &(p, q) in &[
        (-dx, x1 - min_x),
        (dx, max_x - x1),
        (-dy, y1 - min_y),
        (dy, max_y - y1),
    ] {
        if p.abs() < 1e-12 {
            if q < 0.0 {
                return false;
            }
        } else {
            let t = q / p;
            if p < 0.0 {
                t_min = t_min.max(t);
            } else {
                t_max = t_max.min(t);
            }
            if t_min > t_max {
                return false;
            }
        }
    }
    true
}

/// Map a flattened-segment index back to the corresponding path command index.
/// Each CurveTo/QuadTo command generates FLATTEN_STEPS segments, LineTo generates 1,
/// MoveTo generates 0, ClosePath generates 1.
fn flat_index_to_cmd_index(cmds: &[PathCommand], flat_idx: usize) -> usize {
    use crate::geometry::element::FLATTEN_STEPS;
    let mut flat_count = 0usize;
    for (cmd_idx, cmd) in cmds.iter().enumerate() {
        let segs = match cmd {
            PathCommand::MoveTo { .. } => 0,
            PathCommand::LineTo { .. } => 1,
            PathCommand::CurveTo { .. } => FLATTEN_STEPS,
            PathCommand::QuadTo { .. } => FLATTEN_STEPS,
            PathCommand::ClosePath => 1,
            _ => 1, // SmoothCurveTo, SmoothQuadTo, ArcTo approximated as 1 segment
        };
        if segs > 0 && flat_idx < flat_count + segs {
            return cmd_idx;
        }
        flat_count += segs;
    }
    cmds.len().saturating_sub(1)
}

/// Split a path's command list at the given flattened segment index.
/// Returns one or two new command lists.
fn split_path_at_segment(
    cmds: &[PathCommand],
    flat_hit_idx: usize,
    is_closed: bool,
) -> Vec<Vec<PathCommand>> {
    let cmd_idx = flat_index_to_cmd_index(cmds, flat_hit_idx);

    if is_closed {
        // Closed path becomes one open path: rotate commands so the split point
        // becomes the start, and remove the ClosePath.
        let mut open_cmds: Vec<PathCommand> = Vec::new();

        // Collect commands after the split point (excluding ClosePath).
        let drawing_cmds: Vec<&PathCommand> = cmds.iter()
            .filter(|c| !matches!(c, PathCommand::ClosePath))
            .collect();

        if drawing_cmds.is_empty() {
            return vec![];
        }

        // Find the endpoint of the command at cmd_idx (or just after).
        // We'll start the new open path from the endpoint of the removed segment,
        // then continue with remaining commands, wrap around to the start.
        let split_after = (cmd_idx + 1).min(drawing_cmds.len());

        // Commands after the split.
        let after = &drawing_cmds[split_after..];
        // Commands before the split (excluding initial MoveTo — we'll re-add it).
        let before = if drawing_cmds.len() > 1 {
            &drawing_cmds[1..cmd_idx.min(drawing_cmds.len())]
        } else {
            &[]
        };

        // Start with a MoveTo at the endpoint of the split command.
        if let Some(end_pt) = cmd_endpoint(drawing_cmds.get(split_after.saturating_sub(1)).copied().unwrap_or(drawing_cmds[0])) {
            open_cmds.push(PathCommand::MoveTo { x: end_pt.0, y: end_pt.1 });
        }

        for &cmd in after {
            open_cmds.push(*cmd);
        }

        // Wrap around: add the original start point and commands before split.
        if let PathCommand::MoveTo { x, y } = drawing_cmds[0] {
            open_cmds.push(PathCommand::LineTo { x: *x, y: *y });
        }
        for &cmd in before {
            open_cmds.push(*cmd);
        }

        if open_cmds.len() >= 2 {
            vec![open_cmds]
        } else {
            vec![]
        }
    } else {
        // Open path: split into two sub-paths.
        // Part 1: commands from start up to (but not including) the hit command.
        // Part 2: commands from the hit command onward (with a new MoveTo).
        let mut part1: Vec<PathCommand> = Vec::new();
        let mut part2: Vec<PathCommand> = Vec::new();

        // Find current position just before cmd_idx.
        let mut cur = (0.0, 0.0);
        for cmd in &cmds[..cmd_idx] {
            part1.push(*cmd);
            if let Some(pt) = cmd_endpoint(cmd) {
                cur = pt;
            }
        }

        // If part1 has no commands (split at first segment), it's empty.
        // Ensure part1 ends with a proper endpoint.
        if part1.is_empty() || !part1.iter().any(|c| !matches!(c, PathCommand::MoveTo { .. })) {
            // Part1 would be degenerate, skip it.
        }

        // Part 2 starts with MoveTo at the endpoint of the hit command.
        if cmd_idx < cmds.len() {
            if let Some(pt) = cmd_endpoint(&cmds[cmd_idx]) {
                part2.push(PathCommand::MoveTo { x: pt.0, y: pt.1 });
            } else {
                part2.push(PathCommand::MoveTo { x: cur.0, y: cur.1 });
            }
        }

        // Add remaining commands after the hit.
        for cmd in &cmds[cmd_idx + 1..] {
            if matches!(cmd, PathCommand::ClosePath) {
                continue;
            }
            part2.push(*cmd);
        }

        let mut result = Vec::new();
        // Only include non-degenerate parts (at least MoveTo + one drawing command).
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
            self.last_pos = (x, y);
        }
    }

    fn on_release(&mut self, _model: &mut Model, _x: f64, _y: f64, _shift: bool, _alt: bool) {
        self.erasing = false;
    }

    fn draw_overlay(&self, _model: &Model, ctx: &CanvasRenderingContext2d) {
        if !self.erasing {
            return;
        }
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
            common: CommonProps::default(),
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
            common: CommonProps::default(),
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
            common: CommonProps::default(),
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
}
