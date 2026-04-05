import Testing
@testable import JasLib

@Test func colorDefaults() {
    let c = Color(r: 1.0, g: 0.0, b: 0.0)
    #expect(c.a == 1.0)
}

@Test func strokeDefaults() {
    let s = Stroke(color: Color(r: 0, g: 0, b: 0))
    #expect(s.width == 1.0)
    #expect(s.linecap == .butt)
    #expect(s.linejoin == .miter)
}

@Test func transformIdentity() {
    let t = Transform()
    #expect(t.a == 1 && t.d == 1 && t.e == 0)
}

@Test func transformTranslate() {
    let t = Transform.translate(10, 20)
    #expect(t.e == 10)
    #expect(t.f == 20)
}

@Test func transformScale() {
    let t = Transform.scale(2, 3)
    #expect(t.a == 2)
    #expect(t.d == 3)
}

@Test func transformRotate() {
    let t = Transform.rotate(90)
    #expect(abs(t.a) < 1e-10)
    #expect(abs(t.b - 1.0) < 1e-10)
}

@Test func lineBounds() {
    let ln = Line(x1: 0, y1: 0, x2: 10, y2: 20)
    let b = ln.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 10 && b.height == 20)
}

@Test func lineReversed() {
    let ln = Line(x1: 10, y1: 20, x2: 0, y2: 0)
    let b = ln.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 10 && b.height == 20)
}

@Test func rectBounds() {
    let r = Rect(x: 5, y: 10, width: 100, height: 50)
    let b = r.bounds
    #expect(b.x == 5 && b.y == 10 && b.width == 100 && b.height == 50)
}

@Test func rectRounded() {
    let r = Rect(x: 0, y: 0, width: 10, height: 10, rx: 2, ry: 2)
    #expect(r.rx == 2 && r.ry == 2)
}

@Test func circleBounds() {
    let c = Circle(cx: 50, cy: 50, r: 25)
    let b = c.bounds
    #expect(b.x == 25 && b.y == 25 && b.width == 50 && b.height == 50)
}

@Test func circleWithFillAndStroke() {
    let c = Circle(cx: 50, cy: 50, r: 25,
                      fill: Fill(color: Color(r: 0, g: 1, b: 0)),
                      stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 3.0))
    #expect(c.fill?.color.g == 1.0)
    #expect(c.stroke?.width == 3.0)
}

@Test func ellipseBounds() {
    let e = Ellipse(cx: 50, cy: 50, rx: 25, ry: 15)
    let b = e.bounds
    #expect(b.x == 25 && b.y == 35 && b.width == 50 && b.height == 30)
}

@Test func ellipseWithFillAndStroke() {
    let e = Ellipse(cx: 50, cy: 50, rx: 25, ry: 15,
                       fill: Fill(color: Color(r: 0, g: 0, b: 1)),
                       stroke: Stroke(color: Color(r: 1, g: 1, b: 1), linecap: .square))
    #expect(e.fill?.color.b == 1.0)
    #expect(e.stroke?.linecap == .square)
}

@Test func polylineBounds() {
    let pl = Polyline(points: [(0, 0), (10, 5), (20, 0)])
    let b = pl.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 20 && b.height == 5)
}

@Test func emptyPolylineBounds() {
    let pl = Polyline(points: [])
    let b = pl.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 0 && b.height == 0)
}

@Test func polygonBounds() {
    let pg = Polygon(points: [(0, 0), (10, 0), (5, 10)])
    let b = pg.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 10 && b.height == 10)
}

@Test func emptyPolygonBounds() {
    let pg = Polygon(points: [])
    let b = pg.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 0 && b.height == 0)
}

@Test func pathBounds() {
    let p = Path(d: [.moveTo(0, 0), .lineTo(10, 20), .lineTo(5, 15), .closePath])
    let b = p.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 10 && b.height == 20)
}

@Test func pathCubicBezier() {
    let p = Path(d: [.moveTo(0, 0), .curveTo(x1: 5, y1: 10, x2: 15, y2: 10, x: 20, y: 0)])
    let b = p.bounds
    #expect(b.x == 0 && b.width == 20)
}

@Test func pathSmoothCurveTo() {
    let p = Path(d: [.moveTo(0, 0), .curveTo(x1: 1, y1: 2, x2: 3, y2: 4, x: 5, y: 6), .smoothCurveTo(x2: 8, y2: 9, x: 10, y: 12)])
    let b = p.bounds
    #expect(b.x == 0 && b.width == 10 && b.height == 12)
}

@Test func pathQuadTo() {
    let p = Path(d: [.moveTo(0, 0), .quadTo(x1: 5, y1: 10, x: 10, y: 0)])
    let b = p.bounds
    #expect(b.x == 0 && b.width == 10)
}

@Test func pathSmoothQuadTo() {
    let p = Path(d: [.moveTo(0, 0), .quadTo(x1: 5, y1: 10, x: 10, y: 0), .smoothQuadTo(20, 5)])
    let b = p.bounds
    #expect(b.x == 0 && b.width == 20)
}

@Test func pathArcTo() {
    let p = Path(d: [.moveTo(0, 0), .arcTo(rx: 25, ry: 25, rotation: 0, largeArc: true, sweep: false, x: 50, y: 0)])
    let b = p.bounds
    #expect(b.x == 0 && b.width == 50)
}

@Test func pathEmpty() {
    let p = Path(d: [])
    let b = p.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 0 && b.height == 0)
}

@Test func pathWithFillAndStroke() {
    let fill = Fill(color: Color(r: 1, g: 0, b: 0))
    let stroke = Stroke(color: Color(r: 0, g: 0, b: 0), width: 2.0, linecap: .round)
    let p = Path(d: [.moveTo(0, 0), .lineTo(10, 10), .closePath], fill: fill, stroke: stroke)
    #expect(p.fill?.color.r == 1.0)
    #expect(p.stroke?.width == 2.0)
    #expect(p.stroke?.linecap == .round)
}

@Test func textBounds() {
    let t = Text(x: 10, y: 30, content: "Hello")
    let b = t.bounds
    #expect(b.x == 10)
    #expect(b.y == 14)  // y - fontSize
    #expect(b.width > 0)
    #expect(b.height == 16)
}

@Test func textAttributes() {
    let t = Text(x: 0, y: 0, content: "Hi", fontFamily: "monospace", fontSize: 24.0)
    #expect(t.fontFamily == "monospace")
    #expect(t.fontSize == 24.0)
}

@Test func groupBounds() {
    let r = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let e = Element.ellipse(Ellipse(cx: 100, cy: 100, rx: 5, ry: 5))
    let g = Group(children: [r, e])
    let b = g.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 105 && b.height == 105)
}

@Test func groupEmpty() {
    let g = Group(children: [])
    let b = g.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 0 && b.height == 0)
}

@Test func nestedGroup() {
    let inner = Element.group(Group(children: [.rect(Rect(x: 10, y: 10, width: 5, height: 5))]))
    let outer = Group(children: [.rect(Rect(x: 0, y: 0, width: 1, height: 1)), inner])
    let b = outer.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 15 && b.height == 15)
}

@Test func groupWithTransform() {
    let g = Group(children: [.rect(Rect(x: 0, y: 0, width: 10, height: 10))],
                     transform: .translate(100, 200))
    #expect(g.transform != nil)
    #expect(g.transform?.e == 100)
}

@Test func elementOpacity() {
    let r = Rect(x: 0, y: 0, width: 10, height: 10, opacity: 0.5)
    #expect(r.opacity == 0.5)
}

@Test func elementBoundsDispatch() {
    let pathEl = Element.path(Path(d: [.moveTo(0, 0), .lineTo(10, 10)]))
    let rectEl = Element.rect(Rect(x: 5, y: 5, width: 20, height: 20))
    #expect(pathEl.bounds.x == 0 && pathEl.bounds.width == 10)
    #expect(rectEl.bounds.x == 5 && rectEl.bounds.width == 20)
}

@Test func groupAllElementTypes() {
    let children: [Element] = [
        .line(Line(x1: 0, y1: 0, x2: 10, y2: 10)),
        .rect(Rect(x: 0, y: 0, width: 20, height: 20)),
        .circle(Circle(cx: 50, cy: 50, r: 10)),
        .ellipse(Ellipse(cx: 50, cy: 50, rx: 10, ry: 5)),
        .polyline(Polyline(points: [(0, 0), (10, 10)])),
        .polygon(Polygon(points: [(0, 0), (10, 0), (5, 10)])),
        .path(Path(d: [.moveTo(0, 0), .lineTo(10, 10)])),
        .text(Text(x: 0, y: 20, content: "test")),
    ]
    let g = Group(children: children)
    let b = g.bounds
    #expect(b.x == 0 && b.y == 0 && b.width > 0 && b.height > 0)
}

@Test func deeplyNestedGroups() {
    let inner = Group(children: [.rect(Rect(x: 10, y: 10, width: 5, height: 5))])
    let mid = Group(children: [.rect(Rect(x: 0, y: 0, width: 1, height: 1)), .group(inner)])
    let outer = Group(children: [.rect(Rect(x: 20, y: 20, width: 3, height: 3)), .group(mid)])
    let b = outer.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 23 && b.height == 23)
}

@Test func layerDefaultName() {
    let layer = Layer(children: [.rect(Rect(x: 0, y: 0, width: 10, height: 10))])
    #expect(layer.name == "Layer")
}

@Test func layerCustomName() {
    let layer = Layer(name: "Background", children: [.rect(Rect(x: 0, y: 0, width: 10, height: 10))])
    #expect(layer.name == "Background")
}

@Test func layerBounds() {
    let layer = Layer(name: "Shapes", children: [
        .rect(Rect(x: 0, y: 0, width: 10, height: 10)),
        .circle(Circle(cx: 50, cy: 50, r: 5)),
    ])
    let b = layer.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 55 && b.height == 55)
}

@Test func layerEmpty() {
    let layer = Layer(name: "Empty", children: [])
    let b = layer.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 0 && b.height == 0)
}

@Test func layerBoundsDispatch() {
    let layer = Element.layer(Layer(name: "Test", children: [.rect(Rect(x: 5, y: 5, width: 20, height: 20))]))
    #expect(layer.bounds.x == 5 && layer.bounds.width == 20)
}

// MARK: - Path offset tests

private let straightPath: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0)]

@Test func pointAtOffsetStart() {
    let (x, y) = pathPointAtOffset(straightPath, t: 0.0)
    #expect(abs(x) < 1e-6)
    #expect(abs(y) < 1e-6)
}

@Test func pointAtOffsetEnd() {
    let (x, y) = pathPointAtOffset(straightPath, t: 1.0)
    #expect(abs(x - 100) < 1e-6)
    #expect(abs(y) < 1e-6)
}

@Test func pointAtOffsetMidpoint() {
    let (x, y) = pathPointAtOffset(straightPath, t: 0.5)
    #expect(abs(x - 50) < 1e-6)
    #expect(abs(y) < 1e-6)
}

@Test func pointAtOffsetClampedBelow() {
    let (x, y) = pathPointAtOffset(straightPath, t: -1.0)
    #expect(abs(x) < 1e-6)
    #expect(abs(y) < 1e-6)
}

@Test func pointAtOffsetClampedAbove() {
    let (x, y) = pathPointAtOffset(straightPath, t: 2.0)
    #expect(abs(x - 100) < 1e-6)
    #expect(abs(y) < 1e-6)
}

@Test func pointAtOffsetMultiSegment() {
    let lPath: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0), .lineTo(100, 100)]
    let (x, y) = pathPointAtOffset(lPath, t: 0.5)
    #expect(abs(x - 100) < 1.0)
    #expect(abs(y) < 1.0)
}

@Test func closestOffsetOnLine() {
    let off = pathClosestOffset(straightPath, px: 50, py: 0)
    #expect(abs(off - 0.5) < 0.01)
}

@Test func closestOffsetStart() {
    let off = pathClosestOffset(straightPath, px: -10, py: 0)
    #expect(abs(off) < 0.01)
}

@Test func closestOffsetEnd() {
    let off = pathClosestOffset(straightPath, px: 200, py: 0)
    #expect(abs(off - 1.0) < 0.01)
}

@Test func closestOffsetPerpendicular() {
    let off = pathClosestOffset(straightPath, px: 50, py: 30)
    #expect(abs(off - 0.5) < 0.01)
}

@Test func distanceToPointOnPath() {
    let d = pathDistanceToPoint(straightPath, px: 50, py: 0)
    #expect(d < 1e-6)
}

@Test func distanceToPointPerpendicular() {
    let d = pathDistanceToPoint(straightPath, px: 50, py: 30)
    #expect(abs(d - 30) < 1e-6)
}
