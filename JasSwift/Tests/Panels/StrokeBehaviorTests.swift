import Testing
@testable import JasLib

// Cross-language SEAM BEHAVIOR tests for the Stroke panel's
// panel->element mapping (and the element->panel read/sync side).
// Ported from the Rust reference apply_stroke_panel_to_selection
// (jas_dioxus/src/workspace/app_state.rs ~1098) and the Python sync
// reference jas/panels/stroke_panel_sync_test.py, so the SAME
// input->output values gate the Swift apply pipeline. See CLAUDE.md
// (equivalence prime directive).
//
// SEAM SHAPE (Swift): applyStrokePanelToSelection reads MOST fields
// from the flat global store via store.getAll() (keys "stroke_cap",
// "stroke_join", "stroke_align_stroke", "stroke_miter_limit",
// "stroke_dashed", "stroke_dash_1"..., "stroke_start_arrowhead", ...),
// EXCEPT the stroke weight which is read from the panel scope
// getPanel("stroke_panel_content", "weight"). So each case seeds the
// production global keys (+ the panel weight) and runs apply END-TO-END
// against a document with a selected stroked Rect, then asserts the
// resulting element's stroke attribute. This mirrors the Rust
// stroke_panel struct fields with identical values.

// MARK: - helpers

/// Build a Model whose single selected element is a stroked Rect,
/// ready for applyStrokePanelToSelection.
private func strokeModelWithSelectedRect(
    baseStroke: Stroke = Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0)
) -> Model {
    let model = Model()
    let rect = Element.rect(Rect(x: 0, y: 0, width: 100, height: 50,
                                 stroke: baseStroke))
    model.setDocumentUnbracketed(Document(
        layers: [Layer(children: [rect])],
        selectedLayer: 0,
        selection: [ElementSelection(path: [0, 0])]))
    return model
}

/// Seed the production stroke panel state (global keys + panel weight),
/// run apply, and return the resulting selected element's Stroke.
///
/// `globals` are written to the flat store (where apply reads
/// cap/join/align/dashes/arrows/miter). `weight`, if given, is written
/// to the panel scope (where apply reads it).
private func applyStrokePanel(
    _ model: Model, globals: [String: Any] = [:], weight: Double? = nil
) -> Stroke {
    for (k, v) in globals { model.stateStore.set(k, v) }
    if let w = weight {
        model.stateStore.initPanel("stroke_panel_content", defaults: ["weight": w])
    } else {
        model.stateStore.initPanel("stroke_panel_content", defaults: [:])
    }
    applyStrokePanelToSelection(store: model.stateStore,
                               controller: Controller(model: model))
    guard let s = model.document.getElement([0, 0]).stroke else {
        fatalError("expected a Stroke at [0,0] after apply")
    }
    return s
}

// MARK: - weight

@Test func strokeWeight() {
    // panel weight=2.5 -> stroke.width == 2.5
    let s = applyStrokePanel(strokeModelWithSelectedRect(), weight: 2.5)
    #expect(s.width == 2.5)
}

// MARK: - cap -> linecap

@Test func strokeCapRound() {
    let s = applyStrokePanel(strokeModelWithSelectedRect(),
                             globals: ["stroke_cap": "round"])
    #expect(s.linecap == .round)
}

@Test func strokeCapSquare() {
    let s = applyStrokePanel(strokeModelWithSelectedRect(),
                             globals: ["stroke_cap": "square"])
    #expect(s.linecap == .square)
}

@Test func strokeCapButtDefault() {
    // "butt" and unrecognized/default both map to Butt.
    let s = applyStrokePanel(strokeModelWithSelectedRect(),
                             globals: ["stroke_cap": "butt"])
    #expect(s.linecap == .butt)
}

// MARK: - join -> linejoin

@Test func strokeJoinRound() {
    let s = applyStrokePanel(strokeModelWithSelectedRect(),
                             globals: ["stroke_join": "round"])
    #expect(s.linejoin == .round)
}

@Test func strokeJoinBevel() {
    let s = applyStrokePanel(strokeModelWithSelectedRect(),
                             globals: ["stroke_join": "bevel"])
    #expect(s.linejoin == .bevel)
}

@Test func strokeJoinMiterDefault() {
    let s = applyStrokePanel(strokeModelWithSelectedRect(),
                             globals: ["stroke_join": "miter"])
    #expect(s.linejoin == .miter)
}

// MARK: - miter_limit

@Test func strokeMiterLimit() {
    // miter_limit=8 -> stroke.miter_limit == 8
    let s = applyStrokePanel(strokeModelWithSelectedRect(),
                             globals: ["stroke_miter_limit": 8.0])
    #expect(s.miterLimit == 8)
}

// MARK: - align -> StrokeAlign

@Test func strokeAlignInside() {
    let s = applyStrokePanel(strokeModelWithSelectedRect(),
                             globals: ["stroke_align_stroke": "inside"])
    #expect(s.align == .inside)
}

@Test func strokeAlignOutside() {
    let s = applyStrokePanel(strokeModelWithSelectedRect(),
                             globals: ["stroke_align_stroke": "outside"])
    #expect(s.align == .outside)
}

@Test func strokeAlignCenterDefault() {
    let s = applyStrokePanel(strokeModelWithSelectedRect(),
                             globals: ["stroke_align_stroke": "center"])
    #expect(s.align == .center)
}

// MARK: - dash pattern

@Test func strokeDashTwoEntries() {
    // dashed=true, dash_1=12, gap_1=6 -> dash pattern [12, 6]
    let s = applyStrokePanel(strokeModelWithSelectedRect(), globals: [
        "stroke_dashed": true, "stroke_dash_1": 12.0, "stroke_gap_1": 6.0,
    ])
    #expect(s.dashPattern == [12.0, 6.0])
}

@Test func strokeDashFourEntries() {
    // dashed=true, dash_1=12,gap_1=6,dash_2=3,gap_2=3 -> [12,6,3,3]
    let s = applyStrokePanel(strokeModelWithSelectedRect(), globals: [
        "stroke_dashed": true,
        "stroke_dash_1": 12.0, "stroke_gap_1": 6.0,
        "stroke_dash_2": 3.0, "stroke_gap_2": 3.0,
    ])
    #expect(s.dashPattern == [12.0, 6.0, 3.0, 3.0])
}

@Test func strokeDashDisabledEmpty() {
    // dashed=false -> NO dash pattern (empty). Start from a dashed base
    // to prove apply clears it.
    let base = Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0,
                      dashPattern: [12.0, 6.0])
    let s = applyStrokePanel(strokeModelWithSelectedRect(baseStroke: base),
                             globals: ["stroke_dashed": false])
    #expect(s.dashPattern.isEmpty)
}

// MARK: - arrowheads

@Test func strokeStartArrowSimple() {
    // start_arrowhead "simple_arrow" -> start-arrow SimpleArrow variant
    let s = applyStrokePanel(strokeModelWithSelectedRect(),
                             globals: ["stroke_start_arrowhead": "simple_arrow"])
    #expect(s.startArrow == .simpleArrow)
}

@Test func strokeEndArrowNone() {
    // end_arrowhead "none" -> no end-arrow. Start from an element that
    // has an end arrow to prove apply clears it.
    let base = Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0,
                      endArrow: .simpleArrow)
    let s = applyStrokePanel(strokeModelWithSelectedRect(baseStroke: base),
                             globals: ["stroke_end_arrowhead": "none"])
    #expect(s.endArrow == .none)
}

// MARK: - optional extras (reachable via the same seam)

@Test func strokeArrowScale() {
    // start/end_arrowhead_scale pass through.
    let s = applyStrokePanel(strokeModelWithSelectedRect(), globals: [
        "stroke_start_arrowhead_scale": 150.0,
        "stroke_end_arrowhead_scale": 80.0,
    ])
    #expect(s.startArrowScale == 150)
    #expect(s.endArrowScale == 80)
}

@Test func strokeArrowAlignCenterAtEnd() {
    let s = applyStrokePanel(strokeModelWithSelectedRect(),
                             globals: ["stroke_arrow_align": "center_at_end"])
    #expect(s.arrowAlign == .centerAtEnd)
}

@Test func strokeArrowAlignTipAtEndDefault() {
    let s = applyStrokePanel(strokeModelWithSelectedRect(),
                             globals: ["stroke_arrow_align": "tip_at_end"])
    #expect(s.arrowAlign == .tipAtEnd)
}

@Test func strokeDashAlignAnchors() {
    let s = applyStrokePanel(strokeModelWithSelectedRect(),
                             globals: ["stroke_dash_align_anchors": true])
    #expect(s.dashAlignAnchors == true)
}

// MARK: - no-op guard

@Test func strokeNoOpWhenSelectionEmpty() {
    // Empty selection -> apply must not mutate the element's stroke.
    let model = Model()
    let rect = Element.rect(Rect(x: 0, y: 0, width: 100, height: 50,
                                 stroke: Stroke(color: Color(r: 0, g: 0, b: 0),
                                                width: 1.0, linecap: .butt)))
    model.setDocumentUnbracketed(Document(
        layers: [Layer(children: [rect])],
        selectedLayer: 0,
        selection: []))
    model.stateStore.set("stroke_cap", "round")
    model.stateStore.initPanel("stroke_panel_content", defaults: ["weight": 9.0])
    applyStrokePanelToSelection(store: model.stateStore,
                               controller: Controller(model: model))
    let s = model.document.getElement([0, 0]).stroke
    #expect(s?.linecap == .butt)   // unchanged
    #expect(s?.width == 1.0)       // unchanged
}

// MARK: - SYNC / read side (element -> panel)

// Mirror the Python reference stroke_panel_sync_test.py: reflect
// weight/cap/join FROM the selected element into the panel. Swift has
// two read seams:
//   - syncStrokePanelFromSelection (push into the flat store), and
//   - strokePanelLiveOverrides (pull; returns weight/cap/join).
// Both are covered so the element->panel direction is gated.

/// Build a Model with a single selected stroked Rect carrying the
/// given attributes, for the sync/read direction.
private func syncModel(_ stroke: Stroke) -> Model {
    let model = Model()
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, stroke: stroke))
    model.setDocumentUnbracketed(Document(
        layers: [Layer(children: [rect])],
        selectedLayer: 0,
        selection: [ElementSelection(path: [0, 0])]))
    return model
}

@Test func strokeSyncWeightCapJoin_push() {
    // Element stroke width=3.5, cap=round, join=bevel -> flat store keys.
    let m = syncModel(Stroke(color: Color(r: 0, g: 0, b: 0), width: 3.5,
                             linecap: .round, linejoin: .bevel))
    syncStrokePanelFromSelection(store: m.stateStore,
                                 controller: Controller(model: m))
    #expect((m.stateStore.get("stroke_weight") as? Double) == 3.5)
    #expect((m.stateStore.get("stroke_cap") as? String) == "round")
    #expect((m.stateStore.get("stroke_join") as? String) == "bevel")
}

@Test func strokeSyncWeightCapJoin_overrides() {
    // Same element, via the pull-style live overrides used by the dock.
    let m = syncModel(Stroke(color: Color(r: 0, g: 0, b: 0), width: 3.5,
                             linecap: .square, linejoin: .round))
    let o = strokePanelLiveOverrides(model: m)
    #expect((o["weight"] as? Double) == 3.5)
    #expect((o["cap"] as? String) == "square")
    #expect((o["join"] as? String) == "round")
}
