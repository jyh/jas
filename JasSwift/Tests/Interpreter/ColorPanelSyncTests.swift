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

// MARK: - COLORTIERS repair 2: the slider's WRITE path is the SAME reader
//
// The repair above gave the DISPLAY reader its app tier, and left the WRITE
// path a different reader with none — so the panel SHOWED the app-tier colour
// while a drag on that same panel COMPUTED from `color.yaml`'s stored channels.
// Rust has one reader for both halves: the slider's `oninput` / `onchange` and
// the value box's `onchange` all pass `ctx.get("panel")` — the panel-defaults
// map already overlaid by `build_live_panel_overrides` — into
// `compute_color_from_panel` (renderer.rs).
//
// The scenario is the one `colorPanelSlidersReadTheAppTierAfterFileNew` builds,
// carried one step further: after File > New the app tier holds RED and the
// fresh store holds `color.yaml`'s h=0 / s=0 / b=100 (white). Drag Brightness
// to 50 and Rust commits `800000`; this port committed `808080`.

/// `color.yaml`'s declared panel-state defaults, as `DockPanelView` seeds them
/// on first render.
private func seedColorPanelDefaults(_ model: Model) {
    guard let ws = WorkspaceData.load() else {
        Issue.record("workspace failed to load")
        return
    }
    model.stateStore.initPanel(
        "color_panel_content",
        defaults: ws.panelStateDefaults("color_panel_content"))
}

private func panelNum(_ model: Model, _ key: String) -> Double? {
    let v = model.stateStore.getPanel("color_panel_content", key)
    return (v as? Double) ?? (v as? Int).map(Double.init)
}

/// The premise the write-path test rests on, asserted rather than assumed:
/// `color.yaml` seeds the HSB channels to WHITE, so a write path that reads the
/// store alone mixes the dragged channel with white and not with the paint.
@Test func colorPanelStoreDefaultsAreWhiteInHsb() {
    let model = fileNewModel()
    seedColorPanelDefaults(model)
    #expect(model.stateStore.getPanel("color_panel_content", "mode") as? String == "hsb")
    #expect(panelNum(model, "h") == 0)
    #expect(panelNum(model, "s") == 0)
    #expect(panelNum(model, "b") == 100)
}

/// Drag Brightness after File > New. This is `commitPanelWrite`'s own sequence
/// — store the channel, then `notifyPanelStateChanged` — so it exercises the
/// production write path, not a copy of it.
@Test func colorPanelChannelDragReadsTheAppTierAfterFileNew() {
    let workspace = WorkspaceState()
    let first = fileNewModel()
    workspace.addCanvas(first)
    LayersPanel.dispatchYamlAction(
        "set_active_color", model: first, params: ["color": "#ff0000"])

    let second = fileNewModel()
    workspace.addCanvas(second)
    seedColorPanelDefaults(second)
    #expect(second.defaultFill == nil, "the fresh canvas's own tier is empty")

    second.stateStore.setPanel("color_panel_content", "b", 50.0)
    notifyPanelStateChanged("color_panel_content", store: second.stateStore,
                            model: second, edited: "b")

    #expect(second.defaultFill?.color.toHex() == "800000",
            """
            the dragged channel mixes with the channels of the ACTIVE PAINT \
            (h=0 s=100 from the app tier's red), as Rust's \
            compute_color_from_panel does from the overlaid panel map — not \
            with color.yaml's stored white, which commits mid grey
            """)
}

/// The same drag with a SELECTION: the selection's own colour is the one the
/// sibling channels come from. Blue at s=100, so dropping Brightness to 50 has
/// to stay blue.
@Test func colorPanelChannelDragMixesWithTheSelectionsColour() {
    let model = selectedRect(fill: Fill(color: Color(r: 0, g: 0, b: 1)),
                             stroke: Stroke(color: .black))
    seedColorPanelDefaults(model)
    model.stateStore.setPanel("color_panel_content", "b", 50.0)
    notifyPanelStateChanged("color_panel_content", store: model.stateStore,
                            model: model, edited: "b")
    #expect(model.defaultFill?.color.toHex() == "000080",
            "hue 240 / saturation 100 come from the selection, not the store")
}

/// The dragged channel is the one fact the STORE owns: the overlay must not
/// clobber it with the value re-derived from the paint the drag is replacing.
@Test func colorPanelChannelDragKeepsTheDraggedChannel() {
    let workspace = WorkspaceState()
    let model = fileNewModel()
    workspace.addCanvas(model)
    LayersPanel.dispatchYamlAction(
        "set_active_color", model: model, params: ["color": "#ff0000"])
    seedColorPanelDefaults(model)
    // Red is h=0; drag HUE to 120 and the commit must be green, not red.
    model.stateStore.setPanel("color_panel_content", "h", 120.0)
    notifyPanelStateChanged("color_panel_content", store: model.stateStore,
                            model: model, edited: "h")
    #expect(model.defaultFill?.color.toHex() == "00ff00",
            "the edited channel wins over the overlay's value for it")
}

/// A COMMIT (pointer-up, Enter) writes the app tier as well as the document
/// tier, exactly as Rust's `AppState::set_active_color` does — which is what
/// makes a colour dragged on a slider survive File > New the way a colour
/// clicked on a swatch (the YAML `set_active_color` route through
/// ``applyActiveColorWrite``) already did. The LIVE arm writes only the
/// document tier in both ports (Rust's `set_active_color_live` never touches
/// the app tier), so a drag tick cannot leak a half-way colour across a
/// File > New.
@Test func colorPanelCommitWritesBothTiersAndLiveWritesOnlyTheDocumentTier() {
    let workspace = WorkspaceState()
    let model = fileNewModel()
    workspace.addCanvas(model)
    let blue = Color(r: 0, g: 0, b: 1)
    let green = Color(r: 0, g: 1, b: 0)

    ColorPanel.setActiveColorLive(green, model: model)
    #expect(model.defaultFill?.color.toHex() == "00ff00")
    #expect(model.appDefaultFill?.color.toHex() == "ffffff",
            """
            a live drag tick leaves the app tier alone, as Rust's \
            set_active_color_live does
            """)

    ColorPanel.setActiveColor(blue, model: model)
    #expect(model.defaultFill?.color.toHex() == "0000ff")
    #expect(model.appDefaultFill?.color.toHex() == "0000ff",
            """
            the commit writes the app tier too — Rust's set_active_color \
            writes it FIRST, before the per-tab tier
            """)
}

/// Invert / Complement and their enabled state resolve the same two default
/// tiers the panel displays. They greyed out after File > New in BOTH ports:
/// Swift read `model.defaultFill` alone, Rust's `active_color()` reached the
/// app tier only with no tab open. Fixed together (COLORTIERS repair 2);
/// mirrored by Rust's
/// `colortiers_invert_stays_available_after_a_new_document`.
///
/// Neither port consults the SELECTION here — both invert the DEFAULT paint —
/// and that stays true; it is banked in COLOR_TESTS.md, not changed here.
@Test func colorPanelInvertStaysAvailableAfterFileNew() {
    let workspace = WorkspaceState()
    let first = fileNewModel()
    workspace.addCanvas(first)
    LayersPanel.dispatchYamlAction(
        "set_active_color", model: first, params: ["color": "#ff0000"])
    let second = fileNewModel()
    workspace.addCanvas(second)
    #expect(second.defaultFill == nil, "the fresh canvas's own tier is empty")

    #expect(ColorPanel.isEnabled("invert_active_color", model: second),
            "Invert operates on the colour the panel DISPLAYS")
    var layout = WorkspaceLayout.defaultLayout()
    // `invert_active_color` touches neither the layout nor the address; any
    // well-formed address will do (the panel-close arm is the one that reads
    // it).
    let addr = PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0),
                         panelIdx: 0)
    ColorPanel.dispatch("invert_active_color", addr: addr,
                        layout: &layout, model: second)
    #expect(second.defaultFill?.color.toHex() == "00ffff",
            """
            red inverted is cyan; before the fix nothing resolved and the \
            menu item was a no-op
            """)
}

/// …and the tier is a seed, not a floor: the None route clears both tiers, so
/// the two menu items stay disabled for an explicit none (COLOR.md, None
/// state). Mirrors Rust's
/// `colortiers_invert_is_still_disabled_for_an_explicit_none`.
@Test func colorPanelInvertStaysDisabledForAnExplicitNone() {
    let workspace = WorkspaceState()
    let model = fileNewModel()
    workspace.addCanvas(model)
    LayersPanel.dispatchYamlAction("set_fill_none", model: model)
    #expect(model.appDefaultFill == nil, "the None route clears both tiers")
    #expect(!ColorPanel.isEnabled("invert_active_color", model: model),
            "no tier resolves, so Invert / Complement stay greyed")
}
