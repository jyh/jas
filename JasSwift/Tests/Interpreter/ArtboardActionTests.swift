import Testing
@testable import JasLib

/// Integration tests for the artboard YAML action dispatch.
///
/// Each test runs a full action via LayersPanel.dispatchYamlAction
/// (which reads workspace/actions.yaml compiled into workspace.json
/// at build time) and verifies the document-model side effects.

@Test func newArtboardActionAppendsOne() {
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: [Artboard.defaultWithId("aaa00001")]
    ))
    LayersPanel.dispatchYamlAction("new_artboard", model: model)
    #expect(model.document.artboards.count == 2)
    #expect(model.document.artboards[1].name == "Artboard 2")
    #expect(model.document.artboards[0].id != model.document.artboards[1].id)
}

@Test func deleteArtboardsActionRemovesSelection() {
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: [
            Artboard.defaultWithId("aaa"),
            Artboard.defaultWithId("bbb"),
            Artboard.defaultWithId("ccc"),
        ]
    ))
    LayersPanel.dispatchYamlAction(
        "delete_artboards",
        model: model,
        artboardsPanelSelection: ["bbb"]
    )
    let ids = model.document.artboards.map(\.id)
    #expect(ids == ["aaa", "ccc"])
}

@Test func duplicateArtboardsActionWithFreshNameAndOffset() {
    let source = Artboard.defaultWithId("aaa").with(x: 50, y: 80)
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: [source]
    ))
    LayersPanel.dispatchYamlAction(
        "duplicate_artboards",
        model: model,
        artboardsPanelSelection: ["aaa"]
    )
    #expect(model.document.artboards.count == 2)
    let dup = model.document.artboards[1]
    #expect(dup.id != "aaa")
    #expect(dup.name == "Artboard 2")
    #expect(dup.x == 70)   // 50 + 20
    #expect(dup.y == 100)  // 80 + 20
}

@Test func moveArtboardUpActionSwapRule() {
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: [
            Artboard.defaultWithId("aaa"),
            Artboard.defaultWithId("bbb"),
            Artboard.defaultWithId("ccc"),
        ]
    ))
    LayersPanel.dispatchYamlAction(
        "move_artboard_up",
        model: model,
        artboardsPanelSelection: ["bbb"]
    )
    #expect(model.document.artboards.map(\.id) == ["bbb", "aaa", "ccc"])
}

@Test func moveArtboardUpDiscontiguous_1_3_5() {
    // ART-103 canonical example: {1, 3, 5} → [1, 3, 2, 5, 4].
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: ["a1", "a2", "a3", "a4", "a5"].map(Artboard.defaultWithId)
    ))
    LayersPanel.dispatchYamlAction(
        "move_artboard_up",
        model: model,
        artboardsPanelSelection: ["a1", "a3", "a5"]
    )
    #expect(model.document.artboards.map(\.id) == ["a1", "a3", "a2", "a5", "a4"])
}

@Test func confirmArtboardRenameWritesName() {
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: [Artboard.defaultWithId("aaa")]
    ))
    LayersPanel.dispatchYamlAction(
        "confirm_artboard_rename",
        model: model,
        params: [
            "artboard_id": "aaa",
            "new_name": "Cover",
        ]
    )
    #expect(model.document.artboards[0].name == "Cover")
}

@Test func nextArtboardNameFillsGap() {
    let abs = [
        Artboard.defaultWithId("a").with(name: "Artboard 1"),
        Artboard.defaultWithId("b").with(name: "Artboard 3"),
    ]
    #expect(nextArtboardName(abs) == "Artboard 2")
}

@Test func ensureArtboardsInvariantSeedsDefault() {
    let (abs, repaired) = ensureArtboardsInvariant([]) { "seedfeed" }
    #expect(repaired == true)
    #expect(abs.count == 1)
    #expect(abs[0].name == "Artboard 1")
    #expect(abs[0].id == "seedfeed")
}

@Test func artboardFillCanonicalRoundTrip() {
    #expect(ArtboardFill.transparent.asCanonical == "transparent")
    #expect(ArtboardFill.color("#ff0000").asCanonical == "#ff0000")
    #expect(ArtboardFill.fromCanonical("transparent") == .transparent)
    #expect(ArtboardFill.fromCanonical("#ff0000") == .color("#ff0000"))
}

@Test func documentToTestJsonOmitsDefaults() {
    // Legacy-compat: empty artboards + default options produce no
    // artboard-related keys in the canonical JSON.
    let doc = Document(layers: [Layer(children: [])])
    let json = documentToTestJson(doc)
    #expect(!json.contains("\"artboards\""))
    #expect(!json.contains("\"artboard_options\""))
}

@Test func documentToTestJsonEmitsArtboardsWhenPresent() {
    let doc = Document(
        layers: [Layer(children: [])],
        artboards: [Artboard.defaultWithId("idaaaaaa")]
    )
    let json = documentToTestJson(doc)
    #expect(json.contains("\"artboards\":["))
    #expect(json.contains("\"id\":\"idaaaaaa\""))
    #expect(json.contains("\"fill\":\"transparent\""))
}

@Test func artboardsRoundtripPreservesIds() {
    let doc = Document(
        layers: [Layer(children: [])],
        artboards: [
            Artboard.defaultWithId("aaa00001"),
            Artboard.defaultWithId("bbb00002").with(name: "Cover"),
        ]
    )
    let json1 = documentToTestJson(doc)
    let doc2 = testJsonToDocument(json1)
    #expect(doc2.artboards.count == 2)
    #expect(doc2.artboards[0].id == "aaa00001")
    #expect(doc2.artboards[1].name == "Cover")
    let json2 = documentToTestJson(doc2)
    #expect(json1 == json2)
}

// ── Phase F: anchor_offset builtins + dialog computed props ──

@Test func anchorOffsetXCenterHalfWidth() {
    let ctx: [String: Any] = [:]
    let v = evaluate("anchor_offset_x('center', 612)", context: ctx)
    if case .number(let n) = v {
        #expect(n == 306)
    } else {
        Issue.record("Expected number")
    }
}

@Test func anchorOffsetYCenterHalfHeight() {
    let ctx: [String: Any] = [:]
    let v = evaluate("anchor_offset_y('center', 792)", context: ctx)
    if case .number(let n) = v {
        #expect(n == 396)
    } else {
        Issue.record("Expected number")
    }
}

@Test func anchorOffsetTopLeftZero() {
    let ctx: [String: Any] = [:]
    if case .number(let n) = evaluate("anchor_offset_x('top_left', 612)", context: ctx) {
        #expect(n == 0)
    } else {
        Issue.record("Expected number")
    }
}

@Test func anchorOffsetBottomRightFull() {
    let ctx: [String: Any] = [:]
    if case .number(let n) = evaluate("anchor_offset_x('bottom_right', 612)", context: ctx) {
        #expect(n == 612)
    } else {
        Issue.record("Expected number")
    }
}

@Test func dialogComputedPropXRpCenter() {
    // ART-199: reference_point=center on a 612-wide artboard at x=0
    // displays X=306 in the dialog.
    let store = StateStore()
    let props: [String: [String: Any]] = [
        "x_rp": [
            "get": "x_stored + anchor_offset_x(panel.reference_point, width)"
        ],
    ]
    var defaults: [String: Any] = [:]
    defaults["x_stored"] = 0
    defaults["width"] = 612
    store.initDialog("test", defaults: defaults, props: props)
    let outer: [String: Any] = [
        "panel": ["reference_point": "center"]
    ]
    let x = store.getDialogWithOuter("x_rp", outer: outer)
    #expect((x as? Int) == 306 || (x as? Double) == 306)
}

@Test func dialogComputedPropXRpTopLeftShowsRaw() {
    let store = StateStore()
    let props: [String: [String: Any]] = [
        "x_rp": [
            "get": "x_stored + anchor_offset_x(panel.reference_point, width)"
        ],
    ]
    var defaults: [String: Any] = [:]
    defaults["x_stored"] = 100
    defaults["width"] = 612
    store.initDialog("test", defaults: defaults, props: props)
    let outer: [String: Any] = [
        "panel": ["reference_point": "top_left"]
    ]
    let x = store.getDialogWithOuter("x_rp", outer: outer)
    #expect((x as? Int) == 100 || (x as? Double) == 100)
}

// MARK: - Phase F follow-up: render-time outer scope in YamlDialogOverlay
// Verifies that buildDialogEvalContext merges outer-scope keys
// (panel, active_document) alongside dialog / param while preserving
// dialog-local precedence on collision.

@Test func dialogEvalCtxIncludesOuterScope() {
    let state: [String: Any] = ["name": "Cover"]
    let params: [String: Any] = ["artboard_id": "aaa00001"]
    let outer: [String: Any] = [
        "panel": ["reference_point": "center"],
        "active_document": ["artboards_count": 3],
    ]
    let ctx = buildDialogEvalContext(state: state, params: params, outer: outer)
    // Dialog-local keys surfaced intact.
    #expect((ctx["dialog"] as? [String: Any])?["name"] as? String == "Cover")
    #expect((ctx["param"] as? [String: Any])?["artboard_id"] as? String == "aaa00001")
    // Outer-scope keys merged in.
    #expect((ctx["panel"] as? [String: Any])?["reference_point"] as? String == "center")
    #expect((ctx["active_document"] as? [String: Any])?["artboards_count"] as? Int == 3)
}

@Test func dialogEvalCtxDialogWinsOverOuterCollision() {
    // If an outer caller accidentally published a `dialog` key, the
    // overlay's own dialog state must win so bind.value: "dialog.foo"
    // never resolves against the stale outer dict.
    let state: [String: Any] = ["foo": "live"]
    let outer: [String: Any] = ["dialog": ["foo": "stale"]]
    let ctx = buildDialogEvalContext(state: state, params: [:], outer: outer)
    #expect((ctx["dialog"] as? [String: Any])?["foo"] as? String == "live")
}

@Test func dialogEvalCtxResolvesOuterPanelExpression() {
    // Round-trip: feed the merged ctx into the expression evaluator
    // and confirm panel.* lookups succeed. This is the path used by
    // bind.* expressions during dialog rendering.
    let outer: [String: Any] = [
        "panel": ["reference_point": "top_left"]
    ]
    let ctx = buildDialogEvalContext(state: [:], params: [:], outer: outer)
    let result = evaluate("panel.reference_point", context: ctx)
    if case .string(let s) = result {
        #expect(s == "top_left")
    } else {
        Issue.record("Expected string result, got \(result)")
    }
}

@Test func dialogEvalCtxResolvesActiveDocumentArtboardsCount() {
    // Mirrors the Artboard Options footer's bind.disabled predicate:
    // "active_document.artboards_count <= 1".
    let outer: [String: Any] = [
        "active_document": ["artboards_count": 1]
    ]
    let ctx = buildDialogEvalContext(state: [:], params: [:], outer: outer)
    let result = evaluate("active_document.artboards_count <= 1", context: ctx)
    if case .bool(let b) = result {
        #expect(b == true)
    } else {
        Issue.record("Expected bool result, got \(result)")
    }
}

// MARK: - Store → SwiftUI dialog bridge
// Verifies the helper used by DockPanelView to mirror store-driven
// dialog openings into the yamlDialogState binding (open_dialog
// effect path — used by open_artboard_options, which Cancel- or
// X-button dismissal then clears via onDismiss calling
// store.closeDialog).

@Test func yamlDialogStateFromStoreReturnsNilWhenClosed() {
    let store = StateStore()
    #expect(yamlDialogStateFromStore(store) == nil)
}

@Test func yamlDialogStateFromStoreMirrorsOpenDialog() {
    let store = StateStore()
    store.initDialog(
        "artboard_options",
        defaults: ["name": "Cover", "width": 612],
        params: ["artboard_id": "aaa00001"]
    )
    guard let state = yamlDialogStateFromStore(store) else {
        Issue.record("Expected dialog state, got nil")
        return
    }
    #expect(state.id == "artboard_options")
    #expect(state.state["name"] as? String == "Cover")
    #expect(state.state["width"] as? Int == 612)
    #expect(state.params["artboard_id"] as? String == "aaa00001")
}

@Test func yamlDialogStateFromStoreAfterCloseReturnsNil() {
    let store = StateStore()
    store.initDialog("artboard_options", defaults: [:])
    #expect(yamlDialogStateFromStore(store) != nil)
    store.closeDialog()
    #expect(yamlDialogStateFromStore(store) == nil)
}

@Test func openArtboardOptionsActionLeavesStoreDialogOpen() {
    // Integration check: the YAML action → open_dialog effect path
    // transitions the store from no-dialog to "artboard_options".
    // The DockPanelView bridge reads this transition to show the
    // overlay. (The dialog-body button dispatch inside the overlay
    // is a separate gap; tested here only up to the store state.)
    let ab = Artboard.defaultWithId("aaa00001").with(
        x: 0, y: 0, width: 612, height: 792
    )
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: [ab]
    ))
    #expect(model.stateStore.getDialogId() == nil)
    LayersPanel.dispatchYamlAction(
        "open_artboard_options",
        model: model,
        params: ["artboard_id": "aaa00001"]
    )
    #expect(model.stateStore.getDialogId() == "artboard_options")
    // And the bridge helper yields a visible dialog state.
    let state = yamlDialogStateFromStore(model.stateStore)
    #expect(state?.id == "artboard_options")
    #expect(state?.params["artboard_id"] as? String == "aaa00001")
}
