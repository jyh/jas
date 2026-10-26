import Foundation
import Testing
@testable import JasLib

// STATUS-jas item 8, class S: the Symbols panel's Place Instance runs
// actions.yaml `place_instance` (`doc.place_instance` with
// `panel.selected_symbol`), from the panel menu and the footer button alike:
// a minted reference to that master, appended and selected, ONE undo step.

private func modelWithMaster() -> Model {
    let master = Element.rect(Rect(x: 50, y: 0, width: 10, height: 10, id: "m1"))
    let model = Model(document: Document(
        layers: [Layer(name: "L", children: [.rect(Rect(x: 0, y: 0, width: 10, height: 10))])],
        symbols: [master], selectedLayer: 0, selection: []))
    return model
}

private func selectMaster(_ model: Model, _ id: String?) {
    model.stateStore.initPanel("symbols_panel_content", defaults: [:])
    model.stateStore.setPanel("symbols_panel_content", "selected_symbol", id ?? NSNull())
}

@Test func placeInstanceFromTheYamlAppendsAReferenceToThePanelSelectedMaster() {
    let model = modelWithMaster()
    selectMaster(model, "m1")
    #expect(SymbolsPanel.selectedSymbol(model) == "m1", "the control: the master is panel-selected")
    let before = model.document
    var layout = WorkspaceLayout.defaultLayout()
    SymbolsPanel.dispatch("place_instance", addr: PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0),
                          layout: &layout, model: model)
    let kids = model.document.layers[0].children
    #expect(kids.count == 2, "the instance is appended")
    guard case .live(.reference(let r)) = kids[1] else { Issue.record("not a reference"); return }
    #expect(r.target.id == "m1")
    #expect(r.id != nil && r.id != "m1", "its id is minted")
    #expect(model.document.selection.map(\.path) == [[0, 1]], "the instance is selected")
    model.undo()
    #expect(model.document.layers == before.layers, "ONE undo")
}

@Test func placeInstanceWithNoMasterSelectedChangesNothing() {
    let model = modelWithMaster()
    let before = model.document
    LayersPanel.dispatchYamlAction("place_instance", model: model)
    #expect(model.document == before)
}
