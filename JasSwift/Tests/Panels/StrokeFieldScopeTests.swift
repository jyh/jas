import Testing
import Foundation
@testable import JasLib

// STROKEWIDTH: a Stroke-panel edit writes ONLY what the user touched.
//
// The live bug (JYH, 2026-07-24, reported on the Rust port): select a
// line with a 5pt stroke, pick an arrowhead in the Stroke panel, and the
// line snaps back to 1pt. Both ports rebuilt the WHOLE Stroke from panel
// state on every edit and took the width from a source that was NOT the
// element (Rust: the app / tab default stroke; Swift: the panel `weight`
// key, stale until the weight input is committed), so any Stroke-panel
// control silently reset a selected element's weight. Cap / join had the
// same shape — the panel DISPLAYS them from the selected element
// (strokePanelLiveOverrides) while the apply re-imposed panel state —
// and dash / arrowheads / align / miter / width profile were re-stamped
// from stale panel state on every unrelated edit.
//
// The contract (identical to the Rust reference
// `apply_stroke_panel_to_selection`, app_state.rs): the apply names the
// panel field the user just committed and writes only that field's
// group; every other stroke attribute is preserved from the element,
// per element.

// MARK: - helpers

/// A stroke whose every panel-writable field is deliberately NON-default,
/// so any clobber shows up as a diff. Mirrors the Rust `rich_stroke()`.
private func richStroke(width: Double = 5.0,
                        color: Color = Color(r: 1, g: 0, b: 0)) -> Stroke {
    Stroke(color: color, width: width, linecap: .round, linejoin: .bevel,
           miterLimit: 3.0, align: .inside,
           dashPattern: [7.0, 3.0], dashAlignAnchors: true,
           startArrow: .circle, endArrow: .diamond,
           startArrowScale: 150.0, endArrowScale: 75.0,
           arrowAlign: .centerAtEnd, opacity: 0.5)
}

/// N selected Lines, each with its own stroke and width profile, with the
/// model default stroke left at plain 1pt black — the value the old apply
/// stamped over the element's own width.
private func strokeModel(
    _ specs: [(Stroke, [StrokeWidthPoint])]
) -> Model {
    let model = Model()
    let lines = specs.map { spec in
        Element.line(Line(x1: 0, y1: 0, x2: 100, y2: 0,
                          stroke: spec.0, widthPoints: spec.1))
    }
    model.setDocumentForTest(Document(
        layers: [Layer(children: lines)],
        selectedLayer: 0,
        selection: Set((0..<lines.count).map { ElementSelection(path: [0, $0]) })))
    model.defaultStroke = Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0)
    return model
}

private func strokeModel(_ stroke: Stroke) -> Model {
    strokeModel([(stroke, [])])
}

/// Seed the panel scope the way the panel's own widgets do (every write
/// -back lands in the panel state), then apply the named edit.
private func applyEdit(
    _ model: Model, _ edited: String, _ panel: [String: Any] = [:]
) {
    model.stateStore.initPanel("stroke_panel_content", defaults: panel)
    applyStrokePanelToSelection(store: model.stateStore,
                               controller: Controller(model: model),
                               edited: edited)
}

private func strokeAt(_ model: Model, _ i: Int) -> Stroke {
    guard let s = model.document.getElement([0, i]).stroke else {
        fatalError("expected a Stroke at [0,\(i)]")
    }
    return s
}

private func widthPointsAt(_ model: Model, _ i: Int) -> [StrokeWidthPoint] {
    guard case let .line(l) = model.document.getElement([0, i]) else {
        fatalError("expected a Line at [0,\(i)]")
    }
    return l.widthPoints
}

// MARK: - (a) the exact repro

@Test func strokeArrowheadEditKeepsElementWidth() {
    let model = strokeModel(richStroke())
    applyEdit(model, "end_arrowhead", ["end_arrowhead": "simple_arrow"])
    #expect(strokeAt(model, 0).endArrow == .simpleArrow, "the edit must land")
    #expect(strokeAt(model, 0).width == 5.0, "5pt line must STAY 5pt")
}

// MARK: - (b) same for cap / join / dash / align / profile / scale

@Test func strokeCapEditKeepsElementWidth() {
    let model = strokeModel(richStroke())
    applyEdit(model, "cap", ["cap": "square"])
    #expect(strokeAt(model, 0).linecap == .square)
    #expect(strokeAt(model, 0).width == 5.0)
}

@Test func strokeJoinEditKeepsElementWidth() {
    let model = strokeModel(richStroke())
    applyEdit(model, "join", ["join": "round"])
    #expect(strokeAt(model, 0).linejoin == .round)
    #expect(strokeAt(model, 0).width == 5.0)
}

@Test func strokeDashEditKeepsElementWidth() {
    let model = strokeModel(richStroke())
    applyEdit(model, "dash_1", ["dashed": true, "dash_1": 4.0, "gap_1": 2.0])
    #expect(strokeAt(model, 0).dashPattern == [4.0, 2.0])
    #expect(strokeAt(model, 0).width == 5.0)
}

@Test func strokeAlignEditKeepsElementWidth() {
    let model = strokeModel(richStroke())
    applyEdit(model, "align_stroke", ["align_stroke": "outside"])
    #expect(strokeAt(model, 0).align == .outside)
    #expect(strokeAt(model, 0).width == 5.0)
}

@Test func strokeProfileEditKeepsElementWidth() {
    let model = strokeModel(richStroke())
    applyEdit(model, "profile", ["profile": "taper_end"])
    #expect(strokeAt(model, 0).width == 5.0)
    // The profile amplitude derives from the ELEMENT's width.
    let wp = widthPointsAt(model, 0)
    #expect(wp.count == 2)
    #expect(wp.first?.widthLeft == 2.5, "half of the element's 5pt")
}

@Test func strokeArrowScaleEditKeepsElementWidth() {
    let model = strokeModel(richStroke())
    applyEdit(model, "start_arrowhead_scale",
              ["start_arrowhead_scale": 200.0, "end_arrowhead_scale": 200.0])
    #expect(strokeAt(model, 0).startArrowScale == 200.0)
    #expect(strokeAt(model, 0).width == 5.0)
}

// MARK: - (c) the weight input still applies a new width

@Test func strokeWeightEditAppliesNewWidth() {
    let model = strokeModel(richStroke())
    applyEdit(model, "weight", ["weight": 9.0])
    #expect(strokeAt(model, 0).width == 9.0, "weight input must still apply")
    // ...without disturbing the rest of the element's stroke.
    #expect(strokeAt(model, 0).linecap == .round)
    #expect(strokeAt(model, 0).dashPattern == [7.0, 3.0])
}

@Test func strokeWeightEditRescalesProfile() {
    let model = strokeModel(richStroke())
    applyEdit(model, "weight", ["weight": 8.0, "profile": "taper_end"])
    #expect(widthPointsAt(model, 0).first?.widthLeft == 4.0,
            "profile follows the new weight")
}

// MARK: - (d) colour / opacity preservation unchanged

@Test func strokeEditKeepsElementColorAndOpacity() {
    let model = strokeModel(richStroke())
    applyEdit(model, "cap", ["cap": "butt"])
    #expect(strokeAt(model, 0).color == Color(r: 1, g: 0, b: 0))
    #expect(strokeAt(model, 0).opacity == 0.5)
}

// MARK: - the rest of the class

@Test func strokeArrowheadEditKeepsCapJoinAndMiter() {
    let model = strokeModel(richStroke())
    applyEdit(model, "start_arrowhead", ["start_arrowhead": "square"])
    let s = strokeAt(model, 0)
    #expect(s.startArrow == .square)
    #expect(s.linecap == .round, "cap is displayed from the element")
    #expect(s.linejoin == .bevel, "join is displayed from the element")
    #expect(s.miterLimit == 3.0)
    #expect(s.align == .inside)
}

@Test func strokeCapEditKeepsDashAndArrowheads() {
    let model = strokeModel(richStroke())
    applyEdit(model, "cap", ["cap": "butt"])
    let s = strokeAt(model, 0)
    #expect(s.linecap == .butt)
    #expect(s.dashPattern == [7.0, 3.0], "dash survives a cap edit")
    #expect(s.dashAlignAnchors)
    #expect(s.startArrow == .circle)
    #expect(s.endArrow == .diamond)
    #expect(s.startArrowScale == 150.0)
    #expect(s.endArrowScale == 75.0)
    #expect(s.arrowAlign == .centerAtEnd)
}

@Test func strokeCapEditKeepsElementWidthProfile() {
    let taper = [StrokeWidthPoint(t: 0, widthLeft: 2.5, widthRight: 2.5),
                 StrokeWidthPoint(t: 1, widthLeft: 0, widthRight: 0)]
    let model = strokeModel([(richStroke(), taper)])
    applyEdit(model, "cap", ["cap": "butt"])
    #expect(widthPointsAt(model, 0).count == taper.count,
            "a cap edit must not wipe a custom width profile")
}

@Test func strokeEditKeepsEachElementsOwnWidth() {
    let model = strokeModel([
        (richStroke(), []),
        (richStroke(width: 2.0, color: Color(r: 0, g: 0, b: 0)), []),
    ])
    applyEdit(model, "end_arrowhead", ["end_arrowhead": "slash"])
    #expect(strokeAt(model, 0).endArrow == .slash)
    #expect(strokeAt(model, 1).endArrow == .slash)
    #expect(strokeAt(model, 0).width == 5.0)
    #expect(strokeAt(model, 1).width == 2.0, "sibling keeps its own width")
    #expect(strokeAt(model, 0).color == Color(r: 1, g: 0, b: 0))
    #expect(strokeAt(model, 1).color == Color(r: 0, g: 0, b: 0))
}

@Test func strokeEditDoesNotMoveNewElementDefaults() {
    let model = strokeModel(richStroke())
    applyEdit(model, "cap", ["cap": "square"])
    let d = model.defaultStroke
    #expect(d?.width == 1.0, "new-element default width must stay 1pt")
    #expect(d?.color == Color(r: 0, g: 0, b: 0), "default colour stays black")
    #expect(d?.linecap == .square, "the edited field DOES move it")
}

@Test func strokeUnknownFieldIsANoOp() {
    let model = strokeModel(richStroke())
    applyEdit(model, "not_a_stroke_field", ["cap": "butt"])
    #expect(strokeAt(model, 0) == richStroke())
}

// The chain button is UI-only: it must not push a document edit.
@Test func strokeLinkScalesToggleIsANoOp() {
    let model = strokeModel(richStroke())
    applyEdit(model, "link_arrowhead_scale", ["link_arrowhead_scale": true,
                                             "start_arrowhead_scale": 300.0])
    #expect(strokeAt(model, 0) == richStroke())
    #expect(!model.canUndo, "toggling the chain pushes no undo step")
}

// An edit naming a field the panel does not own changes nothing: the apply
// cannot guess which field the user touched, and guessing is what clobbered
// the width. (An edit naming NO field is now a compile error — `edited` is
// required, so the old silent-no-op default cannot be reached at all.)
@Test func strokeUnrecognizedFieldEditIsANoOp() {
    let model = strokeModel(richStroke())
    model.stateStore.initPanel("stroke_panel_content", defaults: ["cap": "round"])
    applyStrokePanelToSelection(store: model.stateStore,
                                controller: Controller(model: model),
                                edited: "not_a_stroke_field")
    #expect(strokeAt(model, 0) == richStroke())
    #expect(!model.canUndo, "an unowned field pushes no undo step")
}

// STROKEWIDTH repair 3: the committed weight applies even with NO default
// stroke (e.g. right after picking the None stroke swatch). This port always
// read the panel-committed `weight` first, so it worked here; Rust read the
// tab / app default stroke width and dropped the commit when that was nil,
// making the same edit a silent no-op there. Both ports now read the
// panel-committed value — pinned on both sides so they cannot drift apart.
@Test func strokeWeightEditAppliesWithNoDefaultStroke() {
    let model = strokeModel(richStroke())
    model.defaultStroke = nil
    applyEdit(model, "weight", ["weight": 6.0])
    #expect(strokeAt(model, 0).width == 6.0,
            "a committed weight must apply with no default stroke")
    // ...and the rest of the element's stroke is still untouched.
    #expect(strokeAt(model, 0).linecap == richStroke().linecap)
    #expect(strokeAt(model, 0).dashPattern == richStroke().dashPattern)
}

// ── the flat GLOBAL scope resolves to the same fields ────────────
//
// Out-of-panel writers reach the Stroke panel through the flat globals a
// YAML `set:` effect writes: `stroke_cap`, and for the weight input
// `stroke_width` (workspace/actions.yaml `reset_fill_stroke`,
// workspace/panels/stroke.yaml `init:`). `strokePanelField` resolved the
// weight's global as `stroke_weight` — a key nothing in workspace/ writes —
// while the reference maps weight -> `stroke_width`
// (effects.py stroke_panel_state). So a global weight write reached the
// width group (fromField normalizes the key) and then fell through to the
// default stroke for its VALUE. Same shape for `align_stroke`, whose global
// is `stroke_align`.

/// Seed the flat GLOBAL scope — what an out-of-panel `set:` effect writes —
/// with NO panel scope at all, then apply the named edit.
private func applyGlobalEdit(
    _ model: Model, _ edited: String, _ globals: [String: Any] = [:]
) {
    for (k, v) in globals { model.stateStore.set(k, v) }
    applyStrokePanelToSelection(store: model.stateStore,
                                controller: Controller(model: model),
                                edited: edited)
}

@Test func strokeWeightAppliesFromTheGlobalScope() {
    let model = strokeModel(richStroke())
    applyGlobalEdit(model, "stroke_width", ["stroke_width": 7.0])
    #expect(strokeAt(model, 0).width == 7.0,
            "a global stroke_width write must supply the committed width")
    // ...and only the width group moved.
    #expect(strokeAt(model, 0).linecap == richStroke().linecap)
    #expect(strokeAt(model, 0).dashPattern == richStroke().dashPattern)
}

@Test func strokeCapAppliesFromTheGlobalScope() {
    let model = strokeModel(richStroke())
    applyGlobalEdit(model, "stroke_cap", ["stroke_cap": "square"])
    #expect(strokeAt(model, 0).linecap == .square)
    #expect(strokeAt(model, 0).width == 5.0)
}

@Test func strokeAlignAppliesFromTheGlobalScope() {
    let model = strokeModel(richStroke())
    applyGlobalEdit(model, "stroke_align", ["stroke_align": "outside"])
    #expect(strokeAt(model, 0).align == .outside)
    #expect(strokeAt(model, 0).width == 5.0)
}

// The panel scope still WINS over the global: that is where every in-panel
// widget write-back lands, and the globals are only the fallback.
@Test func strokePanelScopeBeatsTheGlobal() {
    let model = strokeModel(richStroke())
    model.stateStore.set("stroke_width", 2.0)
    applyEdit(model, "weight", ["weight": 9.0])
    #expect(strokeAt(model, 0).width == 9.0, "the panel commit wins")
}

// Every render key the workspace writes must be one a `set:` effect can
// actually produce, and the reference's list is the contract.
@Test func strokeRenderKeysMatchTheReference() {
    // workspace/actions.yaml reset_fill_stroke writes exactly these.
    for key in ["stroke_width", "stroke_align", "stroke_cap", "stroke_join",
                "stroke_dashed", "stroke_dash_1", "stroke_gap_1",
                "stroke_start_arrowhead", "stroke_end_arrowhead",
                "stroke_start_arrowhead_scale", "stroke_end_arrowhead_scale",
                "stroke_arrow_align", "stroke_profile"] {
        #expect(isStrokeRenderKey(key), "\(key) must trigger the stroke apply")
    }
    // ...and not the spellings nothing writes.
    #expect(!isStrokeRenderKey("stroke_weight"))
    #expect(!isStrokeRenderKey("stroke_align_stroke"))
}

// ── swap_fill_stroke is colour-only ──────────────────────────────
//
// Shift+X / the fill-stroke widget arrow / the Color-panel button all say
// they swap COLOURS (workspace/actions.yaml `swap_fill_stroke`), but this
// port built a bare `Stroke(color:)` and stamped it over the selection, so
// the swap reset a 5pt dashed arrowheaded line's width / cap / join / dash /
// arrowheads / align / miter / opacity. Rust at least kept the DEFAULT's
// attributes — a live port divergence on top of the clobber. Both ports now
// recolour per element and preserve everything else.
//
// These pins drive `Controller.swapFillStrokeColors`, the single home of
// the law, which both views now delegate to. That pins the LAW once (the
// old pins re-implemented it with the mappers, asserting nothing shipped);
// the delegation itself in ContentView.swapColors / the CanvasSubwindow
// keyDown "X" branch is not exercised here — a view that stopped
// delegating would need a GUI-level check to catch.
//
// The defaults are deliberately PLAIN and the element RICH: that gap is the
// bug, and seeding the default with the same rich stroke hides it.
@Test func swapFillStrokeSwapsColoursOnly() {
    let model = strokeModel(richStroke())
    let green = Color(r: 0, g: 1, b: 0)
    model.defaultFill = Fill(color: green, opacity: 0.25)
    model.defaultStroke = Stroke(color: Color(r: 1, g: 1, b: 1), width: 1.0)
    Controller(model: model).swapFillStrokeColors()
    let s = strokeAt(model, 0)
    let rich = richStroke()
    #expect(s.color == green, "stroke takes the fill's colour")
    #expect(s.width == rich.width, "a swap must not reset the weight")
    #expect(s.linecap == rich.linecap)
    #expect(s.linejoin == rich.linejoin)
    #expect(s.miterLimit == rich.miterLimit)
    #expect(s.align == rich.align)
    #expect(s.dashPattern == rich.dashPattern)
    #expect(s.dashAlignAnchors == rich.dashAlignAnchors)
    #expect(s.startArrow == rich.startArrow)
    #expect(s.endArrow == rich.endArrow)
    #expect(s.startArrowScale == rich.startArrowScale)
    #expect(s.endArrowScale == rich.endArrowScale)
    #expect(s.arrowAlign == rich.arrowAlign)
    #expect(s.opacity == rich.opacity, "a swap must not reset stroke opacity")
}

@Test func swapFillStrokePreservesFillOpacity() {
    #expect(ColorPanel.recolorFill(Fill(color: Color(r: 0, g: 1, b: 0), opacity: 0.25),
                                   Color(r: 1, g: 1, b: 1)).opacity == 0.25,
            "a swap must not reset fill opacity")
}

// The two colours come from the tab DEFAULTS, not from the selection.
// ContentView sourced them from the selection first (defaults only as
// fallback) while Shift+X and Rust sourced the defaults, so one action
// swapped different colours depending on how it was invoked. Per-element
// sourcing is also wrong on its own terms: a Line holds no fill, so the
// selection's fill reads as "uniformly nil" and the swap would take the
// line's stroke away entirely instead of recolouring it.
@Test func swapFillStrokeSourcesTheDefaultsNotTheSelection() {
    let model = strokeModel(richStroke())   // a Line: stroke red, NO fill
    let green = Color(r: 0, g: 1, b: 0)
    model.defaultFill = Fill(color: green)
    model.defaultStroke = Stroke(color: Color(r: 1, g: 1, b: 1), width: 1.0)
    Controller(model: model).swapFillStrokeColors()
    #expect(model.document.getElement([0, 0]).stroke != nil,
            "a swap must not delete the line's stroke")
    #expect(strokeAt(model, 0).color == green,
            "the stroke takes the DEFAULT fill's colour")
    #expect(model.defaultStroke?.color == green)
    #expect(model.defaultFill?.color == Color(r: 1, g: 1, b: 1),
            "and the default fill takes the default stroke's colour")
}

@Test func swapFillStrokePushesOneUndoStep() {
    let model = strokeModel(richStroke())
    model.defaultFill = Fill(color: Color(r: 0, g: 1, b: 0))
    Controller(model: model).swapFillStrokeColors()
    #expect(model.canUndo)
    model.undo()
    #expect(strokeAt(model, 0) == richStroke(),
            "one undo restores fill AND stroke")
}

@Test func strokeEditPushesOneUndoStep() {
    let model = strokeModel(richStroke())
    applyEdit(model, "cap", ["cap": "butt"])
    #expect(model.canUndo)
    model.undo()
    #expect(strokeAt(model, 0) == richStroke(), "one undo restores it all")
}

// MARK: - the Color-panel twin: a colour pick is COLOUR-only
//
// setActiveColor used to stamp `Stroke(color:width:)` over the selection,
// so picking a stroke colour on a 5pt dashed arrowheaded line left a plain
// 1pt stroke. Same class as the Stroke-panel clobber, one panel over.

private let blue = Color(r: 0, g: 0, b: 1)

@Test func strokeColorPickKeepsEveryOtherAttribute() {
    let model = strokeModel(richStroke())
    model.fillOnTop = false
    ColorPanel.setActiveColor(blue, model: model)
    let s = strokeAt(model, 0)
    #expect(s.color == blue, "the colour must land")
    #expect(s.width == 5.0, "5pt line must STAY 5pt")
    #expect(s.linecap == .round)
    #expect(s.linejoin == .bevel)
    #expect(s.dashPattern == [7.0, 3.0])
    #expect(s.startArrow == .circle)
    #expect(s.endArrow == .diamond)
    #expect(s.align == .inside)
    #expect(s.opacity == 0.5, "stroke opacity preserved")
}

@Test func strokeColorPickLiveKeepsEveryOtherAttribute() {
    let model = strokeModel(richStroke())
    model.fillOnTop = false
    ColorPanel.setActiveColorLive(blue, model: model)
    let s = strokeAt(model, 0)
    #expect(s.color == blue)
    #expect(s.width == 5.0)
    #expect(s.dashPattern == [7.0, 3.0])
    #expect(!model.canUndo, "live drag stays off the undo stack")
}

@Test func strokeColorPickKeepsEachElementsOwnWidth() {
    let model = strokeModel([
        (richStroke(), []),
        (richStroke(width: 2.0), []),
    ])
    model.fillOnTop = false
    ColorPanel.setActiveColor(blue, model: model)
    #expect(strokeAt(model, 0).width == 5.0)
    #expect(strokeAt(model, 1).width == 2.0)
    #expect(strokeAt(model, 1).color == blue)
}

@Test func strokeColorPickKeepsDefaultAttributes() {
    let model = strokeModel(richStroke())
    model.fillOnTop = false
    // A panel-set default (round cap at 3pt) must survive a pick.
    model.defaultStroke = Stroke(color: Color(r: 0, g: 0, b: 0), width: 3.0,
                                 linecap: .round)
    ColorPanel.setActiveColor(blue, model: model)
    #expect(model.defaultStroke?.color == blue)
    #expect(model.defaultStroke?.width == 3.0)
    #expect(model.defaultStroke?.linecap == .round)
}

@Test func fillColorPickKeepsElementFillOpacity() {
    let model = Model()
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                 fill: Fill(color: Color(r: 1, g: 0, b: 0),
                                            opacity: 0.25)))
    model.setDocumentForTest(Document(
        layers: [Layer(children: [rect])],
        selectedLayer: 0,
        selection: [ElementSelection(path: [0, 0])]))
    model.fillOnTop = true
    ColorPanel.setActiveColor(blue, model: model)
    let f = model.document.getElement([0, 0]).fill
    #expect(f?.color == blue)
    #expect(f?.opacity == 0.25, "fill opacity must survive a colour pick")
}

// The YAML colour route (a swatch / hex click writing state.stroke_color)
// must behave exactly like the Color panel's own commit.
@Test func yamlStrokeColorWriteKeepsEveryOtherAttribute() {
    let model = strokeModel(richStroke())
    applyActiveColorWrite(
        model: model, write: ColorWrite(key: "stroke_color", value: "#0000ff"))
    let s = strokeAt(model, 0)
    #expect(s.color == blue)
    #expect(s.width == 5.0, "5pt line must STAY 5pt")
    #expect(s.dashPattern == [7.0, 3.0])
    #expect(s.startArrow == .circle)
}

@Test func yamlFillColorWriteKeepsFillOpacity() {
    let model = Model()
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                 fill: Fill(color: Color(r: 1, g: 0, b: 0),
                                            opacity: 0.25)))
    model.setDocumentForTest(Document(
        layers: [Layer(children: [rect])],
        selectedLayer: 0,
        selection: [ElementSelection(path: [0, 0])]))
    applyActiveColorWrite(
        model: model, write: ColorWrite(key: "fill_color", value: "#0000ff"))
    let f = model.document.getElement([0, 0]).fill
    #expect(f?.color == blue)
    #expect(f?.opacity == 0.25)
}

// The panel scope is where every in-panel widget write-back lands (the
// arrowhead selects bind `panel.start_arrowhead` only, with no global
// mirror), so the apply must read it. The flat `stroke_*` globals remain
// the fallback for out-of-panel writers.
@Test func strokeEditReadsGlobalWhenPanelScopeIsEmpty() {
    let model = strokeModel(richStroke())
    model.stateStore.set("stroke_cap", "butt")
    applyEdit(model, "cap")
    #expect(strokeAt(model, 0).linecap == .butt)
    #expect(strokeAt(model, 0).width == 5.0)
}
