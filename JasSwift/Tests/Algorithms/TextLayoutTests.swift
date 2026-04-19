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

// MARK: - Phase 5 paragraph-aware layout

@Test func emptyParagraphListMatchesPlainLayout() {
    let m: (String) -> Double = { Double($0.count) * 10.0 }
    let plain = layoutText("hello world", maxWidth: 100, fontSize: 16, measure: m)
    let para = layoutTextWithParagraphs("hello world", maxWidth: 100,
                                         fontSize: 16, paragraphs: [], measure: m)
    #expect(plain.lines.count == para.lines.count)
    #expect(plain.glyphs.count == para.glyphs.count)
    for (a, b) in zip(plain.glyphs, para.glyphs) {
        #expect(a.x == b.x)
        #expect(a.right == b.right)
        #expect(a.line == b.line)
    }
}

@Test func leftIndentShiftsEveryLine() {
    let m: (String) -> Double = { Double($0.count) * 10.0 }
    // "hello world" at width 60 with leftIndent 20 → effective 40 → wraps.
    let segs = [ParagraphSegment(charStart: 0, charEnd: 11, leftIndent: 20)]
    let l = layoutTextWithParagraphs("hello world", maxWidth: 60,
                                      fontSize: 16, paragraphs: segs, measure: m)
    #expect(l.glyphs[0].x == 20)
}

@Test func rightIndentNarrowsWrapWidth() {
    let m: (String) -> Double = { Double($0.count) * 10.0 }
    let segs = [ParagraphSegment(charStart: 0, charEnd: 11, rightIndent: 60)]
    let l = layoutTextWithParagraphs("hello world", maxWidth: 110,
                                      fontSize: 16, paragraphs: segs, measure: m)
    #expect(l.lines.count >= 2)
}

@Test func firstLineIndentOnlyShiftsFirstLine() {
    let m: (String) -> Double = { Double($0.count) * 10.0 }
    let segs = [ParagraphSegment(charStart: 0, charEnd: 11,
                                  firstLineIndent: 25)]
    let l = layoutTextWithParagraphs("hello world", maxWidth: 60,
                                      fontSize: 16, paragraphs: segs, measure: m)
    let firstLineFirst = l.glyphs.first(where: { $0.line == 0 })!
    let secondLineFirst = l.glyphs.first(where: { $0.line == 1 })!
    #expect(firstLineFirst.x == 25)
    #expect(secondLineFirst.x == 0)
}

@Test func alignmentCenterShiftsToCenter() {
    let m: (String) -> Double = { Double($0.count) * 10.0 }
    // "hi" (20 wide) centered in 100 → x = (100-20)/2 = 40.
    let segs = [ParagraphSegment(charStart: 0, charEnd: 2, textAlign: .center)]
    let l = layoutTextWithParagraphs("hi", maxWidth: 100, fontSize: 16,
                                      paragraphs: segs, measure: m)
    #expect(l.glyphs[0].x == 40)
}

@Test func alignmentRightShiftsToRightEdge() {
    let m: (String) -> Double = { Double($0.count) * 10.0 }
    let segs = [ParagraphSegment(charStart: 0, charEnd: 2, textAlign: .right)]
    let l = layoutTextWithParagraphs("hi", maxWidth: 100, fontSize: 16,
                                      paragraphs: segs, measure: m)
    #expect(l.glyphs[0].x == 80)
}

@Test func spaceBeforeSkippedForFirstParagraph() {
    let m: (String) -> Double = { Double($0.count) * 10.0 }
    let segs = [
        ParagraphSegment(charStart: 0, charEnd: 2, spaceBefore: 50, spaceAfter: 0),
        ParagraphSegment(charStart: 2, charEnd: 4, spaceBefore: 30),
    ]
    let l = layoutTextWithParagraphs("abcd", maxWidth: 100, fontSize: 16,
                                      paragraphs: segs, measure: m)
    #expect(l.lines.count == 2)
    #expect(l.lines[0].top == 0)        // first para: no space_before
    #expect(l.lines[1].top == 46)       // 16 (line) + 30 (space_before)
}

@Test func spaceAfterInsertsGap() {
    let m: (String) -> Double = { Double($0.count) * 10.0 }
    let segs = [
        ParagraphSegment(charStart: 0, charEnd: 2, spaceAfter: 20),
        ParagraphSegment(charStart: 2, charEnd: 4),
    ]
    let l = layoutTextWithParagraphs("abcd", maxWidth: 100, fontSize: 16,
                                      paragraphs: segs, measure: m)
    #expect(l.lines[1].top == 36)       // 16 + 20
}

@Test func alignmentWithIndentUsesRemainingWidth() {
    let m: (String) -> Double = { Double($0.count) * 10.0 }
    // "hi" centered in box of effective width 80 (100-20 left).
    // (80-20)/2 = 30; +20 leftIndent → x=50.
    let segs = [ParagraphSegment(charStart: 0, charEnd: 2,
                                  leftIndent: 20, textAlign: .center)]
    let l = layoutTextWithParagraphs("hi", maxWidth: 100, fontSize: 16,
                                      paragraphs: segs, measure: m)
    #expect(l.glyphs[0].x == 50)
}

// MARK: - buildParagraphSegments

@Test func buildSegmentsNoWrapperYieldsEmpty() {
    let segs = buildParagraphSegments(
        tspans: [Tspan(id: 0, content: "hello")],
        content: "hello", isArea: true)
    #expect(segs.isEmpty)
}

@Test func buildSegmentsSingleWrapperCoversContent() {
    let segs = buildParagraphSegments(
        tspans: [
            Tspan(id: 0, content: "", jasRole: "paragraph", jasLeftIndent: 12),
            Tspan(id: 1, content: "hello"),
        ],
        content: "hello", isArea: true)
    #expect(segs.count == 1)
    #expect(segs[0].charStart == 0)
    #expect(segs[0].charEnd == 5)
    #expect(segs[0].leftIndent == 12)
}

@Test func buildSegmentsTwoWrappersSplitContent() {
    let segs = buildParagraphSegments(
        tspans: [
            Tspan(id: 0, content: "", jasRole: "paragraph"),
            Tspan(id: 1, content: "ab"),
            Tspan(id: 2, content: "", jasRole: "paragraph",
                  textAlign: "center", jasSpaceBefore: 6),
            Tspan(id: 3, content: "cde"),
        ],
        content: "abcde", isArea: true)
    #expect(segs.count == 2)
    #expect(segs[0].charEnd == 2)
    #expect(segs[1].charStart == 2)
    #expect(segs[1].charEnd == 5)
    #expect(segs[1].spaceBefore == 6)
    #expect(segs[1].textAlign == TextAlign.center)
}

// MARK: - Phase 6 list markers

@Test func markerTextBullets() {
    #expect(markerText("bullet-disc", counter: 1) == "\u{2022}")
    #expect(markerText("bullet-open-circle", counter: 99) == "\u{25CB}")
    #expect(markerText("bullet-square", counter: 1) == "\u{25A0}")
    #expect(markerText("bullet-open-square", counter: 1) == "\u{25A1}")
    #expect(markerText("bullet-dash", counter: 1) == "\u{2013}")
    #expect(markerText("bullet-check", counter: 1) == "\u{2713}")
}

@Test func markerTextDecimal() {
    #expect(markerText("num-decimal", counter: 1) == "1.")
    #expect(markerText("num-decimal", counter: 42) == "42.")
}

@Test func markerTextAlpha() {
    #expect(markerText("num-lower-alpha", counter: 1) == "a.")
    #expect(markerText("num-lower-alpha", counter: 26) == "z.")
    #expect(markerText("num-lower-alpha", counter: 27) == "aa.")
    #expect(markerText("num-upper-alpha", counter: 28) == "AB.")
}

@Test func markerTextRoman() {
    #expect(markerText("num-lower-roman", counter: 1) == "i.")
    #expect(markerText("num-lower-roman", counter: 4) == "iv.")
    #expect(markerText("num-lower-roman", counter: 9) == "ix.")
    #expect(markerText("num-upper-roman", counter: 1990) == "MCMXC.")
}

@Test func markerTextUnknownStyleReturnsEmpty() {
    #expect(markerText("invented-style", counter: 1) == "")
}

@Test func computeCountersConsecutiveDecimalRun() {
    let segs = (0..<3).map { _ in
        ParagraphSegment(charStart: 0, charEnd: 0, listStyle: "num-decimal")
    }
    #expect(computeCounters(segs) == [1, 2, 3])
}

@Test func computeCountersBulletBreaksRun() {
    let segs = [
        ParagraphSegment(listStyle: "num-decimal"),
        ParagraphSegment(listStyle: "num-decimal"),
        ParagraphSegment(listStyle: "bullet-disc"),
        ParagraphSegment(listStyle: "num-decimal"),
    ]
    #expect(computeCounters(segs) == [1, 2, 0, 1])
}

@Test func computeCountersDifferentNumStyleResets() {
    let segs = [
        ParagraphSegment(listStyle: "num-decimal"),
        ParagraphSegment(listStyle: "num-decimal"),
        ParagraphSegment(listStyle: "num-lower-alpha"),
        ParagraphSegment(listStyle: "num-lower-alpha"),
    ]
    #expect(computeCounters(segs) == [1, 2, 1, 2])
}

@Test func computeCountersNoStyleBreaksRun() {
    let segs = [
        ParagraphSegment(listStyle: "num-decimal"),
        ParagraphSegment(listStyle: nil),
        ParagraphSegment(listStyle: "num-decimal"),
    ]
    #expect(computeCounters(segs) == [1, 0, 1])
}

@Test func listStylePushesTextByMarkerGap() {
    let m: (String) -> Double = { Double($0.count) * 10.0 }
    let segs = [ParagraphSegment(charStart: 0, charEnd: 2,
                                  listStyle: "bullet-disc",
                                  markerGap: 12)]
    let l = layoutTextWithParagraphs("hi", maxWidth: 100, fontSize: 16,
                                      paragraphs: segs, measure: m)
    #expect(l.glyphs[0].x == 12)
}

@Test func listStyleCombinesLeftIndentAndMarkerGap() {
    let m: (String) -> Double = { Double($0.count) * 10.0 }
    let segs = [ParagraphSegment(charStart: 0, charEnd: 2,
                                  leftIndent: 20,
                                  listStyle: "num-decimal",
                                  markerGap: 12)]
    let l = layoutTextWithParagraphs("hi", maxWidth: 100, fontSize: 16,
                                      paragraphs: segs, measure: m)
    #expect(l.glyphs[0].x == 32)
}

@Test func listStyleIgnoresFirstLineIndent() {
    let m: (String) -> Double = { Double($0.count) * 10.0 }
    let segs = [ParagraphSegment(charStart: 0, charEnd: 2,
                                  firstLineIndent: 25,
                                  listStyle: "bullet-disc",
                                  markerGap: 12)]
    let l = layoutTextWithParagraphs("hi", maxWidth: 100, fontSize: 16,
                                      paragraphs: segs, measure: m)
    #expect(l.glyphs[0].x == 12)  // not 12 + 25
}

@Test func listSegmentCarriesStyleAndMarkerGap() {
    let segs = buildParagraphSegments(
        tspans: [
            Tspan(id: 0, content: "", jasRole: "paragraph",
                  jasListStyle: "bullet-disc"),
            Tspan(id: 1, content: "hello"),
        ],
        content: "hello", isArea: true)
    #expect(segs[0].listStyle == "bullet-disc")
    #expect(segs[0].markerGap == markerGapPt)
}
