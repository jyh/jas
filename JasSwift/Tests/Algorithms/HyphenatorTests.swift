import Testing
@testable import JasLib

@Test func splitPatternSimple() {
    let (letters, digits) = splitPattern("2'2")
    #expect(letters == "'")
    #expect(digits == [2, 2])
}

@Test func splitPatternNoDigits() {
    let (letters, digits) = splitPattern("abc")
    #expect(letters == "abc")
    #expect(digits == [0, 0, 0, 0])
}

@Test func splitPatternWithWordAnchors() {
    let (letters, digits) = splitPattern(".un1")
    #expect(letters == ".un")
    #expect(digits == [0, 0, 0, 1])
}

@Test func emptyWordReturnsEmptyBreaks() {
    let breaks = hyphenate("", patterns: [".un1"], minBefore: 1, minAfter: 1)
    #expect(breaks.isEmpty)
}

@Test func noPatternsNoBreaks() {
    let breaks = hyphenate("hello", patterns: [], minBefore: 1, minAfter: 1)
    #expect(breaks.count == 6)
    #expect(breaks.allSatisfy { !$0 })
}

@Test func minBeforeSuppressesEarlyBreaks() {
    let patterns = ["1ello"]
    let breaks = hyphenate("hello", patterns: patterns, minBefore: 2, minAfter: 1)
    #expect(breaks[1] == false)
}

@Test func minAfterSuppressesLateBreaks() {
    let patterns = ["hell1o"]
    let breaks = hyphenate("hello", patterns: patterns, minBefore: 1, minAfter: 2)
    #expect(breaks[4] == false)
}

@Test func enUsSampleBreaksRepeat() {
    let breaks = hyphenate("repeat", patterns: enUsPatternsSample,
                           minBefore: 1, minAfter: 1)
    #expect(breaks[2] == true)
}
