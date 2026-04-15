//! Variable-width stroke rendering via offset paths.
//!
//! Flattens a path to a polyline, computes normals at each sample point,
//! evaluates the width profile, and builds a filled polygon representing
//! the stroke outline.

use web_sys::CanvasRenderingContext2d;
use crate::geometry::element::{
    PathCommand, StrokeWidthPoint, LineCap, flatten_path_commands,
};
use crate::geometry::measure::arc_lengths;

/// A sampled point along a path with position, unit normal, and path offset.
struct PathSample {
    x: f64,
    y: f64,
    nx: f64, // unit normal x (perpendicular to tangent, pointing left)
    ny: f64, // unit normal y
    t: f64,  // fractional offset along path [0, 1]
}

/// Sample a path at regular intervals, computing position and unit normal.
fn sample_path_with_normals(cmds: &[PathCommand]) -> Vec<PathSample> {
    let pts = flatten_path_commands(cmds);
    if pts.len() < 2 {
        return vec![];
    }
    let lengths = arc_lengths(&pts);
    let total = *lengths.last().unwrap();
    if total == 0.0 {
        return vec![];
    }

    let mut samples = Vec::with_capacity(pts.len());
    for i in 0..pts.len() {
        let t = lengths[i] / total;
        // Compute tangent from surrounding points
        let (dx, dy) = if i == 0 {
            (pts[1].0 - pts[0].0, pts[1].1 - pts[0].1)
        } else if i == pts.len() - 1 {
            (pts[i].0 - pts[i - 1].0, pts[i].1 - pts[i - 1].1)
        } else {
            (pts[i + 1].0 - pts[i - 1].0, pts[i + 1].1 - pts[i - 1].1)
        };
        let len = (dx * dx + dy * dy).sqrt();
        let (nx, ny) = if len > 1e-10 {
            // Normal = rotate tangent 90° CCW
            (-dy / len, dx / len)
        } else {
            (0.0, 1.0)
        };
        samples.push(PathSample {
            x: pts[i].0,
            y: pts[i].1,
            nx, ny, t,
        });
    }
    samples
}

/// Sample a line segment with normals at regular intervals.
fn sample_line_with_normals(x1: f64, y1: f64, x2: f64, y2: f64) -> Vec<PathSample> {
    let dx = x2 - x1;
    let dy = y2 - y1;
    let len = (dx * dx + dy * dy).sqrt();
    if len < 1e-10 {
        return vec![];
    }
    let nx = -dy / len;
    let ny = dx / len;
    // Sample at enough points to capture the width profile shape
    let num_samples = 32usize;
    let mut samples = Vec::with_capacity(num_samples + 1);
    for i in 0..=num_samples {
        let t = i as f64 / num_samples as f64;
        samples.push(PathSample {
            x: x1 + dx * t,
            y: y1 + dy * t,
            nx, ny, t,
        });
    }
    samples
}

/// Smoothstep: cubic ease-in-out for smooth width transitions.
fn smoothstep(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Evaluate width at offset t by smoothly interpolating width control points.
/// Uses smoothstep for each segment to avoid sharp kinks at control points.
fn evaluate_width_at(points: &[StrokeWidthPoint], t: f64) -> (f64, f64) {
    if points.is_empty() {
        return (0.0, 0.0);
    }
    if points.len() == 1 {
        return (points[0].width_left, points[0].width_right);
    }
    if t <= points[0].t {
        return (points[0].width_left, points[0].width_right);
    }
    if t >= points.last().unwrap().t {
        let last = points.last().unwrap();
        return (last.width_left, last.width_right);
    }
    for i in 1..points.len() {
        if t <= points[i].t {
            let dt = points[i].t - points[i - 1].t;
            let frac = if dt > 0.0 { (t - points[i - 1].t) / dt } else { 0.0 };
            let s = smoothstep(frac);
            let wl = points[i - 1].width_left + s * (points[i].width_left - points[i - 1].width_left);
            let wr = points[i - 1].width_right + s * (points[i].width_right - points[i - 1].width_right);
            return (wl, wr);
        }
    }
    let last = points.last().unwrap();
    (last.width_left, last.width_right)
}

/// Render a variable-width stroke for a path element.
pub fn render_variable_width_path(
    ctx: &CanvasRenderingContext2d,
    cmds: &[PathCommand],
    width_points: &[StrokeWidthPoint],
    stroke_color: &str,
    linecap: LineCap,
) {
    let samples = sample_path_with_normals(cmds);
    render_from_samples(ctx, &samples, width_points, stroke_color, linecap);
}

/// Render a variable-width stroke for a line element.
pub fn render_variable_width_line(
    ctx: &CanvasRenderingContext2d,
    x1: f64, y1: f64, x2: f64, y2: f64,
    width_points: &[StrokeWidthPoint],
    stroke_color: &str,
    linecap: LineCap,
) {
    let samples = sample_line_with_normals(x1, y1, x2, y2);
    render_from_samples(ctx, &samples, width_points, stroke_color, linecap);
}

fn render_from_samples(
    ctx: &CanvasRenderingContext2d,
    samples: &[PathSample],
    width_points: &[StrokeWidthPoint],
    stroke_color: &str,
    linecap: LineCap,
) {
    if samples.len() < 2 {
        return;
    }

    // Build left and right offset points
    let mut left: Vec<(f64, f64)> = Vec::with_capacity(samples.len());
    let mut right: Vec<(f64, f64)> = Vec::with_capacity(samples.len());

    for s in samples {
        let (wl, wr) = evaluate_width_at(width_points, s.t);
        left.push((s.x + s.nx * wl, s.y + s.ny * wl));
        right.push((s.x - s.nx * wr, s.y - s.ny * wr));
    }

    let (wl0, wr0) = evaluate_width_at(width_points, 0.0);
    let (wln, wrn) = evaluate_width_at(width_points, 1.0);

    ctx.begin_path();

    // Start cap
    let s0 = &samples[0];
    match linecap {
        LineCap::Round if wl0 + wr0 > 0.1 => {
            let r = (wl0 + wr0) / 2.0;
            let tangent_angle = s0.ny.atan2(-s0.nx);
            ctx.move_to(right[0].0, right[0].1);
            ctx.arc_with_anticlockwise(
                s0.x, s0.y, r,
                tangent_angle + std::f64::consts::FRAC_PI_2,
                tangent_angle - std::f64::consts::FRAC_PI_2,
                true,
            ).ok();
        }
        LineCap::Square if wl0 + wr0 > 0.1 => {
            let ext = (wl0 + wr0) / 2.0;
            let bx = -s0.ny;
            let by = s0.nx;
            ctx.move_to(right[0].0 + bx * ext, right[0].1 + by * ext);
            ctx.line_to(left[0].0 + bx * ext, left[0].1 + by * ext);
        }
        _ => {
            ctx.move_to(left[0].0, left[0].1);
        }
    }

    // Left edge forward
    for &(x, y) in &left {
        ctx.line_to(x, y);
    }

    // End cap
    let sn = samples.last().unwrap();
    match linecap {
        LineCap::Round if wln + wrn > 0.1 => {
            let r = (wln + wrn) / 2.0;
            let tangent_angle = sn.ny.atan2(-sn.nx);
            ctx.arc_with_anticlockwise(
                sn.x, sn.y, r,
                tangent_angle - std::f64::consts::FRAC_PI_2,
                tangent_angle + std::f64::consts::FRAC_PI_2,
                true,
            ).ok();
        }
        LineCap::Square if wln + wrn > 0.1 => {
            let ext = (wln + wrn) / 2.0;
            let fx = sn.ny;
            let fy = -sn.nx;
            let ll = left.last().unwrap();
            let rl = right.last().unwrap();
            ctx.line_to(ll.0 + fx * ext, ll.1 + fy * ext);
            ctx.line_to(rl.0 + fx * ext, rl.1 + fy * ext);
        }
        _ => {}
    }

    // Right edge reversed
    for &(x, y) in right.iter().rev() {
        ctx.line_to(x, y);
    }

    ctx.close_path();
    ctx.set_fill_style_str(stroke_color);
    ctx.fill();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn evaluate_width_uniform() {
        let pts = vec![
            StrokeWidthPoint { t: 0.0, width_left: 5.0, width_right: 5.0 },
            StrokeWidthPoint { t: 1.0, width_left: 5.0, width_right: 5.0 },
        ];
        assert_eq!(evaluate_width_at(&pts, 0.0), (5.0, 5.0));
        assert_eq!(evaluate_width_at(&pts, 0.5), (5.0, 5.0));
        assert_eq!(evaluate_width_at(&pts, 1.0), (5.0, 5.0));
    }

    #[test]
    fn evaluate_width_taper() {
        let pts = vec![
            StrokeWidthPoint { t: 0.0, width_left: 0.0, width_right: 0.0 },
            StrokeWidthPoint { t: 1.0, width_left: 10.0, width_right: 10.0 },
        ];
        let (wl, wr) = evaluate_width_at(&pts, 0.5);
        assert!((wl - 5.0).abs() < 1e-10);
        assert!((wr - 5.0).abs() < 1e-10);
    }

    #[test]
    fn evaluate_width_three_points() {
        let pts = vec![
            StrokeWidthPoint { t: 0.0, width_left: 0.0, width_right: 0.0 },
            StrokeWidthPoint { t: 0.5, width_left: 10.0, width_right: 10.0 },
            StrokeWidthPoint { t: 1.0, width_left: 0.0, width_right: 0.0 },
        ];
        let (wl, _) = evaluate_width_at(&pts, 0.25);
        assert!((wl - 5.0).abs() < 1e-10);
        let (wl, _) = evaluate_width_at(&pts, 0.75);
        assert!((wl - 5.0).abs() < 1e-10);
    }

    #[test]
    fn profile_to_width_points_uniform() {
        let pts = crate::geometry::element::profile_to_width_points("uniform", 10.0, false);
        assert!(pts.is_empty());
    }

    #[test]
    fn profile_to_width_points_taper_both() {
        let pts = crate::geometry::element::profile_to_width_points("taper_both", 10.0, false);
        assert_eq!(pts.len(), 3);
        assert_eq!(pts[0].width_left, 0.0);
        assert_eq!(pts[1].width_left, 5.0);
        assert_eq!(pts[2].width_left, 0.0);
    }

    #[test]
    fn profile_flipped() {
        let pts = crate::geometry::element::profile_to_width_points("taper_start", 10.0, false);
        let flipped = crate::geometry::element::profile_to_width_points("taper_start", 10.0, true);
        // Flipped taper_start should look like taper_end
        assert_eq!(flipped[0].width_left, pts.last().unwrap().width_left);
        assert_eq!(flipped.last().unwrap().width_left, pts[0].width_left);
    }
}
