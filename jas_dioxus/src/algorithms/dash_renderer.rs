//! Dash-alignment renderer for stroked paths.
//!
//! Pure function: given a path, a dash array, and an alignment flag,
//! return a list of solid sub-paths to draw. Implements DASH_ALIGN.md
//! §Algorithm — port of `workspace_interpreter/dash_renderer.py`.
//! Keep in lockstep on the conversion table and rounding rules.
//!
//! Phase 4 ships lines-only support (MoveTo / LineTo / ClosePath).
//! Curve segments will join in a follow-up phase that adds De
//! Casteljau subdivision; the API stays unchanged.
//!
//! Output: a `Vec<Vec<PathCommand>>` where each inner `Vec` is one
//! solid sub-path representing one dash. Sub-paths are emitted in
//! arc-length order. The caller draws each sub-path with the
//! existing solid-stroke pipeline (no `stroke-dasharray` /
//! `setLineDash`).

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
        if !has_segments(sp) {
            continue;
        }
        if align_anchors {
            result.extend(expand_align(sp, &pattern));
        } else {
            result.extend(expand_preserve(sp, &pattern));
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

fn has_segments(subpath: &[PathCommand]) -> bool {
    subpath.iter().any(|c| matches!(
        c,
        PathCommand::LineTo { .. } | PathCommand::ClosePath
    ))
}

fn is_closed(subpath: &[PathCommand]) -> bool {
    subpath.iter().any(|c| matches!(c, PathCommand::ClosePath))
}

fn anchor_points(subpath: &[PathCommand]) -> Vec<(f64, f64)> {
    let mut pts = Vec::new();
    for cmd in subpath {
        match cmd {
            PathCommand::MoveTo { x, y } | PathCommand::LineTo { x, y } => {
                pts.push((*x, *y));
            }
            _ => {}
        }
    }
    pts
}

fn seg_len(a: (f64, f64), b: (f64, f64)) -> f64 {
    let dx = b.0 - a.0;
    let dy = b.1 - a.1;
    (dx * dx + dy * dy).sqrt()
}

// ── Preserve mode ────────────────────────────────────────────────

fn expand_preserve(
    subpath: &[PathCommand],
    pattern: &[f64],
) -> Vec<Vec<PathCommand>> {
    let anchors = anchor_points(subpath);
    let anchors_walk: Vec<(f64, f64)> = if is_closed(subpath) {
        let mut a = anchors.clone();
        if !anchors.is_empty() {
            a.push(anchors[0]);
        }
        a
    } else {
        anchors.clone()
    };
    if anchors_walk.len() < 2 {
        return Vec::new();
    }
    let seg_lengths: Vec<f64> = anchors_walk
        .windows(2)
        .map(|w| seg_len(w[0], w[1]))
        .collect();
    let mut cum = vec![0.0];
    let mut s = 0.0;
    for &l in &seg_lengths {
        s += l;
        cum.push(s);
    }
    let total = *cum.last().unwrap_or(&0.0);
    if total <= 0.0 {
        return Vec::new();
    }
    emit_dashes(&anchors_walk, &cum, pattern, 0.0, 0.0, total)
}

// ── Align mode ───────────────────────────────────────────────────

fn expand_align(
    subpath: &[PathCommand],
    pattern: &[f64],
) -> Vec<Vec<PathCommand>> {
    let anchors = anchor_points(subpath);
    let closed = is_closed(subpath);
    let anchors_walk: Vec<(f64, f64)> = if closed {
        let mut a = anchors.clone();
        if !anchors.is_empty() {
            a.push(anchors[0]);
        }
        a
    } else {
        anchors.clone()
    };
    let n_segs = anchors_walk.len().saturating_sub(1);
    if n_segs == 0 {
        return Vec::new();
    }
    let base_period: f64 = pattern.iter().sum();
    if base_period <= 0.0 {
        return Vec::new();
    }
    let seg_lengths: Vec<f64> = anchors_walk
        .windows(2)
        .map(|w| seg_len(w[0], w[1]))
        .collect();
    if seg_lengths.iter().all(|&l| l <= 0.0) {
        return Vec::new();
    }
    let mut cum = vec![0.0];
    let mut s = 0.0;
    for &l in &seg_lengths {
        s += l;
        cum.push(s);
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
        if let Some(sub) = subpath_between_wrapping(&anchors_walk, &cum, gs, ge, closed) {
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
    anchors: &[(f64, f64)],
    cum: &[f64],
    t0: f64,
    t1: f64,
    closed: bool,
) -> Option<Vec<PathCommand>> {
    let total = *cum.last().unwrap_or(&0.0);
    if !closed || t1 <= total + EPS {
        return subpath_between(anchors, cum, t0, t1.min(total));
    }
    let head = subpath_between(anchors, cum, t0, total);
    let tail = subpath_between(anchors, cum, 0.0, t1 - total);
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

fn subpath_between(
    anchors: &[(f64, f64)],
    cum: &[f64],
    t0: f64,
    t1: f64,
) -> Option<Vec<PathCommand>> {
    if t1 <= t0 + EPS {
        return None;
    }
    let p0 = interpolate(anchors, cum, t0);
    let p1 = interpolate(anchors, cum, t1);
    let i = locate_segment(cum, t0);
    let j = locate_segment(cum, t1);
    let mut cmds: Vec<PathCommand> = Vec::with_capacity((j - i).saturating_add(2));
    cmds.push(PathCommand::MoveTo { x: p0.0, y: p0.1 });
    for k in (i + 1)..=j {
        cmds.push(PathCommand::LineTo { x: anchors[k].0, y: anchors[k].1 });
    }
    let last = cmds.last().copied().unwrap();
    let (last_x, last_y) = match last {
        PathCommand::MoveTo { x, y } | PathCommand::LineTo { x, y } => (x, y),
        _ => (p1.0, p1.1),
    };
    if (last_x - p1.0).abs() > 1e-9 || (last_y - p1.1).abs() > 1e-9 {
        cmds.push(PathCommand::LineTo { x: p1.0, y: p1.1 });
    }
    Some(cmds)
}

fn interpolate(anchors: &[(f64, f64)], cum: &[f64], t: f64) -> (f64, f64) {
    if t <= 0.0 {
        return anchors[0];
    }
    let total = *cum.last().unwrap_or(&0.0);
    if t >= total {
        return *anchors.last().unwrap();
    }
    let i = locate_segment(cum, t);
    let seg_l = cum[i + 1] - cum[i];
    if seg_l <= 0.0 {
        return anchors[i];
    }
    let alpha = (t - cum[i]) / seg_l;
    let a = anchors[i];
    let b = anchors[i + 1];
    (a.0 + alpha * (b.0 - a.0), a.1 + alpha * (b.1 - a.1))
}

fn locate_segment(cum: &[f64], t: f64) -> usize {
    let n = cum.len() - 1;
    if t <= cum[0] {
        return 0;
    }
    if t >= cum[cum.len() - 1] {
        return n - 1;
    }
    for i in 0..n {
        if cum[i] <= t && t < cum[i + 1] {
            return i;
        }
    }
    n - 1
}

fn emit_dashes(
    anchors_walk: &[(f64, f64)],
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
            if let Some(sub) = subpath_between(anchors_walk, cum, t, next_t) {
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
}
