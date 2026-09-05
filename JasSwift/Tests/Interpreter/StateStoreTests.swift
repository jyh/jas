import Testing
@testable import JasLib

// MARK: - Global state

@Test func getSetGlobal() {
    let store = StateStore()
    store.set("x", 5)
    #expect(store.get("x") as? Int == 5)
}

@Test func getMissingReturnsNil() {
    let store = StateStore()
    #expect(store.get("missing") == nil)
}

@Test func initFromDefaults() {
    let store = StateStore(defaults: ["x": 10, "y": "hello"])
    #expect(store.get("x") as? Int == 10)
    #expect(store.get("y") as? String == "hello")
}

@Test func getAll() {
    let store = StateStore(defaults: ["a": 1, "b": 2])
    let all = store.getAll()
    #expect(all["a"] as? Int == 1)
    #expect(all["b"] as? Int == 2)
}

// MARK: - Panel state

@Test func initPanel() {
    let store = StateStore()
    store.initPanel("color", defaults: ["mode": "hsb", "h": 0])
    #expect(store.getPanel("color", "mode") as? String == "hsb")
    #expect(store.getPanel("color", "h") as? Int == 0)
}

@Test func setPanel() {
    let store = StateStore()
    store.initPanel("color", defaults: ["mode": "hsb"])
    store.setPanel("color", "mode", "rgb")
    #expect(store.getPanel("color", "mode") as? String == "rgb")
}

@Test func panelScoping() {
    let store = StateStore()
    store.initPanel("color", defaults: ["mode": "hsb"])
    store.initPanel("swatches", defaults: ["mode": "grid"])
    #expect(store.getPanel("color", "mode") as? String == "hsb")
    #expect(store.getPanel("swatches", "mode") as? String == "grid")
}

@Test func activePanelState() {
    let store = StateStore()
    store.initPanel("color", defaults: ["mode": "hsb"])
    store.setActivePanel("color")
    let state = store.getActivePanelState()
    #expect(state["mode"] as? String == "hsb")
}

@Test func destroyPanel() {
    let store = StateStore()
    store.initPanel("color", defaults: ["mode": "hsb"])
    store.destroyPanel("color")
    #expect(store.getPanel("color", "mode") == nil)
}

// MARK: - Dialog state

@Test func initDialog() {
    let store = StateStore()
    store.initDialog("color_picker",
                     defaults: ["h": 0, "color": "#ffffff"],
                     params: ["target": "fill"])
    #expect(store.getDialogId() == "color_picker")
    #expect(store.getDialog("h") as? Int == 0)
    #expect(store.getDialog("color") as? String == "#ffffff")
    #expect(store.getDialogParams()?["target"] as? String == "fill")
}

@Test func getSetDialog() {
    let store = StateStore()
    store.initDialog("test", defaults: ["name": ""])
    store.setDialog("name", "hello")
    #expect(store.getDialog("name") as? String == "hello")
}

@Test func getDialogNoDialogReturnsNil() {
    let store = StateStore()
    #expect(store.getDialog("anything") == nil)
    #expect(store.getDialogId() == nil)
    #expect(store.getDialogParams() == nil)
}

@Test func closeDialog() {
    let store = StateStore()
    store.initDialog("test", defaults: ["x": 1], params: ["p": "v"])
    store.closeDialog()
    #expect(store.getDialogId() == nil)
    #expect(store.getDialog("x") == nil)
    #expect(store.getDialogParams() == nil)
    #expect(store.getDialogState().isEmpty)
}

@Test func dialogStateReturnsCopy() {
    let store = StateStore()
    store.initDialog("test", defaults: ["a": 1, "b": 2])
    var state = store.getDialogState()
    state["a"] = 999
    #expect(store.getDialog("a") as? Int == 1)
}

@Test func initDialogReplacesPrevious() {
    let store = StateStore()
    store.initDialog("first", defaults: ["x": 1])
    store.initDialog("second", defaults: ["y": 2])
    #expect(store.getDialogId() == "second")
    #expect(store.getDialog("x") == nil)
    #expect(store.getDialog("y") as? Int == 2)
}

// MARK: - Dialog preview snapshot/restore (Phase 0)
//
// captureDialogSnapshot copies the current value of every state key
// referenced by a dialog's preview_targets. Phase 0 supports only
// top-level state keys; deep paths are silently skipped and will be
// added with their first real consumer in Phase 8/9.

@Test func dialogSnapshotCaptureAndGet() {
    let store = StateStore(defaults: ["left_indent": 12, "right_indent": 0])
    store.captureDialogSnapshot([
        "dlg_left": "left_indent",
        "dlg_right": "right_indent",
    ])
    let snap = store.getDialogSnapshot()
    #expect(snap?["left_indent"] as? Int == 12)
    #expect(snap?["right_indent"] as? Int == 0)
    #expect(store.hasDialogSnapshot())
}

@Test func dialogSnapshotClearDropsIt() {
    let store = StateStore(defaults: ["x": 1])
    store.captureDialogSnapshot(["k": "x"])
    #expect(store.hasDialogSnapshot())
    store.clearDialogSnapshot()
    #expect(!store.hasDialogSnapshot())
    #expect(store.getDialogSnapshot() == nil)
}

@Test func dialogSnapshotSkipsDeepPathsForPhase0() {
    let store = StateStore(defaults: ["flat": 1])
    store.captureDialogSnapshot([
        "a": "flat",
        "b": "selection.deep.path",
    ])
    let snap = store.getDialogSnapshot()
    #expect(snap?["flat"] != nil)
    #expect(snap?["selection.deep.path"] == nil)
}

// MARK: - Eval context

@Test func evalContextBasic() {
    let store = StateStore(defaults: ["fill_color": "#ff0000"])
    store.initPanel("color", defaults: ["mode": "hsb"])
    store.setActivePanel("color")
    let ctx = store.evalContext()
    let stateDict = ctx["state"] as? [String: Any]
    let panelDict = ctx["panel"] as? [String: Any]
    #expect(stateDict?["fill_color"] as? String == "#ff0000")
    #expect(panelDict?["mode"] as? String == "hsb")
}

@Test func evalContextIncludesDialog() {
    let store = StateStore(defaults: ["fill_color": "#ff0000"])
    store.initDialog("test", defaults: ["h": 180, "s": 50])
    let ctx = store.evalContext()
    let dialogDict = ctx["dialog"] as? [String: Any]
    #expect(dialogDict?["h"] as? Int == 180)
    #expect(dialogDict?["s"] as? Int == 50)
}

@Test func evalContextIncludesDialogParams() {
    let store = StateStore()
    store.initDialog("test", defaults: ["x": 1], params: ["target": "fill"])
    let ctx = store.evalContext()
    let paramDict = ctx["param"] as? [String: Any]
    #expect(paramDict?["target"] as? String == "fill")
}

@Test func evalContextExtraOverridesDialogParams() {
    let store = StateStore()
    store.initDialog("test", defaults: ["x": 1], params: ["target": "fill"])
    let ctx = store.evalContext(extra: ["param": ["target": "stroke"]])
    let paramDict = ctx["param"] as? [String: Any]
    #expect(paramDict?["target"] as? String == "stroke")
}

@Test func evalContextNoDialogOmitsKey() {
    let store = StateStore(defaults: ["x": 1])
    let ctx = store.evalContext()
    #expect(ctx["dialog"] == nil)
}

@Test func dialogAndPanelCoexist() {
    let store = StateStore()
    store.initPanel("color", defaults: ["mode": "hsb"])
    store.setActivePanel("color")
    store.initDialog("picker", defaults: ["h": 270])
    let ctx = store.evalContext()
    let panelDict = ctx["panel"] as? [String: Any]
    let dialogDict = ctx["dialog"] as? [String: Any]
    #expect(panelDict?["mode"] as? String == "hsb")
    #expect(dialogDict?["h"] as? Int == 270)
}

// MARK: - List push

@Test func listPushToFront() {
    let store = StateStore()
    store.initPanel("color", defaults: ["recent": ["a", "b", "c"]])
    store.listPush("color", "recent", "d")
    let result = store.getPanel("color", "recent") as? [String]
    #expect(result == ["d", "a", "b", "c"])
}

@Test func listPushMaxLength() {
    let store = StateStore()
    store.initPanel("color", defaults: ["recent": ["a", "b", "c"]])
    store.listPush("color", "recent", "d", maxLength: 3)
    let result = store.getPanel("color", "recent") as? [String]
    #expect(result == ["d", "a", "b"])
}

// ── One panel scope per panel, whatever the spelling ─────────────
//
// The YAML names a panel's state scope by its SHORT kind at every effect
// site (`set_panel_state: { panel: brushes, … }`); the bundle keys every
// panel map by the CONTENT id. This store used to canonicalise inside the
// `set_panel_state` effect and nowhere else, so the native artboard verbs
// (writing `"artboards"`) and the YAML's writes (landing in
// `artboards_panel_content`) kept two buckets for one selection. The rule is
// the store's now, at its boundary. Mirrors the reference's
// `test_panel_scope_spelling.py`.

@Test func panelContentIdNormalisesBothSpellings() {
    #expect(StateStore.panelContentId("brushes") == "brushes_panel_content")
    #expect(StateStore.panelContentId("brushes_panel_content") == "brushes_panel_content")
    #expect(StateStore.panelContentId("magic_wand") == "magic_wand_panel_content")
}

@Test func shortAndFullSpellingsAddressOneScope() {
    let store = StateStore()
    store.initPanel("swatches_panel_content", defaults: ["thumbnail_size": "small"])
    store.setPanel("swatches", "thumbnail_size", "large")
    #expect(store.getPanel("swatches_panel_content", "thumbnail_size") as? String == "large")
    #expect(store.getPanel("swatches", "thumbnail_size") as? String == "large")
    #expect(store.hasPanel("swatches"))
    // Initialised SHORT, read by the content id.
    store.initPanel("color", defaults: ["mode": "hsb"])
    #expect(store.getPanel("color_panel_content", "mode") as? String == "hsb")
    // The active panel, spelled short, is the content scope.
    store.setActivePanel("color")
    #expect(store.getActivePanelId() == "color_panel_content")
    #expect(store.getActivePanelState()["mode"] as? String == "hsb")
    // The list verb too.
    store.initPanel("layers_panel_content", defaults: ["isolation_stack": [] as [Any]])
    store.listPush("layers", "isolation_stack", [0])
    #expect((store.getPanel("layers_panel_content", "isolation_stack") as? [Any])?.count == 1)
    store.destroyPanel("color")
    #expect(!store.hasPanel("color_panel_content"))
}

/// THE MEASUREMENT this file was written for: the YAML's `set_panel_state
/// { panel: artboards, key: rearrange_dirty }` (six sites in actions.yaml)
/// and a native verb's `setPanel("artboards", …)` must land in the bucket the
/// artboards panel's own dispatch reads (`getPanelState("artboards")`) AND
/// the one the dock's body context reads (`artboards_panel_content`). Before
/// the store canonicalised, the first assertion held and the second did not.
@Test func yamlWriteAndNativeWriteOnTheArtboardsScopeShareOneBucket() {
    let store = StateStore()
    store.initPanel("artboards_panel_content",
                    defaults: ["rearrange_dirty": false, "artboards_panel_selection": [String]()])
    runEffects(
        [["set_panel_state": ["panel": "artboards", "key": "rearrange_dirty", "value": "true"]]],
        ctx: [:], store: store)
    #expect(store.getPanel("artboards", "rearrange_dirty") as? Bool == true,
            "the YAML's write, read by the native verbs' spelling")
    #expect(store.getPanel("artboards_panel_content", "rearrange_dirty") as? Bool == true,
            "the YAML's write, read by the body's spelling")
    store.setPanel("artboards", "artboards_panel_selection", ["ab-1"])
    #expect(store.getPanelState("artboards_panel_content")["artboards_panel_selection"] as? [String] == ["ab-1"],
            "a native verb's write, read by the body's spelling")
}
