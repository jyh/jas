import Testing
import Foundation
@testable import JasLib

// MARK: - buildActiveDocumentView

@Test func activeDocumentNilModelYieldsNoSelectionAndEmptyLayers() {
    let view = buildActiveDocumentView(model: nil)
    #expect(view["has_selection"] as? Bool == false)
    #expect(view["selection_count"] as? Int == 0)
    let selection = view["element_selection"] as? [Any]
    #expect(selection?.isEmpty == true)
    let topLevel = view["top_level_layers"] as? [Any]
    #expect(topLevel?.isEmpty == true)
    #expect(view["next_layer_name"] as? String == "Layer 1")
    #expect(view["new_layer_insert_index"] as? Int == 0)
    #expect(view["layers_panel_selection_count"] as? Int == 0)
}

@Test func activeDocumentEmptySelectionYieldsNoSelection() {
    let model = Model(document: Document(layers: [Layer(children: [])]))
    let view = buildActiveDocumentView(model: model)
    #expect(view["has_selection"] as? Bool == false)
    #expect(view["selection_count"] as? Int == 0)
    let selection = view["element_selection"] as? [Any]
    #expect(selection?.isEmpty == true)
}

@Test func activeDocumentSelectionCountMatchesSelectionLength() {
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        selection: [
            ElementSelection.all([0]),
            ElementSelection.all([0, 1]),
            ElementSelection.all([0, 2]),
        ]
    ))
    let view = buildActiveDocumentView(model: model)
    #expect(view["has_selection"] as? Bool == true)
    #expect(view["selection_count"] as? Int == 3)
}

@Test func activeDocumentElementSelectionContainsPathMarkersInSortedOrder() {
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        selection: [
            ElementSelection.all([0, 2]),
            ElementSelection.all([0]),
        ]
    ))
    let view = buildActiveDocumentView(model: model)
    let selection = view["element_selection"] as? [[String: Any]]
    #expect(selection?.count == 2)
    // Sorted lexicographically: [0] before [0, 2].
    let first = selection?[0]["__path__"] as? [Int]
    let second = selection?[1]["__path__"] as? [Int]
    #expect(first == [0])
    #expect(second == [0, 2])
}

@Test func activeDocumentSelectedConceptNullWithoutGenerated() {
    // No selection -> selected_concept is null. Concepts panel Slice 2 (A).
    let model = Model(document: Document(layers: [Layer(children: [])]))
    let view = buildActiveDocumentView(model: model)
    #expect(view["selected_concept"] is NSNull)
}

@Test func activeDocumentSelectedConceptPresentForSingleGenerated() {
    // With exactly one Generated instance selected, selected_concept is the
    // concept's param schema merged with the instance's current values.
    // Mirrors Rust active_document_view_selected_concept_present_for_single_generated.
    let doc = Document(layers: [Layer(name: "Layer", children: [])], symbols: [])
    let ctrl = Controller(model: Model(document: doc))
    ctrl.placeConceptInstance(
        conceptId: "regular_polygon", params: ["sides": 6, "radius": 50], elemId: "g1")
    let view = buildActiveDocumentView(model: ctrl.model)
    let sc = view["selected_concept"] as? [String: Any]
    #expect(sc?["concept_id"] as? String == "regular_polygon")
    let plist = sc?["params"] as? [[String: Any]]
    let sides = plist?.first { $0["name"] as? String == "sides" }
    // The instance's current value (6) is carried on the schema entry.
    #expect((sides?["value"] as? Int) == 6)
    // operations (CONCEPTS.md §9): the concept's named edit verbs, so the panel
    // can render a button per operation.
    let ops = sc?["operations"] as? [[String: Any]]
    let ids = ops?.compactMap { $0["id"] as? String } ?? []
    #expect(ids.contains("add_side") && ids.contains("remove_side"),
            "selected_concept.operations lists the concept's verbs: \(ids)")
}

@Test func activeDocumentLayersRollupsPopulatedFromModel() {
    let layerA = Layer(name: "A", children: [])
    let layerB = Layer(name: "B", children: [])
    let model = Model(document: Document(layers: [layerA, layerB]))
    let view = buildActiveDocumentView(model: model)
    let topLevel = view["top_level_layers"] as? [[String: Any]]
    #expect(topLevel?.count == 2)
    #expect(topLevel?[0]["name"] as? String == "A")
    #expect(topLevel?[1]["name"] as? String == "B")
    // Layer names "A" and "B" don't collide with "Layer N", so next is "Layer 1".
    #expect(view["next_layer_name"] as? String == "Layer 1")
}

@Test func activeDocumentNextLayerNameSkipsExistingNames() {
    let model = Model(document: Document(layers: [
        Layer(name: "Layer 1", children: []),
        Layer(name: "Layer 2", children: []),
    ]))
    let view = buildActiveDocumentView(model: model)
    #expect(view["next_layer_name"] as? String == "Layer 3")
}

@Test func activeDocumentLayersPanelSelectionCountReflectsArgument() {
    let model = Model(document: Document(layers: [Layer(children: [])]))
    let view = buildActiveDocumentView(
        model: model,
        layersPanelSelection: [[0], [0, 2]]
    )
    #expect(view["layers_panel_selection_count"] as? Int == 2)
}

@Test func activeDocumentNewLayerInsertIndexAboveSelectedTopLevel() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: []),
        Layer(name: "B", children: []),
        Layer(name: "C", children: []),
    ]))
    // Selected top-level index 1 → insert at 2 (one above)
    let view = buildActiveDocumentView(
        model: model,
        layersPanelSelection: [[1]]
    )
    #expect(view["new_layer_insert_index"] as? Int == 2)
}
