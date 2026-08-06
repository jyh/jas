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
    let selection: Selection = selected.map { ElementSelection.all($0) }
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

@Test func strokeCapJoinFromSelectedElement() {
    // The panel reflects the selection's cap / join, not just weight.
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                 stroke: Stroke(color: Color(r: 0, g: 0, b: 0),
                                                width: 1, linecap: .round,
                                                linejoin: .bevel)))
    let o = strokePanelLiveOverrides(model: strokeModel([rect], selected: [[0, 0]]))
    #expect((o["cap"] as? String) == "round")
    #expect((o["join"] as? String) == "bevel")
}

// MARK: - CAPREACH: does clicking a cap button reach the selected element?

/// JYH, driving JasSwift 2026-08-05: "In the stroke panel it is round, but it
/// comes up a square. Clicking on a different cap does not do anything."
///
/// The render half is explained (an arrowhead butts the cap for the whole
/// stroke, deliberately, in BOTH ports). This test asks the OTHER half, which
/// the windows seat's diagnosis reported as a Swift-only divergence: does the
/// click actually write `linecap` onto the selected element?
///
/// Driven through the REAL action from `workspace.json` with the production
/// effect map, not by calling the apply directly — the whole question is
/// whether the chain from button to element is connected, so testing any link
/// in isolation would answer a narrower question than the one asked.
@Test func clickingACapButtonReachesTheSelectedElement() {
    let path = Element.path(Path(
        d: [.moveTo(0, 0), .lineTo(50, 0)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 4.0),
        fillRule: .nonzero))
    let doc = Document(layers: [Layer(name: "L0", children: [path])])
    let model = Model(document: doc.replacing(selection: [ElementSelection.all([0, 0])]))

    // Precondition, so a pass cannot be the default value agreeing by luck.
    guard case .path(let before) = model.document.getElement([0, 0]) else {
        Issue.record("[0,0] should be a Path"); return
    }
    #expect(before.stroke?.linecap == .butt, "fixture starts at the default")

    let store = StateStore()
    runYamlActionByName("set_stroke_cap", params: ["cap": "round"], model: model)

    guard case .path(let after) = model.document.getElement([0, 0]) else {
        Issue.record("[0,0] should still be a Path"); return
    }
    #expect(after.stroke?.linecap == .round,
            "the cap button must write linecap onto the SELECTED element; Rust's stroke_panel dispatch calls apply_stroke_panel_to_selection(\"cap\") directly")
    _ = store
}
