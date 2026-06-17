import Testing
@testable import JasLib

@Test func modelDefaultDocument() {
    let model = Model()
    #expect(model.filename.hasPrefix("Untitled-"))
    #expect(model.document.layers.count == 1)
}

@Test func modelInitialFilename() {
    let model = Model(filename: "Test")
    #expect(model.filename == "Test")
}

@Test func modelSetDocumentNotifies() {
    let model = Model()
    var received: [Int] = []
    model.onDocumentChanged { doc in received.append(doc.layers.count) }
    model.document = Document(layers: [])
    #expect(received == [0])
}

@Test func modelMultipleListeners() {
    let model = Model()
    var a: [Int] = []
    var b: [Int] = []
    model.onDocumentChanged { doc in a.append(doc.layers.count) }
    model.onDocumentChanged { doc in b.append(doc.layers.count) }
    model.document = Document(layers: [])
    #expect(a == [0])
    #expect(b == [0])
}

@Test func modelListenerCalledOnEachChange() {
    let model = Model()
    var counts: [Int] = []
    model.onDocumentChanged { doc in counts.append(doc.layers.count) }
    let layer = Layer(name: "L1", children: [])
    model.document = Document(layers: [layer])
    model.document = Document(layers: [layer, layer])
    #expect(counts == [1, 2])
}

@Test func modelImmutability() {
    let model = Model()
    let before = model.document
    model.document = Document(layers: [])
    let after = model.document
    #expect(before.layers.count == 1)
    #expect(after.layers.count == 0)
}

@Test func modelFilename() {
    let model = Model()
    #expect(model.filename.hasPrefix("Untitled-"))
    model.filename = "drawing.jas"
    #expect(model.filename == "drawing.jas")
}

@Test func modelUndoRedo() {
    let model = Model()
    #expect(!model.canUndo)
    model.snapshot()
    model.document = Document(layers: [])
    #expect(model.canUndo)
    #expect(!model.canRedo)
    model.undo()
    #expect(model.document.layers.count == 1)
    #expect(model.canRedo)
    model.redo()
    #expect(model.document.layers.count == 0)
}

@Test func modelUndoClearsRedoOnNewEdit() {
    let layer = Layer(name: "L1", children: [])
    let model = Model()
    model.snapshot()
    model.document = Document(layers: [layer])
    model.snapshot()
    model.document = Document(layers: [layer, layer])
    model.undo()
    #expect(model.document.layers.count == 1)
    #expect(model.canRedo)
    model.snapshot()
    model.document = Document(layers: [])
    #expect(!model.canRedo)
}

@Test func modelUndoEmptyStack() {
    let model = Model()
    model.undo()
    #expect(model.document.layers.count == 1)
}

@Test func modelRedoEmptyStack() {
    let model = Model()
    model.redo()
    #expect(model.document.layers.count == 1)
}

// MARK: - EditingTarget (Mask editor UI — OPACITY.md §Preview interactions)

@Test func modelDefaultsToContentEditingTarget() {
    // Default editing target is the document's normal content —
    // mask-editing mode is entered explicitly via the MASK_PREVIEW
    // click. OPACITY.md §Preview interactions.
    let model = Model()
    #expect(model.editingTarget == .content)
}

@Test func modelEditingTargetRoundTripsThroughMaskMode() {
    let model = Model()
    model.editingTarget = .mask([0, 2, 1])
    #expect(model.editingTarget == .mask([0, 2, 1]))
    model.editingTarget = .content
    #expect(model.editingTarget == .content)
}

@Test func modelDefaultsToNoMaskIsolation() {
    // Mask-isolation is entered explicitly via Alt-click on
    // MASK_PREVIEW. OPACITY.md §Preview interactions.
    let model = Model()
    #expect(model.maskIsolationPath == nil)
}

@Test func modelMaskIsolationRoundTrips() {
    let model = Model()
    model.maskIsolationPath = [0, 3]
    #expect(model.maskIsolationPath == [0, 3])
    model.maskIsolationPath = nil
    #expect(model.maskIsolationPath == nil)
}

// MARK: - Phase 4b: id->element index companion (REFERENCE_GRAPH.md §2.4)

/// An id-bearing rect appended to the default layer.
private func idRect(_ id: String) -> Element {
    .rect(Rect(x: 0, y: 0, width: 10, height: 10, id: id))
}

/// Append `elem` to layer 0 of `doc`, returning a new document.
private func appendToLayer0(_ doc: Document, _ elem: Element) -> Document {
    var layers = doc.layers
    let l = layers[0]
    layers[0] = Layer(name: l.name, children: l.children + [elem],
                      opacity: l.opacity, transform: l.transform)
    return doc.replacing(layers: layers)
}

@Test func modelIdIndexPairedWithDocumentAtConstruction() {
    // Default + init() build the index up front so paint can read it. The
    // stored companion always equals a from-scratch rebuild (the gate).
    let model = Model()
    #expect(model.idIndex == rebuildIdIndex(model.document))
    let model2 = Model(document: Document())
    #expect(model2.idIndex == rebuildIdIndex(model2.document))
}

@Test func modelIdIndexTracksDocumentSetterChokepoint() {
    // Every assignment to model.document rebuilds the paired index at the
    // didSet chokepoint, so the companion tracks set-document and controller
    // edits alike. Mirrors Rust set_document / document_mut tracking.
    let model = Model()
    model.document = appendToLayer0(model.document, idRect("a"))
    #expect(model.idIndex["a"] != nil)
    #expect(model.idIndex == rebuildIdIndex(model.document))

    model.document = appendToLayer0(model.document, idRect("b"))
    #expect(model.idIndex["b"] != nil)
    #expect(model.idIndex == rebuildIdIndex(model.document))
}

@Test func modelIdIndexMatchesRebuildAfterEditsUndoRedoAndResolves() {
    // Drive the full edit/undo/redo cycle and assert the carried (paired)
    // index always equals a from-scratch rebuild — this is the gate, asserted
    // explicitly (it also fires as an assert inside undo/redo in debug).
    // Mirrors Rust `id_index_matches_rebuild_after_controller_edits_and_undo_and_resolves`.
    let model = Model()

    // Edit 1: add id-bearing rect "r1" (undoable).
    model.snapshot()
    model.document = appendToLayer0(model.document, idRect("r1"))
    // Edit 2: add a second id-bearing rect "r2" (undoable).
    model.snapshot()
    model.document = appendToLayer0(model.document, idRect("r2"))
    #expect(model.idIndex["r1"] != nil)
    #expect(model.idIndex["r2"] != nil)
    #expect(model.idIndex == rebuildIdIndex(model.document))

    // Undo edit 2: the carried index must equal a rebuild of the restored doc.
    model.undo()
    #expect(model.idIndex == rebuildIdIndex(model.document),
        "after undo the carried index equals rebuild(document)")
    #expect(model.idIndex["r1"] != nil, "r1 survives the undo")
    #expect(model.idIndex["r2"] == nil, "r2 removed by undo")

    // The index resolves a live reference to the surviving target.
    let resolver = IdIndexResolver(index: model.idIndex)
    let reference = ReferenceElem(target: ElementRef("r1"))
    var visiting = VisitSet()
    let ps = reference.evaluateWith(
        precision: DEFAULT_PRECISION, resolver: resolver, visiting: &visiting)
    #expect(ps.count == 1, "reference to r1 resolves to its single ring")

    // Redo edit 2: index again carries r2 and matches rebuild.
    model.redo()
    #expect(model.idIndex["r2"] != nil, "redo restores r2")
    #expect(model.idIndex == rebuildIdIndex(model.document))
}
