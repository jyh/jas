import Testing
@testable import JasLib

private func b(_ width: Double, _ idx: Int) -> KPItem {
    .box(width: width, charIdx: idx)
}
private func g(_ width: Double, _ idx: Int) -> KPItem {
    .glue(width: width, stretch: width * 0.5, shrink: width * 0.33, charIdx: idx)
}
private func gWide(_ width: Double, _ idx: Int) -> KPItem {
    .glue(width: width, stretch: 20, shrink: 5, charIdx: idx)
}
private func filGlue(_ idx: Int) -> KPItem {
    .glue(width: 0, stretch: 1e9, shrink: 0, charIdx: idx)
}
private func forced(_ idx: Int) -> KPItem {
    .penalty(width: 0, value: -kpPenaltyInfinity, flagged: false, charIdx: idx)
}

@Test func kpEmptyReturnsEmpty() {
    let breaks = kpCompose(items: [], lineWidths: [100])!
    #expect(breaks.isEmpty)
}

@Test func kpThreeWordsOneLineWideEnough() {
    let items: [KPItem] = [
        b(30, 0), g(10, 3), b(30, 4), g(10, 7), b(30, 8),
        filGlue(11), forced(11),
    ]
    let breaks = kpCompose(items: items, lineWidths: [200])!
    #expect(breaks.count == 1)
    #expect(breaks[0].itemIdx == items.count - 1)
}

@Test func kpThreeWordsTwoLinesNarrow() {
    let items: [KPItem] = [
        b(30, 0), g(10, 3), b(30, 4), g(10, 7), b(30, 8),
        filGlue(11), forced(11),
    ]
    let breaks = kpCompose(items: items, lineWidths: [70])!
    #expect(breaks.count == 2)
    #expect(breaks[0].itemIdx == 3)
}

private func hyphenCorpus(penalty: Double) -> [KPItem] {
    [
        b(35, 0), gWide(5, 2), b(50, 3), g(5, 8), b(10, 9),
        .penalty(width: 5, value: penalty, flagged: true, charIdx: 11),
        b(10, 11), filGlue(13), forced(13),
    ]
}

@Test func kpHyphenPenaltyDiscouragesHigh() {
    let items = hyphenCorpus(penalty: 1000)
    let breaks = kpCompose(items: items, lineWidths: [110])!
    let usedHyphen = breaks.contains { $0.itemIdx == 5 }
    #expect(!usedHyphen)
}

@Test func kpHyphenPenaltyTakenLow() {
    let items = hyphenCorpus(penalty: 10)
    let breaks = kpCompose(items: items, lineWidths: [110])!
    let usedHyphen = breaks.contains { $0.itemIdx == 5 }
    #expect(usedHyphen)
}
