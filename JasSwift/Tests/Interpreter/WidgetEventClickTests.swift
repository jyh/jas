import Foundation
import Testing
@testable import JasLib

// WIDGET_EVENTS.md, "Clicking a button": a declared `click` behavior IS the
// click, so a node-level `action` runs only when none is declared, even when
// every declared behavior's condition would skip it. The reference's
// `TestClickSynthetic` (test_widget_event.py) holds the whole procedure; this
// file holds the one rule the view's click handler consults.

private func button(_ extra: [String: Any] = [:]) -> [String: Any] {
    var w: [String: Any] = ["type": "button", "action": "rec", "params": ["n": "dialog.n"]]
    for (k, v) in extra { w[k] = v }
    return w
}

@Test func aNodeActionRunsWhenNoClickBehaviorIsDeclared() {
    #expect(WidgetEvent.clickRunsNodeAction(button()))
    #expect(WidgetEvent.clickRunsNodeAction(button(["type": "icon_button"])))
}

@Test func aDeclaredClickBehaviorOwnsTheClickEvenWhenSkipped() {
    let skipped: [[String: Any]] = [["event": "click", "condition": "false",
                                     "effects": [["set": ["dialog.n": 1]]]]]
    #expect(!WidgetEvent.clickRunsNodeAction(button(["behavior": skipped])))
}

@Test func aPointerBehaviorIsNotAClick() {
    let held: [[String: Any]] = [["event": "mouse_down", "effects": [["set": ["dialog.n": 1]]]]]
    #expect(WidgetEvent.clickRunsNodeAction(button(["behavior": held])))
}

@Test func noNodeActionRunsNothing() {
    #expect(!WidgetEvent.clickRunsNodeAction(["type": "button", "label": "x"]))
}

@Test func onlyAClickKindRunsANodeAction() {
    for kind in ["toggle", "radio", "dropdown", "number_input", "submenu"] {
        #expect(!WidgetEvent.clickRunsNodeAction(button(["type": kind])), "\(kind)")
    }
}

@Test func theClickKindsMatchTheReference() {
    #expect(WidgetEvent.clickKinds == ["button", "icon_button"])
    #expect(WidgetEvent.clickEvents == ["click"])
}

// MARK: - The click procedure (the reference's `TestClickSynthetic`)
//
// `WidgetEvent.click` is the reference's `click` (widget_event.py): refuse a
// wrong kind, a wrong event and a disabled widget; a declared `click`
// behavior IS the click; else the node-level `action` runs with its params;
// `event` is the four modifiers, each false when absent, and no value.

private let recordActions: [String: Any] = ["record": ["effects": [
    ["set": ["got_n": "param.n", "got_copy": "param.copy",
             "got_target": "param.target", "got_alt": "event.alt"]]]]]

private func clickStore(_ n: Int = 7) -> StateStore {
    let store = StateStore()
    store.initDialog("d", defaults: ["n": n, "hits": 0])
    return store
}

private func recordButton(_ extra: [String: Any] = [:]) -> [String: Any] {
    var w: [String: Any] = ["type": "button", "action": "record",
                            "params": ["n": "dialog.n", "copy": false, "target": "artboard"]]
    for (k, v) in extra { w[k] = v }
    return w
}

private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

@Test func clickANodeActionDispatchesWithItsParamsResolved() {
    let store = clickStore()
    let r = WidgetEvent.click(widget: recordButton(), event: "click", store: store,
                              panel: nil, actions: recordActions)
    #expect(r.outcome == "committed" && r.behaviorsRun == 1)
    #expect(num(store.get("got_n")) == 7, "a string param is an expression")
    #expect(store.get("got_copy") as? Bool == false, "a YAML literal is that value")
    #expect(store.get("got_target") as? String == "artboard", "a bare null identifier is its name")
}

@Test func clickAnIconButtonIsAClickKindToo() {
    let store = clickStore()
    let w: [String: Any] = ["type": "icon_button", "action": "record", "params": ["n": "dialog.n"]]
    #expect(WidgetEvent.click(widget: w, event: "click", store: store, panel: nil,
                              actions: recordActions).outcome == "committed")
    #expect(num(store.get("got_n")) == 7)
}

@Test func clickDeclaredBehaviorsAreTheClickAndTheActionDoesNotRun() {
    let store = clickStore()
    let w = recordButton(["behavior": [
        ["event": "click", "effects": [["set": ["dialog.hits": "dialog.hits + 1"]]]],
        ["event": "click", "effects": [["set": ["dialog.hits": "dialog.hits + 10"]]]]]])
    let r = WidgetEvent.click(widget: w, event: "click", store: store, panel: nil,
                              actions: recordActions)
    #expect(r.outcome == "committed" && r.behaviorsRun == 2)
    #expect(num(store.getDialog("hits")) == 11, "both ran, in order")
    #expect(store.get("got_n") == nil, "the node action did not run")
}

@Test func clickABehaviorSkippedByItsConditionStillOwnsTheClick() {
    let store = clickStore()
    let w = recordButton(["behavior": [["event": "click", "condition": "event.alt",
                                        "effects": [["set": ["dialog.hits": 1]]]]]])
    let r = WidgetEvent.click(widget: w, event: "click", store: store, panel: nil,
                              actions: recordActions)
    #expect(r.outcome == "inert" && r.behaviorsRun == 0)
    #expect(num(store.getDialog("hits")) == 0 && store.get("got_n") == nil)
}

@Test func clickEventCarriesTheModifiersAndNoValue() {
    let store = clickStore()
    let w = recordButton(["behavior": [["event": "click", "condition": "event.alt",
                                        "effects": [["set": ["dialog.hits": "event.shift"]]]]]])
    let r = WidgetEvent.click(widget: w, event: "click", store: store, panel: nil,
                              modifiers: ["alt": true, "shift": true], actions: recordActions)
    #expect(r.outcome == "committed" && store.getDialog("hits") as? Bool == true)
    #expect(WidgetEvent.click(widget: recordButton(), event: "click", store: clickStore(),
                              panel: nil, modifiers: ["alt": true]).value == nil)
}

@Test func clickAbsentModifiersReadFalseNotNull() {
    let store = clickStore()
    WidgetEvent.click(widget: recordButton(), event: "click", store: store, panel: nil,
                      actions: recordActions)
    #expect(store.get("got_alt") as? Bool == false)
}

@Test func clickANodeActionSeesTheModifiers() {
    let store = clickStore()
    WidgetEvent.click(widget: recordButton(), event: "click", store: store, panel: nil,
                      modifiers: ["alt": true], actions: recordActions)
    #expect(store.get("got_alt") as? Bool == true)
}

@Test func clickMouseDownBehaviorsAreNotAClick() {
    let store = clickStore()
    let w: [String: Any] = ["type": "icon_button", "behavior": [
        ["event": "mouse_down", "effects": [["set": ["dialog.hits": 1]]]]]]
    #expect(WidgetEvent.click(widget: w, event: "click", store: store, panel: nil).outcome == "inert")
    #expect(num(store.getDialog("hits")) == 0)
}

@Test func clickNothingDeclaredIsInert() {
    #expect(WidgetEvent.click(widget: ["type": "button", "label": "x"], event: "click",
                              store: clickStore(), panel: nil).outcome == "inert")
}

@Test func clickADisabledButtonRunsNothing() {
    let store = clickStore()
    let r = WidgetEvent.click(widget: recordButton(["bind": ["disabled": "dialog.n > 5"]]),
                              event: "click", store: store, panel: nil, actions: recordActions)
    #expect(r.outcome == "refused" && r.reason == WidgetEvent.disabled)
    #expect(store.get("got_n") == nil)
}

@Test func clickOnlyClickIsAClick() {
    let store = clickStore()
    for event in ["mouse_down", "mouse_up", "change", "commit", "toggle"] {
        let r = WidgetEvent.click(widget: recordButton(), event: event, store: store,
                                  panel: nil, actions: recordActions)
        #expect(r.outcome == "refused" && r.reason == WidgetEvent.wrongEvent, "\(event)")
    }
    #expect(store.get("got_n") == nil)
}

@Test func clickRefusesEveryOtherKind() {
    let store = clickStore()
    for kind in ["toggle", "checkbox", "radio", "dropdown", "number_input", "text"] {
        let w: [String: Any] = ["type": kind, "action": "record", "params": ["n": "dialog.n"]]
        let r = WidgetEvent.click(widget: w, event: "click", store: store, panel: nil,
                                  actions: recordActions)
        #expect(r.outcome == "refused" && r.reason == WidgetEvent.wrongKind, "\(kind)")
    }
    #expect(store.get("got_n") == nil)
}
