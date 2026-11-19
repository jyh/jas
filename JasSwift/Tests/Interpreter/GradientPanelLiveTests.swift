import Testing
import Foundation
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
    #expect(o.count == 8)
    #expect((o["type"] as? String) == "radial")
    // The selection holds a gradient, so the panel shows it, not a seed.
    #expect((o["preview_state"] as? Bool) == false)
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
    // A seed is a preview: the Gradient menu's three transforms are disabled on
    // it (row 147). Mirrors gradient_host.rs.
    #expect((o["preview_state"] as? Bool) == true)
}

@Test func gradientPanelAddsNothingWithNoSelectionAndOnlyTheFirstStopsWhenMixed() {
    #expect(gradientPanelLiveOverrides(model: gradientModel([filled(blueRadial)], selected: [])).isEmpty)
    // GRADIENT.md §Multi-selection: the slider shows the first element's
    // stops; every other field stands as the store holds it, except that a
    // mixed selection is not a seeded preview. Mirrors gradient_host.rs
    // `live_values_are_empty_with_no_selection_and_only_the_first_stops_when_mixed`.
    let mixed = gradientModel([filled(blueRadial), filled(nil)], selected: [[0, 0], [0, 1]])
    let o = gradientPanelLiveOverrides(model: mixed)
    #expect(Set(o.keys) == ["preview_state", "stops"])
    #expect((o["preview_state"] as? Bool) == false)
    #expect((o["stops"] as? [[String: Any]])?.map { $0["color"] as? String } == blueRadial.stops.map { $0.color })
}

// MARK: - The Gradient menu reads the selection (row 147)
//
// A Gradient panel-menu row runs its YAML in the panel's STORE scope, so
// ``panelDispatchRow`` lays the selection's gradient over that scope first,
// unless the slider's press snapshot is held. A released press leaves NSNull.

private func fillStops(_ m: Model) -> [String] {
    guard case .rect(let r) = m.document.layers[0].children[0] else { return [] }
    return r.fillGradient?.stops.map { "\($0.color)@\(Int($0.location))" } ?? []
}

@Test func gradientMenuReverseReadsTheSelectionAfterAReleasedPress() {
    let m = gradientModel([filled(blueRadial)], selected: [[0, 0]])
    let pid = "gradient_panel_content"
    m.stateStore.initPanel(pid, defaults: WorkspaceData.load()?.panelStateDefaults(pid) ?? [:])
    m.stateStore.setPanel(pid, "stops__press", NSNull())
    panelDispatchRow(.gradient, action: "gradient_reverse", params: [:], model: m)
    // blue@0, white@100 reversed; the store's black→white default would give
    // white@0, black@100.
    #expect(fillStops(m) == ["#ffffff@0", "#0000ff@100"])
}

@Test func gradientMenuLeavesTheStoreStopsWhileAPressIsHeld() {
    let m = gradientModel([filled(blueRadial)], selected: [[0, 0]])
    let pid = "gradient_panel_content"
    m.stateStore.initPanel(pid, defaults: WorkspaceData.load()?.panelStateDefaults(pid) ?? [:])
    let preview: [[String: Any]] = [
        ["color": "#ff0000", "opacity": 100.0, "location": 0.0, "midpoint_to_next": 50.0],
        ["color": "#00ff00", "opacity": 100.0, "location": 100.0, "midpoint_to_next": 50.0],
    ]
    m.stateStore.setPanel(pid, "stops", preview)
    m.stateStore.setPanel(pid, "stops__press", preview)
    panelDispatchRow(.gradient, action: "gradient_reverse", params: [:], model: m)
    // The held preview is what the panel shows, so it is what reverses.
    #expect(fillStops(m) == ["#00ff00@0", "#ff0000@100"])
}

// Row 155: a panel-menu row's transaction carries its action's name, as the
// engine's (`{name: gradient_reverse, ops: []}`). Swift's panel route ran its
// effects outside the journal owner-bracket, so the transaction was anonymous.
@Test func gradientMenuReverseJournalsANamedTransaction() {
    let m = gradientModel([filled(blueRadial)], selected: [[0, 0]])
    let pid = "gradient_panel_content"
    m.stateStore.initPanel(pid, defaults: WorkspaceData.load()?.panelStateDefaults(pid) ?? [:])
    let j0 = m.journal.count
    panelDispatchRow(.gradient, action: "gradient_reverse", params: [:], model: m)
    let new = Array(m.journal.dropFirst(j0))
    #expect(new.count == 1, "one transaction: \(new.map { $0.name ?? "nil" })")
    #expect(new.first?.name == "gradient_reverse")
    #expect(new.first?.ops.isEmpty == true, "a host-key edit journals no ops (OP_LOG.md §14)")
    m.undo()
    #expect(fillStops(m) == ["#0000ff@0", "#ffffff@100"], "one undo restores the gradient")
}

// ...and the name does not outlive its batch: an edit made afterwards, outside
// any action, journals anonymously as before.
@Test func theBatchNameDoesNotOutliveItsAction() {
    let m = gradientModel([filled(blueRadial)], selected: [[0, 0]])
    let pid = "gradient_panel_content"
    m.stateStore.initPanel(pid, defaults: WorkspaceData.load()?.panelStateDefaults(pid) ?? [:])
    panelDispatchRow(.gradient, action: "gradient_reverse", params: [:], model: m)
    #expect(m.batchActionName == nil)
    let j0 = m.journal.count
    m.editDocument(m.document.replaceElement([0, 0], with: filled(nil)))
    #expect(m.journal.count == j0 + 1)
    #expect(m.journal.last?.name == nil, "a standalone edit stays anonymous: \(m.journal.last?.name ?? "nil")")
}
