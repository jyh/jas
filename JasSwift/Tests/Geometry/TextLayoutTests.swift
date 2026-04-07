import Testing
@testable import JasLib

// Mirrors the layout tests in `text_layout_test.py` and the layout
// tests in `jas_dioxus/src/geometry/text_layout.rs`. Uses the
// deterministic stub measurer (10 pixels per char at fontSize=10) so
// geometric assertions are exact.

private func fixedMeasure(_ width: Double) -> (String) -> Double {
    { s in Double(s.count) * width }
}

@Test func emptyContentProducesOneLine() {
    let lay = layoutText("", maxWidth: 100, fontSize: 10, measure: fixedMeasure(10))
    #expect(lay.lines.count == 1)
    #expect(lay.glyphs.isEmpty)
    #expect(lay.charCount == 0)
}

@Test func singleLineNoWrap() {
    let lay = layoutText("hello", maxWidth: 1000, fontSize: 10, measure: fixedMeasure(10))
    #expect(lay.lines.count == 1)
    #expect(lay.glyphs.count == 5)
    #expect(lay.glyphs[0].x == 0)
    #expect(lay.glyphs[1].x == 10)
}

@Test func hardBreakNewline() {
    let lay = layoutText("a\nb", maxWidth: 1000, fontSize: 10, measure: fixedMeasure(10))
    #expect(lay.lines.count == 2)
    #expect(lay.lines[0].hardBreak == true)
}

@Test func newlineWithMaxWidthZero() {
    // Point text uses maxWidth=0; verify hard breaks still produce
    // multi-line layout (this is what the type tool relies on for the
    // editing-overlay bbox to grow vertically).
    let lay = layoutText("ab\ncd", maxWidth: 0, fontSize: 16, measure: fixedMeasure(8))
    #expect(lay.lines.count == 2)
    #expect(lay.lines[0].end == 2)
    #expect(lay.lines[1].start == 3)
}

@Test func softWrapAtWordBoundary() {
    // "hello world" — at width 60 should wrap before "world".
    let lay = layoutText("hello world", maxWidth: 60, fontSize: 10, measure: fixedMeasure(10))
    #expect(lay.lines.count == 2)
}

@Test func cursorXYAtStartIsZero() {
    let lay = layoutText("abc", maxWidth: 1000, fontSize: 10, measure: fixedMeasure(10))
    let (x, _, _) = lay.cursorXY(0)
    #expect(x == 0)
}

@Test func cursorXYAtEndIsRightOfLastGlyph() {
    let lay = layoutText("abc", maxWidth: 1000, fontSize: 10, measure: fixedMeasure(10))
    let (x, _, _) = lay.cursorXY(3)
    #expect(x == 30)
}

@Test func hitTestMapsXToCharIndex() {
    let lay = layoutText("abc", maxWidth: 1000, fontSize: 10, measure: fixedMeasure(10))
    #expect(lay.hitTest(-5, 5) == 0)
    #expect(lay.hitTest(4, 5) == 0)
    #expect(lay.hitTest(7, 5) == 1)
    #expect(lay.hitTest(100, 5) >= 3)
}

@Test func cursorUpFromSecondLineMovesTowardStart() {
    let lay = layoutText("hello world", maxWidth: 60, fontSize: 10, measure: fixedMeasure(10))
    // From end-of-content (on line 1) cursorUp must move strictly back.
    let endCursor = lay.charCount
    let upCursor = lay.cursorUp(endCursor)
    #expect(upCursor < endCursor)
}

@Test func orderedRangeSwapsArguments() {
    let (a, b) = orderedRange(5, 2)
    #expect(a == 2 && b == 5)
}
