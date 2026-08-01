/// Variable-width stroke rendering via offset paths.
///
/// Flattens a path to a polyline, computes normals at each sample point,
/// evaluates the width profile, and builds a filled polygon representing
/// the stroke outline.
///
/// # The GEOMETRY is separate from the RASTERISATION, and the split is the point
///
/// Until 2026-08-01 the outline was never a value in either port: it existed
/// only as a sequence of drawing calls, so no roundtrip verb could serialise
/// it and no cross-port comparison could see it. Now `variableWidthOutline`
/// returns a `StrokeOutline` — two rails and two caps, as numbers — and
/// `flattenOutline` turns that into the closed polygon the renderer fills.
/// The `offset_path` algorithm family gates the arithmetic.
///
/// **Why the cap is flattened HERE rather than handed to CoreGraphics.** The
/// previous code passed the arc to `CGMutablePath.addArc(.., clockwise: true)`
/// while Rust passed the same numbers to `CanvasRenderingContext2d
/// .arc_with_anticlockwise(.., true)`, and whether those two flags denote the
/// same sweep was an open question answered only by reading two vendors'
/// prose. They do — measured in `Tests/Canvas/OffsetPathCapTests.swift`,
/// which reads the points back out of a real `CGMutablePath` — but the answer
/// is not what makes this safe. What makes it safe is that neither port asks
/// its platform any more: both walk the same `capArcSteps`-segment polyline
/// out of the same arithmetic.

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

// MARK: - The outline, as values

/// One end of a variable-width stroke, as VALUES rather than as a call.
///
/// Angles are ordinary `atan2` angles in DOCUMENT space: the point of a
/// `.round` cap at angle `a` is `(cx + r*cos a, cy + r*sin a)`. No platform is
/// named and no platform flag is stored — `decreasing` says which way the
/// sweep runs in that arithmetic and nothing else.
public enum StrokeCap: Equatable {
    /// SVG `butt`: the stroke ends on the rail, nothing is added.
    case butt
    /// SVG `round`: a semicircle centred on the endpoint.
    case round(cx: Double, cy: Double, r: Double,
               a0: Double, a1: Double, decreasing: Bool)
    /// SVG `square`: both rails extend `ext` along the unit vector
    /// `(ux, uy)` — backward at the start of the stroke, forward at its end.
    case square(ext: Double, ux: Double, uy: Double)
}

/// A variable-width stroke's outline, before it is drawn.
public struct StrokeOutline: Equatable {
    /// The left rail, in path order. Empty iff the stroke is degenerate.
    public let left: [Point2]
    /// The right rail, in path order (the polygon walks it backwards).
    public let right: [Point2]
    public let startCap: StrokeCap
    public let endCap: StrokeCap
}

/// A plain (x, y) pair. Swift tuples are not `Equatable`, so the outline
/// carries this rather than `(Double, Double)`.
public struct Point2: Equatable {
    public let x: Double
    public let y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// Segments per cap semicircle when the renderer flattens one.
///
/// The chord error of an `n`-segment semicircle is `r * (1 - cos(pi/(2n)))`;
/// at 32 that is `r * 0.0012`, i.e. 0.006pt for a 10pt-wide stroke and 0.12pt
/// for a 200pt one. Both ports use this same number, and it travels on the
/// algorithm wire as `default_arc_steps` so it cannot drift between them.
public let capArcSteps = 32

/// The outline of a variable-width stroke along a path element.
public func variableWidthOutlinePath(_ cmds: [PathCommand],
                                     widthPoints: [StrokeWidthPoint],
                                     linecap: LineCap) -> StrokeOutline {
    buildOutline(samplePathWithNormals(cmds), widthPoints, linecap)
}

/// The outline of a variable-width stroke along a line element.
public func variableWidthOutlineLine(x1: Double, y1: Double, x2: Double, y2: Double,
                                     widthPoints: [StrokeWidthPoint],
                                     linecap: LineCap) -> StrokeOutline {
    buildOutline(sampleLineWithNormals(x1, y1, x2, y2), widthPoints, linecap)
}

private func buildOutline(_ samples: [PathSample],
                          _ widthPoints: [StrokeWidthPoint],
                          _ linecap: LineCap) -> StrokeOutline {
    if samples.count < 2 {
        return StrokeOutline(left: [], right: [], startCap: .butt, endCap: .butt)
    }

    var left: [Point2] = []
    var right: [Point2] = []
    left.reserveCapacity(samples.count)
    right.reserveCapacity(samples.count)
    for s in samples {
        let (wl, wr) = evaluateWidthAt(widthPoints, s.t)
        left.append(Point2(s.x + s.nx * wl, s.y + s.ny * wl))
        right.append(Point2(s.x - s.nx * wr, s.y - s.ny * wr))
    }

    let (wl0, wr0) = evaluateWidthAt(widthPoints, 0)
    let (wln, wrn) = evaluateWidthAt(widthPoints, 1)
    let s0 = samples[0]
    let sn = samples.last!

    // A cap narrower than 0.1pt across is not drawn at all: a taper profile
    // reaches zero width at the ends, and a zero-radius arc is a wart.
    var startCap = StrokeCap.butt
    switch linecap {
    case .round where wl0 + wr0 > 0.1:
        let a = capAngle(s0)
        // FROM the right rail, which sits at theta - pi/2, BACKWARDS around
        // the far side, TO the left rail at theta + pi/2. The decreasing
        // sweep is what carries it through theta - pi, i.e. behind the start
        // of the stroke.
        startCap = .round(cx: s0.x, cy: s0.y, r: (wl0 + wr0) / 2.0,
                          a0: a - .pi / 2, a1: a + .pi / 2, decreasing: true)
    case .square where wl0 + wr0 > 0.1:
        startCap = .square(ext: (wl0 + wr0) / 2.0, ux: -s0.ny, uy: s0.nx)
    default:
        startCap = .butt
    }

    var endCap = StrokeCap.butt
    switch linecap {
    case .round where wln + wrn > 0.1:
        let a = capAngle(sn)
        // FROM the left rail TO the right rail, the other way round, so the
        // decreasing sweep passes through theta itself -- ahead of the end
        // of the stroke.
        endCap = .round(cx: sn.x, cy: sn.y, r: (wln + wrn) / 2.0,
                        a0: a + .pi / 2, a1: a - .pi / 2, decreasing: true)
    case .square where wln + wrn > 0.1:
        endCap = .square(ext: (wln + wrn) / 2.0, ux: sn.ny, uy: -sn.nx)
    default:
        endCap = .butt
    }

    return StrokeOutline(left: left, right: right,
                         startCap: startCap, endCap: endCap)
}

/// The direction of travel at a sample, as an angle.
///
/// The normal is the tangent turned a quarter turn — `n = (-t_y, t_x)` — so
/// the tangent read back off it is `(n_y, -n_x)` and its angle is
/// `atan2(-n_x, n_y)`.
///
/// UNTIL 2026-08-01 THIS WAS `atan2(n_y, -n_x)`: the same two arguments the
/// other way round, which evaluates to `pi/2 - theta` — a REFLECTION of the
/// direction about the 45-degree line rather than the direction itself. A
/// reflection agrees with the truth along one axis and diverges by `2*theta`
/// everywhere else, so both round caps were welded on at the wrong angle for
/// every stroke direction except 135 and 315 degrees, where the two errors
/// happened to cancel. Measured on a 10pt-wide horizontal stroke: the cap arc
/// began 7.07pt from the rail it was joined to, and the renderer bridged that
/// gap with a straight chord. Both ports carried the identical expression, so
/// no port-against-port comparison could see it — the `offset_path` family's
/// hand-derived vectors are what reddened.
private func capAngle(_ s: PathSample) -> Double {
    atan2(-s.nx, s.ny)
}

/// The closed polygon a renderer fills, in draw order.
///
/// FAITHFUL, not tidy. It reproduces exactly the point sequence the drawing
/// code emits, including the duplicate vertex where a `move` lands on the
/// first rail point and including any chord between a rail and the point a
/// cap arc actually starts at. A cap whose arc does not begin on its rail is
/// a real defect in the filled shape, and a flattener that quietly bridged it
/// would be an instrument reporting a prettier answer than the truth.
public func flattenOutline(_ o: StrokeOutline, arcSteps: Int) -> [Point2] {
    if o.left.count < 2 { return [] }
    var poly: [Point2] = []
    let last = o.left.count - 1

    switch o.startCap {
    case .butt:
        poly.append(o.left[0])
    case .square(let ext, let ux, let uy):
        poly.append(Point2(o.right[0].x + ux * ext, o.right[0].y + uy * ext))
        poly.append(Point2(o.left[0].x + ux * ext, o.left[0].y + uy * ext))
    case .round:
        poly.append(o.right[0])
        appendArc(&poly, o.startCap, arcSteps)
    }

    poly.append(contentsOf: o.left)

    switch o.endCap {
    case .butt:
        break
    case .square(let ext, let ux, let uy):
        poly.append(Point2(o.left[last].x + ux * ext, o.left[last].y + uy * ext))
        poly.append(Point2(o.right[last].x + ux * ext, o.right[last].y + uy * ext))
    case .round:
        appendArc(&poly, o.endCap, arcSteps)
    }

    poly.append(contentsOf: o.right.reversed())
    return poly
}

/// SCOPE: a cap sweep is at most a half turn, so the wrap-around cases a
/// general arc flattener must decide — a sweep of exactly zero, and one of a
/// full turn or more — cannot arise here and are NOT handled. The normalised
/// sweep is taken into `(0, 2*pi]`.
private func appendArc(_ poly: inout [Point2], _ cap: StrokeCap, _ steps: Int) {
    guard case .round(let cx, let cy, let r, let a0, let a1, let decreasing) = cap
    else { return }
    let tau = 2 * Double.pi
    let raw = decreasing ? a0 - a1 : a1 - a0
    var sweep = raw.truncatingRemainder(dividingBy: tau)
    if sweep <= 0 { sweep += tau }
    let n = max(steps, 1)
    for i in 0...n {
        let f = Double(i) / Double(n)
        let a = decreasing ? a0 - sweep * f : a0 + sweep * f
        poly.append(Point2(cx + r * cos(a), cy + r * sin(a)))
    }
}

// MARK: - Rasterisation

/// Render a variable-width stroke for a path element.
func renderVariableWidthPath(_ ctx: CGContext, cmds: [PathCommand],
                             widthPoints: [StrokeWidthPoint],
                             strokeColor: CGColor, linecap: LineCap) {
    let outline = variableWidthOutlinePath(cmds, widthPoints: widthPoints,
                                           linecap: linecap)
    fillOutline(ctx, outline, strokeColor)
}

/// Render a variable-width stroke for a line element.
func renderVariableWidthLine(_ ctx: CGContext,
                             x1: Double, y1: Double, x2: Double, y2: Double,
                             widthPoints: [StrokeWidthPoint],
                             strokeColor: CGColor, linecap: LineCap) {
    let outline = variableWidthOutlineLine(x1: x1, y1: y1, x2: x2, y2: y2,
                                           widthPoints: widthPoints,
                                           linecap: linecap)
    fillOutline(ctx, outline, strokeColor)
}

private func fillOutline(_ ctx: CGContext, _ outline: StrokeOutline,
                         _ strokeColor: CGColor) {
    let poly = flattenOutline(outline, arcSteps: capArcSteps)
    if poly.isEmpty { return }
    let path = CGMutablePath()
    path.move(to: CGPoint(x: poly[0].x, y: poly[0].y))
    for p in poly.dropFirst() {
        path.addLine(to: CGPoint(x: p.x, y: p.y))
    }
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(strokeColor)
    ctx.fillPath()
}
