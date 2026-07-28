//! Variable-width outline of a path stroked with a Calligraphic
//! brush. Faithful port of jas_flask/static/js/engine/geometry.mjs
//! `calligraphicOutline`. Produces a closed polygon as a list of
//! (x, y) points; callers fill it on the Canvas2D context to render
//! the brushed stroke.
//!
//! Brush parameters (BRUSHES.md §Brush types > Calligraphic):
//!   angle     - degrees, screen-fixed orientation of the oval major axis
//!   roundness - percent, 100 = circular, < 100 = elongated perpendicular to angle
//!   size      - pt, major-axis length
//!
//! Per-point offset distance perpendicular to the path tangent:
//!   φ = θ_brush − (θ_path + π/2)
//!   d(φ) = √((a/2 · cos φ)² + (b/2 · sin φ)²)
//! where a = brush.size, b = brush.size · brush.roundness / 100.
//!
//! Phase 1: fixed variation only. Multi-subpath paths render the
//! first subpath only.

use crate::geometry::element::PathCommand;

#[derive(Debug, Clone, Copy)]
pub struct CalligraphicBrush {
    pub angle: f64,     // degrees, screen-fixed
    pub roundness: f64, // 0..=100
    pub size: f64,      // pt
}

/// Compute the variable-width outline of `commands` stroked with a
/// Calligraphic brush. Returns a closed polygon's points (forward
/// along the left-offset, then back along the right-offset). Empty
/// vec for degenerate input (no segments, single MoveTo, zero-area
/// sweep).
pub fn calligraphic_outline(commands: &[PathCommand], brush: &CalligraphicBrush) -> Vec<(f64, f64)> {
    let samples = sample_stroke_path(commands);
    if samples.len() < 2 {
        return Vec::new();
    }

    let a = brush.size / 2.0;
    let b = (brush.size * (brush.roundness / 100.0)) / 2.0;
    let theta_brush = brush.angle.to_radians();

    let mut left = Vec::with_capacity(samples.len());
    let mut right = Vec::with_capacity(samples.len());
    for s in &samples {
        let phi = theta_brush - (s.tangent + std::f64::consts::FRAC_PI_2);
        let d = ((a * phi.cos()).powi(2) + (b * phi.sin()).powi(2)).sqrt();
        let nx = -s.tangent.sin();
        let ny = s.tangent.cos();
        left.push((s.x + nx * d, s.y + ny * d));
        right.push((s.x - nx * d, s.y - ny * d));
    }

    let mut out = Vec::with_capacity(left.len() + right.len());
    out.extend(left.iter().copied());
    for p in right.iter().rev() {
        out.push(*p);
    }
    out
}

#[derive(Debug, Clone, Copy)]
struct Sample {
    x: f64,
    y: f64,
    tangent: f64, // radians
}

const SAMPLE_INTERVAL_PT: f64 = 1.0;
const CUBIC_SAMPLES: u32 = 32;
const QUADRATIC_SAMPLES: u32 = 24;

fn sample_stroke_path(commands: &[PathCommand]) -> Vec<Sample> {
    let mut out = Vec::new();
    let mut cx = 0.0_f64;
    let mut cy = 0.0_f64;
    let mut sx = 0.0_f64;
    let mut sy = 0.0_f64;
    let mut started = false;
    // S-4's guard, and it cannot be `out.is_empty()` the way the art
    // flattener's is: `out` here holds SAMPLES, which a bare MoveTo does not
    // emit, so an empty accumulator does not mean "no current point". This
    // flag is exactly "a current point has been established", which is what
    // `flatten_path_commands`' `!pts.is_empty()` means in a walk whose
    // accumulator holds vertices.
    let mut has_current = false;

    for cmd in commands {
        match cmd {
            PathCommand::MoveTo { x, y } => {
                if started {
                    return out;
                }
                cx = *x;
                cy = *y;
                sx = cx;
                sy = cy;
                has_current = true;
            }
            PathCommand::LineTo { x, y } => {
                sample_line(&mut out, cx, cy, *x, *y);
                cx = *x;
                cy = *y;
                started = true;
                has_current = true;
            }
            PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                sample_cubic(&mut out, cx, cy, *x1, *y1, *x2, *y2, *x, *y);
                cx = *x;
                cy = *y;
                started = true;
                has_current = true;
            }
            PathCommand::QuadTo { x1, y1, x, y } => {
                sample_quadratic(&mut out, cx, cy, *x1, *y1, *x, *y);
                cx = *x;
                cy = *y;
                started = true;
                has_current = true;
            }
            PathCommand::ClosePath => {
                // S-4: a LEADING ClosePath is a no-op (JYH, fleet council
                // 2026-07-27). This is the FOURTH first-subpath walker in the
                // tree and the second one that got the ruling wrong: without
                // the guard it returned the still-empty sample list, so the
                // CALLIGRAPHIC brush -- the Phase-1 default -- drew nothing at
                // all on a path whose `d` begins with Z. Wrong identically in
                // both ports, so no equivalence gate could see it; gated now
                // by test_fixtures/algorithms/calligraphic_outline.json.
                //
                // NOT `cx == sx && cy == sy`: at a MoveTo-then-Z degenerate
                // subpath those are equal too, and there the close is REAL --
                // it ends the subpath instead of letting the walk run on into
                // the next one.
                if !has_current {
                    continue;
                }
                if cx != sx || cy != sy {
                    sample_line(&mut out, cx, cy, sx, sy);
                }
                return out;
            }
            // Smooth/short variants — flatten via the helper if needed.
            // Treat conservatively: convert smooth cubic / quadratic to
            // their explicit forms by reusing the previous control
            // reflection. For Phase 1, the seed Pencil/Paintbrush tools
            // emit only M, C, Z so this branch is unreached in
            // practice.
            _ => {
                // Unsupported in Phase 1; bail.
                return out;
            }
        }
    }
    out
}

fn sample_line(out: &mut Vec<Sample>, x0: f64, y0: f64, x1: f64, y1: f64) {
    let len = (x1 - x0).hypot(y1 - y0);
    if len == 0.0 {
        return;
    }
    let tangent = (y1 - y0).atan2(x1 - x0);
    let n = ((len / SAMPLE_INTERVAL_PT).ceil() as u32).max(1);
    let start_i = if out.is_empty() { 0 } else { 1 };
    for i in start_i..=n {
        let t = i as f64 / n as f64;
        out.push(Sample {
            x: x0 + (x1 - x0) * t,
            y: y0 + (y1 - y0) * t,
            tangent,
        });
    }
}

fn sample_cubic(
    out: &mut Vec<Sample>,
    x0: f64, y0: f64, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64,
) {
    let start_i = if out.is_empty() { 0 } else { 1 };
    for i in start_i..=CUBIC_SAMPLES {
        let t = i as f64 / CUBIC_SAMPLES as f64;
        let u = 1.0 - t;
        let x = u*u*u * x0 + 3.0*u*u*t * x1 + 3.0*u*t*t * x2 + t*t*t * x3;
        let y = u*u*u * y0 + 3.0*u*u*t * y1 + 3.0*u*t*t * y2 + t*t*t * y3;
        let dx = 3.0*u*u * (x1 - x0) + 6.0*u*t * (x2 - x1) + 3.0*t*t * (x3 - x2);
        let dy = 3.0*u*u * (y1 - y0) + 6.0*u*t * (y2 - y1) + 3.0*t*t * (y3 - y2);
        let tangent = if dx == 0.0 && dy == 0.0 {
            (y3 - y0).atan2(x3 - x0)
        } else {
            dy.atan2(dx)
        };
        out.push(Sample { x, y, tangent });
    }
}

fn sample_quadratic(
    out: &mut Vec<Sample>,
    x0: f64, y0: f64, x1: f64, y1: f64, x2: f64, y2: f64,
) {
    let start_i = if out.is_empty() { 0 } else { 1 };
    for i in start_i..=QUADRATIC_SAMPLES {
        let t = i as f64 / QUADRATIC_SAMPLES as f64;
        let u = 1.0 - t;
        let x = u*u * x0 + 2.0*u*t * x1 + t*t * x2;
        let y = u*u * y0 + 2.0*u*t * y1 + t*t * y2;
        let dx = 2.0*u * (x1 - x0) + 2.0*t * (x2 - x1);
        let dy = 2.0*u * (y1 - y0) + 2.0*t * (y2 - y1);
        let tangent = if dx == 0.0 && dy == 0.0 {
            (y2 - y0).atan2(x2 - x0)
        } else {
            dy.atan2(dx)
        };
        out.push(Sample { x, y, tangent });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn move_to(x: f64, y: f64) -> PathCommand { PathCommand::MoveTo { x, y } }
    fn line_to(x: f64, y: f64) -> PathCommand { PathCommand::LineTo { x, y } }

    #[test]
    fn empty_input_returns_empty() {
        let brush = CalligraphicBrush { angle: 0.0, roundness: 100.0, size: 4.0 };
        assert!(calligraphic_outline(&[], &brush).is_empty());
    }

    #[test]
    fn single_move_returns_empty() {
        let brush = CalligraphicBrush { angle: 0.0, roundness: 100.0, size: 4.0 };
        let cmds = vec![move_to(0.0, 0.0)];
        assert!(calligraphic_outline(&cmds, &brush).is_empty());
    }

    /// `if len == 0.0` is FALSE for a NaN length, so a NaN coordinate reaches
    /// the sample-count cast. `(nan / SAMPLE_INTERVAL_PT).ceil() as u32` is 0
    /// and `.max(1)` lifts it to one interval: two samples, a four-point
    /// polygon. The coordinates themselves are NaN, so the COUNT is what the
    /// two ports agree on and all this asserts. JasSwift's twin is
    /// `R9CallSitePinTests.calligraphicOutlineSurvivesANaNCoordinate`, where
    /// the same expression was a precondition failure before risk R9.
    #[test]
    fn nan_coordinate_yields_two_samples() {
        let brush = CalligraphicBrush { angle: 0.0, roundness: 100.0, size: 4.0 };
        let cmds = vec![move_to(0.0, 0.0), line_to(f64::NAN, 0.0)];
        assert_eq!(calligraphic_outline(&cmds, &brush).len(), 4);
    }

    #[test]
    fn horizontal_line_with_circular_brush() {
        // Half-width perpendicular to a horizontal line with a circular
        // tip of size 4 is 2; ys should be ±2 throughout.
        let brush = CalligraphicBrush { angle: 0.0, roundness: 100.0, size: 4.0 };
        let cmds = vec![move_to(0.0, 0.0), line_to(10.0, 0.0)];
        let pts = calligraphic_outline(&cmds, &brush);
        for &(_, y) in &pts {
            assert!((y.abs() - 2.0).abs() < 1e-3, "y={}", y);
        }
        let xs: Vec<f64> = pts.iter().map(|p| p.0).collect();
        let min_x = xs.iter().cloned().fold(f64::INFINITY, f64::min);
        let max_x = xs.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        assert!((min_x - 0.0).abs() < 1e-9);
        assert!((max_x - 10.0).abs() < 1e-9);
    }

    #[test]
    fn brush_angle_parallel_uses_minor_axis() {
        // Horizontal path, brush angle 0° (major horizontal),
        // roundness 50% → effective half-width = b/2 = 1.
        let brush = CalligraphicBrush { angle: 0.0, roundness: 50.0, size: 4.0 };
        let cmds = vec![move_to(0.0, 0.0), line_to(10.0, 0.0)];
        let pts = calligraphic_outline(&cmds, &brush);
        for &(_, y) in &pts {
            assert!((y.abs() - 1.0).abs() < 1e-3, "y={}", y);
        }
    }

    #[test]
    fn brush_angle_perpendicular_uses_major_axis() {
        let brush = CalligraphicBrush { angle: 90.0, roundness: 50.0, size: 4.0 };
        let cmds = vec![move_to(0.0, 0.0), line_to(10.0, 0.0)];
        let pts = calligraphic_outline(&cmds, &brush);
        for &(_, y) in &pts {
            assert!((y.abs() - 2.0).abs() < 1e-3, "y={}", y);
        }
    }

    #[test]
    fn circular_brush_independent_of_path_direction() {
        // 45° path, circular tip; perpendicular distance from each
        // outline point to line x = y is half-width = 2.
        let brush = CalligraphicBrush { angle: 30.0, roundness: 100.0, size: 4.0 };
        let cmds = vec![move_to(0.0, 0.0), line_to(10.0, 10.0)];
        let pts = calligraphic_outline(&cmds, &brush);
        for &(x, y) in &pts {
            let dist = (x - y).abs() / std::f64::consts::SQRT_2;
            assert!((dist - 2.0).abs() < 1e-3, "dist={}", dist);
        }
    }

    #[test]
    fn cubic_curve_sampled_and_outlined() {
        let brush = CalligraphicBrush { angle: 0.0, roundness: 100.0, size: 4.0 };
        let cmds = vec![
            move_to(0.0, 0.0),
            PathCommand::CurveTo { x1: 3.0, y1: 5.0, x2: 7.0, y2: 5.0, x: 10.0, y: 0.0 },
        ];
        let pts = calligraphic_outline(&cmds, &brush);
        assert!(pts.len() > 50, "expected >50 outline points, got {}", pts.len());
        let max_y = pts.iter().map(|p| p.1).fold(f64::NEG_INFINITY, f64::max);
        let min_y = pts.iter().map(|p| p.1).fold(f64::INFINITY, f64::min);
        assert!(max_y > 3.0, "outline should reach above curve");
        assert!(min_y < -0.5, "outline should dip below path baseline");
    }

    // ── S-4: a leading ClosePath is a no-op ──────────────────────────────
    //
    // Ruled by JYH at the fleet council, 2026-07-27. `sample_stroke_path` is
    // the FOURTH first-subpath walker in the tree and the SECOND one that got
    // the ruling wrong (the art flattener was the first). The consequence here
    // is louder: Calligraphic is the Phase-1 DEFAULT brush, so a path whose `d`
    // begins with Z stroked nothing at all. Cross-language pin:
    // test_fixtures/algorithms/calligraphic_outline.json.

    /// THE CONSEQUENCE, as an equality: a leading Z changes nothing.
    #[test]
    fn calligraphic_outline_ignores_a_leading_close() {
        let brush = CalligraphicBrush { angle: 30.0, roundness: 40.0, size: 6.0 };
        let with_z = calligraphic_outline(
            &[PathCommand::ClosePath, move_to(0.0, 0.0), line_to(4.0, 0.0)],
            &brush,
        );
        let without_z =
            calligraphic_outline(&[move_to(0.0, 0.0), line_to(4.0, 0.0)], &brush);
        assert_eq!(with_z, without_z, "a leading Z changed the outline");
        // MANDATORY GEOMETRY PAIRING: equality to a possibly-empty value proves
        // nothing, so say where the ribbon is. A 4pt horizontal line sampled at
        // 1pt gives 5 samples, so 10 outline points, and every one of them sits
        // at a constant offset from the baseline y = 0 (the brush angle is
        // fixed in screen space and the tangent never turns).
        assert_eq!(with_z.len(), 10, "5 samples -> 10 outline points");
        let off = with_z[0].1;
        assert!(off.abs() > 1.0, "the ribbon must have real width, got {off}");
        for (i, &(x, y)) in with_z.iter().enumerate() {
            assert!(
                (0.0..=4.0).contains(&x),
                "point {i} left the path's x span: {x}"
            );
            assert!(
                (y.abs() - off.abs()).abs() < 1e-9,
                "point {i} is not at the constant offset {off}: {y}"
            );
        }
    }

    /// SCOPE BOUNDARY, and why the guard is "a current point has been
    /// established" and NOT `cx == sx && cy == sy`: at `M(5,5) Z` those
    /// coordinates are equal exactly as at a leading close, but the close is
    /// REAL and ends the subpath. A guard on the coordinates would fall through
    /// and sample the SECOND subpath — this asserts it does not.
    #[test]
    fn calligraphic_moveto_then_immediate_close_does_not_sample_the_next_subpath() {
        let brush = CalligraphicBrush { angle: 30.0, roundness: 40.0, size: 6.0 };
        let pts = calligraphic_outline(
            &[
                move_to(5.0, 5.0),
                PathCommand::ClosePath,
                move_to(50.0, 50.0),
                line_to(54.0, 50.0),
            ],
            &brush,
        );
        assert!(
            pts.is_empty(),
            "a zero-length first subpath outlines to nothing; got {} points \
             starting at {:?} — the walk ran on into the second subpath",
            pts.len(),
            pts.first()
        );
    }
}
