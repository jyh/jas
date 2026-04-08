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
