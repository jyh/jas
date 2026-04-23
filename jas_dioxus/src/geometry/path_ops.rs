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
