import Testing
import Foundation
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
    model.setDocumentForTest(Document(
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
    // The apply is field-scoped: it writes only the group of the field the
    // user just committed (STROKEWIDTH — a panel edit must not rewrite
    // attributes the user did not touch). Each case here seeds exactly the
    // keys it exercises, so replay one apply per seeded key, which is what
    // the runtime does (one commit -> one apply).
    var edits = Array(globals.keys)
    if weight != nil { edits.append("weight") }
    for key in edits {
        applyStrokePanelToSelection(store: model.stateStore,
                                    controller: Controller(model: model),
                                    edited: key)
    }
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
    model.setDocumentForTest(Document(
        layers: [Layer(children: [rect])],
        selectedLayer: 0,
        selection: []))
    model.stateStore.set("stroke_cap", "round")
    model.stateStore.initPanel("stroke_panel_content", defaults: ["weight": 9.0])
    applyStrokePanelToSelection(store: model.stateStore,
                               controller: Controller(model: model),
                               edited: "cap")
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
    model.setDocumentForTest(Document(
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
    // The weight's global spelling is `stroke_width` — the key
    // `strokePanelField` reads back and a `set:` effect writes. It was
    // `stroke_weight`, which nothing read.
    #expect((m.stateStore.get("stroke_width") as? Double) == 3.5)
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

// MARK: - Dashed-Line checkbox toggles both ways (DASHFIX)

/// The Dashed-Line checkbox fires the canonical paired toggle:
///   set_panel_state { dashed:       "not panel.dashed" }   (panel scope)
///   set            { stroke_dashed: "not state.stroke_dashed" } (global)
/// `set_panel_state` toggles the PANEL scope (the checkbox's `checked`
/// binding), and always toggles correctly. The bug lives in the GLOBAL
/// `stroke_dashed` that applyStrokePanelToSelection reads: the `set`
/// reads `state.stroke_dashed` from the panel eval-context, which the
/// dock (DockPanelView.buildPanelCtx) seeds from the STATIC workspace
/// defaults — that map then shadows the live store globals in
/// StateStore.evalContext. Unless the dock overlays the live value
/// (strokePanelStateOverrides), the read is a stale `false` on every
/// click, the global latches to `true`, and the rendered dash sticks ON
/// even as the checkbox visually toggles. This test rebuilds the dock's
/// context the same way and clicks twice; BOTH scopes must clear.
@Test func strokeDashedCheckboxTogglesBothWays() {
    let ws = WorkspaceData.load()!
    let store = StateStore()
    store.set("stroke_dashed", false)
    store.initPanel("stroke_panel_content", defaults: ["dashed": false])
    store.setActivePanel("stroke_panel_content")

    let effects: [Any] = [
        ["set_panel_state": ["key": "dashed", "value": "not panel.dashed"]],
        ["set": ["stroke_dashed": "not state.stroke_dashed"]],
    ]
    // Mirror DockPanelView.buildPanelCtx: static state defaults overlaid
    // with the live stroke-toggle values, plus the live panel scope.
    func dockCtx() -> [String: Any] {
        var stateMap = ws.stateDefaults()
        for (k, v) in strokePanelStateOverrides(store: store) { stateMap[k] = v }
        return ["state": stateMap,
                "panel": store.getPanelState("stroke_panel_content")]
    }

    // Click 1 — turns dashing on (both the checkbox and the applied dash).
    runEffects(effects, ctx: dockCtx(), store: store)
    #expect((store.getPanel("stroke_panel_content", "dashed") as? Bool) == true)
    #expect((store.get("stroke_dashed") as? Bool) == true)

    // Click 2 — must turn dashing OFF. The global key (what apply reads)
    // is the one the bug latches on, so it is the load-bearing assertion.
    runEffects(effects, ctx: dockCtx(), store: store)
    #expect((store.getPanel("stroke_panel_content", "dashed") as? Bool) == false)
    #expect((store.get("stroke_dashed") as? Bool) == false)
}

// MARK: - LINKSCALE: linked arrowhead-scale mirror + panel/global gap
//
// SWIFTLINK. The two Stroke scale combos (`stk_start_arrowhead_scale` /
// `stk_end_arrowhead_scale`) carry a generic `event: commit` behavior:
// when `panel.link_arrowhead_scale` is true, committing one scale copies
// it onto the OTHER scale in BOTH scopes — the panel field that drives the
// sibling widget, and the global `stroke_<field>` that
// applyStrokePanelToSelection reads. renderComboBox runs the native
// two-way write (commitWidgetWrite + the panel->global gap closure
// `mirrorStrokeScaleCommitToGlobal`) then `runInputCommitBehavior`. These
// pins target those pure helpers (the SwiftUI closure needs component
// context) — mirroring the Rust reference, which tests
// `run_input_commit_behavior` directly, and the reference-interpreter
// values in TestLinkedArrowheadScaleMirror.

/// Inline copy of the shipped `stk_start_arrowhead_scale` combo (the
/// bundle presence is gated by the reference / Rust bundle tests). Mirrors
/// onto the end scale when the chain is active.
private func startScaleCombo() -> [String: Any] {
    let mirror: [[String: Any]] = [
        ["set_panel_state": ["key": "end_arrowhead_scale",
                             "value": "panel.start_arrowhead_scale"]],
        ["set": ["stroke_end_arrowhead_scale": "panel.start_arrowhead_scale"]],
    ]
    let guardEffect: [String: Any] = ["if": [
        "condition": "panel.link_arrowhead_scale",
        "then": mirror,
    ] as [String: Any]]
    let behavior: [[String: Any]] = [[
        "event": "commit",
        "effects": [guardEffect],
    ]]
    return [
        "id": "stk_start_arrowhead_scale",
        "type": "combo_box",
        "bind": ["value": "panel.start_arrowhead_scale"],
        "behavior": behavior,
    ]
}

/// Inline copy of the shipped `stk_end_arrowhead_scale` combo — the
/// symmetric partner mirroring onto the start scale.
private func endScaleCombo() -> [String: Any] {
    let mirror: [[String: Any]] = [
        ["set_panel_state": ["key": "start_arrowhead_scale",
                             "value": "panel.end_arrowhead_scale"]],
        ["set": ["stroke_start_arrowhead_scale": "panel.end_arrowhead_scale"]],
    ]
    let guardEffect: [String: Any] = ["if": [
        "condition": "panel.link_arrowhead_scale",
        "then": mirror,
    ] as [String: Any]]
    let behavior: [[String: Any]] = [[
        "event": "commit",
        "effects": [guardEffect],
    ]]
    return [
        "id": "stk_end_arrowhead_scale",
        "type": "combo_box",
        "bind": ["value": "panel.end_arrowhead_scale"],
        "behavior": behavior,
    ]
}

/// Seed a Stroke panel scope (panel + mirrored globals) for the scale
/// combos, and mark it active (set_panel_state targets the active panel).
private func linkScaleStore(linked: Bool) -> StateStore {
    let store = StateStore()
    store.initPanel("stroke_panel_content", defaults: [
        "start_arrowhead_scale": 100.0, "end_arrowhead_scale": 100.0,
        "link_arrowhead_scale": linked, "weight": 1.0,
    ])
    store.setActivePanel("stroke_panel_content")
    store.set("stroke_start_arrowhead_scale", 100.0)
    store.set("stroke_end_arrowhead_scale", 100.0)
    return store
}

/// Reproduce the scale combo's native two-way write: the panel scope
/// receives the committed value AND the global `stroke_<field>` is mirrored
/// (the gap closure the port performs before apply).
private func commitStrokeScale(_ store: StateStore, _ field: String, _ v: Double) {
    store.setPanel("stroke_panel_content", field, v)
    mirrorStrokeScaleCommitToGlobal(store: store, key: field, value: v)
}

/// A render-time panel snapshot (STALE for the just-committed field): the
/// commit hook must patch the committed value in, mirroring Rust.
private func staleScaleCtx(linked: Bool) -> [String: Any] {
    ["panel": [
        "start_arrowhead_scale": 100.0, "end_arrowhead_scale": 100.0,
        "link_arrowhead_scale": linked,
    ]]
}

private func numeric(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

// (a) linked mirror: link on, commit start=200 -> end scale (panel AND
// global) becomes 200.
@Test func linkedStartScaleCommitMirrorsBothScopes() {
    let model = Model()
    let store = model.stateStore
    // Re-seed model's store the same way linkScaleStore does.
    store.initPanel("stroke_panel_content", defaults: [
        "start_arrowhead_scale": 100.0, "end_arrowhead_scale": 100.0,
        "link_arrowhead_scale": true, "weight": 1.0])
    store.setActivePanel("stroke_panel_content")
    store.set("stroke_start_arrowhead_scale", 100.0)
    store.set("stroke_end_arrowhead_scale", 100.0)

    commitStrokeScale(store, "start_arrowhead_scale", 200)
    runInputCommitBehavior(element: startScaleCombo(),
                           field: "start_arrowhead_scale", committed: 200.0,
                           context: staleScaleCtx(linked: true),
                           store: store, model: model)

    // The other scale mirrors in BOTH scopes.
    #expect(numeric(store.getPanel("stroke_panel_content", "end_arrowhead_scale")) == 200)
    #expect(numeric(store.get("stroke_end_arrowhead_scale")) == 200)
    // The edited scale reached the global too (gap closure, patch overrode
    // the stale render snapshot).
    #expect(numeric(store.get("stroke_start_arrowhead_scale")) == 200)
}

// Symmetric partner: end -> start.
@Test func linkedEndScaleCommitMirrorsBothScopes() {
    let model = Model()
    let store = model.stateStore
    store.initPanel("stroke_panel_content", defaults: [
        "start_arrowhead_scale": 100.0, "end_arrowhead_scale": 100.0,
        "link_arrowhead_scale": true, "weight": 1.0])
    store.setActivePanel("stroke_panel_content")
    store.set("stroke_start_arrowhead_scale", 100.0)
    store.set("stroke_end_arrowhead_scale", 100.0)

    commitStrokeScale(store, "end_arrowhead_scale", 75)
    runInputCommitBehavior(element: endScaleCombo(),
                           field: "end_arrowhead_scale", committed: 75.0,
                           context: staleScaleCtx(linked: true),
                           store: store, model: model)

    #expect(numeric(store.getPanel("stroke_panel_content", "start_arrowhead_scale")) == 75)
    #expect(numeric(store.get("stroke_start_arrowhead_scale")) == 75)
}

// (b) link off -> independent.
@Test func unlinkedStartScaleCommitLeavesOtherAlone() {
    let model = Model()
    let store = model.stateStore
    store.initPanel("stroke_panel_content", defaults: [
        "start_arrowhead_scale": 100.0, "end_arrowhead_scale": 100.0,
        "link_arrowhead_scale": false, "weight": 1.0])
    store.setActivePanel("stroke_panel_content")
    store.set("stroke_start_arrowhead_scale", 100.0)
    store.set("stroke_end_arrowhead_scale", 100.0)

    commitStrokeScale(store, "start_arrowhead_scale", 200)
    runInputCommitBehavior(element: startScaleCombo(),
                           field: "start_arrowhead_scale", committed: 200.0,
                           context: staleScaleCtx(linked: false),
                           store: store, model: model)

    // The other scale is untouched in both scopes.
    #expect(numeric(store.getPanel("stroke_panel_content", "end_arrowhead_scale")) == 100)
    #expect(numeric(store.get("stroke_end_arrowhead_scale")) == 100)
    // The edited scale still reaches its own global (gap closure runs
    // regardless of the link flag).
    #expect(numeric(store.get("stroke_start_arrowhead_scale")) == 200)
}

// (c) link-flag persistence: after a scale commit, link_arrowhead_scale
// stays true (the mirror never clobbers the UI-only chain flag).
@Test func scaleCommitKeepsLinkFlag() {
    let model = Model()
    let store = model.stateStore
    store.initPanel("stroke_panel_content", defaults: [
        "start_arrowhead_scale": 100.0, "end_arrowhead_scale": 100.0,
        "link_arrowhead_scale": true, "weight": 1.0])
    store.setActivePanel("stroke_panel_content")

    commitStrokeScale(store, "start_arrowhead_scale", 200)
    runInputCommitBehavior(element: startScaleCombo(),
                           field: "start_arrowhead_scale", committed: 200.0,
                           context: staleScaleCtx(linked: true),
                           store: store, model: model)

    #expect(store.getPanel("stroke_panel_content", "link_arrowhead_scale") as? Bool == true)
}

// (d) gap-closure regression: a committed scale is visible to
// applyStrokePanelToSelection (globals fresh). WITHOUT the panel->global
// mirror the global stays at its default 100 and the element scale never
// changes.
@Test func committedScaleReachesApplyToSelection() {
    let model = strokeModelWithSelectedRect()
    let store = model.stateStore
    store.initPanel("stroke_panel_content", defaults: [
        "weight": 1.0, "start_arrowhead_scale": 100.0,
        "end_arrowhead_scale": 100.0])
    store.setActivePanel("stroke_panel_content")
    store.set("stroke_start_arrowhead_scale", 100.0)
    store.set("stroke_end_arrowhead_scale", 100.0)

    // Native combo commit of start=150 (panel bind + gap-closure global).
    commitStrokeScale(store, "start_arrowhead_scale", 150)
    applyStrokePanelToSelection(store: store, controller: Controller(model: model),
                                edited: "start_arrowhead_scale")

    #expect(model.document.getElement([0, 0]).stroke?.startArrowScale == 150)
}

// (e) SWIFTLINK re-apply gap (the confirmed divergence): link ON, commit
// start=200 through the REAL runInputCommitBehavior path against a Model
// with a SELECTED stroked element. The mirror's set / set_panel_state
// effects must drive applyStrokePanelToSelection for the SIBLING scale —
// exactly as Rust's apply_set_panel_state_with_ctx re-applies with its own
// key (renderer.rs). The SIBLING must reach the element through the
// commit-behavior effects, NOT a direct applyStrokePanelToSelection call.
// Before the fix the commit-behavior platformEffects map
// (alignPlatformEffects) registered no notify_panel_state_changed hook, so
// the mirror updated the panel/global scopes but the element stayed
// {startArrowScale:200, endArrowScale:100} (start applied by the
// edited-field commit, end stale). Rust: {200,200}.
//
// STROKEWIDTH: the MECHANISM changed, the law did not. Each arrowhead
// scale is now its own edit group, so the sibling no longer rides along on
// the edited field's apply — it reaches the element because the notify
// payload NAMES the key each mirror write touched, and that key's own
// group is what gets written. Same {200,200} outcome, now for the right
// reason: an UNLINKED start-scale edit leaves the end scale alone (see
// StrokeFieldScopeTests / the stroke_apply corpus).
@Test func linkedStartScaleCommitReAppliesSiblingToSelection() {
    let model = strokeModelWithSelectedRect()
    let store = model.stateStore
    store.initPanel("stroke_panel_content", defaults: [
        "start_arrowhead_scale": 100.0, "end_arrowhead_scale": 100.0,
        "link_arrowhead_scale": true, "weight": 1.0])
    store.setActivePanel("stroke_panel_content")
    store.set("stroke_start_arrowhead_scale", 100.0)
    store.set("stroke_end_arrowhead_scale", 100.0)

    // The edited field's native two-way write + its OWN apply — this is
    // what commitPanelWrite does BEFORE runInputCommitBehavior. Element
    // reaches {200,100}: start applied, sibling still stale.
    commitStrokeScale(store, "start_arrowhead_scale", 200)
    applyStrokePanelToSelection(store: store, controller: Controller(model: model),
                                edited: "start_arrowhead_scale")
    #expect(model.document.getElement([0, 0]).stroke?.startArrowScale == 200)
    #expect(model.document.getElement([0, 0]).stroke?.endArrowScale == 100)

    // The linked mirror runs through the real commit-behavior path. Its
    // set / set_panel_state effects must re-apply the mirrored sibling to
    // the selection (the effect-hook path, no direct apply call here).
    runInputCommitBehavior(element: startScaleCombo(),
                           field: "start_arrowhead_scale", committed: 200.0,
                           context: staleScaleCtx(linked: true),
                           store: store, model: model)

    let s = model.document.getElement([0, 0]).stroke
    #expect(s?.endArrowScale == 200)    // SIBLING re-applied (was stale 100)
    #expect(s?.startArrowScale == 200)  // edited field intact
}

// (f) mirror-OFF element guard: link off, commit start=200 via the real
// path. The `if` guard is false so no mirror effects run — the sibling end
// scale on the ELEMENT must stay 100. Confirms the fix adds NO new apply
// where Rust has none (passes both before and after the fix).
@Test func unlinkedStartScaleCommitLeavesSiblingElementAlone() {
    let model = strokeModelWithSelectedRect()
    let store = model.stateStore
    store.initPanel("stroke_panel_content", defaults: [
        "start_arrowhead_scale": 100.0, "end_arrowhead_scale": 100.0,
        "link_arrowhead_scale": false, "weight": 1.0])
    store.setActivePanel("stroke_panel_content")
    store.set("stroke_start_arrowhead_scale", 100.0)
    store.set("stroke_end_arrowhead_scale", 100.0)

    commitStrokeScale(store, "start_arrowhead_scale", 200)
    applyStrokePanelToSelection(store: store, controller: Controller(model: model),
                                edited: "start_arrowhead_scale")
    runInputCommitBehavior(element: startScaleCombo(),
                           field: "start_arrowhead_scale", committed: 200.0,
                           context: staleScaleCtx(linked: false),
                           store: store, model: model)

    let s = model.document.getElement([0, 0]).stroke
    #expect(s?.startArrowScale == 200)
    #expect(s?.endArrowScale == 100)    // sibling untouched (no spurious apply)
}
