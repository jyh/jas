import Testing
import AppKit
@testable import JasLib

@Test func defaultToolIsSelection() {
    let tool: Tool = .selection
    #expect(tool == .selection)
}

@Test func toolEnumCases() {
    let tools = Tool.allCases
    #expect(tools.count == 18)
    #expect(tools.contains(.selection))
    #expect(tools.contains(.partialSelection))
    #expect(tools.contains(.interiorSelection))
    #expect(tools.contains(.pen))
    #expect(tools.contains(.addAnchorPoint))
    #expect(tools.contains(.deleteAnchorPoint))
    #expect(tools.contains(.anchorPoint))
    #expect(tools.contains(.pencil))
    #expect(tools.contains(.pathEraser))
    #expect(tools.contains(.smooth))
    #expect(tools.contains(.typeTool))
    #expect(tools.contains(.typeOnPath))
    #expect(tools.contains(.line))
    #expect(tools.contains(.rect))
    #expect(tools.contains(.roundedRect))
    #expect(tools.contains(.polygon))
    #expect(tools.contains(.star))
    #expect(tools.contains(.lasso))
}

@Test func contentViewInitializes() {
    let view = ContentView(workspace: WorkspaceState())
    _ = view.body
}

@Test func defaultBoundingBox() {
    let bbox = CanvasBoundingBox()
    #expect(bbox.x == 0 && bbox.y == 0 && bbox.width == 800 && bbox.height == 600)
}

@Test func customBoundingBox() {
    let bbox = CanvasBoundingBox(x: 10, y: 20, width: 1024, height: 768)
    #expect(bbox.x == 10 && bbox.y == 20 && bbox.width == 1024 && bbox.height == 768)
}

// MARK: - CanvasNSView tool tests

@Test func canvasNSViewDefaultTool() {
    let view = CanvasNSView()
    #expect(view.currentTool == .selection)
}

@Test func canvasNSViewSetTool() {
    let view = CanvasNSView()
    view.currentTool = .line
    #expect(view.currentTool == .line)
    view.currentTool = .rect
    #expect(view.currentTool == .rect)
}

@Test func lineToolCreatesLineElement() {
    let model = Model()
    let controller = Controller(model: model)
    let view = CanvasNSView()
    view.document = model.document
    view.controller = controller
    view.currentTool = .line
    view.onToolRead = { .line }

    // Simulate drag from (10,20) to (50,60) via internal state
    view.simulateDrag(from: NSPoint(x: 10, y: 20), to: NSPoint(x: 50, y: 60))

    let doc = model.document
    #expect(doc.layers.count == 1)
    if case .line(let line) = doc.layers[0].children[0] {
        #expect(line.x1 == 10)
        #expect(line.y1 == 20)
        #expect(line.x2 == 50)
        #expect(line.y2 == 60)
    } else {
        Issue.record("Expected a line element")
    }
}

@Test func rectToolCreatesRectElement() {
    let model = Model()
    let controller = Controller(model: model)
    let view = CanvasNSView()
    view.document = model.document
    view.controller = controller
    view.currentTool = .rect
    view.onToolRead = { .rect }

    // Drag from (50,60) to (10,20) — should normalize
    view.simulateDrag(from: NSPoint(x: 50, y: 60), to: NSPoint(x: 10, y: 20))

    let doc = model.document
    #expect(doc.layers.count == 1)
    if case .rect(let r) = doc.layers[0].children[0] {
        #expect(r.x == 10)
        #expect(r.y == 20)
        #expect(r.width == 40)
        #expect(r.height == 40)
    } else {
        Issue.record("Expected a rect element")
    }
}

@Test func drawingAddsToExistingLayer() {
    let model = Model()
    let controller = Controller(model: model)
    let layer = Layer(name: "L1", children: [
        .line(Line(x1: 0, y1: 0, x2: 1, y2: 1,
                      stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
    ])
    model.document = Document(layers: [layer])

    let view = CanvasNSView()
    view.document = model.document
    view.controller = controller
    view.currentTool = .line
    view.onToolRead = { .line }

    view.simulateDrag(from: NSPoint(x: 0, y: 0), to: NSPoint(x: 99, y: 99))

    let doc = model.document
    #expect(doc.layers.count == 1)
    #expect(doc.layers[0].children.count == 2)
}

@Test func selectionToolIgnoresMouse() {
    let model = Model()
    let controller = Controller(model: model)
    let view = CanvasNSView()
    view.document = model.document
    view.controller = controller
    view.currentTool = .selection
    view.onToolRead = { .selection }

    view.simulateDrag(from: NSPoint(x: 10, y: 10), to: NSPoint(x: 50, y: 50))

    // No elements should have been created
    #expect(model.document.layers[0].children.isEmpty)
}

// MARK: - arcToBeziers tests

@Test func arcToBeziers90Degree() {
    // A 90-degree arc from (100, 0) to (0, 100) on a unit circle of radius 100
    // centered at the origin. Should produce exactly 1 Bezier segment.
    let result = arcToBeziers(
        cx0: 100, cy0: 0,
        rx: 100, ry: 100, xRotation: 0,
        largeArc: false, sweep: true,
        x: 0, y: 100
    )
    #expect(result.count == 1)
    // The endpoint of the single segment should be near (0, 100)
    let (_, _, _, _, epx, epy) = result[0]
    #expect(abs(epx - 0) < 1e-9)
    #expect(abs(epy - 100) < 1e-9)
}

@Test func arcToBeziersZeroRadius() {
    // Zero-radius arc should return empty result
    let result = arcToBeziers(
        cx0: 10, cy0: 20,
        rx: 0, ry: 0, xRotation: 0,
        largeArc: false, sweep: false,
        x: 30, y: 40
    )
    #expect(result.isEmpty)
}

@Test func arcToBeziersSamePoint() {
    // Start and end at the same point should return empty result
    let result = arcToBeziers(
        cx0: 50, cy0: 50,
        rx: 100, ry: 100, xRotation: 0,
        largeArc: false, sweep: true,
        x: 50, y: 50
    )
    #expect(result.isEmpty)
}

@Test func arcToBeziers360Degree() {
    // A full-circle arc (large arc flag set, sweep set).
    // From (100, 0) sweeping 360 degrees back to near (100, 0).
    // We use a point very close but not identical to avoid the same-point check.
    let result = arcToBeziers(
        cx0: 100, cy0: 0,
        rx: 100, ry: 100, xRotation: 0,
        largeArc: true, sweep: true,
        x: 100, y: 0.001
    )
    // A near-full circle should produce 4 segments (ceil(2*pi / (pi/2)) = 4)
    #expect(result.count == 4)
    // The endpoint of the last segment should be near (100, 0.001)
    let (_, _, _, _, epx, epy) = result[result.count - 1]
    #expect(abs(epx - 100) < 0.1)
    #expect(abs(epy - 0.001) < 0.1)
}

@Test func arcToBeziers180Degree() {
    // A half-circle arc should produce exactly 2 segments (ceil(pi / (pi/2)) = 2)
    let result = arcToBeziers(
        cx0: 100, cy0: 0,
        rx: 100, ry: 100, xRotation: 0,
        largeArc: false, sweep: true,
        x: -100, y: 0
    )
    #expect(result.count == 2)
    // The endpoint of the last segment should be near (-100, 0)
    let (_, _, _, _, epx, epy) = result[result.count - 1]
    #expect(abs(epx - (-100)) < 1e-9)
    #expect(abs(epy - 0) < 1e-9)
}

// MARK: - Visibility ordering tests

@Test func visibilityInvisibleLessThanOutline() {
    #expect(Visibility.invisible < Visibility.outline)
}

@Test func visibilityOutlineLessThanPreview() {
    #expect(Visibility.outline < Visibility.preview)
}

@Test func visibilityInvisibleLessThanPreview() {
    #expect(Visibility.invisible < Visibility.preview)
}

// MARK: - BlendMode to CGBlendMode mapping

@Test func cgBlendModeNormalIsNormal() {
    #expect(cgBlendMode(.normal) == .normal)
}

@Test func cgBlendModeMapsAllSixteenVariants() {
    let pairs: [(BlendMode, CGBlendMode)] = [
        (.normal,      .normal),
        (.darken,      .darken),
        (.multiply,    .multiply),
        (.colorBurn,   .colorBurn),
        (.lighten,     .lighten),
        (.screen,      .screen),
        (.colorDodge,  .colorDodge),
        (.overlay,     .overlay),
        (.softLight,   .softLight),
        (.hardLight,   .hardLight),
        (.difference,  .difference),
        (.exclusion,   .exclusion),
        (.hue,         .hue),
        (.saturation,  .saturation),
        (.color,       .color),
        (.luminosity,  .luminosity),
    ]
    #expect(pairs.count == 16)
    for (m, expected) in pairs {
        #expect(cgBlendMode(m) == expected)
    }
}

// MARK: - maskPlan (Track C)

private func testMask(clip: Bool, invert: Bool, disabled: Bool) -> Mask {
    Mask(
        subtreeElement: .group(Group(children: [])),
        clip: clip,
        invert: invert,
        disabled: disabled,
        linked: true,
        unlinkTransform: nil
    )
}

@Test func maskPlanClipNotInvertedIsClipIn() {
    #expect(maskPlan(testMask(clip: true, invert: false, disabled: false)) == .clipIn)
}

@Test func maskPlanClipInvertedIsClipOut() {
    #expect(maskPlan(testMask(clip: true, invert: true, disabled: false)) == .clipOut)
}

@Test func maskPlanDisabledIsNil() {
    // disabled overrides both clip and invert: falls back to no
    // mask rendering per OPACITY.md §States.
    #expect(maskPlan(testMask(clip: true, invert: false, disabled: true)) == nil)
    #expect(maskPlan(testMask(clip: true, invert: true, disabled: true)) == nil)
    #expect(maskPlan(testMask(clip: false, invert: false, disabled: true)) == nil)
    #expect(maskPlan(testMask(clip: false, invert: true, disabled: true)) == nil)
}

@Test func maskPlanNoClipNoInvertIsRevealOutsideBbox() {
    // Phase 2: clip=false, invert=false keeps the element visible
    // outside the mask subtree's bounding box and clips to the
    // mask inside it.
    #expect(maskPlan(testMask(clip: false, invert: false, disabled: false)) == .revealOutsideBbox)
}

@Test func maskPlanNoClipInvertedCollapsesToClipOut() {
    // Alpha-based mask: `clip: false, invert: true` gives the same
    // output as `clip: true, invert: true` because the mask's
    // outside-region alpha is zero either way.
    #expect(maskPlan(testMask(clip: false, invert: true, disabled: false)) == .clipOut)
}

// MARK: - effectiveMaskTransform (Track C phase 3)

private func testTransform(_ e: Double, _ f: Double) -> Transform {
    // Pure translation by (e, f) for easy identification in tests.
    Transform(a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: e, f: f)
}

private func testRect(_ transform: Transform?) -> Element {
    .rect(Rect(
        x: 0, y: 0, width: 10, height: 10,
        transform: transform
    ))
}

private func testMaskLinked(_ linked: Bool, unlink: Transform?) -> Mask {
    Mask(
        subtreeElement: .group(Group(children: [])),
        clip: true, invert: false, disabled: false,
        linked: linked, unlinkTransform: unlink
    )
}

@Test func effectiveMaskTransformLinkedReturnsElementTransform() {
    // linked=true: mask follows the element, so the renderer
    // should apply `elem.transform`.
    let mask = testMaskLinked(true, unlink: nil)
    let elem = testRect(testTransform(5, 7))
    let t = effectiveMaskTransform(mask, elem)
    #expect(t != nil)
    #expect(t?.e == 5)
    #expect(t?.f == 7)
}

@Test func effectiveMaskTransformLinkedNilWhenElementHasNoTransform() {
    // linked=true with no element transform: nil — the
    // compositing path skips the applyTransform call.
    let mask = testMaskLinked(true, unlink: nil)
    let elem = testRect(nil)
    #expect(effectiveMaskTransform(mask, elem) == nil)
}

@Test func effectiveMaskTransformUnlinkedReturnsCapturedUnlinkTransform() {
    // linked=false: mask stays frozen under the unlink-time
    // transform, regardless of the element's current transform.
    let mask = testMaskLinked(false, unlink: testTransform(3, 4))
    let elem = testRect(testTransform(100, 100))
    let t = effectiveMaskTransform(mask, elem)
    #expect(t != nil)
    #expect(t?.e == 3)
    #expect(t?.f == 4)
}

@Test func effectiveMaskTransformUnlinkedNilWhenUnlinkMissing() {
    // linked=false with no captured transform (edge case:
    // unlinked at identity): nil.
    let mask = testMaskLinked(false, unlink: nil)
    let elem = testRect(testTransform(7, 8))
    #expect(effectiveMaskTransform(mask, elem) == nil)
}
