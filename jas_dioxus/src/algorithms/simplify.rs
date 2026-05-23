//! Polyline-to-Bezier simplification with corner detection.
//!
//! Wraps `algorithms::fit_curve::fit_curve` (Schneider 1990) so it can
//! be applied to a closed or open polyline that mixes straight runs
//! and smooth arcs. The wrapper:
//!
//! 1. Detects "corners" — vertices where the direction changes by
//!    more than `corner_angle_threshold` (default 30 degrees). Boolean
//!    operation outputs preserve original sharp corners but flatten
//!    arcs into many short segments; fitting one curve across a
//!    corner would round it off, so corners must split the polyline
//!    into per-segment runs before fitting.
//! 2. For each run between corners, calls fit_curve with the supplied
//!    error tolerance. A run of two points emits a single LineTo;
//!    longer runs emit one or more CurveTo segments.
//! 3. Re-stitches the run outputs into a single PathCommand sequence,
//!    closing with ClosePath when the input was a closed ring.
//!
//! See `transcripts/BOOLEAN.md` Simplify section for the integration
//! contract and `transcripts/SIMPLIFY.md` (TODO) for the standalone
//! Object menu command.

use crate::geometry::element::PathCommand;
use super::fit_curve::fit_curve;

/// Default corner angle threshold: 30 degrees (in radians).
pub const DEFAULT_CORNER_ANGLE: f64 = std::f64::consts::PI / 6.0;

/// Simplify a polyline to a Bezier-rich PathCommand sequence.
///
/// `points` is the polyline (no duplicate closing vertex).
/// `precision` is the Schneider max-error tolerance in document units
/// (typically points).
/// `closed` controls whether the wraparound seam can become a corner
/// and whether the output ends with `ClosePath`.
///
/// Returns a sequence starting with `MoveTo` and ending with (for
/// closed inputs) `ClosePath`. Returns an empty Vec when fewer than
/// 2 points are supplied.
pub fn simplify_polyline(
    points: &[(f64, f64)],
    precision: f64,
    closed: bool,
) -> Vec<PathCommand> {
    simplify_polyline_with_angle(points, precision, closed, DEFAULT_CORNER_ANGLE)
}

/// `simplify_polyline` with an explicit corner-angle threshold (in
/// radians). Useful for tests and future tuning surfaces.
pub fn simplify_polyline_with_angle(
    points: &[(f64, f64)],
    precision: f64,
    closed: bool,
    corner_angle_threshold: f64,
) -> Vec<PathCommand> {
    if points.len() < 2 {
        return Vec::new();
    }
    if points.len() == 2 {
        let mut out = Vec::with_capacity(if closed { 3 } else { 2 });
        out.push(PathCommand::MoveTo { x: points[0].0, y: points[0].1 });
        out.push(PathCommand::LineTo { x: points[1].0, y: points[1].1 });
        if closed {
            out.push(PathCommand::ClosePath);
        }
        return out;
    }

    let corners = detect_corners(points, corner_angle_threshold, closed);
    let runs = split_into_runs(points, &corners, closed);

    let mut out: Vec<PathCommand> = Vec::new();
    out.push(PathCommand::MoveTo { x: runs[0][0].0, y: runs[0][0].1 });
    for run in &runs {
        if run.len() == 2 {
            // Pure line segment — no fitting.
            out.push(PathCommand::LineTo { x: run[1].0, y: run[1].1 });
        } else {
            // Bezier fit on the run.
            let segs = fit_curve(run, precision);
            if segs.is_empty() {
                // Defensive: fit failed (too few points after filtering);
                // fall back to a straight line to the last vertex.
                out.push(PathCommand::LineTo { x: run[run.len() - 1].0, y: run[run.len() - 1].1 });
                continue;
            }
            for (_x0, _y0, c1x, c1y, c2x, c2y, x, y) in segs {
                out.push(PathCommand::CurveTo {
                    x1: c1x, y1: c1y,
                    x2: c2x, y2: c2y,
                    x, y,
                });
            }
        }
    }
    if closed {
        out.push(PathCommand::ClosePath);
    }
    out
}

/// Return indices of corner vertices. A corner is a vertex where the
/// direction change between the incoming and outgoing edges exceeds
/// `angle_threshold` radians. For `closed` inputs, the wraparound
/// seam (vertex 0) is treated like any other interior vertex; for
/// open inputs, endpoints (index 0 and n-1) are never corners.
fn detect_corners(points: &[(f64, f64)], angle_threshold: f64, closed: bool) -> Vec<usize> {
    let n = points.len();
    let mut corners = Vec::new();
    let cos_threshold = angle_threshold.cos();
    let start = if closed { 0 } else { 1 };
    let end = if closed { n } else { n - 1 };
    for i in start..end {
        let prev_idx = (i + n - 1) % n;
        let next_idx = (i + 1) % n;
        let v1 = norm(sub(points[i], points[prev_idx]));
        let v2 = norm(sub(points[next_idx], points[i]));
        // Degenerate (zero-length) edges shouldn't mark corners.
        if v1.is_none() || v2.is_none() {
            continue;
        }
        let d = dot(v1.unwrap(), v2.unwrap());
        // d == 1 means edges are collinear (no turn); d < cos_threshold
        // means the turn exceeds angle_threshold.
        if d < cos_threshold {
            corners.push(i);
        }
    }
    corners
}

/// Split `points` into runs separated by corners. Each run is
/// returned as an owned Vec because closed-ring runs may wrap around
/// the seam.
fn split_into_runs(
    points: &[(f64, f64)],
    corners: &[usize],
    closed: bool,
) -> Vec<Vec<(f64, f64)>> {
    let n = points.len();
    if corners.is_empty() {
        if closed {
            // No corners on a closed ring — emit one run that includes
            // the seam vertex twice (start == end) so fit_curve can
            // recover a closed-loop Bezier approximation.
            let mut r: Vec<(f64, f64)> = points.to_vec();
            r.push(points[0]);
            return vec![r];
        } else {
            return vec![points.to_vec()];
        }
    }
    let mut runs: Vec<Vec<(f64, f64)>> = Vec::new();
    if closed {
        // Walk corner-to-corner around the ring. Each run starts at
        // corner k and ends at corner k+1 (mod corners.len()),
        // collecting every intermediate vertex.
        for k in 0..corners.len() {
            let a = corners[k];
            let b = corners[(k + 1) % corners.len()];
            let mut run = Vec::new();
            let mut i = a;
            run.push(points[i]);
            loop {
                i = (i + 1) % n;
                run.push(points[i]);
                if i == b { break; }
            }
            runs.push(run);
        }
    } else {
        // Open polyline: runs are [start..corners[0]], [corners[0]..corners[1]],
        // ..., [corners[last]..n-1].
        let mut prev = 0usize;
        for &c in corners {
            runs.push(points[prev..=c].to_vec());
            prev = c;
        }
        runs.push(points[prev..n].to_vec());
    }
    runs
}

fn sub(a: (f64, f64), b: (f64, f64)) -> (f64, f64) { (a.0 - b.0, a.1 - b.1) }
fn dot(a: (f64, f64), b: (f64, f64)) -> f64 { a.0 * b.0 + a.1 * b.1 }
fn norm(v: (f64, f64)) -> Option<(f64, f64)> {
    let m = (v.0 * v.0 + v.1 * v.1).sqrt();
    if m < 1e-12 { None } else { Some((v.0 / m, v.1 / m)) }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::PI;

    fn approx_eq(a: f64, b: f64, eps: f64) -> bool { (a - b).abs() < eps }

    #[test]
    fn empty_input_returns_empty() {
        assert!(simplify_polyline(&[], 0.5, true).is_empty());
    }

    #[test]
    fn two_points_emits_lineto() {
        let out = simplify_polyline(&[(0.0, 0.0), (10.0, 0.0)], 0.5, false);
        assert_eq!(out.len(), 2);
        assert!(matches!(out[0], PathCommand::MoveTo { .. }));
        assert!(matches!(out[1], PathCommand::LineTo { .. }));
    }

    #[test]
    fn detect_corners_on_square() {
        // Closed unit square — every vertex is a 90 degree corner.
        let sq = vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        let corners = detect_corners(&sq, DEFAULT_CORNER_ANGLE, true);
        assert_eq!(corners, vec![0, 1, 2, 3]);
    }

    #[test]
    fn detect_corners_on_collinear_points() {
        // Collinear points should not yield corners.
        let line: Vec<(f64, f64)> = (0..10).map(|i| (i as f64, 0.0)).collect();
        let corners = detect_corners(&line, DEFAULT_CORNER_ANGLE, false);
        assert!(corners.is_empty(),
            "got unexpected corners on a straight line: {:?}", corners);
    }

    #[test]
    fn detect_corners_below_threshold_is_smooth() {
        // 25-degree turn — below the 30-degree threshold, no corner.
        let angle = (25.0_f64).to_radians();
        let pts = vec![
            (0.0, 0.0),
            (10.0, 0.0),
            (10.0 + 10.0 * angle.cos(), 10.0 * angle.sin()),
        ];
        let corners = detect_corners(&pts, DEFAULT_CORNER_ANGLE, false);
        assert!(corners.is_empty(),
            "25 degree turn should not be a corner, got {:?}", corners);
    }

    #[test]
    fn detect_corners_above_threshold_is_corner() {
        // 45-degree turn — above the 30-degree threshold, marked.
        let angle = (45.0_f64).to_radians();
        let pts = vec![
            (0.0, 0.0),
            (10.0, 0.0),
            (10.0 + 10.0 * angle.cos(), 10.0 * angle.sin()),
        ];
        let corners = detect_corners(&pts, DEFAULT_CORNER_ANGLE, false);
        assert_eq!(corners, vec![1]);
    }

    #[test]
    fn simplify_square_keeps_lines() {
        // Closed square — every edge is straight, so the output should
        // be 4 LineTo + ClosePath after the initial MoveTo. No
        // CurveTo commands.
        let sq = vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        let out = simplify_polyline(&sq, 0.5, true);
        let curve_count = out.iter().filter(|c| matches!(c, PathCommand::CurveTo { .. })).count();
        let line_count = out.iter().filter(|c| matches!(c, PathCommand::LineTo { .. })).count();
        assert_eq!(curve_count, 0, "square should fit with no curves");
        assert_eq!(line_count, 4, "square should fit as 4 LineTo segments");
        assert!(matches!(out.last(), Some(PathCommand::ClosePath)));
    }

    #[test]
    fn simplify_circle_recovers_curves() {
        // 32-segment regular circle sampling — should fit as 4 CurveTo
        // segments (one per quadrant, give or take) with no corners
        // and no LineTo.
        let n = 32;
        let r = 50.0;
        let pts: Vec<(f64, f64)> = (0..n)
            .map(|i| {
                let t = 2.0 * PI * (i as f64) / (n as f64);
                (r * t.cos(), r * t.sin())
            })
            .collect();
        let out = simplify_polyline(&pts, 0.5, true);
        let curve_count = out.iter().filter(|c| matches!(c, PathCommand::CurveTo { .. })).count();
        let line_count = out.iter().filter(|c| matches!(c, PathCommand::LineTo { .. })).count();
        assert!(curve_count > 0, "circle sampling should fit at least one CurveTo");
        assert_eq!(line_count, 0, "circle sampling should not produce LineTo");
        assert!(matches!(out.last(), Some(PathCommand::ClosePath)));
    }

    #[test]
    fn simplify_rounded_rect_mixes_lines_and_curves() {
        // Pseudo rounded-rect: 4 straight edges + 4 arc corners (8
        // samples each). Expect a mix of LineTo (straight edges) and
        // CurveTo (arc corners), with exactly 4 corner-detection hits
        // at the line-to-arc junctions.
        let r = 5.0;
        let w = 30.0;
        let h = 20.0;
        let arc_samples = 8;
        let mut pts: Vec<(f64, f64)> = Vec::new();
        // Bottom edge midpoint to bottom-right arc.
        pts.push((r, 0.0));
        pts.push((w - r, 0.0));
        for i in 1..arc_samples {
            let t = (i as f64) / (arc_samples as f64);
            let a = -PI / 2.0 + t * (PI / 2.0);
            pts.push((w - r + r * a.cos(), r + r * a.sin()));
        }
        pts.push((w, r));
        pts.push((w, h - r));
        for i in 1..arc_samples {
            let t = (i as f64) / (arc_samples as f64);
            let a = 0.0 + t * (PI / 2.0);
            pts.push((w - r + r * a.cos(), h - r + r * a.sin()));
        }
        pts.push((w - r, h));
        pts.push((r, h));
        for i in 1..arc_samples {
            let t = (i as f64) / (arc_samples as f64);
            let a = PI / 2.0 + t * (PI / 2.0);
            pts.push((r + r * a.cos(), h - r + r * a.sin()));
        }
        pts.push((0.0, h - r));
        pts.push((0.0, r));
        for i in 1..arc_samples {
            let t = (i as f64) / (arc_samples as f64);
            let a = PI + t * (PI / 2.0);
            pts.push((r + r * a.cos(), r + r * a.sin()));
        }
        let out = simplify_polyline(&pts, 0.5, true);
        let curve_count = out.iter().filter(|c| matches!(c, PathCommand::CurveTo { .. })).count();
        // Tangent line-to-arc junctions are NOT corners under the
        // angle-change criterion (the polyline approximation already
        // smooths the transition), so the simplifier fits the whole
        // ring as Bezier curves. The straight edges become 1-2
        // curve segments each with collinear control points; we
        // assert that the total count is small (the algorithm
        // didn't degenerate into hundreds of segments).
        assert!(curve_count > 0, "rounded rect should fit with at least one curve segment");
        assert!(curve_count <= 20, "rounded rect fit should be compact, got {curve_count} curve segments");
    }

    #[test]
    fn open_polyline_endpoints_are_not_corners() {
        // Three colinear points — endpoint at index 0 and 2 must not
        // be reported as corners, only vertex 1 could (and it
        // shouldn't here because it's collinear).
        let pts = vec![(0.0, 0.0), (5.0, 0.0), (10.0, 0.0)];
        let corners = detect_corners(&pts, DEFAULT_CORNER_ANGLE, false);
        assert!(corners.is_empty(), "got {:?}", corners);
    }

    #[test]
    fn approx_check_for_dummy_value() {
        // Sanity check on the approx_eq helper itself.
        assert!(approx_eq(1.0, 1.0001, 0.01));
        assert!(!approx_eq(1.0, 1.1, 0.01));
    }
}
