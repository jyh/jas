import Testing
import Foundation
@testable import JasLib

// STATUS-jas row 140. Swift Testing runs tests on several threads at once, and
// a parallel `swift test` hung at 0 % CPU with two or more threads inside
// `renderedTextWidth` → `NSFont(name:size:)` → CoreText's font lookup. A serial
// run passed. So the text measure must be safe to call from many threads at
// once, and it must return the same widths it returns serially.
//
// The arm runs the CONCURRENT pass FIRST, on font/size pairs nothing else in
// the suite uses. A serial pass first would warm CoreText's caches, and a
// warm lookup may never reach the code that hangs. It waits with a TIMEOUT,
// so a deadlock fails the test by name instead of hanging the run.
//
// MEASURED 2026-11-16, and it is NOT the fix the row asked for. The hang did
// not reproduce. This arm PASSED on the unchanged code (8 threads, 56 cold
// pairs), and three parallel `swift test` runs of the whole suite (3,720
// tests) all passed. So concurrent `NSFont(name:size:)` alone does not hang,
// and the row's read mechanism is refuted at this scale. No lock was added,
// because a fix that cannot go red first is not tested. The arm stays as a
// guard on the property. Its failure path is proved by a mutant: a 1 s sleep
// in `renderedTextWidth` failed it by name at 30.001 s, without hanging.

private let families = ["Helvetica", "Times New Roman", "Courier", "Georgia", "Menlo",
                        "Avenir", "Futura", "Optima", "Palatino", "Gill Sans",
                        "sans-serif", "serif", "monospace", "No Such Family 140"]
private let weights = [("normal", "normal"), ("bold", "normal"), ("normal", "italic"), ("bold", "italic")]

private struct Job: Hashable {
    let family: String, weight: String, style: String, size: Double
}

private func jobs(seed: Double) -> [Job] {
    var out: [Job] = []
    for (i, f) in families.enumerated() {
        for (j, ws) in weights.enumerated() {
            // Sizes no other test uses, so every lookup is a cold one.
            out.append(Job(family: f, weight: ws.0, style: ws.1, size: seed + Double(i) * 0.37 + Double(j) * 0.011))
        }
    }
    return out
}

/// Run `body` once per job on `threads` threads at once. Returns nil on a
/// timeout, and otherwise one result per job.
private func concurrently(_ js: [Job], threads: Int, timeout: Double,
                          _ body: @escaping @Sendable (Job) -> Double) -> [Job: Double]? {
    let lock = NSLock()
    nonisolated(unsafe) var results: [Job: Double] = [:]
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "row140", attributes: .concurrent)
    for t in 0..<threads {
        group.enter()
        queue.async {
            // Each thread walks the list from its own offset, so threads hit
            // DIFFERENT cold pairs at the same moment as well as the same ones.
            for k in 0..<js.count {
                let job = js[(k + t * 7) % js.count]
                let w = body(job)
                lock.lock(); results[job] = w; lock.unlock()
            }
            group.leave()
        }
    }
    guard group.wait(timeout: .now() + timeout) == .success else { return nil }
    return results
}

@Test func renderedTextWidthIsSafeUnderConcurrency() {
    let js = jobs(seed: 13.03)
    let got = concurrently(js, threads: 8, timeout: 30) { j in
        renderedTextWidth("Row 140 Wq", family: j.family, weight: j.weight, style: j.style, size: j.size)
    }
    #expect(got != nil, "renderedTextWidth did not finish on 8 threads within 30 s (a deadlock)")
    guard let got else { return }
    #expect(got.count == js.count)
    for j in js {
        let serial = renderedTextWidth("Row 140 Wq", family: j.family, weight: j.weight, style: j.style, size: j.size)
        #expect(got[j] == serial, "concurrent and serial widths differ for \(j)")
    }
    // CONTROL: the instrument can tell two sizes apart, so equality above is not vacuous.
    #expect(renderedTextWidth("Wq", family: "Helvetica", weight: "normal", style: "normal", size: 10)
            != renderedTextWidth("Wq", family: "Helvetica", weight: "normal", style: "normal", size: 20))
}

@Test func makeMeasurerIsSafeUnderConcurrency() {
    let js = jobs(seed: 17.41)
    let got = concurrently(js, threads: 8, timeout: 30) { j in
        makeMeasurer(family: j.family, weight: j.weight, style: j.style, size: j.size)("Row 140 Wq")
    }
    #expect(got != nil, "makeMeasurer did not finish on 8 threads within 30 s (a deadlock)")
    guard let got else { return }
    #expect(got.count == js.count)
    for j in js {
        let serial = makeMeasurer(family: j.family, weight: j.weight, style: j.style, size: j.size)("Row 140 Wq")
        #expect(got[j] == serial, "concurrent and serial widths differ for \(j)")
    }
}
