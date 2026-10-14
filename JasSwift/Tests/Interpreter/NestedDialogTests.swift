import Foundation
import Testing
@testable import JasLib

// A dialog opened from inside another (the Color Picker from Layer Options or
// Artboard Options) returns to its parent: the reference's
// `test_nested_dialogs.py`, against the SHIPPED workspace. The openers' params
// and the picker's OK effects are read from `workspace.json`, never typed here.

private let nestedWorkspace = WorkspaceData.load()
private let nestedActions = nestedWorkspace?.data["actions"] as? [String: Any] ?? [:]
private let nestedDialogs = nestedWorkspace?.data["dialogs"] as? [String: Any] ?? [:]

/// The first node under `node` (depth first) for which `pred` holds.
private func findNode(_ node: Any, _ pred: ([String: Any]) -> Bool) -> [String: Any]? {
    if let d = node as? [String: Any] {
        if pred(d) { return d }
        for v in d.values { if let hit = findNode(v, pred) { return hit } }
    } else if let a = node as? [Any] {
        for v in a { if let hit = findNode(v, pred) { return hit } }
    }
    return nil
}

/// The params the parent's swatch passes to `open_color_picker`.
private func pickerOpener(_ parent: String) -> [String: Any] {
    let content = (nestedDialogs[parent] as? [String: Any])?["content"] ?? [:]
    let opens: ([String: Any]) -> Bool = { b in b["action"] as? String == "open_color_picker" }
    let node = findNode(content) { n in
        (n["behavior"] as? [Any])?.contains { ($0 as? [String: Any]).map(opens) ?? false } ?? false
    }
    let behavior = (node?["behavior"] as? [Any])?.compactMap { $0 as? [String: Any] }.first(where: opens)
    return behavior?["params"] as? [String: Any] ?? [:]
}

/// The picker's OK button's click effects, as the spec writes them.
private func pickerOkEffects() -> [Any] {
    let content = (nestedDialogs["color_picker"] as? [String: Any])?["content"] ?? [:]
    let ok = findNode(content) { $0["type"] as? String == "button" && $0["label"] as? String == "OK" }
    let click = (ok?["behavior"] as? [Any])?.compactMap { $0 as? [String: Any] }
        .first { $0["event"] as? String == "click" }
    return click?["effects"] as? [Any] ?? []
}

private func dispatch(_ store: StateStore, _ action: String, _ params: [String: Any]) {
    runEffects([["dispatch": ["action": action, "params": params]]], ctx: [:], store: store,
               actions: nestedActions, dialogs: nestedDialogs)
}

@Test func nestedSwatchTargetsItsOwnDialogField() {
    for (parent, field) in [("layer_options", "color"), ("artboard_options", "fill")] {
        let params = pickerOpener(parent)
        #expect(params["target"] as? String == "\"dialog.\(field)\"", "\(parent)")
        #expect(params["color"] as? String == "dialog.\(field)", "\(parent)")
    }
}

@Test func okInANestedPickerWritesTheParentFieldAndReturnsToIt() {
    let store = StateStore(defaults: ["stroke_color": "#000000", "fill_color": "#ffffff"])
    dispatch(store, "open_layer_options", ["mode": "\"create\""])
    #expect(store.getDialogId() == "layer_options")
    store.setDialog("name", "Edited")

    dispatch(store, "open_color_picker", pickerOpener("layer_options"))
    #expect(store.getDialogId() == "color_picker")
    #expect(store.getDialog("color") as? String == "#4a90d9", "the picker starts from the parent's colour")
    store.setDialog("color", "#ff0000")

    let ok = pickerOkEffects()
    #expect(!ok.isEmpty, "the picker's OK effects were read")
    runEffects(ok, ctx: [:], store: store, actions: nestedActions, dialogs: nestedDialogs)

    #expect(store.getDialogId() == "layer_options", "OK returns to the parent")
    #expect(store.getDialog("name") as? String == "Edited", "the parent keeps its edits")
    #expect(store.getDialog("color") as? String == "#ff0000", "the picked colour lands in the parent's field")
    #expect(store.get("stroke_color") as? String == "#000000", "the app's stroke is not the target")
    #expect(store.get("fill_color") as? String == "#ffffff")
}

@Test func cancelInANestedPickerReturnsToTheParentUnchanged() {
    let store = StateStore(defaults: ["stroke_color": "#000000"])
    dispatch(store, "open_layer_options", ["mode": "\"create\""])
    let before = store.getDialog("color") as? String
    dispatch(store, "open_color_picker", pickerOpener("layer_options"))
    store.setDialog("color", "#ff0000")

    dispatch(store, "dismiss_dialog", [:])

    #expect(store.getDialogId() == "layer_options")
    #expect(store.getDialog("color") as? String == before)
    #expect(store.get("stroke_color") as? String == "#000000")
}

@Test func closingTheParentAfterTheChildLeavesNoDialog() {
    let store = StateStore()
    dispatch(store, "open_layer_options", ["mode": "\"create\""])
    dispatch(store, "open_color_picker", pickerOpener("layer_options"))
    #expect(store.dialogDepth() == 2)
    dispatch(store, "dismiss_dialog", [:])
    dispatch(store, "dismiss_dialog", [:])
    #expect(store.getDialogId() == nil)
    #expect(store.dialogDepth() == 0)
}
