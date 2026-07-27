import Testing
@testable import JasLib

/// Tests for Controller.makeCompoundShape / releaseCompoundShape /
/// expandCompoundShape — mirror jas_dioxus controller_test.rs.

private func rectAt(_ x: Double, _ y: Double) -> Element {
    .rect(Rect(x: x, y: y, width: 10, height: 10))
}

private func modelWithRects(_ rects: [Element], selected: [ElementPath]) -> Model {
    let layer = Layer(children: rects)
    let sel: Selection = Set(selected.map { ElementSelection.all($0) })
    let doc = Document(layers: [layer], selectedLayer: 0, selection: sel)
    return Model(document: doc)
}

private func topChildrenCount(_ model: Model) -> Int {
    model.document.layers[0].children.count
}

@Test func makeCompoundShapeWrapsSelection() {
    let model = modelWithRects([rectAt(0, 0), rectAt(5, 0)],
                               selected: [[0, 0], [0, 1]])
    Controller(model: model).makeCompoundShape()
    #expect(topChildrenCount(model) == 1)
    let child = model.document.layers[0].children[0]
    if case .live = child {
    } else {
        Issue.record("expected live element")
    }
}

@Test func makeCompoundShapeSelectionIsNewCompound() {
    let model = modelWithRects([rectAt(0, 0), rectAt(5, 0)],
                               selected: [[0, 0], [0, 1]])
    Controller(model: model).makeCompoundShape()
    #expect(model.document.selection.count == 1)
}

@Test func makeCompoundShapeLessThanTwoIsNoop() {
    let model = modelWithRects([rectAt(0, 0)], selected: [[0, 0]])
    Controller(model: model).makeCompoundShape()
    #expect(topChildrenCount(model) == 1)
    if case .rect = model.document.layers[0].children[0] {
    } else {
        Issue.record("expected rect, compound was created")
    }
}

@Test func releaseCompoundShapeRestoresOperands() {
    let model = modelWithRects([rectAt(0, 0), rectAt(5, 0)],
                               selected: [[0, 0], [0, 1]])
    let ctrl = Controller(model: model)
    ctrl.makeCompoundShape()
    ctrl.releaseCompoundShape()
    #expect(topChildrenCount(model) == 2)
    #expect(model.document.selection.count == 2)
}

@Test func expandCompoundShapeReplacesWithPolygons() {
    // Two overlapping rects to Union to one polygon.
    let model = modelWithRects([rectAt(0, 0), rectAt(5, 0)],
                               selected: [[0, 0], [0, 1]])
    let ctrl = Controller(model: model)
    ctrl.makeCompoundShape()
    ctrl.expandCompoundShape()
    #expect(topChildrenCount(model) == 1)
    if case .polygon = model.document.layers[0].children[0] {
    } else {
        Issue.record("expected polygon element")
    }
}

// MARK: - Destructive boolean ops

private func twoOverlapping() -> Model {
    modelWithRects([rectAt(0, 0), rectAt(5, 0)], selected: [[0, 0], [0, 1]])
}

@Test func destructiveUnionProducesOnePolygon() {
    let m = twoOverlapping()
    Controller(model: m).applyDestructiveBoolean("union")
    #expect(topChildrenCount(m) == 1)
    if case .polygon = m.document.layers[0].children[0] {
    } else { Issue.record("expected polygon") }
}

@Test func destructiveIntersectionProducesOnePolygon() {
    let m = twoOverlapping()
    Controller(model: m).applyDestructiveBoolean("intersection")
    #expect(topChildrenCount(m) == 1)
}

@Test func destructiveExcludeProducesSingleEvenOddPath() {
    // Twin of Rust's `destructive_exclude_produces_single_evenodd_path`.
    //
    // THE MULTI-RING HOLE BUG, pinned. A symmetric difference is one
    // outer ring plus an inner ring cutting out the overlap. Swift used
    // to emit each ring as its own Polygon, and a Polygon fills its own
    // area on its own — so the hole was PAINTED OVER and the app drew a
    // disc where Rust drew a donut. It is now one Path carrying every
    // ring as a subpath, declaring even-odd (boolResultFillRule), which
    // is what makes the hole survive both in the model and on canvas.
    let m = twoOverlapping()
    Controller(model: m).applyDestructiveBoolean("exclude")
    #expect(topChildrenCount(m) == 1)
    #expect(m.document.selection.count == 1)
    guard case .path(let p) = m.document.layers[0].children[0] else {
        Issue.record("expected a Path, got \(m.document.layers[0].children[0])")
        return
    }
    #expect(p.fillRule == .evenodd)
    var moveCount = 0
    for c in p.d { if case .moveTo = c { moveCount += 1 } }
    #expect(moveCount >= 2)
}

@Test func destructiveSubtractFrontConsumesFront() {
    let m = twoOverlapping()
    Controller(model: m).applyDestructiveBoolean("subtract_front")
    #expect(topChildrenCount(m) == 1)
}

@Test func destructiveSubtractBackConsumesBack() {
    let m = twoOverlapping()
    Controller(model: m).applyDestructiveBoolean("subtract_back")
    #expect(topChildrenCount(m) == 1)
}

@Test func destructiveCropUsesFrontmostAsMask() {
    let m = twoOverlapping()
    Controller(model: m).applyDestructiveBoolean("crop")
    #expect(topChildrenCount(m) == 1)
}

@Test func destructiveUnknownOpIsNoop() {
    let m = twoOverlapping()
    let before = topChildrenCount(m)
    Controller(model: m).applyDestructiveBoolean("nonexistent")
    #expect(topChildrenCount(m) == before)
}

// MARK: - DIVIDE / TRIM / MERGE

private func rectWithFill(_ x: Double, _ y: Double, _ color: Color) -> Element {
    .rect(Rect(x: x, y: y, width: 10, height: 10,
               fill: Fill(color: color)))
}

private func disjointRects() -> Model {
    modelWithRects([rectAt(0, 0), rectAt(20, 0)],
                   selected: [[0, 0], [0, 1]])
}

@Test func divideOverlappingProducesThreeFragments() {
    let m = twoOverlapping()
    Controller(model: m).applyDestructiveBoolean("divide")
    #expect(topChildrenCount(m) == 3)
}

@Test func divideDisjointKeepsTwo() {
    let m = disjointRects()
    Controller(model: m).applyDestructiveBoolean("divide")
    #expect(topChildrenCount(m) == 2)
}

@Test func trimOverlappingKeepsTwo() {
    let m = twoOverlapping()
    Controller(model: m).applyDestructiveBoolean("trim")
    #expect(topChildrenCount(m) == 2)
}

@Test func trimFullyCoveredOperandVanishes() {
    let back = rectAt(0, 0)
    let front = Element.rect(Rect(x: 0, y: 0, width: 20, height: 20))
    let m = modelWithRects([back, front], selected: [[0, 0], [0, 1]])
    Controller(model: m).applyDestructiveBoolean("trim")
    #expect(topChildrenCount(m) == 1)
}

@Test func mergeMatchingFillsCombine() {
    let red = Color(r: 1, g: 0, b: 0)
    let m = modelWithRects(
        [rectWithFill(0, 0, red), rectWithFill(5, 0, red)],
        selected: [[0, 0], [0, 1]]
    )
    Controller(model: m).applyDestructiveBoolean("merge")
    #expect(topChildrenCount(m) == 1)
}

@Test func mergeMismatchedFillsStaySeparate() {
    let red = Color(r: 1, g: 0, b: 0)
    let blue = Color(r: 0, g: 0, b: 1)
    let m = modelWithRects(
        [rectWithFill(0, 0, red), rectWithFill(5, 0, blue)],
        selected: [[0, 0], [0, 1]]
    )
    Controller(model: m).applyDestructiveBoolean("merge")
    #expect(topChildrenCount(m) == 2)
}

@Test func mergeNoneFillNeverMatches() {
    let m = twoOverlapping()
    Controller(model: m).applyDestructiveBoolean("merge")
    #expect(topChildrenCount(m) == 2)
}

// MARK: - Compound creation (Alt+click)

private func firstChildCompoundOp(_ m: Model) -> CompoundOperation? {
    guard case .live(.compoundShape(let cs)) = m.document.layers[0].children[0]
    else { return nil }
    return cs.operation
}

@Test func unionCompoundUsesUnion() {
    let m = twoOverlapping()
    Controller(model: m).applyCompoundCreation("union")
    #expect(firstChildCompoundOp(m) == .union)
}

@Test func subtractFrontCompoundUsesSubtractFront() {
    let m = twoOverlapping()
    Controller(model: m).applyCompoundCreation("subtract_front")
    #expect(firstChildCompoundOp(m) == .subtractFront)
}

@Test func intersectionCompoundUsesIntersection() {
    let m = twoOverlapping()
    Controller(model: m).applyCompoundCreation("intersection")
    #expect(firstChildCompoundOp(m) == .intersection)
}

@Test func excludeCompoundUsesExclude() {
    let m = twoOverlapping()
    Controller(model: m).applyCompoundCreation("exclude")
    #expect(firstChildCompoundOp(m) == .exclude)
}

@Test func compoundCreationUnknownOpIsNoop() {
    let m = twoOverlapping()
    Controller(model: m).applyCompoundCreation("nonexistent")
    #expect(topChildrenCount(m) == 2)
}

// MARK: - BooleanOptions / Repeat

@Test func collapseCollinearDropsMidpoint() {
    let ring: [(Double, Double)] = [(0, 0), (5, 0), (10, 0), (10, 10), (0, 10)]
    let collapsed = collapseCollinearPoints(ring, tolerance: 0.01)
    #expect(collapsed.count == 4)
}

@Test func collapsePreservesTriangleCorners() {
    let ring: [(Double, Double)] = [(0, 0), (10, 0), (5, 10)]
    let collapsed = collapseCollinearPoints(ring, tolerance: 0.01)
    #expect(collapsed.count == 3)
}

/// Twin of Rust's `destructive_remove_redundant_points_collapses_collinear`,
/// with the same exact counts. `twoOverlapping()` is two rects overlapping in
/// x with the same y-extent, so their UNION is one rectangle whose ring
/// carries four vertices the sweep inserted where each operand's vertical
/// edges meet the shared horizontal ones. The flag defaults to OFF
/// (`workspace/state.yaml`), so the default arm keeps all 8.
@Test func removeRedundantPointsCollapsesTheSeamVerticesOnlyWhenOn() {
    let off = twoOverlapping()
    Controller(model: off).applyDestructiveBoolean("union")
    guard case .polygon(let pOff) = off.document.layers[0].children[0] else {
        Issue.record("expected a polygon"); return
    }
    #expect(pOff.points.count == 8)

    let on = twoOverlapping()
    Controller(model: on).applyDestructiveBoolean(
        "union", options: BooleanOptions(removeRedundantPoints: true))
    guard case .polygon(let pOn) = on.document.layers[0].children[0] else {
        Issue.record("expected a polygon"); return
    }
    #expect(pOn.points.count == 4)
}

@Test func divideRemoveUnpaintedDropsUnfilled() {
    let m = twoOverlapping()
    let opts = BooleanOptions(divideRemoveUnpainted: true)
    Controller(model: m).applyDestructiveBoolean("divide", options: opts)
    #expect(topChildrenCount(m) == 0)
}

@Test func repeatDestructiveReplaysOp() {
    let m = twoOverlapping()
    Controller(model: m).applyRepeatBooleanOperation("union")
    #expect(topChildrenCount(m) == 1)
}

@Test func repeatCompoundReplaysCompoundCreation() {
    let m = twoOverlapping()
    Controller(model: m).applyRepeatBooleanOperation("intersection_compound")
    #expect(firstChildCompoundOp(m) == .intersection)
}

@Test func repeatNilIsNoop() {
    let m = twoOverlapping()
    Controller(model: m).applyRepeatBooleanOperation(nil)
    #expect(topChildrenCount(m) == 2)
}

@Test func repeatEmptyStringIsNoop() {
    let m = twoOverlapping()
    Controller(model: m).applyRepeatBooleanOperation("")
    #expect(topChildrenCount(m) == 2)
}

// MARK: - BOOLEAN.md "Operand and paint rules": opacity and blend mode
//
// The rule names FOUR properties as the paint the result carries: "fill,
// stroke, opacity, blend mode". Swift's output rebuild passed fill and
// stroke but wrote `opacity: 1.0` and left `blendMode` at its `.normal`
// default, so a half-transparent multiply operand came out opaque and
// normal. Rust carries all four (its rebuild clones the operand's
// CommonProps). The shared operations corpus pins `opacity` (it is in
// documentToTestJson); `blendMode` is NOT serialized there, which is why
// these live as per-port unit tests with Rust twins in controller.rs.

/// Two overlapping rects with DIFFERENT opacity and blend mode, front
/// (index 1, the last child = topmost) distinguishable from back.
private func twoOverlappingPainted() -> Model {
    let back = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                 opacity: 0.25, blendMode: .screen))
    let front = Element.rect(Rect(x: 5, y: 0, width: 10, height: 10,
                                  opacity: 0.5, blendMode: .multiply))
    return modelWithRects([back, front], selected: [[0, 0], [0, 1]])
}

@Test func unionCarriesFrontmostOpacityAndBlendMode() {
    let m = twoOverlappingPainted()
    Controller(model: m).applyDestructiveBoolean("union")
    guard case .polygon(let p) = m.document.layers[0].children[0] else {
        Issue.record("expected a polygon, got \(m.document.layers[0].children[0])")
        return
    }
    #expect(p.opacity == 0.5)
    #expect(p.blendMode == .multiply)
}

@Test func excludePathArmCarriesFrontmostOpacityAndBlendMode() {
    // The multi-ring arm builds a Path, a SECOND construction site that
    // has to carry the same four properties as the single-ring Polygon.
    let m = twoOverlappingPainted()
    Controller(model: m).applyDestructiveBoolean("exclude")
    guard case .path(let p) = m.document.layers[0].children[0] else {
        Issue.record("expected a path, got \(m.document.layers[0].children[0])")
        return
    }
    #expect(p.opacity == 0.5)
    #expect(p.blendMode == .multiply)
}

@Test func subtractFrontSurvivorKeepsItsOwnOpacityAndBlendMode() {
    // "Each remaining element has the frontmost subtracted from it and
    // keeps its own paint" — so the survivor is the BACK rect and the
    // result must carry 0.25 / .screen, not the consumed cutter's.
    let m = twoOverlappingPainted()
    Controller(model: m).applyDestructiveBoolean("subtract_front")
    guard case .polygon(let p) = m.document.layers[0].children[0] else {
        Issue.record("expected a polygon, got \(m.document.layers[0].children[0])")
        return
    }
    #expect(p.opacity == 0.25)
    #expect(p.blendMode == .screen)
}
