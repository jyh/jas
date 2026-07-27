import Testing
@testable import JasLib

// The three vectors below are the ones where Unicode scalars and grapheme
// clusters disagree; every expected value is the reference implementation's
// `len(s) * char_width` (see CorpusTextMeasure.swift for the derivation).

@Test func corpusMeasureAsciiIsOneUnitPerLetter() {
    let m = fixedCharWidthMeasure(10)
    #expect(m("hello") == 50)
}

@Test func corpusMeasureCombiningMarkCountsAsItsOwnUnit() {
    let m = fixedCharWidthMeasure(10)
    // "a", "e", U+0301 COMBINING ACUTE, "b" = 4 scalars / 3 clusters.
    #expect(m("ae\u{301}b") == 40)
}

@Test func corpusMeasureZwjSequenceCountsEveryScalar() {
    let m = fixedCharWidthMeasure(10)
    // MAN ZWJ WOMAN ZWJ GIRL = 5 scalars / 1 cluster.
    #expect(m("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}") == 50)
}

@Test func corpusMeasureScalesLinearlyWithCharWidth() {
    // Guards the multiply as well as the count: a helper that ignored
    // charWidth would still pass the three cases above at width 10.
    let m = fixedCharWidthMeasure(2.5)
    #expect(m("ae\u{301}b") == 10)
}
