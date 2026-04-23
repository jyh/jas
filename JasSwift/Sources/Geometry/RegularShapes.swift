// Shape-geometry helpers for regular polygons and stars — the Swift
// analogue of jas_dioxus/src/geometry/regular_shapes.rs.
//
// L2 primitives per NATIVE_BOUNDARY.md §5: shape geometry is shared
// across vector-illustration apps, not app-specific behavior.

import Foundation

/// Ratio of inner radius to outer radius for the default star.
public let starInnerRatio: Double = 0.4

/// Compute vertices of a regular N-gon whose first edge runs from
/// `(x1, y1)` to `(x2, y2)`. Returns `n` (x, y) pairs. For degenerate
/// zero-length edges returns `n` copies of the start point.
public func regularPolygonPoints(
    _ x1: Double, _ y1: Double,
    _ x2: Double, _ y2: Double,
    _ n: Int
) -> [(Double, Double)] {
    let ex = x2 - x1
    let ey = y2 - y1
    let s = (ex * ex + ey * ey).squareRoot()
    if s == 0 {
        return Array(repeating: (x1, y1), count: n)
    }
    let mx = (x1 + x2) / 2
    let my = (y1 + y2) / 2
    let px = -ey / s
    let py = ex / s
    let d = s / (2 * tan(.pi / Double(n)))
    let cx = mx + d * px
    let cy = my + d * py
    let r = s / (2 * sin(.pi / Double(n)))
    let theta0 = atan2(y1 - cy, x1 - cx)
    return (0..<n).map { k in
        let angle = theta0 + 2 * .pi * Double(k) / Double(n)
        return (cx + r * cos(angle), cy + r * sin(angle))
    }
}

/// Compute vertices of a star inscribed in the axis-aligned bounding
/// box with corners `(sx, sy)` and `(ex, ey)`. `points` is the number
/// of outer vertices; the returned array alternates outer / inner
/// points for `2 * points` total. First outer point sits at top-center.
public func starPoints(
    _ sx: Double, _ sy: Double,
    _ ex: Double, _ ey: Double,
    _ points: Int
) -> [(Double, Double)] {
    let cx = (sx + ex) / 2
    let cy = (sy + ey) / 2
    let rxOuter = abs(ex - sx) / 2
    let ryOuter = abs(ey - sy) / 2
    let rxInner = rxOuter * starInnerRatio
    let ryInner = ryOuter * starInnerRatio
    let n = points * 2
    let theta0 = -Double.pi / 2
    return (0..<n).map { k in
        let angle = theta0 + .pi * Double(k) / Double(points)
        let (rx, ry) = (k % 2 == 0)
            ? (rxOuter, ryOuter) : (rxInner, ryInner)
        return (cx + rx * cos(angle), cy + ry * sin(angle))
    }
}
