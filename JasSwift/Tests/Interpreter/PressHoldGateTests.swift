import Testing
@testable import JasLib

// WIDGET_EVENTS.md, "A press-and-hold consumes its click": once a press's
// mouse_down timer has fired (a toolbar slot's alternates flyout opened), the
// release does not also click the button. A press released before its timer
// fires is an ordinary click. SwiftUI may deliver the Button's action before
// or after the release gesture ends, so both orders are pinned.

private final class Clock { var t: Double = 0 }

private func gate(_ c: Clock) -> PressHoldGate {
    PressHoldGate(window: 0.5, now: { c.t })
}

@Test func aPressReleasedBeforeItsTimerFiresIsAClick() {
    let c = Clock(); let g = gate(c)
    g.pressed(["long_press_btn_pen_slot"])
    g.released(["long_press_btn_pen_slot"])
    #expect(g.consumesClick(["long_press_btn_pen_slot"]) == false)
}

@Test func aFiredHoldConsumesTheClickThatArrivesAfterTheRelease() {
    let c = Clock(); let g = gate(c)
    g.pressed(["long_press_btn_pen_slot"])
    g.timerFired("long_press_btn_pen_slot")
    g.released(["long_press_btn_pen_slot"])
    #expect(g.consumesClick(["long_press_btn_pen_slot"]) == true)
}

@Test func aFiredHoldConsumesTheClickThatArrivesBeforeTheRelease() {
    let c = Clock(); let g = gate(c)
    g.pressed(["long_press_btn_pen_slot"])
    g.timerFired("long_press_btn_pen_slot")
    #expect(g.consumesClick(["long_press_btn_pen_slot"]) == true)
    g.released(["long_press_btn_pen_slot"])
    // Consumed once: the next quick press is a click again.
    g.pressed(["long_press_btn_pen_slot"])
    g.released(["long_press_btn_pen_slot"])
    #expect(g.consumesClick(["long_press_btn_pen_slot"]) == false)
}

@Test func aConsumedClickIsConsumedOnce() {
    let c = Clock(); let g = gate(c)
    g.pressed(["t"]); g.timerFired("t"); g.released(["t"])
    #expect(g.consumesClick(["t"]) == true)
    #expect(g.consumesClick(["t"]) == false)
}

@Test func aFiredHoldDoesNotEatAClickLongAfterItsRelease() {
    // A click with no press (an accessibility press) well after a fired hold
    // released without clicking is a click.
    let c = Clock(); let g = gate(c)
    g.pressed(["t"]); g.timerFired("t"); g.released(["t"])
    c.t = 0.6
    #expect(g.consumesClick(["t"]) == false)
}

@Test func aTimerFiringWithNoPressInProgressConsumesNothing() {
    let c = Clock(); let g = gate(c)
    g.timerFired("t")
    // A click with no press of its own (an accessibility press).
    #expect(g.consumesClick(["t"]) == false)
}

@Test func aNewPressForgetsAFiredHoldWhoseReleaseNeverArrived() {
    // A gesture can be cancelled without its end being delivered. The next
    // press starts clean, so its quick release is a click.
    let c = Clock(); let g = gate(c)
    g.pressed(["t"]); g.timerFired("t")
    g.pressed(["t"]); g.released(["t"])
    #expect(g.consumesClick(["t"]) == false)
}

@Test func anotherSlotsFiredHoldDoesNotConsumeThisSlotsClick() {
    let c = Clock(); let g = gate(c)
    g.pressed(["a"]); g.timerFired("a"); g.released(["a"])
    g.pressed(["b"]); g.released(["b"])
    #expect(g.consumesClick(["b"]) == false)
}

@Test func aWidgetWithNoHoldTimerAlwaysClicks() {
    let c = Clock(); let g = gate(c)
    #expect(g.consumesClick([]) == false)
}

@Test func theStartTimerIdsAreReadFromTheMouseDownBehavior() {
    let element: [String: Any] = ["behavior": [
        ["event": "mouse_down", "effects": [["start_timer": ["id": "long_press_btn_pen_slot", "delay_ms": 250, "effects": []]]]],
        ["event": "mouse_up", "effects": [["cancel_timer": "long_press_btn_pen_slot"]]],
        ["event": "click", "action": "select_tool"],
    ]]
    #expect(PressHoldGate.holdTimerIds(element) == ["long_press_btn_pen_slot"])
    #expect(PressHoldGate.holdTimerIds(["behavior": [["event": "click", "action": "x"]]]) == [])
}

@Test func everyToolbarSlotWithAHoldTimerNamesItInBothHandlers() {
    // The shipped toolbar: each slot's mouse_down starts the timer its
    // mouse_up cancels, so the gate's ids are the ones TimerManager fires.
    guard let ws = WorkspaceData.load() else { Issue.record("no workspace"); return }
    var slots = 0
    func walk(_ n: Any) {
        if let d = n as? [String: Any] {
            let ids = PressHoldGate.holdTimerIds(d)
            if !ids.isEmpty {
                slots += 1
                let behaviors = d["behavior"] as? [[String: Any]] ?? []
                let cancels = behaviors.filter { ($0["event"] as? String) == "mouse_up" }
                    .flatMap { ($0["effects"] as? [[String: Any]]) ?? [] }
                    .compactMap { $0["cancel_timer"] as? String }
                #expect(Set(cancels) == Set(ids), "\(ids)")
            }
            d.values.forEach(walk)
        } else if let a = n as? [Any] { a.forEach(walk) }
    }
    walk(ws.data)
    #expect(slots >= 7, "only \(slots) hold slots found")
}
