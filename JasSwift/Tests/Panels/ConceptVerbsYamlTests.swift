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

// Object > Promote to Concept runs its YAML (`doc.promote_to_concept`): the
// selected square (the fitter corpus's `[4, 10, 100, 20, 0]` case) becomes a
// Generated regular_polygon at translate(100, 20), ONE undo; an oblong, which
// no fitter matches, changes nothing.
@Test func promoteToConceptRunsItsYamlFromThePanelMenu() {
    func model(_ pts: [(Double, Double)]) -> Model {
        let m = Model()
        m.setDocumentForTest(Document(layers: [Layer(children: [.polygon(Polygon(points: pts))])],
                                      selectedLayer: 0, selection: [ElementSelection.all([0, 0])]))
        return m
    }
    var layout = WorkspaceLayout.defaultLayout()
    let addr = PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0)
    let oblong = model([(0, 0), (20, 0), (20, 10), (0, 10)])
    let before = oblong.document
    ConceptsPanel.menuDispatch("promote_to_concept", addr: addr, layout: &layout, model: oblong)
    #expect(oblong.document == before, "no fitter matches an oblong: nothing")

    let square = model([(110, 20), (100, 30), (90, 20), (100, 10)])
    let squareBefore = square.document
    ConceptsPanel.menuDispatch("promote_to_concept", addr: addr, layout: &layout, model: square)
    guard case .live(.generated(let g)) = square.document.layers[0].children[0] else {
        Issue.record("not promoted"); return
    }
    #expect(g.conceptId == "regular_polygon")
    #expect((g.params["sides"] as? NSNumber)?.doubleValue == 4 && (g.params["radius"] as? NSNumber)?.doubleValue == 10)
    #expect(g.transform?.e == 100 && g.transform?.f == 20)
    square.undo()
    #expect(square.document.layers == squareBefore.layers, "ONE undo")
}
