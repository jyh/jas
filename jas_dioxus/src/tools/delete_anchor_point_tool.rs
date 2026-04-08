//! Delete Anchor Point tool.
//!
//! Clicking on an anchor point removes it from the path, merging the
//! adjacent segments into a single curve that preserves the outer
//! control handles.

use web_sys::CanvasRenderingContext2d;

use crate::document::document::ElementSelection;
use crate::document::model::Model;
use crate::geometry::element::{control_point_count, Element, PathCommand, PathElem};
use super::tool::{CanvasTool, HIT_RADIUS};

pub struct DeleteAnchorPointTool {
    _private: (),
}

impl DeleteAnchorPointTool {
    pub fn new() -> Self {
        Self { _private: () }
    }
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

/// Find an existing anchor point on any path near (px, py).
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

/// Delete the anchor point at `anchor_idx` from the path commands.
///
/// When an interior anchor is deleted, its two adjacent segments are merged
/// into a single segment that keeps the outer control handles (the outgoing
/// handle of the previous anchor and the incoming handle of the next anchor).
///
/// Returns `None` if the resulting path would have fewer than 2 commands
/// (i.e. the path should be removed entirely).
fn delete_anchor_from_path(d: &[PathCommand], anchor_idx: usize) -> Option<Vec<PathCommand>> {
    // Count the number of anchor points (MoveTo, LineTo, CurveTo endpoints)
    let anchor_count = d.iter().filter(|cmd| matches!(cmd,
        PathCommand::MoveTo { .. } | PathCommand::LineTo { .. } | PathCommand::CurveTo { .. }
    )).count();

    // Need at least 2 anchors to have a valid path after deletion
    if anchor_count <= 2 {
        return None;
    }

    // Case 1: Deleting the first point (MoveTo at index 0)
    if anchor_idx == 0 {
        let mut result = Vec::new();
        // The next command becomes the new MoveTo
        if d.len() > 1 {
            let (nx, ny) = match d[1] {
                PathCommand::LineTo { x, y } => (x, y),
                PathCommand::CurveTo { x, y, .. } => (x, y),
                _ => return None,
            };
            result.push(PathCommand::MoveTo { x: nx, y: ny });
            // Skip commands 0 and 1, keep the rest
            for cmd in &d[2..] {
                result.push(*cmd);
            }
        }
        return Some(result);
    }

    // Case 2: Deleting the last anchor point
    let last_anchor_idx = d.len() - 1;
    // Walk backward to find the true last anchor (skip ClosePath)
    let effective_last = if matches!(d[last_anchor_idx], PathCommand::ClosePath) {
        if last_anchor_idx > 0 { last_anchor_idx - 1 } else { last_anchor_idx }
    } else {
        last_anchor_idx
    };

    if anchor_idx == effective_last {
        let mut result: Vec<PathCommand> = d[..anchor_idx].to_vec();
        // If there was a ClosePath after, keep it
        if effective_last < last_anchor_idx {
            result.push(PathCommand::ClosePath);
        }
        return Some(result);
    }

    // Case 3: Deleting an interior anchor point - merge adjacent segments
    let mut result = Vec::new();
    let cmd_at_idx = &d[anchor_idx];
    let cmd_after = &d[anchor_idx + 1];

    for (i, cmd) in d.iter().enumerate() {
        if i == anchor_idx {
            // Skip this anchor - merge with the next command
            match (cmd_at_idx, cmd_after) {
                // Both curves: keep outer handles
                (PathCommand::CurveTo { x1, y1, .. },
                 PathCommand::CurveTo { x2, y2, x, y, .. }) => {
                    result.push(PathCommand::CurveTo {
                        x1: *x1, y1: *y1,
                        x2: *x2, y2: *y2,
                        x: *x, y: *y,
                    });
                }
                // Curve then line: keep outgoing handle of prev, straight to next
                (PathCommand::CurveTo { x1, y1, .. },
                 PathCommand::LineTo { x, y }) => {
                    result.push(PathCommand::CurveTo {
                        x1: *x1, y1: *y1,
                        x2: *x, y2: *y,
                        x: *x, y: *y,
                    });
                }
                // Line then curve: straight from prev, keep incoming handle of next
                (PathCommand::LineTo { .. },
                 PathCommand::CurveTo { x2, y2, x, y, .. }) => {
                    // Get the previous anchor position for the outgoing handle
                    let (px, py) = if anchor_idx > 0 {
                        match d[anchor_idx - 1] {
                            PathCommand::MoveTo { x, y }
                            | PathCommand::LineTo { x, y }
                            | PathCommand::CurveTo { x, y, .. } => (x, y),
                            _ => (0.0, 0.0),
                        }
                    } else {
                        (0.0, 0.0)
                    };
                    result.push(PathCommand::CurveTo {
                        x1: px, y1: py,
                        x2: *x2, y2: *y2,
                        x: *x, y: *y,
                    });
                }
                // Both lines: merge into single line
                (PathCommand::LineTo { .. },
                 PathCommand::LineTo { x, y }) => {
                    result.push(PathCommand::LineTo { x: *x, y: *y });
                }
                _ => {
                    // Fallback: just skip this command
                }
            }
            continue;
        }
        if i == anchor_idx + 1 {
            // Already merged with the previous command
            continue;
        }
        result.push(*cmd);
    }

    Some(result)
}

impl CanvasTool for DeleteAnchorPointTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        if let Some((path, pe, anchor_idx)) = hit_test_anchor(model, x, y) {
            model.snapshot();
            match delete_anchor_from_path(&pe.d, anchor_idx) {
                Some(new_cmds) => {
                    let new_elem = Element::Path(PathElem {
                        d: new_cmds,
                        fill: pe.fill.clone(),
                        stroke: pe.stroke.clone(),
                        common: pe.common.clone(),
                    });
                    let mut doc = model.document().replace_element(&path, new_elem.clone());
                    // Select all remaining control points
                    let _cp_count = control_point_count(&new_elem);
                    doc.selection.retain(|es| es.path != path);
                    doc.selection.push(ElementSelection::all(path.clone()));
                    model.set_document(doc);
                }
                None => {
                    // Path too small after deletion - remove the element entirely
                    let doc = model.document().delete_element(&path);
                    model.set_document(doc);
                }
            }
        }
    }

    fn on_move(&mut self, _model: &mut Model, _x: f64, _y: f64, _shift: bool, _alt: bool, _dragging: bool) {
        // No drag behavior for delete tool
    }

    fn on_release(&mut self, _model: &mut Model, _x: f64, _y: f64, _shift: bool, _alt: bool) {
        // Nothing to do
    }

    fn draw_overlay(&self, _model: &Model, _ctx: &CanvasRenderingContext2d) {
        // No overlay for delete tool
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_cubic_path() -> Vec<PathCommand> {
        vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::CurveTo { x1: 10.0, y1: 0.0, x2: 20.0, y2: 0.0, x: 30.0, y: 0.0 },
            PathCommand::CurveTo { x1: 40.0, y1: 0.0, x2: 50.0, y2: 0.0, x: 60.0, y: 0.0 },
            PathCommand::CurveTo { x1: 70.0, y1: 0.0, x2: 80.0, y2: 0.0, x: 90.0, y: 0.0 },
        ]
    }

    #[test]
    fn delete_interior_anchor_merges_curves() {
        let cmds = make_cubic_path();
        // Delete anchor at index 2 (endpoint at 60,0)
        let result = delete_anchor_from_path(&cmds, 2).unwrap();
        // Should go from 4 commands to 3 (MoveTo + 2 CurveTos)
        assert_eq!(result.len(), 3);
        assert!(matches!(result[0], PathCommand::MoveTo { .. }));
        assert!(matches!(result[1], PathCommand::CurveTo { .. }));
        assert!(matches!(result[2], PathCommand::CurveTo { .. }));

        // The merged curve should keep outer handles:
        // x1,y1 from deleted cmd (outgoing of prev anchor) = 40,0
        // x2,y2 from cmd after deleted (incoming of next anchor) = 80,0
        // x,y = endpoint of cmd after deleted = 90,0
        if let PathCommand::CurveTo { x1, y1, x2, y2, x, y } = result[2] {
            assert!((x1 - 40.0).abs() < 0.01);
            assert!((y1 - 0.0).abs() < 0.01);
            assert!((x2 - 80.0).abs() < 0.01);
            assert!((y2 - 0.0).abs() < 0.01);
            assert!((x - 90.0).abs() < 0.01);
            assert!((y - 0.0).abs() < 0.01);
        } else {
            panic!("expected CurveTo");
        }
    }

    #[test]
    fn delete_first_anchor_promotes_next_to_moveto() {
        let cmds = make_cubic_path();
        // Delete anchor at index 0 (MoveTo at 0,0)
        let result = delete_anchor_from_path(&cmds, 0).unwrap();
        assert_eq!(result.len(), 3);
        // First command should be MoveTo at position of old cmd[1]'s endpoint
        if let PathCommand::MoveTo { x, y } = result[0] {
            assert!((x - 30.0).abs() < 0.01);
            assert!((y - 0.0).abs() < 0.01);
        } else {
            panic!("expected MoveTo");
        }
    }

    #[test]
    fn delete_last_anchor_removes_last_segment() {
        let cmds = make_cubic_path();
        // Delete anchor at index 3 (last, endpoint at 90,0)
        let result = delete_anchor_from_path(&cmds, 3).unwrap();
        assert_eq!(result.len(), 3);
        // Last curve should end at 60,0
        if let PathCommand::CurveTo { x, y, .. } = result[2] {
            assert!((x - 60.0).abs() < 0.01);
            assert!((y - 0.0).abs() < 0.01);
        } else {
            panic!("expected CurveTo");
        }
    }

    #[test]
    fn delete_returns_none_for_two_point_path() {
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::CurveTo { x1: 10.0, y1: 0.0, x2: 20.0, y2: 0.0, x: 30.0, y: 0.0 },
        ];
        // Deleting either point should return None (path too small)
        assert!(delete_anchor_from_path(&cmds, 0).is_none());
        assert!(delete_anchor_from_path(&cmds, 1).is_none());
    }

    #[test]
    fn delete_interior_line_merges_to_single_line() {
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 50.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 0.0 },
        ];
        let result = delete_anchor_from_path(&cmds, 1).unwrap();
        assert_eq!(result.len(), 2);
        if let PathCommand::LineTo { x, y } = result[1] {
            assert!((x - 100.0).abs() < 0.01);
            assert!((y - 0.0).abs() < 0.01);
        } else {
            panic!("expected LineTo");
        }
    }

    #[test]
    fn delete_middle_of_five_point_path() {
        // 5-point path: M, C1, C2, C3, C4
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::CurveTo { x1: 5.0, y1: 10.0, x2: 15.0, y2: 10.0, x: 20.0, y: 0.0 },
            PathCommand::CurveTo { x1: 25.0, y1: -10.0, x2: 35.0, y2: -10.0, x: 40.0, y: 0.0 },
            PathCommand::CurveTo { x1: 45.0, y1: 10.0, x2: 55.0, y2: 10.0, x: 60.0, y: 0.0 },
            PathCommand::CurveTo { x1: 65.0, y1: -10.0, x2: 75.0, y2: -10.0, x: 80.0, y: 0.0 },
        ];
        // Delete anchor at index 2 (40,0)
        let result = delete_anchor_from_path(&cmds, 2).unwrap();
        assert_eq!(result.len(), 4); // M + 3 CurveTos

        // Merged curve at index 2 should have:
        // x1,y1 = outgoing handle of prev (25,-10)
        // x2,y2 = incoming handle of next (55,10)
        // x,y = next endpoint (60,0)
        if let PathCommand::CurveTo { x1, y1, x2, y2, x, y } = result[2] {
            assert!((x1 - 25.0).abs() < 0.01);
            assert!((y1 - (-10.0)).abs() < 0.01);
            assert!((x2 - 55.0).abs() < 0.01);
            assert!((y2 - 10.0).abs() < 0.01);
            assert!((x - 60.0).abs() < 0.01);
            assert!((y - 0.0).abs() < 0.01);
        } else {
            panic!("expected CurveTo");
        }
    }
}
