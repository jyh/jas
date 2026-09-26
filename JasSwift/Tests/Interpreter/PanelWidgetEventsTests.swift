import Foundation
import Testing
@testable import JasLib

// PanelWidgetEvents: the Swift app's route for a value widget's commit and a
// boolean widget's press (WIDGET_EVENTS.md).
//
// `YamlPanelBodyView` builds one per event from its model, its panel id and
// its render scope, and calls `commit` or `press`. These tests build it the
// same way, over the SHIPPED widgets, so the route the view takes is the
// route driven here. The headless contract is held to the corpus by
// `WidgetEventCorpusTests`; these arms hold what the app adds to it: the
// render scope, the panel-write host, the native dispatch, and the store the
// app actually has (no bundle `state` defaults, no panel `init:` hydration).

private func shipped(_ panelId: String, _ widgetId: String) -> [String: Any] {
    guard let panel = WorkspaceData.load()?.panel(panelId),
          let widget = WidgetEvent.findWidget(in: panel["content"], id: widgetId) else {
        Issue.record("no shipped widget \(widgetId) in \(panelId)")
        return [:]
    }
    return widget
}

/// Open `panelId` the way the dock does (its `state:` defaults, active), and
/// return the route with a render scope taken NOW, as a render would take it.
private func events(_ model: Model, _ panelId: String,
                    panelOverlay: [String: Any] = [:]) -> PanelWidgetEvents {
    let store = model.stateStore
    if !store.hasPanel(panelId) {
        store.initPanel(panelId,
                        defaults: WorkspaceData.load()?.panelStateDefaults(panelId) ?? [:])
    }
    store.setActivePanel(panelId)
    var panelScope = store.getPanelState(panelId)
    for (k, v) in panelOverlay { panelScope[k] = v }
    return PanelWidgetEvents(model: model, panelId: panelId,
                             scope: ["panel": panelScope, "state": store.getAll()])
}

private func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

private func modelWithSelectedRect(
    stroke: Stroke? = Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0)
) -> Model {
    let model = Model()
    let rect = Element.rect(Rect(x: 0, y: 0, width: 100, height: 50, stroke: stroke))
    model.setDocumentForTest(Document(
        layers: [Layer(children: [rect])],
        selectedLayer: 0,
        selection: [ElementSelection(path: [0, 0])]))
    return model
}

private let magicWand = "magic_wand_panel_content"
private let stroke = "stroke_panel_content"
private let gradient = "gradient_panel_content"

// MARK: - Magic Wand: the behaviors run, and the two halves stay one value

@Test func aMagicWandToleranceCommitRunsItsBehaviorAndWritesBothHalves() {
    let model = Model()
    let version = model.panelStateVersion
    let r = events(model, magicWand).commit(shipped(magicWand, "mwp_fill_tolerance"),
                                            text: "40")
    #expect(r.outcome == "committed" && r.bindWritten && r.behaviorsRun == 1,
            "outcome \(r.outcome), bind \(r.bindWritten), behaviors \(r.behaviorsRun)")
    #expect(number(model.stateStore.getPanel(magicWand, "fill_tolerance")) == 40)
    #expect(number(model.stateStore.get("magic_wand_fill_tolerance")) == 40)
    #expect(model.panelStateVersion != version, "a bound widget re-reads on the bump")
}

@Test func aMagicWandTogglePressFlipsItsFieldAndItsGlobalTogether() {
    // The app store starts with NO magic_wand_* globals: Swift never seeds
    // the bundle's `state` defaults nor runs the panel's `init:`. The flip
    // `not state.magic_wand_X` would read a null there, so the route seeds
    // each absent bound global from its field before the event.
    let ids = ["mwp_fill_color", "mwp_stroke_color", "mwp_stroke_weight",
               "mwp_opacity", "mwp_blending_mode"]
    for id in ids {
        let model = Model()
        let widget = shipped(magicWand, id)
        let key = String(((widget["bind"] as? [String: Any])?["checked"] as? String ?? "")
            .dropFirst("panel.".count))
        #expect(model.stateStore.get("magic_wand_" + key) == nil,
                "\(id): the arm needs the app's unseeded store")
        let start = model.stateStore.getPanel(magicWand, key) as? Bool
            ?? (WorkspaceData.load()?.panelStateDefaults(magicWand)[key] as? Bool)
        for expected in [!(start ?? false), start ?? false] {
            let version = model.panelStateVersion
            let r = events(model, magicWand).press(widget)
            // No bind write, so only the route's own bump re-reads the box.
            #expect(model.panelStateVersion != version, "\(id): the version moved")
            #expect(r.outcome == "committed" && !r.bindWritten && r.behaviorsRun == 1,
                    "\(id): \(r.outcome), bind \(r.bindWritten), behaviors \(r.behaviorsRun)")
            #expect(model.stateStore.getPanel(magicWand, key) as? Bool == expected,
                    "\(id): the field is \(String(describing: model.stateStore.getPanel(magicWand, key)))")
            #expect(model.stateStore.get("magic_wand_" + key) as? Bool == expected,
                    "\(id): the global is \(String(describing: model.stateStore.get("magic_wand_" + key)))")
        }
    }
}

@Test func theSeedNeverOverwritesAGlobalThatIsPresent() {
    // Only an ABSENT bound global is seeded. A present one is the truth the
    // field was hydrated from, however the two came to differ.
    let model = modelWithSelectedRect()
    model.stateStore.set("stroke_width", 5.0)
    let route = events(model, stroke)
    #expect(number(model.stateStore.getPanel(stroke, "weight")) != 5,
            "the arm needs a field that differs from the global")
    route.press(shipped(stroke, "stk_dashed"))
    #expect(number(model.stateStore.get("stroke_width")) == 5)
}

@Test func anEventWritesItsOwnPanelWhenAnotherRenderedLast() {
    // The dock pins the active panel at render, so the panel that rendered
    // LAST is active. The route pins its own before the event.
    let model = Model()
    let route = events(model, magicWand)
    _ = events(model, stroke)
    #expect(model.stateStore.getActivePanelId() == stroke)
    route.commit(shipped(magicWand, "mwp_fill_tolerance"), text: "40")
    #expect(number(model.stateStore.getPanel(magicWand, "fill_tolerance")) == 40)
    #expect(model.stateStore.getPanel(stroke, "fill_tolerance") == nil)
}

@Test func aDisabledToleranceIsRefusedAndMovesNothing() {
    let model = Model()
    _ = events(model, magicWand).press(shipped(magicWand, "mwp_fill_color"))
    let version = model.panelStateVersion
    let before = model.stateStore.getPanel(magicWand, "fill_tolerance")
    let r = events(model, magicWand).commit(shipped(magicWand, "mwp_fill_tolerance"),
                                            text: "40")
    #expect(r.outcome == "refused" && r.reason == WidgetEvent.disabled)
    #expect(number(model.stateStore.getPanel(magicWand, "fill_tolerance")) == number(before))
    #expect(model.panelStateVersion == version, "a refusal moves nothing, the version too")
}

// MARK: - The render scope decides what the person saw, and only that

@Test func theDisabledCheckReadsTheRenderScope() {
    // The store says Fill Color is on; the view showed it off. The person saw
    // a disabled box, so the commit is refused.
    let model = Model()
    let r = events(model, magicWand, panelOverlay: ["fill_color": false])
        .commit(shipped(magicWand, "mwp_fill_tolerance"), text: "40")
    #expect(model.stateStore.getPanel(magicWand, "fill_color") as? Bool == true)
    #expect(r.reason == WidgetEvent.disabled)
}

@Test func aPressNegatesTheValueTheViewShowed() {
    // A Swift panel scope can overlay live selection values the store does
    // not hold (Character, Paragraph). An undeclared toggle writes the
    // negation of what the person saw, not of the stored default.
    let model = Model()
    let widget: [String: Any] = ["type": "toggle", "bind": ["checked": "panel.x"]]
    let seen = events(model, stroke, panelOverlay: ["x": true])
    model.stateStore.setPanel(stroke, "x", false)
    let r = seen.press(widget)
    #expect(r.outcome == "committed" && r.bindWritten)
    #expect(model.stateStore.getPanel(stroke, "x") as? Bool == false)
}

@Test func aStaleRenderScopeDoesNotShadowTheStoreInABehavior() {
    // The scope is taken before the commit and still says start=100. The
    // linked mirror copies panel.start_arrowhead_scale, which must be the
    // NEW value: behaviors read the store, never the scope's namespaces.
    let model = Model()
    model.stateStore.initPanel(stroke,
                               defaults: WorkspaceData.load()?.panelStateDefaults(stroke) ?? [:])
    model.stateStore.setPanel(stroke, "link_arrowhead_scale", true)
    let stale = events(model, stroke)
    #expect(number((stale.scope["panel"] as? [String: Any])?["start_arrowhead_scale"]) != 200)
    stale.commit(shipped(stroke, "stk_start_arrowhead_scale"), text: "200")
    #expect(number(model.stateStore.getPanel(stroke, "end_arrowhead_scale")) == 200)
    #expect(number(model.stateStore.get("stroke_end_arrowhead_scale")) == 200)
}

// MARK: - Stroke: the panel-write host fires on the bind write

@Test func aStrokeWeightCommitReachesTheSelection() {
    let model = modelWithSelectedRect()
    let r = events(model, stroke).commit(shipped(stroke, "stk_weight"), text: "3 in")
    #expect(r.outcome == "committed" && r.bindWritten)
    #expect(model.document.getElement([0, 0]).stroke?.width == 216)
    #expect(number(model.stateStore.get("stroke_width")) == 216,
            "the two-way bound global is written with the field")
}

@Test func aLinkedScaleCommitMirrorsTheSiblingOntoTheSelection() {
    // Ported from StrokeBehaviorTests' runInputCommitBehavior arm (e), which
    // the view no longer calls: the mirror's set / set_panel_state name the
    // sibling's key, and that key's own group reaches the element.
    let model = modelWithSelectedRect()
    let open = events(model, stroke)
    model.stateStore.setPanel(stroke, "link_arrowhead_scale", true)
    open.commit(shipped(stroke, "stk_start_arrowhead_scale"), text: "200")
    let s = model.document.getElement([0, 0]).stroke
    #expect(s?.startArrowScale == 200)
    #expect(s?.endArrowScale == 200)
    #expect(model.stateStore.getPanel(stroke, "link_arrowhead_scale") as? Bool == true,
            "the mirror never clobbers the chain flag")
}

@Test func aLinkedEndScaleCommitMirrorsOntoTheStartScale() {
    // The symmetric partner: the end combo's own mirror, in both scopes.
    let model = modelWithSelectedRect()
    let open = events(model, stroke)
    model.stateStore.setPanel(stroke, "link_arrowhead_scale", true)
    open.commit(shipped(stroke, "stk_end_arrowhead_scale"), text: "75")
    #expect(number(model.stateStore.getPanel(stroke, "start_arrowhead_scale")) == 75)
    #expect(number(model.stateStore.get("stroke_start_arrowhead_scale")) == 75)
    #expect(model.document.getElement([0, 0]).stroke?.startArrowScale == 75)
}

@Test func anUnlinkedScaleCommitLeavesTheSiblingAlone() {
    let model = modelWithSelectedRect()
    let open = events(model, stroke)
    model.stateStore.setPanel(stroke, "link_arrowhead_scale", false)
    let r = open.commit(shipped(stroke, "stk_end_arrowhead_scale"), text: "75")
    #expect(r.outcome == "committed" && r.behaviorsRun == 1,
            "the behavior ran; its `if` found the chain off")
    let s = model.document.getElement([0, 0]).stroke
    #expect(s?.endArrowScale == 75)
    #expect(s?.startArrowScale == 100)
    #expect(number(model.stateStore.get("stroke_start_arrowhead_scale")) != 75)
}

@Test func theDashedCheckboxFlipsOnceBothWays() {
    let model = modelWithSelectedRect()
    for expected in [true, false] {
        let r = events(model, stroke).press(shipped(stroke, "stk_dashed"))
        #expect(r.outcome == "committed" && !r.bindWritten && r.behaviorsRun == 1)
        #expect(model.stateStore.getPanel(stroke, "dashed") as? Bool == expected)
        #expect(model.stateStore.get("stroke_dashed") as? Bool == expected)
    }
}

// MARK: - Gradient: the change behaviors reach the selection

@Test func aGradientAngleCommitAppliesToTheSelection() {
    let model = modelWithSelectedRect(stroke: nil)
    let r = events(model, gradient).commit(shipped(gradient, "grad_angle_combo"), text: "45")
    #expect(r.outcome == "committed" && r.bindWritten && r.behaviorsRun == 1)
    #expect(number(model.stateStore.getPanel(gradient, "angle")) == 45)
    #expect(model.document.getElement([0, 0]).fillGradient?.angle == 45,
            "fill gradient: \(String(describing: model.document.getElement([0, 0]).fillGradient))")
}

@Test func aGradientAngleCommitIsClampedToItsDeclaredBounds() {
    let model = Model()
    let r = events(model, gradient).commit(shipped(gradient, "grad_angle_combo"), text: "500")
    #expect(number(r.value) == 180)
    #expect(number(model.stateStore.get("gradient_angle")) == 180)
}

@Test func theGradientDitherPressFlipsTheBox() {
    let model = modelWithSelectedRect(stroke: nil)
    for expected in [true, false] {
        let r = events(model, gradient).press(shipped(gradient, "grad_dither_checkbox"))
        #expect(r.outcome == "committed" && !r.bindWritten && r.behaviorsRun == 1)
        #expect(model.stateStore.getPanel(gradient, "dither") as? Bool == expected)
        #expect(model.document.getElement([0, 0]).fillGradient?.dither == expected)
    }
}

// MARK: - Concepts: a foreach item reaches the native dispatch

@Test func aConceptParamCommitDispatchesNativelyWithItsItem() {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let model = Model(document: Document(
        layers: [Layer(name: "L", children: [rect])], selectedLayer: 0, selection: []))
    let concepts = "concepts_panel_content"
    model.stateStore.initPanel(concepts, defaults: [:])
    model.stateStore.setPanel(concepts, "selected_concept", "regular_polygon")
    ConceptsPanel.dispatch("place_concept_instance", model: model)
    guard case .live(.generated) = model.document.tryGetElement([0, 1]) else {
        Issue.record("the arm needs a placed, selected Generated at [0,1]"); return
    }
    // The shipped param editor: a number_input inside `foreach … as: p`, bound
    // to the item (`p.value`, not writable) with a `change` behavior whose
    // params read `p.name` and `event.value`.
    let editor: [String: Any] = {
        func find(_ node: Any?) -> [String: Any]? {
            if let d = node as? [String: Any] {
                if d["type"] as? String == "number_input",
                   (d["bind"] as? [String: Any])?["value"] as? String == "p.value" { return d }
                for v in d.values { if let f = find(v) { return f } }
            } else if let l = node as? [Any] {
                for v in l { if let f = find(v) { return f } }
            }
            return nil
        }
        return find(WorkspaceData.load()?.panel(concepts)?["content"]) ?? [:]
    }()
    #expect(!editor.isEmpty, "the shipped concepts param editor")
    var route = events(model, concepts)
    route.scope["p"] = ["name": "sides", "value": 6, "min": 3, "max": 12] as [String: Any]
    let r = route.commit(editor, text: "8")
    #expect(r.outcome == "committed" && !r.bindWritten && r.behaviorsRun == 1)
    let live = documentToTestJson(model.document)
    #expect(live.contains("\"sides\":8.0"), "set_concept_param tuned sides to 8: \(live)")
}

// MARK: - Dialogs and Character: the app's write host

@Test func aDialogBindWritesThroughTheOverlayClosure() {
    let model = Model()
    var written: [(String, String)] = []
    let route = PanelWidgetEvents(
        model: model, panelId: nil, scope: [:],
        onDialogWrite: { k, v in written.append((k, "\(v ?? "nil")")) })
    let widget: [String: Any] = [
        "type": "select", "bind": ["value": "dialog.k"],
        "options": [["value": "a"], ["value": "b"]],
    ]
    let r = route.commit(widget, text: "b")
    #expect(r.outcome == "committed" && r.bindWritten)
    #expect(written.count == 1 && written.first?.0 == "k" && written.first?.1 == "b",
            "writes: \(written)")
}

@Test func aBehaviorThatClosesTheDialogClosesTheOverlay() {
    let model = Model()
    model.stateStore.initDialog("d", defaults: ["k": "a"])
    var closed = 0
    let route = PanelWidgetEvents(model: model, panelId: nil, scope: [:],
                                  onDialogWrite: { k, v in model.stateStore.setDialog(k, v) },
                                  onDialogClosed: { closed += 1 })
    let widget: [String: Any] = [
        "type": "select", "bind": ["value": "dialog.k"],
        "options": [["value": "a"], ["value": "b"]],
        "behavior": [["event": "change", "effects": [["close_dialog": NSNull()]]]],
    ]
    let r = route.commit(widget, text: "b")
    #expect(r.behaviorsRun == 1 && model.stateStore.getDialogId() == nil)
    #expect(closed == 1, "the overlay heard the store close the dialog")
}

@Test func clearingCharacterLeadingWritesTheAutoValue() {
    let model = Model()
    let character = "character_panel_content"
    let route = events(model, character)
    model.stateStore.setPanel(character, "font_size", 20.0)
    let r = route.commit(shipped(character, "ch_leading"), text: "  ")
    #expect(r.outcome == "committed" && r.bindWritten && r.value == nil)
    #expect(number(model.stateStore.getPanel(character, "leading")) == 24,
            "font_size 20 x 1.2, with no text selected to read it from")
}

// MARK: - The headless host seam

@Test func aHostWriteReceivesTheFieldAndItsBoundGlobal() {
    let store = StateStore()
    store.initPanel("p", defaults: ["f": 1.0])
    store.setActivePanel("p")
    var calls: [String] = []
    let host = WidgetEvent.Host(writeBind: { scope, key, value, global in
        calls.append("\(scope).\(key)=\(value ?? "nil") global=\(global ?? "nil")")
    })
    let widget: [String: Any] = ["type": "number_input", "bind": ["value": "panel.f"]]
    let panel: [String: Any] = ["init": ["f": "state.g"]]
    let r = WidgetEvent.commit(widget: widget, text: "7", store: store, panel: panel, host: host)
    #expect(r.bindWritten)
    #expect(calls == ["panel.f=7.0 global=g"], "calls: \(calls)")
    #expect(number(store.getPanel("p", "f")) == 1, "the host owns the write")
    #expect(store.get("g") == nil)
}

@Test func aHostDispatchReceivesEvaluatedParamsAndTheScopesOwnNames() {
    let store = StateStore()
    store.initPanel("p", defaults: ["f": 1.0])
    store.setActivePanel("p")
    var got: [(String, [String: Any], [String: Any])] = []
    let host = WidgetEvent.Host(
        scope: ["item": ["name": "n1"], "panel": ["f": 99.0]],
        dispatch: { a, p, c in got.append((a, p, c)) })
    let widget: [String: Any] = [
        "type": "number_input", "bind": ["value": "panel.f"],
        "behavior": [["event": "commit", "action": "act",
                      "params": ["name": "item.name", "now": "panel.f",
                                 "v": "event.value", "gone": "nothing.here"]]],
    ]
    let r = WidgetEvent.commit(widget: widget, text: "5", store: store, panel: nil, host: host)
    #expect(r.behaviorsRun == 1 && got.count == 1)
    guard let (action, params, ctx) = got.first else { return }
    #expect(action == "act")
    #expect(params["name"] as? String == "n1", "a scope name reaches the params")
    #expect(number(params["now"]) == 5, "the store, not the scope's stale panel")
    #expect(number(params["v"]) == 5)
    #expect(params["gone"] is NSNull, "a null param stays a null: \(params)")
    #expect(ctx["panel"] == nil && ctx["item"] != nil && ctx["event"] != nil,
            "ctx keys: \(ctx.keys.sorted())")
}

// MARK: - The Layers type filter's pick (the bank's §1.3)

// The menu used to compute the next checked set natively, and SORTED it. The
// declared route (`list_toggle`, WIDGET_EVENTS.md "Picking a dropdown item")
// APPENDS, so the two stores disagreed on order from the first pick. These
// drive the shipped widget through the app's route, as the menu now does.

private func filterAfter(_ picks: [(String, Bool)], from initial: [String]) -> [String]? {
    let model = Model()
    let route = events(model, "layers_panel_content")
    model.stateStore.setPanel("layers_panel_content", "type_filter", initial)
    let widget = shipped("layers_panel_content", "lp_filter_button")
    for (value, alt) in picks {
        let r = route.pick(widget, value: value, alt: alt)
        #expect(r.outcome == "committed", "\(value) alt=\(alt): \(r.outcome) \(r.reason ?? "")")
    }
    return model.stateStore.getPanel("layers_panel_content", "type_filter") as? [String]
}

@Test func aPlainPickTogglesByTheDeclaredRouteAndKeepsItsOrder() {
    #expect(filterAfter([("circle", false)], from: ["path"]) == ["path", "circle"],
            "appended, not sorted")
    #expect(filterAfter([("path", false)], from: ["path", "text"]) == ["text"])
}

@Test func anAltPickSolosAndASecondRestoresEverything() {
    #expect(filterAfter([("text", true)], from: ["path", "circle"]) == ["text"])
    #expect(filterAfter([("text", true), ("text", true)], from: ["path"]) == [])
}

@Test func theAllItemRunsItsOwnActionAndClearsTheFilter() {
    #expect(filterAfter([("__all__", false)], from: ["path", "circle"]) == [])
}

@Test func anItemsCheckIsItsValueInTheDeclaredList() {
    let widget = shipped("layers_panel_content", "lp_filter_button")
    let scope: [String: Any] = ["panel": ["type_filter": ["path", "text"]]]
    #expect(WidgetEvent.itemChecked(widget: widget, value: "path", scope: scope) == true)
    #expect(WidgetEvent.itemChecked(widget: widget, value: "circle", scope: scope) == false)
    // No declared list: the check is UNKNOWN, not unchecked.
    #expect(WidgetEvent.itemChecked(widget: ["type": "dropdown"], value: "path", scope: scope) == nil)
    #expect(WidgetEvent.itemChecked(widget: widget, value: "path", scope: ["panel": [:]]) == nil)
}
