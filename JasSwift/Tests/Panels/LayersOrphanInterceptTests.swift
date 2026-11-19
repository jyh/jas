import Testing
import Foundation
@testable import JasLib

// STATUS-jas row 141 part 2b. Deleting the Layers panel selection can orphan
// live instances, so the delete is gated by `orphanedReferences(doc, paths)`
// over the PANEL selection (delete_layer_orphan_confirm.yaml). The web keeps
// that gate in its action dispatch (`renderer.rs`, "delete_layer_selection"),
// so every route that reaches the action meets it. Swift kept it only in the
// native tree view, so the panel door's dispatch deleted unconditionally.

private func model(selecting path: [Int]) -> Model {
    let a = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, id: "a"))
    let r1 = Element.live(.reference(ReferenceElem(target: ElementRef("a"), name: nil, id: "r1")))
    let doc = Document(layers: [Layer(name: "L0", children: [a]), Layer(name: "L1", children: [r1])],
                       selectedLayer: 0, selection: [], artboards: [])
    let m = Model(document: doc)
    if let ws = WorkspaceData.load(), let panels = ws.panels() {
        for pid in panels.keys.sorted() { m.stateStore.initPanel(pid, defaults: ws.panelStateDefaults(pid)) }
    }
    m.stateStore.setActivePanel("layers_panel_content")
    m.stateStore.setPanel("layers_panel_content", "layers_panel_selection", [["__path__": path] as [String: Any]])
    return m
}

private func dispatchDelete(_ m: Model) {
    let ws = WorkspaceData.load()!
    let ctx = buildPanelBodyContext(ws: ws, model: m, contentId: "layers_panel_content", opacityPanel: OpacityPanelState())
    dispatchPanelAction("delete_layer_selection", params: [:], actions: ws.actions(), ctx: ctx,
                        store: m.stateStore, model: m, onDialogOpened: nil)
}

@Test func aPanelDeleteThatWouldOrphanAnInstanceOpensTheConfirmInstead() {
    let m = model(selecting: [0, 0])
    #expect(DependencyIndex.orphanedReferences(m.document, [[0, 0]]) == ["r1"], "positive control: r1 would be orphaned")
    dispatchDelete(m)
    #expect(m.document.layers[0].children.count == 1, "nothing was deleted")
    #expect(m.stateStore.getDialogId() == "delete_layer_orphan_confirm")
    #expect((m.stateStore.getDialogParams()?["count"] as? NSNumber)?.intValue == 1,
            "\(String(describing: m.stateStore.getDialogParams()))")
}

@Test func aPanelDeleteThatOrphansNothingDeletesInline() {
    // CONTROL: deleting the reference itself orphans nothing.
    let m = model(selecting: [1, 0])
    dispatchDelete(m)
    #expect(m.document.layers[1].children.isEmpty, "deleted inline")
    #expect(m.stateStore.getDialogId() == nil)
}
