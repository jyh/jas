// Affine transform builders for the Scale / Rotate / Shear tools.
//
// Each public function returns a 2×3 affine `Transform` (from
// Geometry/Element.swift) that composes:
//
//   1. Transform.translate(-rx, -ry) — move the reference point to
//      the origin.
//   2. The tool-specific base transform (scale / rotate / shear).
//   3. Transform.translate(rx, ry) — move the reference point back.
//
// The composition is delegated to `Transform.aroundPoint` so every
// tool's matrix pivots around the same reference point.
//
// See SCALE_TOOL.md / ROTATE_TOOL.md / SHEAR_TOOL.md §Apply behavior.

import Foundation

public enum TransformApply {

    /// Scale matrix: (sx, sy) factors applied around (rx, ry).
    /// Negative factors flip the selection on that axis. A factor
    /// of 1.0 on both axes is the identity transform.
    public static func scaleMatrix(sx: Double, sy: Double,
                                   rx: Double, ry: Double) -> Transform {
        Transform.scale(sx, sy).aroundPoint(rx, ry)
    }

    /// Rotation matrix: thetaDeg degrees CCW around (rx, ry).
    /// thetaDeg = 0.0 is the identity transform.
    public static func rotateMatrix(thetaDeg: Double,
                                    rx: Double, ry: Double) -> Transform {
        Transform.rotate(thetaDeg).aroundPoint(rx, ry)
    }

    /// Shear matrix: angleDeg degrees of slant along axis around
    /// (rx, ry). Axis is "horizontal", "vertical", or "custom".
    /// When custom, axisAngleDeg is the axis direction in degrees
    /// from horizontal.
    ///
    /// The shear factor is tan(angleDeg). Angles approaching ±90°
    /// become unstable; callers clamp to a reasonable range (the
    /// dialog uses ±89.9°).
    public static func shearMatrix(angleDeg: Double, axis: String,
                                   axisAngleDeg: Double,
                                   rx: Double, ry: Double) -> Transform {
        let k = tan(angleDeg * .pi / 180)
        let base: Transform
        switch axis {
        case "horizontal":
            base = Transform.shear(k, 0)
        case "vertical":
            base = Transform.shear(0, k)
        case "custom":
            // Custom-axis shear = R(-axisAngle) * shear(k, 0) * R(axisAngle).
            // The selection is rotated so the custom axis becomes
            // horizontal, sheared horizontally, then rotated back.
            let rBack = Transform.rotate(axisAngleDeg)
            let rFwd = Transform.rotate(-axisAngleDeg)
            let s = Transform.shear(k, 0)
            base = rBack.multiply(s).multiply(rFwd)
        default:
            base = Transform.identity
        }
        return base.aroundPoint(rx, ry)
    }

    /// Geometric mean of (sx, sy) for use as the stroke-width
    /// multiplier under non-uniform scaling. Always returns a
    /// non-negative value (strokes don't flip).
    ///
    /// See SCALE_TOOL.md §Apply behavior — "Stroke width: when
    /// state.scale_strokes is true, multiply by the unsigned
    /// geometric mean √(|sx · sy|)."
    public static func strokeWidthFactor(sx: Double, sy: Double) -> Double {
        sqrt(abs(sx) * abs(sy))
    }
}
