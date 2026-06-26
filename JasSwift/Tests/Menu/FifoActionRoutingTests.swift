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

@Test func fifoSelectAllSelectsViaNativeHandler() {
    let model = fifoTwoRectModel(selected: false)
    #expect(model.document.selection.isEmpty)
    FifoActionRouting.dispatch("select_all", model: model)
    // Native Controller.selectAll ran (NOT the log stub) -> both selected.
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
        fallthrough: { name, _, params in calls.append((name, params)) })
    // Not a native action -> routed to the generic panel dispatcher.
    #expect(calls.count == 1)
    #expect(calls.first?.0 == "some_panel_action")
    #expect((calls.first?.1["k"] as? Int) == 1)
}
