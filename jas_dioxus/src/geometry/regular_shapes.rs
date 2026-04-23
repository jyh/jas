//! Shape-geometry helpers for regular polygons and stars.
//!
//! These functions were originally inlined in `tools/polygon_tool.rs`
//! and `tools/star_tool.rs`. When those native tools were migrated
//! to YAML-driven YamlTool (see RUST_TOOL_RUNTIME.md), the geometry
//! moved here so it survives the deletion and stays available both
//! to the `polygon` / `star` arms of `interpreter::effects::build_element`
//! and to the matching overlay render types in `tools::yaml_tool`.
//!
//! Per NATIVE_BOUNDARY.md §5 ("Domain (L2) primitives"), shape
//! geometry is legitimately native — it's a universal vector-app
//! primitive, not app-specific behavior.

use std::f64::consts::PI;

/// Ratio of inner radius to outer radius for the default star.
pub const STAR_INNER_RATIO: f64 = 0.4;

/// Compute vertices of a regular N-gon whose first edge runs from
/// `(x1, y1)` to `(x2, y2)`. Returns a `Vec` of `n` `(x, y)` pairs.
///
/// For `n < 3`, the result is geometrically degenerate but still
/// well-defined (the formula still returns `n` points around a
/// computed center). Callers should validate `n >= 3` upstream.
pub fn regular_polygon_points(
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    n: usize,
) -> Vec<(f64, f64)> {
    let ex = x2 - x1;
    let ey = y2 - y1;
    let s = (ex * ex + ey * ey).sqrt();
    if s == 0.0 {
        return vec![(x1, y1); n];
    }
    let mx = (x1 + x2) / 2.0;
    let my = (y1 + y2) / 2.0;
    let px = -ey / s;
    let py = ex / s;
    let d = s / (2.0 * (PI / n as f64).tan());
    let cx = mx + d * px;
    let cy = my + d * py;
    let r = s / (2.0 * (PI / n as f64).sin());
    let theta0 = (y1 - cy).atan2(x1 - cx);
    (0..n)
        .map(|k| {
            let angle = theta0 + 2.0 * PI * k as f64 / n as f64;
            (cx + r * angle.cos(), cy + r * angle.sin())
        })
        .collect()
}

/// Compute vertices of a star inscribed in the axis-aligned bounding
/// box with corners `(sx, sy)` and `(ex, ey)`. `points` is the number
/// of outer vertices; the returned `Vec` alternates outer / inner
/// points for `2 * points` total. Outer radius matches the bounding
/// box; inner radius is `STAR_INNER_RATIO × outer`. First outer point
/// sits at the top-center of the bounding box.
pub fn star_points(
    sx: f64,
    sy: f64,
    ex: f64,
    ey: f64,
    points: usize,
) -> Vec<(f64, f64)> {
    let cx = (sx + ex) / 2.0;
    let cy = (sy + ey) / 2.0;
    let rx_outer = (ex - sx).abs() / 2.0;
    let ry_outer = (ey - sy).abs() / 2.0;
    let rx_inner = rx_outer * STAR_INNER_RATIO;
    let ry_inner = ry_outer * STAR_INNER_RATIO;
    let n = points * 2;
    let theta0 = -PI / 2.0;
    (0..n)
        .map(|k| {
            let angle = theta0 + PI * k as f64 / points as f64;
            let (rx, ry) = if k % 2 == 0 {
                (rx_outer, ry_outer)
            } else {
                (rx_inner, ry_inner)
            };
            (cx + rx * angle.cos(), cy + ry * angle.sin())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn star_points_count_is_double_outer() {
        let pts = star_points(0.0, 0.0, 100.0, 100.0, 5);
        assert_eq!(pts.len(), 10);
    }

    #[test]
    fn star_points_first_at_top() {
        let pts = star_points(0.0, 0.0, 100.0, 100.0, 5);
        assert!((pts[0].0 - 50.0).abs() < 1e-9);
        assert!((pts[0].1 - 0.0).abs() < 1e-9);
    }

    #[test]
    fn star_points_alternate_inner_outer() {
        let pts = star_points(0.0, 0.0, 100.0, 100.0, 5);
        let center = (50.0, 50.0);
        for (i, (x, y)) in pts.iter().enumerate() {
            let dx = x - center.0;
            let dy = y - center.1;
            let r = (dx * dx + dy * dy).sqrt();
            let expected = if i % 2 == 0 { 50.0 } else { 20.0 };
            assert!(
                (r - expected).abs() < 1e-9,
                "point {} radius {} != {}",
                i, r, expected,
            );
        }
    }

    #[test]
    fn regular_polygon_first_edge_matches_input() {
        let pts = regular_polygon_points(0.0, 0.0, 10.0, 0.0, 5);
        assert_eq!(pts.len(), 5);
        // First vertex is (x1, y1) up to floating-point noise.
        assert!((pts[0].0 - 0.0).abs() < 1e-9);
        assert!((pts[0].1 - 0.0).abs() < 1e-9);
        // Second vertex is (x2, y2) — the other end of the first edge.
        assert!((pts[1].0 - 10.0).abs() < 1e-9);
        assert!((pts[1].1 - 0.0).abs() < 1e-9);
    }

    #[test]
    fn regular_polygon_zero_length_edge_returns_repeated_point() {
        // Degenerate input: both endpoints coincide.
        let pts = regular_polygon_points(5.0, 7.0, 5.0, 7.0, 5);
        assert_eq!(pts.len(), 5);
        for p in &pts {
            assert_eq!(*p, (5.0, 7.0));
        }
    }
}
