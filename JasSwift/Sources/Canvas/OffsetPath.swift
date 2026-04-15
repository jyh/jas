/// Variable-width stroke rendering via offset paths.
///
/// Flattens a path to a polyline, computes normals at each sample point,
/// evaluates the width profile, and builds a filled polygon representing
/// the stroke outline.

import CoreGraphics

private struct PathSample {
    let x: Double
    let y: Double
    let nx: Double // unit normal x
    let ny: Double // unit normal y
    let t: Double  // fractional offset along path [0, 1]
}

private func samplePathWithNormals(_ cmds: [PathCommand]) -> [PathSample] {
    let pts = flattenPathCommands(cmds)
    if pts.count < 2 { return [] }
    let lengths = offsetArcLengths(pts)
    let total = lengths.last!
    if total == 0 { return [] }

    var samples: [PathSample] = []
    samples.reserveCapacity(pts.count)
    for i in 0..<pts.count {
        let t = lengths[i] / total
        let (dx, dy): (Double, Double)
        if i == 0 {
            dx = pts[1].0 - pts[0].0; dy = pts[1].1 - pts[0].1
        } else if i == pts.count - 1 {
            dx = pts[i].0 - pts[i - 1].0; dy = pts[i].1 - pts[i - 1].1
        } else {
            dx = pts[i + 1].0 - pts[i - 1].0; dy = pts[i + 1].1 - pts[i - 1].1
        }
        let len = sqrt(dx * dx + dy * dy)
        let (nx, ny) = len > 1e-10 ? (-dy / len, dx / len) : (0.0, 1.0)
        samples.append(PathSample(x: pts[i].0, y: pts[i].1, nx: nx, ny: ny, t: t))
    }
    return samples
}

private func sampleLineWithNormals(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> [PathSample] {
    let dx = x2 - x1, dy = y2 - y1
    let len = sqrt(dx * dx + dy * dy)
    if len < 1e-10 { return [] }
    let nx = -dy / len, ny = dx / len
    let numSamples = 32
    var samples: [PathSample] = []
    samples.reserveCapacity(numSamples + 1)
    for i in 0...numSamples {
        let t = Double(i) / Double(numSamples)
        samples.append(PathSample(x: x1 + dx * t, y: y1 + dy * t, nx: nx, ny: ny, t: t))
    }
    return samples
}

private func smoothstep(_ t: Double) -> Double {
    let t = min(max(t, 0), 1)
    return t * t * (3 - 2 * t)
}

private func evaluateWidthAt(_ points: [StrokeWidthPoint], _ t: Double) -> (Double, Double) {
    if points.isEmpty { return (0, 0) }
    if points.count == 1 { return (points[0].widthLeft, points[0].widthRight) }
    if t <= points[0].t { return (points[0].widthLeft, points[0].widthRight) }
    if t >= points.last!.t { return (points.last!.widthLeft, points.last!.widthRight) }
    for i in 1..<points.count {
        if t <= points[i].t {
            let dt = points[i].t - points[i - 1].t
            let frac = dt > 0 ? (t - points[i - 1].t) / dt : 0
            let s = smoothstep(frac)
            let wl = points[i - 1].widthLeft + s * (points[i].widthLeft - points[i - 1].widthLeft)
            let wr = points[i - 1].widthRight + s * (points[i].widthRight - points[i - 1].widthRight)
            return (wl, wr)
        }
    }
    return (points.last!.widthLeft, points.last!.widthRight)
}

/// Cumulative arc lengths for a polyline.
private func offsetArcLengths(_ pts: [(Double, Double)]) -> [Double] {
    var lengths = [0.0]
    for i in 1..<pts.count {
        let dx = pts[i].0 - pts[i - 1].0
        let dy = pts[i].1 - pts[i - 1].1
        lengths.append(lengths[i - 1] + sqrt(dx * dx + dy * dy))
    }
    return lengths
}

/// Render a variable-width stroke for a path element.
func renderVariableWidthPath(_ ctx: CGContext, cmds: [PathCommand],
                             widthPoints: [StrokeWidthPoint],
                             strokeColor: CGColor, linecap: LineCap) {
    let samples = samplePathWithNormals(cmds)
    renderFromSamples(ctx, samples: samples, widthPoints: widthPoints,
                      strokeColor: strokeColor, linecap: linecap)
}

/// Render a variable-width stroke for a line element.
func renderVariableWidthLine(_ ctx: CGContext,
                             x1: Double, y1: Double, x2: Double, y2: Double,
                             widthPoints: [StrokeWidthPoint],
                             strokeColor: CGColor, linecap: LineCap) {
    let samples = sampleLineWithNormals(x1, y1, x2, y2)
    renderFromSamples(ctx, samples: samples, widthPoints: widthPoints,
                      strokeColor: strokeColor, linecap: linecap)
}

private func renderFromSamples(_ ctx: CGContext, samples: [PathSample],
                                widthPoints: [StrokeWidthPoint],
                                strokeColor: CGColor, linecap: LineCap) {
    if samples.count < 2 { return }

    var left: [(Double, Double)] = []
    var right: [(Double, Double)] = []
    left.reserveCapacity(samples.count)
    right.reserveCapacity(samples.count)

    for s in samples {
        let (wl, wr) = evaluateWidthAt(widthPoints, s.t)
        left.append((s.x + s.nx * wl, s.y + s.ny * wl))
        right.append((s.x - s.nx * wr, s.y - s.ny * wr))
    }

    let (wl0, wr0) = evaluateWidthAt(widthPoints, 0)
    let (wln, wrn) = evaluateWidthAt(widthPoints, 1)

    let path = CGMutablePath()

    // Start cap
    let s0 = samples[0]
    switch linecap {
    case .round where wl0 + wr0 > 0.1:
        let r = (wl0 + wr0) / 2.0
        let tangentAngle = atan2(s0.ny, -s0.nx)
        path.move(to: CGPoint(x: right[0].0, y: right[0].1))
        path.addArc(center: CGPoint(x: s0.x, y: s0.y), radius: CGFloat(r),
                    startAngle: CGFloat(tangentAngle + .pi / 2),
                    endAngle: CGFloat(tangentAngle - .pi / 2),
                    clockwise: true)
    case .square where wl0 + wr0 > 0.1:
        let ext = (wl0 + wr0) / 2.0
        let bx = -s0.ny, by = s0.nx
        path.move(to: CGPoint(x: right[0].0 + bx * ext, y: right[0].1 + by * ext))
        path.addLine(to: CGPoint(x: left[0].0 + bx * ext, y: left[0].1 + by * ext))
    default:
        path.move(to: CGPoint(x: left[0].0, y: left[0].1))
    }

    // Left edge forward
    for (x, y) in left {
        path.addLine(to: CGPoint(x: x, y: y))
    }

    // End cap
    let sn = samples.last!
    switch linecap {
    case .round where wln + wrn > 0.1:
        let r = (wln + wrn) / 2.0
        let tangentAngle = atan2(sn.ny, -sn.nx)
        path.addArc(center: CGPoint(x: sn.x, y: sn.y), radius: CGFloat(r),
                    startAngle: CGFloat(tangentAngle - .pi / 2),
                    endAngle: CGFloat(tangentAngle + .pi / 2),
                    clockwise: true)
    case .square where wln + wrn > 0.1:
        let ext = (wln + wrn) / 2.0
        let fx = sn.ny, fy = -sn.nx
        let ll = left.last!, rl = right.last!
        path.addLine(to: CGPoint(x: ll.0 + fx * ext, y: ll.1 + fy * ext))
        path.addLine(to: CGPoint(x: rl.0 + fx * ext, y: rl.1 + fy * ext))
    default: break
    }

    // Right edge reversed
    for (x, y) in right.reversed() {
        path.addLine(to: CGPoint(x: x, y: y))
    }

    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(strokeColor)
    ctx.fillPath()
}
