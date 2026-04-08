//! Smooth tool for simplifying path curves by re-fitting anchor points.
//!
//! # Overview
//!
//! The Smooth tool is a brush-like tool that simplifies vector paths by
//! reducing the number of anchor points while preserving the overall shape.
//! The user drags the tool over a selected path, and the portion of the path
//! that falls within the tool's circular influence region (radius =
//! `SMOOTH_SIZE`, currently 100 pt) is simplified in real time.
//!
//! Only selected, unlocked Path elements are affected. Non-path elements
//! (rectangles, ellipses, text, etc.) and locked paths are skipped.
//!
//! # Algorithm
//!
//! Each time the tool processes a cursor position (on press and on drag),
//! it runs the following pipeline on every selected path:
//!
//! ## 1. Flatten with command map
//!
//! The path's command list (MoveTo, LineTo, CurveTo, QuadTo, etc.) is
//! converted into a dense polyline of (x, y) points. Curves are subdivided
//! into `FLATTEN_STEPS` (20) evenly-spaced samples using de Casteljau
//! evaluation. Straight segments produce a single point.
//!
//! Alongside the flat point array, a parallel **command map** array is built:
//! `cmd_map[i]` records the index of the original path command that produced
//! flat point `i`. This mapping is the key data structure that connects the
//! polyline back to the original command list.
//!
//! ## 2. Hit detection
//!
//! The flat points are scanned to find the **contiguous range** that lies
//! within the tool's circular influence region (distance ≤ `SMOOTH_SIZE`
//! from the cursor). The scan records `first_hit` and `last_hit` — the
//! indices of the first and last flat points inside the circle.
//!
//! If no flat points are within range, the path is skipped.
//!
//! ## 3. Command mapping
//!
//! The flat-point hit indices are mapped back to original command indices
//! via the command map: `first_cmd = cmd_map[first_hit]` and
//! `last_cmd = cmd_map[last_hit]`. These define the range of original
//! commands `[first_cmd, last_cmd]` that will be replaced.
//!
//! If `first_cmd == last_cmd`, the influence region only touches points
//! from a single command — there is nothing to merge, so the path is
//! skipped. At least two commands must be affected for smoothing to have
//! any effect.
//!
//! ## 4. Re-fit (Schneider curve fitting)
//!
//! All flat points whose command index falls in `[first_cmd, last_cmd]`
//! are collected into `range_flat`. The start point of `first_cmd` (i.e.
//! the endpoint of the preceding command) is prepended to form
//! `points_to_fit`, ensuring the re-fitted curve begins exactly where the
//! unaffected prefix ends.
//!
//! These points are passed to `fit_curve()`, which implements the Schneider
//! curve-fitting algorithm. This algorithm recursively subdivides the point
//! sequence and fits cubic Bezier segments to each subdivision, using
//! `SMOOTH_ERROR` (8.0) as the maximum allowed deviation. Because this
//! tolerance is relatively generous, the fitter typically produces fewer
//! Bezier segments than the original commands — that is the simplification.
//!
//! ## 5. Reassembly
//!
//! The original command list is reconstructed in three parts:
//!   - **Prefix**: commands `[0, first_cmd)` — unchanged.
//!   - **Middle**: the re-fitted CurveTo commands from step 4.
//!   - **Suffix**: commands `(last_cmd, end]` — unchanged.
//!
//! If the resulting command count is not strictly less than the original,
//! the replacement is discarded (no improvement). Otherwise the path
//! element is replaced in the document.
//!
//! ## Cumulative effect
//!
//! The effect is cumulative: each drag pass removes more detail, producing
//! progressively smoother curves. Repeatedly dragging over the same region
//! continues to simplify until the path can be represented by a single
//! Bezier segment (or the fit can no longer reduce the command count).
//!
//! ## Overlay
//!
//! While the tool is active, a cornflower-blue circle (rgba 100, 149, 237,
//! 0.4) is drawn at the cursor position showing the influence region.

use web_sys::CanvasRenderingContext2d;

use crate::document::model::Model;
use crate::geometry::element::{
    flatten_path_commands, Element, PathCommand, PathElem, FLATTEN_STEPS,
};
use crate::algorithms::fit_curve::fit_curve;

use super::tool::{CanvasTool, SMOOTH_SIZE};

/// Error tolerance for curve re-fitting. Higher = smoother (fewer points).
const SMOOTH_ERROR: f64 = 8.0;

pub struct SmoothTool {
    smoothing: bool,
    last_pos: (f64, f64),
}

impl SmoothTool {
    pub fn new() -> Self {
        Self {
            smoothing: false,
            last_pos: (0.0, 0.0),
        }
    }

    /// Smooth selected paths at the given cursor position.
    ///
    /// For each selected, unlocked path element with at least 2 commands:
    ///   1. Flatten the path into a polyline with a command-index map.
    ///   2. Find which flat points fall inside the influence circle.
    ///   3. Map those flat indices back to original command indices.
    ///   4. Re-fit the affected region with Schneider curve fitting.
    ///   5. Splice the re-fitted curves into the original command list.
    /// If the result has fewer commands, update the document.
    fn smooth_at(&self, model: &mut Model, x: f64, y: f64) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        let radius = SMOOTH_SIZE;
        let radius_sq = radius * radius;
        let mut changed = false;

        for es in &doc.selection {
            let path = &es.path;
            let elem = match doc.get_element(path) {
                Some(e) => e,
                None => continue,
            };
            let path_elem = match elem {
                Element::Path(pe) => pe,
                _ => continue,
            };
            if elem.locked() {
                continue;
            }
            if path_elem.d.len() < 2 {
                continue;
            }

            // Flatten with command mapping.
            let (flat, cmd_map) = flatten_with_cmd_map(&path_elem.d);
            if flat.len() < 2 {
                continue;
            }

            // Find contiguous range of flat points within the circle.
            let mut first_hit: Option<usize> = None;
            let mut last_hit: Option<usize> = None;
            for (i, &(px, py)) in flat.iter().enumerate() {
                let dx = px - x;
                let dy = py - y;
                if dx * dx + dy * dy <= radius_sq {
                    if first_hit.is_none() {
                        first_hit = Some(i);
                    }
                    last_hit = Some(i);
                }
            }

            let (first_flat, last_flat) = match (first_hit, last_hit) {
                (Some(f), Some(l)) => (f, l),
                _ => continue,
            };

            // Map to command indices.
            let first_cmd = cmd_map[first_flat];
            let last_cmd = cmd_map[last_flat];

            // Need at least 2 commands affected to smooth.
            if first_cmd >= last_cmd {
                continue;
            }

            // Collect flattened points for the affected command range.
            // Include the start point of the first affected command.
            let range_flat: Vec<(f64, f64)> = flat
                .iter()
                .enumerate()
                .filter(|(i, _)| {
                    let ci = cmd_map[*i];
                    ci >= first_cmd && ci <= last_cmd
                })
                .map(|(_, &p)| p)
                .collect();

            // Also include the start point (the end of the command before first_cmd).
            let start_point = cmd_start_point(&path_elem.d, first_cmd);
            let mut points_to_fit = vec![start_point];
            points_to_fit.extend_from_slice(&range_flat);

            if points_to_fit.len() < 2 {
                continue;
            }

            // Re-fit the points.
            let segments = fit_curve(&points_to_fit, SMOOTH_ERROR);
            if segments.is_empty() {
                continue;
            }

            // Build replacement commands.
            let mut new_cmds: Vec<PathCommand> = Vec::new();

            // Commands before the affected range.
            for cmd in &path_elem.d[..first_cmd] {
                new_cmds.push(cmd.clone());
            }

            // Re-fitted curves.
            for seg in &segments {
                new_cmds.push(PathCommand::CurveTo {
                    x1: seg.2,
                    y1: seg.3,
                    x2: seg.4,
                    y2: seg.5,
                    x: seg.6,
                    y: seg.7,
                });
            }

            // Commands after the affected range.
            for cmd in &path_elem.d[last_cmd + 1..] {
                new_cmds.push(cmd.clone());
            }

            // Skip if no actual change in command count or structure.
            if new_cmds.len() >= path_elem.d.len() {
                continue;
            }

            let new_elem = Element::Path(PathElem {
                d: new_cmds,
                fill: path_elem.fill,
                stroke: path_elem.stroke,
                common: path_elem.common.clone(),
            });
            new_doc = new_doc.replace_element(path, new_elem);
            changed = true;
        }

        if changed {
            model.set_document(new_doc);
        }
    }
}

/// Return the start point of command at `cmd_idx`.
///
/// A path command's "start point" is the endpoint of the preceding command,
/// since each command implicitly begins where the previous one ended. For
/// the first command (index 0), the start point is the origin (0, 0).
///
/// This is used during re-fitting to prepend the correct start point to
/// the collected flat points, ensuring the re-fitted curve connects
/// seamlessly with the unaffected prefix of the path.
fn cmd_start_point(cmds: &[PathCommand], cmd_idx: usize) -> (f64, f64) {
    if cmd_idx == 0 {
        return (0.0, 0.0);
    }
    cmd_endpoint(&cmds[cmd_idx - 1])
}

/// Return the endpoint of a path command.
///
/// Every path command except ClosePath moves the "pen" to a new position.
/// This function extracts that final position. For ClosePath, which returns
/// to the last MoveTo, we return (0, 0) as a fallback — ClosePath commands
/// are not expected in the middle of a smoothable region.
fn cmd_endpoint(cmd: &PathCommand) -> (f64, f64) {
    match cmd {
        PathCommand::MoveTo { x, y }
        | PathCommand::LineTo { x, y }
        | PathCommand::SmoothQuadTo { x, y } => (*x, *y),
        PathCommand::CurveTo { x, y, .. }
        | PathCommand::SmoothCurveTo { x, y, .. }
        | PathCommand::QuadTo { x, y, .. }
        | PathCommand::ArcTo { x, y, .. } => (*x, *y),
        PathCommand::ClosePath => (0.0, 0.0),
    }
}

/// Flatten path commands into a polyline with a parallel command-index map.
///
/// Returns `(flat_points, cmd_map)` where:
///   - `flat_points[i]` is the (x, y) position of the i-th polyline sample.
///   - `cmd_map[i]` is the index of the original path command that produced
///     `flat_points[i]`.
///
/// **MoveTo** and **LineTo** commands produce exactly one flat point each.
/// **CurveTo** commands are subdivided into `FLATTEN_STEPS` samples using
/// the cubic Bezier formula: B(t) = (1-t)³·P0 + 3(1-t)²t·P1 + 3(1-t)t²·P2 + t³·P3,
/// evaluated at t = 1/steps, 2/steps, …, 1. This captures the curve's shape
/// as a dense polyline while recording which command each sample came from.
/// **QuadTo** commands are similarly subdivided using the quadratic formula.
/// **ClosePath** produces no points. Rare commands (SmoothCurveTo,
/// SmoothQuadTo, ArcTo) are approximated as a single point at their endpoint.
fn flatten_with_cmd_map(cmds: &[PathCommand]) -> (Vec<(f64, f64)>, Vec<usize>) {
    let mut pts = Vec::new();
    let mut map = Vec::new();
    let mut cx = 0.0_f64;
    let mut cy = 0.0_f64;
    let steps = FLATTEN_STEPS;

    for (cmd_idx, cmd) in cmds.iter().enumerate() {
        match cmd {
            PathCommand::MoveTo { x, y } => {
                pts.push((*x, *y));
                map.push(cmd_idx);
                cx = *x;
                cy = *y;
            }
            PathCommand::LineTo { x, y } => {
                pts.push((*x, *y));
                map.push(cmd_idx);
                cx = *x;
                cy = *y;
            }
            PathCommand::CurveTo {
                x1, y1, x2, y2, x, y,
            } => {
                for i in 1..=steps {
                    let t = i as f64 / steps as f64;
                    let mt = 1.0 - t;
                    let px = mt.powi(3) * cx
                        + 3.0 * mt.powi(2) * t * x1
                        + 3.0 * mt * t.powi(2) * x2
                        + t.powi(3) * x;
                    let py = mt.powi(3) * cy
                        + 3.0 * mt.powi(2) * t * y1
                        + 3.0 * mt * t.powi(2) * y2
                        + t.powi(3) * y;
                    pts.push((px, py));
                    map.push(cmd_idx);
                }
                cx = *x;
                cy = *y;
            }
            PathCommand::QuadTo { x1, y1, x, y } => {
                for i in 1..=steps {
                    let t = i as f64 / steps as f64;
                    let mt = 1.0 - t;
                    let px = mt.powi(2) * cx + 2.0 * mt * t * x1 + t.powi(2) * x;
                    let py = mt.powi(2) * cy + 2.0 * mt * t * y1 + t.powi(2) * y;
                    pts.push((px, py));
                    map.push(cmd_idx);
                }
                cx = *x;
                cy = *y;
            }
            PathCommand::ClosePath => {
                // ClosePath goes back to the last MoveTo; skip for now.
            }
            _ => {
                // SmoothCurveTo, SmoothQuadTo, Arc — treat as LineTo to endpoint.
                let (ex, ey) = cmd_endpoint(cmd);
                pts.push((ex, ey));
                map.push(cmd_idx);
                cx = ex;
                cy = ey;
            }
        }
    }
    (pts, map)
}

impl CanvasTool for SmoothTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        model.snapshot();
        self.smoothing = true;
        self.last_pos = (x, y);
        self.smooth_at(model, x, y);
    }

    fn on_move(
        &mut self,
        model: &mut Model,
        x: f64,
        y: f64,
        _shift: bool,
        _alt: bool,
        _dragging: bool,
    ) {
        if self.smoothing {
            self.smooth_at(model, x, y);
        }
        self.last_pos = (x, y);
    }

    fn on_release(&mut self, _model: &mut Model, _x: f64, _y: f64, _shift: bool, _alt: bool) {
        self.smoothing = false;
    }

    fn draw_overlay(&self, _model: &Model, ctx: &CanvasRenderingContext2d) {
        // Draw smooth circle at current position.
        let (x, y) = self.last_pos;
        ctx.set_stroke_style_str("rgba(100, 149, 237, 0.4)");
        ctx.set_line_width(1.0);
        ctx.begin_path();
        let _ = ctx.arc(x, y, SMOOTH_SIZE, 0.0, std::f64::consts::TAU);
        ctx.stroke();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::controller::Controller;
    use crate::document::document::ElementSelection;
    use crate::geometry::element::{Color, CommonProps, Stroke};
    use std::collections::HashSet;

    fn make_zigzag_path() -> Element {
        // A path with many small zigzag segments that can be smoothed.
        let mut cmds = vec![PathCommand::MoveTo { x: 0.0, y: 0.0 }];
        for i in 1..=20 {
            let x = i as f64 * 10.0;
            let y = if i % 2 == 0 { 10.0 } else { -10.0 };
            cmds.push(PathCommand::LineTo { x, y });
        }
        Element::Path(PathElem {
            d: cmds,
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            common: CommonProps::default(),
        })
    }

    fn make_curved_path() -> Element {
        // Many small curve segments that can be reduced by smoothing.
        let mut cmds = vec![PathCommand::MoveTo { x: 0.0, y: 0.0 }];
        for i in 0..10 {
            let base_x = i as f64 * 16.0;
            let sign = if i % 2 == 0 { 1.0 } else { -1.0 };
            cmds.push(PathCommand::CurveTo {
                x1: base_x + 4.0,
                y1: sign * 8.0,
                x2: base_x + 12.0,
                y2: sign * 8.0,
                x: base_x + 16.0,
                y: 0.0,
            });
        }
        Element::Path(PathElem {
            d: cmds,
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            common: CommonProps::default(),
        })
    }

    fn select_first(model: &mut Model) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        new_doc.selection = vec![ElementSelection::all(vec![0, 0])];
        model.set_document(new_doc);
    }

    #[test]
    fn smooth_reduces_commands_on_zigzag() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_zigzag_path());
        select_first(&mut model);

        let before = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };
        assert_eq!(before, 21); // 1 MoveTo + 20 LineTo

        let mut tool = SmoothTool::new();
        // Smooth over the middle of the path (x=100, y=0, radius=100 covers most).
        tool.on_press(&mut model, 100.0, 0.0, false, false);
        tool.on_release(&mut model, 100.0, 0.0, false, false);

        let after = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };
        assert!(
            after < before,
            "smoothing should reduce commands: before={before}, after={after}"
        );
    }

    #[test]
    fn smooth_only_affects_selected_paths() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_zigzag_path());
        // Clear selection so the path is NOT selected.
        let mut doc = model.document().clone();
        doc.selection.clear();
        model.set_document(doc);

        let before = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };

        let mut tool = SmoothTool::new();
        tool.on_press(&mut model, 100.0, 0.0, false, false);
        tool.on_release(&mut model, 100.0, 0.0, false, false);

        let after = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };
        assert_eq!(before, after, "unselected path should not be modified");
    }

    #[test]
    fn smooth_preserves_path_outside_circle() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_zigzag_path());
        select_first(&mut model);

        let mut tool = SmoothTool::new();
        // Smooth only the left end (x=0), radius=100 covers roughly x=0..100.
        tool.on_press(&mut model, 0.0, 0.0, false, false);
        tool.on_release(&mut model, 0.0, 0.0, false, false);

        let path = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe,
            _ => panic!("expected path"),
        };

        // The last command should still reach x=200 (the original endpoint).
        let last = &path.d[path.d.len() - 1];
        let (lx, _ly) = cmd_endpoint(last);
        assert!(
            (lx - 200.0).abs() < 1.0,
            "endpoint should be preserved, got x={lx}"
        );
    }

    #[test]
    fn smooth_noop_when_no_path_under_cursor() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_zigzag_path());
        select_first(&mut model);

        let before = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };

        let mut tool = SmoothTool::new();
        // Smooth far away from the path.
        tool.on_press(&mut model, 500.0, 500.0, false, false);
        tool.on_release(&mut model, 500.0, 500.0, false, false);

        let after = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };
        assert_eq!(before, after, "path far from cursor should not be modified");
    }

    #[test]
    fn smooth_works_on_curves() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_curved_path());
        select_first(&mut model);

        let before = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };
        assert_eq!(before, 11); // 1 MoveTo + 10 CurveTo

        let mut tool = SmoothTool::new();
        tool.on_press(&mut model, 80.0, 0.0, false, false);
        tool.on_release(&mut model, 80.0, 0.0, false, false);

        let after = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };
        assert!(
            after < before,
            "smoothing curves should reduce commands: before={before}, after={after}"
        );
    }

    #[test]
    fn flatten_with_cmd_map_basic() {
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 10.0, y: 0.0 },
            PathCommand::LineTo { x: 20.0, y: 0.0 },
        ];
        let (pts, map) = flatten_with_cmd_map(&cmds);
        assert_eq!(pts.len(), 3);
        assert_eq!(map, vec![0, 1, 2]);
    }

    #[test]
    fn flatten_with_cmd_map_curve() {
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::CurveTo {
                x1: 10.0, y1: 20.0,
                x2: 30.0, y2: 20.0,
                x: 40.0, y: 0.0,
            },
        ];
        let (pts, map) = flatten_with_cmd_map(&cmds);
        // 1 (MoveTo) + 20 (CurveTo with FLATTEN_STEPS=20) = 21
        assert_eq!(pts.len(), 21);
        assert_eq!(map[0], 0); // MoveTo
        for i in 1..21 {
            assert_eq!(map[i], 1); // All from CurveTo
        }
    }

    #[test]
    fn smoothing_state_transitions() {
        let mut tool = SmoothTool::new();
        let mut model = Model::default();
        assert!(!tool.smoothing);
        tool.on_press(&mut model, 0.0, 0.0, false, false);
        assert!(tool.smoothing);
        tool.on_release(&mut model, 0.0, 0.0, false, false);
        assert!(!tool.smoothing);
    }

    #[test]
    fn smooth_produces_curve_commands() {
        // Smoothing a zigzag of LineTo commands should produce CurveTo commands.
        let mut model = Model::default();
        Controller::add_element(&mut model, make_zigzag_path());
        select_first(&mut model);

        let mut tool = SmoothTool::new();
        tool.on_press(&mut model, 100.0, 0.0, false, false);
        tool.on_release(&mut model, 100.0, 0.0, false, false);

        let path = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe,
            _ => panic!("expected path"),
        };
        let has_curve = path.d.iter().any(|c| matches!(c, PathCommand::CurveTo { .. }));
        assert!(has_curve, "smoothed path should contain CurveTo commands");
    }

    #[test]
    fn smooth_preserves_stroke_and_fill() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_zigzag_path());
        select_first(&mut model);

        let (stroke_before, fill_before) = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => (pe.stroke, pe.fill),
            _ => panic!("expected path"),
        };

        let mut tool = SmoothTool::new();
        tool.on_press(&mut model, 100.0, 0.0, false, false);
        tool.on_release(&mut model, 100.0, 0.0, false, false);

        let (stroke_after, fill_after) = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => (pe.stroke, pe.fill),
            _ => panic!("expected path"),
        };
        assert_eq!(stroke_before, stroke_after, "stroke should be preserved");
        assert_eq!(fill_before, fill_after, "fill should be preserved");
    }

    #[test]
    fn smooth_locked_path_not_modified() {
        let mut model = Model::default();
        let mut path = make_zigzag_path();
        path.common_mut().locked = true;
        Controller::add_element(&mut model, path);
        select_first(&mut model);

        let before = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };

        let mut tool = SmoothTool::new();
        tool.on_press(&mut model, 100.0, 0.0, false, false);
        tool.on_release(&mut model, 100.0, 0.0, false, false);

        let after = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };
        assert_eq!(before, after, "locked path should not be modified");
    }

    #[test]
    fn smooth_cumulative_effect() {
        // Smoothing the same region twice should reduce commands further
        // (or at least not increase them).
        let mut model = Model::default();
        Controller::add_element(&mut model, make_zigzag_path());
        select_first(&mut model);

        let mut tool = SmoothTool::new();
        tool.on_press(&mut model, 100.0, 0.0, false, false);
        tool.on_release(&mut model, 100.0, 0.0, false, false);

        let after_first = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };

        // Re-select (selection may have been lost if the path was replaced).
        select_first(&mut model);

        tool.on_press(&mut model, 100.0, 0.0, false, false);
        tool.on_release(&mut model, 100.0, 0.0, false, false);

        let after_second = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };
        assert!(
            after_second <= after_first,
            "second smooth pass should not increase commands: first={after_first}, second={after_second}"
        );
    }

    #[test]
    fn smooth_move_without_press_is_noop() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_zigzag_path());
        select_first(&mut model);

        let before = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };

        let mut tool = SmoothTool::new();
        tool.on_move(&mut model, 100.0, 0.0, false, false, true);

        let after = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };
        assert_eq!(before, after, "move without press should not modify path");
    }

    #[test]
    fn smooth_release_without_press_is_noop() {
        let mut tool = SmoothTool::new();
        let mut model = Model::default();
        Controller::add_element(&mut model, make_zigzag_path());
        select_first(&mut model);

        let before = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };

        tool.on_release(&mut model, 100.0, 0.0, false, false);

        let after = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };
        assert_eq!(before, after, "release without press should not modify path");
    }

    #[test]
    fn smooth_preserves_start_point() {
        // Create a long path where the start is far from the smooth center.
        let mut cmds = vec![PathCommand::MoveTo { x: 0.0, y: 0.0 }];
        for i in 1..=40 {
            let x = i as f64 * 10.0;
            let y = if i % 2 == 0 { 10.0 } else { -10.0 };
            cmds.push(PathCommand::LineTo { x, y });
        }
        let path = Element::Path(PathElem {
            d: cmds,
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            common: CommonProps::default(),
        });

        let mut model = Model::default();
        Controller::add_element(&mut model, path);
        select_first(&mut model);

        let mut tool = SmoothTool::new();
        // Smooth the far end (x=300), well beyond the circle's reach to x=0.
        tool.on_press(&mut model, 300.0, 0.0, false, false);
        tool.on_release(&mut model, 300.0, 0.0, false, false);

        let path = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe,
            _ => panic!("expected path"),
        };

        // First command should still be MoveTo at (0,0).
        if let PathCommand::MoveTo { x, y } = &path.d[0] {
            assert_eq!(*x, 0.0, "start x should be preserved");
            assert_eq!(*y, 0.0, "start y should be preserved");
        } else {
            panic!("first command should be MoveTo");
        }
    }

    #[test]
    fn smooth_non_path_element_ignored() {
        // Add a rect element, select it, and try to smooth — should be a no-op.
        let mut model = Model::default();
        let rect = crate::geometry::element::Element::Rect(crate::geometry::element::RectElem {
            x: 10.0, y: 10.0, width: 50.0, height: 50.0,
            rx: 0.0, ry: 0.0,
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            common: CommonProps::default(),
        });
        Controller::add_element(&mut model, rect);
        // Element is auto-selected by add_element.

        let mut tool = SmoothTool::new();
        tool.on_press(&mut model, 35.0, 35.0, false, false);
        tool.on_release(&mut model, 35.0, 35.0, false, false);

        // Rect should still be there, unchanged.
        let elem = model.document().get_element(&vec![0, 0]).unwrap();
        assert!(matches!(elem, Element::Rect(_)), "rect should remain a rect");
    }

    #[test]
    fn smooth_last_pos_always_updated() {
        let mut tool = SmoothTool::new();
        let mut model = Model::default();

        // Move without press should still update last_pos.
        tool.on_move(&mut model, 42.0, 73.0, false, false, false);
        assert_eq!(tool.last_pos, (42.0, 73.0));

        // Press should update last_pos.
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        assert_eq!(tool.last_pos, (10.0, 20.0));
    }

    #[test]
    fn flatten_with_cmd_map_quad() {
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::QuadTo {
                x1: 20.0, y1: 40.0,
                x: 40.0, y: 0.0,
            },
        ];
        let (pts, map) = flatten_with_cmd_map(&cmds);
        // 1 (MoveTo) + 20 (QuadTo with FLATTEN_STEPS=20) = 21
        assert_eq!(pts.len(), 21);
        assert_eq!(map[0], 0);
        for i in 1..21 {
            assert_eq!(map[i], 1);
        }
        // Last point should be the endpoint.
        let last = pts.last().unwrap();
        assert!((last.0 - 40.0).abs() < 0.01);
        assert!((last.1 - 0.0).abs() < 0.01);
    }

    #[test]
    fn flatten_with_cmd_map_mixed() {
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 10.0, y: 0.0 },
            PathCommand::CurveTo {
                x1: 15.0, y1: 10.0,
                x2: 25.0, y2: 10.0,
                x: 30.0, y: 0.0,
            },
            PathCommand::LineTo { x: 40.0, y: 0.0 },
        ];
        let (pts, map) = flatten_with_cmd_map(&cmds);
        // 1 (MoveTo) + 1 (LineTo) + 20 (CurveTo) + 1 (LineTo) = 23
        assert_eq!(pts.len(), 23);
        assert_eq!(map[0], 0); // MoveTo
        assert_eq!(map[1], 1); // LineTo
        assert_eq!(map[2], 2); // CurveTo first step
        assert_eq!(map[21], 2); // CurveTo last step
        assert_eq!(map[22], 3); // LineTo
    }

    #[test]
    fn cmd_endpoint_variants() {
        assert_eq!(cmd_endpoint(&PathCommand::MoveTo { x: 1.0, y: 2.0 }), (1.0, 2.0));
        assert_eq!(cmd_endpoint(&PathCommand::LineTo { x: 3.0, y: 4.0 }), (3.0, 4.0));
        assert_eq!(
            cmd_endpoint(&PathCommand::CurveTo {
                x1: 0.0, y1: 0.0, x2: 0.0, y2: 0.0, x: 5.0, y: 6.0
            }),
            (5.0, 6.0)
        );
        assert_eq!(
            cmd_endpoint(&PathCommand::QuadTo {
                x1: 0.0, y1: 0.0, x: 7.0, y: 8.0
            }),
            (7.0, 8.0)
        );
    }

    #[test]
    fn smooth_drag_across_path() {
        // Simulate a drag (press + multiple moves + release).
        let mut model = Model::default();
        Controller::add_element(&mut model, make_zigzag_path());
        select_first(&mut model);

        let before = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };

        let mut tool = SmoothTool::new();
        tool.on_press(&mut model, 50.0, 0.0, false, false);
        // Need to re-select since smooth_at may replace the element.
        select_first(&mut model);
        tool.on_move(&mut model, 100.0, 0.0, false, false, true);
        select_first(&mut model);
        tool.on_move(&mut model, 150.0, 0.0, false, false, true);
        tool.on_release(&mut model, 150.0, 0.0, false, false);

        let after = match model.document().get_element(&vec![0, 0]).unwrap() {
            Element::Path(pe) => pe.d.len(),
            _ => panic!("expected path"),
        };
        assert!(
            after < before,
            "dragging smooth tool should reduce commands: before={before}, after={after}"
        );
    }
}
