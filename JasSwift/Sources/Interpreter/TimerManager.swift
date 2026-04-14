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
