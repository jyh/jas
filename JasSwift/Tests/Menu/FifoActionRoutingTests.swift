import Testing
import Foundation
@testable import JasLib

// Native-first routing for the test-only `--test-fifo` `action <name>`
// channel (JasSwift port of the Python reference commit eae9c2f9,
// FifoActionRoutingTest in jas/menu/menu_test.py).
//
// WHY: document-mutating menubar / edit / file actions
// (`new_document`, `select_all`, `delete_selection`, ...) are
// NATIVE-INTERCEPTED — their actions.yaml `effects` are deliberate
// `log` / `if` stubs, and the real behavior lives in native handlers
// (JasCommands' private menu router + keyboard-only natives). The FIFO
// `action` verb used to route through the GENERIC panel dispatcher
// (`LayersPanel.dispatchYamlAction`), which runs only those `effects`,
// so `action select_all` / `delete_selection` logged-and-no-op'd while a
// real menu click / keystroke worked. These pin the live-GUI contract:
// a FIFO `action select_all` selects all, `delete_selection` deletes —
// while a genuine panel / generic action still falls through to the
// generic dispatcher.

/// Helper: extract the set of paths from a Selection.
private func fifoSelPaths(_ selection: Selection) -> Set<ElementPath> {
    Set(selection.map(\.path))
}

/// Model with two sibling rects on one layer; `selected` toggles whether
/// they start selected (mirrors Python `_add_model`).
private func fifoTwoRectModel(selected: Bool) -> Model {
    let r1 = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let r2 = Element.rect(Rect(x: 20, y: 20, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [r1, r2])
    let sel: Selection = selected
        ? [ElementSelection.all([0, 0]), ElementSelection.all([0, 1])]
        : []
    let doc = Document(layers: [layer], selection: sel)
    return Model(document: doc)
}

@Test func fifoSelectAllSelectsThroughItsYaml() {
    let model = fifoTwoRectModel(selected: false)
    #expect(model.document.selection.isEmpty)
    FifoActionRouting.dispatch("select_all", model: model)
    // The default fall-through ran its YAML (`doc.op: {op: select_all}`) ->
    // both selected.
    #expect(fifoSelPaths(model.document.selection) == Set([[0, 0], [0, 1]]))
}

@Test func fifoDeleteSelectionRemovesSelectedViaNativeHandler() {
    let model = fifoTwoRectModel(selected: true)
    #expect(model.document.layers[0].children.count == 2)
    FifoActionRouting.dispatch("delete_selection", model: model)
    // Native delete (shared opApply delete_selection) ran -> both gone.
    #expect(model.document.layers[0].children.isEmpty)
}

@Test func fifoUnknownActionFallsThroughToPanelDispatcher() {
    let model = fifoTwoRectModel(selected: false)
    var calls: [(String, [String: Any])] = []
    // Inject a spy for the generic-dispatcher fall-through (the Swift
    // analog of Python monkeypatching dock_panel._dispatch_yaml_action).
    FifoActionRouting.dispatch(
        "some_panel_action", model: model, params: ["k": 1],
        knows: { _ in true },
        fallthrough: { name, _, params in calls.append((name, params)) })
    // Not a native action -> routed to the generic panel dispatcher.
    #expect(calls.count == 1)
    #expect(calls.first?.0 == "some_panel_action")
    #expect((calls.first?.1["k"] as? Int) == 1)
}

// ── Row 217: a FIFO `action` publishes its panel-state write ───────────
// The dock's panel bodies redraw on `model.panelStateVersion`
// (`PanelBodyObserver`); `StateStore` publishes nothing. Every person's
// route that runs `dispatchYamlAction` bumps the version after it (the
// panel menu, the Layers keys, the eye button); the FIFO `action` did not,
// so on the Mac `action toggle_snap_to_glyph_visible` wrote the store and
// the Character panel kept drawing the old section until a tab switch
// (measured 11-22 at a78197a4: shown -> shown, then hidden after the
// switch). A harness that shot after the action read a stale view.

@Test func fifoActionPublishesAPanelStateChangeAfterItsWrite() {
    let model = fifoTwoRectModel(selected: false)
    let before = model.panelStateVersion
    var versionDuringWrite: Int?
    FifoActionRouting.dispatch(
        "some_panel_action", model: model,
        knows: { _ in true },
        fallthrough: { _, m, _ in versionDuringWrite = m.panelStateVersion })
    // The bump comes AFTER the write: a bump before it would announce the
    // old state, and the view would read it before the write landed.
    #expect(versionDuringWrite == before)
    #expect(model.panelStateVersion != before)
}

@Test func fifoSnapToGlyphToggleWritesTheCharacterScopeBothWaysAndPublishesEach() {
    let model = fifoTwoRectModel(selected: false)
    let store = model.stateStore
    let pid = "character_panel_content"
    store.initPanel(pid, defaults: WorkspaceData.load()?.panelStateDefaults(pid) ?? [:])
    // The declared default is shown (character.yaml `snap_to_glyph_visible`).
    #expect(store.getPanel(pid, "snap_to_glyph_visible") as? Bool == true)
    let v0 = model.panelStateVersion
    FifoActionRouting.dispatch("toggle_snap_to_glyph_visible", model: model)
    #expect(store.getPanel(pid, "snap_to_glyph_visible") as? Bool == false)
    let v1 = model.panelStateVersion
    #expect(v1 != v0)
    // Both directions: a toggle is a radio of two, and the forward one is
    // the direction a test naturally drives.
    FifoActionRouting.dispatch("toggle_snap_to_glyph_visible", model: model)
    #expect(store.getPanel(pid, "snap_to_glyph_visible") as? Bool == true)
    #expect(model.panelStateVersion != v1)
}

// ── Row 226: a FIFO `action` naming no workspace action is refused by name ──
// `dispatchYamlAction` returns silently when the name is not in the workspace,
// so a harness typo (`toggle_snap_to_glyf_visible`, measured live 11-23) did
// nothing and logged nothing but its own echo: a script reading the next shot
// would see "the toggle did nothing", which reads like an app defect.

@Test func fifoActionRefusesAnUnknownActionByNameAndDispatchesNothing() {
    let model = fifoTwoRectModel(selected: false)
    var calls = 0
    let refusal = FifoActionRouting.dispatch(
        "toggle_snap_to_glyf_visible", model: model,
        fallthrough: { _, _, _ in calls += 1 })
    #expect(calls == 0)
    #expect(refusal?.contains("toggle_snap_to_glyf_visible") == true, "\(refusal ?? "nil")")
    #expect(refusal?.contains("REFUSED") == true, "\(refusal ?? "nil")")
}

@Test func fifoActionDispatchesAKnownWorkspaceActionWithNoRefusal() {
    // The control: the same door with the real spelling dispatches.
    let model = fifoTwoRectModel(selected: false)
    var calls = 0
    let refusal = FifoActionRouting.dispatch(
        "toggle_snap_to_glyph_visible", model: model,
        fallthrough: { _, _, _ in calls += 1 })
    #expect(refusal == nil)
    #expect(calls == 1)
}
