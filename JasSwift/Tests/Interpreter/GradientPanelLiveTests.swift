import Testing
@testable import JasLib

// MARK: - Selection → Gradient panel
//
// The Gradient panel's fields describe the SELECTION's active attribute,
// as `gradient_host::live_values` gives them to the engine and the Rust
// dock. Until this the panel drew gradient.yaml's black→white linear
// default over a selected blue radial (flask STATUS 495). Nothing selected,
// or a mixed selection, contributes nothing, so the stored panel stands.

private func gradientModel(_ rects: [Element], selected: [ElementPath]) -> Model {
    let layer = Layer(children: rects)
    let selection: Selection = selected.map { ElementSelection.all($0) }
    return Model(document: Document(layers: [layer], selectedLayer: 0,
                                    selection: selection))
}

private let blueRadial = Gradient(type: .radial, stops: [
    GradientStop(color: "#0000ff", location: 0),
    GradientStop(color: "#ffffff", location: 100),
])

private func filled(_ g: Gradient?, _ c: Color = Color(r: 0, g: 0, b: 1)) -> Element {
    .rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: Fill(color: c), fillGradient: g))
}

@Test func gradientPanelReadsTheSelectedGradient() {
    let o = gradientPanelLiveOverrides(model: gradientModel([filled(blueRadial)], selected: [[0, 0]]))
    #expect(o.count == 7)
    #expect((o["type"] as? String) == "radial")
    #expect((o["angle"] as? Double) == 0)
    #expect((o["aspect_ratio"] as? Double) == 100)
    #expect((o["method"] as? String) == "classic")
    #expect((o["dither"] as? Bool) == false)
    #expect((o["stroke_sub_mode"] as? String) == "within")
    let stops = o["stops"] as? [[String: Any]]
    #expect(stops?.map { $0["color"] as? String } == ["#0000ff", "#ffffff"])
    #expect(stops?.map { $0["location"] as? Double } == [0, 100])
    #expect(stops?.map { $0["opacity"] as? Double } == [100, 100])
    #expect(stops?.map { $0["midpoint_to_next"] as? Double } == [50, 50])
}

@Test func gradientPanelSeedsASolidSelection() {
    let o = gradientPanelLiveOverrides(model: gradientModel([filled(nil, Color(r: 1, g: 0, b: 0))],
                                                            selected: [[0, 0]]))
    #expect((o["type"] as? String) == "linear")
    #expect(((o["stops"] as? [[String: Any]])?.first?["color"] as? String) == "#ff0000")
}

@Test func gradientPanelAddsNothingWithNoSelectionOrAMixedOne() {
    #expect(gradientPanelLiveOverrides(model: gradientModel([filled(blueRadial)], selected: [])).isEmpty)
    let mixed = gradientModel([filled(blueRadial), filled(nil)], selected: [[0, 0], [0, 1]])
    #expect(gradientPanelLiveOverrides(model: mixed).isEmpty)
}
