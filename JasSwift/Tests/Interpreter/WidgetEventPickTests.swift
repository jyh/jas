import Foundation
import Testing
@testable import JasLib

// WIDGET_EVENTS.md, "Picking a dropdown item", and `list_toggle`, row for row
// with the reference's `TestPickSynthetic` / `TestShippedLayersFilter`
// (test_widget_event.py) and `TestListToggleEffect` (test_effects.py).

private func dropdown(behavior: [[String: Any]]? = nil, bind: [String: Any]? = nil) -> [String: Any] {
    var w: [String: Any] = [
        "type": "dropdown", "id": "dd",
        "items": [
            ["label": "All", "value": "__all__", "type": "action", "action": "act_all"],
            "separator",
            ["label": "A", "value": "a", "type": "toggle"],
            ["label": "B", "value": "b", "type": "toggle"],
        ] as [Any],
        "behavior": behavior ?? [
            ["event": "toggle",
             "effects": [["set": ["picked": "item.value"]], ["set": ["ev": "event.value"]]]],
            ["event": "alt_toggle", "effects": [["set": ["alt_picked": "item.label"]]]],
        ],
    ]
    if let bind = bind { w["bind"] = bind }
    return w
}

private let actions: [String: Any] = ["act_all": ["effects": [["set": ["all_ran": "true"]]]]]

private func pick(_ value: String?, _ event: String = "toggle",
                  widget: [String: Any] = dropdown(), store: StateStore) -> WidgetEvent.Result {
    WidgetEvent.pick(widget: widget, itemValue: value, event: event, store: store, panel: nil,
                     actions: actions)
}

@Test func aToggleItemRunsTheEventsBehaviorsWithItemBound() {
    let store = StateStore()
    let r = pick("b", store: store)
    #expect(r.outcome == "committed" && r.behaviorsRun == 1)
    #expect(store.get("picked") as? String == "b")
    #expect(store.get("ev") as? String == "b", "event.value is the item's value")
    #expect(store.get("alt_picked") == nil, "only the requested event runs")
}

@Test func altToggleRunsOnlyItsOwnBehaviorsWithTheWholeItem() {
    let store = StateStore()
    let r = pick("a", "alt_toggle", store: store)
    #expect(r.behaviorsRun == 1)
    #expect(store.get("alt_picked") as? String == "A", "the WHOLE item is bound")
    #expect(store.get("picked") == nil)
}

@Test func anActionItemRunsItsOwnActionAndNoBehavior() {
    let store = StateStore()
    let r = pick("__all__", store: store)
    #expect(r.outcome == "committed" && r.behaviorsRun == 0)
    #expect(store.get("all_ran") as? Bool == true)
    #expect(store.get("picked") == nil)
}

@Test func aPickRefusesByName() {
    let rows: [(String, String?, String, [String: Any], String)] = [
        ("no item named", nil, "toggle", dropdown(), WidgetEvent.missingValue),
        ("an undeclared item", "c", "toggle", dropdown(), WidgetEvent.badValue),
        ("a separator is not an item", "separator", "toggle", dropdown(), WidgetEvent.badValue),
        ("an event outside the table", "a", "click", dropdown(), WidgetEvent.wrongEvent),
        ("not a dropdown", "a", "toggle", ["type": "select", "items": [] as [Any]], WidgetEvent.wrongKind),
        ("disabled", "a", "toggle", dropdown(bind: ["disabled": "true"]), WidgetEvent.disabled),
    ]
    for (name, value, event, widget, reason) in rows {
        let store = StateStore()
        let r = pick(value, event, widget: widget, store: store)
        #expect(r.outcome == "refused" && r.reason == reason, "\(name): \(r)")
        #expect(store.get("picked") == nil, "\(name): a refusal writes nothing")
    }
}

@Test func anItemWithNoDeclaredBehaviorIsInert() {
    #expect(pick("a", widget: dropdown(behavior: []), store: StateStore()).outcome == "inert")
}

// ── The shipped Layers type filter ──

private func layersFilter(_ value: String, _ event: String = "toggle",
                          initial: [String]? = nil) -> (WidgetEvent.Result, [String]?) {
    let ws = WorkspaceData.load()!
    let panelId = "layers_panel_content"
    let panel = ws.panel(panelId)!
    let widget = WidgetEvent.findWidget(in: panel["content"], id: "lp_filter_button")!
    let store = StateStore()
    store.initPanel(panelId, defaults: ws.panelStateDefaults(panelId))
    store.setActivePanel(panelId)
    if let initial = initial { store.setPanel(panelId, "type_filter", initial) }
    let r = WidgetEvent.pick(widget: widget, itemValue: value, event: event, store: store,
                             panel: panel, actions: ws.actions())
    return (r, store.getPanel(panelId, "type_filter") as? [String])
}

@Test func theShippedLayersFilterPicks() {
    #expect(layersFilter("path").1 == ["path"], "the TYPE, never null")
    #expect(layersFilter("path", initial: ["path", "text"]).1 == ["text"])
    #expect(layersFilter("circle", "alt_toggle", initial: ["path", "text"]).1 == ["circle"])
    let (r, tf) = layersFilter("__all__", initial: ["path", "text"])
    #expect(r.outcome == "committed" && tf == [])
}

// ── list_toggle ──

private func toggled(_ initial: Any?, _ value: String, active: Bool = true,
                     target: String = "panel.type_filter",
                     ctx: [String: Any] = [:]) -> Any? {
    let store = StateStore()
    store.initPanel("layers", defaults: initial.map { ["type_filter": $0] } ?? [:])
    if active { store.setActivePanel("layers") }
    runEffects([["list_toggle": ["target": target, "value": value]]], ctx: ctx, store: store)
    return store.getPanel("layers", "type_filter")
}

@Test func listToggleMatchesTheReferenceRowForRow() {
    #expect(toggled(["path", "rect"], "\"text\"") as? [String] == ["path", "rect", "text"],
            "absent: appended at the end")
    #expect(toggled(["path", "rect", "text"], "\"rect\"") as? [String] == ["path", "text"],
            "present: removed, order kept")
    #expect(toggled(["path", "rect", "path"], "\"path\"") as? [String] == ["rect", "path"],
            "only the FIRST occurrence is removed")
    #expect(toggled(nil, "\"path\"") as? [String] == ["path"], "a missing key starts an empty list")
    #expect(toggled("path", "\"rect\"") as? [String] == ["rect"], "a non-list value is replaced")
    #expect(toggled([String](), "param.t", ctx: ["param": ["t": "group"]]) as? [String] == ["group"],
            "the value is an expression")
    #expect(toggled(["path"], "\"rect\"", active: false) as? [String] == ["path"],
            "no active panel: no-op")
    #expect(toggled(["path"], "\"rect\"", target: "state.type_filter") as? [String] == ["path"],
            "a target outside panel: no-op")
}
