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

@Test func modelMaxUntitledNFindsHighest() {
    #expect(maxUntitledN([]) == 0)
    #expect(maxUntitledN(["drawing.svg"]) == 0)
    #expect(maxUntitledN(["Untitled-1"]) == 1)
    #expect(maxUntitledN(["Untitled-1", "Untitled-3", "logo.svg"]) == 3)
    // Non-numeric / empty suffixes are ignored.
    #expect(maxUntitledN(["Untitled-", "Untitled-x"]) == 0)
}

@Test func modelAdvancePastRestoredAvoidsCollision() {
    // A restored Untitled-1 must push the next fresh name past it. The
    // nextUntitled counter is process-global, so other tests may have
    // advanced it further; the invariant is only that the next name never
    // collides with the restored Untitled-1 (its N is >= 2).
    advanceNextUntitledPast(["Untitled-1"])
    let name = Model().filename  // nil filename -> freshFilename()
    let n = Int(name.dropFirst("Untitled-".count)) ?? 0
    #expect(n >= 2, "expected Untitled-2 or later, got \(name)")
}

@Test func modelSetDocumentNotifies() {
    let model = Model()
    var received: [Int] = []
    model.onDocumentChanged { doc in received.append(doc.layers.count) }
    model.setDocumentUnbracketed(Document(layers: []))
    #expect(received == [0])
}

@Test func modelMultipleListeners() {
    let model = Model()
    var a: [Int] = []
    var b: [Int] = []
    model.onDocumentChanged { doc in a.append(doc.layers.count) }
    model.onDocumentChanged { doc in b.append(doc.layers.count) }
    model.setDocumentUnbracketed(Document(layers: []))
    #expect(a == [0])
    #expect(b == [0])
}

@Test func modelListenerCalledOnEachChange() {
    let model = Model()
    var counts: [Int] = []
    model.onDocumentChanged { doc in counts.append(doc.layers.count) }
    let layer = Layer(name: "L1", children: [])
    model.setDocumentUnbracketed(Document(layers: [layer]))
    model.setDocumentUnbracketed(Document(layers: [layer, layer]))
    #expect(counts == [1, 2])
}

@Test func modelImmutability() {
    let model = Model()
    let before = model.document
    model.setDocumentUnbracketed(Document(layers: []))
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
    model.setDocumentUnbracketed(Document(layers: []))
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
    model.setDocumentUnbracketed(Document(layers: [layer]))
    model.snapshot()
    model.setDocumentUnbracketed(Document(layers: [layer, layer]))
    model.undo()
    #expect(model.document.layers.count == 1)
    #expect(model.canRedo)
    model.snapshot()
    model.setDocumentUnbracketed(Document(layers: []))
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

// MARK: - is_modified journal-head semantics (OP_LOG.md Increment 2 §5/§9)
//
// isModified is the journal-head cursor (journalHead != savedJournalHead), so
// undo back to the saved point reads as not-modified. Mirrors the Python /
// Rust model journal tests.

@Test func modelIsModifiedDefaultFalse() {
    #expect(!Model().isModified)
}

@Test func modelIsModifiedAfterCommittedEdit() {
    let model = Model()
    model.snapshot()
    model.setDocumentUnbracketed(Document(layers: []))
    #expect(model.isModified)
}

@Test func modelIsModifiedFalseAfterUndoBackToSaved() {
    let model = Model()
    model.markSaved()  // saved at journalHead 0
    model.snapshot()
    model.setDocumentUnbracketed(Document(layers: []))
    #expect(model.isModified)
    model.undo()
    #expect(!model.isModified, "undo back to the saved point is not modified")
    model.redo()
    #expect(model.isModified, "redo past the saved point is modified again")
}

@Test func modelIsModifiedFalseAfterMarkSaved() {
    let model = Model()
    model.snapshot()
    model.setDocumentUnbracketed(Document(layers: []))
    #expect(model.isModified)
    model.markSaved()
    #expect(!model.isModified)
}

// MARK: - Transaction journal (OP_LOG.md Increment 2, full journal)
//
// beginTxn/commitTxn build the typed Transaction journal with deterministic
// txn-N ids + the no-op rule. Mirrors the Python / Rust model journal tests:
// per-net-change journaling, no-op not journaled, cursor + redo-tail drop,
// txn-N ids + parent.

@Test func modelCommitJournalsOneTransactionPerNetChange() {
    let model = Model()
    model.withTxn { model.setDocument(Document(layers: [])) }
    #expect(model.journal.count == 1, "one committed edit = one transaction")
    #expect(model.journalHeadValue == 1, "cursor advanced to the new transaction")
    #expect(model.journal[0].txnId == "txn-0")
}

@Test func modelNoOpTransactionIsNotJournaled() {
    let model = Model()
    model.beginTxn()
    model.commitTxn()  // no edit
    #expect(model.journal.count == 0, "no-op is not journaled")
    #expect(model.journalHeadValue == 0)
    #expect(!model.canUndo, "no-op leaves no undo step")
}

@Test func modelNoOpTransactionNetIdenticalIsNotJournaled() {
    // A write that nets back to the checkpoint document is also a no-op
    // (compared via documentToTestJson — the canonical byte form).
    let model = Model()
    let checkpoint = model.document
    model.withTxn {
        model.setDocument(Document(layers: []))
        model.setDocument(checkpoint)  // back to the exact checkpoint
    }
    #expect(model.journal.count == 0, "net-identical transaction is not journaled")
    #expect(!model.canUndo)
    #expect(!model.isModified)
}

@Test func modelJournalCursorAndRedoTailDrop() {
    let model = Model()
    let l = Layer(name: "L1", children: [])
    model.withTxn { model.setDocument(Document(layers: [l])) }       // txn-0
    model.withTxn { model.setDocument(Document(layers: [l, l])) }    // txn-1
    #expect(model.journal.map { $0.txnId } == ["txn-0", "txn-1"])
    #expect(model.journal[0].parent == nil)
    #expect(model.journal[1].parent == "txn-0")
    model.undo()
    #expect(model.journalHeadValue == 1)
    // New commit after undo drops the redo tail and appends.
    model.withTxn { model.setDocument(Document(layers: [])) }
    #expect(model.journal.count == 2, "redo tail dropped, new txn appended")
    #expect(model.journal[1].txnId == "txn-2", "counter keeps advancing")
    #expect(!model.canRedo, "redo cleared on the new edit")
}

@Test func modelUndoAndRedoMoveTheJournalCursor() {
    let model = Model()
    let l = Layer(name: "A", children: [])
    model.withTxn { model.setDocument(Document(layers: [])) }
    model.withTxn { model.setDocument(Document(layers: [l])) }
    #expect(model.journalHeadValue == 2)
    model.undo()
    #expect(model.journalHeadValue == 1, "undo moves the cursor back")
    model.undo()
    #expect(model.journalHeadValue == 0)
    // The journal itself is retained across undo (it is a cursor, not a
    // high-water mark).
    #expect(model.journal.count == 2)
    model.redo()
    #expect(model.journalHeadValue == 1, "redo moves the cursor forward")
    model.redo()
    #expect(model.journalHeadValue == 2)
}

@Test func modelBeginTxnIsIdempotentWhileOpen() {
    // A session that calls beginTxn repeatedly pushes exactly ONE checkpoint
    // and undoes in one step. Mirrors Rust `begin_txn_is_idempotent_while_open`.
    let model = Model()
    model.beginTxn()
    model.setDocument(Document(layers: []))
    model.beginTxn()  // nested / repeated — no-op while open
    model.setDocument(Document(layers: [Layer(name: "L", children: [])]))
    model.commitTxn()
    model.undo()
    #expect(model.document.layers.count == 1,
        "one undo step reverts the whole session")
}

@Test func modelRedoClearsAtCommitNotBegin() {
    // The redo-clear lives in commitTxn(), not beginTxn(). Mirrors Rust
    // `redo_clears_at_commit_not_begin`.
    let model = Model()
    model.withTxn { model.setDocument(Document(layers: [])) }
    model.undo()
    #expect(model.canRedo, "undo populates redo")
    model.beginTxn()
    #expect(model.canRedo, "beginTxn does NOT clear redo")
    model.setDocument(Document(layers: []))
    model.commitTxn()
    #expect(!model.canRedo, "commitTxn clears redo (new edit invalidates redo)")
}

@Test func modelAbortTxnRollsBackAndDoesNotJournal() {
    // abortTxn rolls back to the checkpoint, discards the pending txn, and does
    // not journal or move the cursor. Mirrors Rust `abort_*` tests.
    let model = Model()
    model.withTxn { model.setDocument(Document(layers: [])) }  // txn-0
    let head = model.journalHeadValue
    let len = model.journal.count
    model.beginTxn()
    model.setDocument(Document(layers: [Layer(name: "Z", children: [])]))
    model.abortTxn()
    #expect(model.journal.count == len, "aborted transaction is not journaled")
    #expect(model.journalHeadValue == head, "cursor unmoved by abort")
    #expect(model.document.layers.count == 0, "abort rolled back the edit")
}

@Test func modelRecordOpAndNameTxnPopulateTheTransaction() {
    // recordOp appends to the open transaction; nameTxn names it. Both are
    // no-ops outside a bracket. The recorded ops carry the raw params dict.
    let model = Model()
    model.beginTxn()
    model.nameTxn("move")
    model.setDocument(Document(layers: []))
    model.recordOp(PrimitiveOp(op: "select_rect",
        params: ["op": "select_rect", "x": 0.0]))
    model.recordOp(PrimitiveOp(op: "move_selection",
        params: ["op": "move_selection", "dx": 10.0]))
    model.commitTxn()
    #expect(model.journal.count == 1)
    #expect(model.journal[0].name == "move")
    #expect(model.journal[0].ops.map { $0.op } == ["select_rect", "move_selection"])
    #expect(model.journal[0].actor == "artist")
}

// MARK: - Versioning labels (OP_LOG.md Increment 3a / VISION.md §6.9)
//
// labelVersion stamps the committed transaction AND stores the doc+index;
// restoreVersion is an ordinary undoable edit (linear timeline, not a cursor
// jump); restoring to the current state is a no-op; re-label re-points and an
// unknown name returns false. Mirrors the Rust model versioning tests.

@Test func modelLabelVersionStoresAVersionAndStampsTheTransaction() {
    let model = Model()
    model.withTxn { model.setDocument(Document(layers: [Layer(name: "A", children: [])])) }
    model.labelVersion("v1")

    #expect(model.versions.count == 1)
    #expect(model.versions[0].label == "v1")
    #expect(model.versions[0].journalHead == 1)
    // The label is stamped onto the committed transaction (serializes into the
    // journal artifact).
    #expect(model.journal[0].label == "v1")
}

@Test func modelRestoreVersionIsAnUndoableEditBackToTheLabeledState() {
    let model = Model()
    model.withTxn { model.setDocument(Document(layers: [Layer(name: "A", children: [])])) }
    model.labelVersion("v1")
    // Edit past the version.
    model.withTxn {
        model.setDocument(Document(layers: [Layer(name: "A", children: []),
                                           Layer(name: "B", children: [])]))
    }
    #expect(model.document.layers.count == 2)

    #expect(model.restoreVersion("v1"))
    #expect(model.document.layers.count == 1, "restored the labeled document")
    // Restore is an ordinary transaction on the linear timeline — undoable.
    #expect(model.canUndo)
    model.undo()
    #expect(model.document.layers.count == 2, "undo reverts the restore")
}

@Test func modelRestoreVersionToCurrentStateIsANoop() {
    let model = Model()
    model.withTxn { model.setDocument(Document(layers: [Layer(name: "A", children: [])])) }
    model.labelVersion("v1")
    let head = model.journalHeadValue
    // Already at v1's state — restoring is a no-op (not journaled).
    #expect(model.restoreVersion("v1"))
    #expect(model.journalHeadValue == head, "no transaction for a no-op restore")
}

@Test func modelLabelVersionRelabelRepointsAndUnknownRestoreReturnsFalse() {
    let model = Model()
    model.withTxn { model.setDocument(Document(layers: [Layer(name: "A", children: [])])) }
    model.labelVersion("v1")
    model.withTxn {
        model.setDocument(Document(layers: [Layer(name: "A", children: []),
                                           Layer(name: "B", children: [])]))
    }
    model.labelVersion("v1")  // re-point to the new state

    #expect(model.versions.count == 1, "re-label re-points, no duplicate")
    #expect(model.versions[0].journalHead == 2)
    #expect(!model.restoreVersion("nope"), "unknown version restore is a no-op false")
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
    model.setDocumentUnbracketed(appendToLayer0(model.document, idRect("a")))
    #expect(model.idIndex["a"] != nil)
    #expect(model.idIndex == rebuildIdIndex(model.document))

    model.setDocumentUnbracketed(appendToLayer0(model.document, idRect("b")))
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
    model.setDocumentUnbracketed(appendToLayer0(model.document, idRect("r1")))
    // Edit 2: add a second id-bearing rect "r2" (undoable).
    model.snapshot()
    model.setDocumentUnbracketed(appendToLayer0(model.document, idRect("r2")))
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
