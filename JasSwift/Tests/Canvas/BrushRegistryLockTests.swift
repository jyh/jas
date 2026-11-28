import Foundation
import Testing
@testable import JasLib

// Row 303: the canvas brush registry is ONE process-wide value, written by the
// brush render tests, by `installCanvasBrushRegistry` (every paint) and by the
// Brush Options dialog effects (`syncCanvasBrushes`). Swift Testing runs tests
// in parallel, so a test that set the registry and then painted could paint
// with another test's libraries: 1 red in 8 local runs of the brush render
// tests beside the dialog-action corpus (and once in CI, on #1170).
// `withCanvasBrushRegistry` holds the registry for its body, so a writer on
// another thread waits until the body returns.
@Test func aRegistryTransactionIsNotInterleavedByAnotherWriter() {
    let started = DispatchSemaphore(value: 0)
    let wrote = DispatchSemaphore(value: 0)
    var seen: [String] = []
    var finishedInside = false
    withCanvasBrushRegistry {
        setCanvasBrushLibraries(["mine": [String: Any]()])
        // A DEDICATED thread, never a GCD queue: while this transaction holds
        // the lock, other parallel tests' writers block on it on the
        // cooperative threads, and GCD does not count a mutex wait as blocked,
        // so a queued writer could wait for a thread for ever (it did: run 1
        // of the first after-fix loop hung 12 min until sampled).
        let writer = Thread {
            started.signal()
            setCanvasBrushLibraries(["theirs": [String: Any]()])
            wrote.signal()
        }
        writer.start()
        started.wait()
        // Inside the transaction the writer cannot finish; without the lock
        // it lands here, well within the wait.
        finishedInside = wrote.wait(timeout: .now() + .milliseconds(300)) == .success
        seen = Array(canvasBrushLibrariesSnapshot().keys)
        setCanvasBrushLibraries([:])
    }
    // The writer finishes once the transaction is over. Bounded, and only
    // when it has not already finished inside, so the RED path (no lock: the
    // writer finished inside and its one signal is spent) fails, never hangs.
    let finishedAfter = finishedInside || wrote.wait(timeout: .now() + .seconds(5)) == .success
    setCanvasBrushLibraries([:])
    #expect(!finishedInside, "a writer on another thread finished INSIDE the transaction")
    #expect(finishedAfter, "the waiting writer never finished after the transaction")
    #expect(seen == ["mine"], "another writer changed the registry inside a transaction: \(seen)")
}
