import Testing
@testable import JasLib

// MARK: - Selection → Stroke panel weight (decision-5a)
//
// The Stroke panel's Weight field must show the SELECTED element's
// stroke.width — its baked / effective width after the scale counter-
// scale work — not the YAML default. `strokePanelLiveOverrides`
// resolves the FIRST selected element's stroke width, falling back to
// the model default (then 1.0). Mirrors `colorPanelLiveOverrides` and
// the Python `sync_stroke_panel_from_selection`.

private func strokeModel(_ rects: [Element], selected: [ElementPath]) -> Model {
    let layer = Layer(children: rects)
    let selection: Selection = Set(selected.map { ElementSelection.all($0) })
    return Model(document: Document(layers: [layer], selectedLayer: 0,
                                    selection: selection))
}

private func stroked(_ width: Double) -> Element {
    .rect(Rect(x: 0, y: 0, width: 10, height: 10,
               stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: width)))
}

@Test func strokeWeightFromSelectedElement() {
    // A scaled element baked its stroke to 2.5pt — the panel must show it.
    let model = strokeModel([stroked(2.5)], selected: [[0, 0]])
    let o = strokePanelLiveOverrides(model: model)
    #expect((o["weight"] as? Double) == 2.5)
}

@Test func strokeWeightNoSelectionUsesDefault() {
    let model = strokeModel([stroked(2.5)], selected: [])
    let o = strokePanelLiveOverrides(model: model)
    #expect((o["weight"] as? Double) == (model.defaultStroke?.width ?? 1.0))
}

@Test func strokeWeightSelectedWithoutStrokeUsesDefault() {
    // Rect has no stroke — fall back to the model default.
    let model = strokeModel([.rect(Rect(x: 0, y: 0, width: 10, height: 10))],
                            selected: [[0, 0]])
    let o = strokePanelLiveOverrides(model: model)
    #expect((o["weight"] as? Double) == (model.defaultStroke?.width ?? 1.0))
}
