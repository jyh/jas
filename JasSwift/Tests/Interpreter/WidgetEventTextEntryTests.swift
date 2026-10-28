import Foundation
import Testing
@testable import JasLib

// WIDGET_EVENTS.md, "Typing in a text field" (STATUS-jas item 40): a
// `text_input`'s `keydown` carries `event.key` and `event.value` (the text
// before the key acts), `blur` and `input` carry `event.value` and no key, and
// only the event's own behaviors run. The reference's `TestTextEntry`
// (test_widget_event.py); Rust `a_text_field_carries_its_key_and_its_text`.

private func field() -> [String: Any] {
    ["type": "text_input", "bind": ["value": "panel.name"], "behavior": [
        ["event": "keydown", "condition": "event.key == 'Enter'",
         "effects": [["set": ["confirmed": "event.value"]]]],
        ["event": "keydown", "condition": "event.key == 'Escape'",
         "effects": [["set": ["cancelled": "true"]]]],
        ["event": "blur", "effects": [["set": ["blurred": "event.value", "blur_key": "event.key"]]]],
        ["event": "input", "effects": [["set": ["typed": "event.value"]]]],
        ["event": "commit", "effects": [["set": ["never": "1"]]]],
    ] as [[String: Any]]]
}

@Test func enterCarriesTheKeyAndTheText() {
    let store = StateStore()
    let r = WidgetEvent.textEntry(widget: field(), event: "keydown", store: store, panel: nil,
                                  text: "Sun", key: "Enter")
    #expect(r.outcome == "committed" && r.behaviorsRun == 1)
    #expect(store.get("confirmed") as? String == "Sun")
    #expect(store.get("cancelled") == nil)
    #expect(store.get("never") == nil, "a key is not a commit")
}

@Test func escapeAndOtherKeys() {
    let store = StateStore()
    #expect(WidgetEvent.textEntry(widget: field(), event: "keydown", store: store, panel: nil,
                                  text: "x", key: "Escape").behaviorsRun == 1)
    #expect(store.get("cancelled") as? Bool == true)
    #expect(store.get("confirmed") == nil)
    #expect(WidgetEvent.textEntry(widget: field(), event: "keydown", store: store, panel: nil,
                                  text: "Su", key: "n").outcome == "inert")
}

@Test func blurAndInputCarryTheTextAndNoKey() {
    let store = StateStore()
    #expect(WidgetEvent.textEntry(widget: field(), event: "blur", store: store, panel: nil,
                                  text: "Sun", key: "Enter").behaviorsRun == 1)
    #expect(store.get("blurred") as? String == "Sun")
    #expect(store.get("blur_key") == nil, "a key rides on keydown only")
    #expect(WidgetEvent.textEntry(widget: field(), event: "input", store: store, panel: nil,
                                  text: "S").behaviorsRun == 1)
    #expect(store.get("typed") as? String == "S")
}

@Test func textEntryRefusals() {
    let store = StateStore()
    let reason = { (w: [String: Any], e: String, t: String?, k: String?) in
        WidgetEvent.textEntry(widget: w, event: e, store: store, panel: nil, text: t, key: k).reason }
    #expect(reason(["type": "number_input"], "keydown", "1", "Enter") == WidgetEvent.wrongKind)
    #expect(reason(field(), "commit", "x", nil) == WidgetEvent.wrongEvent)
    #expect(reason(field(), "keydown", "x", nil) == WidgetEvent.missingValue, "a keydown names its key")
    #expect(reason(field(), "blur", nil, nil) == WidgetEvent.missingValue)
}
