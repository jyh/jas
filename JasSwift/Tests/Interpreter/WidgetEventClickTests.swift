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
