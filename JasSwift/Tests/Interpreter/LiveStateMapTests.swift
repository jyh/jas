import Testing
import Foundation
@testable import JasLib

// MARK: - CPTRIAGE: the Color panel's None controls were click-DEAD
//
// `cp_none_swatch` (set_active_color_none) and the fill/stroke widget's
// `cp_none_btn` (set_fill_none) both clear the active paint — and the panel
// they sit in did not move. The write was never the problem; the READ-BACK
// was. A panel body renders against a `state` scope that ``DockPanelView``
// built from the STATIC workspace defaults alone, so `state.fill_color` was
// the literal `"#ffffff"` no matter what the user had chosen, and
// `state.fill_color == null` could never be true.
//
// That comparison is load-bearing fifteen times over in `color.yaml`: every
// slider row's `disabled`, the hex field's `disabled`, the colour bar's
// `disabled` (honoured in `YamlPanelBodyView.renderColorBar`), and the
// panel-menu `enabled_when` on Invert / Complement. Swift's evaluator is
// ctx-only — `evaluate(_:context:)` never consults the store — so an
// unpublished null has no second chance downstream.
//
// These tests evaluate `color.yaml`'s REAL bind expressions against the REAL
// panel-render scope, and drive the state changes through the production
// action dispatcher. Mirrors the Rust `cptriage_*` tests in
// jas_dioxus/src/interpreter/renderer.rs.

/// `color.yaml`, verbatim: the guard every slider row, the hex field and the
/// colour bar bind to `disabled`.
private let cpDisabledGuard =
    "if state.fill_on_top then state.fill_color == null "
    + "else state.stroke_color == null"

/// `color.yaml`, verbatim: the panel-menu `enabled_when` on Invert and
/// Complement — the same fact read the other way round.
private let cpInvertEnabledWhen =
    "if state.fill_on_top then state.fill_color != null "
    + "else state.stroke_color != null"

/// The panel-render `state` scope, composed exactly as `buildPanelCtx` does.
private func colorRenderCtx(_ model: Model) -> [String: Any] {
    guard let ws = WorkspaceData.load() else {
        Issue.record("workspace bundle failed to load")
        return [:]
    }
    return ["state": buildLiveStateMap(ws: ws, model: model)]
}

private func rect(fill: Fill?, stroke: Stroke?) -> Element {
    .rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: fill, stroke: stroke))
}

/// A model with one selected rect carrying the given paint.
private func selectedRect(fill: Fill?, stroke: Stroke?) -> Model {
    Model(document: Document(
        layers: [Layer(children: [rect(fill: fill, stroke: stroke)])],
        selectedLayer: 0,
        selection: [ElementSelection(path: [0, 0])]))
}

private let white = Fill(color: Color(r: 1, g: 1, b: 1))
private let blackStroke = Stroke(color: Color(r: 0, g: 0, b: 0))

@Test func colorPanelControlsStartEnabledForARealColour() {
    let model = selectedRect(fill: white, stroke: blackStroke)
    let ctx = colorRenderCtx(model)
    #expect(evaluate("state.fill_color", context: ctx).toStringCoerce() == "#ffffff")
    #expect(evaluate(cpDisabledGuard, context: ctx).toBool() == false,
            "with a white fill the sliders / hex / colour bar are ENABLED")
    #expect(evaluate(cpInvertEnabledWhen, context: ctx).toBool() == true,
            "Invert / Complement are available while a colour is in force")
}

@Test func fillNoneVerbDisablesTheColorPanelControls() {
    let model = selectedRect(fill: white, stroke: blackStroke)
    // Exactly what cp_none_btn dispatches while the fill is on top.
    LayersPanel.dispatchYamlAction("set_fill_none", model: model)

    let ctx = colorRenderCtx(model)
    #expect(evaluate("state.fill_color", context: ctx).isNull,
            """
            the fill swatch's own bind must resolve to null, not to the \
            workspace default — otherwise the swatch keeps painting white and \
            the click looks dead
            """)
    #expect(evaluate(cpDisabledGuard, context: ctx).toBool() == true,
            "sliders / hex / colour bar must disable once the fill is None")
    #expect(evaluate(cpInvertEnabledWhen, context: ctx).toBool() == false,
            "Invert / Complement have nothing to invert")
}

@Test func strokeNoneVerbDisablesTheColorPanelControls() {
    let model = selectedRect(fill: white, stroke: blackStroke)
    model.fillOnTop = false
    LayersPanel.dispatchYamlAction("set_stroke_none", model: model)

    let ctx = colorRenderCtx(model)
    #expect(evaluate("state.stroke_color", context: ctx).isNull,
            "the stroke swatch's bind must resolve to null")
    #expect(evaluate(cpDisabledGuard, context: ctx).toBool() == true,
            "with the stroke active and None, the controls disable too")
    // The fill is untouched: a stroke verb must not clear the other attribute.
    #expect(evaluate("state.fill_color", context: ctx).toStringCoerce() == "#ffffff")
}

// The same fact reached from the OTHER direction: an element that simply has
// no fill. Nothing was dispatched — selecting it is enough, and the panel must
// report None for it exactly as it does after the None button.
@Test func selectedElementWithoutFillReportsNone() {
    let model = selectedRect(fill: nil, stroke: blackStroke)
    let ctx = colorRenderCtx(model)
    #expect(evaluate("state.fill_color", context: ctx).isNull,
            "a uniform no-fill selection reports None as null")
    #expect(evaluate(cpDisabledGuard, context: ctx).toBool() == true,
            "sliders / hex / colour bar disable for a no-fill selection")
}

// `fill_on_top` is what SELECTS which colour the guard reads, so it has to be
// live too. Publishing the colours while leaving the selector static would
// half-fix the guard.
@Test func fillOnTopSelectsWhichColourTheGuardReads() {
    // Fill is None, stroke is black. On top: fill → disabled. Swapped: the
    // guard reads the STROKE, which is a real colour → enabled.
    let model = selectedRect(fill: nil, stroke: blackStroke)
    #expect(evaluate(cpDisabledGuard, context: colorRenderCtx(model)).toBool() == true)
    model.fillOnTop = false
    #expect(evaluate(cpDisabledGuard, context: colorRenderCtx(model)).toBool() == false,
            "swapping to stroke-on-top must move the guard to the stroke")
}

// A MIXED selection has no single value to show, which is a THIRD outcome —
// not a colour and not a None. The overlay leaves the key alone (the workspace
// default stands) rather than inventing a null, so the controls stay enabled:
// a colour edit applies to the whole selection.
@Test func mixedSelectionLeavesTheWorkspaceDefaultStanding() {
    let model = Model(document: Document(
        layers: [Layer(children: [
            rect(fill: white, stroke: blackStroke),
            rect(fill: Fill(color: Color(r: 1, g: 0, b: 0)), stroke: blackStroke),
        ])],
        selectedLayer: 0,
        selection: [ElementSelection(path: [0, 0]), ElementSelection(path: [0, 1])]))
    let overrides = liveAppStateOverrides(model: model)
    #expect(overrides["fill_color"] == nil,
            "a Mixed fill publishes NOTHING — the caller's value stands")
    #expect(evaluate(cpDisabledGuard, context: colorRenderCtx(model)).toBool() == false,
            "Mixed is not None: the controls stay live")
}

// NOTHING SELECTED is a fourth outcome for the reader and the one a FRESH
// LAUNCH is in. It resolves down two tiers — the per-document default, then the
// app-level default, seeded white — so the controls open LIVE, exactly as Rust
// opens them (`tab.model.default_fill.or(st.app_default_fill)`). Publishing null
// here disabled fifteen sliders, the hex field and the colour bar on an empty
// canvas and greyed Invert / Complement, which is the wave's own defect shape
// reintroduced one tier down. Pinned cross-language by the
// `nothing_selected_*` cases in test_fixtures/actions/fill_stroke_none.json.
@Test func emptyCanvasOpensWithTheSeededAppDefault() {
    let model = Model()
    #expect(model.defaultFill == nil, "the per-document tier starts empty")
    let ctx = colorRenderCtx(model)
    #expect(evaluate("state.fill_color", context: ctx).toStringCoerce() == "#ffffff",
            "the app tier is what a fresh launch publishes")
    #expect(evaluate("state.stroke_color", context: ctx).toStringCoerce() == "#000000")
    #expect(evaluate(cpDisabledGuard, context: ctx).toBool() == false,
            "a fresh launch's sliders / hex / colour bar are ENABLED")
    #expect(evaluate(cpInvertEnabledWhen, context: ctx).toBool() == true,
            "and Invert / Complement are available")
}

// The tier is a SEED, not a floor: the None verbs clear it along with the
// document tier, so a user who chooses None with nothing selected still reaches
// the panel. A hardcoded `?? "#ffffff"` fallback would pass the test above and
// fail this one.
@Test func fillNoneWithNothingSelectedStillPublishesNull() {
    let model = Model()
    LayersPanel.dispatchYamlAction("set_fill_none", model: model)
    let ctx = colorRenderCtx(model)
    #expect(evaluate("state.fill_color", context: ctx).isNull,
            "clearing the paint with an empty selection must clear BOTH tiers")
    #expect(evaluate(cpDisabledGuard, context: ctx).toBool() == true)
    #expect(evaluate("state.stroke_color", context: ctx).toStringCoerce() == "#000000",
            "the stroke tier is untouched")
}

// The reader is derived from the model, so the verbs that write the fact have
// to reach the model. `set_fill_none` through the GENERIC dispatcher used to
// stop at the store — no `apply_active_color` hook was registered there — so
// the document kept its paint.
@Test func fillNoneVerbReachesTheDocument() {
    let model = selectedRect(fill: white, stroke: blackStroke)
    LayersPanel.dispatchYamlAction("set_fill_none", model: model)
    #expect(model.document.getElement([0, 0]).fill == nil,
            "the selected element loses its fill")
    #expect(model.defaultFill == nil, "and so does the tab default")
    #expect(model.document.getElement([0, 0]).stroke != nil,
            "the stroke is untouched")
}

// `set_active_color` branches on `state.fill_on_top`. The generic dispatcher
// gave effects no `state` namespace at all, so the read fell through to an
// unseeded store, came back null, and the ELSE branch recoloured the STROKE
// while the fill was on top.
@Test func setActiveColorHonoursFillOnTop() {
    let model = selectedRect(fill: white, stroke: blackStroke)
    LayersPanel.dispatchYamlAction(
        "set_active_color", model: model, params: ["color": "#112233"])
    let elem = model.document.getElement([0, 0])
    #expect(elem.fill?.color == Color.fromHex("#112233"),
            "the FILL is on top, so the fill is what gets the colour")
    #expect(elem.stroke?.color == Color(r: 0, g: 0, b: 0),
            "the stroke keeps its own colour")
}
