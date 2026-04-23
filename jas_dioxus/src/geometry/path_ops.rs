//! Path-level operations: anchor insertion, deletion, handle moves.
//!
//! L2 primitives per NATIVE_BOUNDARY.md §5 — path geometry is
//! shared across vector-illustration apps. These were originally
//! inlined in the deleted
//!   tools/delete_anchor_point_tool.rs
//!   tools/anchor_point_tool.rs
//!   tools/add_anchor_point_tool.rs
//! and moved here when those tools migrated to YAML-driven YamlTool.
//! The `interpreter::effects::doc.path.*` effects call into this
//! module.

use crate::geometry::element::PathCommand;

/// Linear interpolation — helper used by split_cubic /
/// insert_point_in_path.
pub fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + t * (b - a)
}

/// Evaluate a cubic Bezier at parameter `t ∈ [0, 1]`. Returns the
/// (x, y) point on the curve.
pub fn eval_cubic(
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

/// Closest-point projection onto a line segment from (x0, y0) to
/// (x1, y1). Returns (distance, t) where t is clamped to [0, 1].
pub fn closest_on_line(
    x0: f64, y0: f64, x1: f64, y1: f64, px: f64, py: f64,
) -> (f64, f64) {
    let dx = x1 - x0;
    let dy = y1 - y0;
    let len_sq = dx * dx + dy * dy;
    if len_sq == 0.0 {
        let d = (px - x0).hypot(py - y0);
        return (d, 0.0);
    }
    let t = ((px - x0) * dx + (py - y0) * dy) / len_sq;
    let t = t.clamp(0.0, 1.0);
    let qx = x0 + t * dx;
    let qy = y0 + t * dy;
    let d = (px - qx).hypot(py - qy);
    (d, t)
}

/// Closest-point projection onto a cubic Bezier. Returns
/// (distance, t). Uses a coarse 50-sample pass followed by a
/// trisection refinement over ~20 iterations — sufficient accuracy
/// for interactive-hit-test purposes (native-equivalent).
pub fn closest_on_cubic(
    x0: f64, y0: f64,
    x1: f64, y1: f64,
    x2: f64, y2: f64,
    x3: f64, y3: f64,
    px: f64, py: f64,
) -> (f64, f64) {
    let steps = 50;
    let mut best_dist = f64::INFINITY;
    let mut best_t = 0.0;
    for i in 0..=steps {
        let t = i as f64 / steps as f64;
        let (bx, by) = eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, t);
        let d = (px - bx).hypot(py - by);
        if d < best_dist {
            best_dist = d;
            best_t = t;
        }
    }
    let mut lo = (best_t - 1.0 / steps as f64).max(0.0);
    let mut hi = (best_t + 1.0 / steps as f64).min(1.0);
    for _ in 0..20 {
        let t1 = lo + (hi - lo) / 3.0;
        let t2 = hi - (hi - lo) / 3.0;
        let (bx1, by1) = eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, t1);
        let (bx2, by2) = eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, t2);
        let d1 = (px - bx1).hypot(py - by1);
        let d2 = (px - bx2).hypot(py - by2);
        if d1 < d2 {
            hi = t2;
        } else {
            lo = t1;
        }
    }
    best_t = (lo + hi) / 2.0;
    let (bx, by) = eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, best_t);
    best_dist = (px - bx).hypot(py - by);
    (best_dist, best_t)
}

/// Split a cubic Bezier at parameter `t`. Returns the two half-cubics
/// as `((a1x, a1y, b1x, b1y, mx, my), (b2x, b2y, a3x, a3y, endX, endY))`
/// — control handles of the first half, then control handles and
/// endpoint of the second half. Start point P0 is implicit.
pub fn split_cubic(
    x0: f64, y0: f64,
    x1: f64, y1: f64,
    x2: f64, y2: f64,
    x3: f64, y3: f64,
    t: f64,
) -> (
    (f64, f64, f64, f64, f64, f64),
    (f64, f64, f64, f64, f64, f64),
) {
    let a1x = lerp(x0, x1, t);
    let a1y = lerp(y0, y1, t);
    let a2x = lerp(x1, x2, t);
    let a2y = lerp(y1, y2, t);
    let a3x = lerp(x2, x3, t);
    let a3y = lerp(y2, y3, t);
    let b1x = lerp(a1x, a2x, t);
    let b1y = lerp(a1y, a2y, t);
    let b2x = lerp(a2x, a3x, t);
    let b2y = lerp(a2y, a3y, t);
    let mx = lerp(b1x, b2x, t);
    let my = lerp(b1y, b2y, t);
    (
        (a1x, a1y, b1x, b1y, mx, my),
        (b2x, b2y, a3x, a3y, x3, y3),
    )
}

/// Find which path segment `(px, py)` is closest to, and the
/// parameter `t` on that segment. Returns `(command_index, t)` — the
/// index refers to the command list position of the LineTo / CurveTo
/// that owns the segment.
pub fn closest_segment_and_t(
    d: &[PathCommand], px: f64, py: f64,
) -> Option<(usize, f64)> {
    let mut best_dist = f64::INFINITY;
    let mut best_seg: usize = 0;
    let mut best_t: f64 = 0.0;
    let mut cx = 0.0_f64;
    let mut cy = 0.0_f64;
    for (i, cmd) in d.iter().enumerate() {
        match cmd {
            PathCommand::MoveTo { x, y } => {
                cx = *x;
                cy = *y;
            }
            PathCommand::LineTo { x, y } => {
                let (dist, t) = closest_on_line(cx, cy, *x, *y, px, py);
                if dist < best_dist {
                    best_dist = dist;
                    best_seg = i;
                    best_t = t;
                }
                cx = *x;
                cy = *y;
            }
            PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                let (dist, t) = closest_on_cubic(
                    cx, cy, *x1, *y1, *x2, *y2, *x, *y, px, py);
                if dist < best_dist {
                    best_dist = dist;
                    best_seg = i;
                    best_t = t;
                }
                cx = *x;
                cy = *y;
            }
            _ => {}
        }
    }
    if best_dist.is_finite() {
        Some((best_seg, best_t))
    } else {
        None
    }
}

/// Result of [`insert_point_in_path`] — the new command list, the
/// command index of the first half of the split, and the new anchor
/// position.
#[derive(Debug, Clone, PartialEq)]
pub struct InsertAnchorResult {
    pub commands: Vec<PathCommand>,
    pub first_new_idx: usize,
    pub anchor_x: f64,
    pub anchor_y: f64,
}

/// Insert an anchor at parameter `t` along the segment at
/// `seg_idx`. Returns the new command list plus metadata. For a
/// LineTo segment, inserts a LineTo + LineTo (splits at lerp). For
/// a CurveTo, uses `split_cubic` to produce two CurveTos that match
/// the original curve shape, splitting at `t`.
pub fn insert_point_in_path(
    d: &[PathCommand], seg_idx: usize, t: f64,
) -> InsertAnchorResult {
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
                    let (
                        (a1x, a1y, b1x, b1y, mx, my),
                        (b2x, b2y, a3x, a3y, ex, ey),
                    ) = split_cubic(cx, cy, *x1, *y1, *x2, *y2, *x, *y, t);
                    first_new_idx = result.len();
                    anchor_x = mx;
                    anchor_y = my;
                    result.push(PathCommand::CurveTo {
                        x1: a1x, y1: a1y, x2: b1x, y2: b1y,
                        x: mx, y: my,
                    });
                    result.push(PathCommand::CurveTo {
                        x1: b2x, y1: b2y, x2: a3x, y2: a3y,
                        x: ex, y: ey,
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
            PathCommand::MoveTo { x, y } => { cx = *x; cy = *y; }
            PathCommand::LineTo { x, y }
            | PathCommand::CurveTo { x, y, .. } => { cx = *x; cy = *y; }
            _ => {}
        }
        result.push(*cmd);
    }
    InsertAnchorResult {
        commands: result,
        first_new_idx,
        anchor_x,
        anchor_y,
    }
}

/// Delete the anchor at `anchor_idx` from `d`. Returns `None` if the
/// result would have < 2 anchors (caller should remove the element
/// entirely).
///
/// Interior deletion merges the two adjacent segments, preserving
/// the outer handles:
/// - curve + curve → single curve keeping (prev.out, next.in)
/// - curve + line  → curve with collapsed outgoing = next endpoint
/// - line  + curve → curve with collapsed incoming = prev endpoint
/// - line  + line  → single line
///
/// Deleting the first anchor (MoveTo) promotes the next command's
/// endpoint to the new MoveTo. Deleting the last anchor trims the
/// trailing segment and preserves any ClosePath that followed.
pub fn delete_anchor_from_path(
    d: &[PathCommand],
    anchor_idx: usize,
) -> Option<Vec<PathCommand>> {
    let anchor_count = d
        .iter()
        .filter(|cmd| {
            matches!(
                cmd,
                PathCommand::MoveTo { .. }
                    | PathCommand::LineTo { .. }
                    | PathCommand::CurveTo { .. }
            )
        })
        .count();

    if anchor_count <= 2 {
        return None;
    }

    // First anchor: promote command[1] into the new MoveTo.
    if anchor_idx == 0 {
        let mut result = Vec::new();
        if d.len() > 1 {
            let (nx, ny) = match d[1] {
                PathCommand::LineTo { x, y } => (x, y),
                PathCommand::CurveTo { x, y, .. } => (x, y),
                _ => return None,
            };
            result.push(PathCommand::MoveTo { x: nx, y: ny });
            for cmd in &d[2..] {
                result.push(*cmd);
            }
        }
        return Some(result);
    }

    // Last anchor: trim the trailing segment, keep any ClosePath.
    let last_cmd_idx = d.len() - 1;
    let effective_last = if matches!(d[last_cmd_idx], PathCommand::ClosePath) {
        if last_cmd_idx > 0 {
            last_cmd_idx - 1
        } else {
            last_cmd_idx
        }
    } else {
        last_cmd_idx
    };
    if anchor_idx == effective_last {
        let mut result: Vec<PathCommand> = d[..anchor_idx].to_vec();
        if effective_last < last_cmd_idx {
            result.push(PathCommand::ClosePath);
        }
        return Some(result);
    }

    // Interior: merge this command with the next.
    let mut result = Vec::new();
    let cmd_at = &d[anchor_idx];
    let cmd_after = &d[anchor_idx + 1];
    for (i, cmd) in d.iter().enumerate() {
        if i == anchor_idx {
            match (cmd_at, cmd_after) {
                (
                    PathCommand::CurveTo { x1, y1, .. },
                    PathCommand::CurveTo { x2, y2, x, y, .. },
                ) => {
                    result.push(PathCommand::CurveTo {
                        x1: *x1,
                        y1: *y1,
                        x2: *x2,
                        y2: *y2,
                        x: *x,
                        y: *y,
                    });
                }
                (
                    PathCommand::CurveTo { x1, y1, .. },
                    PathCommand::LineTo { x, y },
                ) => {
                    result.push(PathCommand::CurveTo {
                        x1: *x1,
                        y1: *y1,
                        x2: *x,
                        y2: *y,
                        x: *x,
                        y: *y,
                    });
                }
                (
                    PathCommand::LineTo { .. },
                    PathCommand::CurveTo { x2, y2, x, y, .. },
                ) => {
                    // Use the previous anchor's position as the new
                    // outgoing handle — matches native behavior.
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
                        x1: px,
                        y1: py,
                        x2: *x2,
                        y2: *y2,
                        x: *x,
                        y: *y,
                    });
                }
                (
                    PathCommand::LineTo { .. },
                    PathCommand::LineTo { x, y },
                ) => {
                    result.push(PathCommand::LineTo { x: *x, y: *y });
                }
                _ => {
                    // Unhandled pairing — leave a gap.
                }
            }
            continue;
        }
        if i == anchor_idx + 1 {
            continue;
        }
        result.push(*cmd);
    }
    Some(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cubic_chain() -> Vec<PathCommand> {
        vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::CurveTo {
                x1: 10.0, y1: 0.0, x2: 20.0, y2: 0.0, x: 30.0, y: 0.0,
            },
            PathCommand::CurveTo {
                x1: 40.0, y1: 0.0, x2: 50.0, y2: 0.0, x: 60.0, y: 0.0,
            },
            PathCommand::CurveTo {
                x1: 70.0, y1: 0.0, x2: 80.0, y2: 0.0, x: 90.0, y: 0.0,
            },
        ]
    }

    #[test]
    fn delete_interior_anchor_merges_curves() {
        let result = delete_anchor_from_path(&cubic_chain(), 2).unwrap();
        assert_eq!(result.len(), 3);
        if let PathCommand::CurveTo { x1, y1, x2, y2, x, y } = result[2] {
            assert_eq!(x1, 40.0);
            assert_eq!(y1, 0.0);
            assert_eq!(x2, 80.0);
            assert_eq!(y2, 0.0);
            assert_eq!(x, 90.0);
            assert_eq!(y, 0.0);
        } else {
            panic!("expected CurveTo");
        }
    }

    #[test]
    fn delete_first_anchor_promotes_next() {
        let result = delete_anchor_from_path(&cubic_chain(), 0).unwrap();
        assert_eq!(result.len(), 3);
        if let PathCommand::MoveTo { x, y } = result[0] {
            assert_eq!(x, 30.0);
            assert_eq!(y, 0.0);
        } else {
            panic!("expected MoveTo");
        }
    }

    #[test]
    fn delete_last_anchor_trims_tail() {
        let result = delete_anchor_from_path(&cubic_chain(), 3).unwrap();
        assert_eq!(result.len(), 3);
        if let PathCommand::CurveTo { x, y, .. } = result[2] {
            assert_eq!(x, 60.0);
            assert_eq!(y, 0.0);
        } else {
            panic!("expected CurveTo");
        }
    }

    #[test]
    fn delete_rejects_two_anchor_path() {
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::CurveTo {
                x1: 10.0, y1: 0.0, x2: 20.0, y2: 0.0, x: 30.0, y: 0.0,
            },
        ];
        assert!(delete_anchor_from_path(&cmds, 0).is_none());
        assert!(delete_anchor_from_path(&cmds, 1).is_none());
    }

    #[test]
    fn delete_interior_lines_merges_to_single_line() {
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 50.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 0.0 },
        ];
        let result = delete_anchor_from_path(&cmds, 1).unwrap();
        assert_eq!(result.len(), 2);
        if let PathCommand::LineTo { x, y } = result[1] {
            assert_eq!(x, 100.0);
            assert_eq!(y, 0.0);
        }
    }

    #[test]
    fn delete_preserves_closepath_after_last_trim() {
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 10.0, y: 0.0 },
            PathCommand::LineTo { x: 10.0, y: 10.0 },
            PathCommand::LineTo { x: 0.0, y: 10.0 },
            PathCommand::ClosePath,
        ];
        // Delete the third anchor (index 3, LineTo to 0,10).
        let result = delete_anchor_from_path(&cmds, 3).unwrap();
        // Should still be closed.
        assert!(matches!(result.last().unwrap(), PathCommand::ClosePath));
    }
}
