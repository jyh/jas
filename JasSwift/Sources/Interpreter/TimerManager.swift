/// Timer manager for start_timer/cancel_timer effects.
///
/// Manages named delayed timers for the YAML interpreter. When a timer
/// fires, it runs the nested effects (e.g., open_dialog for tool alternates).

import Foundation

/// Manages named timers with delayed callbacks.
class TimerManager {
    static let shared = TimerManager()

    private var timers: [String: DispatchWorkItem] = [:]

    /// Start a named timer that fires after delay_ms.
    /// If a timer with the same id already exists, it is cancelled first.
    /// The callback runs on the main queue.
    func startTimer(id: String, delayMs: Int, callback: @escaping () -> Void) {
        cancelTimer(id: id)
        let work = DispatchWorkItem { [weak self] in
            self?.timers.removeValue(forKey: id)
            PressHoldGate.shared.timerFired(id)
            callback()
        }
        timers[id] = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(delayMs),
            execute: work
        )
    }

    /// Cancel a pending timer by ID.
    func cancelTimer(id: String) {
        if let work = timers.removeValue(forKey: id) {
            work.cancel()
        }
    }

    /// Cancel all pending timers.
    func cancelAll() {
        for (_, work) in timers {
            work.cancel()
        }
        timers.removeAll()
    }
}

/// WIDGET_EVENTS.md, "A press-and-hold consumes its click": once a press's
/// `mouse_down` timer has fired (a toolbar slot's alternates flyout opened),
/// the release does not also click the button. A press released before its
/// timer fires is an ordinary click.
///
/// A SwiftUI `Button` fires its action on release however long the press was
/// held, and the press itself is a simultaneous gesture whose end may be
/// delivered before or after that action. So the gate answers in both orders:
/// a click while the fired press is still down is consumed, and so is one
/// within `window` seconds after its release. Each fired hold consumes at most
/// one click, and a click long after the release (an accessibility press, with
/// no press of its own) is a click.
final class PressHoldGate {
    static let shared = PressHoldGate()

    private let window: Double
    private let now: () -> Double
    /// Timer ids of the presses in progress.
    private var down: Set<String> = []
    /// Ids whose timer fired during the press in progress.
    private var fired: Set<String> = []
    /// Ids whose fired press was released without its click yet, with the
    /// time after which a click is a click again.
    private var consumeUntil: [String: Double] = [:]

    init(window: Double = 0.5,
         now: @escaping () -> Double = { Date().timeIntervalSinceReferenceDate }) {
        self.window = window
        self.now = now
    }

    func pressed(_ ids: [String]) {
        for id in ids {
            down.insert(id)
            fired.remove(id)
            consumeUntil.removeValue(forKey: id)
        }
    }

    func timerFired(_ id: String) {
        if down.contains(id) { fired.insert(id) }
    }

    func released(_ ids: [String]) {
        for id in ids {
            down.remove(id)
            if fired.remove(id) != nil { consumeUntil[id] = now() + window }
        }
    }

    /// True when this click belongs to a press whose hold timer fired; the
    /// caller then runs nothing. Consumes the hold either way it matched.
    func consumesClick(_ ids: [String]) -> Bool {
        for id in ids {
            if fired.remove(id) != nil { return true }
            if let until = consumeUntil.removeValue(forKey: id), now() <= until { return true }
        }
        return false
    }

    /// The `start_timer` ids an element's `mouse_down` behaviors start.
    static func holdTimerIds(_ element: [String: Any]) -> [String] {
        let behaviors = element["behavior"] as? [[String: Any]] ?? []
        return behaviors
            .filter { ($0["event"] as? String) == "mouse_down" }
            .flatMap { ($0["effects"] as? [[String: Any]]) ?? [] }
            .compactMap { ($0["start_timer"] as? [String: Any])?["id"] as? String }
    }
}
