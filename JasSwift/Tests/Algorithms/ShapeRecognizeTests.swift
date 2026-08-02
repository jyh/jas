import Foundation
import Testing
@testable import JasLib

// MARK: - Deterministic PRNG (seeded LCG)

private func lcg(_ seed: inout UInt64) -> Double {
    seed = seed &* 1664525 &+ 1013904223
    let v = Double(seed >> 11) / Double(UInt64(1) << 53)
    return 2.0 * v - 1.0
}

// MARK: - Synthetic generators

private func sampleLine(_ a: Pt, _ b: Pt, _ n: Int) -> [Pt] {
    (0..<n).map { i in
        let t = Double(i) / Double(n - 1)
        return (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
    }
}

private func sampleTriangle(_ a: Pt, _ b: Pt, _ c: Pt, _ nPerSide: Int) -> [Pt] {
    var pts: [Pt] = []
    for (p, q) in [(a, b), (b, c), (c, a)] {
        let side = sampleLine(p, q, nPerSide)
        pts.append(contentsOf: side.dropLast())
    }
    pts.append(a)
    return pts
}

private func sampleRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ nPerSide: Int) -> [Pt] {
    let p0: Pt = (x, y), p1: Pt = (x + w, y), p2: Pt = (x + w, y + h), p3: Pt = (x, y + h)
    var pts: [Pt] = []
    for (p, q) in [(p0, p1), (p1, p2), (p2, p3), (p3, p0)] {
        let side = sampleLine(p, q, nPerSide)
        pts.append(contentsOf: side.dropLast())
    }
    pts.append(p0)
    return pts
}

private func sampleRoundRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
                              _ r: Double, _ n: Int) -> [Pt] {
    let arcN = max(n / 16, 4)
    let sideN = max(n / 8, 4)
    var pts: [Pt] = []
    func arc(_ pts: inout [Pt], _ cx: Double, _ cy: Double, _ a0: Double, _ a1: Double, _ k: Int) {
        for i in 0..<k {
            let t = Double(i) / Double(k)
            let a = a0 + (a1 - a0) * t
            pts.append((cx + r * cos(a), cy + r * sin(a)))
        }
    }
    func line(_ pts: inout [Pt], _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ k: Int) {
        for i in 0..<k {
            let t = Double(i) / Double(k)
            pts.append((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t))
        }
    }
    line(&pts, x + r, y, x + w - r, y, sideN)
    arc(&pts, x + w - r, y + r, -.pi / 2, 0, arcN)
    line(&pts, x + w, y + r, x + w, y + h - r, sideN)
    arc(&pts, x + w - r, y + h - r, 0, .pi / 2, arcN)
    line(&pts, x + w - r, y + h, x + r, y + h, sideN)
    arc(&pts, x + r, y + h - r, .pi / 2, .pi, arcN)
    line(&pts, x, y + h - r, x, y + r, sideN)
    arc(&pts, x + r, y + r, .pi, 3 * .pi / 2, arcN)
    pts.append((x + r, y))
    return pts
}

private func sampleCircle(_ cx: Double, _ cy: Double, _ r: Double, _ n: Int) -> [Pt] {
    (0...n).map { i in
        let a = 2 * Double.pi * Double(i) / Double(n)
        return (cx + r * cos(a), cy + r * sin(a))
    }
}

private func sampleEllipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ n: Int) -> [Pt] {
    (0...n).map { i in
        let a = 2 * Double.pi * Double(i) / Double(n)
        return (cx + rx * cos(a), cy + ry * sin(a))
    }
}

private func sampleArrowOutline(_ tail: Pt, _ tip: Pt, _ headLen: Double,
                                 _ headHalfW: Double, _ shaftHalfW: Double) -> [Pt] {
    let dx = tip.0 - tail.0, dy = tip.1 - tail.1
    let corners: [Pt]
    if abs(dy) < 1e-9 {
        let dir = dx > 0 ? 1.0 : -1.0
        let sex = tip.0 - dir * headLen
        corners = [
            (tail.0, tail.1 - shaftHalfW), (sex, tail.1 - shaftHalfW),
            (sex, tail.1 - headHalfW), (tip.0, tip.1),
            (sex, tail.1 + headHalfW), (sex, tail.1 + shaftHalfW),
            (tail.0, tail.1 + shaftHalfW),
        ]
    } else {
        let dir = dy > 0 ? 1.0 : -1.0
        let sey = tip.1 - dir * headLen
        corners = [
            (tail.0 - shaftHalfW, tail.1), (tail.0 - shaftHalfW, sey),
            (tail.0 - headHalfW, sey), (tip.0, tip.1),
            (tail.0 + headHalfW, sey), (tail.0 + shaftHalfW, sey),
            (tail.0 + shaftHalfW, tail.1),
        ]
    }
    var pts: [Pt] = []
    for i in 0..<corners.count {
        let p = corners[i], q = corners[(i + 1) % corners.count]
        let side = sampleLine(p, q, 10)
        pts.append(contentsOf: side.dropLast())
    }
    pts.append(corners[0])
    return pts
}

private func sampleLemniscate(_ cx: Double, _ cy: Double, _ a: Double,
                               _ horizontal: Bool, _ n: Int) -> [Pt] {
    (0...n).map { i in
        let t = 2.0 * Double.pi * Double(i) / Double(n)
        let s = sin(t), c = cos(t)
        let denom = 1.0 + s * s
        let lx = a * c / denom, ly = a * s * c / denom
        return horizontal ? (cx + lx, cy + ly) : (cx + ly, cy + lx)
    }
}

private func sampleZigzag(_ xStart: Double, _ yCenter: Double, _ xStep: Double,
                            _ yAmplitude: Double, _ nZags: Int, _ ptsPerSeg: Int) -> [Pt] {
    let vertices: [Pt] = (0...nZags).map { i in
        let x = xStart + xStep * Double(i)
        let y = i % 2 == 0 ? yCenter - yAmplitude : yCenter + yAmplitude
        return (x, y)
    }
    var pts: [Pt] = []
    for i in 0..<(vertices.count - 1) {
        let seg = sampleLine(vertices[i], vertices[i + 1], ptsPerSeg)
        pts.append(contentsOf: seg.dropLast())
    }
    pts.append(vertices.last!)
    return pts
}

private func jitter(_ pts: [Pt], _ seed: UInt64, _ amplitude: Double) -> [Pt] {
    var s = seed
    return pts.map { (x, y) in (x + amplitude * lcg(&s), y + amplitude * lcg(&s)) }
}

private func openGap(_ pts: [Pt], _ frac: Double) -> [Pt] {
    let keep = max(Int(Double(pts.count) * (1.0 - frac)), 2)
    return Array(pts[..<keep])
}

private func bboxDiag(_ pts: [Pt]) -> Double {
    var xmin = Double.infinity, xmax = -Double.infinity
    var ymin = Double.infinity, ymax = -Double.infinity
    for (x, y) in pts {
        if x < xmin { xmin = x }; if x > xmax { xmax = x }
        if y < ymin { ymin = y }; if y > ymax { ymax = y }
    }
    return ((xmax - xmin) * (xmax - xmin) + (ymax - ymin) * (ymax - ymin)).squareRoot()
}

private func rotatePts(_ pts: [Pt], _ cx: Double, _ cy: Double, _ theta: Double) -> [Pt] {
    let (s, c) = (sin(theta), cos(theta))
    return pts.map { (x, y) in
        let dx = x - cx, dy = y - cy
        return (cx + dx * c - dy * s, cy + dx * s + dy * c)
    }
}

private func assertClose(_ a: Double, _ b: Double, _ tol: Double, _ name: String,
                          sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(a - b) <= tol, "\(name): expected \(b), got \(a), tol \(tol)",
            sourceLocation: sourceLocation)
}

// MARK: - Generator sanity checks

@Test func generatorCircleHasExpectedRadius() {
    let pts = sampleCircle(50, 50, 30, 64)
    for (x, y) in pts {
        let r = ((x - 50) * (x - 50) + (y - 50) * (y - 50)).squareRoot()
        #expect(abs(r - 30) < 1e-9)
    }
}

@Test func generatorRoundRectRunsWithoutPanic() {
    let pts = sampleRoundRect(0, 0, 100, 60, 10, 200)
    #expect(pts.count > 50)
}

@Test func generatorLemniscatePassesThroughOriginOffset() {
    let pts = sampleLemniscate(100, 100, 40, true, 64)
    #expect(abs(pts[0].0 - 140) < 1e-9)
    #expect(abs(pts[0].1 - 100) < 1e-9)
}

@Test func jitterIsDeterministic() {
    let pts = sampleCircle(0, 0, 10, 32)
    let a = jitter(pts, 42, 0.5)
    let b = jitter(pts, 42, 0.5)
    for (p, q) in zip(a, b) {
        #expect(p.0 == q.0 && p.1 == q.1)
    }
}

// MARK: - Clean positive ID

@Test func recognizeCleanLine() {
    let pts = sampleLine((10, 20), (110, 20), 32)
    let cfg = RecognizeConfig()
    if case .line(let a, let b) = recognize(pts, cfg) {
        let tol = 0.02 * bboxDiag(pts)
        assertClose(min(a.0, b.0), 10, tol, "x_min")
        assertClose(max(a.0, b.0), 110, tol, "x_max")
        assertClose(a.1, 20, tol, "y1")
        assertClose(b.1, 20, tol, "y2")
    } else {
        Issue.record("expected Line")
    }
}

@Test func recognizeCleanTriangle() {
    let pts = sampleTriangle((0, 0), (100, 0), (50, 86.6), 20)
    let cfg = RecognizeConfig()
    guard case .triangle = recognize(pts, cfg) else {
        Issue.record("expected Triangle"); return
    }
}

@Test func recognizeCleanRectangle() {
    let pts = sampleRect(10, 20, 100, 60, 16)
    let cfg = RecognizeConfig()
    if case .rectangle(let x, let y, let w, let h) = recognize(pts, cfg) {
        let tol = 0.02 * bboxDiag(pts)
        assertClose(x, 10, tol, "x"); assertClose(y, 20, tol, "y")
        assertClose(w, 100, tol, "w"); assertClose(h, 60, tol, "h")
    } else {
        Issue.record("expected Rectangle")
    }
}

@Test func recognizeCleanSquareEmitsRectangleWithEqualSides() {
    let pts = sampleRect(0, 0, 80, 80, 16)
    let cfg = RecognizeConfig()
    if case .rectangle(_, _, let w, let h) = recognize(pts, cfg) {
        #expect(abs(w - h) < 1e-6, "square should have w == h")
    } else {
        Issue.record("expected Rectangle")
    }
}

@Test func recognizeCleanRoundRect() {
    let pts = sampleRoundRect(0, 0, 120, 80, 15, 256)
    let cfg = RecognizeConfig()
    if case .roundRect(let x, let y, let w, let h, let r) = recognize(pts, cfg) {
        let tol = 0.04 * bboxDiag(pts)
        assertClose(x, 0, tol, "x"); assertClose(y, 0, tol, "y")
        assertClose(w, 120, tol, "w"); assertClose(h, 80, tol, "h")
        assertClose(r, 15, tol, "r")
    } else {
        Issue.record("expected RoundRect")
    }
}

@Test func recognizeCleanCircle() {
    let pts = sampleCircle(50, 50, 30, 64)
    let cfg = RecognizeConfig()
    if case .circle(let cx, let cy, let r) = recognize(pts, cfg) {
        let tol = 0.02 * bboxDiag(pts)
        assertClose(cx, 50, tol, "cx"); assertClose(cy, 50, tol, "cy")
        assertClose(r, 30, tol, "r")
    } else {
        Issue.record("expected Circle")
    }
}

@Test func recognizeCleanEllipse() {
    let pts = sampleEllipse(50, 50, 60, 30, 64)
    let cfg = RecognizeConfig()
    if case .ellipse(let cx, let cy, let rx, let ry) = recognize(pts, cfg) {
        let tol = 0.02 * bboxDiag(pts)
        assertClose(cx, 50, tol, "cx"); assertClose(cy, 50, tol, "cy")
        assertClose(rx, 60, tol, "rx"); assertClose(ry, 30, tol, "ry")
    } else {
        Issue.record("expected Ellipse")
    }
}

@Test func recognizeCleanArrowOutline() {
    let pts = sampleArrowOutline((0, 50), (100, 50), 25, 20, 8)
    let cfg = RecognizeConfig()
    if case .arrow(let tail, let tip, let headLen, let headHW, let shaftHW) = recognize(pts, cfg) {
        let tol = 0.05 * bboxDiag(pts)
        assertClose(tail.0, 0, tol, "tail.x"); assertClose(tip.0, 100, tol, "tip.x")
        assertClose(headLen, 25, tol, "headLen")
        assertClose(headHW, 20, tol, "headHW"); assertClose(shaftHW, 8, tol, "shaftHW")
    } else {
        Issue.record("expected Arrow")
    }
}

@Test func recognizeCleanLemniscateHorizontal() {
    let pts = sampleLemniscate(100, 100, 50, true, 128)
    let cfg = RecognizeConfig()
    if case .lemniscate(let center, let a, let horizontal) = recognize(pts, cfg) {
        let tol = 0.05 * bboxDiag(pts)
        assertClose(center.0, 100, tol, "cx"); assertClose(center.1, 100, tol, "cy")
        assertClose(a, 50, tol, "a"); #expect(horizontal)
    } else {
        Issue.record("expected Lemniscate")
    }
}

@Test func recognizeCleanLemniscateVertical() {
    let pts = sampleLemniscate(0, 0, 30, false, 128)
    let cfg = RecognizeConfig()
    if case .lemniscate(_, _, let horizontal) = recognize(pts, cfg) {
        #expect(!horizontal)
    } else {
        Issue.record("expected Lemniscate")
    }
}

// MARK: - Noisy positive ID

@Test func recognizeNoisyCircle() {
    let clean = sampleCircle(50, 50, 30, 64)
    let pts = jitter(clean, 1, 0.03 * bboxDiag(clean))
    let cfg = RecognizeConfig()
    if case .circle(let cx, let cy, let r) = recognize(pts, cfg) {
        let tol = 0.05 * bboxDiag(clean)
        assertClose(cx, 50, tol, "cx"); assertClose(cy, 50, tol, "cy")
        assertClose(r, 30, tol, "r")
    } else {
        Issue.record("expected Circle")
    }
}

@Test func recognizeNoisyRectangle() {
    let clean = sampleRect(0, 0, 100, 60, 16)
    let pts = jitter(clean, 2, 0.03 * bboxDiag(clean))
    guard case .rectangle = recognize(pts, RecognizeConfig()) else {
        Issue.record("expected Rectangle"); return
    }
}

@Test func recognizeNoisyEllipse() {
    let clean = sampleEllipse(0, 0, 60, 30, 64)
    let pts = jitter(clean, 3, 0.03 * bboxDiag(clean))
    guard case .ellipse = recognize(pts, RecognizeConfig()) else {
        Issue.record("expected Ellipse"); return
    }
}

@Test func recognizeNoisyTriangle() {
    let clean = sampleTriangle((0, 0), (100, 0), (50, 86.6), 20)
    let pts = jitter(clean, 4, 0.03 * bboxDiag(clean))
    guard case .triangle = recognize(pts, RecognizeConfig()) else {
        Issue.record("expected Triangle"); return
    }
}

// MARK: - Closed/open dispatch

@Test func nearlyClosedPolylineTreatedAsClosed() {
    let clean = sampleRect(0, 0, 100, 60, 16)
    let pts = openGap(clean, 0.05)
    guard case .rectangle = recognize(pts, RecognizeConfig()) else {
        Issue.record("expected Rectangle"); return
    }
}

@Test func clearlyOpenPolylineNotRectangle() {
    let clean = sampleRect(0, 0, 100, 60, 16)
    let pts = openGap(clean, 0.25)
    if case .rectangle = recognize(pts, RecognizeConfig()) {
        Issue.record("clearly open path should not classify as Rectangle")
    }
}

@Test func recognizePathViaBezierInput() {
    let d: [PathCommand] = [
        .moveTo(0, 0), .lineTo(100, 0), .lineTo(100, 100), .lineTo(0, 100), .closePath,
    ]
    guard case .rectangle = recognizePath(d, RecognizeConfig()) else {
        Issue.record("expected Rectangle"); return
    }
}

// MARK: - Disambiguation edge cases

@Test func squareWithAspect104IsSquare() {
    let pts = sampleRect(0, 0, 104, 100, 16)
    if case .rectangle(_, _, let w, let h) = recognize(pts, RecognizeConfig()) {
        #expect(abs(w - h) < 1e-6, "near-square should snap")
    } else {
        Issue.record("expected Rectangle")
    }
}

@Test func rectWithAspect115IsNotSquare() {
    let pts = sampleRect(0, 0, 115, 100, 16)
    if case .rectangle(_, _, let w, let h) = recognize(pts, RecognizeConfig()) {
        #expect(abs(w - h) > 1, "1.15 aspect should NOT snap")
    } else {
        Issue.record("expected Rectangle")
    }
}

@Test func nearlyCircularEllipseIsCircle() {
    let pts = sampleEllipse(0, 0, 30, 29.5, 64)
    guard case .circle = recognize(pts, RecognizeConfig()) else {
        Issue.record("expected Circle"); return
    }
}

@Test func clearlyEllipticalIsEllipse() {
    let pts = sampleEllipse(0, 0, 30, 15, 64)
    guard case .ellipse = recognize(pts, RecognizeConfig()) else {
        Issue.record("expected Ellipse"); return
    }
}

@Test func tinyCornerRadiusIsPlainRect() {
    let pts = sampleRoundRect(0, 0, 100, 60, 1, 256)
    guard case .rectangle = recognize(pts, RecognizeConfig()) else {
        Issue.record("expected Rectangle"); return
    }
}

@Test func flatTriangleIsLine() {
    let pts = sampleTriangle((0, 0), (100, 0), (50, 0.5), 20)
    guard case .line = recognize(pts, RecognizeConfig()) else {
        Issue.record("expected Line"); return
    }
}

@Test func randomScribbleReturnsNone() {
    var s: UInt64 = 99
    let pts: [Pt] = (0..<64).map { _ in (50 + 50 * lcg(&s), 50 + 50 * lcg(&s)) }
    #expect(recognize(pts, RecognizeConfig()) == nil)
}

@Test func nearlyStraightArrowOutlineStillRecognized() {
    let pts = sampleArrowOutline((0, 50), (200, 50), 20, 15, 4)
    guard case .arrow = recognize(pts, RecognizeConfig()) else {
        Issue.record("expected Arrow"); return
    }
}

@Test func tiltedSquareReturnsNone() {
    let clean = sampleRect(-50, -50, 100, 100, 16)
    let pts = rotatePts(clean, 0, 0, 30.0 * (Double.pi / 180))
    let result = recognize(pts, RecognizeConfig())
    if case .rectangle = result {
        Issue.record("tilted square should NOT classify as Rectangle")
    }
}

@Test func lemniscateOffCenterCrossingReturnsNone() {
    let pts = sampleLemniscate(0, 0, 50, true, 128)
    let skewed: [Pt] = pts.map { (x, y) in x > 0 ? (x + 30, y) : (x, y) }
    #expect(recognize(skewed, RecognizeConfig()) == nil)
}

// MARK: - Element conversion

@Test func recognizedToElementPreservesStrokeAndCommon() {
    let template = Element.path(Path(d: [],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 2.5),
        opacity: 0.7, fillRule: .nonzero))
    let shape = RecognizedShape.rectangle(x: 10, y: 20, w: 30, h: 40)
    if case .rect(let r) = recognizedToElement(shape, template) {
        #expect(r.x == 10); #expect(r.width == 30); #expect(r.height == 40)
        #expect(r.rx == 0)
        #expect(abs(r.stroke!.width - 2.5) < 1e-9)
        #expect(abs(r.opacity - 0.7) < 1e-9)
    } else {
        Issue.record("expected Rect")
    }
}

@Test func recognizedToElementRoundRectSetsRxRy() {
    let template = Element.path(Path(d: [], fillRule: .nonzero))
    let shape = RecognizedShape.roundRect(x: 0, y: 0, w: 100, h: 60, r: 12)
    if case .rect(let r) = recognizedToElement(shape, template) {
        #expect(r.rx == 12); #expect(r.ry == 12)
    } else {
        Issue.record("expected Rect")
    }
}

@Test func recognizedToElementArrowEmitsPolygon() {
    let template = Element.path(Path(d: [], fillRule: .nonzero))
    let shape = RecognizedShape.arrow(tail: (0, 0), tip: (100, 0),
        headLen: 25, headHalfWidth: 20, shaftHalfWidth: 8)
    if case .polygon(let p) = recognizedToElement(shape, template) {
        #expect(p.points.count == 7)
        #expect(abs(p.points[3].0 - 100) < 1e-9)
        #expect(abs(p.points[3].1) < 1e-9)
    } else {
        Issue.record("expected Polygon")
    }
}

// MARK: - Scribble tests

@Test func recognizeCleanZigzagScribble() {
    let pts = sampleZigzag(0, 50, 20, 30, 8, 10)
    if case .scribble(let points) = recognize(pts, RecognizeConfig()) {
        #expect(points.count >= 5, "expected ≥5 vertices, got \(points.count)")
    } else {
        Issue.record("expected Scribble")
    }
}

@Test func recognizeNoisyZigzagScribble() {
    let clean = sampleZigzag(0, 50, 15, 25, 10, 10)
    let pts = jitter(clean, 7, 0.02 * bboxDiag(clean))
    guard case .scribble = recognize(pts, RecognizeConfig()) else {
        Issue.record("expected Scribble"); return
    }
}

@Test func straightLineNotScribble() {
    let pts = sampleLine((0, 0), (200, 0), 64)
    let result = recognize(pts, RecognizeConfig())
    if case .scribble = result {
        Issue.record("straight line should not be Scribble")
    }
    guard case .line = result else {
        Issue.record("expected Line, got \(String(describing: result))"); return
    }
}

@Test func diagonalLineNotScribble() {
    let pts = sampleLine((0, 0), (100, 80), 64)
    guard case .line = recognize(pts, RecognizeConfig()) else {
        Issue.record("expected Line"); return
    }
}

@Test func recognizedToElementScribbleEmitsPolyline() {
    let template = Element.path(Path(d: [], fillRule: .nonzero))
    let shape = RecognizedShape.scribble(points: [(0, 0), (10, 20), (20, 0), (30, 20), (40, 0)])
    if case .polyline(let p) = recognizedToElement(shape, template) {
        #expect(p.points.count == 5)
    } else {
        Issue.record("expected Polyline")
    }
}

// MARK: - recognize_element tests

@Test func recognizeElementSkipsLine() {
    let elem = Element.line(Line(x1: 0, y1: 0, x2: 100, y2: 0))
    #expect(recognizeElement(elem, RecognizeConfig()) == nil)
}

@Test func recognizeElementSkipsRect() {
    let elem = Element.rect(Rect(x: 0, y: 0, width: 100, height: 60))
    #expect(recognizeElement(elem, RecognizeConfig()) == nil)
}

@Test func recognizeElementSkipsCircle() {
    let elem = Element.ellipse(Ellipse(cx: 50, cy: 50, rx: 30, ry: 30))
    #expect(recognizeElement(elem, RecognizeConfig()) == nil)
}

@Test func recognizeElementSkipsPolygon() {
    let elem = Element.polygon(Polygon(points: [(0, 0), (100, 0), (50, 86.6)]))
    #expect(recognizeElement(elem, RecognizeConfig()) == nil)
}

@Test func recognizeElementConvertsPathCircle() {
    let pts = sampleCircle(50, 50, 30, 64)
    let d: [PathCommand] = pts.enumerated().map { i, p in
        i == 0 ? .moveTo(p.0, p.1) : .lineTo(p.0, p.1)
    }
    let elem = Element.path(Path(d: d, fillRule: .nonzero))
    if let (kind, result) = recognizeElement(elem, RecognizeConfig()) {
        // The RECOGNISER still recognises a circle; the ELEMENT it builds is
        // the one round kind. Those are different axes and both are asserted.
        #expect(kind == .circle)
        guard case .ellipse = result else {
            Issue.record("expected a round ellipse element"); return
        }
    } else {
        Issue.record("expected recognition result")
    }
}

@Test func recognizeElementSquareReturnsSquareKind() {
    let pts = sampleRect(0, 0, 80, 80, 16)
    let d: [PathCommand] = pts.enumerated().map { i, p in
        i == 0 ? .moveTo(p.0, p.1) : .lineTo(p.0, p.1)
    }
    let elem = Element.path(Path(d: d, fillRule: .nonzero))
    if let (kind, result) = recognizeElement(elem, RecognizeConfig()) {
        #expect(kind == .square)
        guard case .rect = result else {
            Issue.record("expected Rect element"); return
        }
    } else {
        Issue.record("expected recognition result")
    }
}

// MARK: - Candidate precedence (JYH ruling, 2026-07-31)

/// The ruled tie-break order, transcribed from the ruling:
///
///     line, scribble, circle/ellipse, rectangle, roundRect,
///     triangle, lemniscate, arrow
///
/// Circle and ellipse share one slot (one ellipse fit, snapped either way),
/// as do rectangle and square.
private func ruledPrecedenceRank(_ kind: ShapeKind) -> Int {
    switch kind {
    case .line: return 0
    case .scribble: return 1
    case .circle, .ellipse: return 2
    case .rectangle, .square: return 3
    case .roundRect: return 4
    case .triangle: return 5
    case .lemniscate: return 6
    case .arrow: return 7
    }
}

/// The four points where an axis-aligned ellipse touches its own bounding
/// box: each lies EXACTLY on the box perimeter and EXACTLY on the ellipse.
/// Half-extents 30 and 40 make every side exactly 50 long, so arc-length
/// resampling to 5 points returns these four verbatim (no interpolation, no
/// rounding) and both fits see a perfect shape.
private func ellipseBboxTouchPoints() -> [Pt] {
    [(30, 0), (0, 40), (-30, 0), (0, -40), (30, 0)]
}

/// Config that hands the recogniser exactly the five points above.
private func touchPointCfg() -> RecognizeConfig {
    RecognizeConfig(resampleN: 5)
}

@Test func ellipseAndRectangleResidualsTieExactly() {
    // Instrumentation, kept as a test in its own right: without a genuine
    // tie the precedence test below would be pinning a comparison that
    // never happens.
    let cands = recognizeCandidates(ellipseBboxTouchPoints(), touchPointCfg())
    #expect(cands.count == 2,
            "expected exactly the ellipse and rectangle fits, got \(cands.map { ($1.kind, $0) })")
    guard cands.count == 2 else { return }
    // Equal as Double — not "within epsilon". Both fits are perfect.
    #expect(cands[0].0 == cands[1].0)
    #expect(cands[0].0 == 0.0)
}

@Test func tiedEllipseAndRectangleResolveToEllipse() {
    // The ruling: circle/ellipse outranks rectangle, so when the two fit
    // equally well the stroke commits as an ellipse. Swap the two appends
    // in `recognizeCandidates` and this stroke silently becomes a 60x80
    // rectangle instead.
    let pts = ellipseBboxTouchPoints()
    let cfg = touchPointCfg()
    let kinds = recognizeCandidates(pts, cfg).map { $1.kind }
    #expect(kinds == [.ellipse, .rectangle])

    if case .ellipse(let cx, let cy, let rx, let ry) = recognize(pts, cfg) {
        #expect(cx == 0 && cy == 0 && rx == 30 && ry == 40)
    } else {
        Issue.record("tie must resolve to the ellipse, got \(String(describing: recognize(pts, cfg)))")
    }
}

@Test func candidateOrderFollowsTheRuledPrecedence() {
    // Inputs chosen because each produces MORE THAN ONE candidate — an
    // ordering claim over single-candidate lists proves nothing.
    let cfg = RecognizeConfig()
    let cases: [(String, [Pt])] = [
        // line + scribble: shallow enough that the straight fit also lands
        // inside tolerance.
        ("shallow zigzag", sampleZigzag(0, 0, 25, 15, 8, 10)),
        // ellipse + rectangle + roundRect
        ("round rect", sampleRoundRect(0, 0, 120, 80, 15, 256)),
        // circle + square
        ("circle", sampleCircle(50, 50, 30, 64)),
        // ellipse + rectangle
        ("ellipse", sampleEllipse(50, 50, 60, 30, 64)),
        // line + ellipse + rectangle + triangle + arrow
        ("long thin arrow", sampleArrowOutline((0, 50), (200, 50), 20, 15, 4)),
        ("noisy rect", jitter(sampleRect(0, 0, 100, 60, 16), 2, 3.5)),
        ("nearly closed rect", openGap(sampleRect(0, 0, 100, 60, 16), 0.05)),
    ]

    var multiCandidateCases = 0
    var ranksSeen: Set<Int> = []
    for (name, pts) in cases {
        let kinds = recognizeCandidates(pts, cfg).map { $1.kind }
        let ranks = kinds.map(ruledPrecedenceRank)
        let ascending = zip(ranks, ranks.dropFirst()).allSatisfy { $0 < $1 }
        #expect(ascending, """
            \(name): candidates \(kinds) (ranks \(ranks)) are not in the ruled \
            precedence order line, scribble, circle/ellipse, rectangle, roundRect, \
            triangle, lemniscate, arrow
            """)
        if kinds.count > 1 {
            multiCandidateCases += 1
            ranksSeen.formUnion(ranks)
        }
    }

    // Vacuity guards. If a future change stops these inputs from producing
    // overlapping fits, the ordering above becomes unwatched and the test
    // must say so rather than keep passing.
    #expect(multiCandidateCases >= 5,
            "only \(multiCandidateCases) inputs produced competing candidates")
    // Every slot but the lemniscate is observed in a contested list. Nothing
    // can contest a lemniscate: its own aspect gate (cross extent within 20%
    // of a*sqrt(2)/2) puts every rival fit further from the points than the
    // tolerance allows.
    #expect(ranksSeen == [0, 1, 2, 3, 4, 5, 7],
            "precedence slots exercised by this corpus changed: \(ranksSeen.sorted())")
}
