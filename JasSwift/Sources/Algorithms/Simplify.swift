import Foundation

// Polyline-to-Bezier simplification with corner detection.
//
// Wraps `fitCurve` (Schneider 1990, FitCurve.swift) so it can be
// applied to a closed or open polyline that mixes straight runs and
// smooth arcs. The wrapper:
//
// 1. Detects "corners" — vertices where the direction changes by more
//    than `cornerAngleThreshold` (default 30 degrees). Boolean
//    operation outputs preserve original sharp corners but flatten
//    arcs into many short segments; fitting one curve across a corner
//    would round it off, so corners must split the polyline into
//    per-segment runs before fitting.
// 2. For each run between corners, calls fitCurve with the supplied
//    error tolerance. A run of two points emits a single LineTo;
//    longer runs emit one or more CurveTo segments.
// 3. Re-stitches the run outputs into a single PathCommand sequence,
//    closing with ClosePath when the input was a closed ring.
//
// This is a faithful port of jas_dioxus/src/algorithms/simplify.rs.
// Every numeric detail (the 1e-12 zero-length guard, the cos(threshold)
// comparison, the closed-ring seam handling) is preserved for
// cross-language behavioral equivalence.

/// Default corner angle threshold: 30 degrees (in radians).
public let defaultCornerAngle: Double = Double.pi / 6.0

/// Simplify a polyline to a Bezier-rich PathCommand sequence.
///
/// `points` is the polyline (no duplicate closing vertex).
/// `precision` is the Schneider max-error tolerance in document units
/// (typically points).
/// `closed` controls whether the wraparound seam can become a corner
/// and whether the output ends with `closePath`.
///
/// Returns a sequence starting with `moveTo` and ending with (for
/// closed inputs) `closePath`. Returns an empty array when fewer than
/// 2 points are supplied.
public func simplifyPolyline(
    _ points: [(Double, Double)],
    precision: Double,
    closed: Bool
) -> [PathCommand] {
    simplifyPolyline(points, precision: precision, closed: closed,
                     cornerAngleThreshold: defaultCornerAngle)
}

/// `simplifyPolyline` with an explicit corner-angle threshold (in
/// radians). Useful for tests and future tuning surfaces.
public func simplifyPolyline(
    _ points: [(Double, Double)],
    precision: Double,
    closed: Bool,
    cornerAngleThreshold: Double
) -> [PathCommand] {
    if points.count < 2 {
        return []
    }
    if points.count == 2 {
        var out: [PathCommand] = []
        out.reserveCapacity(closed ? 3 : 2)
        out.append(.moveTo(points[0].0, points[0].1))
        out.append(.lineTo(points[1].0, points[1].1))
        if closed {
            out.append(.closePath)
        }
        return out
    }

    let corners = detectCorners(points, angleThreshold: cornerAngleThreshold, closed: closed)
    let runs = splitIntoRuns(points, corners: corners, closed: closed)

    var out: [PathCommand] = []
    out.append(.moveTo(runs[0][0].0, runs[0][0].1))
    for run in runs {
        if run.count == 2 {
            // Pure line segment — no fitting.
            out.append(.lineTo(run[1].0, run[1].1))
        } else {
            // Bezier fit on the run.
            let segs = fitCurve(points: run, error: precision)
            if segs.isEmpty {
                // Defensive: fit failed (too few points after filtering);
                // fall back to a straight line to the last vertex.
                let last = run[run.count - 1]
                out.append(.lineTo(last.0, last.1))
                continue
            }
            for seg in segs {
                out.append(.curveTo(x1: seg.c1x, y1: seg.c1y,
                                    x2: seg.c2x, y2: seg.c2y,
                                    x: seg.p2x, y: seg.p2y))
            }
        }
    }
    if closed {
        out.append(.closePath)
    }
    return out
}

/// Return indices of corner vertices. A corner is a vertex where the
/// direction change between the incoming and outgoing edges exceeds
/// `angleThreshold` radians. For `closed` inputs, the wraparound seam
/// (vertex 0) is treated like any other interior vertex; for open
/// inputs, endpoints (index 0 and n-1) are never corners.
func detectCorners(_ points: [(Double, Double)], angleThreshold: Double, closed: Bool) -> [Int] {
    let n = points.count
    var corners: [Int] = []
    let cosThreshold = cos(angleThreshold)
    let start = closed ? 0 : 1
    let end = closed ? n : n - 1
    var i = start
    while i < end {
        let prevIdx = (i + n - 1) % n
        let nextIdx = (i + 1) % n
        let v1 = normVec(subVec(points[i], points[prevIdx]))
        let v2 = normVec(subVec(points[nextIdx], points[i]))
        // Degenerate (zero-length) edges shouldn't mark corners.
        if v1 == nil || v2 == nil {
            i += 1
            continue
        }
        let d = dotVec(v1!, v2!)
        // d == 1 means edges are collinear (no turn); d < cosThreshold
        // means the turn exceeds angleThreshold.
        if d < cosThreshold {
            corners.append(i)
        }
        i += 1
    }
    return corners
}

/// Split `points` into runs separated by corners. Each run is returned
/// as its own array because closed-ring runs may wrap around the seam.
func splitIntoRuns(
    _ points: [(Double, Double)],
    corners: [Int],
    closed: Bool
) -> [[(Double, Double)]] {
    let n = points.count
    if corners.isEmpty {
        if closed {
            // No corners on a closed ring — emit one run that includes
            // the seam vertex twice (start == end) so fitCurve can
            // recover a closed-loop Bezier approximation.
            var r = points
            r.append(points[0])
            return [r]
        } else {
            return [points]
        }
    }
    var runs: [[(Double, Double)]] = []
    if closed {
        // Walk corner-to-corner around the ring. Each run starts at
        // corner k and ends at corner k+1 (mod corners.count),
        // collecting every intermediate vertex.
        for k in 0..<corners.count {
            let a = corners[k]
            let b = corners[(k + 1) % corners.count]
            var run: [(Double, Double)] = []
            var i = a
            run.append(points[i])
            while true {
                i = (i + 1) % n
                run.append(points[i])
                if i == b { break }
            }
            runs.append(run)
        }
    } else {
        // Open polyline: runs are [start..corners[0]], [corners[0]..corners[1]],
        // ..., [corners[last]..n-1].
        var prev = 0
        for c in corners {
            runs.append(Array(points[prev...c]))
            prev = c
        }
        runs.append(Array(points[prev..<n]))
    }
    return runs
}

private func subVec(_ a: (Double, Double), _ b: (Double, Double)) -> (Double, Double) {
    (a.0 - b.0, a.1 - b.1)
}
private func dotVec(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
    a.0 * b.0 + a.1 * b.1
}
private func normVec(_ v: (Double, Double)) -> (Double, Double)? {
    let m = (v.0 * v.0 + v.1 * v.1).squareRoot()
    if m < 1e-12 { return nil }
    return (v.0 / m, v.1 / m)
}
