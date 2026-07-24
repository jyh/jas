//! True arc-length trim for arrowheaded strokes.
//!
//! The legacy `arrowheads::shorten_path` moved the first/last ANCHOR inward
//! along the endpoint tangent while leaving the control points untouched. On a
//! curved final segment that deforms the curve instead of trimming it — the
//! sweep still bulges out from under the head — and at a large setback (e.g.
//! arrowhead scale 200) it can fold the endpoint PAST the control point, hooking
//! the stroke retrograde behind the head.
//!
//! `trim_path` replaces that with a real arc-length trim: walk in from each armed
//! end by the setback distance along arc length, de-Casteljau-split the segment
//! that straddles the cut, drop the tail, and butt the cut. The head is still
//! oriented off the ORIGINAL path (see `arrowheads` orientation contract), so the
//! stroke ends exactly at the head base with nothing protruding.
//!
//! Arc length reuses the house parameterization: each curve is sampled at
//! `FLATTEN_STEPS` uniform-in-t points and measured as the resulting polyline,
//! identical to `geometry::element::flatten_path_commands` and
//! `geometry::measure::arc_lengths` (the dash engine walks the same polyline
//! anchors). Lines are measured exactly. This keeps the arc→parameter mapping
//! byte-reproducible across the active ports, which the cross-language corpus
//! (`test_fixtures/algorithms/arrow_trim.json`) pins to 4 decimals.
//!
//! Pure geometry (no `web` dependency) so the `algorithm_roundtrip` binary can
//! drive it under `--no-default-features`.

use crate::geometry::element::{PathCommand, FLATTEN_STEPS};

const EPS: f64 = 1e-9;

type P = (f64, f64);

/// A single drawable segment, retaining its original curve form so the trim can
/// split it exactly.
#[derive(Clone, Copy)]
enum Seg {
    Line { p0: P, p1: P },
    Quad { p0: P, p1: P, p2: P },
    Cubic { p0: P, p1: P, p2: P, p3: P },
}

fn lerp(a: P, b: P, t: f64) -> P {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
}

fn dist(a: P, b: P) -> f64 {
    let dx = b.0 - a.0;
    let dy = b.1 - a.1;
    (dx * dx + dy * dy).sqrt()
}

impl Seg {
    fn p0(&self) -> P {
        match *self {
            Seg::Line { p0, .. } | Seg::Quad { p0, .. } | Seg::Cubic { p0, .. } => p0,
        }
    }
    fn p1(&self) -> P {
        match *self {
            Seg::Line { p1, .. } => p1,
            Seg::Quad { p2, .. } => p2,
            Seg::Cubic { p3, .. } => p3,
        }
    }

    /// Point on the segment at parameter `t` in [0, 1].
    fn point_at(&self, t: f64) -> P {
        match *self {
            Seg::Line { p0, p1 } => lerp(p0, p1, t),
            Seg::Quad { p0, p1, p2 } => {
                let a = lerp(p0, p1, t);
                let b = lerp(p1, p2, t);
                lerp(a, b, t)
            }
            Seg::Cubic { p0, p1, p2, p3 } => {
                let a = lerp(p0, p1, t);
                let b = lerp(p1, p2, t);
                let c = lerp(p2, p3, t);
                let d = lerp(a, b, t);
                let e = lerp(b, c, t);
                lerp(d, e, t)
            }
        }
    }

    /// Flatten to a polyline the same way the house arc-length machinery does:
    /// lines stay exact (two points); curves take `FLATTEN_STEPS` uniform-t
    /// samples.
    fn flatten(&self) -> Vec<P> {
        match *self {
            Seg::Line { p0, p1 } => vec![p0, p1],
            _ => {
                let n = FLATTEN_STEPS;
                let mut pts = Vec::with_capacity(n + 1);
                for i in 0..=n {
                    pts.push(self.point_at(i as f64 / n as f64));
                }
                pts
            }
        }
    }

    fn arc_len(&self) -> f64 {
        let pts = self.flatten();
        let mut total = 0.0;
        for w in pts.windows(2) {
            total += dist(w[0], w[1]);
        }
        total
    }

    /// Parameter `t` at arc distance `target` (in [0, arc_len]) from the segment
    /// start, using the same polyline the length is measured on.
    fn param_at_arc(&self, target: f64) -> f64 {
        if target <= 0.0 {
            return 0.0;
        }
        match *self {
            Seg::Line { p0, p1 } => {
                let l = dist(p0, p1);
                if l <= EPS {
                    0.0
                } else {
                    (target / l).clamp(0.0, 1.0)
                }
            }
            _ => {
                let n = FLATTEN_STEPS;
                let pts = self.flatten();
                let mut cum = 0.0;
                for i in 1..=n {
                    let seg_l = dist(pts[i - 1], pts[i]);
                    if cum + seg_l >= target - EPS {
                        let frac = if seg_l <= EPS { 0.0 } else { (target - cum) / seg_l };
                        return ((i - 1) as f64 + frac.clamp(0.0, 1.0)) / n as f64;
                    }
                    cum += seg_l;
                }
                1.0
            }
        }
    }

    /// The sub-segment between parameters `t0` and `t1` (0 <= t0 <= t1 <= 1) as a
    /// PathCommand that draws FROM `point_at(t0)` TO `point_at(t1)`. The caller
    /// emits the MoveTo/joining point.
    fn sub_command(&self, t0: f64, t1: f64) -> PathCommand {
        match *self {
            Seg::Line { .. } => {
                let e = self.point_at(t1);
                PathCommand::LineTo { x: e.0, y: e.1 }
            }
            Seg::Cubic { p0, p1, p2, p3 } => {
                let (q0, q1, q2, q3) = cubic_between(p0, p1, p2, p3, t0, t1);
                let _ = q0;
                PathCommand::CurveTo { x1: q1.0, y1: q1.1, x2: q2.0, y2: q2.1, x: q3.0, y: q3.1 }
            }
            Seg::Quad { p0, p1, p2 } => {
                let (q0, q1, q2) = quad_between(p0, p1, p2, t0, t1);
                let _ = q0;
                PathCommand::QuadTo { x1: q1.0, y1: q1.1, x: q2.0, y: q2.1 }
            }
        }
    }

    /// The whole segment as a PathCommand drawing to its endpoint.
    fn full_command(&self) -> PathCommand {
        match *self {
            Seg::Line { p1, .. } => PathCommand::LineTo { x: p1.0, y: p1.1 },
            Seg::Cubic { p1, p2, p3, .. } => {
                PathCommand::CurveTo { x1: p1.0, y1: p1.1, x2: p2.0, y2: p2.1, x: p3.0, y: p3.1 }
            }
            Seg::Quad { p1, p2, .. } => PathCommand::QuadTo { x1: p1.0, y1: p1.1, x: p2.0, y: p2.1 },
        }
    }
}

/// de Casteljau split of a cubic at `t`; returns (left ctrl pts, right ctrl pts).
fn cubic_split(p0: P, p1: P, p2: P, p3: P, t: f64) -> ((P, P, P, P), (P, P, P, P)) {
    let a = lerp(p0, p1, t);
    let b = lerp(p1, p2, t);
    let c = lerp(p2, p3, t);
    let d = lerp(a, b, t);
    let e = lerp(b, c, t);
    let m = lerp(d, e, t);
    ((p0, a, d, m), (m, e, c, p3))
}

/// The cubic sub-curve over [t0, t1] as four control points.
fn cubic_between(p0: P, p1: P, p2: P, p3: P, t0: f64, t1: f64) -> (P, P, P, P) {
    let (_, right) = cubic_split(p0, p1, p2, p3, t0);
    let denom = 1.0 - t0;
    let tt = if denom.abs() <= EPS { 0.0 } else { ((t1 - t0) / denom).clamp(0.0, 1.0) };
    let (left, _) = cubic_split(right.0, right.1, right.2, right.3, tt);
    left
}

fn quad_split(p0: P, p1: P, p2: P, t: f64) -> ((P, P, P), (P, P, P)) {
    let a = lerp(p0, p1, t);
    let b = lerp(p1, p2, t);
    let m = lerp(a, b, t);
    ((p0, a, m), (m, b, p2))
}

fn quad_between(p0: P, p1: P, p2: P, t0: f64, t1: f64) -> (P, P, P) {
    let (_, right) = quad_split(p0, p1, p2, t0);
    let denom = 1.0 - t0;
    let tt = if denom.abs() <= EPS { 0.0 } else { ((t1 - t0) / denom).clamp(0.0, 1.0) };
    let (left, _) = quad_split(right.0, right.1, right.2, tt);
    left
}

/// Parse path commands into drawable segments. `SmoothCurveTo`/`SmoothQuadTo`/
/// `ArcTo` degrade to a line to their endpoint, matching `flatten_path_commands`
/// (arrowheaded strokes are lines and explicit cubics/quads in practice).
fn build_segments(cmds: &[PathCommand]) -> Vec<Seg> {
    let mut segs = Vec::new();
    let mut cur: P = (0.0, 0.0);
    let mut sub_start: P = (0.0, 0.0);
    for cmd in cmds {
        match *cmd {
            PathCommand::MoveTo { x, y } => {
                cur = (x, y);
                sub_start = (x, y);
            }
            PathCommand::LineTo { x, y } => {
                segs.push(Seg::Line { p0: cur, p1: (x, y) });
                cur = (x, y);
            }
            PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                segs.push(Seg::Cubic { p0: cur, p1: (x1, y1), p2: (x2, y2), p3: (x, y) });
                cur = (x, y);
            }
            PathCommand::QuadTo { x1, y1, x, y } => {
                segs.push(Seg::Quad { p0: cur, p1: (x1, y1), p2: (x, y) });
                cur = (x, y);
            }
            PathCommand::SmoothCurveTo { x, y, .. }
            | PathCommand::SmoothQuadTo { x, y }
            | PathCommand::ArcTo { x, y, .. } => {
                segs.push(Seg::Line { p0: cur, p1: (x, y) });
                cur = (x, y);
            }
            PathCommand::ClosePath => {
                if dist(cur, sub_start) > EPS {
                    segs.push(Seg::Line { p0: cur, p1: sub_start });
                }
                cur = sub_start;
            }
        }
    }
    segs
}

/// Locate the segment straddling global arc distance `a` and the local distance
/// into it. `cum` has `segs.len() + 1` entries (leading 0).
fn locate(cum: &[f64], a: f64) -> (usize, f64) {
    let n = cum.len() - 1;
    if a <= cum[0] {
        return (0, 0.0);
    }
    if a >= cum[n] {
        return (n - 1, cum[n] - cum[n - 1]);
    }
    for i in 0..n {
        if a < cum[i + 1] {
            return (i, a - cum[i]);
        }
    }
    (n - 1, cum[n] - cum[n - 1])
}

/// Arc-length-trim `cmds` inward by `start_setback` from the path start and
/// `end_setback` from the path end (both in document units).
///
/// Returns the trimmed stroke path. An empty vec means "nothing remains" — the
/// setbacks meet or exceed the total length — and the caller must draw only the
/// arrowheads (oriented off the original path), no stroke. This covers the
/// corner cases: a single setback >= total, and both setbacks overlapping
/// (proportional apportionment leaves no middle, so it degenerates to
/// heads-only).
pub fn trim_path(cmds: &[PathCommand], start_setback: f64, end_setback: f64) -> Vec<PathCommand> {
    if cmds.is_empty() {
        return Vec::new();
    }
    let start_setback = start_setback.max(0.0);
    let end_setback = end_setback.max(0.0);
    if start_setback <= EPS && end_setback <= EPS {
        return cmds.to_vec();
    }

    let segs = build_segments(cmds);
    if segs.is_empty() {
        return cmds.to_vec();
    }

    let lens: Vec<f64> = segs.iter().map(Seg::arc_len).collect();
    let mut cum = Vec::with_capacity(segs.len() + 1);
    cum.push(0.0);
    let mut s = 0.0;
    for &l in &lens {
        s += l;
        cum.push(s);
    }
    let total = s;
    if total <= EPS {
        return cmds.to_vec();
    }

    let a_start = start_setback.min(total);
    let a_end = total - end_setback;
    // Overlapping or total consumption -> heads-only.
    if a_end <= a_start + EPS {
        return Vec::new();
    }

    let (i0, local0) = locate(&cum, a_start);
    let (i1, local1) = locate(&cum, a_end);
    let t0 = segs[i0].param_at_arc(local0);
    let t1 = segs[i1].param_at_arc(local1);

    let mut out: Vec<PathCommand> = Vec::new();
    let start_pt = segs[i0].point_at(t0);
    out.push(PathCommand::MoveTo { x: start_pt.0, y: start_pt.1 });
    let mut last_pt = start_pt;

    if i0 == i1 {
        out.push(segs[i0].sub_command(t0, t1));
        last_pt = segs[i0].point_at(t1);
    } else {
        // Head of the first straddled segment: [t0, 1].
        out.push(segs[i0].sub_command(t0, 1.0));
        last_pt = segs[i0].p1();
        // Whole interior segments (re-emit a MoveTo across any pen-up gap).
        for k in (i0 + 1)..i1 {
            if dist(segs[k].p0(), last_pt) > EPS {
                out.push(PathCommand::MoveTo { x: segs[k].p0().0, y: segs[k].p0().1 });
            }
            out.push(segs[k].full_command());
            last_pt = segs[k].p1();
        }
        // Tail of the last straddled segment: [0, t1].
        if dist(segs[i1].p0(), last_pt) > EPS {
            out.push(PathCommand::MoveTo { x: segs[i1].p0().0, y: segs[i1].p0().1 });
        }
        out.push(segs[i1].sub_command(0.0, t1));
        last_pt = segs[i1].point_at(t1);
    }
    let _ = last_pt;
    out
}

// ── Tests ────────────────────────────────────────────────────────
#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::PathCommand::{CurveTo as C, LineTo as L, MoveTo as M};

    fn pt_of(cmd: &PathCommand) -> P {
        match *cmd {
            PathCommand::MoveTo { x, y }
            | PathCommand::LineTo { x, y }
            | PathCommand::CurveTo { x, y, .. }
            | PathCommand::QuadTo { x, y, .. } => (x, y),
            _ => (f64::NAN, f64::NAN),
        }
    }

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-4, "expected {b}, got {a}");
    }

    #[test]
    fn line_trim_both_ends_is_exact() {
        // A 100-long horizontal line, trim 10 off the start and 20 off the end.
        let d = vec![M { x: 0.0, y: 0.0 }, L { x: 100.0, y: 0.0 }];
        let r = trim_path(&d, 10.0, 20.0);
        assert_eq!(r.len(), 2);
        let s = pt_of(&r[0]);
        let e = pt_of(&r[1]);
        approx(s.0, 10.0);
        approx(s.1, 0.0);
        approx(e.0, 80.0);
        approx(e.1, 0.0);
    }

    #[test]
    fn zero_setback_is_identity() {
        let d = vec![M { x: 0.0, y: 0.0 }, C { x1: 10.0, y1: 10.0, x2: 20.0, y2: 10.0, x: 30.0, y: 0.0 }];
        assert_eq!(trim_path(&d, 0.0, 0.0), d);
    }

    #[test]
    fn curve_end_trim_keeps_a_curve_not_a_folded_anchor() {
        // Cubic whose last leg (ctrl2 -> end) is short. The old shorten moved
        // the endpoint back along the tangent, folding the curve; the true trim
        // splits it and the kept endpoint lands ON the curve, short of the
        // original end, with the head-facing tangent preserved.
        let d = vec![M { x: 0.0, y: 0.0 }, C { x1: 0.0, y1: 40.0, x2: 40.0, y2: 40.0, x: 40.0, y: 0.0 }];
        let total = super::build_segments(&d)[0].arc_len();
        let r = trim_path(&d, 0.0, total * 0.25);
        // Still one MoveTo + one CurveTo (a curve, not a line/fold).
        assert!(matches!(r[0], PathCommand::MoveTo { .. }));
        assert!(matches!(r[1], PathCommand::CurveTo { .. }));
        // The kept endpoint sits on the original curve at ~75% arc length and is
        // strictly inside the original endpoint (x < 40, and pulled off y=0).
        let e = pt_of(r.last().unwrap());
        assert!(e.0 < 40.0 - 1e-6, "endpoint should retreat from x=40, got {}", e.0);
        assert!(e.1 > 1e-6, "endpoint should lift off y=0 onto the curve, got {}", e.1);
    }

    #[test]
    fn setback_exceeding_total_yields_heads_only() {
        let d = vec![M { x: 0.0, y: 0.0 }, L { x: 30.0, y: 0.0 }];
        assert!(trim_path(&d, 0.0, 50.0).is_empty());
        assert!(trim_path(&d, 50.0, 0.0).is_empty());
    }

    #[test]
    fn overlapping_setbacks_degenerate_to_heads_only() {
        let d = vec![M { x: 0.0, y: 0.0 }, L { x: 40.0, y: 0.0 }];
        // 25 + 25 > 40 -> the two trims cross -> nothing remains.
        assert!(trim_path(&d, 25.0, 25.0).is_empty());
    }

    #[test]
    fn trim_spans_a_corner_across_two_segments() {
        // Two 50-long legs. Trim 10 off start, 10 off end: the kept stroke spans
        // the corner, so the interior anchor (50,0) survives as a joint.
        let d = vec![M { x: 0.0, y: 0.0 }, L { x: 50.0, y: 0.0 }, L { x: 50.0, y: 50.0 }];
        let r = trim_path(&d, 10.0, 10.0);
        // MoveTo(10,0), LineTo(50,0) [corner], LineTo(50,40).
        assert_eq!(r.len(), 3);
        approx(pt_of(&r[0]).0, 10.0);
        let corner = pt_of(&r[1]);
        approx(corner.0, 50.0);
        approx(corner.1, 0.0);
        let e = pt_of(&r[2]);
        approx(e.0, 50.0);
        approx(e.1, 40.0);
    }

    #[test]
    fn determinism() {
        let d = vec![M { x: 0.0, y: 0.0 }, C { x1: 0.0, y1: 40.0, x2: 40.0, y2: 40.0, x: 40.0, y: 0.0 }];
        assert_eq!(trim_path(&d, 5.0, 7.0), trim_path(&d, 5.0, 7.0));
    }
}
