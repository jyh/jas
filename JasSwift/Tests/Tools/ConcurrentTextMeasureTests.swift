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
// witness the defect. Its failure path is proved by a 1 s sleep mutant, which
// fails it by name at 30.001 s.

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
    let before = faceLookupFailures()
    let face = withFontLookup {
        faceWithTraits(base, [.bold, .italic], size: 13) { desc, size in
            calls += 1
            return calls == 1 ? nil : NSFont(descriptor: desc, size: size)
        }
    }
    #expect(calls == 2, "a nil lookup is tried once more")
    #expect(face.fontName == "Helvetica-BoldOblique", "the retry's face is measured, not the base: \(face.fontName)")
    #expect(faceLookupFailures() == before, "a retry that succeeds is not a failure")
}

@Test func aTraitLookupThatNeverFindsAFaceIsCounted() {
    let base = NSFont(name: "Helvetica", size: 13)!
    let before = faceLookupFailures()
    let face = withFontLookup { faceWithTraits(base, [.italic], size: 13) { _, _ in nil } }
    #expect(face.fontName == base.fontName, "with no face the base is what is left")
    #expect(faceLookupFailures() >= before + 1, "the fallback is counted, not silent")
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
        faceWithTraits(base, [.bold, .italic], size: 13, lookup: lookupOnly([[.bold], [.italic]], calls: calls))
    }
    #expect(face.fontName == "Helvetica-Bold", "bold is tried before italic and before the base: \(face.fontName)")
    #expect(faceLookupFailures() >= before + 1, "a partial face is still counted")
}

@Test func aMissingBoldItalicWithNoBoldKeepsTheItalic() {
    let base = NSFont(name: "Helvetica", size: 13)!
    let calls = LookupLog()
    let face = withFontLookup {
        faceWithTraits(base, [.bold, .italic], size: 13, lookup: lookupOnly([[.italic]], calls: calls))
    }
    #expect(face.fontName == "Helvetica-Oblique", "italic alone when the family has no bold: \(face.fontName)")
}

@Test func aSingleTraitMissDoesNotTryOtherTraits() {
    let base = NSFont(name: "Helvetica", size: 13)!
    let calls = LookupLog()
    let face = withFontLookup {
        faceWithTraits(base, [.italic], size: 13, lookup: lookupOnly([[.bold]], calls: calls))
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
