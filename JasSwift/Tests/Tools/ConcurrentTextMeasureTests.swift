import Testing
import Foundation
import AppKit
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
// MEASURED 2026-11-16. The hang is real, and THIS ARM DOES NOT REPRODUCE IT.
// The arm passed on the unfixed code at 8 and at 32 threads. The instrument that
// does reproduce it is a PARALLEL `swift test --filter 'Forms|forms'` from a
// cold process. Unfixed it hung 3 runs of 3: 14 threads each sat in
// `renderedTextWidth` → `NSFont(name:size:)` → a synchronous XPC to the font
// service, with no reply. With `withFontLookup` (Element.swift) it passed 4 runs
// of 4, and a mutant that removes the lock hung again. So this arm guards a
// PROPERTY (concurrent widths equal serial ones, and no deadlock) and does not
// witness the defect. Its failure path is a STALL (no job finishing for 10 s;
// row 262 replaced the 30 s wall bound), proved by the two arms on
// `concurrently` below and by their mutants (the old wall bound reds the slow
// arm; a stall check never taken reds the deadlock arm).

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

/// Run `body` once per job on `threads` threads at once. Returns nil when NO
/// job has finished for `stall` seconds (a deadlock), and otherwise one result
/// per job. Row 262: this was a WALL-CLOCK bound of 30 s, and the arm's wall
/// time tracks the whole parallel suite's, not its own work (measured 11-24:
/// 0.09 s alone, 1.2-1.6 s inside a 2 s local suite, 33.1 s inside CI's 34.5 s
/// suite, where it failed). A starved run that keeps finishing jobs is not a
/// hang, so only a stall fails it.
private func concurrently(_ js: [Job], threads: Int, stall: Double,
                          _ body: @escaping @Sendable (Job) -> Double) -> [Job: Double]? {
    let lock = NSLock()
    nonisolated(unsafe) var results: [Job: Double] = [:]
    nonisolated(unsafe) var lastDone = Date()
    let group = DispatchGroup()
    // DEDICATED threads, not GCD's shared pool (row 262): a parallel suite can
    // hold every pool thread, and then a job here does not even START, which a
    // deadlock bound reads as a hang.
    for t in 0..<threads {
        group.enter()
        Thread {
            // Each thread walks the list from its own offset, so threads hit
            // DIFFERENT cold pairs at the same moment as well as the same ones.
            for k in 0..<js.count {
                let job = js[(k + t * 7) % js.count]
                let w = body(job)
                lock.lock(); results[job] = w; lastDone = Date(); lock.unlock()
            }
            group.leave()
        }.start()
    }
    while group.wait(timeout: .now() + 0.05) != .success {
        lock.lock(); let idle = Date().timeIntervalSince(lastDone); lock.unlock()
        if idle > stall { return nil }
    }
    return results
}

/// Row 262, the bound's own two arms. A run whose WALL time exceeds the stall
/// bound but which keeps finishing jobs is NOT a deadlock (the CI shape that
/// failed the 30 s wall bound), and a run in which nothing finishes for longer
/// than the bound IS one, so the bound can still fail.
@Test func aSlowRunThatKeepsFinishingJobsIsNotADeadlock() {
    let js = Array(jobs(seed: 3.0).prefix(12))
    let start = Date()
    let got = concurrently(js, threads: 2, stall: 0.5) { _ in Thread.sleep(forTimeInterval: 0.1); return 1 }
    #expect(Date().timeIntervalSince(start) > 0.5, "the run's wall time must exceed the stall bound, or this arm proves nothing")
    #expect(got?.count == js.count, "a slow but progressing run returned its results")
}

@Test func aRunThatFinishesNothingForLongerThanTheBoundIsADeadlock() {
    let js = Array(jobs(seed: 4.0).prefix(2))
    let got = concurrently(js, threads: 1, stall: 0.3) { _ in Thread.sleep(forTimeInterval: 1.5); return 1 }
    #expect(got == nil, "a stall longer than the bound is refused as a deadlock")
}

@Test func renderedTextWidthIsSafeUnderConcurrency() {
    let js = jobs(seed: 13.03)
    let got = concurrently(js, threads: 8, stall: 10) { j in
        renderedTextWidth("Row 140 Wq", family: j.family, weight: j.weight, style: j.style, size: j.size)
    }
    #expect(got != nil, "renderedTextWidth finished no job on 8 threads for 10 s (a deadlock)")
    guard let got else { return }
    #expect(got.count == js.count)
    let failuresBefore = faceLookupFailures()
    for j in js {
        let serial = renderedTextWidth("Row 140 Wq", family: j.family, weight: j.weight, style: j.style, size: j.size)
        #expect(got[j] == serial, "concurrent and serial widths differ for \(j); face lookups that fell back to the base face so far: \(faceLookupFailures() - failuresBefore)")
    }
    // CONTROL: the instrument can tell two sizes apart, so equality above is not vacuous.
    #expect(renderedTextWidth("Wq", family: "Helvetica", weight: "normal", style: "normal", size: 10)
            != renderedTextWidth("Wq", family: "Helvetica", weight: "normal", style: "normal", size: 20))
}

@Test func makeMeasurerIsSafeUnderConcurrency() {
    let js = jobs(seed: 17.41)
    let got = concurrently(js, threads: 8, stall: 10) { j in
        makeMeasurer(family: j.family, weight: j.weight, style: j.style, size: j.size)("Row 140 Wq")
    }
    #expect(got != nil, "makeMeasurer finished no job on 8 threads for 10 s (a deadlock)")
    guard let got else { return }
    #expect(got.count == js.count)
    for j in js {
        let serial = makeMeasurer(family: j.family, weight: j.weight, style: j.style, size: j.size)("Row 140 Wq")
        #expect(got[j] == serial, "concurrent and serial widths differ for \(j)")
    }
}

/// Row 178: an italic lookup never silently measures the REGULAR face. CI's
/// 4dc577dd red read Georgia-Italic concurrently and Georgia regular serially
/// (79.364 vs 80.477 at 14.162 pt, measured), so the italic descriptor lookup
/// can fail and `renderedTextWidth` substituted the base font. Serial, many
/// times: every measure must equal the width of the face the family names.
@Test func anItalicMeasureIsAlwaysTheItalicFace() {
    let size = 14.161999999999999
    guard let italic = NSFont(name: "Georgia-Italic", size: CGFloat(size)) else { return }
    let want = Double(NSAttributedString(string: "Row 140 Wq", attributes: [.font: italic]).size().width)
    var wrong = 0
    for _ in 0..<200 {
        let got = renderedTextWidth("Row 140 Wq", family: "Georgia", weight: "normal", style: "italic", size: size)
        if got != want { wrong += 1 }
    }
    #expect(wrong == 0, "\(wrong) of 200 italic measures were not the italic face")
}

// STATUS-jas row 188. CI has read a SERIAL width in the BASE face for an italic
// or bold job (Georgia italic 11-19; Helvetica bold+italic 11-20, 74.781 for
// the 76.936 of Helvetica-Bold): the trait lookup came back nil and the width
// was the base face's, with nothing said. A nil lookup is now retried once,
// and a second nil is COUNTED and logged before the base face is measured.
// The lookup is injected so these arms do not depend on the flake.

@Test func aTraitLookupThatFailsOnceIsRetried() {
    let base = NSFont(name: "Helvetica", size: 13)!
    var calls = 0
    // Both reads of the process-wide counter sit inside the one lock hold, so a
    // parallel arm's counted failure cannot land between them.
    let (face, before, after) = withFontLookup {
        let before = faceLookupFailuresHoldingLock()
        let face = faceWithTraits(base, [.bold, .italic], size: 13) { desc, size in
            calls += 1
            return calls == 1 ? nil : NSFont(descriptor: desc, size: size)
        }
        return (face, before, faceLookupFailuresHoldingLock())
    }
    #expect(calls == 2, "a nil lookup is tried once more")
    #expect(face.fontName == "Helvetica-BoldOblique", "the retry's face is measured, not the base: \(face.fontName)")
    #expect(after == before, "a retry that succeeds is not a failure")
}

@Test func aTraitLookupThatNeverFindsAFaceIsCounted() {
    let base = NSFont(name: "Helvetica", size: 13)!
    let before = faceLookupFailures()
    let face = withFontLookup { faceWithTraits(base, [.italic], size: 13, lookup: { _, _ in nil }, alternate: noAlternate) }
    #expect(face.fontName == base.fontName, "with no face the base is what is left")
    #expect(faceLookupFailures() >= before + 1, "the fallback is counted, not silent")
}

/// The arms above are about the path where NO mechanism finds a face, so they
/// refuse the CoreText alternate as well.
private let noAlternate: (NSFont, NSFontDescriptor.SymbolicTraits, CGFloat) -> NSFont? = { _, _, _ in nil }

// Row 188, 11-21: CI (run 44884499909) saw the AppKit lookup return nil TWICE
// for Georgia bold, a face macOS ships, and the width was Georgia's. A scratch
// stress run did not reproduce it (0 nils of 418,141 locked lookups, with and
// without unlocked CoreText traffic), so the cause is unknown. The answer is by
// mechanism: a second API, CoreText's CTFontCreateCopyWithSymbolicTraits, is
// asked before any fallback, and a face it finds is a RESCUE, counted apart
// from a failure, so a CI log still says the AppKit lookup missed.
@Test func aTraitLookupThatFailsIsRescuedByCoreText() {
    let base = NSFont(name: "Helvetica", size: 13)!
    let (face, failed, rescued) = withFontLookup {
        let (f0, r0) = (faceLookupFailuresHoldingLock(), faceLookupRescuesHoldingLock())
        let face = faceWithTraits(base, [.italic], size: 13, lookup: { _, _ in nil })
        return (face, faceLookupFailuresHoldingLock() - f0, faceLookupRescuesHoldingLock() - r0)
    }
    #expect(face.fontName == "Helvetica-Oblique", "CoreText finds the italic the lookup missed: \(face.fontName)")
    #expect(failed == 0, "a rescued lookup is not a failure")
    #expect(rescued == 1, "a rescue is counted")
}

/// CoreText's answer is taken only when it carries every trait asked for: a
/// face it returns without them is no rescue. The FACE cannot tell (the
/// alternate here returns the base, which the fallback also returns), so the
/// counters do: a failure, not a rescue. A mutant without the traits check
/// survived the face-only form of this arm (11-21).
@Test func aCoreTextFaceWithoutTheTraitsIsNoRescue() {
    let base = NSFont(name: "Helvetica", size: 13)!
    let (face, failed, rescued) = withFontLookup {
        let (f0, r0) = (faceLookupFailuresHoldingLock(), faceLookupRescuesHoldingLock())
        let face = faceWithTraits(base, [.italic], size: 13, lookup: { _, _ in nil }, alternate: { b, _, _ in b })
        return (face, faceLookupFailuresHoldingLock() - f0, faceLookupRescuesHoldingLock() - r0)
    }
    #expect(face == base, "\(face.fontName)")
    #expect(rescued == 0, "a face without the traits is no rescue")
    #expect(failed == 1, "it is a failure, counted")
}

@Test func noTraitsIsTheBaseFaceWithNoLookup() {
    let base = NSFont(name: "Helvetica", size: 13)!
    var calls = 0
    let face = withFontLookup { faceWithTraits(base, [], size: 13) { _, _ in calls += 1; return nil } }
    #expect(calls == 0 && face == base)
}

// STATUS-jas row 188(b). When a family has no face with ALL the requested
// traits, the fallback keeps as many of them as the family has: bold alone,
// then italic alone, and the base face only when neither exists. Before this,
// a bold-italic job in Futura-Medium (no bold italic, measured on macOS 11-20:
// the [bold, italic] lookup is nil, [bold] is Futura-Bold, [italic] is
// Futura-MediumItalic) measured Futura-Medium and lost the bold as well. A
// partial face is still COUNTED as a failure: it is not the face asked for.

/// A lookup that finds a face only when the descriptor's traits are in `has`.
private final class LookupLog { var traits: [UInt32] = [] }

private func lookupOnly(_ has: [NSFontDescriptor.SymbolicTraits], calls: LookupLog)
    -> (NSFontDescriptor, CGFloat) -> NSFont? {
    return { desc, size in
        let t = desc.symbolicTraits.intersection([.bold, .italic])
        calls.traits.append(t.rawValue)
        return has.contains(t) ? NSFont(descriptor: desc, size: size) : nil
    }
}

@Test func aMissingBoldItalicKeepsTheBold() {
    let base = NSFont(name: "Helvetica", size: 13)!
    let calls = LookupLog()
    let before = faceLookupFailures()
    let face = withFontLookup {
        faceWithTraits(base, [.bold, .italic], size: 13, lookup: lookupOnly([[.bold], [.italic]], calls: calls), alternate: noAlternate)
    }
    #expect(face.fontName == "Helvetica-Bold", "bold is tried before italic and before the base: \(face.fontName)")
    #expect(faceLookupFailures() >= before + 1, "a partial face is still counted")
}

@Test func aMissingBoldItalicWithNoBoldKeepsTheItalic() {
    let base = NSFont(name: "Helvetica", size: 13)!
    let calls = LookupLog()
    let face = withFontLookup {
        faceWithTraits(base, [.bold, .italic], size: 13, lookup: lookupOnly([[.italic]], calls: calls), alternate: noAlternate)
    }
    #expect(face.fontName == "Helvetica-Oblique", "italic alone when the family has no bold: \(face.fontName)")
}

@Test func aSingleTraitMissDoesNotTryOtherTraits() {
    let base = NSFont(name: "Helvetica", size: 13)!
    let calls = LookupLog()
    let face = withFontLookup {
        faceWithTraits(base, [.italic], size: 13, lookup: lookupOnly([[.bold]], calls: calls), alternate: noAlternate)
    }
    #expect(face == base, "an italic job never measures a bold face: \(face.fontName)")
    #expect(!calls.traits.contains(NSFontDescriptor.SymbolicTraits.bold.rawValue), "bold was never asked for: \(calls.traits)")
}

/// The real lookup, no injection: Futura-Medium has no bold italic on macOS.
@Test func futuraBoldItalicMeasuresFuturaBold() {
    guard let base = NSFont(name: "Futura-Medium", size: 13),
          NSFont(name: "Futura-Bold", size: 13) != nil else { return }
    let face = withFontLookup { faceWithTraits(base, [.bold, .italic], size: 13) }
    #expect(face.fontName == "Futura-Bold", "the bold is kept when the italic is absent: \(face.fontName)")
}

// Row 188, 11-22: every main Swift run printed the same four row-188 lines,
// and all four were PROVOKED by the arms above (a stubbed lookup or
// alternate). The log dedupes per face and traits per process, so once a test
// had logged "Helvetica/1", a REAL miss of Helvetica italic in the same run
// printed nothing: the watch could not see the recurrence it exists for. A
// line from an injected lookup is now filed apart and labelled.
@Test func anInjectedLookupsLineDoesNotSwallowARealMissOfTheSameFace() {
    let base = NSFont(name: "Helvetica", size: 13)!
    let keys = withFontLookup { () -> (Bool, Bool) in
        _ = faceWithTraits(base, [.italic], size: 13, lookup: { _, _ in nil }, alternate: noAlternate)
        return (faceLookupWasLoggedHoldingLock("injected/Helvetica/\(NSFontDescriptor.SymbolicTraits.italic.rawValue)"),
                faceLookupWasLoggedHoldingLock("Helvetica/\(NSFontDescriptor.SymbolicTraits.italic.rawValue)"))
    }
    #expect(keys.0, "the injected miss is logged under its own key")
    #expect(!keys.1, "the REAL key stays free, so a production miss of this face still prints")
}
