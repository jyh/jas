import Testing
import Foundation
@testable import JasLib

// MARK: - COLORTIERS: the Color panel's SLIDERS read the same tiers as its swatch
//
// ``colorPanelLiveOverrides`` is the THIRD reader of the active-paint fact (the
// panel-render `state` scope and the action-dispatch scope are the other two),
// and it re-derived the tiers itself: `selection ?? model.defaultFill`, with no
// app tier. While the app tier was reseeded per canvas that was unreachable —
// a fresh Model's `defaultFill` was `nil` only before the first colour write.
// Once the tier moved ABOVE the canvases (so File > New carries the colour
// forward), it became reachable: set a red with nothing selected, File > New,
// and the per-document tier of the new canvas is empty while the app tier holds
// red. Rust's `build_live_panel_overrides` answers red (it has
// `.or_else(|| st.app_default_fill…)`); this port answered "nothing resolved",
// so the sliders / hex fell back to `color.yaml`'s stored 255/255/255 — while
// the SAME panel's fill swatch, one reader away, painted red.
//
// Mirrors the Rust block in jas_dioxus/src/workspace/dock_panel.rs
// (`build_live_panel_overrides`) tier for tier, including the fall-through on
// an explicit None.

/// File > New, verbatim: what `JasCommands`' `new_document` arm hands
/// ``WorkspaceState/addCanvas``.
private func fileNewModel() -> Model {
    Model(document: Document.newEmptyDocument())
}

private func rect(fill: Fill?, stroke: Stroke?) -> Element {
    .rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: fill, stroke: stroke))
}

private func selectedRect(fill: Fill?, stroke: Stroke?) -> Model {
    Model(document: Document(
        layers: [Layer(children: [rect(fill: fill, stroke: stroke)])],
        selectedLayer: 0,
        selection: [ElementSelection(path: [0, 0])]))
}

@Test func colorPanelSlidersReadTheAppTierAfterFileNew() {
    let workspace = WorkspaceState()
    let first = fileNewModel()
    workspace.addCanvas(first)
    // Nothing selected, so the colour lands on the DEFAULTS, not on a shape.
    LayersPanel.dispatchYamlAction(
        "set_active_color", model: first, params: ["color": "#ff0000"])

    let second = fileNewModel()
    workspace.addCanvas(second)
    #expect(second.defaultFill == nil,
            "the fresh canvas's OWN tier is empty — only the tier above answers")

    let overrides = try? #require(colorPanelLiveOverrides(model: second))
    #expect(overrides?["hex"] as? String == "ff0000",
            """
            the sliders must read the app tier, as Rust's \
            build_live_panel_overrides does — otherwise the hex field shows \
            color.yaml's stored ffffff while the fill swatch beside it is RED
            """)
    #expect(overrides?["r"] as? Int == 255)
    #expect(overrides?["g"] as? Int == 0)
    #expect(overrides?["bl"] as? Int == 0)
}

/// The swatch and the sliders are two readers of ONE fact, so they must not be
/// able to disagree. This is the divergence stated as a single assertion.
@Test func colorPanelSlidersAgreeWithTheFillSwatch() {
    let workspace = WorkspaceState()
    let first = fileNewModel()
    workspace.addCanvas(first)
    LayersPanel.dispatchYamlAction(
        "set_active_color", model: first, params: ["color": "#ff0000"])
    let second = fileNewModel()
    workspace.addCanvas(second)

    let swatch = liveSwatchPaint(model: second, isFill: true)
    let sliderHex = colorPanelLiveOverrides(model: second)?["hex"] as? String
    #expect(swatch == Color.fromHex("#ff0000"))
    #expect(sliderHex.map { "#" + $0 } == swatch.map { "#" + $0.toHex() },
            "one fact, one answer: the swatch and the sliders read the same tiers")
}

/// A COLD launch resolves through the same tier (nothing selected, no
/// per-document default), so it too is the app tier answering — white.
@Test func colorPanelSlidersOpenWhiteOnAColdLaunch() {
    let workspace = WorkspaceState()
    let model = fileNewModel()
    workspace.addCanvas(model)
    #expect(colorPanelLiveOverrides(model: model)?["hex"] as? String == "ffffff")
    model.fillOnTop = false
    #expect(colorPanelLiveOverrides(model: model)?["hex"] as? String == "000000",
            "stroke-on-top reads the stroke tiers")
}

/// The SELECTION still wins over both default tiers — the reason this reader
/// exists at all.
@Test func colorPanelSlidersFollowTheSelection() {
    let model = selectedRect(fill: Fill(color: Color(r: 0, g: 0, b: 1)),
                             stroke: Stroke(color: .black))
    #expect(colorPanelLiveOverrides(model: model)?["hex"] as? String == "0000ff")
}

/// An explicit None falls THROUGH to the app tier, exactly as Rust's
/// `and_then` → `.or_else` chain does: the `Uniform(None)` arm yields nothing
/// from the document tiers and the app tier answers. What the user sees is
/// unaffected — `color.yaml`'s fifteen slider `disabled` guards read
/// `state.fill_color`, which is null and disables them — but the NUMBERS the
/// disabled sliders hold have to be the same numbers in both ports.
@Test func colorPanelSlidersHoldTheAppTierUnderAnExplicitNone() {
    let workspace = WorkspaceState()
    let model = selectedRect(fill: nil, stroke: Stroke(color: .black))
    workspace.addCanvas(model)
    #expect(colorPanelLiveOverrides(model: model)?["hex"] as? String == "ffffff",
            "Rust's or_else supplies the app tier here; so must this port")
}

/// …and when the app tier itself is cleared (the user chose None with nothing
/// selected) NOTHING resolves, so the panel keeps its stored state. The tier is
/// a seed, not a floor: a hardcoded `?? white` would pass every test above and
/// fail this one.
@Test func colorPanelSlidersFallBackToStoredStateWhenBothTiersAreClear() {
    let workspace = WorkspaceState()
    let model = fileNewModel()
    workspace.addCanvas(model)
    LayersPanel.dispatchYamlAction("set_fill_none", model: model)
    #expect(model.appDefaultFill == nil, "the None route clears BOTH tiers")
    #expect(colorPanelLiveOverrides(model: model) == nil,
            "no tier resolves, so the panel falls back to its stored state")
}
