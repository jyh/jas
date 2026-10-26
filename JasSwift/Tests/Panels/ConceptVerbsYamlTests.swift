import Foundation
import Testing
@testable import JasLib

// STATUS-jas item 8, class S: the Concepts panel's Place Instance runs
// actions.yaml `place_concept_instance` (`doc.place_concept_instance` with
// `panel.selected_concept`), and a parameter field's commit runs
// `set_concept_param` (`doc.set_concept_param` with `param.name` and
// `param.value`), each ONE undo step.

private let concepts = "concepts_panel_content"

private func emptyModel() -> Model {
    Model(document: Document(layers: [Layer(name: "L", children: [])], selectedLayer: 0, selection: []))
}

private func selectConcept(_ model: Model, _ id: String?) {
    model.stateStore.initPanel(concepts, defaults: [:])
    model.stateStore.setPanel(concepts, "selected_concept", id ?? NSNull())
}

private func points(_ model: Model) -> Double? {
    guard case .live(.generated(let g)) = model.document.layers[0].children.first else { return nil }
    return (g.params["points"] as? NSNumber)?.doubleValue
}

@Test func placeConceptInstanceFromTheMenuAppendsThePanelSelectedConceptWithItsDefaults() {
    let model = emptyModel()
    let before = model.document
    var layout = WorkspaceLayout.defaultLayout()
    let addr = PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0)
    for none in [nil, "no_such_concept"] as [String?] {
        selectConcept(model, none)
        ConceptsPanel.menuDispatch("place_concept_instance", addr: addr, layout: &layout, model: model)
        #expect(model.document == before, "\(String(describing: none)): nothing")
    }
    selectConcept(model, "star")
    ConceptsPanel.menuDispatch("place_concept_instance", addr: addr, layout: &layout, model: model)
    let kids = model.document.layers[0].children
    #expect(kids.count == 1, "the instance is appended")
    guard case .live(.generated(let g)) = kids.first else { Issue.record("not a generated instance"); return }
    #expect(g.conceptId == "star")
    #expect(g.params.keys.sorted() == ["inner", "outer", "points"], "the concept's declared defaults")
    #expect(points(model) == 5)
    #expect(g.id != nil, "its id is minted")
    #expect(model.document.selection.map(\.path) == [[0, 0]], "the instance is selected")
    model.undo()
    #expect(model.document.layers == before.layers, "ONE undo")
}

@Test func placeConceptInstanceFromTheFooterButtonRunsTheYaml() {
    let model = emptyModel()
    selectConcept(model, "star")
    dispatchPanelAction("place_concept_instance", params: [:], actions: nil, ctx: [:],
                        store: model.stateStore, model: model, onDialogOpened: nil)
    #expect(points(model) == 5)
}

@Test func setConceptParamWritesTheOneSelectedGeneratedInstance() {
    let model = emptyModel()
    selectConcept(model, "star")
    LayersPanel.dispatchYamlAction("place_concept_instance", model: model)
    #expect(points(model) == 5, "the control: a placed, selected instance")
    let set = { (v: Any) in
        dispatchPanelAction("set_concept_param", params: ["name": "points", "value": v], actions: nil,
                            ctx: [:], store: model.stateStore, model: model, onDialogOpened: nil)
    }
    set(7)
    #expect(points(model) == 7)
    set("9")
    #expect(points(model) == 9, "a numeric string is its number")
    for bad in ["seven", "inf", "1e999", NSNull()] as [Any] {
        set(bad)
        #expect(points(model) == 9, "\(bad): nothing")
    }
    model.undo()
    #expect(points(model) == 7, "one undo per commit")
    model.setDocumentUnbracketed(Document(layers: model.document.layers, selectedLayer: 0, selection: []),
                                 intent: .testOnly)
    set(11)
    #expect(points(model) == 7, "nothing selected: nothing")
}
