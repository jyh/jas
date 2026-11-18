/// The Gradient panel's writeback in JasSwift. The read direction is
/// `gradientPanelLiveOverrides` (GradientPanelLiveTests.swift); the
/// store-writing sync it replaced had no caller and was deleted (row 151).

import Foundation
import Testing
@testable import JasLib

private func sampleGradient() -> Gradient {
    Gradient(
        type: .radial,
        angle: 30,
        aspectRatio: 200,
        method: .smooth,
        dither: true,
        strokeSubMode: .within,
        stops: [
            GradientStop(color: "#00ff00", opacity: 100, location: 0,   midpointToNext: 50),
            GradientStop(color: "#0000ff", opacity: 100, location: 100, midpointToNext: 50),
        ]
    )
}

private func rectWithFillGradient(_ g: Gradient?) -> Element {
    .rect(Rect(
        x: 0, y: 0, width: 100, height: 50,
        fill: Fill(color: .rgb(r: 1, g: 0, b: 0, a: 1)),
        fillGradient: g
    ))
}

private func modelWithRect(_ r: Element) -> Model {
    let layer = Layer(children: [r])
    let doc = Document(
        layers: [layer], selectedLayer: 0,
        selection: [ElementSelection.all([0, 0])]
    )
    return Model(document: doc)
}

// MARK: - Phase 5: panel writeback

@Test func applyGradientPanelWritesFillGradient() {
    let model = modelWithRect(rectWithFillGradient(nil))
    let store = model.stateStore
    store.set("fill_on_top", true)
    store.set("gradient_type", "radial")
    store.set("gradient_angle", 90.0)
    store.set("gradient_aspect_ratio", 150.0)
    store.set("gradient_method", "smooth")
    store.set("gradient_dither", true)
    store.set("gradient_stroke_sub_mode", "across")
    // The solid rect shows a seeded preview (the live overrides, the one source
    // the dock and the Gradient menu read since row 147).
    #expect((gradientPanelLiveOverrides(model: model)["preview_state"] as? Bool) == true)
    applyGradientPanelToSelection(store: store, controller: Controller(model: model))
    let elem = model.document.getElement([0, 0])
    let g = elem.fillGradient
    #expect(g != nil)
    #expect(g?.type == .radial)
    #expect(g?.angle == 90)
    #expect(g?.aspectRatio == 150)
    #expect(g?.method == .smooth)
    #expect(g?.dither == true)
    #expect(g?.strokeSubMode == .across)
    // The first edit ends the preview: the rect now holds a gradient.
    #expect((gradientPanelLiveOverrides(model: model)["preview_state"] as? Bool) == false)
}

@Test func theSlidersWholeListKeyWritesTheSelectionsStops() {
    // WIDGET_EVENTS.md §The stops kind: a finished slider gesture sets
    // `gradient_stops`, which the selection takes whole (from the seed here,
    // since the rect is solid). Mirrors renderer.rs's arm of the same name.
    let model = modelWithRect(rectWithFillGradient(nil))
    let store = model.stateStore
    store.set("fill_on_top", true)
    store.set(gradientStopsKey, [
        ["color": "#000000", "opacity": 100, "location": 0, "midpoint_to_next": 50],
        ["color": "#ff0000", "opacity": 75, "location": 25, "midpoint_to_next": 50],
        ["color": "#ffffff", "opacity": 100, "location": 100, "midpoint_to_next": 40]])
    applyGradientPanelToSelection(store: store, controller: Controller(model: model), key: gradientStopsKey)
    let stops = model.document.getElement([0, 0]).fillGradient?.stops ?? []
    #expect(stops.map { [$0.location, $0.opacity, $0.midpointToNext] }
        == [[0, 100, 50], [25, 75, 50], [100, 100, 40]])
    #expect(stops.map(\.color) == ["#000000", "#ff0000", "#ffffff"])
}

@Test func demoteGradientPanelClearsFillGradient() {
    let g = sampleGradient()
    let model = modelWithRect(rectWithFillGradient(g))
    let store = model.stateStore
    store.set("fill_on_top", true)
    // Sanity: fillGradient is set.
    #expect(model.document.getElement([0, 0]).fillGradient == g)
    demoteGradientPanelSelection(store: store, controller: Controller(model: model))
    #expect(model.document.getElement([0, 0]).fillGradient == nil)
    // Underlying solid fill is preserved.
    #expect(model.document.getElement([0, 0]).fill != nil)
}
