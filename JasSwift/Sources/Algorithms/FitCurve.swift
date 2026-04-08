import Foundation

/// A fitted cubic Bezier segment with endpoints and control points.
struct FitSegment {
    let p1x: Double, p1y: Double
    let c1x: Double, c1y: Double
    let c2x: Double, c2y: Double
    let p2x: Double, p2y: Double
}

/// Fit a cubic Bezier spline to a sequence of 2D points using the
/// Schneider algorithm (Graphics Gems I, 1990).
func fitCurve(points: [(Double, Double)], error: Double) -> [FitSegment] {
    guard points.count >= 2 else { return [] }
    let d = points
    let tHat1 = leftTangent(d, 0)
    let tHat2 = rightTangent(d, d.count - 1)
    var result: [FitSegment] = []
    fitCubic(d, 0, d.count - 1, tHat1, tHat2, error, &result)
    return result
}

private let maxIterations = 4

private func fitCubic(
    _ d: [(Double, Double)], _ first: Int, _ last: Int,
    _ tHat1: (Double, Double), _ tHat2: (Double, Double),
    _ error: Double, _ result: inout [FitSegment]
) {
    let nPts = last - first + 1

    if nPts == 2 {
        let dist = vdist(d[first], d[last]) / 3.0
        result.append(FitSegment(
            p1x: d[first].0, p1y: d[first].1,
            c1x: d[first].0 + tHat1.0 * dist, c1y: d[first].1 + tHat1.1 * dist,
            c2x: d[last].0 + tHat2.0 * dist, c2y: d[last].1 + tHat2.1 * dist,
            p2x: d[last].0, p2y: d[last].1
        ))
        return
    }

    var u = chordLengthParameterize(d, first, last)
    var bezCurve = generateBezier(d, first, last, u, tHat1, tHat2)
    var (maxError, splitPoint) = computeMaxError(d, first, last, bezCurve, u)

    if maxError < error {
        result.append(bezCurve)
        return
    }

    let iterationError = error * error
    if maxError < iterationError {
        for _ in 0..<maxIterations {
            let uPrime = reparameterize(d, first, last, u, bezCurve)
            bezCurve = generateBezier(d, first, last, uPrime, tHat1, tHat2)
            (maxError, splitPoint) = computeMaxError(d, first, last, bezCurve, uPrime)
            if maxError < error {
                result.append(bezCurve)
                return
            }
            u = uPrime
        }
    }

    let tHatCenter = centerTangent(d, splitPoint)
    fitCubic(d, first, splitPoint, tHat1, tHatCenter, error, &result)
    fitCubic(d, splitPoint, last, (-tHatCenter.0, -tHatCenter.1), tHat2, error, &result)
}

private func generateBezier(
    _ d: [(Double, Double)], _ first: Int, _ last: Int,
    _ uPrime: [Double],
    _ tHat1: (Double, Double), _ tHat2: (Double, Double)
) -> FitSegment {
    let nPts = last - first + 1

    let A: [((Double, Double), (Double, Double))] = (0..<nPts).map { i in
        (vscale(tHat1, b1(uPrime[i])), vscale(tHat2, b2(uPrime[i])))
    }

    var C = [[0.0, 0.0], [0.0, 0.0]]
    var X = [0.0, 0.0]

    for i in 0..<nPts {
        C[0][0] += vdot(A[i].0, A[i].0)
        C[0][1] += vdot(A[i].0, A[i].1)
        C[1][0] = C[0][1]
        C[1][1] += vdot(A[i].1, A[i].1)
        let tmp = vsub(
            d[first + i],
            vadd(vscale(d[first], b0(uPrime[i])),
                 vadd(vscale(d[first], b1(uPrime[i])),
                      vadd(vscale(d[last], b2(uPrime[i])),
                           vscale(d[last], b3(uPrime[i])))))
        )
        X[0] += vdot(A[i].0, tmp)
        X[1] += vdot(A[i].1, tmp)
    }

    let det_C0_C1 = C[0][0] * C[1][1] - C[1][0] * C[0][1]
    let det_C0_X = C[0][0] * X[1] - C[1][0] * X[0]
    let det_X_C1 = X[0] * C[1][1] - X[1] * C[0][1]

    let alpha_l = det_C0_C1 == 0 ? 0.0 : det_X_C1 / det_C0_C1
    let alpha_r = det_C0_C1 == 0 ? 0.0 : det_C0_X / det_C0_C1

    let segLength = vdist(d[first], d[last])
    let epsilon = 1.0e-6 * segLength

    if alpha_l < epsilon || alpha_r < epsilon {
        let dist = segLength / 3.0
        return FitSegment(
            p1x: d[first].0, p1y: d[first].1,
            c1x: d[first].0 + tHat1.0 * dist, c1y: d[first].1 + tHat1.1 * dist,
            c2x: d[last].0 + tHat2.0 * dist, c2y: d[last].1 + tHat2.1 * dist,
            p2x: d[last].0, p2y: d[last].1
        )
    }

    return FitSegment(
        p1x: d[first].0, p1y: d[first].1,
        c1x: d[first].0 + tHat1.0 * alpha_l, c1y: d[first].1 + tHat1.1 * alpha_l,
        c2x: d[last].0 + tHat2.0 * alpha_r, c2y: d[last].1 + tHat2.1 * alpha_r,
        p2x: d[last].0, p2y: d[last].1
    )
}

private func reparameterize(
    _ d: [(Double, Double)], _ first: Int, _ last: Int,
    _ u: [Double], _ bez: FitSegment
) -> [Double] {
    let pts = [(bez.p1x, bez.p1y), (bez.c1x, bez.c1y),
               (bez.c2x, bez.c2y), (bez.p2x, bez.p2y)]
    return (first...last).map { i in
        newtonRaphson(pts, d[i], u[i - first])
    }
}

private func newtonRaphson(
    _ Q: [(Double, Double)], _ P: (Double, Double), _ u: Double
) -> Double {
    let Q_u = bezierII(3, Q, u)
    let Q1 = [
        ((Q[1].0 - Q[0].0) * 3, (Q[1].1 - Q[0].1) * 3),
        ((Q[2].0 - Q[1].0) * 3, (Q[2].1 - Q[1].1) * 3),
        ((Q[3].0 - Q[2].0) * 3, (Q[3].1 - Q[2].1) * 3),
    ]
    let Q2 = [
        ((Q1[1].0 - Q1[0].0) * 2, (Q1[1].1 - Q1[0].1) * 2),
        ((Q1[2].0 - Q1[1].0) * 2, (Q1[2].1 - Q1[1].1) * 2),
    ]
    let Q1_u = bezierII(2, Q1, u)
    let Q2_u = bezierII(1, Q2, u)

    let numerator = (Q_u.0 - P.0) * Q1_u.0 + (Q_u.1 - P.1) * Q1_u.1
    let denominator = Q1_u.0 * Q1_u.0 + Q1_u.1 * Q1_u.1
        + (Q_u.0 - P.0) * Q2_u.0 + (Q_u.1 - P.1) * Q2_u.1

    if denominator == 0 { return u }
    return u - numerator / denominator
}

private func bezierII(_ degree: Int, _ V: [(Double, Double)], _ t: Double) -> (Double, Double) {
    var Vtemp = V
    for i in 1...degree {
        for j in 0...(degree - i) {
            Vtemp[j] = (
                (1.0 - t) * Vtemp[j].0 + t * Vtemp[j + 1].0,
                (1.0 - t) * Vtemp[j].1 + t * Vtemp[j + 1].1
            )
        }
    }
    return Vtemp[0]
}

private func computeMaxError(
    _ d: [(Double, Double)], _ first: Int, _ last: Int,
    _ bez: FitSegment, _ u: [Double]
) -> (Double, Int) {
    let pts = [(bez.p1x, bez.p1y), (bez.c1x, bez.c1y),
               (bez.c2x, bez.c2y), (bez.p2x, bez.p2y)]
    var splitPoint = (last - first + 1) / 2
    var maxDist = 0.0
    for i in (first + 1)..<last {
        let P = bezierII(3, pts, u[i - first])
        let dx = P.0 - d[i].0, dy = P.1 - d[i].1
        let dist = dx * dx + dy * dy
        if dist >= maxDist {
            maxDist = dist
            splitPoint = i
        }
    }
    return (maxDist, splitPoint)
}

private func chordLengthParameterize(
    _ d: [(Double, Double)], _ first: Int, _ last: Int
) -> [Double] {
    var u = [Double](repeating: 0, count: last - first + 1)
    for i in (first + 1)...last {
        u[i - first] = u[i - first - 1] + vdist(d[i], d[i - 1])
    }
    let total = u[last - first]
    if total > 0 {
        for i in (first + 1)...last {
            u[i - first] /= total
        }
    }
    return u
}

private func leftTangent(_ d: [(Double, Double)], _ end: Int) -> (Double, Double) {
    vnormalize(vsub(d[end + 1], d[end]))
}
private func rightTangent(_ d: [(Double, Double)], _ end: Int) -> (Double, Double) {
    vnormalize(vsub(d[end - 1], d[end]))
}
private func centerTangent(_ d: [(Double, Double)], _ center: Int) -> (Double, Double) {
    let v1 = vsub(d[center - 1], d[center])
    let v2 = vsub(d[center], d[center + 1])
    return vnormalize(((v1.0 + v2.0) / 2, (v1.1 + v2.1) / 2))
}

// Bernstein basis functions
private func b0(_ u: Double) -> Double { let t = 1 - u; return t * t * t }
private func b1(_ u: Double) -> Double { let t = 1 - u; return 3 * u * t * t }
private func b2(_ u: Double) -> Double { let t = 1 - u; return 3 * u * u * t }
private func b3(_ u: Double) -> Double { u * u * u }

// Vector helpers
private func vadd(_ a: (Double, Double), _ b: (Double, Double)) -> (Double, Double) {
    (a.0 + b.0, a.1 + b.1)
}
private func vsub(_ a: (Double, Double), _ b: (Double, Double)) -> (Double, Double) {
    (a.0 - b.0, a.1 - b.1)
}
private func vscale(_ v: (Double, Double), _ s: Double) -> (Double, Double) {
    (v.0 * s, v.1 * s)
}
private func vdot(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
    a.0 * b.0 + a.1 * b.1
}
private func vdist(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
    hypot(a.0 - b.0, a.1 - b.1)
}
private func vnormalize(_ v: (Double, Double)) -> (Double, Double) {
    let len = hypot(v.0, v.1)
    if len == 0 { return v }
    return (v.0 / len, v.1 / len)
}
