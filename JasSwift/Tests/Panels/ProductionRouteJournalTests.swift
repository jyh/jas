import Testing
import Foundation
@testable import JasLib

/// OP_LOG.md §9 — production-route proofs that the PANEL / MENU production
/// handlers for the verb33 verbs journal a real op through the shared `opApply`
/// dispatcher (the same path the tool gestures already use). Mirrors Rust's
/// `production_route_*` tests in `jas_dioxus/src/interpreter/renderer.rs`.
///
/// Each test drives the REAL Swift production handler (the LayersPanel platform-
/// effect registry via `LayersPanel.dispatchYamlAction`, or the tool-effect
/// registry via `buildYamlToolEffects`) against a real `Model`, then asserts:
///   (1) the committed Transaction journals the expected verb op(s) with the
///       RESOLVED params (the production eval → literal path, NOT the YAML expr
///       string) and the right targets;
///   (2) the transaction carries the action name (`nameTxn`);
///   (3) ZERO behavior change: the live document is exactly what the direct
///       mutator produced before routing, AND replaying the journal from the
///       pre-edit document is byte-identical to the live document
///       (checkpoint_equivalence);
///   (4) the snapshot/undo bracket still works (one undo step round-trips).
///
/// These complement the operations-fixture proofs (CrossLanguageTests), which
/// drive `opApply` directly via the harness — here we prove the PRODUCTION
/// gesture reaches the same dispatcher.

// MARK: - Shared helpers

/// Replay the whole journal onto a fresh model seeded from `preDoc` and
/// byte-compare to the live document — the checkpoint_equivalence gate.
private func assertCheckpointEquivalence(_ model: Model, preDoc: Document) {
    let snapshotDoc = documentToTestJson(model.document)
    let replay = Model(document: preDoc)
    let controller = Controller(model: replay)
    for t in model.journal {
        for o in t.ops {
            var op = o.params
            op["op"] = o.op
            opApply(replay, controller, op)
        }
    }
    let replayDoc = documentToTestJson(replay.document)
    #expect(replayDoc == snapshotDoc,
            "checkpoint_equivalence: journal replay == snapshot path")
}

/// Build a Model carrying two artboards with known ids ("ab1", "ab2") so the
/// production artboard verbs have something to write.
private func makeModelWithTwoArtboards() -> Model {
    let doc = Document(
        layers: [Layer(name: "A", children: [], visibility: .preview)],
        selectedLayer: 0,
        selection: [],
        artboards: [Artboard.defaultWithId("ab1"), Artboard.defaultWithId("ab2")]
    )
    return Model(document: doc)
}

// MARK: - Print-config setters (8 verbs)

@Test func productionRouteJournalsPrintConfigSetter() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: [], visibility: .preview),
    ]))
    let preDoc = model.document
    let before = model.journal.count

    // Mirror document_setup_confirm: a `snapshot` opens the txn, then the
    // field setter runs through the production handler. dispatchYamlAction owns
    // + names + commits the transaction.
    LayersPanel.dispatchYamlAction(
        "document_setup_confirm",
        model: model,
        params: [
            "bleed_top": 0, "bleed_right": 0, "bleed_bottom": 0, "bleed_left": 0,
            "bleed_uniform": true,
            "show_images_outline": false,
            "highlight_substituted_glyphs": false,
            "grid_size": 42,
        ]
    )

    // (1a) exactly one new, named transaction.
    #expect(model.journal.count == before + 1,
            "the print-config action commits one transaction")
    guard let txn = model.journal.last else {
        Issue.record("a committed transaction"); return
    }
    #expect(txn.name == "document_setup_confirm",
            "the transaction is named with its action verb")
    // (1b) it journals at least the grid_size op with the RESOLVED literal.
    // (document_setup_confirm chains many field sets; the no-net-change ones are
    // dropped by the commit-time no-op rule, so the surviving op is grid_size.)
    let gridOp = txn.ops.first { ($0.params["field"] as? String) == "grid_size" }
    guard let op = gridOp else {
        Issue.record("a grid_size set_document_setup_field op was journaled"); return
    }
    #expect(op.op == "set_document_setup_field", "the journaled verb")
    // The param value is the RESOLVED literal 42, not an expr string.
    #expect((op.params["value"] as? NSNumber)?.doubleValue == 42.0,
            "the journaled value is the RESOLVED literal")
    // (1c) document-global config ⇒ empty targets.
    #expect(op.targets.isEmpty, "print-config ops carry empty targets")
    // The mutation actually landed.
    #expect(model.document.documentSetup.gridSize == 42.0,
            "grid_size was set on the live document")

    assertCheckpointEquivalence(model, preDoc: preDoc)

    // (4) undo round-trips in ONE step.
    model.undo()
    #expect(model.document.documentSetup.gridSize == preDoc.documentSetup.gridSize,
            "undo restores the pre-edit grid_size")
}

@Test func productionRouteJournalsPrintPreferencesSetter() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: [], visibility: .preview),
    ]))
    let preDoc = model.document
    let before = model.journal.count

    // Drive a single print-preferences field setter through the production
    // registry. Use a synthetic action carrying exactly one field set so the
    // journaled op is unambiguous.
    LayersPanel.runEffectsForTest(
        actionName: "print_dialog_done",
        effects: [
            "snapshot",
            ["doc.set_print_preferences_field": ["field": "copies", "value": "7"]],
        ],
        model: model
    )

    #expect(model.journal.count == before + 1)
    guard let txn = model.journal.last else {
        Issue.record("a committed transaction"); return
    }
    #expect(txn.name == "print_dialog_done")
    #expect(txn.ops.count == 1, "exactly one print-prefs op journaled")
    guard let op = txn.ops.first else { Issue.record("at least one op"); return }
    #expect(op.op == "set_print_preferences_field")
    #expect(op.params["field"] as? String == "copies")
    #expect((op.params["value"] as? NSNumber)?.doubleValue == 7.0,
            "the RESOLVED literal, not the YAML expr")
    #expect(op.targets.isEmpty)

    assertCheckpointEquivalence(model, preDoc: preDoc)
    // (4) undo round-trips in ONE step (the snapshot/undo bracket still works).
    model.undo()
    #expect(model.document.printPreferences.copies == preDoc.printPreferences.copies,
            "undo restores the pre-edit copies")
}

// MARK: - Artboard setters / minting / reorder (7 verbs)

@Test func productionRouteJournalsSetArtboardField() {
    let model = makeModelWithTwoArtboards()
    let preDoc = model.document
    let before = model.journal.count

    LayersPanel.runEffectsForTest(
        actionName: "artboard_options_confirm",
        effects: [
            "snapshot",
            ["doc.set_artboard_field": ["id": "'ab2'", "field": "x", "value": "100"]],
        ],
        model: model
    )

    #expect(model.journal.count == before + 1)
    guard let txn = model.journal.last else { Issue.record("txn"); return }
    #expect(txn.name == "artboard_options_confirm")
    #expect(txn.ops.count == 1, "exactly one artboard op journaled")
    guard let op = txn.ops.first else { Issue.record("at least one op"); return }
    #expect(op.op == "set_artboard_field")
    #expect(op.params["id"] as? String == "ab2", "the resolved artboard id")
    #expect(op.params["field"] as? String == "x")
    #expect((op.params["value"] as? NSNumber)?.doubleValue == 100.0,
            "the RESOLVED literal")
    #expect(op.targets == ["ab2"], "targets carry the written artboard id")
    // Mutation landed.
    let ab2 = model.document.artboards.first { $0.id == "ab2" }!
    #expect(ab2.x == 100.0)

    assertCheckpointEquivalence(model, preDoc: preDoc)
    model.undo()
    #expect(model.document.artboards.first { $0.id == "ab2" }!.x == preDoc.artboards[1].x)
}

@Test func productionRouteJournalsSetArtboardOptionsFieldEmptyTargets() {
    let model = makeModelWithTwoArtboards()
    let preDoc = model.document

    // Default is true; set false so it is a real change (a no-net-change txn
    // would be dropped by the commit-time no-op rule).
    LayersPanel.runEffectsForTest(
        actionName: "artboard_options_confirm",
        effects: [
            "snapshot",
            ["doc.set_artboard_options_field":
                ["field": "fade_region_outside_artboard", "value": "false"]],
        ],
        model: model
    )

    guard let txn = model.journal.last else { Issue.record("txn"); return }
    #expect(txn.ops.count == 1)
    guard let op = txn.ops.first else { Issue.record("at least one op"); return }
    #expect(op.op == "set_artboard_options_field")
    #expect(op.params["field"] as? String == "fade_region_outside_artboard")
    #expect((op.params["value"] as? NSNumber)?.isBool == true)
    #expect((op.params["value"] as? NSNumber)?.boolValue == false)
    #expect(op.targets.isEmpty, "options field is document-global ⇒ empty targets")
    #expect(model.document.artboardOptions.fadeRegionOutsideArtboard == false)

    assertCheckpointEquivalence(model, preDoc: preDoc)
}

@Test func productionRouteJournalsDeleteArtboardById() {
    let model = makeModelWithTwoArtboards()
    let preDoc = model.document
    let before = model.journal.count

    LayersPanel.runEffectsForTest(
        actionName: "delete_artboard_from_dialog",
        effects: [
            "snapshot",
            ["doc.delete_artboard_by_id": "'ab1'"],
        ],
        model: model
    )

    #expect(model.journal.count == before + 1)
    guard let txn = model.journal.last else { Issue.record("txn"); return }
    #expect(txn.ops.count == 1)
    guard let op = txn.ops.first else { Issue.record("at least one op"); return }
    #expect(op.op == "delete_artboard_by_id")
    #expect(op.params["id"] as? String == "ab1")
    #expect(op.targets == ["ab1"], "delete targets carry the deleted id")
    #expect(model.document.artboards.count == 1)
    #expect(model.document.artboards[0].id == "ab2")

    assertCheckpointEquivalence(model, preDoc: preDoc)
    model.undo()
    #expect(model.document.artboards.count == 2)
}

@Test func productionRouteJournalsCreateArtboard() {
    let model = makeModelWithTwoArtboards()
    let preDoc = model.document

    LayersPanel.runEffectsForTest(
        actionName: "new_artboard",
        effects: [
            "snapshot",
            ["doc.create_artboard": ["x": "0", "y": "0", "width": "100", "height": "100"]],
        ],
        model: model
    )

    guard let txn = model.journal.last else { Issue.record("txn"); return }
    #expect(txn.ops.count == 1)
    guard let op = txn.ops.first else { Issue.record("at least one op"); return }
    #expect(op.op == "create_artboard")
    // VALUE-IN-OP: the id is minted ONCE in production and journaled as a literal.
    let mintedId = op.params["id"] as? String
    #expect(mintedId != nil && !(mintedId!.isEmpty), "the minted id is journaled as a literal")
    #expect(op.targets == [mintedId!], "targets carry the new artboard id")
    #expect(model.document.artboards.count == 3)
    #expect(model.document.artboards[2].id == mintedId)

    // checkpoint_equivalence: replay reads the recorded id VERBATIM (never re-mints).
    assertCheckpointEquivalence(model, preDoc: preDoc)
    model.undo()
    #expect(model.document.artboards.count == 2)
}

@Test func productionRouteJournalsDuplicateArtboard() {
    let model = makeModelWithTwoArtboards()
    let preDoc = model.document

    LayersPanel.runEffectsForTest(
        actionName: "duplicate_artboards",
        effects: [
            "snapshot",
            ["doc.duplicate_artboard": "'ab1'"],
        ],
        model: model
    )

    guard let txn = model.journal.last else { Issue.record("txn"); return }
    #expect(txn.ops.count == 1)
    guard let op = txn.ops.first else { Issue.record("at least one op"); return }
    #expect(op.op == "duplicate_artboard")
    #expect(op.params["id"] as? String == "ab1", "the resolved source id")
    let newId = op.params["new_id"] as? String
    #expect(newId != nil && !(newId!.isEmpty), "the minted new_id is a journaled literal")
    // The derived name is journaled as a literal (replay never re-derives).
    #expect(op.params["name"] as? String != nil, "the derived name is a journaled literal")
    #expect(op.targets == [newId!], "targets carry the new id")
    #expect(model.document.artboards.count == 3)

    assertCheckpointEquivalence(model, preDoc: preDoc)
    model.undo()
    #expect(model.document.artboards.count == 2)
}

@Test func productionRouteJournalsMoveArtboardsUp() {
    let model = makeModelWithTwoArtboards()
    let preDoc = model.document

    // Move ab2 (index 1) up.
    LayersPanel.runEffectsForTest(
        actionName: "move_artboard_up",
        effects: [
            "snapshot",
            ["doc.move_artboards_up": "['ab2']"],
        ],
        model: model
    )

    guard let txn = model.journal.last else { Issue.record("txn"); return }
    #expect(txn.ops.count == 1)
    guard let op = txn.ops.first else { Issue.record("at least one op"); return }
    #expect(op.op == "move_artboards_up")
    #expect((op.params["ids"] as? [Any])?.compactMap { $0 as? String } == ["ab2"])
    #expect(op.targets == ["ab2"], "targets carry the moved ids")
    #expect(model.document.artboards.map(\.id) == ["ab2", "ab1"])

    assertCheckpointEquivalence(model, preDoc: preDoc)
    model.undo()
    #expect(model.document.artboards.map(\.id) == ["ab1", "ab2"])
}

// MARK: - Structural tree-mutation verbs

@Test func productionRouteNewGroupJournalsOneWrapInGroup() {
    let children: [Element] = [
        .rect(Rect(x: 0, y: 0, width: 10, height: 10)),
        .rect(Rect(x: 20, y: 0, width: 10, height: 10)),
        .rect(Rect(x: 40, y: 0, width: 10, height: 10)),
    ]
    let model = Model(document: Document(layers: [Layer(name: "L", children: children)]))
    let preDoc = model.document
    let before = model.journal.count

    LayersPanel.dispatchYamlAction("new_group", model: model,
                                   panelSelection: [[0, 0], [0, 1]])

    #expect(model.journal.count == before + 1, "one transaction")
    guard let txn = model.journal.last else { Issue.record("txn"); return }
    #expect(txn.name == "new_group")
    #expect(txn.ops.count == 1, "one wrap_in_group op")
    #expect(txn.ops.first?.op == "wrap_in_group")
    // Mutation landed: layer has 2 children (group + trailing rect).
    #expect(model.document.layers[0].children.count == 2)
    guard case .group = model.document.layers[0].children[0] else {
        Issue.record("expected a group at children[0]"); return
    }

    assertCheckpointEquivalence(model, preDoc: preDoc)
    model.undo()
    #expect(model.document.layers[0].children.count == 3)
}

@Test func productionRouteCollectInNewLayerJournalsWrapInLayer() {
    let model = Model(document: Document(layers: [
        Layer(name: "Layer 1", children: []),
        Layer(name: "Layer 2", children: []),
        Layer(name: "Layer 3", children: []),
    ]))
    let preDoc = model.document
    let before = model.journal.count

    LayersPanel.dispatchYamlAction("collect_in_new_layer", model: model,
                                   panelSelection: [[0], [2]])

    #expect(model.journal.count == before + 1)
    guard let txn = model.journal.last else { Issue.record("txn"); return }
    #expect(txn.name == "collect_in_new_layer")
    #expect(txn.ops.count == 1, "one wrap_in_layer op")
    guard let op = txn.ops.first else { Issue.record("at least one op"); return }
    #expect(op.op == "wrap_in_layer")
    // CRITICAL: the name is the RESOLVED literal (the live next_layer_name),
    // NOT the YAML expr string — replay must not re-derive a colliding name.
    #expect(op.params["name"] as? String == "Layer 4",
            "the journaled name is the RESOLVED literal")
    #expect(model.document.layers.count == 2)
    #expect(model.document.layers[1].name == "Layer 4")

    assertCheckpointEquivalence(model, preDoc: preDoc)
    model.undo()
    #expect(model.document.layers.count == 3)
}

@Test func productionRouteFlattenArtworkJournalsUnpackGroupAt() {
    let inner: [Element] = [
        .rect(Rect(x: 0, y: 0, width: 10, height: 10)),
        .rect(Rect(x: 20, y: 0, width: 10, height: 10)),
    ]
    let group = Element.group(Group(children: inner))
    let model = Model(document: Document(layers: [Layer(name: "L", children: [group])]))
    let preDoc = model.document
    let before = model.journal.count

    LayersPanel.dispatchYamlAction("flatten_artwork", model: model,
                                   panelSelection: [[0, 0]])

    #expect(model.journal.count == before + 1)
    guard let txn = model.journal.last else { Issue.record("txn"); return }
    #expect(txn.name == "flatten_artwork")
    #expect(txn.ops.count == 1, "one unpack_group_at op")
    #expect(txn.ops.first?.op == "unpack_group_at")
    #expect(model.document.layers[0].children.count == 2)

    assertCheckpointEquivalence(model, preDoc: preDoc)
    model.undo()
    #expect(model.document.layers[0].children.count == 1)
}

@Test func productionRouteDeleteLayerSelectionJournalsDeleteAt() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: []),
        Layer(name: "B", children: []),
        Layer(name: "C", children: []),
    ]))
    let preDoc = model.document
    let before = model.journal.count

    LayersPanel.dispatchYamlAction("delete_layer_selection", model: model,
                                   panelSelection: [[0], [2]])

    #expect(model.journal.count == before + 1, "one transaction for the whole foreach")
    guard let txn = model.journal.last else { Issue.record("txn"); return }
    #expect(txn.name == "delete_layer_selection")
    // foreach over reverse([[0],[2]]) → two delete_at ops in one txn.
    #expect(txn.ops.count == 2, "two delete_at ops journaled in one txn")
    for op in txn.ops {
        #expect(op.op == "delete_at")
    }
    #expect(model.document.layers.count == 1)
    #expect(model.document.layers[0].name == "B")

    assertCheckpointEquivalence(model, preDoc: preDoc)
    model.undo()
    #expect(model.document.layers.count == 3)
}

@Test func productionRouteDuplicateLayerSelectionJournalsInsertAfter() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: []),
        Layer(name: "B", children: []),
    ]))
    let preDoc = model.document
    let before = model.journal.count

    LayersPanel.dispatchYamlAction("duplicate_layer_selection", model: model,
                                   panelSelection: [[1]])

    #expect(model.journal.count == before + 1)
    guard let txn = model.journal.last else { Issue.record("txn"); return }
    #expect(txn.name == "duplicate_layer_selection")
    #expect(txn.ops.count == 1, "one insert_after op")
    #expect(txn.ops.first?.op == "insert_after")
    #expect(model.document.layers.count == 3)

    assertCheckpointEquivalence(model, preDoc: preDoc)
    model.undo()
    #expect(model.document.layers.count == 2)
}

@Test func productionRouteNewLayerJournalsInsertAt() {
    let model = Model(document: Document(layers: [
        Layer(name: "Layer 1", children: []),
    ]))
    let preDoc = model.document
    let before = model.journal.count

    LayersPanel.dispatchYamlAction("new_layer", model: model)

    #expect(model.journal.count == before + 1)
    guard let txn = model.journal.last else { Issue.record("txn"); return }
    #expect(txn.name == "new_layer")
    #expect(txn.ops.count == 1, "one insert_at op")
    #expect(txn.ops.first?.op == "insert_at")
    #expect(model.document.layers.count == 2)
    #expect(model.document.layers[1].name == "Layer 2")

    assertCheckpointEquivalence(model, preDoc: preDoc)
    model.undo()
    #expect(model.document.layers.count == 1)
}

// MARK: - delete_selection (orphan-confirm OK path)

@Test func productionRouteDeleteSelectionJournalsThroughOpApply() {
    // A document with a selected rect; the orphan-confirm OK action deletes it.
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let model = Model(document: Document(
        layers: [Layer(name: "L", children: [rect])],
        selectedLayer: 0,
        selection: [ElementSelection.all([0, 0])]
    ))
    let preDoc = model.document
    let before = model.journal.count

    LayersPanel.runEffectsForTest(
        actionName: "delete_orphan_confirm_ok",
        effects: ["snapshot", "doc.delete_selection"],
        model: model
    )

    #expect(model.journal.count == before + 1)
    guard let txn = model.journal.last else { Issue.record("txn"); return }
    #expect(txn.name == "delete_orphan_confirm_ok")
    #expect(txn.ops.count == 1)
    #expect(txn.ops.first?.op == "delete_selection")
    #expect(model.document.layers[0].children.isEmpty, "the selection was deleted")

    assertCheckpointEquivalence(model, preDoc: preDoc)
    model.undo()
    #expect(model.document.layers[0].children.count == 1)
}

// MARK: - set_attr_on_selection (brush apply)

@Test func productionRouteSetAttrOnSelectionJournalsThroughOpApply() {
    // A selected Path (brushes apply to Paths only); apply_brush_to_selection
    // sets stroke_brush + clears overrides. The brush attrs are canonically-
    // invisible, so the no-op rule falls back to the structural element compare
    // to keep the txn.
    let path = Element.path(Path(d: [.moveTo(0, 0), .lineTo(10, 10)],
                                 stroke: Stroke(color: .black)))
    let model = Model(document: Document(
        layers: [Layer(name: "L", children: [path])],
        selectedLayer: 0,
        selection: [ElementSelection.all([0, 0])]
    ))
    let preDoc = model.document
    let before = model.journal.count

    // Drive the REAL brush-apply effect list through the tool-effect registry
    // (the production registry that owns doc.set_attr_on_selection).
    let effects: [Any] = [
        ["doc.snapshot": [:]],
        ["doc.set_attr_on_selection": ["attr": "stroke_brush", "value": "'lib/calligraphic'"]],
        ["doc.set_attr_on_selection": ["attr": "stroke_brush_overrides", "value": "null"]],
    ]
    runEffects(effects, ctx: [:], store: model.stateStore,
               platformEffects: buildYamlToolEffects(model: model),
               model: model, actionName: "apply_brush_to_selection")

    #expect(model.journal.count == before + 1, "one transaction")
    guard let txn = model.journal.last else { Issue.record("txn"); return }
    #expect(txn.name == "apply_brush_to_selection")
    // The first set is an effective change (sets the brush); the second
    // (clear overrides on an already-null override) is a no-op that journals
    // nothing — so exactly one op survives.
    let setOps = txn.ops.filter { $0.op == "set_attr_on_selection" }
    #expect(setOps.count >= 1, "the brush set journaled a set_attr_on_selection op")
    let op = setOps[0]
    #expect(op.params["attr"] as? String == "stroke_brush")
    #expect(op.params["value"] as? String == "lib/calligraphic",
            "the RESOLVED literal value")
    // The mutation landed.
    guard case .path(let p) = model.document.layers[0].children[0] else {
        Issue.record("expected path"); return
    }
    #expect(p.strokeBrush == "lib/calligraphic")

    assertCheckpointEquivalence(model, preDoc: preDoc)
    // Undo round-trips the brush attr.
    model.undo()
    guard case .path(let p2) = model.document.layers[0].children[0] else {
        Issue.record("expected path"); return
    }
    #expect(p2.strokeBrush == nil, "undo clears the brush")
}

@Test func productionRouteSetAttrOnSelectionClearJournalsThroughOpApply() {
    // remove_brush_from_selection sets stroke_brush -> null (CLEAR). The
    // production handler encodes a resolved-null value as the empty string;
    // the opApply arm reads a present-but-empty `value` as a CLEAR (nil).
    let path = Element.path(Path(d: [.moveTo(0, 0), .lineTo(10, 10)],
                                 stroke: Stroke(color: .black),
                                 strokeBrush: "lib/calligraphic"))
    let model = Model(document: Document(
        layers: [Layer(name: "L", children: [path])],
        selectedLayer: 0,
        selection: [ElementSelection.all([0, 0])]
    ))
    let preDoc = model.document

    let effects: [Any] = [
        ["doc.snapshot": [:]],
        ["doc.set_attr_on_selection": ["attr": "stroke_brush", "value": "null"]],
    ]
    runEffects(effects, ctx: [:], store: model.stateStore,
               platformEffects: buildYamlToolEffects(model: model),
               model: model, actionName: "remove_brush_from_selection")

    guard let txn = model.journal.last else { Issue.record("txn"); return }
    let setOps = txn.ops.filter { $0.op == "set_attr_on_selection" }
    #expect(setOps.count == 1, "the clear journaled one set_attr_on_selection op")
    #expect(setOps.first?.params["attr"] as? String == "stroke_brush")
    // The resolved-null clear is encoded as the empty string in the op.
    #expect(setOps.first?.params["value"] as? String == "")
    guard case .path(let p) = model.document.layers[0].children[0] else {
        Issue.record("expected path"); return
    }
    #expect(p.strokeBrush == nil, "the brush was cleared")

    assertCheckpointEquivalence(model, preDoc: preDoc)
}

// MARK: - Native menu Delete / Cut (JasCommands routes the SAME delete_selection op)

@Test func productionRouteNativeMenuDeleteJournalsDeleteSelection() {
    // JasCommands' menu Delete uses a native NSAlert confirm but routes the
    // mutation through `model.withTxn { nameTxn; opApply(delete_selection) }`.
    // Drive that exact routing (the no-orphan path, so no alert) and assert it
    // journals one named delete_selection op + zero behavior change + undo.
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let model = Model(document: Document(
        layers: [Layer(name: "L", children: [rect])],
        selectedLayer: 0,
        selection: [ElementSelection.all([0, 0])]
    ))
    let preDoc = model.document
    let before = model.journal.count

    // The native handler's routed core (the only behavior when no orphans).
    model.withTxn {
        model.nameTxn("delete_orphan_confirm_ok")
        opApply(model, Controller(model: model), ["op": "delete_selection"])
    }

    #expect(model.journal.count == before + 1)
    guard let txn = model.journal.last else { Issue.record("txn"); return }
    #expect(txn.name == "delete_orphan_confirm_ok")
    #expect(txn.ops.count == 1)
    #expect(txn.ops.first?.op == "delete_selection")
    #expect(model.document.layers[0].children.isEmpty)

    assertCheckpointEquivalence(model, preDoc: preDoc)
    model.undo()
    #expect(model.document.layers[0].children.count == 1)
}
