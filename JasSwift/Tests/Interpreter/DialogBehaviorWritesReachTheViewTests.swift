import Testing
import Foundation
@testable import JasLib

// STATUS-jas row 277, measured live on the Mac test box (slot-1125c, app at
// main 918729fd): in Artboard Options the Size preset's pick showed
// "Letter (612 × 792)" and the width stayed 72 after OK; a typed Width
// (the control) applied. The dialog view (YamlDialogView) holds its own
// `dialogState` and re-syncs it from the store only when `onDialogWrite`
// fires, and PanelWidgetEvents fired it for the widget's OWN bound field
// alone. The `change` behavior's writes (`dialog.width`, `dialog.height`)
// reached the store, which the corpus runner reads, and never the view,
// whose context OK's `width: "dialog.width"` resolves against.

private func findNode(_ n: Any?, _ id: String) -> [String: Any]? {
    if let d = n as? [String: Any] {
        if d["id"] as? String == id { return d }
        for v in d.values { if let f = findNode(v, id) { return f } }
    } else if let a = n as? [Any] {
        for v in a { if let f = findNode(v, id) { return f } }
    }
    return nil
}

/// The dialog_actions corpus's own setup (artboard `zs8ap4x3`), read from
/// the repo: `svgToDocument` mints no artboard from a bare SVG.
private func setupSvg() throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent("test_fixtures/svg/paragraph_justified.svg"), encoding: .utf8)
}

@Test func aDialogBehaviorsStoreWritesReachTheDialogView() throws {
    let ws = try #require(WorkspaceData.load())
    let m = Model(document: svgToDocument(try setupSvg()))
    let store = m.stateStore
    let ab = try #require(m.document.artboards.first)
    LayersPanel.dispatchYamlAction("open_artboard_options", model: m, params: ["artboard_id": ab.id])
    #expect(store.getDialogId() == "artboard_options", "the precondition: the dialog is open")
    let spec = try #require(ws.dialog("artboard_options"))
    let node = try #require(findNode(spec["content"], "ao_preset"))
    let ctx = buildDialogEvalContextWithGetters(
        store: store, state: store.getDialogState(),
        params: store.getDialogParams() ?? [:], outer: [:])
    var heard: [String: Any?] = [:]
    let route = PanelWidgetEvents(model: m, panelId: nil, scope: ctx, onDialogWrite: { k, v in
        heard[k] = v
        DialogWidgetActions.write(k, v, store: store)
    })
    // A4, not Letter: this fixture's artboard is already 612 wide, so a Letter
    // pick changes nothing and a control reading 612 after it passes vacuously.
    let num = { (v: Any?) in v as? Double ?? (v as? NSNumber)?.doubleValue }
    #expect(num(store.getDialogState()["width"]) != 595.28, "precondition: the pick must change the width")
    _ = route.commit(node, text: "a4")
    let w = store.getDialogState()["width"]
    #expect(num(w) == 595.28,
            "positive control: the behavior wrote the store (\(String(describing: w)))")
    #expect(heard.keys.contains("preset"), "the bound field is heard: \(heard.keys.sorted())")
    #expect(heard.keys.contains("width") && heard.keys.contains("height"),
            "the behavior's writes reach the dialog view: heard \(heard.keys.sorted())")
}
