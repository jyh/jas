//! Variable-width stroke rendering via offset paths.
//!
//! Flattens a path to a polyline, computes normals at each sample point,
//! evaluates the width profile, and builds a filled polygon representing
//! the stroke outline.
//!
//! # The GEOMETRY is separate from the RASTERISATION, and the split is the point
//!
//! Until 2026-08-01 this module existed only as `web_sys` drawing calls: the
//! outline was never a value, so no roundtrip verb could serialise it, no
//! cross-port comparison could see it, and `algorithms/mod.rs` gated the whole
//! file behind `web` for one import.
//!
//! Now `variable_width_outline_path` / `_line` return a [`StrokeOutline`] —
//! two rails and two caps, as numbers — and `flatten_outline` turns that into
//! the closed polygon the renderer fills. The three drawing functions keep the
//! `web` gate; everything above them is arithmetic that both active ports must
//! agree on, and the `offset_path` algorithm family gates it.
//!
//! **Why the cap is flattened HERE rather than handed to the platform.** The
//! previous code passed the arc to `CanvasRenderingContext2d::arc_with_
//! anticlockwise(.., true)` in Rust and to `CGMutablePath.addArc(..,
//! clockwise: true)` in Swift, and whether those two flags denote the same
//! sweep was an open question answered only by *reading* two vendors' prose.
//! They do denote the same sweep — measured, see `OffsetPathCapTests.swift`
//! and `docs/CHECKERS.md` — but the answer is not what makes this safe. What
//! makes it safe is that neither port asks its platform any more: both walk
//! the same [`CAP_ARC_STEPS`]-segment polyline out of the same arithmetic, so
//! the two rasterisers cannot disagree about a cap even in principle.

#[cfg(feature = "web")]
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

/// One end of a variable-width stroke, as VALUES rather than as a call.
///
/// Angles are ordinary `atan2` angles in DOCUMENT space: the point of a
/// [`StrokeCap::Round`] at angle `a` is `(cx + r*cos a, cy + r*sin a)`. No
/// platform is named and no platform flag is stored — `decreasing` says which
/// way the sweep runs in that arithmetic and nothing else.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum StrokeCap {
    /// SVG `butt`: the stroke ends on the rail, nothing is added.
    Butt,
    /// SVG `round`: a semicircle centred on the endpoint.
    Round {
        cx: f64,
        cy: f64,
        r: f64,
        /// Where the sweep starts.
        a0: f64,
        /// Where it ends.
        a1: f64,
        /// True when the sweep runs toward DECREASING angle.
        decreasing: bool,
    },
    /// SVG `square`: both rails extend `ext` along the unit vector
    /// `(ux, uy)` — backward at the start of the stroke, forward at its end.
    Square { ext: f64, ux: f64, uy: f64 },
}

/// A variable-width stroke's outline, before it is drawn.
#[derive(Debug, Clone, PartialEq)]
pub struct StrokeOutline {
    /// The left rail, in path order. Empty iff the stroke is degenerate.
    pub left: Vec<(f64, f64)>,
    /// The right rail, in path order (the polygon walks it backwards).
    pub right: Vec<(f64, f64)>,
    pub start_cap: StrokeCap,
    pub end_cap: StrokeCap,
}

/// Segments per cap semicircle when the renderer flattens one.
///
/// The chord error of an `n`-segment semicircle is `r * (1 - cos(pi/(2n)))`;
/// at 32 that is `r * 0.0012`, i.e. 0.006pt for a 10pt-wide stroke and 0.12pt
/// for a 200pt one. Both ports use this same number, and it travels on the
/// algorithm wire as `default_arc_steps` so it cannot drift between them.
pub const CAP_ARC_STEPS: usize = 32;

/// The outline of a variable-width stroke along a path element.
pub fn variable_width_outline_path(
    cmds: &[PathCommand],
    width_points: &[StrokeWidthPoint],
    linecap: LineCap,
) -> StrokeOutline {
    build_outline(&sample_path_with_normals(cmds), width_points, linecap)
}

/// The outline of a variable-width stroke along a line element.
pub fn variable_width_outline_line(
    x1: f64, y1: f64, x2: f64, y2: f64,
    width_points: &[StrokeWidthPoint],
    linecap: LineCap,
) -> StrokeOutline {
    build_outline(
        &sample_line_with_normals(x1, y1, x2, y2), width_points, linecap,
    )
}

fn build_outline(
    samples: &[PathSample],
    width_points: &[StrokeWidthPoint],
    linecap: LineCap,
) -> StrokeOutline {
    if samples.len() < 2 {
        return StrokeOutline {
            left: Vec::new(),
            right: Vec::new(),
            start_cap: StrokeCap::Butt,
            end_cap: StrokeCap::Butt,
        };
    }

    let mut left: Vec<(f64, f64)> = Vec::with_capacity(samples.len());
    let mut right: Vec<(f64, f64)> = Vec::with_capacity(samples.len());
    for s in samples {
        let (wl, wr) = evaluate_width_at(width_points, s.t);
        left.push((s.x + s.nx * wl, s.y + s.ny * wl));
        right.push((s.x - s.nx * wr, s.y - s.ny * wr));
    }

    let (wl0, wr0) = evaluate_width_at(width_points, 0.0);
    let (wln, wrn) = evaluate_width_at(width_points, 1.0);
    let s0 = &samples[0];
    let sn = samples.last().unwrap();

    // A cap narrower than 0.1pt across is not drawn at all: a taper profile
    // reaches zero width at the ends, and a zero-radius arc is a wart.
    let start_cap = match linecap {
        LineCap::Round if wl0 + wr0 > 0.1 => {
            let a = tangent_angle(s0);
            StrokeCap::Round {
                cx: s0.x, cy: s0.y, r: (wl0 + wr0) / 2.0,
                // FROM the right rail, which sits at theta - pi/2, BACKWARDS
                // around the far side, TO the left rail at theta + pi/2. The
                // decreasing sweep is what carries it through theta - pi,
                // i.e. behind the start of the stroke.
                a0: a - std::f64::consts::FRAC_PI_2,
                a1: a + std::f64::consts::FRAC_PI_2,
                decreasing: true,
            }
        }
        LineCap::Square if wl0 + wr0 > 0.1 => StrokeCap::Square {
            ext: (wl0 + wr0) / 2.0, ux: -s0.ny, uy: s0.nx,
        },
        _ => StrokeCap::Butt,
    };
    let end_cap = match linecap {
        LineCap::Round if wln + wrn > 0.1 => {
            let a = tangent_angle(sn);
            StrokeCap::Round {
                cx: sn.x, cy: sn.y, r: (wln + wrn) / 2.0,
                // FROM the left rail TO the right rail, the other way round,
                // so the decreasing sweep passes through theta itself --
                // ahead of the end of the stroke.
                a0: a + std::f64::consts::FRAC_PI_2,
                a1: a - std::f64::consts::FRAC_PI_2,
                decreasing: true,
            }
        }
        LineCap::Square if wln + wrn > 0.1 => StrokeCap::Square {
            ext: (wln + wrn) / 2.0, ux: sn.ny, uy: -sn.nx,
        },
        _ => StrokeCap::Butt,
    };

    StrokeOutline { left, right, start_cap, end_cap }
}

/// The direction of travel at a sample, as an angle.
///
/// The normal is the tangent turned a quarter turn — `n = (-t_y, t_x)` — so
/// the tangent read back off it is `(n_y, -n_x)` and its angle is
/// `atan2(-n_x, n_y)`.
///
/// UNTIL 2026-08-01 THIS WAS `atan2(n_y, -n_x)`: the same two arguments the
/// other way round, which evaluates to `pi/2 - theta` — a REFLECTION of the
/// direction about the 45-degree line rather than the direction itself. A
/// reflection agrees with the truth along one axis and diverges by `2*theta`
/// everywhere else, so both round caps were welded on at the wrong angle for
/// every stroke direction except 135 and 315 degrees, where the two errors
/// happened to cancel. Measured on a 10pt-wide horizontal stroke: the cap arc
/// began 7.07pt from the rail it was joined to, and the renderer bridged that
/// gap with a straight chord. Both ports carried the identical expression, so
/// no port-against-port comparison could see it — the `offset_path` family's
/// hand-derived vectors are what reddened.
fn tangent_angle(s: &PathSample) -> f64 {
    (-s.nx).atan2(s.ny)
}

/// The closed polygon a renderer fills, in draw order.
///
/// FAITHFUL, not tidy. It reproduces exactly the point sequence the drawing
/// code emits, including the duplicate vertex where a `move_to` lands on the
/// first rail point and including any chord between a rail and the point a
/// cap arc actually starts at. A cap whose arc does not begin on its rail is
/// a real defect in the filled shape, and a flattener that quietly bridged it
/// would be an instrument reporting a prettier answer than the truth.
pub fn flatten_outline(o: &StrokeOutline, arc_steps: usize) -> Vec<(f64, f64)> {
    if o.left.len() < 2 {
        return Vec::new();
    }
    let mut poly: Vec<(f64, f64)> = Vec::new();
    let last = o.left.len() - 1;

    match o.start_cap {
        StrokeCap::Butt => poly.push(o.left[0]),
        StrokeCap::Square { ext, ux, uy } => {
            poly.push((o.right[0].0 + ux * ext, o.right[0].1 + uy * ext));
            poly.push((o.left[0].0 + ux * ext, o.left[0].1 + uy * ext));
        }
        StrokeCap::Round { .. } => {
            poly.push(o.right[0]);
            append_arc(&mut poly, &o.start_cap, arc_steps);
        }
    }

    poly.extend_from_slice(&o.left);

    match o.end_cap {
        StrokeCap::Butt => {}
        StrokeCap::Square { ext, ux, uy } => {
            poly.push((o.left[last].0 + ux * ext, o.left[last].1 + uy * ext));
            poly.push((o.right[last].0 + ux * ext, o.right[last].1 + uy * ext));
        }
        StrokeCap::Round { .. } => append_arc(&mut poly, &o.end_cap, arc_steps),
    }

    poly.extend(o.right.iter().rev().copied());
    poly
}

/// SCOPE: a cap sweep is at most a half turn, so the wrap-around cases a
/// general arc flattener must decide — a sweep of exactly zero, and one of a
/// full turn or more — cannot arise here and are NOT handled. The normalised
/// sweep is taken into `(0, 2*pi]`.
fn append_arc(poly: &mut Vec<(f64, f64)>, cap: &StrokeCap, steps: usize) {
    let StrokeCap::Round { cx, cy, r, a0, a1, decreasing } = *cap else {
        return;
    };
    let tau = std::f64::consts::TAU;
    let raw = if decreasing { a0 - a1 } else { a1 - a0 };
    let mut sweep = raw % tau;
    if sweep <= 0.0 {
        sweep += tau;
    }
    let n = steps.max(1);
    for i in 0..=n {
        let f = i as f64 / n as f64;
        let a = if decreasing { a0 - sweep * f } else { a0 + sweep * f };
        poly.push((cx + r * a.cos(), cy + r * a.sin()));
    }
}

/// Render a variable-width stroke for a path element.
#[cfg(feature = "web")]
pub fn render_variable_width_path(
    ctx: &CanvasRenderingContext2d,
    cmds: &[PathCommand],
    width_points: &[StrokeWidthPoint],
    stroke_color: &str,
    linecap: LineCap,
) {
    let outline = variable_width_outline_path(cmds, width_points, linecap);
    fill_outline(ctx, &outline, stroke_color);
}

/// Render a variable-width stroke for a line element.
#[cfg(feature = "web")]
pub fn render_variable_width_line(
    ctx: &CanvasRenderingContext2d,
    x1: f64, y1: f64, x2: f64, y2: f64,
    width_points: &[StrokeWidthPoint],
    stroke_color: &str,
    linecap: LineCap,
) {
    let outline =
        variable_width_outline_line(x1, y1, x2, y2, width_points, linecap);
    fill_outline(ctx, &outline, stroke_color);
}

#[cfg(feature = "web")]
fn fill_outline(
    ctx: &CanvasRenderingContext2d,
    outline: &StrokeOutline,
    stroke_color: &str,
) {
    let poly = flatten_outline(outline, CAP_ARC_STEPS);
    if poly.is_empty() {
        return;
    }
    ctx.begin_path();
    ctx.move_to(poly[0].0, poly[0].1);
    for &(x, y) in &poly[1..] {
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

    /// THE REGRESSION THIS FAMILY WAS WRITTEN AGAINST, in port, so a
    /// Rust-only edit reds without waiting for the cross-language runner.
    ///
    /// SVG 11.4: a round cap is the semicircle of radius half the stroke
    /// width centred on the endpoint — so its two ends ARE the two rail
    /// points and the outline needs no chord to reach them. Four directions,
    /// because the defect it catches was a REFLECTION of the direction rather
    /// than a rotation: it agreed with the truth along one axis and diverged
    /// by twice the angle everywhere else.
    #[test]
    fn a_round_cap_begins_on_the_rail_it_is_joined_to() {
        use crate::geometry::element::PathCommand;
        let w = vec![
            StrokeWidthPoint { t: 0.0, width_left: 5.0, width_right: 5.0 },
            StrokeWidthPoint { t: 1.0, width_left: 5.0, width_right: 5.0 },
        ];
        for (dx, dy) in [(10.0, 0.0), (0.0, 10.0), (7.0, 7.0), (-3.0, 9.0)] {
            let d = vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: dx, y: dy },
            ];
            let o = variable_width_outline_path(&d, &w, LineCap::Round);
            let StrokeCap::Round { cx, cy, r, a0, a1, .. } = o.start_cap else {
                panic!("a round-capped stroke should have a round start cap");
            };
            let begin = (cx + r * a0.cos(), cy + r * a0.sin());
            let finish = (cx + r * a1.cos(), cy + r * a1.sin());
            assert!((begin.0 - o.right[0].0).abs() < 1e-9
                    && (begin.1 - o.right[0].1).abs() < 1e-9,
                    "start cap begins at {begin:?}, right rail is {:?}, \
                     direction ({dx}, {dy})", o.right[0]);
            assert!((finish.0 - o.left[0].0).abs() < 1e-9
                    && (finish.1 - o.left[0].1).abs() < 1e-9,
                    "start cap ends at {finish:?}, left rail is {:?}, \
                     direction ({dx}, {dy})", o.left[0]);
        }
    }

    /// The cap must lie BEYOND the endpoint, not across the stroke. The
    /// endpoint check above pins the two ends of the sweep; this pins which
    /// of the two semicircles between them was taken.
    ///
    /// THE TWO ARE COMPLEMENTARY, AND THAT WAS MEASURED, not assumed. Restore
    /// the pre-2026-08-01 reflected angle and only the endpoint test reds —
    /// the reflected cap still reaches past both ends, it is simply welded on
    /// sideways. Flip `decreasing` instead and only this test and the sweep
    /// test red, because the endpoints are unchanged and it is the half that
    /// moved. Neither catches the other's defect; do not delete one as
    /// redundant.
    #[test]
    fn a_round_cap_bulges_away_from_the_stroke() {
        use crate::geometry::element::PathCommand;
        let w = vec![
            StrokeWidthPoint { t: 0.0, width_left: 5.0, width_right: 5.0 },
            StrokeWidthPoint { t: 1.0, width_left: 5.0, width_right: 5.0 },
        ];
        let d = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 10.0, y: 0.0 },
        ];
        let o = variable_width_outline_path(&d, &w, LineCap::Round);
        let poly = flatten_outline(&o, 8);
        assert!(poly.iter().any(|p| p.0 < -4.9),
                "the start cap should reach behind x = 0: {poly:?}");
        assert!(poly.iter().any(|p| p.0 > 14.9),
                "the end cap should reach beyond x = 10: {poly:?}");
    }

    /// A cap sweep is a half turn, in both directions and at both ends.
    #[test]
    fn every_cap_sweeps_exactly_half_a_turn() {
        use crate::geometry::element::PathCommand;
        let w = vec![
            StrokeWidthPoint { t: 0.0, width_left: 3.0, width_right: 3.0 },
            StrokeWidthPoint { t: 1.0, width_left: 3.0, width_right: 3.0 },
        ];
        for (dx, dy) in [(10.0, 0.0), (0.0, -4.0), (-6.0, 2.0)] {
            let d = vec![
                PathCommand::MoveTo { x: 1.0, y: 2.0 },
                PathCommand::LineTo { x: 1.0 + dx, y: 2.0 + dy },
            ];
            let o = variable_width_outline_path(&d, &w, LineCap::Round);
            for cap in [o.start_cap, o.end_cap] {
                let StrokeCap::Round { a0, a1, decreasing, .. } = cap else {
                    panic!("expected a round cap");
                };
                assert!(decreasing);
                let mut sweep = (a0 - a1) % std::f64::consts::TAU;
                if sweep <= 0.0 {
                    sweep += std::f64::consts::TAU;
                }
                assert!((sweep - std::f64::consts::PI).abs() < 1e-9,
                        "sweep {sweep} for direction ({dx}, {dy})");
            }
        }
    }

    /// A square cap extends BACKWARD at the start and FORWARD at the end —
    /// the half of the cap arithmetic that was already right, kept honest so
    /// a repair to the round arm cannot quietly break it.
    #[test]
    fn a_square_cap_extends_along_the_stroke_not_across_it() {
        use crate::geometry::element::PathCommand;
        let w = vec![
            StrokeWidthPoint { t: 0.0, width_left: 5.0, width_right: 5.0 },
            StrokeWidthPoint { t: 1.0, width_left: 5.0, width_right: 5.0 },
        ];
        let d = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 10.0, y: 0.0 },
        ];
        let o = variable_width_outline_path(&d, &w, LineCap::Square);
        let StrokeCap::Square { ext, ux, uy } = o.start_cap else {
            panic!("expected a square start cap");
        };
        assert!((ext - 5.0).abs() < 1e-12);
        assert!((ux - -1.0).abs() < 1e-12 && uy.abs() < 1e-12);
        let StrokeCap::Square { ux, uy, .. } = o.end_cap else {
            panic!("expected a square end cap");
        };
        assert!((ux - 1.0).abs() < 1e-12 && uy.abs() < 1e-12);
    }

    /// A profile that tapers to nothing gets no cap there, whatever the cap
    /// style says: below 0.1pt across, an arc is a wart.
    #[test]
    fn a_zero_width_end_gets_no_cap() {
        use crate::geometry::element::PathCommand;
        let w = vec![
            StrokeWidthPoint { t: 0.0, width_left: 5.0, width_right: 5.0 },
            StrokeWidthPoint { t: 1.0, width_left: 0.0, width_right: 0.0 },
        ];
        let d = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 10.0, y: 0.0 },
        ];
        let o = variable_width_outline_path(&d, &w, LineCap::Round);
        assert!(matches!(o.start_cap, StrokeCap::Round { .. }));
        assert_eq!(o.end_cap, StrokeCap::Butt);
    }

    /// A path with nothing to stroke produces no outline rather than a panic.
    #[test]
    fn a_degenerate_path_has_no_outline() {
        use crate::geometry::element::PathCommand;
        let w = vec![
            StrokeWidthPoint { t: 0.0, width_left: 5.0, width_right: 5.0 },
        ];
        for d in [
            vec![],
            vec![PathCommand::MoveTo { x: 3.0, y: 4.0 }],
            vec![PathCommand::MoveTo { x: 3.0, y: 4.0 },
                 PathCommand::LineTo { x: 3.0, y: 4.0 }],
        ] {
            let o = variable_width_outline_path(&d, &w, LineCap::Round);
            assert!(flatten_outline(&o, 8).is_empty(), "for {d:?}");
        }
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
