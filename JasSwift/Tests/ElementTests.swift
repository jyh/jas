import Testing
@testable import JasLib

@Test func colorDefaults() {
    let c = JasColor(r: 1.0, g: 0.0, b: 0.0)
    #expect(c.a == 1.0)
}

@Test func strokeDefaults() {
    let s = JasStroke(color: JasColor(r: 0, g: 0, b: 0))
    #expect(s.width == 1.0)
    #expect(s.linecap == .butt)
    #expect(s.linejoin == .miter)
}

@Test func transformIdentity() {
    let t = JasTransform()
    #expect(t.a == 1 && t.d == 1 && t.e == 0)
}

@Test func transformTranslate() {
    let t = JasTransform.translate(10, 20)
    #expect(t.e == 10)
    #expect(t.f == 20)
}

@Test func transformScale() {
    let t = JasTransform.scale(2, 3)
    #expect(t.a == 2)
    #expect(t.d == 3)
}

@Test func transformRotate() {
    let t = JasTransform.rotate(90)
    #expect(abs(t.a) < 1e-10)
    #expect(abs(t.b - 1.0) < 1e-10)
}

@Test func lineBounds() {
    let ln = JasLine(x1: 0, y1: 0, x2: 10, y2: 20)
    let b = ln.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 10 && b.height == 20)
}

@Test func lineReversed() {
    let ln = JasLine(x1: 10, y1: 20, x2: 0, y2: 0)
    let b = ln.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 10 && b.height == 20)
}

@Test func rectBounds() {
    let r = JasRect(x: 5, y: 10, width: 100, height: 50)
    let b = r.bounds
    #expect(b.x == 5 && b.y == 10 && b.width == 100 && b.height == 50)
}

@Test func rectRounded() {
    let r = JasRect(x: 0, y: 0, width: 10, height: 10, rx: 2, ry: 2)
    #expect(r.rx == 2 && r.ry == 2)
}

@Test func circleBounds() {
    let c = JasCircle(cx: 50, cy: 50, r: 25)
    let b = c.bounds
    #expect(b.x == 25 && b.y == 25 && b.width == 50 && b.height == 50)
}

@Test func circleWithFillAndStroke() {
    let c = JasCircle(cx: 50, cy: 50, r: 25,
                      fill: JasFill(color: JasColor(r: 0, g: 1, b: 0)),
                      stroke: JasStroke(color: JasColor(r: 0, g: 0, b: 0), width: 3.0))
    #expect(c.fill?.color.g == 1.0)
    #expect(c.stroke?.width == 3.0)
}

@Test func ellipseBounds() {
    let e = JasEllipse(cx: 50, cy: 50, rx: 25, ry: 15)
    let b = e.bounds
    #expect(b.x == 25 && b.y == 35 && b.width == 50 && b.height == 30)
}

@Test func ellipseWithFillAndStroke() {
    let e = JasEllipse(cx: 50, cy: 50, rx: 25, ry: 15,
                       fill: JasFill(color: JasColor(r: 0, g: 0, b: 1)),
                       stroke: JasStroke(color: JasColor(r: 1, g: 1, b: 1), linecap: .square))
    #expect(e.fill?.color.b == 1.0)
    #expect(e.stroke?.linecap == .square)
}

@Test func polylineBounds() {
    let pl = JasPolyline(points: [(0, 0), (10, 5), (20, 0)])
    let b = pl.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 20 && b.height == 5)
}

@Test func emptyPolylineBounds() {
    let pl = JasPolyline(points: [])
    let b = pl.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 0 && b.height == 0)
}

@Test func polygonBounds() {
    let pg = JasPolygon(points: [(0, 0), (10, 0), (5, 10)])
    let b = pg.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 10 && b.height == 10)
}

@Test func emptyPolygonBounds() {
    let pg = JasPolygon(points: [])
    let b = pg.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 0 && b.height == 0)
}

@Test func pathBounds() {
    let p = JasPath(d: [.moveTo(0, 0), .lineTo(10, 20), .lineTo(5, 15), .closePath])
    let b = p.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 10 && b.height == 20)
}

@Test func pathCubicBezier() {
    let p = JasPath(d: [.moveTo(0, 0), .curveTo(x1: 5, y1: 10, x2: 15, y2: 10, x: 20, y: 0)])
    let b = p.bounds
    #expect(b.x == 0 && b.width == 20)
}

@Test func pathSmoothCurveTo() {
    let p = JasPath(d: [.moveTo(0, 0), .curveTo(x1: 1, y1: 2, x2: 3, y2: 4, x: 5, y: 6), .smoothCurveTo(x2: 8, y2: 9, x: 10, y: 12)])
    let b = p.bounds
    #expect(b.x == 0 && b.width == 10 && b.height == 12)
}

@Test func pathQuadTo() {
    let p = JasPath(d: [.moveTo(0, 0), .quadTo(x1: 5, y1: 10, x: 10, y: 0)])
    let b = p.bounds
    #expect(b.x == 0 && b.width == 10)
}

@Test func pathSmoothQuadTo() {
    let p = JasPath(d: [.moveTo(0, 0), .quadTo(x1: 5, y1: 10, x: 10, y: 0), .smoothQuadTo(20, 5)])
    let b = p.bounds
    #expect(b.x == 0 && b.width == 20)
}

@Test func pathArcTo() {
    let p = JasPath(d: [.moveTo(0, 0), .arcTo(rx: 25, ry: 25, rotation: 0, largeArc: true, sweep: false, x: 50, y: 0)])
    let b = p.bounds
    #expect(b.x == 0 && b.width == 50)
}

@Test func pathEmpty() {
    let p = JasPath(d: [])
    let b = p.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 0 && b.height == 0)
}

@Test func pathWithFillAndStroke() {
    let fill = JasFill(color: JasColor(r: 1, g: 0, b: 0))
    let stroke = JasStroke(color: JasColor(r: 0, g: 0, b: 0), width: 2.0, linecap: .round)
    let p = JasPath(d: [.moveTo(0, 0), .lineTo(10, 10), .closePath], fill: fill, stroke: stroke)
    #expect(p.fill?.color.r == 1.0)
    #expect(p.stroke?.width == 2.0)
    #expect(p.stroke?.linecap == .round)
}

@Test func textBounds() {
    let t = JasText(x: 10, y: 30, content: "Hello")
    let b = t.bounds
    #expect(b.x == 10)
    #expect(b.y == 14)  // y - fontSize
    #expect(b.width > 0)
    #expect(b.height == 16)
}

@Test func textAttributes() {
    let t = JasText(x: 0, y: 0, content: "Hi", fontFamily: "monospace", fontSize: 24.0)
    #expect(t.fontFamily == "monospace")
    #expect(t.fontSize == 24.0)
}

@Test func groupBounds() {
    let r = Element.rect(JasRect(x: 0, y: 0, width: 10, height: 10))
    let e = Element.ellipse(JasEllipse(cx: 100, cy: 100, rx: 5, ry: 5))
    let g = JasGroup(children: [r, e])
    let b = g.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 105 && b.height == 105)
}

@Test func groupEmpty() {
    let g = JasGroup(children: [])
    let b = g.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 0 && b.height == 0)
}

@Test func nestedGroup() {
    let inner = Element.group(JasGroup(children: [.rect(JasRect(x: 10, y: 10, width: 5, height: 5))]))
    let outer = JasGroup(children: [.rect(JasRect(x: 0, y: 0, width: 1, height: 1)), inner])
    let b = outer.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 15 && b.height == 15)
}

@Test func groupWithTransform() {
    let g = JasGroup(children: [.rect(JasRect(x: 0, y: 0, width: 10, height: 10))],
                     transform: .translate(100, 200))
    #expect(g.transform != nil)
    #expect(g.transform?.e == 100)
}

@Test func elementOpacity() {
    let r = JasRect(x: 0, y: 0, width: 10, height: 10, opacity: 0.5)
    #expect(r.opacity == 0.5)
}

@Test func elementBoundsDispatch() {
    let pathEl = Element.path(JasPath(d: [.moveTo(0, 0), .lineTo(10, 10)]))
    let rectEl = Element.rect(JasRect(x: 5, y: 5, width: 20, height: 20))
    #expect(pathEl.bounds.x == 0 && pathEl.bounds.width == 10)
    #expect(rectEl.bounds.x == 5 && rectEl.bounds.width == 20)
}

@Test func groupAllElementTypes() {
    let children: [Element] = [
        .line(JasLine(x1: 0, y1: 0, x2: 10, y2: 10)),
        .rect(JasRect(x: 0, y: 0, width: 20, height: 20)),
        .circle(JasCircle(cx: 50, cy: 50, r: 10)),
        .ellipse(JasEllipse(cx: 50, cy: 50, rx: 10, ry: 5)),
        .polyline(JasPolyline(points: [(0, 0), (10, 10)])),
        .polygon(JasPolygon(points: [(0, 0), (10, 0), (5, 10)])),
        .path(JasPath(d: [.moveTo(0, 0), .lineTo(10, 10)])),
        .text(JasText(x: 0, y: 20, content: "test")),
    ]
    let g = JasGroup(children: children)
    let b = g.bounds
    #expect(b.x == 0 && b.y == 0 && b.width > 0 && b.height > 0)
}

@Test func deeplyNestedGroups() {
    let inner = JasGroup(children: [.rect(JasRect(x: 10, y: 10, width: 5, height: 5))])
    let mid = JasGroup(children: [.rect(JasRect(x: 0, y: 0, width: 1, height: 1)), .group(inner)])
    let outer = JasGroup(children: [.rect(JasRect(x: 20, y: 20, width: 3, height: 3)), .group(mid)])
    let b = outer.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 23 && b.height == 23)
}
