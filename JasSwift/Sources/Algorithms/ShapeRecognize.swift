/// Shape recognition: classify a freehand path as the nearest geometric
/// primitive (line, scribble, triangle, rectangle, rounded rectangle,
/// circle, ellipse, filled-arrow outline, or lemniscate).
///
/// Design constraints:
///   - Output shapes are axis-aligned. Rotated inputs return nil.
///   - Strict: if no candidate fits within tolerance, return nil.
///   - Accepts both raw pencil polylines and Bezier paths (via flatten).

import Foundation

public typealias Pt = (Double, Double)

// MARK: - Public types

public enum ShapeKind: Equatable, Hashable {
    case line
    case triangle
    case rectangle
    case square
    case roundRect
    case circle
    case ellipse
    case arrow
    case lemniscate
    case scribble
}

public enum RecognizedShape: Equatable {
    case line(a: Pt, b: Pt)
    case triangle(pts: (Pt, Pt, Pt))
    /// Square is emitted as rectangle with w == h.
    case rectangle(x: Double, y: Double, w: Double, h: Double)
    case roundRect(x: Double, y: Double, w: Double, h: Double, r: Double)
    case circle(cx: Double, cy: Double, r: Double)
    case ellipse(cx: Double, cy: Double, rx: Double, ry: Double)
    case arrow(tail: Pt, tip: Pt, headLen: Double, headHalfWidth: Double, shaftHalfWidth: Double)
    case lemniscate(center: Pt, a: Double, horizontal: Bool)
    case scribble(points: [Pt])

    public var kind: ShapeKind {
        switch self {
        case .line: return .line
        case .triangle: return .triangle
        case .rectangle(_, _, let w, let h):
            return abs(w - h) < 1e-9 ? .square : .rectangle
        case .roundRect: return .roundRect
        case .circle: return .circle
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .lemniscate: return .lemniscate
        case .scribble: return .scribble
        }
    }

    public static func == (lhs: RecognizedShape, rhs: RecognizedShape) -> Bool {
        switch (lhs, rhs) {
        case (.line(let a1, let b1), .line(let a2, let b2)):
            return ptEq(a1, a2) && ptEq(b1, b2)
        case (.triangle(let p1), .triangle(let p2)):
            return ptEq(p1.0, p2.0) && ptEq(p1.1, p2.1) && ptEq(p1.2, p2.2)
        case (.rectangle(let x1, let y1, let w1, let h1), .rectangle(let x2, let y2, let w2, let h2)):
            return x1 == x2 && y1 == y2 && w1 == w2 && h1 == h2
        case (.roundRect(let x1, let y1, let w1, let h1, let r1), .roundRect(let x2, let y2, let w2, let h2, let r2)):
            return x1 == x2 && y1 == y2 && w1 == w2 && h1 == h2 && r1 == r2
        case (.circle(let cx1, let cy1, let r1), .circle(let cx2, let cy2, let r2)):
            return cx1 == cx2 && cy1 == cy2 && r1 == r2
        case (.ellipse(let cx1, let cy1, let rx1, let ry1), .ellipse(let cx2, let cy2, let rx2, let ry2)):
            return cx1 == cx2 && cy1 == cy2 && rx1 == rx2 && ry1 == ry2
        case (.arrow(let t1, let p1, let hl1, let hw1, let sw1), .arrow(let t2, let p2, let hl2, let hw2, let sw2)):
            return ptEq(t1, t2) && ptEq(p1, p2) && hl1 == hl2 && hw1 == hw2 && sw1 == sw2
        case (.lemniscate(let c1, let a1, let h1), .lemniscate(let c2, let a2, let h2)):
            return ptEq(c1, c2) && a1 == a2 && h1 == h2
        case (.scribble(let p1), .scribble(let p2)):
            return p1.count == p2.count && zip(p1, p2).allSatisfy { ptEq($0, $1) }
        default:
            return false
        }
    }
}

private func ptEq(_ a: Pt, _ b: Pt) -> Bool { a.0 == b.0 && a.1 == b.1 }

public struct RecognizeConfig {
    public var tolerance: Double
    public var closeGapFrac: Double
    public var cornerAngleDeg: Double
    public var squareAspectEps: Double
    public var circleEccentricityEps: Double
    public var resampleN: Int

    public init(
        tolerance: Double = 0.05,
        closeGapFrac: Double = 0.10,
        cornerAngleDeg: Double = 35.0,
        squareAspectEps: Double = 0.10,
        circleEccentricityEps: Double = 0.92,
        resampleN: Int = 64
    ) {
        self.tolerance = tolerance
        self.closeGapFrac = closeGapFrac
        self.cornerAngleDeg = cornerAngleDeg
        self.squareAspectEps = squareAspectEps
        self.circleEccentricityEps = circleEccentricityEps
        self.resampleN = resampleN
    }
}

private let minClosedBboxAspect = 0.10

// MARK: - Public API

/// Recognize from a raw polyline.
public func recognize(_ points: [Pt], _ cfg: RecognizeConfig) -> RecognizedShape? {
    if points.count < 3 { return nil }
    let pts = resample(points, cfg.resampleN)
    let diag = bboxDiagOf(pts)
    if diag < 1e-9 { return nil }
    let closed = isClosed(pts, cfg.closeGapFrac)
    let tolAbs = cfg.tolerance * diag

    var candidates: [(Double, RecognizedShape)] = []

    // Line is always a valid candidate (open or closed).
    if let (a, b, res) = fitLine(pts) {
        if res <= tolAbs {
            candidates.append((res, .line(a: a, b: b)))
        }
    }

    // Scribble (open paths only).
    if !closed {
        if let (segs, res) = fitScribble(pts, diag) {
            if res <= tolAbs {
                candidates.append((res, .scribble(points: segs)))
            }
        }
    }

    if closed {
        // Ellipse (axis-aligned, bbox-based). Snap to circle when nearly so.
        if let (cx, cy, rx, ry, res) = fitEllipseAA(pts) {
            if res <= tolAbs {
                let ratio = min(rx, ry) / max(rx, ry)
                if ratio >= cfg.circleEccentricityEps {
                    let r = (rx + ry) / 2.0
                    candidates.append((res, .circle(cx: cx, cy: cy, r: r)))
                } else {
                    candidates.append((res, .ellipse(cx: cx, cy: cy, rx: rx, ry: ry)))
                }
            }
        }

        // Rectangle (axis-aligned, bbox-based). Snap to square when nearly so.
        let rectFit = fitRectAA(pts)
        if let (x, y, w, h, res) = rectFit {
            if res <= tolAbs {
                let aspect = abs(w - h) / max(w, h)
                let (fw, fh): (Double, Double)
                if aspect <= cfg.squareAspectEps {
                    let m = (w + h) / 2.0
                    (fw, fh) = (m, m)
                } else {
                    (fw, fh) = (w, h)
                }
                candidates.append((res, .rectangle(x: x, y: y, w: fw, h: fh)))
            }
        }

        // Round rectangle.
        if let (x, y, w, h, r, res) = fitRoundRect(pts) {
            let short = min(w, h)
            let rectRms = rectFit?.4 ?? Double.infinity
            if res <= tolAbs && r / short > 0.05 && r / short < 0.45 && res < 0.5 * rectRms {
                candidates.append((res, .roundRect(x: x, y: y, w: w, h: h, r: r)))
            }
        }

        // Triangle.
        if let (verts, res) = fitTriangle(pts) {
            if res <= tolAbs {
                candidates.append((res, .triangle(pts: verts)))
            }
        }

        // Lemniscate.
        if countSelfIntersections(pts) >= 1 {
            if let (cx, cy, a, horizontal, res) = fitLemniscate(pts) {
                if res <= tolAbs {
                    candidates.append((res, .lemniscate(center: (cx, cy), a: a, horizontal: horizontal)))
                }
            }
        }

        // Arrow outline (closed, 7-corner silhouette).
        if let (tail, tip, headLen, headHalfWidth, shaftHalfWidth, res) = fitArrow(points, diag) {
            if res <= tolAbs {
                candidates.append((res, .arrow(tail: tail, tip: tip, headLen: headLen,
                    headHalfWidth: headHalfWidth, shaftHalfWidth: shaftHalfWidth)))
            }
        }
    }

    candidates.sort { $0.0 < $1.0 }
    return candidates.first?.1
}

/// Recognize from a path that may contain Beziers.
public func recognizePath(_ d: [PathCommand], _ cfg: RecognizeConfig) -> RecognizedShape? {
    let pts = flattenPathCommands(d)
    return recognize(pts, cfg)
}

/// Try to recognize an Element as a cleaner geometric shape. Returns nil when
/// the element is already a clean primitive or cannot be interpreted as a path.
public func recognizeElement(_ element: Element, _ cfg: RecognizeConfig) -> (ShapeKind, Element)? {
    let pts: [Pt]
    switch element {
    case .path(let p): pts = flattenPathCommands(p.d)
    case .polyline(let p): pts = p.points
    case .line, .rect, .circle, .ellipse, .polygon, .text, .textPath, .group, .layer:
        return nil
    }
    guard let shape = recognize(pts, cfg) else { return nil }
    return (shape.kind, recognizedToElement(shape, element))
}

// MARK: - Template appearance

private struct Appearance {
    let fill: Fill?
    let stroke: Stroke?
    let opacity: Double
    let transform: Transform?
    let locked: Bool
    let visibility: Visibility
}

private func templateAppearance(_ e: Element) -> Appearance {
    switch e {
    case .line(let l):
        return Appearance(fill: nil, stroke: l.stroke, opacity: l.opacity,
                         transform: l.transform, locked: l.locked, visibility: l.visibility)
    case .rect(let r):
        return Appearance(fill: r.fill, stroke: r.stroke, opacity: r.opacity,
                         transform: r.transform, locked: r.locked, visibility: r.visibility)
    case .circle(let c):
        return Appearance(fill: c.fill, stroke: c.stroke, opacity: c.opacity,
                         transform: c.transform, locked: c.locked, visibility: c.visibility)
    case .ellipse(let e):
        return Appearance(fill: e.fill, stroke: e.stroke, opacity: e.opacity,
                         transform: e.transform, locked: e.locked, visibility: e.visibility)
    case .polyline(let p):
        return Appearance(fill: p.fill, stroke: p.stroke, opacity: p.opacity,
                         transform: p.transform, locked: p.locked, visibility: p.visibility)
    case .polygon(let p):
        return Appearance(fill: p.fill, stroke: p.stroke, opacity: p.opacity,
                         transform: p.transform, locked: p.locked, visibility: p.visibility)
    case .path(let p):
        return Appearance(fill: p.fill, stroke: p.stroke, opacity: p.opacity,
                         transform: p.transform, locked: p.locked, visibility: p.visibility)
    default:
        return Appearance(fill: nil, stroke: nil, opacity: 1.0,
                         transform: nil, locked: false, visibility: .preview)
    }
}

/// Build a clean primitive Element from a recognized shape.
public func recognizedToElement(_ shape: RecognizedShape, _ template: Element) -> Element {
    let a = templateAppearance(template)
    switch shape {
    case .line(let p1, let p2):
        return .line(Line(x1: p1.0, y1: p1.1, x2: p2.0, y2: p2.1,
                         stroke: a.stroke, opacity: a.opacity, transform: a.transform,
                         locked: a.locked, visibility: a.visibility))
    case .triangle(let pts):
        return .polygon(Polygon(points: [pts.0, pts.1, pts.2],
                               fill: a.fill, stroke: a.stroke, opacity: a.opacity,
                               transform: a.transform, locked: a.locked, visibility: a.visibility))
    case .rectangle(let x, let y, let w, let h):
        return .rect(Rect(x: x, y: y, width: w, height: h,
                          fill: a.fill, stroke: a.stroke, opacity: a.opacity,
                          transform: a.transform, locked: a.locked, visibility: a.visibility))
    case .roundRect(let x, let y, let w, let h, let r):
        return .rect(Rect(x: x, y: y, width: w, height: h, rx: r, ry: r,
                          fill: a.fill, stroke: a.stroke, opacity: a.opacity,
                          transform: a.transform, locked: a.locked, visibility: a.visibility))
    case .circle(let cx, let cy, let r):
        return .circle(Circle(cx: cx, cy: cy, r: r,
                             fill: a.fill, stroke: a.stroke, opacity: a.opacity,
                             transform: a.transform, locked: a.locked, visibility: a.visibility))
    case .ellipse(let cx, let cy, let rx, let ry):
        return .ellipse(Ellipse(cx: cx, cy: cy, rx: rx, ry: ry,
                               fill: a.fill, stroke: a.stroke, opacity: a.opacity,
                               transform: a.transform, locked: a.locked, visibility: a.visibility))
    case .arrow(let tail, let tip, let headLen, let headHalfWidth, let shaftHalfWidth):
        let dx = tip.0 - tail.0
        let dy = tip.1 - tail.1
        let len = sqrt(dx * dx + dy * dy)
        let (ux, uy) = len > 1e-9 ? (dx / len, dy / len) : (1.0, 0.0)
        let (px, py) = (-uy, ux)
        let shaftEnd = (tip.0 - ux * headLen, tip.1 - uy * headLen)
        func p(_ c: Pt, _ s: Double) -> Pt { (c.0 + px * s, c.1 + py * s) }
        let points: [Pt] = [
            p(tail, -shaftHalfWidth),
            p(shaftEnd, -shaftHalfWidth),
            p(shaftEnd, -headHalfWidth),
            tip,
            p(shaftEnd, headHalfWidth),
            p(shaftEnd, shaftHalfWidth),
            p(tail, shaftHalfWidth),
        ]
        return .polygon(Polygon(points: points,
                               fill: a.fill, stroke: a.stroke, opacity: a.opacity,
                               transform: a.transform, locked: a.locked, visibility: a.visibility))
    case .scribble(let points):
        return .polyline(Polyline(points: points,
                                 stroke: a.stroke, opacity: a.opacity,
                                 transform: a.transform, locked: a.locked, visibility: a.visibility))
    case .lemniscate(let center, let la, let horizontal):
        let n = 96
        var d: [PathCommand] = []
        d.reserveCapacity(n + 2)
        for i in 0...n {
            let t = 2.0 * Double.pi * Double(i) / Double(n)
            let s = sin(t)
            let c = cos(t)
            let denom = 1.0 + s * s
            let lx = la * c / denom
            let ly = la * s * c / denom
            let (x, y) = horizontal
                ? (center.0 + lx, center.1 + ly)
                : (center.0 + ly, center.1 + lx)
            if i == 0 {
                d.append(.moveTo(x, y))
            } else {
                d.append(.lineTo(x, y))
            }
        }
        d.append(.closePath)
        return .path(Path(d: d,
                         fill: a.fill, stroke: a.stroke, opacity: a.opacity,
                         transform: a.transform, locked: a.locked, visibility: a.visibility))
    }
}

// MARK: - Geometric helpers

private func dist(_ a: Pt, _ b: Pt) -> Double {
    sqrt((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1))
}

private func bboxOf(_ pts: [Pt]) -> (Double, Double, Double, Double) {
    var xmin = Double.infinity, ymin = Double.infinity
    var xmax = -Double.infinity, ymax = -Double.infinity
    for (x, y) in pts {
        if x < xmin { xmin = x }
        if x > xmax { xmax = x }
        if y < ymin { ymin = y }
        if y > ymax { ymax = y }
    }
    return (xmin, ymin, xmax, ymax)
}

private func bboxDiagOf(_ pts: [Pt]) -> Double {
    let (xmin, ymin, xmax, ymax) = bboxOf(pts)
    return sqrt((xmax - xmin) * (xmax - xmin) + (ymax - ymin) * (ymax - ymin))
}

private func arcLength(_ pts: [Pt]) -> Double {
    zip(pts, pts.dropFirst()).reduce(0.0) { $0 + dist($1.0, $1.1) }
}

private func isClosed(_ pts: [Pt], _ frac: Double) -> Bool {
    guard pts.count >= 2 else { return false }
    let total = arcLength(pts)
    if total < 1e-12 { return false }
    let gap = dist(pts[0], pts[pts.count - 1])
    return gap / total <= frac
}

private func resample(_ pts: [Pt], _ n: Int) -> [Pt] {
    guard pts.count >= 2, n >= 2 else { return pts }
    var cum = [Double](repeating: 0.0, count: pts.count)
    for i in 1..<pts.count {
        cum[i] = cum[i - 1] + dist(pts[i - 1], pts[i])
    }
    let total = cum[cum.count - 1]
    if total < 1e-12 { return pts }
    let step = total / Double(n - 1)
    var out: [Pt] = [pts[0]]
    out.reserveCapacity(n)
    var idx = 1
    for k in 1..<(n - 1) {
        let target = step * Double(k)
        while idx < pts.count - 1 && cum[idx] < target { idx += 1 }
        let segStart = cum[idx - 1]
        let segLen = cum[idx] - segStart
        let t = segLen > 1e-12 ? max(0, min(1, (target - segStart) / segLen)) : 0.0
        let x = pts[idx - 1].0 + t * (pts[idx].0 - pts[idx - 1].0)
        let y = pts[idx - 1].1 + t * (pts[idx].1 - pts[idx - 1].1)
        out.append((x, y))
    }
    out.append(pts[pts.count - 1])
    return out
}

private func pointToSegmentDist(_ p: Pt, _ a: Pt, _ b: Pt) -> Double {
    let dx = b.0 - a.0, dy = b.1 - a.1
    let len2 = dx * dx + dy * dy
    if len2 < 1e-12 { return dist(p, a) }
    let t = max(0, min(1, ((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len2))
    let qx = a.0 + t * dx, qy = a.1 + t * dy
    return sqrt((p.0 - qx) * (p.0 - qx) + (p.1 - qy) * (p.1 - qy))
}

private func pointToLineDist(_ p: Pt, _ a: Pt, _ b: Pt) -> Double {
    let dx = b.0 - a.0, dy = b.1 - a.1
    let len = sqrt(dx * dx + dy * dy)
    if len < 1e-12 { return dist(p, a) }
    return abs((p.0 - a.0) * dy - (p.1 - a.1) * dx) / len
}

// MARK: - Fits

private func fitLine(_ pts: [Pt]) -> (Pt, Pt, Double)? {
    let n = Double(pts.count)
    guard pts.count >= 2 else { return nil }
    let cx = pts.reduce(0.0) { $0 + $1.0 } / n
    let cy = pts.reduce(0.0) { $0 + $1.1 } / n
    var sxx = 0.0, syy = 0.0, sxy = 0.0
    for (x, y) in pts {
        sxx += (x - cx) * (x - cx)
        syy += (y - cy) * (y - cy)
        sxy += (x - cx) * (y - cy)
    }
    let trace = sxx + syy
    let det = sxx * syy - sxy * sxy
    let disc = sqrt(max(0, trace * trace / 4.0 - det))
    let lambda1 = trace / 2.0 + disc
    var (dx, dy): (Double, Double)
    if abs(sxy) > 1e-12 {
        (dx, dy) = (lambda1 - syy, sxy)
    } else if sxx >= syy {
        (dx, dy) = (1.0, 0.0)
    } else {
        (dx, dy) = (0.0, 1.0)
    }
    let len = sqrt(dx * dx + dy * dy)
    if len < 1e-12 { return nil }
    dx /= len; dy /= len
    var tmin = Double.infinity, tmax = -Double.infinity
    var sqSum = 0.0
    for (x, y) in pts {
        let t = (x - cx) * dx + (y - cy) * dy
        if t < tmin { tmin = t }
        if t > tmax { tmax = t }
        let perp = (x - cx) * (-dy) + (y - cy) * dx
        sqSum += perp * perp
    }
    let rms = sqrt(sqSum / n)
    let a: Pt = (cx + tmin * dx, cy + tmin * dy)
    let b: Pt = (cx + tmax * dx, cy + tmax * dy)
    return (a, b, rms)
}

private func fitEllipseAA(_ pts: [Pt]) -> (Double, Double, Double, Double, Double)? {
    let (xmin, ymin, xmax, ymax) = bboxOf(pts)
    let rx = (xmax - xmin) / 2.0, ry = (ymax - ymin) / 2.0
    if rx <= 1e-9 || ry <= 1e-9 { return nil }
    if min(rx, ry) / max(rx, ry) < minClosedBboxAspect { return nil }
    let cx = (xmin + xmax) / 2.0, cy = (ymin + ymax) / 2.0
    let scale = min(rx, ry)
    var sqSum = 0.0
    for (x, y) in pts {
        let nx = (x - cx) / rx, ny = (y - cy) / ry
        let r = sqrt(nx * nx + ny * ny)
        let d = (r - 1.0) * scale
        sqSum += d * d
    }
    return (cx, cy, rx, ry, sqrt(sqSum / Double(pts.count)))
}

private func fitRectAA(_ pts: [Pt]) -> (Double, Double, Double, Double, Double)? {
    let (xmin, ymin, xmax, ymax) = bboxOf(pts)
    let w = xmax - xmin, h = ymax - ymin
    if w <= 1e-9 || h <= 1e-9 { return nil }
    if min(w, h) / max(w, h) < minClosedBboxAspect { return nil }
    var sqSum = 0.0
    for (x, y) in pts {
        let dx = min(abs(x - xmin), abs(x - xmax))
        let dy = min(abs(y - ymin), abs(y - ymax))
        let d = min(dx, dy)
        sqSum += d * d
    }
    return (xmin, ymin, w, h, sqrt(sqSum / Double(pts.count)))
}

private func distToRoundRect(_ p: Pt, _ x: Double, _ y: Double,
                              _ w: Double, _ h: Double, _ r: Double) -> Double {
    let px = p.0 - x, py = p.1 - y
    let qx = px > w / 2.0 ? w - px : px
    let qy = py > h / 2.0 ? h - py : py
    if qx >= r && qy >= r {
        return min(qx, qy)
    } else if qx >= r {
        return qy
    } else if qy >= r {
        return qx
    } else {
        let dx = qx - r, dy = qy - r
        return abs(sqrt(dx * dx + dy * dy) - r)
    }
}

private func roundRectRms(_ pts: [Pt], _ x: Double, _ y: Double,
                           _ w: Double, _ h: Double, _ r: Double) -> Double {
    var sqSum = 0.0
    for p in pts {
        let d = distToRoundRect(p, x, y, w, h, r)
        sqSum += d * d
    }
    return sqrt(sqSum / Double(pts.count))
}

private func fitRoundRect(_ pts: [Pt]) -> (Double, Double, Double, Double, Double, Double)? {
    let (xmin, ymin, xmax, ymax) = bboxOf(pts)
    let w = xmax - xmin, h = ymax - ymin
    if w <= 1e-9 || h <= 1e-9 { return nil }
    if min(w, h) / max(w, h) < minClosedBboxAspect { return nil }
    let rMax = min(w, h) / 2.0
    let nSteps = 40
    var bestR = 0.0, bestRms = Double.infinity
    for i in 0...nSteps {
        let r = rMax * Double(i) / Double(nSteps)
        let rms = roundRectRms(pts, xmin, ymin, w, h, r)
        if rms < bestRms { bestRms = rms; bestR = r }
    }
    let step = rMax / Double(nSteps)
    var lo = max(bestR - step, 0.0), hi = min(bestR + step, rMax)
    for _ in 0..<30 {
        let m1 = lo + (hi - lo) * 0.382
        let m2 = lo + (hi - lo) * 0.618
        let r1 = roundRectRms(pts, xmin, ymin, w, h, m1)
        let r2 = roundRectRms(pts, xmin, ymin, w, h, m2)
        if r1 < r2 { hi = m2 } else { lo = m1 }
    }
    let r = (lo + hi) / 2.0
    let rms = roundRectRms(pts, xmin, ymin, w, h, r)
    return (xmin, ymin, w, h, r, rms)
}

private func rdp(_ pts: [Pt], _ epsilon: Double) -> [Pt] {
    guard pts.count >= 3 else { return pts }
    var keep = [Bool](repeating: false, count: pts.count)
    keep[0] = true; keep[pts.count - 1] = true
    rdpRecurse(pts, 0, pts.count - 1, epsilon, &keep)
    return pts.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
}

private func rdpRecurse(_ pts: [Pt], _ start: Int, _ end: Int,
                         _ eps: Double, _ keep: inout [Bool]) {
    if end <= start + 1 { return }
    let a = pts[start], b = pts[end]
    var maxD = 0.0, maxI = start
    for i in (start + 1)..<end {
        let d = pointToSegmentDist(pts[i], a, b)
        if d > maxD { maxD = d; maxI = i }
    }
    if maxD > eps {
        keep[maxI] = true
        rdpRecurse(pts, start, maxI, eps, &keep)
        rdpRecurse(pts, maxI, end, eps, &keep)
    }
}

private func fitScribble(_ pts: [Pt], _ diag: Double) -> ([Pt], Double)? {
    guard pts.count >= 6 else { return nil }
    let totalArc = arcLength(pts)
    if totalArc < 1.5 * diag { return nil }
    let eps = 0.05 * diag
    let simplified = rdp(pts, eps)
    if simplified.count < 5 { return nil }
    var signChanges = 0
    var lastSign = 0.0
    for i in 1..<(simplified.count - 1) {
        let prev = simplified[i - 1], curr = simplified[i], next = simplified[i + 1]
        let v1 = (curr.0 - prev.0, curr.1 - prev.1)
        let v2 = (next.0 - curr.0, next.1 - curr.1)
        let cross = v1.0 * v2.1 - v1.1 * v2.0
        if abs(cross) < 1e-9 { continue }
        let sign = cross > 0 ? 1.0 : -1.0
        if lastSign != 0.0 && sign != lastSign { signChanges += 1 }
        lastSign = sign
    }
    if signChanges < 2 { return nil }
    var sqSum = 0.0
    for p in pts {
        var minD = Double.infinity
        for i in 0..<(simplified.count - 1) {
            let d = pointToSegmentDist(p, simplified[i], simplified[i + 1])
            if d < minD { minD = d }
        }
        sqSum += minD * minD
    }
    return (simplified, sqrt(sqSum / Double(pts.count)))
}

private func fitTriangle(_ pts: [Pt]) -> ((Pt, Pt, Pt), Double)? {
    guard pts.count >= 3 else { return nil }
    var maxD = 0.0, ai = 0, bi = 0
    for i in 0..<pts.count {
        for j in (i + 1)..<pts.count {
            let d = dist(pts[i], pts[j])
            if d > maxD { maxD = d; ai = i; bi = j }
        }
    }
    if maxD < 1e-9 { return nil }
    let pa = pts[ai], pb = pts[bi]
    var maxPerp = 0.0, ci = 0
    for (i, p) in pts.enumerated() {
        if i == ai || i == bi { continue }
        let d = pointToLineDist(p, pa, pb)
        if d > maxPerp { maxPerp = d; ci = i }
    }
    if maxPerp < 1e-9 { return nil }
    if maxPerp / maxD < 0.05 { return nil }
    let pc = pts[ci]
    let verts = (pa, pb, pc)
    let edges: [(Pt, Pt)] = [(pa, pb), (pb, pc), (pc, pa)]
    var sqSum = 0.0
    for p in pts {
        var minD = Double.infinity
        for (e0, e1) in edges {
            let d = pointToSegmentDist(p, e0, e1)
            if d < minD { minD = d }
        }
        sqSum += minD * minD
    }
    return (verts, sqrt(sqSum / Double(pts.count)))
}

private func countSelfIntersections(_ pts: [Pt]) -> Int {
    func ccw(_ a: Pt, _ b: Pt, _ c: Pt) -> Double {
        (b.0 - a.0) * (c.1 - a.1) - (b.1 - a.1) * (c.0 - a.0)
    }
    func segmentsIntersect(_ a1: Pt, _ a2: Pt, _ b1: Pt, _ b2: Pt) -> Bool {
        let d1 = ccw(b1, b2, a1), d2 = ccw(b1, b2, a2)
        let d3 = ccw(a1, a2, b1), d4 = ccw(a1, a2, b2)
        return d1 * d2 < 0 && d3 * d4 < 0
    }
    let n = pts.count
    guard n >= 4 else { return 0 }
    let nSegs = n - 1
    var count = 0
    for i in 0..<nSegs {
        guard i + 2 < nSegs else { continue }
        for j in (i + 2)..<nSegs {
            if i == 0 && j == nSegs - 1 {
                if dist(pts[0], pts[n - 1]) < 1e-6 { continue }
            }
            if segmentsIntersect(pts[i], pts[i + 1], pts[j], pts[j + 1]) { count += 1 }
        }
    }
    return count
}

private func fitLemniscate(_ pts: [Pt]) -> (Double, Double, Double, Bool, Double)? {
    let (xmin, ymin, xmax, ymax) = bboxOf(pts)
    let w = xmax - xmin, h = ymax - ymin
    if w <= 1e-9 || h <= 1e-9 { return nil }
    let cx = (xmin + xmax) / 2.0, cy = (ymin + ymax) / 2.0
    let horizontal = w >= h
    let a = horizontal ? w / 2.0 : h / 2.0
    let cross = horizontal ? h : w
    let expectedCross = a * sqrt(2.0) / 2.0
    if abs(cross / expectedCross - 1.0) > 0.20 { return nil }

    let nSamples = 200
    var samples: [Pt] = []
    samples.reserveCapacity(nSamples)
    for i in 0..<nSamples {
        let t = 2.0 * Double.pi * Double(i) / Double(nSamples)
        let s = sin(t), c = cos(t)
        let denom = 1.0 + s * s
        let lx = a * c / denom, ly = a * s * c / denom
        if horizontal {
            samples.append((cx + lx, cy + ly))
        } else {
            samples.append((cx + ly, cy + lx))
        }
    }
    var sqSum = 0.0
    for p in pts {
        var minDSq = Double.infinity
        for s in samples {
            let dx = p.0 - s.0, dy = p.1 - s.1
            let d2 = dx * dx + dy * dy
            if d2 < minDSq { minDSq = d2 }
        }
        sqSum += minDSq
    }
    return (cx, cy, a, horizontal, sqrt(sqSum / Double(pts.count)))
}

private func fitArrow(_ pts: [Pt], _ diag: Double) -> (Pt, Pt, Double, Double, Double, Double)? {
    guard pts.count >= 7 else { return nil }
    var corners: [Pt] = []
    for frac in [0.04, 0.02, 0.01, 0.005] {
        let eps = frac * diag
        var s = rdp(pts, eps)
        if s.count >= 2 && dist(s[0], s[s.count - 1]) < max(eps, 1e-6) {
            s.removeLast()
        }
        if s.count == 7 { corners = s; break }
    }
    guard corners.count == 7 else { return nil }
    let n = corners.count

    let crossSigns: [Double] = (0..<n).map { i in
        let prev = corners[(i + n - 1) % n]
        let curr = corners[i]
        let next = corners[(i + 1) % n]
        let v1 = (prev.0 - curr.0, prev.1 - curr.1)
        let v2 = (next.0 - curr.0, next.1 - curr.1)
        return v2.0 * v1.1 - v2.1 * v1.0
    }
    let positives = crossSigns.filter { $0 > 0 }.count
    let negatives = n - positives
    guard max(positives, negatives) == 5, min(positives, negatives) == 2 else { return nil }
    let majorityPositive = positives > negatives

    let isMajority = { (s: Double) -> Bool in (s > 0) == majorityPositive }
    var tipIdxOpt: Int? = nil
    for i in 0..<n {
        if isMajority(crossSigns[i])
            && isMajority(crossSigns[(i + n - 1) % n])
            && isMajority(crossSigns[(i + 1) % n]) {
            if tipIdxOpt != nil { return nil }
            tipIdxOpt = i
        }
    }
    guard let tipIdx = tipIdxOpt else { return nil }
    let tip = corners[tipIdx]

    let c = { (k: Int) -> Pt in
        let idx = ((tipIdx + k) % n + n) % n
        return corners[idx]
    }

    let headBackA = c(-1), headBackB = c(1)
    let shaftEndA = c(-2), shaftEndB = c(2)
    let tailA = c(-3), tailB = c(3)

    let tail: Pt = ((tailA.0 + tailB.0) / 2.0, (tailA.1 + tailB.1) / 2.0)
    let dx = tip.0 - tail.0, dy = tip.1 - tail.1
    let len = sqrt(dx * dx + dy * dy)
    if len < 1e-9 { return nil }
    let nx = abs(dx / len), ny = abs(dy / len)
    if max(nx, ny) < 0.95 { return nil }

    let shaftHalfWidth = dist(tailA, tailB) / 2.0
    let headHalfWidth = dist(headBackA, headBackB) / 2.0
    let shaftEndMid: Pt = ((shaftEndA.0 + shaftEndB.0) / 2.0, (shaftEndA.1 + shaftEndB.1) / 2.0)
    let headLen = dist(tip, shaftEndMid)

    if headHalfWidth <= shaftHalfWidth { return nil }
    if shaftHalfWidth < 1e-6 || headLen < 1e-6 { return nil }

    let arrowCorners = [tailA, shaftEndA, headBackA, tip, headBackB, shaftEndB, tailB]
    let edges: [(Pt, Pt)] = (0..<7).map { i in (arrowCorners[i], arrowCorners[(i + 1) % 7]) }
    var sqSum = 0.0
    for p in pts {
        var minD = Double.infinity
        for (e0, e1) in edges {
            let d = pointToSegmentDist(p, e0, e1)
            if d < minD { minD = d }
        }
        sqSum += minD * minD
    }
    return (tail, tip, headLen, headHalfWidth, shaftHalfWidth, sqrt(sqSum / Double(pts.count)))
}
