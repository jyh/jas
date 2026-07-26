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

// MARK: - COLORTIERS: the app tier lives ABOVE the canvases
//
// JYH ruled 2026-07-26: fill/stroke defaults are WORKSPACE state, not document
// state — they belong with brush size and the active tool. Set a red, hit
// File > New, and you are mid-flow and expect red; nobody thinks of "current
// fill" as a property of the file. Rust has always had that shape (one
// `AppState.app_default_fill` above all tabs); this port kept the tier on
// ``Model`` and there is one Model PER CANVAS, so File > New reseeded white.
//
// The tier now lives on ``WorkspaceState`` — this port's AppState-above-tabs —
// and every canvas that enters the workspace adopts it. Mirrored by Rust's
// `colortiers_app_default_survives_a_new_document`.

/// File > New, verbatim: what `JasCommands`' `new_document` arm hands
/// ``WorkspaceState/addCanvas``.
private func fileNewModel() -> Model {
    Model(document: Document.newEmptyDocument())
}

@Test func appDefaultsSurviveFileNew() {
    let workspace = WorkspaceState()
    let first = fileNewModel()
    workspace.addCanvas(first)

    // Nothing selected, so the colour lands on the DEFAULTS, not on a shape.
    LayersPanel.dispatchYamlAction(
        "set_active_color", model: first, params: ["color": "#ff0000"])
    #expect(evaluate("state.fill_color", context: colorRenderCtx(first))
                .toStringCoerce() == "#ff0000")

    let second = fileNewModel()
    workspace.addCanvas(second)
    #expect(second.defaultFill == nil,
            """
            the fresh document's OWN tier starts empty — the answer below can \
            only come from the tier above the canvases
            """)
    #expect(evaluate("state.fill_color", context: colorRenderCtx(second))
                .toStringCoerce() == "#ff0000",
            """
            File > New must carry the colour forward: the defaults are \
            workspace state, and the user is mid-flow
            """)
}

// The tier is shared, not copied: a colour set on the SECOND canvas is the
// colour the first one reports too. A per-canvas copy would pass the test
// above (adoption at add time) and fail this one.
@Test func appDefaultsAreOneTierNotACopyPerCanvas() {
    let workspace = WorkspaceState()
    let first = fileNewModel()
    let second = fileNewModel()
    workspace.addCanvas(first)
    workspace.addCanvas(second)
    LayersPanel.dispatchYamlAction(
        "set_active_color", model: second, params: ["color": "#00ff00"])
    #expect(evaluate("state.fill_color", context: colorRenderCtx(first))
                .toStringCoerce() == "#00ff00",
            "one tier above the canvases, as Rust's AppState has above its tabs")
}

// COLD LAUNCH is unchanged: white fill, black stroke. The ruling moved WHERE
// the tier lives, not what it is seeded with.
@Test func coldLaunchStillOpensBlackAndWhite() {
    let workspace = WorkspaceState()
    let model = fileNewModel()
    workspace.addCanvas(model)
    let ctx = colorRenderCtx(model)
    #expect(evaluate("state.fill_color", context: ctx).toStringCoerce() == "#ffffff")
    #expect(evaluate("state.stroke_color", context: ctx).toStringCoerce() == "#000000")
}

// MARK: - COLORTIERS: one fact, one reader
//
// Three more sites answered the fill/stroke question their own way. Each is the
// same disease as the tier split above: the fact has a reader, and a caller
// that re-derives it from `model.defaultFill` gets a different answer.

// The two dialog-opening sites seeded `state.fill_color` from the per-document
// default ALONE — so double-clicking the toolbar fill swatch with a red rect
// selected opened the picker on RED in Rust (which seeds from
// `build_live_state_map`) and on WHITE here.
@Test func dialogSeedShowsTheSelectionsColour() {
    let model = selectedRect(fill: Fill(color: Color(r: 1, g: 0, b: 0)), stroke: blackStroke)
    #expect(dialogStateScope(model: model)["fill_color"] as? String == "#ff0000",
            "a dialog opens on the paint the user can see, not the tab default")
}

// The THIRD dialog-opening site: `fill_stroke_widget`'s double-click →
// open_color_picker, the one the Color and Swatches panels carry. It hand-rolled
// `selection ?? model.defaultFill` and overlaid THAT onto the panel ctx, which
// already carried the right answer — so for a MIXED selection with a non-empty
// tab default it OVERWROTE the declared default with the tab colour. Rust seeds
// `#ffffff` there (Mixed publishes nothing, the declared default stands), which
// is the one Mixed rule the COLORTIERS corpus case pins.
@Test func colorPickerSeedLeavesTheDeclaredDefaultStandingForMixed() {
    let model = Model(document: Document(
        layers: [Layer(children: [
            rect(fill: Fill(color: Color(r: 1, g: 0, b: 0)), stroke: blackStroke),
            rect(fill: Fill(color: Color(r: 0, g: 0, b: 1)), stroke: blackStroke),
        ])],
        selectedLayer: 0,
        selection: [ElementSelection(path: [0, 0]), ElementSelection(path: [0, 1])]))
    model.defaultFill = Fill(color: Color(r: 0, g: 1, b: 0))

    guard let ws = WorkspaceData.load() else {
        Issue.record("workspace bundle failed to load")
        return
    }
    // The ctx the widget renders against — correct before the overlay touches it.
    let panelCtx: [String: Any] = ["state": buildLiveStateMap(ws: ws, model: model)]
    let seeded = colorPickerSeedContext(panelCtx, model: model)
    let state = seeded["state"] as? [String: Any]
    #expect(state?["fill_color"] as? String == "#ffffff",
            """
            a Mixed selection publishes nothing, so the DECLARED default is \
            what the picker opens on — the tab default must not overwrite it
            """)
}

// …and the site still does the job it was added for: a uniform selection seeds
// the picker on the paint the user can see.
@Test func colorPickerSeedShowsTheSelectionsColour() {
    let model = selectedRect(fill: Fill(color: Color(r: 1, g: 0, b: 0)), stroke: blackStroke)
    let seeded = colorPickerSeedContext(["state": [String: Any]()], model: model)
    let state = seeded["state"] as? [String: Any]
    #expect(state?["fill_color"] as? String == "#ff0000")
    #expect(state?["stroke_color"] as? String == "#000000")
}

// A no-fill selection must SAY none (NSNull), not leave white standing — the
// same thing `dialogStateScope` says, because it is now the same reader.
@Test func colorPickerSeedSaysNoneForANoFillSelection() {
    let model = selectedRect(fill: nil, stroke: blackStroke)
    let state = colorPickerSeedContext(["state": [String: Any]()],
                                       model: model)["state"] as? [String: Any]
    #expect(state?["fill_color"] is NSNull)
}

// Keys the widget's ctx carried that are NOT the two colours survive untouched:
// the seed re-states two facts, it does not rebuild the scope.
@Test func colorPickerSeedKeepsTheRestOfTheCtx() {
    let model = selectedRect(fill: white, stroke: blackStroke)
    let seeded = colorPickerSeedContext(
        ["state": ["active_tool": "selection"] as [String: Any],
         "panel": ["mode": "rgb"] as [String: Any]],
        model: model)
    let state = seeded["state"] as? [String: Any]
    #expect(state?["active_tool"] as? String == "selection")
    #expect((seeded["panel"] as? [String: Any])?["mode"] as? String == "rgb")
}

@Test func dialogSeedSaysNoneForANoFillSelection() {
    let model = selectedRect(fill: nil, stroke: blackStroke)
    #expect(dialogStateScope(model: model)["fill_color"] is NSNull,
            """
            hand-rolled `if let fill = model.defaultFill` could not SAY none — \
            it left the workspace's white standing
            """)
}

// The toolbar's native fill/stroke squares resolved
// `selection ?? model.defaultFill` on their own, skipping the app tier — so on
// a cold launch the square drew the NO-PAINT indicator while the Color panel,
// one reader away, showed white.
@Test func toolbarSquaresReadTheAppTier() {
    let model = Model()
    #expect(model.defaultFill == nil, "the per-document tier starts empty")
    #expect(liveSwatchPaint(model: model, isFill: true) == Color(r: 1, g: 1, b: 1),
            "a cold launch's fill square is WHITE, as the Color panel says")
    #expect(liveSwatchPaint(model: model, isFill: false) == Color(r: 0, g: 0, b: 0))
}

@Test func toolbarSquaresStillSayNoPaint() {
    let model = selectedRect(fill: nil, stroke: blackStroke)
    #expect(liveSwatchPaint(model: model, isFill: true) == nil,
            "a no-fill selection still draws the red-diagonal indicator")
}

// A null colour has TWO meanings and the value alone cannot tell them apart:
// `state.fill_color` null means "the user set this attribute to None" (draw the
// red-diagonal indicator), while `panel.recent_colors.3` null means "that slot
// is empty" (draw a hollow placeholder). `renderColorSwatch` used to send both
// to `.clear`, so the two rendered identically. The decision is read off the
// bind's own declaration — mirrors Rust's
// `cptriage_null_means_none_only_for_nullable_state_colours`.
@Test func nullMeansNoneOnlyForNullableStateColours() {
    #expect(nullColorMeansNone("state.fill_color"))
    #expect(nullColorMeansNone("state.stroke_color"))
    #expect(!nullColorMeansNone("panel.recent_colors.3"),
            "an empty recent slot is a placeholder, not a None indicator")
    #expect(!nullColorMeansNone("swatch.color"))
    #expect(!nullColorMeansNone("stroke_dash_2"), "nullable but not a colour")
    #expect(!nullColorMeansNone("stroke_width"),
            "a colour bind on a non-nullable field means nothing here")
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
