import Testing
@testable import JasLib

// MARK: - Selection → Properties panel X/Y/W/H (decision-5 Part B.1)
//
// The Properties panel shows the selection's EVALUATED bounding box: each
// element's geometric bbox mapped through its own + ancestor transforms,
// axis-aligned, unioned. Mirrors the Python selection_evaluated_bounds tests.

private func propModel(_ elements: [Element], selected: [ElementPath]) -> Model {
    let layer = Layer(children: elements)
    let selection: Selection = selected.map { ElementSelection.all($0) }
    return Model(document: Document(layers: [layer], selectedLayer: 0,
                                    selection: selection))
}

private func rectT(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
                   _ t: Transform? = nil) -> Element {
    .rect(Rect(x: x, y: y, width: w, height: h, transform: t))
}

@Test func evalBoundsUntransformedRect() {
    let doc = propModel([rectT(10, 20, 30, 40)], selected: [[0, 0]]).document
    let b = selectionEvaluatedBounds(doc)
    #expect(b.x == 10 && b.y == 20 && b.width == 30 && b.height == 40)
}

@Test func evalBoundsScaledRectGrows() {
    let doc = propModel([rectT(10, 20, 30, 40, Transform.scale(2))],
                        selected: [[0, 0]]).document
    let b = selectionEvaluatedBounds(doc)
    #expect(b.x == 20 && b.y == 40 && b.width == 60 && b.height == 80)
}

@Test func evalBoundsTranslatedRectShifts() {
    let doc = propModel([rectT(10, 20, 30, 40, Transform.translate(5, 7))],
                        selected: [[0, 0]]).document
    let b = selectionEvaluatedBounds(doc)
    #expect(b.x == 15 && b.y == 27 && b.width == 30 && b.height == 40)
}

@Test func evalBoundsRotate90SwapsExtents() {
    // 10x20 rect rotated 90deg -> 20x10 bbox.
    let doc = propModel([rectT(0, 0, 10, 20, Transform.rotate(90))],
                        selected: [[0, 0]]).document
    let b = selectionEvaluatedBounds(doc)
    #expect(abs(b.width - 20) < 1e-6)
    #expect(abs(b.height - 10) < 1e-6)
}

@Test func evalBoundsUnionOfTwo() {
    let doc = propModel([rectT(0, 0, 10, 10), rectT(100, 0, 10, 10)],
                        selected: [[0, 0], [0, 1]]).document
    let b = selectionEvaluatedBounds(doc)
    #expect(b.x == 0 && b.y == 0 && b.width == 110 && b.height == 10)
}

@Test func evalBoundsEmptySelectionIsZero() {
    let doc = propModel([rectT(10, 20, 30, 40)], selected: []).document
    let b = selectionEvaluatedBounds(doc)
    #expect(b.x == 0 && b.y == 0 && b.width == 0 && b.height == 0)
}

@Test func propertiesOverridesWriteRoundedBbox() {
    let model = propModel([rectT(10, 20, 30, 40, Transform.scale(2))],
                          selected: [[0, 0]])
    let o = propertiesPanelLiveOverrides(model: model)
    #expect((o["prop_x"] as? Double) == 20)
    #expect((o["prop_y"] as? Double) == 40)
    #expect((o["prop_w"] as? Double) == 60)
    #expect((o["prop_h"] as? Double) == 80)
}

// MARK: - Part B.3: rotation / opacity / blend (first selected element)

@Test func propertiesAttrsFromFirstSelected() {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                 opacity: 0.5,
                                 transform: Transform.rotate(90),
                                 blendMode: .multiply))
    let o = propertiesPanelLiveOverrides(model: propModel([rect], selected: [[0, 0]]))
    #expect(abs((o["prop_rotation"] as? Double ?? 0) - 90) < 0.01)
    #expect((o["prop_opacity"] as? Double) == 50)
    #expect((o["prop_blend"] as? String) == "multiply")
}

@Test func propertiesAttrsDefaultNoSelection() {
    let o = propertiesPanelLiveOverrides(model: propModel([rectT(0, 0, 10, 10)],
                                                          selected: []))
    #expect((o["prop_rotation"] as? Double) == 0)
    #expect((o["prop_opacity"] as? Double) == 100)
    #expect((o["prop_blend"] as? String) == "normal")
    #expect((o["prop_shear"] as? Double) == 0)
}

// MARK: - SHEAR-FIELD display (first selected element)

@Test func propertiesShearFromFirstSelected() {
    // T1: element transform (a=1,b=0,c=1,d=1,e=0,f=0) -> prop_shear ~= 45.
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                 transform: Transform(a: 1, b: 0, c: 1, d: 1,
                                                      e: 0, f: 0)))
    let o = propertiesPanelLiveOverrides(model: propModel([rect], selected: [[0, 0]]))
    #expect(abs((o["prop_shear"] as? Double ?? 0) - 45) < 0.01)
}

@Test func propertiesShearDefaultNoTransform() {
    let o = propertiesPanelLiveOverrides(model: propModel([rectT(0, 0, 10, 10)],
                                                          selected: [[0, 0]]))
    #expect((o["prop_shear"] as? Double) == 0)
}

// MARK: - RESOLVEDBOUNDS: an instance reports the box it OCCUPIES
//
// A symbol instance carries no coordinates of its own — its geometry is its
// master's, reached by id. `Element.geometricBounds` has no resolver, so it
// answered the zero box, and the Properties panel showed X/Y/W/H all zero for a
// shape plainly sitting elsewhere on the canvas.
//
// Worse in a group: the zero box is not absent, it is a phantom point AT THE
// ORIGIN that the children-union swallows, so a group holding one instance got
// a selection box reaching back to (0,0) across empty canvas.
//
// Twins of Rust's tests in document/evaluated_bounds.rs.

/// A master rect at (5,7,10,20) in `symbols`, one instance of it at [0,0].
private func docWithInstance() -> Document {
    let master = Element.rect(Rect(x: 5, y: 7, width: 10, height: 20, id: "m1"))
    let instance = Element.live(.reference(ReferenceElem(
        target: ElementRef("m1"), name: nil, id: "i1")))
    return Document(layers: [Layer(children: [instance])], symbols: [master])
}

/// A group holding that same instance plus a rect at (100,100,10,10).
private func docWithGroupHoldingInstance() -> Document {
    let master = Element.rect(Rect(x: 5, y: 7, width: 10, height: 20, id: "m1"))
    let instance = Element.live(.reference(ReferenceElem(
        target: ElementRef("m1"), name: nil, id: "i1")))
    let sibling = Element.rect(Rect(x: 100, y: 100, width: 10, height: 10))
    let group = Element.group(Group(children: [instance, sibling]))
    return Document(layers: [Layer(children: [group])], symbols: [master])
}

private func expectBBox(_ got: BBox?, _ want: (Double, Double, Double, Double),
                        _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let g = got else {
        Issue.record("\(what): expected a box, got nil", sourceLocation: sourceLocation)
        return
    }
    #expect(abs(g.x - want.0) < 1e-9 && abs(g.y - want.1) < 1e-9
            && abs(g.width - want.2) < 1e-9 && abs(g.height - want.3) < 1e-9,
            "\(what): expected \(want), got \(g)", sourceLocation: sourceLocation)
}

@Test func aPlacedSymbolInstanceReportsTheBoxItOccupies() {
    // Measured before the repair: (0,0,0,0).
    expectBBox(elementEvaluatedBBox(docWithInstance(), [0, 0]),
               (5, 7, 10, 20), "instance")
}

@Test func aGroupHoldingAnInstanceIsNotStretchedBackToTheOrigin() {
    // Measured before the repair: (0,0,110,110).
    expectBBox(elementEvaluatedBBox(docWithGroupHoldingInstance(), [0, 0]),
               (5, 7, 105, 103), "group with instance")
}

@Test func aDanglingInstanceStillReportsNothing() {
    // REFERENCE_GRAPH.md §3: unresolvable evaluates to empty. It draws nothing,
    // so there is no honest box — and the zero box is what this function has
    // always returned for "nothing to show". Unchanged.
    var doc = docWithInstance()
    doc = Document(layers: doc.layers, symbols: [])
    expectBBox(elementEvaluatedBBox(doc, [0, 0]), (0, 0, 0, 0), "dangling instance")
}

@Test func aGroupOfOnlyDanglingInstancesDoesNotClaimTheOrigin() {
    // The union must SKIP what occupies nothing rather than fold in a point at
    // (0,0) — otherwise the group claims a corner nothing is drawn in.
    var doc = docWithGroupHoldingInstance()
    doc = Document(layers: doc.layers, symbols: [])
    expectBBox(elementEvaluatedBBox(doc, [0, 0]),
               (100, 100, 10, 10), "group whose instance is dangling")
}

@Test func theResolverlessMethodsKeepAnsweringZeroForAnInstance() {
    // The forbidden fix, pinned (same guard as CONTAINERPAINT and RESOLVEDHIT):
    // widening `bounds` / `geometricBounds` would make them answer a question
    // they cannot see. They stay resolver-less and stay AGREEING WITH EACH OTHER.
    let instance = Element.live(.reference(ReferenceElem(
        target: ElementRef("m1"), name: nil, id: "i1")))
    #expect(instance.bounds == (x: 0, y: 0, width: 0, height: 0))
    #expect(instance.geometricBounds == (x: 0, y: 0, width: 0, height: 0))
}
