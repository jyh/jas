import Foundation
import Testing
@testable import JasLib

// WIDGET_EVENTS.md, "The bound target": a write to the open dialog runs its
// `on_change`, once, at the end of the event. Row for row with the reference's
// `TestDialogOnChange` (test_widget_event.py). Until 2026-10-24 a dialog bind
// write here was a bare `setDialog`, outside any batch, so a typed angle in
// Rotate Options previewed only at the next button press.

private let seen: [String: Any] = ["seen": ["effects": [["set": [
    "fired": "state.fired + 1", "fired_angle": "dialog.angle"]]]]]

private func dialogStore() -> StateStore {
    let store = StateStore(defaults: ["fired": 0])
    store.initDialog("d", defaults: ["angle": 0, "on": false])
    store.setDialogOnChange("seen")
    _ = store.takeDialogDirty()
    return store
}

private func fired(_ store: StateStore) -> Int? { (store.get("fired") as? NSNumber)?.intValue }

@Test func aDialogCommitRunsOnChangeWithTheNewValue() {
    let store = dialogStore()
    let w: [String: Any] = ["type": "number_input", "bind": ["value": "dialog.angle"]]
    let r = WidgetEvent.commit(widget: w, text: "30", store: store, panel: nil, actions: seen)
    #expect(r.outcome == "committed")
    #expect(fired(store) == 1)
    #expect((store.get("fired_angle") as? NSNumber)?.doubleValue == 30.0)
}

@Test func aDialogPressRunsOnChange() {
    let store = dialogStore()
    let w: [String: Any] = ["type": "toggle", "bind": ["checked": "dialog.on"]]
    _ = WidgetEvent.press(widget: w, store: store, panel: nil, actions: seen)
    #expect(store.getDialog("on") as? Bool == true)
    #expect(fired(store) == 1)
}

@Test func aBehaviorBatchRunsOnChangeOnceNotTwice() {
    let store = dialogStore()
    let w: [String: Any] = ["type": "number_input", "bind": ["value": "dialog.angle"],
                            "behavior": [["event": "commit", "effects": [["set": ["x": "1"]]]]]]
    _ = WidgetEvent.commit(widget: w, text: "5", store: store, panel: nil, actions: seen)
    #expect(fired(store) == 1)
}

@Test func aPanelWriteRunsNoDialogAction() {
    let store = dialogStore()
    store.initPanel("p", defaults: ["n": 0])
    store.setActivePanel("p")
    let w: [String: Any] = ["type": "number_input", "bind": ["value": "panel.n"]]
    _ = WidgetEvent.commit(widget: w, text: "4", store: store, panel: nil, actions: seen)
    #expect(fired(store) == 0)
}
