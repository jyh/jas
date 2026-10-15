import Foundation
import Testing
@testable import JasLib

// WIDGET_EVENTS.md, "Checking a radio" and "Picking a radio option", row for
// row with the reference's `TestCheckSynthetic` / `TestChooseSynthetic`
// (test_widget_event.py).

private func radio(_ extra: [String: Any] = [:]) -> [String: Any] {
    var w: [String: Any] = [
        "type": "radio", "bind": ["checked": "dialog.axis == 'v'"],
        "on_check": [["set": ["dialog.axis": "'v'"]]],
    ]
    for (k, v) in extra { w[k] = v }
    return w
}

private func dialogStore(_ fields: [String: Any]) -> StateStore {
    let store = StateStore()
    store.initDialog("d", defaults: fields)
    return store
}

@Test func onCheckIsTheCheckAndTheComparisonIsNotWritten() {
    let store = dialogStore(["axis": "h", "n": 0])
    let r = WidgetEvent.check(widget: radio(), store: store, panel: nil)
    #expect(r.outcome == "committed" && r.behaviorsRun == 1 && !r.bindWritten)
    #expect(r.value as? Bool == true)
    #expect(store.getDialog("axis") as? String == "v")
}

@Test func aCheckedRadioIsInertAndNeverUnchecks() {
    let store = dialogStore(["axis": "v", "n": 0])
    let r = WidgetEvent.check(widget: radio(["on_check": [["set": ["dialog.n": "dialog.n + 1"]]]]),
                              store: store, panel: nil)
    #expect(r.outcome == "inert")
    #expect((store.getDialog("n") as? NSNumber)?.intValue == 0, "on_check did not run")
}

@Test func aDisabledRadioMovesNothing() {
    let store = dialogStore(["axis": "h"])
    let r = WidgetEvent.check(widget: radio(["bind": ["checked": "dialog.axis == 'v'", "disabled": "true"]]),
                              store: store, panel: nil)
    #expect(r.outcome == "refused" && r.reason == WidgetEvent.disabled)
    #expect(store.getDialog("axis") as? String == "h")
}

@Test func noOnCheckWritesTrueToAWritableBind() {
    let store = dialogStore(["on": false])
    let r = WidgetEvent.check(widget: ["type": "radio", "bind": ["checked": "dialog.on"]],
                              store: store, panel: nil)
    #expect(r.outcome == "committed" && r.bindWritten)
    #expect(store.getDialog("on") as? Bool == true)
}

@Test func noOnCheckAndNoWritableBindIsInert() {
    let store = dialogStore(["axis": "h"])
    let r = WidgetEvent.check(widget: ["type": "radio", "bind": ["checked": "dialog.axis == 'v'"]],
                              store: store, panel: nil)
    #expect(r.outcome == "inert")
    #expect(store.getDialog("axis") as? String == "h")
}

@Test func declaredPressBehaviorsRunAfterOnCheck() {
    let store = dialogStore(["axis": "h", "n": 0])
    let w = radio(["behavior": [
        ["event": "click", "effects": [["set": ["dialog.n": "dialog.axis == 'v'"]]]],
        ["event": "alt_toggle", "effects": [["set": ["dialog.n": 99]]]],
    ] as [Any]])
    let r = WidgetEvent.check(widget: w, store: store, panel: nil)
    #expect(r.outcome == "committed" && r.behaviorsRun == 2)
    #expect(store.getDialog("n") as? Bool == true, "the behavior read the axis on_check wrote")
}

@Test func checkRefusesEveryOtherKindAndPressRefusesARadio() {
    let store = dialogStore(["on": false])
    for kind in ["toggle", "checkbox", "radio_group", "dropdown", "number_input"] {
        let r = WidgetEvent.check(widget: ["type": kind, "bind": ["checked": "dialog.on"]],
                                  store: store, panel: nil)
        #expect(r.outcome == "refused" && r.reason == WidgetEvent.wrongKind, "\(kind)")
    }
    #expect(WidgetEvent.press(widget: radio(), store: store, panel: nil).reason == WidgetEvent.wrongKind)
}

private func group(_ extra: [String: Any] = [:]) -> [String: Any] {
    var w: [String: Any] = [
        "type": "radio_group", "bind": "dialog.channel",
        "options": [["id": "h", "label": ""], ["id": "s", "label": ""]] as [Any],
    ]
    for (k, v) in extra { w[k] = v }
    return w
}

private func choose(_ id: String?, _ event: String = "toggle", widget: [String: Any] = group(),
                    store: StateStore) -> WidgetEvent.Result {
    WidgetEvent.choose(widget: widget, optionId: id, event: event, store: store, panel: nil)
}

@Test func aPickWritesTheOptionsId() {
    let store = dialogStore(["channel": "h", "n": 0])
    let r = choose("s", store: store)
    #expect(r.outcome == "committed" && r.bindWritten && r.value as? String == "s")
    #expect(store.getDialog("channel") as? String == "s")
}

@Test func theCheckedOptionIsInert() {
    let store = dialogStore(["channel": "h"])
    #expect(choose("h", store: store).outcome == "inert")
}

@Test func theComparisonIsAsTextAndAWholeNumberMatchesItsIntegerId() {
    // 2.0, the value a Swift Double holds: "\(2.0)" is "2.0", so without the
    // whole-number rule the id "2" would never match.
    let store = dialogStore(["channel": 2.0])
    let w = group(["options": [["id": "2"], ["id": "3"]] as [Any]])
    #expect(choose("2", widget: w, store: store).outcome == "inert")
    #expect(choose("3", widget: w, store: store).outcome == "committed")
    #expect(store.getDialog("channel") as? String == "3", "the id is written as a string")
}

@Test func choiceRefusalsMoveNothing() {
    for (value, event, reason) in [("s", "change", WidgetEvent.wrongEvent),
                                   (nil, "toggle", WidgetEvent.missingValue),
                                   ("x", "toggle", WidgetEvent.badValue)] as [(String?, String, String)] {
        let store = dialogStore(["channel": "h"])
        let r = choose(value, event, store: store)
        #expect(r.outcome == "refused" && r.reason == reason, "\(String(describing: value)) \(event)")
        #expect(store.getDialog("channel") as? String == "h")
    }
    for (disabled, outcome) in [("true", "refused"), ("false", "committed")] {
        let store = dialogStore(["channel": "h"])
        let w = group(["bind": ["value": "dialog.channel", "disabled": disabled]])
        #expect(choose("s", widget: w, store: store).outcome == outcome, "\(disabled)")
    }
}

@Test func toggleBehaviorsRunAfterTheWrite() {
    let store = dialogStore(["channel": "h", "n": 0])
    let w = group(["behavior": [["event": "toggle",
                                 "effects": [["set": ["dialog.n": "event.value"]]]]] as [Any]])
    let r = choose("s", widget: w, store: store)
    #expect(r.outcome == "committed" && r.bindWritten && r.behaviorsRun == 1)
    #expect(store.getDialog("n") as? String == "s")
}

@Test func chooseRefusesEveryOtherKind() {
    let store = dialogStore(["channel": "h"])
    for kind in ["radio", "dropdown", "select"] {
        let r = choose("s", widget: group(["type": kind]), store: store)
        #expect(r.outcome == "refused" && r.reason == WidgetEvent.wrongKind, "\(kind)")
    }
}

// The view's `change` loop honours a behavior's `condition`, driven on the
// SHIPPED orientation group, as Rust's
// `a_value_loop_honours_the_shipped_orientation_condition`.
@Test func aViewChangeLoopHonoursTheShippedOrientationCondition() throws {
    let ws = try #require(WorkspaceData.load())
    let dialogs = try #require(ws.data["dialogs"] as? [String: Any])
    let group = try #require(WidgetEvent.findWidget(in: dialogs["artboard_options"], id: "ao_orientation"))
    let b = try #require((group["behavior"] as? [[String: Any]])?.first)
    #expect(b["condition"] != nil, "the control: the shipped behavior is guarded")
    let ctx = { (v: String) -> [String: Any] in
        ["dialog": ["width": 100, "height": 200], "event": ["value": v]] }
    #expect(!behaviorConditionHolds(b, context: ctx("portrait")), "the shown orientation does not toggle")
    #expect(behaviorConditionHolds(b, context: ctx("landscape")), "the other orientation toggles")
    #expect(behaviorConditionHolds(["action": "x"], context: ctx("portrait")), "no condition: it runs")
}

// Artboard Options' orientation group is an input kind: a commit is the
// option's value text, as the reference's `test_icon_button_group_is_a_select`.
@Test func anIconButtonGroupIsASelect() {
    let w: [String: Any] = ["type": "icon_button_group", "options": [
        ["icon": "orientation_portrait", "value": "portrait"],
        ["icon": "orientation_landscape", "value": "landscape"]] as [Any]]
    #expect(WidgetEvent.parseCommit(widget: w, text: "landscape").accepted)
    #expect(WidgetEvent.parseCommit(widget: w, text: "landscape").value as? String == "landscape")
    #expect(!WidgetEvent.parseCommit(widget: w, text: "square").accepted)
}

// The KIND owns its nine anchors, as the reference's
// `test_reference_point_widget_takes_one_of_its_nine_anchors`.
@Test func aReferencePointWidgetTakesOneOfItsNineAnchors() {
    #expect(WidgetEvent.referencePointAnchors == ["top_left", "top_center", "top_right", "middle_left",
        "center", "middle_right", "bottom_left", "bottom_center", "bottom_right"])
    let w: [String: Any] = ["type": "reference_point_widget", "bind": ["value": "panel.rp"]]
    for a in WidgetEvent.referencePointAnchors {
        #expect(WidgetEvent.parseCommit(widget: w, text: a).value as? String == a)
    }
    for t in ["", "Center", "middle_center", " center"] {
        #expect(!WidgetEvent.parseCommit(widget: w, text: t).accepted, "\(t)")
    }
}
