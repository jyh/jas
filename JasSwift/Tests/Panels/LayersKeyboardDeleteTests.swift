import Testing
import Foundation
@testable import JasLib

// STATUS-jas row 141 (the flagged second gate). The Mac tree's keyboard
// Delete/Backspace kept its own NATIVE orphan confirm because it dispatched
// past the panel dispatch, where part 2b put the one gate. It now runs
// through `dispatchPanelAction` (`LayersPanel.keyboardDelete`), so every
// Layers delete meets the same gate and the same yaml confirm.

private func model(selecting paths: [[Int]]) -> Model {
    let a = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, id: "a"))
    let b = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, id: "b"))
    let r1 = Element.live(.reference(ReferenceElem(target: ElementRef("a"), name: nil, id: "r1")))
    let doc = Document(layers: [Layer(name: "L0", children: [a, b]), Layer(name: "L1", children: [r1])],
                       selectedLayer: 0, selection: [], artboards: [])
    let m = Model(document: doc)
    if let ws = WorkspaceData.load(), let panels = ws.panels() {
        for pid in panels.keys.sorted() { m.stateStore.initPanel(pid, defaults: ws.panelStateDefaults(pid)) }
    }
    m.stateStore.setActivePanel("layers_panel_content")
    setLayersPanelSelection(model: m, Set(paths))
    return m
}

@Test func aKeyboardDeleteThatWouldOrphanAnInstanceOpensTheYamlConfirm() {
    let m = model(selecting: [[0, 0]])
    var opened = false
    LayersPanel.keyboardDelete(model: m, onDialogOpened: { opened = true })
    #expect(m.document.layers[0].children.count == 2, "nothing was deleted")
    #expect(m.stateStore.getDialogId() == "delete_layer_orphan_confirm")
    #expect(opened)
}

@Test func aKeyboardDeleteThatOrphansNothingDeletesInline() {
    let m = model(selecting: [[0, 1]])
    LayersPanel.keyboardDelete(model: m, onDialogOpened: nil)
    #expect(m.document.layers[0].children.count == 1, "deleted inline")
    #expect(m.stateStore.getDialogId() == nil)
}

@Test func aKeyboardDeleteOfEveryTopLevelLayerDoesNothing() {
    // "A document always has at least one layer" (layers.yaml, Empty State).
    let m = model(selecting: [[0], [1]])
    LayersPanel.keyboardDelete(model: m, onDialogOpened: nil)
    #expect(m.document.layers.count == 2)
    #expect(m.stateStore.getDialogId() == nil)
}
