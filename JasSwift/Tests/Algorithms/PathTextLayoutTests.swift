import Testing
import Foundation
@testable import JasLib

// Mirrors path_text_layout tests in jas_dioxus/src/algorithms/path_text_layout.rs.

private func straight() -> [PathCommand] {
    [.moveTo(0, 0), .lineTo(100, 0)]
}

private func fixedMeasure(_ w: Double) -> (String) -> Double {
    { s in Double(s.count) * w }
}

@Test func ptlEmptyContentIsEmptyLayout() {
    let l = layoutPathText(straight(), content: "", startOffset: 0.0, fontSize: 16.0, measure: fixedMeasure(10.0))
    #expect(l.charCount == 0)
    #expect(l.glyphs.isEmpty)
}

@Test func ptlGlyphsAdvanceAlongStraightPath() {
    let l = layoutPathText(straight(), content: "abc", startOffset: 0.0, fontSize: 16.0, measure: fixedMeasure(10.0))
    #expect(l.glyphs.count == 3)
    #expect(abs(l.glyphs[0].cx - 5.0) < 1e-6)
    #expect(abs(l.glyphs[1].cx - 15.0) < 1e-6)
    #expect(abs(l.glyphs[2].cx - 25.0) < 1e-6)
    for g in l.glyphs {
        #expect(abs(g.cy) < 1e-6)
        #expect(abs(g.angle) < 1e-6)
    }
}

@Test func ptlCursorPosAtStartIsPathOrigin() {
    let l = layoutPathText(straight(), content: "abc", startOffset: 0.0, fontSize: 16.0, measure: fixedMeasure(10.0))
    let p = l.cursorPos(0)!
    #expect(abs(p.0) < 1e-6)
    #expect(abs(p.1) < 1e-6)
}

/// Row 112 (flask §895): an EMPTY session draws its caret at the path point
/// of `startOffset`, along the tangent, before the first character.
@Test func ptlCursorPosOnAnEmptyLayoutIsTheStartPointAlongTheTangent() {
    let m = fixedMeasure(10.0)
    let l = layoutPathText(straight(), content: "", startOffset: 0.25, fontSize: 16.0, measure: m)
    let p = l.cursorPos(0)
    #expect(p != nil, "an empty session still has a caret")
    if let (x, y, a) = p {
        #expect(abs(x - 25.0) < 1e-6 && abs(y) < 1e-6 && abs(a) < 1e-6, "(\(x), \(y), \(a))")
    }
    let vertical: [PathCommand] = [.moveTo(0, 0), .lineTo(0, 100)]
    let v = layoutPathText(vertical, content: "", startOffset: 0.5, fontSize: 16.0, measure: m)
    let q = v.cursorPos(0)
    #expect(q != nil, "a caret on the vertical path")
    if let (x, y, a) = q {
        #expect(abs(x) < 1e-6 && abs(y - 50.0) < 1e-6 && abs(a - Double.pi / 2) < 1e-6, "(\(x), \(y), \(a))")
    }
    // A degenerate path still has no caret.
    let d = layoutPathText([.moveTo(5, 5)], content: "", startOffset: 0.0, fontSize: 16.0, measure: m)
    #expect(d.cursorPos(0) == nil)
}

@Test func ptlCursorPosAtEndIsAfterLastGlyph() {
    let l = layoutPathText(straight(), content: "abc", startOffset: 0.0, fontSize: 16.0, measure: fixedMeasure(10.0))
    let p = l.cursorPos(3)!
    #expect(abs(p.0 - 30.0) < 1e-6)
}

@Test func ptlHitTestPicksNearestCursorIndex() {
    let l = layoutPathText(straight(), content: "abc", startOffset: 0.0, fontSize: 16.0, measure: fixedMeasure(10.0))
    #expect(l.hitTest(12.0, 0.0) == 1)
    #expect(l.hitTest(1000.0, 0.0) == 3)
    #expect(l.hitTest(-100.0, 0.0) == 0)
}

@Test func ptlStartOffsetShiftsGlyphsAlongPath() {
    let l = layoutPathText(straight(), content: "abc", startOffset: 0.5, fontSize: 16.0, measure: fixedMeasure(10.0))
    #expect(abs(l.glyphs[0].cx - 55.0) < 1e-6)
    #expect(abs(l.glyphs[1].cx - 65.0) < 1e-6)
    #expect(abs(l.glyphs[2].cx - 75.0) < 1e-6)
}

@Test func ptlTotalLengthMatchesStraightPath() {
    let l = layoutPathText(straight(), content: "ab", startOffset: 0.0, fontSize: 16.0, measure: fixedMeasure(10.0))
    #expect(abs(l.totalLength - 100.0) < 1e-6)
}

@Test func ptlCursorPosForIndexInMiddle() {
    let l = layoutPathText(straight(), content: "abc", startOffset: 0.0, fontSize: 16.0, measure: fixedMeasure(10.0))
    let p = l.cursorPos(1)!
    #expect(abs(p.0 - 10.0) < 1e-6)
}

@Test func ptlEmptyPathHasZeroTotalLength() {
    let l = layoutPathText([], content: "abc", startOffset: 0.0, fontSize: 16.0, measure: fixedMeasure(10.0))
    #expect(l.totalLength == 0.0)
}

@Test func ptlGlyphsOverflowWhenPathTooShort() {
    let l = layoutPathText(straight(), content: "abcdefghijkl", startOffset: 0.0, fontSize: 16.0, measure: fixedMeasure(10.0))
    #expect(l.glyphs.contains(where: { $0.overflow }))
}
