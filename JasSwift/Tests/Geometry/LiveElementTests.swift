import Testing
@testable import JasLib

/// Tests for the LiveElement framework — mirror jas_dioxus live.rs
/// tests.

private func rectAt(_ x: Double, _ y: Double) -> Element {
    .rect(Rect(x: x, y: y, width: 10, height: 10))
}

private func bboxOfRing(_ ring: BoolRing) -> (Double, Double, Double, Double) {
    let xs = ring.map { $0.0 }
    let ys = ring.map { $0.1 }
    return (xs.min()!, ys.min()!, xs.max()!, ys.max()!)
}

@Test func elementToPolygonSetRect() {
    let ps = elementToPolygonSet(rectAt(0, 0), precision: DEFAULT_PRECISION)
    #expect(ps.count == 1)
}

@Test func compoundShapeUnionOfTwoRects() {
    let cs = CompoundShape(
        operation: .union,
        operands: [rectAt(0, 0), rectAt(5, 0)]
    )
    let polygons = cs.evaluate(precision: DEFAULT_PRECISION)
    #expect(polygons.count == 1)
    let (minX, _, maxX, _) = bboxOfRing(polygons[0])
    #expect(abs(minX - 0) < 1e-6)
    #expect(abs(maxX - 15) < 1e-6)
}

@Test func compoundShapeIntersection() {
    let cs = CompoundShape(
        operation: .intersection,
        operands: [rectAt(0, 0), rectAt(5, 0)]
    )
    let polygons = cs.evaluate(precision: DEFAULT_PRECISION)
    #expect(polygons.count == 1)
    let (minX, _, maxX, _) = bboxOfRing(polygons[0])
    #expect(abs(minX - 5) < 1e-6)
    #expect(abs(maxX - 10) < 1e-6)
}

@Test func compoundShapeExclude() {
    let cs = CompoundShape(
        operation: .exclude,
        operands: [rectAt(0, 0), rectAt(5, 0)]
    )
    let polygons = cs.evaluate(precision: DEFAULT_PRECISION)
    #expect(polygons.count == 2)
}

@Test func compoundShapeSubtractFront() {
    let cs = CompoundShape(
        operation: .subtractFront,
        operands: [rectAt(0, 0), rectAt(5, 0)]
    )
    let polygons = cs.evaluate(precision: DEFAULT_PRECISION)
    #expect(polygons.count == 1)
    let (minX, _, maxX, _) = bboxOfRing(polygons[0])
    #expect(abs(minX - 0) < 1e-6)
    #expect(abs(maxX - 5) < 1e-6)
}

@Test func compoundShapeBoundsReflectEvaluation() {
    let cs = CompoundShape(
        operation: .union,
        operands: [rectAt(0, 0), rectAt(5, 0)]
    )
    let (bx, by, bw, bh) = cs.bounds
    #expect(abs(bx - 0) < 1e-6)
    #expect(abs(by - 0) < 1e-6)
    #expect(abs(bw - 15) < 1e-6)
    #expect(abs(bh - 10) < 1e-6)
}

@Test func emptyCompoundHasEmptyBounds() {
    let cs = CompoundShape(operation: .union, operands: [])
    let (bx, by, bw, bh) = cs.bounds
    #expect(bx == 0 && by == 0 && bw == 0 && bh == 0)
}

@Test func expandProducesPolygonPerRing() {
    let red = Fill(color: Color(r: 1, g: 0, b: 0))
    let cs = CompoundShape(
        operation: .exclude,
        operands: [rectAt(0, 0), rectAt(5, 0)],
        fill: red
    )
    let expanded = cs.expand(precision: DEFAULT_PRECISION)
    #expect(expanded.count == 2)  // XOR → 2 rings → 2 polygons
    for e in expanded {
        if case .polygon(let p) = e {
            #expect(p.fill == red)
        } else {
            Issue.record("expected polygon element")
        }
    }
}

@Test func releaseReturnsOperandsVerbatim() {
    let r1 = rectAt(0, 0)
    let r2 = rectAt(5, 0)
    let cs = CompoundShape(operation: .union, operands: [r1, r2])
    let released = cs.release()
    #expect(released.count == 2)
}

@Test func pathFlattensIntoPolygonSet() {
    let path = Element.path(Path(d: [
        .moveTo(0, 0),
        .lineTo(10, 0),
        .lineTo(10, 10),
        .lineTo(0, 10),
        .closePath,
    ]))
    let ps = elementToPolygonSet(path, precision: DEFAULT_PRECISION)
    #expect(ps.count == 1)
}
