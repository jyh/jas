//! Affine transform builders for the Scale / Rotate / Shear tools.
//!
//! Each public function returns a 2×3 affine `Transform` (from
//! `geometry::element`) that composes:
//!
//! 1. `Transform::translate(-rx, -ry)` — move the reference point to
//!    the origin.
//! 2. The tool-specific base transform (scale / rotate / shear).
//! 3. `Transform::translate(rx, ry)` — move the reference point back.
//!
//! The composition is delegated to [`Transform::around_point`] so
//! every tool's matrix pivots around the same reference point.
//!
//! See SCALE_TOOL.md / ROTATE_TOOL.md / SHEAR_TOOL.md §Apply behavior.

use crate::geometry::element::Transform;

/// Scale matrix: `(sx, sy)` factors applied around `(rx, ry)`.
///
/// Negative factors flip the selection on that axis. A factor of
/// `1.0` on both axes is the identity transform.
pub fn scale_matrix(sx: f64, sy: f64, rx: f64, ry: f64) -> Transform {
    Transform::scale(sx, sy).around_point(rx, ry)
}

/// Rotation matrix: `theta_deg` degrees CCW around `(rx, ry)`.
///
/// `theta_deg = 0.0` is the identity transform. Positive values
/// rotate counter-clockwise.
pub fn rotate_matrix(theta_deg: f64, rx: f64, ry: f64) -> Transform {
    Transform::rotate(theta_deg).around_point(rx, ry)
}

/// Shear matrix: `angle_deg` degrees of slant along `axis` around
/// `(rx, ry)`.
///
/// Axis values:
/// - `"horizontal"` — points slide horizontally; y-axis fixed.
/// - `"vertical"`   — points slide vertically; x-axis fixed.
/// - `"custom"`     — `axis_angle_deg` degrees from horizontal.
///
/// The shear factor is `tan(angle_deg)`. Angles approaching ±90°
/// become unstable; callers are expected to clamp to a reasonable
/// range (the dialog uses ±89.9°).
pub fn shear_matrix(
    angle_deg: f64,
    axis: &str,
    axis_angle_deg: f64,
    rx: f64,
    ry: f64,
) -> Transform {
    let k = angle_deg.to_radians().tan();
    let base = match axis {
        "horizontal" => Transform::shear(k, 0.0),
        "vertical" => Transform::shear(0.0, k),
        "custom" => {
            // Custom-axis shear = R(-axis_angle) * shear(k, 0) * R(axis_angle).
            // The selection is rotated so the custom axis becomes
            // horizontal, sheared horizontally, then rotated back.
            let r_back = Transform::rotate(axis_angle_deg);
            let r_fwd = Transform::rotate(-axis_angle_deg);
            let s = Transform::shear(k, 0.0);
            r_back.multiply(&s).multiply(&r_fwd)
        }
        _ => Transform::IDENTITY,
    };
    base.around_point(rx, ry)
}

/// Geometric mean of `(sx, sy)` for use as the stroke-width
/// multiplier under non-uniform scaling. Always returns a
/// non-negative value (strokes don't flip).
///
/// See SCALE_TOOL.md §Apply behavior — "Stroke width: when
/// state.scale_strokes is true, multiply by the unsigned geometric
/// mean √(|sx · sy|)."
pub fn stroke_width_factor(sx: f64, sy: f64) -> f64 {
    (sx.abs() * sy.abs()).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx_eq(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    fn point_approx(p: (f64, f64), expected: (f64, f64)) {
        assert!(
            approx_eq(p.0, expected.0) && approx_eq(p.1, expected.1),
            "got ({:.6}, {:.6}), expected ({:.6}, {:.6})",
            p.0,
            p.1,
            expected.0,
            expected.1,
        );
    }

    // ── Scale matrix ─────────────────────────────────────────────

    #[test]
    fn scale_identity_at_unit_factors() {
        let m = scale_matrix(1.0, 1.0, 50.0, 50.0);
        point_approx(m.apply_point(10.0, 20.0), (10.0, 20.0));
        point_approx(m.apply_point(0.0, 0.0), (0.0, 0.0));
    }

    #[test]
    fn scale_uniform_around_origin() {
        let m = scale_matrix(2.0, 2.0, 0.0, 0.0);
        point_approx(m.apply_point(3.0, 5.0), (6.0, 10.0));
    }

    #[test]
    fn scale_uniform_around_ref_point() {
        // Reference point stays put; everything else doubles
        // distance.
        let m = scale_matrix(2.0, 2.0, 100.0, 100.0);
        point_approx(m.apply_point(100.0, 100.0), (100.0, 100.0));
        point_approx(m.apply_point(110.0, 100.0), (120.0, 100.0));
        point_approx(m.apply_point(100.0, 90.0), (100.0, 80.0));
    }

    #[test]
    fn scale_non_uniform() {
        let m = scale_matrix(2.0, 0.5, 0.0, 0.0);
        point_approx(m.apply_point(4.0, 4.0), (8.0, 2.0));
    }

    #[test]
    fn scale_negative_flips() {
        let m = scale_matrix(-1.0, 1.0, 0.0, 0.0);
        point_approx(m.apply_point(5.0, 7.0), (-5.0, 7.0));
    }

    // ── Rotate matrix ────────────────────────────────────────────

    #[test]
    fn rotate_zero_is_identity() {
        let m = rotate_matrix(0.0, 50.0, 50.0);
        point_approx(m.apply_point(10.0, 20.0), (10.0, 20.0));
    }

    #[test]
    fn rotate_90_around_origin() {
        // (1, 0) → (0, 1) under a 90° CCW rotation in image-space.
        let m = rotate_matrix(90.0, 0.0, 0.0);
        point_approx(m.apply_point(1.0, 0.0), (0.0, 1.0));
    }

    #[test]
    fn rotate_180_around_ref_point() {
        let m = rotate_matrix(180.0, 50.0, 50.0);
        point_approx(m.apply_point(50.0, 50.0), (50.0, 50.0));
        point_approx(m.apply_point(60.0, 50.0), (40.0, 50.0));
        point_approx(m.apply_point(50.0, 60.0), (50.0, 40.0));
    }

    // ── Shear matrix ─────────────────────────────────────────────

    #[test]
    fn shear_zero_angle_is_identity() {
        let m = shear_matrix(0.0, "horizontal", 0.0, 50.0, 50.0);
        point_approx(m.apply_point(10.0, 20.0), (10.0, 20.0));
    }

    #[test]
    fn shear_horizontal_at_45_around_origin() {
        // tan(45°) = 1; horizontal shear: x' = x + y, y' = y.
        let m = shear_matrix(45.0, "horizontal", 0.0, 0.0, 0.0);
        point_approx(m.apply_point(0.0, 10.0), (10.0, 10.0));
        point_approx(m.apply_point(5.0, 0.0), (5.0, 0.0));
    }

    #[test]
    fn shear_vertical_at_45_around_origin() {
        // tan(45°) = 1; vertical shear: x' = x, y' = y + x.
        let m = shear_matrix(45.0, "vertical", 0.0, 0.0, 0.0);
        point_approx(m.apply_point(10.0, 0.0), (10.0, 10.0));
        point_approx(m.apply_point(0.0, 5.0), (0.0, 5.0));
    }

    #[test]
    fn shear_horizontal_around_ref_point() {
        // tan(45°) shear horizontally around (50, 50). Reference
        // point stays put.
        let m = shear_matrix(45.0, "horizontal", 0.0, 50.0, 50.0);
        point_approx(m.apply_point(50.0, 50.0), (50.0, 50.0));
        // A point one unit above the ref shears one unit right.
        point_approx(m.apply_point(50.0, 49.0), (49.0, 49.0));
    }

    #[test]
    fn shear_custom_axis_at_zero_matches_horizontal() {
        let custom = shear_matrix(30.0, "custom", 0.0, 0.0, 0.0);
        let horizontal = shear_matrix(30.0, "horizontal", 0.0, 0.0, 0.0);
        point_approx(custom.apply_point(7.0, 11.0), horizontal.apply_point(7.0, 11.0));
    }

    #[test]
    fn shear_unknown_axis_returns_identity() {
        let m = shear_matrix(45.0, "diagonal", 0.0, 0.0, 0.0);
        point_approx(m.apply_point(10.0, 20.0), (10.0, 20.0));
    }

    // ── Stroke width factor ──────────────────────────────────────

    #[test]
    fn stroke_factor_uniform() {
        assert!(approx_eq(stroke_width_factor(2.0, 2.0), 2.0));
        assert!(approx_eq(stroke_width_factor(0.5, 0.5), 0.5));
    }

    #[test]
    fn stroke_factor_geometric_mean() {
        // sqrt(2 * 8) = sqrt(16) = 4
        assert!(approx_eq(stroke_width_factor(2.0, 8.0), 4.0));
    }

    #[test]
    fn stroke_factor_negative_factors_use_abs() {
        // sqrt(|-2| * |3|) = sqrt(6)
        let expected = 6.0_f64.sqrt();
        assert!(approx_eq(stroke_width_factor(-2.0, 3.0), expected));
    }

    // ── Transform composition ────────────────────────────────────

    #[test]
    fn around_point_translate_no_op_at_origin() {
        // Translate around origin == translate.
        let t = Transform::translate(5.0, 7.0);
        let m = t.around_point(0.0, 0.0);
        point_approx(m.apply_point(0.0, 0.0), (5.0, 7.0));
    }

    #[test]
    fn multiply_associative_basic_case() {
        let a = Transform::translate(10.0, 0.0);
        let b = Transform::scale(2.0, 2.0);
        let c = Transform::translate(0.0, 5.0);
        let left = a.multiply(&b).multiply(&c);
        let right = a.multiply(&b.multiply(&c));
        point_approx(left.apply_point(3.0, 4.0), right.apply_point(3.0, 4.0));
    }
}
