/// Phase 4: selection → gradient panel reads in JasSwift.
/// Mirrors Rust `sync_gradient_panel_*` tests in renderer.rs.

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
        selection: Set([ElementSelection.all([0, 0])])
    )
    return Model(document: doc)
}

@Test func syncGradientPanelUniformWithGradient() {
    let g = sampleGradient()
    let model = modelWithRect(rectWithFillGradient(g))
    let store = model.stateStore
    store.set("fill_on_top", true)
    syncGradientPanelFromSelection(store: store, controller: Controller(model: model))
    #expect(store.get("gradient_type") as? String == "radial")
    #expect((store.get("gradient_angle") as? Double) == 30)
    #expect((store.get("gradient_aspect_ratio") as? Double) == 200)
    #expect(store.get("gradient_method") as? String == "smooth")
    #expect(store.get("gradient_dither") as? Bool == true)
    #expect(store.get("gradient_preview_state") as? Bool == false)
}

@Test func syncGradientPanelSolidSeedsPreview() {
    let model = modelWithRect(rectWithFillGradient(nil))
    let store = model.stateStore
    store.set("fill_on_top", true)
    syncGradientPanelFromSelection(store: store, controller: Controller(model: model))
    #expect(store.get("gradient_preview_state") as? Bool == true)
    // First-stop seed = current solid color (red) per fill-type-coupling.
    #expect(store.get("gradient_seed_first_color") as? String == "#ff0000")
    #expect(store.get("gradient_type") as? String == "linear")
}

@Test func syncGradientPanelEmptySelectionLeavesStoreAlone() {
    let layer = Layer(children: [Element]())
    let doc = Document(layers: [layer], selectedLayer: 0, selection: [])
    let model = Model(document: doc)
    let store = model.stateStore
    // Pre-populate so we can detect a no-op.
    store.set("gradient_type", "radial")
    syncGradientPanelFromSelection(store: store, controller: Controller(model: model))
    #expect(store.get("gradient_type") as? String == "radial")
}
