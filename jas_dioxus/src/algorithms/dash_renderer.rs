//! Dash-alignment renderer for stroked paths.
//!
//! Pure function: given a path, a dash array, and an alignment flag,
//! return a list of solid sub-paths to draw. Implements DASH_ALIGN.md
//! §Algorithm — port of `workspace_interpreter/dash_renderer.py`.
//! Keep in lockstep on the conversion table and rounding rules.
//!
//! Lines AND curves. A subpath is walked as a list of primitive
//! segments (line / quad / cubic) between consecutive anchors —
//! `arrow_trim`'s segment kernel, reused verbatim so the arc→parameter
//! mapping and the de-Casteljau split are the same ones the arrowhead
//! trim is pinned on. A dash that straddles a cubic is emitted as a
//! cubic (DASH_ALIGN.md §subpath_between), not as a chord and not as a
//! polyline.
//!
//! Output: a `Vec<Vec<PathCommand>>` where each inner `Vec` is one
//! solid sub-path representing one dash. Sub-paths are emitted in
//! arc-length order. The caller draws each sub-path with the
//! existing solid-stroke pipeline (no `stroke-dasharray` /
//! `setLineDash`).

use crate::algorithms::arrow_trim::{build_segments, locate, Seg};
use crate::geometry::element::PathCommand;

const EPS: f64 = 1e-9;

/// Expand a dashed stroke into a list of solid sub-paths.
///
/// See [`workspace_interpreter::dash_renderer::expand_dashed_stroke`]
/// for the canonical Python reference.
pub fn expand_dashed_stroke(
    path: &[PathCommand],
    dash_array: &[f64],
    align_anchors: bool,
) -> Vec<Vec<PathCommand>> {
    if path.is_empty() {
        return Vec::new();
    }
    // No dashing → single solid sub-path equal to the original path.
    if dash_array.is_empty() || dash_array.iter().all(|&v| v == 0.0) {
        if path.iter().any(|c| !matches!(c, PathCommand::MoveTo { .. })) {
            return vec![path.to_vec()];
        }
        return Vec::new();
    }

    // Pad odd-length pattern to even (SVG semantics).
    let pattern: Vec<f64> = if dash_array.len() % 2 == 1 {
        dash_array.iter().chain(dash_array.iter()).copied().collect()
    } else {
        dash_array.to_vec()
    };

    let subpaths = split_at_moveto(path);
    let mut result = Vec::new();
    for sp in &subpaths {
        // No drawable segment (a bare MoveTo, or the S-4 bare ClosePath
        // that establishes no anchor) -> no dash.
        let segs = build_segments(sp);
        if segs.is_empty() {
            continue;
        }
        if align_anchors {
            result.extend(expand_align(&segs, is_closed(sp), &pattern));
        } else {
            result.extend(expand_preserve(&segs, &pattern));
        }
    }
    result
}

// ── Path utilities ───────────────────────────────────────────────

fn split_at_moveto(path: &[PathCommand]) -> Vec<Vec<PathCommand>> {
    let mut subs: Vec<Vec<PathCommand>> = Vec::new();
    let mut cur: Vec<PathCommand> = Vec::new();
    for cmd in path {
        if matches!(cmd, PathCommand::MoveTo { .. }) {
            if !cur.is_empty() {
                subs.push(cur);
            }
            cur = vec![*cmd];
        } else {
            cur.push(*cmd);
        }
    }
    if !cur.is_empty() {
        subs.push(cur);
    }
    subs
}

fn is_closed(subpath: &[PathCommand]) -> bool {
    subpath.iter().any(|c| matches!(c, PathCommand::ClosePath))
}

/// Per-segment arc lengths plus their running total (`cum[0] = 0`,
/// `cum[i + 1] = cum[i] + len(seg i)`). A line measures exactly; a curve
/// measures as its `FLATTEN_STEPS` polyline, the house parameterization.
fn seg_lengths_and_cum(segs: &[Seg]) -> (Vec<f64>, Vec<f64>) {
    let lengths: Vec<f64> = segs.iter().map(Seg::arc_len).collect();
    let mut cum = Vec::with_capacity(lengths.len() + 1);
    cum.push(0.0);
    let mut s = 0.0;
    for &l in &lengths {
        s += l;
        cum.push(s);
    }
    (lengths, cum)
}

// ── Preserve mode ────────────────────────────────────────────────

fn expand_preserve(segs: &[Seg], pattern: &[f64]) -> Vec<Vec<PathCommand>> {
    let (_, cum) = seg_lengths_and_cum(segs);
    let total = *cum.last().unwrap_or(&0.0);
    if total <= 0.0 {
        return Vec::new();
    }
    emit_dashes(segs, &cum, pattern, 0.0, 0.0, total)
}

// ── Align mode ───────────────────────────────────────────────────

fn expand_align(
    segs: &[Seg],
    closed: bool,
    pattern: &[f64],
) -> Vec<Vec<PathCommand>> {
    let n_segs = segs.len();
    if n_segs == 0 {
        return Vec::new();
    }
    let base_period: f64 = pattern.iter().sum();
    if base_period <= 0.0 {
        return Vec::new();
    }
    let (seg_lengths, cum) = seg_lengths_and_cum(segs);
    if seg_lengths.iter().all(|&l| l <= 0.0) {
        return Vec::new();
    }

    // Per-segment dash ranges in global arc-length.
    let mut all_ranges: Vec<(f64, f64)> = Vec::new();
    for i in 0..n_segs {
        let l_i = seg_lengths[i];
        if l_i <= 0.0 {
            continue;
        }
        let kind = boundary_kind(i, n_segs, closed);
        let scale = solve_segment_scale(l_i, pattern, kind);
        let local = segment_dash_ranges(l_i, pattern, scale, kind);
        let off = cum[i];
        for (a, b) in local {
            all_ranges.push((a + off, b + off));
        }
    }

    let mut merged = merge_adjacent_ranges(&all_ranges);

    // Closed-path cyclic stitch.
    if closed && merged.len() >= 2 {
        let total = *cum.last().unwrap_or(&0.0);
        let last = merged.last().copied().unwrap();
        let first = merged[0];
        if (last.1 - total).abs() < EPS && first.0.abs() < EPS {
            let wrapped = (last.0, first.1 + total);
            let mut new_merged = vec![wrapped];
            new_merged.extend_from_slice(&merged[1..merged.len() - 1]);
            merged = new_merged;
        }
    }

    let mut result: Vec<Vec<PathCommand>> = Vec::new();
    for (gs, ge) in merged {
        if let Some(sub) = subpath_between_wrapping(segs, &cum, gs, ge, closed) {
            result.push(sub);
        }
    }
    result
}

#[derive(Copy, Clone, PartialEq, Eq, Debug)]
enum BoundaryKind {
    II,
    EE,
    EI,
    IE,
}

fn boundary_kind(i: usize, n_segs: usize, closed: bool) -> BoundaryKind {
    if closed {
        return BoundaryKind::II;
    }
    if n_segs == 1 {
        return BoundaryKind::EE;
    }
    if i == 0 {
        return BoundaryKind::EI;
    }
    if i == n_segs - 1 {
        return BoundaryKind::IE;
    }
    BoundaryKind::II
}

fn solve_segment_scale(seg_l: f64, pattern: &[f64], kind: BoundaryKind) -> f64 {
    let base_period: f64 = pattern.iter().sum();
    let d0 = pattern[0];
    match kind {
        BoundaryKind::II => {
            let m = ((seg_l / base_period).round() as i64).max(1) as f64;
            seg_l / (m * base_period)
        }
        BoundaryKind::EE => {
            let m = (((seg_l - d0) / base_period).round() as i64).max(0) as f64;
            let denom = m * base_period + d0;
            if denom > 0.0 { seg_l / denom } else { 1.0 }
        }
        BoundaryKind::EI | BoundaryKind::IE => {
            let m = (((seg_l - 0.5 * d0) / base_period).round() as i64).max(1) as f64;
            let denom = m * base_period + 0.5 * d0;
            if denom > 0.0 { seg_l / denom } else { 1.0 }
        }
    }
}

fn segment_dash_ranges(
    seg_l: f64,
    pattern: &[f64],
    scale: f64,
    kind: BoundaryKind,
) -> Vec<(f64, f64)> {
    let scaled: Vec<f64> = pattern.iter().map(|p| p * scale).collect();
    let period: f64 = scaled.iter().sum();
    if period <= 0.0 || seg_l <= 0.0 {
        return Vec::new();
    }
    let half_d = scaled[0] * 0.5;
    let offset0 = match kind {
        BoundaryKind::EE | BoundaryKind::EI => 0.0,
        BoundaryKind::II | BoundaryKind::IE => half_d,
    };
    let mut ranges: Vec<(f64, f64)> = Vec::new();
    let mut t = 0.0;
    let (mut cur_idx, mut in_idx) = locate_in_pattern(offset0, &scaled);
    while t < seg_l - EPS {
        let remaining = scaled[cur_idx] - in_idx;
        let next_t = (t + remaining).min(seg_l);
        let is_dash = cur_idx % 2 == 0;
        if is_dash && next_t > t + EPS {
            ranges.push((t, next_t));
        }
        let consumed = next_t - t;
        in_idx += consumed;
        if in_idx >= scaled[cur_idx] - EPS {
            in_idx = 0.0;
            cur_idx = (cur_idx + 1) % scaled.len();
        }
        t = next_t;
    }
    ranges
}

fn locate_in_pattern(offset: f64, pattern: &[f64]) -> (usize, f64) {
    let period: f64 = pattern.iter().sum();
    if period <= 0.0 {
        return (0, 0.0);
    }
    let mut o = offset.rem_euclid(period);
    for (i, &w) in pattern.iter().enumerate() {
        if o < w - EPS {
            return (i, o);
        }
        o -= w;
    }
    (0, 0.0)
}

fn merge_adjacent_ranges(ranges: &[(f64, f64)]) -> Vec<(f64, f64)> {
    let mut out: Vec<(f64, f64)> = Vec::new();
    for &(s, e) in ranges {
        if let Some(last) = out.last_mut() {
            if (last.1 - s).abs() < EPS {
                last.1 = e;
                continue;
            }
        }
        out.push((s, e));
    }
    out
}

fn subpath_between_wrapping(
    segs: &[Seg],
    cum: &[f64],
    t0: f64,
    t1: f64,
    closed: bool,
) -> Option<Vec<PathCommand>> {
    let total = *cum.last().unwrap_or(&0.0);
    if !closed || t1 <= total + EPS {
        return subpath_between(segs, cum, t0, t1.min(total));
    }
    let head = subpath_between(segs, cum, t0, total);
    let tail = subpath_between(segs, cum, 0.0, t1 - total);
    match (head, tail) {
        (Some(h), Some(t)) => {
            // Drop tail's leading MoveTo.
            let mut combined = h;
            for cmd in t.into_iter().skip(1) {
                if matches!(cmd, PathCommand::MoveTo { .. }) {
                    continue;
                }
                combined.push(cmd);
            }
            Some(combined)
        }
        (Some(h), None) => Some(h),
        (None, Some(t)) => Some(t),
        (None, None) => None,
    }
}

/// The stretch of the subpath between arc-lengths `t0` and `t1`, in the
/// subpath's own primitives: the straddled ends are de-Casteljau splits
/// of their segment, the segments fully inside are re-emitted verbatim.
/// A cubic in, a cubic out — the dash follows the drawn geometry, never
/// its chord.
fn subpath_between(
    segs: &[Seg],
    cum: &[f64],
    t0: f64,
    t1: f64,
) -> Option<Vec<PathCommand>> {
    if t1 <= t0 + EPS {
        return None;
    }
    let (i, local0) = locate(cum, t0);
    let (j, local1) = locate(cum, t1);
    let a0 = segs[i].param_at_arc(local0);
    let a1 = segs[j].param_at_arc(local1);
    let start = segs[i].point_at(a0);
    let mut cmds: Vec<PathCommand> = Vec::with_capacity(j - i + 2);
    cmds.push(PathCommand::MoveTo { x: start.0, y: start.1 });
    if i == j {
        cmds.push(segs[i].sub_command(a0, a1));
    } else {
        cmds.push(segs[i].sub_command(a0, 1.0));
        for k in (i + 1)..j {
            cmds.push(segs[k].full_command());
        }
        cmds.push(segs[j].sub_command(0.0, a1));
    }
    // `t1` landing exactly on an anchor makes the final command a
    // zero-length repeat of the point we just drew to; drop it, as the
    // lines-only engine dropped its redundant trailing LineTo.
    if cmds.len() >= 2 {
        let last = cmd_endpoint(&cmds[cmds.len() - 1]);
        let prev = cmd_endpoint(&cmds[cmds.len() - 2]);
        if (last.0 - prev.0).abs() <= 1e-9 && (last.1 - prev.1).abs() <= 1e-9 {
            cmds.pop();
        }
    }
    Some(cmds)
}

fn cmd_endpoint(cmd: &PathCommand) -> (f64, f64) {
    match *cmd {
        PathCommand::MoveTo { x, y }
        | PathCommand::LineTo { x, y }
        | PathCommand::CurveTo { x, y, .. }
        | PathCommand::QuadTo { x, y, .. }
        | PathCommand::SmoothCurveTo { x, y, .. }
        | PathCommand::SmoothQuadTo { x, y }
        | PathCommand::ArcTo { x, y, .. } => (x, y),
        PathCommand::ClosePath => (f64::NAN, f64::NAN),
    }
}

fn emit_dashes(
    segs: &[Seg],
    cum: &[f64],
    pattern: &[f64],
    period_offset: f64,
    t_start: f64,
    t_end: f64,
) -> Vec<Vec<PathCommand>> {
    let mut out: Vec<Vec<PathCommand>> = Vec::new();
    let period: f64 = pattern.iter().sum();
    if period <= 0.0 {
        return out;
    }
    let (mut cur_idx, mut in_idx) = locate_in_pattern(period_offset, pattern);
    let mut t = t_start;
    while t < t_end - EPS {
        let remaining = pattern[cur_idx] - in_idx;
        let next_t = (t + remaining).min(t_end);
        let is_dash = cur_idx % 2 == 0;
        if is_dash && next_t > t + EPS {
            if let Some(sub) = subpath_between(segs, cum, t, next_t) {
                out.push(sub);
            }
        }
        let consumed = next_t - t;
        in_idx += consumed;
        if in_idx >= pattern[cur_idx] - EPS {
            in_idx = 0.0;
            cur_idx = (cur_idx + 1) % pattern.len();
        }
        t = next_t;
    }
    out
}

// ── Tests ────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::PathCommand::{LineTo as L, MoveTo as M, ClosePath as Z};

    fn approx_eq(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-6
    }

    #[test]
    fn empty_dash_array_returns_path_unchanged() {
        let path = vec![M { x: 0.0, y: 0.0 }, L { x: 10.0, y: 0.0 }, L { x: 10.0, y: 10.0 }, Z];
        let r = expand_dashed_stroke(&path, &[], false);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0], path);
    }

    #[test]
    fn empty_path_returns_empty() {
        let r = expand_dashed_stroke(&[], &[4.0, 2.0], false);
        assert!(r.is_empty());
    }

    #[test]
    fn preserve_simple_line_one_period() {
        let path = vec![M { x: 0.0, y: 0.0 }, L { x: 6.0, y: 0.0 }];
        let r = expand_dashed_stroke(&path, &[4.0, 2.0], false);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0], vec![M { x: 0.0, y: 0.0 }, L { x: 4.0, y: 0.0 }]);
    }

    #[test]
    fn preserve_simple_line_partial_period() {
        let path = vec![M { x: 0.0, y: 0.0 }, L { x: 10.0, y: 0.0 }];
        let r = expand_dashed_stroke(&path, &[4.0, 2.0], false);
        assert_eq!(r.len(), 2);
        assert_eq!(r[0], vec![M { x: 0.0, y: 0.0 }, L { x: 4.0, y: 0.0 }]);
        assert_eq!(r[1], vec![M { x: 6.0, y: 0.0 }, L { x: 10.0, y: 0.0 }]);
    }

    #[test]
    fn preserve_dash_spans_corner() {
        let path = vec![M { x: 0.0, y: 0.0 }, L { x: 5.0, y: 0.0 }, L { x: 5.0, y: 5.0 }];
        let r = expand_dashed_stroke(&path, &[4.0, 2.0], false);
        assert_eq!(r.len(), 2);
        assert_eq!(r[0], vec![M { x: 0.0, y: 0.0 }, L { x: 4.0, y: 0.0 }]);
        assert_eq!(r[1], vec![M { x: 5.0, y: 1.0 }, L { x: 5.0, y: 5.0 }]);
    }

    #[test]
    fn align_open_two_anchor_line_no_flex_needed() {
        let path = vec![M { x: 0.0, y: 0.0 }, L { x: 10.0, y: 0.0 }];
        let r = expand_dashed_stroke(&path, &[4.0, 2.0], true);
        assert_eq!(r.len(), 2);
        assert_eq!(r[0], vec![M { x: 0.0, y: 0.0 }, L { x: 4.0, y: 0.0 }]);
        assert_eq!(r[1], vec![M { x: 6.0, y: 0.0 }, L { x: 10.0, y: 0.0 }]);
    }

    #[test]
    fn align_open_path_endpoint_starts_with_full_dash() {
        let path = vec![M { x: 0.0, y: 0.0 }, L { x: 20.0, y: 0.0 }];
        let r = expand_dashed_stroke(&path, &[4.0, 2.0], true);
        assert!(!r.is_empty());
        assert_eq!(r[0][0], M { x: 0.0, y: 0.0 });
    }

    #[test]
    fn align_closed_rect_dash_spans_corner() {
        // 24×24 square, dash [16, 4]. Verify at least one sub-path
        // includes an interior anchor (corner) — proving the
        // anchor-stitching works.
        let path = vec![
            M { x: 0.0, y: 0.0 }, L { x: 24.0, y: 0.0 }, L { x: 24.0, y: 24.0 },
            L { x: 0.0, y: 24.0 }, Z,
        ];
        let r = expand_dashed_stroke(&path, &[16.0, 4.0], true);
        let mut spans_corner = false;
        'outer: for sub in &r {
            for (idx, cmd) in sub.iter().enumerate() {
                match cmd {
                    L { x, y } | M { x, y } => {
                        if approx_eq(*x, 24.0) && approx_eq(*y, 0.0) {
                            if idx > 0 && idx < sub.len() - 1 {
                                spans_corner = true;
                                break 'outer;
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
        assert!(spans_corner, "expected a sub-path to span the (24,0) corner");
    }

    #[test]
    fn align_open_zigzag_terminates_at_endpoint() {
        let path = vec![M { x: 0.0, y: 0.0 }, L { x: 50.0, y: 0.0 }, L { x: 50.0, y: 75.0 }];
        let r = expand_dashed_stroke(&path, &[12.0, 6.0], true);
        assert!(!r.is_empty());
        let last = r.last().unwrap();
        let last_cmd = last.last().unwrap();
        match last_cmd {
            L { x, y } => {
                assert!(approx_eq(*x, 50.0));
                assert!(approx_eq(*y, 75.0));
            }
            _ => panic!("last command should be LineTo"),
        }
    }

    #[test]
    fn determinism() {
        let path = vec![
            M { x: 0.0, y: 0.0 }, L { x: 100.0, y: 0.0 }, L { x: 100.0, y: 60.0 },
            L { x: 0.0, y: 60.0 }, Z,
        ];
        let r1 = expand_dashed_stroke(&path, &[12.0, 6.0], true);
        let r2 = expand_dashed_stroke(&path, &[12.0, 6.0], true);
        assert_eq!(r1, r2);
    }

    // ── Curve segments (DASH_ALIGN.md walk_dashes / subpath_between) ──
    //
    // The checkers below never restate the renderer's arithmetic. They
    // evaluate the ORIGINAL cubic from its Bernstein definition -- a
    // different formulation from the de-Casteljau lerps the renderer
    // splits with -- and assert that every point of every emitted dash
    // lies on THAT curve. A renderer that walked the chord instead
    // (the pre-fix behaviour, and the failure mode a lines-only engine
    // degrades to when a LineTo keeps the subpath alive) puts the whole
    // dash run on y == 0, which `bulge` catches.

    /// The reference arc: a symmetric hump from (0,0) to (60,0) whose
    /// height is exactly 30 at t = 0.5 (y(t) = 120 t (1-t)) and whose
    /// chord is the straight segment y == 0. Any answer that collapses
    /// the curve to its chord is therefore off by up to 30 units.
    const ARC: [PathCommand; 2] = [
        M { x: 0.0, y: 0.0 },
        PathCommand::CurveTo { x1: 20.0, y1: 40.0, x2: 40.0, y2: 40.0, x: 60.0, y: 0.0 },
    ];

    /// Bernstein evaluation of the ARC cubic -- the mathematical
    /// definition, independent of how the renderer subdivides.
    fn arc_point(t: f64) -> (f64, f64) {
        let (p0, p1, p2, p3) = ((0.0, 0.0), (20.0, 40.0), (40.0, 40.0), (60.0, 0.0));
        let mt = 1.0 - t;
        let b0 = mt * mt * mt;
        let b1 = 3.0 * mt * mt * t;
        let b2 = 3.0 * mt * t * t;
        let b3 = t * t * t;
        (
            b0 * p0.0 + b1 * p1.0 + b2 * p2.0 + b3 * p3.0,
            b0 * p0.1 + b1 * p1.1 + b2 * p2.1 + b3 * p3.1,
        )
    }

    /// True distance from `p` to the ARC: a coarse scan of `arc_point`
    /// to bracket the closest parameter, then a ternary search to
    /// converge on it. Refining matters — a bare 4000-sample scan
    /// bottoms out around 0.017 near the fast-moving ends, which would
    /// force a slack tolerance and blunt the checker.
    fn dist_to_arc(p: (f64, f64)) -> f64 {
        let d_at = |t: f64| {
            let q = arc_point(t);
            ((q.0 - p.0).powi(2) + (q.1 - p.1).powi(2)).sqrt()
        };
        const N: usize = 2000;
        let mut best_i = 0;
        let mut best = f64::INFINITY;
        for i in 0..=N {
            let d = d_at(i as f64 / N as f64);
            if d < best {
                best = d;
                best_i = i;
            }
        }
        let mut lo = (best_i.saturating_sub(1)) as f64 / N as f64;
        let mut hi = (best_i + 1).min(N) as f64 / N as f64;
        for _ in 0..200 {
            let m1 = lo + (hi - lo) / 3.0;
            let m2 = hi - (hi - lo) / 3.0;
            if d_at(m1) < d_at(m2) {
                hi = m2;
            } else {
                lo = m1;
            }
        }
        d_at(0.5 * (lo + hi)).min(best)
    }

    /// Every point the emitted sub-paths actually draw through: line
    /// endpoints, and cubics sampled along their own Bernstein form.
    /// Control points are excluded -- they need not lie on the curve.
    fn drawn_points(subs: &[Vec<PathCommand>]) -> Vec<(f64, f64)> {
        let mut out = Vec::new();
        for sub in subs {
            let mut cur = (0.0, 0.0);
            for cmd in sub {
                match *cmd {
                    M { x, y } | L { x, y } => {
                        out.push((x, y));
                        cur = (x, y);
                    }
                    PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                        for i in 0..=20 {
                            let t = i as f64 / 20.0;
                            let mt = 1.0 - t;
                            let (b0, b1, b2, b3) = (
                                mt * mt * mt,
                                3.0 * mt * mt * t,
                                3.0 * mt * t * t,
                                t * t * t,
                            );
                            out.push((
                                b0 * cur.0 + b1 * x1 + b2 * x2 + b3 * x,
                                b0 * cur.1 + b1 * y1 + b2 * y2 + b3 * y,
                            ));
                        }
                        cur = (x, y);
                    }
                    PathCommand::QuadTo { x1, y1, x, y } => {
                        for i in 0..=20 {
                            let t = i as f64 / 20.0;
                            let mt = 1.0 - t;
                            out.push((
                                mt * mt * cur.0 + 2.0 * mt * t * x1 + t * t * x,
                                mt * mt * cur.1 + 2.0 * mt * t * y1 + t * t * y,
                            ));
                        }
                        cur = (x, y);
                    }
                    _ => {}
                }
            }
        }
        out
    }

    fn endpoint_of(cmd: &PathCommand) -> (f64, f64) {
        match *cmd {
            M { x, y } | L { x, y } => (x, y),
            PathCommand::CurveTo { x, y, .. } => (x, y),
            PathCommand::QuadTo { x, y, .. } => (x, y),
            _ => (f64::NAN, f64::NAN),
        }
    }

    /// THE ARTIST-VISIBLE DEFECT. Draw a curve, dash it, switch the
    /// Stroke panel to align-to-anchors: the whole stroke disappears.
    /// A bare open cubic has no LineTo and no ClosePath, so a
    /// lines-only engine finds "no segments" and emits nothing.
    #[test]
    fn align_open_cubic_is_not_dropped() {
        let r = expand_dashed_stroke(&ARC, &[12.0, 6.0], true);
        assert!(!r.is_empty(), "an open cubic must still produce dashes");
    }

    /// Preserve mode drops it too -- the pure function is blind to
    /// curves in BOTH modes. (Only align is artist-visible, because the
    /// canvas renderer routes preserve mode to the platform's own dash
    /// array and never calls this function.)
    #[test]
    fn preserve_open_cubic_is_not_dropped() {
        let r = expand_dashed_stroke(&ARC, &[12.0, 6.0], false);
        assert!(!r.is_empty(), "an open cubic must still produce dashes");
    }

    /// A closed cubic -- Z makes it look like it "has segments", but
    /// the anchor walk then finds a single point and folds to nothing.
    #[test]
    fn align_closed_cubic_is_not_dropped() {
        let mut path = ARC.to_vec();
        path.push(Z);
        let r = expand_dashed_stroke(&path, &[12.0, 6.0], true);
        assert!(!r.is_empty(), "a closed cubic must still produce dashes");
    }

    /// The dashes must ride the curve, and they must be curves.
    #[test]
    fn align_open_cubic_dashes_ride_the_curve() {
        let r = expand_dashed_stroke(&ARC, &[12.0, 6.0], true);
        assert!(!r.is_empty());
        for p in drawn_points(&r) {
            let d = dist_to_arc(p);
            assert!(d < 1e-6, "drawn point {p:?} is {d} off the curve");
        }
        let bulge = drawn_points(&r).iter().fold(0.0_f64, |m, p| m.max(p.1.abs()));
        assert!(bulge > 20.0, "dashes hug the chord (max |y| = {bulge}), not the arc");
        assert!(
            r.iter().flatten().any(|c| matches!(c, PathCommand::CurveTo { .. })),
            "a dash over a cubic must be emitted as a cubic (DASH_ALIGN.md subpath_between)"
        );
    }

    /// EE boundary: a single open segment gets a full dash at each end,
    /// so the run starts exactly at the curve start and finishes
    /// exactly at the curve end.
    #[test]
    fn align_open_cubic_starts_and_ends_on_the_endpoints() {
        let r = expand_dashed_stroke(&ARC, &[12.0, 6.0], true);
        assert!(!r.is_empty());
        let first = endpoint_of(&r[0][0]);
        assert!(approx_eq(first.0, 0.0) && approx_eq(first.1, 0.0), "got {first:?}");
        let last = endpoint_of(r.last().unwrap().last().unwrap());
        assert!(approx_eq(last.0, 60.0) && approx_eq(last.1, 0.0), "got {last:?}");
    }

    /// The silent-wrong-answer sibling: a curve followed by a line
    /// survives the "has segments" screen, so nothing vanishes -- the
    /// curve is just quietly replaced by its chord. Arc length and
    /// geometry are both wrong, and the curve's own endpoint is not
    /// treated as an alignment anchor.
    #[test]
    fn align_cubic_then_line_keeps_the_curve_and_anchors_its_endpoint() {
        let mut path = ARC.to_vec();
        path.push(L { x: 90.0, y: 0.0 });
        let r = expand_dashed_stroke(&path, &[12.0, 6.0], true);
        assert!(!r.is_empty());

        // Points on the cubic half must lie on the cubic.
        let bulge = drawn_points(&r).iter().fold(0.0_f64, |m, p| m.max(p.1.abs()));
        assert!(bulge > 20.0, "the cubic was flattened to its chord (max |y| = {bulge})");

        // (60,0) is an interior anchor -> a dash is centered on it, so
        // some sub-path crosses it rather than starting or ending there.
        let mut spans = false;
        for sub in &r {
            for (idx, cmd) in sub.iter().enumerate() {
                let p = endpoint_of(cmd);
                if approx_eq(p.0, 60.0) && approx_eq(p.1, 0.0)
                    && idx > 0 && idx < sub.len() - 1
                {
                    spans = true;
                }
            }
        }
        assert!(spans, "a dash must be centered on the curve's own endpoint anchor");
    }
    // S-4: a leading ClosePath is a no-op. Ruled by JYH at the fleet
    // council, 2026-07-27. A subpath that is nothing but Z establishes
    // no anchor and produces no dash. Rust already behaved this way when
    // these were written -- `expand_preserve` and `expand_align` both
    // guard the cyclic wrap on `!anchors.is_empty()`, and `expand_align`
    // guards `n_segs` with `saturating_sub` -- so these are regression
    // pins, not a fix. The live reference raised IndexError on the same
    // inputs; these are its counterparts.

    #[test]
    fn leading_close_bare_produces_no_dash_preserve() {
        assert!(expand_dashed_stroke(&[Z], &[4.0, 2.0], false).is_empty());
    }

    #[test]
    fn leading_close_bare_produces_no_dash_align() {
        assert!(expand_dashed_stroke(&[Z], &[4.0, 2.0], true).is_empty());
    }

    /// A leading Z is a no-op, not a poison pill: the subpath after it
    /// still dashes. Asserted as equality against the same path WITHOUT
    /// the leading Z, so an implementation that bailed out early and
    /// returned nothing would fail rather than pass vacuously. The
    /// companion length assertion below keeps the equality non-vacuous.
    #[test]
    fn leading_close_does_not_suppress_the_real_subpath() {
        let real = vec![M { x: 0.0, y: 0.0 }, L { x: 20.0, y: 0.0 }];
        let with_z = {
            let mut v = vec![Z];
            v.extend(real.iter().cloned());
            v
        };
        for align in [false, true] {
            let a = expand_dashed_stroke(&with_z, &[4.0, 2.0], align);
            let b = expand_dashed_stroke(&real, &[4.0, 2.0], align);
            assert_eq!(a, b, "align={align}");
            assert_eq!(a.len(), 4, "align={align}");
        }
    }

}

