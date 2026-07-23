import Testing
import CoreGraphics
@testable import JasLib

// SH-4: the pure viewport / dirty-rect culling predicate. Visual invariance is
// the law, so every case that could paint into the dirty region must return
// "keep" (true). The predicate errs toward drawing.

private let dirty = CGRect(x: 0, y: 0, width: 800, height: 600)

@Test func cullKeepsElementInsideDirtyRect() {
    let b: BBox = (x: 100, y: 100, width: 50, height: 40)
    #expect(CanvasCull.mayDraw(bounds: b, localToDoc: .identity, dirtyDoc: dirty, margin: 0))
}

@Test func cullSkipsElementFarOutsideDirtyRect() {
    let b: BBox = (x: 5000, y: 5000, width: 50, height: 40)
    #expect(!CanvasCull.mayDraw(bounds: b, localToDoc: .identity, dirtyDoc: dirty, margin: 64))
}

@Test func cullKeepsElementStraddlingEdge() {
    // Half in, half out — must draw.
    let b: BBox = (x: 780, y: 100, width: 60, height: 40)
    #expect(CanvasCull.mayDraw(bounds: b, localToDoc: .identity, dirtyDoc: dirty, margin: 0))
}

@Test func cullMarginKeepsJustOutsideElement() {
    // Geometry is 20pt outside the right edge, but the stroke/AA margin reaches
    // back in — must draw.
    let b: BBox = (x: 820, y: 100, width: 10, height: 10)
    #expect(!CanvasCull.mayDraw(bounds: b, localToDoc: .identity, dirtyDoc: dirty, margin: 5))
    #expect(CanvasCull.mayDraw(bounds: b, localToDoc: .identity, dirtyDoc: dirty, margin: 64))
}

@Test func cullIsTransformAwareTranslate() {
    // Geometry sits far away, but a translate transform brings it into view —
    // the predicate must test the POST-transform position, not the local one.
    let b: BBox = (x: 5000, y: 5000, width: 40, height: 40)
    let bring = CGAffineTransform(translationX: -4900, y: -4900)  // → (100,100)
    #expect(CanvasCull.mayDraw(bounds: b, localToDoc: bring, dirtyDoc: dirty, margin: 0))
}

@Test func cullIsTransformAwareScale() {
    // A tiny local element scaled up to cover the viewport must be kept.
    let b: BBox = (x: 0, y: 0, width: 1, height: 1)
    let scale = CGAffineTransform(scaleX: 1000, y: 1000)
    #expect(CanvasCull.mayDraw(bounds: b, localToDoc: scale, dirtyDoc: dirty, margin: 0))
}

@Test func cullTransformCanMoveElementOutOfView() {
    // Local geometry is in-view, but a translate pushes its POST-transform
    // extent entirely off — must be culled.
    let b: BBox = (x: 100, y: 100, width: 40, height: 40)
    let push = CGAffineTransform(translationX: 6000, y: 0)
    #expect(!CanvasCull.mayDraw(bounds: b, localToDoc: push, dirtyDoc: dirty, margin: 64))
}

@Test func mappedAABBExpandsForRotation() {
    // A 100x0-ish thin box rotated 45° grows its AABB in both axes.
    let b: BBox = (x: 0, y: 0, width: 100, height: 100)
    let rot = CGAffineTransform(rotationAngle: .pi / 4)
    let box = CanvasCull.mappedAABB(b, rot)
    // Diagonal of a 100x100 square is ~141.4; the AABB width/height match that.
    #expect(abs(box.width - 141.4213562) < 1e-3)
    #expect(abs(box.height - 141.4213562) < 1e-3)
}

@Test func cullStrokeInflatedBoundsKeptViaBoundsAndMargin() {
    // A thick-stroked shape whose geometry is just off-view: the .bounds passed
    // in already includes half-stroke inflation, and the margin adds more, so
    // it stays drawn.
    let halfStroke = 30.0  // stroke width 60 → half on each side
    let geomX = 815.0
    let b: BBox = (x: geomX - halfStroke, y: 100, width: 20 + 2 * halfStroke, height: 20)
    #expect(CanvasCull.mayDraw(bounds: b, localToDoc: .identity, dirtyDoc: dirty, margin: 64))
}
