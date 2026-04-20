import Testing
@testable import JasLib

@Test func colorDefaults() {
    let c = Color(r: 1.0, g: 0.0, b: 0.0)
    #expect(c.alpha == 1.0)
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

// MARK: - Element.geometricBounds
// Align reads geometricBounds (stroke-exclusive) when Use Preview
// Bounds is off, the default per ALIGN.md §Bounding box selection.

@Test func geometricBoundsIgnoresStrokeInflationOnLine() {
    let ln = Line(x1: 0, y1: 0, x2: 50, y2: 50,
                  stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 2.0))
    let e = Element.line(ln)
    let b = e.geometricBounds
    #expect(b.x == 0 && b.y == 0 && b.width == 50 && b.height == 50)
}

@Test func geometricBoundsRect() {
    let r = Rect(x: 10, y: 20, width: 30, height: 40)
    let e = Element.rect(r)
    let b = e.geometricBounds
    #expect(b.x == 10 && b.y == 20 && b.width == 30 && b.height == 40)
}

@Test func geometricBoundsCircle() {
    let c = Circle(cx: 50, cy: 50, r: 20)
    let e = Element.circle(c)
    let b = e.geometricBounds
    #expect(b.x == 30 && b.y == 30 && b.width == 40 && b.height == 40)
}

@Test func geometricBoundsEllipse() {
    let el = Ellipse(cx: 50, cy: 50, rx: 30, ry: 15)
    let e = Element.ellipse(el)
    let b = e.geometricBounds
    #expect(b.x == 20 && b.y == 35 && b.width == 60 && b.height == 30)
}

@Test func geometricBoundsGroupUnionsChildrenWithoutInflation() {
    let c1 = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let c2 = Element.rect(Rect(x: 20, y: 20, width: 10, height: 10))
    let g = Group(children: [c1, c2])
    let e = Element.group(g)
    let b = e.geometricBounds
    #expect(b.x == 0 && b.y == 0 && b.width == 30 && b.height == 30)
}

@Test func geometricBoundsMatchesBoundsForUnstrokedShapes() {
    let c = Circle(cx: 50, cy: 50, r: 20)
    let e = Element.circle(c)
    let g = e.geometricBounds
    let p = e.bounds
    #expect(g.x == p.x && g.y == p.y && g.width == p.width && g.height == p.height)
}

@Test func geometricBoundsNarrowerThanPreviewForStrokedLine() {
    let ln = Line(x1: 0, y1: 0, x2: 50, y2: 50,
                  stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 4.0))
    let e = Element.line(ln)
    let g = e.geometricBounds
    let p = e.bounds
    #expect(p.width > g.width)
    #expect(p.height > g.height)
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
    #expect(c.fill?.color.toRgba().1 == 1.0)
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
    #expect(e.fill?.color.toRgba().2 == 1.0)
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
    #expect(p.fill?.color.toRgba().0 == 1.0)
    #expect(p.stroke?.width == 2.0)
    #expect(p.stroke?.linecap == .round)
}

@Test func textBounds() {
    let t = Text(x: 10, y: 30, content: "Hello")
    let b = t.bounds
    #expect(b.x == 10)
    #expect(b.y == 30)  // y is the top of the layout box
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

// MARK: - Color conversion tests

@Test func colorRgbIdentity() {
    let c = Color(r: 0.5, g: 0.3, b: 0.7, a: 0.8)
    let (r, g, b, a) = c.toRgba()
    #expect(abs(r - 0.5) < 1e-10)
    #expect(abs(g - 0.3) < 1e-10)
    #expect(abs(b - 0.7) < 1e-10)
    #expect(abs(a - 0.8) < 1e-10)
}

@Test func colorAlphaProperty() {
    #expect(Color(r: 1, g: 0, b: 0, a: 0.5).alpha == 0.5)
    #expect(Color.hsb(h: 120, s: 1, b: 1, a: 0.3).alpha == 0.3)
    #expect(Color.cmyk(c: 0, m: 1, y: 1, k: 0, a: 0.7).alpha == 0.7)
}

@Test func colorBlackWhiteConstants() {
    let (br, bg, bb, ba) = Color.black.toRgba()
    #expect(br == 0 && bg == 0 && bb == 0 && ba == 1)
    let (wr, wg, wb, wa) = Color.white.toRgba()
    #expect(wr == 1 && wg == 1 && wb == 1 && wa == 1)
}

@Test func colorHsbToRgbRed() {
    let c = Color.hsb(h: 0, s: 1, b: 1, a: 1)
    let (r, g, b, _) = c.toRgba()
    #expect(abs(r - 1.0) < 1e-10)
    #expect(abs(g) < 1e-10)
    #expect(abs(b) < 1e-10)
}

@Test func colorHsbToRgbGreen() {
    let c = Color.hsb(h: 120, s: 1, b: 1, a: 1)
    let (r, g, b, _) = c.toRgba()
    #expect(abs(r) < 1e-10)
    #expect(abs(g - 1.0) < 1e-10)
    #expect(abs(b) < 1e-10)
}

@Test func colorHsbToRgbBlue() {
    let c = Color.hsb(h: 240, s: 1, b: 1, a: 1)
    let (r, g, b, _) = c.toRgba()
    #expect(abs(r) < 1e-10)
    #expect(abs(g) < 1e-10)
    #expect(abs(b - 1.0) < 1e-10)
}

@Test func colorHsbGrayscale() {
    let c = Color.hsb(h: 0, s: 0, b: 0.5, a: 1)
    let (r, g, b, _) = c.toRgba()
    #expect(abs(r - 0.5) < 1e-10)
    #expect(abs(g - 0.5) < 1e-10)
    #expect(abs(b - 0.5) < 1e-10)
}

@Test func colorRgbToHsbRoundtrip() {
    let orig = Color(r: 0.8, g: 0.3, b: 0.6, a: 0.9)
    let (h, s, bri, a) = orig.toHsba()
    let back = Color.hsb(h: h, s: s, b: bri, a: a)
    let (r2, g2, b2, a2) = back.toRgba()
    let (r1, g1, b1, a1) = orig.toRgba()
    #expect(abs(r1 - r2) < 1e-10)
    #expect(abs(g1 - g2) < 1e-10)
    #expect(abs(b1 - b2) < 1e-10)
    #expect(abs(a1 - a2) < 1e-10)
}

@Test func colorCmykToRgb() {
    // Pure cyan: c=1,m=0,y=0,k=0 => r=0,g=1,b=1
    let c = Color.cmyk(c: 1, m: 0, y: 0, k: 0, a: 1)
    let (r, g, b, _) = c.toRgba()
    #expect(abs(r) < 1e-10)
    #expect(abs(g - 1.0) < 1e-10)
    #expect(abs(b - 1.0) < 1e-10)
}

@Test func colorCmykBlack() {
    // k=1 => all black
    let c = Color.cmyk(c: 0, m: 0, y: 0, k: 1, a: 1)
    let (r, g, b, _) = c.toRgba()
    #expect(abs(r) < 1e-10)
    #expect(abs(g) < 1e-10)
    #expect(abs(b) < 1e-10)
}

@Test func colorRgbToCmykRoundtrip() {
    let orig = Color(r: 0.8, g: 0.3, b: 0.6, a: 0.9)
    let (c, m, y, k, a) = orig.toCmyka()
    let back = Color.cmyk(c: c, m: m, y: y, k: k, a: a)
    let (r2, g2, b2, a2) = back.toRgba()
    let (r1, g1, b1, a1) = orig.toRgba()
    #expect(abs(r1 - r2) < 1e-10)
    #expect(abs(g1 - g2) < 1e-10)
    #expect(abs(b1 - b2) < 1e-10)
    #expect(abs(a1 - a2) < 1e-10)
}

@Test func colorRgbBlackToCmyk() {
    let (c, m, y, k, _) = Color.black.toCmyka()
    #expect(c == 0 && m == 0 && y == 0 && k == 1)
}

@Test func colorAlphaPreservedHsbRoundtrip() {
    let orig = Color(r: 1, g: 0, b: 0, a: 0.42)
    let (h, s, bri, a) = orig.toHsba()
    #expect(abs(a - 0.42) < 1e-10)
    let back = Color.hsb(h: h, s: s, b: bri, a: a)
    #expect(abs(back.alpha - 0.42) < 1e-10)
}

@Test func colorAlphaPreservedCmykRoundtrip() {
    let orig = Color(r: 0, g: 1, b: 0, a: 0.37)
    let (c, m, y, k, a) = orig.toCmyka()
    #expect(abs(a - 0.37) < 1e-10)
    let back = Color.cmyk(c: c, m: m, y: y, k: k, a: a)
    #expect(abs(back.alpha - 0.37) < 1e-10)
}

@Test func colorHsbIdentity() {
    let c = Color.hsb(h: 200, s: 0.8, b: 0.6, a: 0.5)
    let (h, s, bri, a) = c.toHsba()
    #expect(abs(h - 200) < 1e-10)
    #expect(abs(s - 0.8) < 1e-10)
    #expect(abs(bri - 0.6) < 1e-10)
    #expect(abs(a - 0.5) < 1e-10)
}

@Test func colorCmykIdentity() {
    let c = Color.cmyk(c: 0.1, m: 0.2, y: 0.3, k: 0.4, a: 0.5)
    let (cc, m, y, k, a) = c.toCmyka()
    #expect(abs(cc - 0.1) < 1e-10)
    #expect(abs(m - 0.2) < 1e-10)
    #expect(abs(y - 0.3) < 1e-10)
    #expect(abs(k - 0.4) < 1e-10)
    #expect(abs(a - 0.5) < 1e-10)
}

// MARK: - withFill / withStroke tests

@Test func withFillSetsRectFill() {
    let elem = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let fill = Fill(color: Color(r: 1, g: 0, b: 0))
    let result = withFill(elem, fill: fill)
    if case .rect(let r) = result {
        #expect(r.fill == fill)
    } else {
        Issue.record("Expected Rect element")
    }
}

@Test func withFillOnLineIsNoop() {
    let stroke = Stroke(color: .black, width: 2.0)
    let elem = Element.line(Line(x1: 0, y1: 0, x2: 10, y2: 10, stroke: stroke))
    let fill = Fill(color: Color(r: 1, g: 0, b: 0))
    let result = withFill(elem, fill: fill)
    #expect(result == elem)
}

@Test func withStrokeSetsPathStroke() {
    let elem = Element.path(Path(d: [.moveTo(0, 0), .lineTo(10, 10)]))
    let stroke = Stroke(color: Color(r: 0, g: 1, b: 0), width: 3.0)
    let result = withStroke(elem, stroke: stroke)
    if case .path(let p) = result {
        #expect(p.stroke == stroke)
    } else {
        Issue.record("Expected Path element")
    }
}

@Test func withFillOnGroupIsNoop() {
    let inner = Element.rect(Rect(x: 0, y: 0, width: 5, height: 5))
    let elem = Element.group(Group(children: [inner]))
    let fill = Fill(color: Color(r: 1, g: 0, b: 0))
    let result = withFill(elem, fill: fill)
    #expect(result == elem)
}

// MARK: - Color hex conversion tests

@Test func colorToHexBlack() {
    #expect(Color.black.toHex() == "000000")
}

@Test func colorToHexRed() {
    let c = Color(r: 1, g: 0, b: 0)
    #expect(c.toHex() == "ff0000")
}

@Test func colorFromHexValid() {
    let c = Color.fromHex("ff8000")
    #expect(c != nil)
    if let c = c {
        let (r, g, b, _) = c.toRgba()
        #expect(abs(r - 1.0) < 0.01)
        #expect(abs(g - 0.502) < 0.01)
        #expect(abs(b) < 0.01)
    }
}

@Test func colorFromHexInvalidReturnsNil() {
    #expect(Color.fromHex("xyz") == nil)
    #expect(Color.fromHex("12345") == nil)
    #expect(Color.fromHex("") == nil)
}

@Test func colorHexRoundtrip() {
    let orig = Color(r: 0.2, g: 0.6, b: 0.8)
    let hex = orig.toHex()
    let back = Color.fromHex(hex)
    #expect(back != nil)
    if let back = back {
        let (r1, g1, b1, _) = orig.toRgba()
        let (r2, g2, b2, _) = back.toRgba()
        #expect(abs(r1 - r2) < 0.01)
        #expect(abs(g1 - g2) < 0.01)
        #expect(abs(b1 - b2) < 0.01)
    }
}
