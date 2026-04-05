//! Path measurement utilities: arc lengths, point-at-offset, closest-offset.

use super::element::{flatten_path_commands, PathCommand};

/// Compute cumulative arc lengths for a polyline.
pub fn arc_lengths(pts: &[(f64, f64)]) -> Vec<f64> {
    let mut lengths = vec![0.0];
    for i in 1..pts.len() {
        let dx = pts[i].0 - pts[i - 1].0;
        let dy = pts[i].1 - pts[i - 1].1;
        lengths.push(lengths[i - 1] + (dx * dx + dy * dy).sqrt());
    }
    lengths
}

/// Return the (x, y) point at fraction t (0..1) along the path.
pub fn path_point_at_offset(d: &[PathCommand], t: f64) -> (f64, f64) {
    let pts = flatten_path_commands(d);
    if pts.len() < 2 {
        return pts.first().copied().unwrap_or((0.0, 0.0));
    }
    let lengths = arc_lengths(&pts);
    let total = *lengths.last().unwrap();
    if total == 0.0 {
        return pts[0];
    }
    let target = t.clamp(0.0, 1.0) * total;
    for i in 1..lengths.len() {
        if lengths[i] >= target {
            let seg_len = lengths[i] - lengths[i - 1];
            if seg_len == 0.0 {
                return pts[i];
            }
            let frac = (target - lengths[i - 1]) / seg_len;
            let x = pts[i - 1].0 + frac * (pts[i].0 - pts[i - 1].0);
            let y = pts[i - 1].1 + frac * (pts[i].1 - pts[i - 1].1);
            return (x, y);
        }
    }
    *pts.last().unwrap()
}

/// Return the offset (0..1) of the closest point on the path to (px, py).
pub fn path_closest_offset(d: &[PathCommand], px: f64, py: f64) -> f64 {
    let pts = flatten_path_commands(d);
    if pts.len() < 2 {
        return 0.0;
    }
    let lengths = arc_lengths(&pts);
    let total = *lengths.last().unwrap();
    if total == 0.0 {
        return 0.0;
    }
    let mut best_dist = f64::INFINITY;
    let mut best_offset = 0.0;
    for i in 1..pts.len() {
        let (ax, ay) = pts[i - 1];
        let (bx, by) = pts[i];
        let dx = bx - ax;
        let dy = by - ay;
        let seg_len_sq = dx * dx + dy * dy;
        if seg_len_sq == 0.0 {
            continue;
        }
        let t = ((px - ax) * dx + (py - ay) * dy) / seg_len_sq;
        let t = t.clamp(0.0, 1.0);
        let qx = ax + t * dx;
        let qy = ay + t * dy;
        let dist = ((px - qx).powi(2) + (py - qy).powi(2)).sqrt();
        if dist < best_dist {
            best_dist = dist;
            let seg_arc = lengths[i - 1] + t * (lengths[i] - lengths[i - 1]);
            best_offset = seg_arc / total;
        }
    }
    best_offset
}

/// Return the minimum distance from point (px, py) to the path curve.
pub fn path_distance_to_point(d: &[PathCommand], px: f64, py: f64) -> f64 {
    let pts = flatten_path_commands(d);
    if pts.len() < 2 {
        return pts
            .first()
            .map(|(x, y)| ((px - x).powi(2) + (py - y).powi(2)).sqrt())
            .unwrap_or(f64::INFINITY);
    }
    let mut best_dist = f64::INFINITY;
    for i in 1..pts.len() {
        let (ax, ay) = pts[i - 1];
        let (bx, by) = pts[i];
        let dx = bx - ax;
        let dy = by - ay;
        let seg_len_sq = dx * dx + dy * dy;
        if seg_len_sq == 0.0 {
            continue;
        }
        let t = ((px - ax) * dx + (py - ay) * dy) / seg_len_sq;
        let t = t.clamp(0.0, 1.0);
        let qx = ax + t * dx;
        let qy = ay + t * dy;
        let dist = ((px - qx).powi(2) + (py - qy).powi(2)).sqrt();
        if dist < best_dist {
            best_dist = dist;
        }
    }
    best_dist
}
