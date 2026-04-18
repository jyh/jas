import Testing
import Foundation
@testable import JasLib

/// Path to the shared cross-language fixtures, resolved from this
/// source file so tests run from any cwd.
private func fixtureRoot() -> String {
    let thisFile = #filePath
    let testsDir = (thisFile as NSString).deletingLastPathComponent  // Tests/Geometry
    let jasTests = (testsDir as NSString).deletingLastPathComponent  // Tests
    let jasSwift = (jasTests as NSString).deletingLastPathComponent  // JasSwift
    return (jasSwift as NSString).appendingPathComponent("../test_fixtures")
}

private func loadFixture(_ relPath: String) -> [String: Any] {
    let full = (fixtureRoot() as NSString).appendingPathComponent(relPath)
    let standardized = (full as NSString).standardizingPath
    guard let data = FileManager.default.contents(atPath: standardized),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { fatalError("Failed to read fixture: \(standardized)") }
    return obj
}

/// Small inline tspan parser for fixture JSON. Converts snake_case
/// field names to the Swift camelCase on Tspan. Transform fixtures
/// aren't used in the primitive vectors, so `transform` stays nil.
private func tspanFromJSON(_ d: [String: Any]) -> Tspan {
    let decor: [String]?
    if let arr = d["text_decoration"] as? [Any] {
        decor = arr.compactMap { $0 as? String }
    } else {
        decor = nil
    }
    return Tspan(
        id: UInt32((d["id"] as? NSNumber)?.intValue ?? 0),
        content: d["content"] as? String ?? "",
        baselineShift: (d["baseline_shift"] as? NSNumber)?.doubleValue,
        dx: (d["dx"] as? NSNumber)?.doubleValue,
        fontFamily: d["font_family"] as? String,
        fontSize: (d["font_size"] as? NSNumber)?.doubleValue,
        fontStyle: d["font_style"] as? String,
        fontVariant: d["font_variant"] as? String,
        fontWeight: d["font_weight"] as? String,
        jasAaMode: d["jas_aa_mode"] as? String,
        jasFractionalWidths: d["jas_fractional_widths"] as? Bool,
        jasKerningMode: d["jas_kerning_mode"] as? String,
        jasNoBreak: d["jas_no_break"] as? Bool,
        letterSpacing: (d["letter_spacing"] as? NSNumber)?.doubleValue,
        lineHeight: (d["line_height"] as? NSNumber)?.doubleValue,
        rotate: (d["rotate"] as? NSNumber)?.doubleValue,
        styleName: d["style_name"] as? String,
        textDecoration: decor,
        textRendering: d["text_rendering"] as? String,
        textTransform: d["text_transform"] as? String,
        transform: nil,
        xmlLang: d["xml_lang"] as? String
    )
}

private func parseTspans(_ v: Any?) -> [Tspan] {
    (v as? [[String: Any]] ?? []).map(tspanFromJSON)
}

private func optInt(_ v: Any?) -> Int? {
    (v as? NSNumber)?.intValue
}

// MARK: - default_tspan

@Test func tspanDefaultMatchesFixtures() {
    let file = loadFixture("algorithms/tspan_default.json")
    let vectors = file["vectors"] as? [[String: Any]] ?? []
    for v in vectors {
        let expected = tspanFromJSON(v["expected"] as? [String: Any] ?? [:])
        let got = Tspan.defaultTspan()
        #expect(got == expected, "vector \(v["name"] ?? "?")")
        #expect(got.id == 0)
        #expect(got.content.isEmpty)
        #expect(got.hasNoOverrides)
    }
}

// MARK: - concat_content

@Test func tspanConcatContentMatchesFixtures() {
    let file = loadFixture("algorithms/tspan_concat_content.json")
    let vectors = file["vectors"] as? [[String: Any]] ?? []
    for v in vectors {
        let tspans = parseTspans(v["tspans"])
        let expected = v["expected"] as? String ?? ""
        #expect(concatTspanContent(tspans) == expected, "vector \(v["name"] ?? "?")")
    }
}

// MARK: - resolve_id

@Test func tspanResolveIdMatchesFixtures() {
    let file = loadFixture("algorithms/tspan_resolve_id.json")
    let vectors = file["vectors"] as? [[String: Any]] ?? []
    for v in vectors {
        let input = v["input"] as? [String: Any] ?? [:]
        let tspans = parseTspans(input["tspans"])
        let id = UInt32((input["id"] as? NSNumber)?.intValue ?? 0)
        let expected = optInt(v["expected"])
        #expect(resolveTspanId(tspans, id: id) == expected, "vector \(v["name"] ?? "?")")
    }
}

// MARK: - split

@Test func tspanSplitMatchesFixtures() {
    let file = loadFixture("algorithms/tspan_split.json")
    let vectors = file["vectors"] as? [[String: Any]] ?? []
    for v in vectors {
        let input = v["input"] as? [String: Any] ?? [:]
        let tspans = parseTspans(input["tspans"])
        let idx = (input["tspan_idx"] as? NSNumber)?.intValue ?? 0
        let offset = (input["offset"] as? NSNumber)?.intValue ?? 0

        let (got, leftIdx, rightIdx) = splitTspans(tspans, tspanIdx: idx, offset: offset)
        let expected = v["expected"] as? [String: Any] ?? [:]
        let expectedTspans = parseTspans(expected["tspans"])
        let expectedLeft = optInt(expected["left_idx"])
        let expectedRight = optInt(expected["right_idx"])

        let name = v["name"] ?? "?"
        #expect(got == expectedTspans, "vector \(name) tspans")
        #expect(leftIdx == expectedLeft, "vector \(name) left_idx")
        #expect(rightIdx == expectedRight, "vector \(name) right_idx")
    }
}

// MARK: - split_range

@Test func tspanSplitRangeMatchesFixtures() {
    let file = loadFixture("algorithms/tspan_split_range.json")
    let vectors = file["vectors"] as? [[String: Any]] ?? []
    for v in vectors {
        let input = v["input"] as? [String: Any] ?? [:]
        let tspans = parseTspans(input["tspans"])
        let start = (input["char_start"] as? NSNumber)?.intValue ?? 0
        let end = (input["char_end"] as? NSNumber)?.intValue ?? 0

        let (got, firstIdx, lastIdx) = splitTspanRange(tspans, charStart: start, charEnd: end)
        let expected = v["expected"] as? [String: Any] ?? [:]
        let expectedTspans = parseTspans(expected["tspans"])
        let expectedFirst = optInt(expected["first_idx"])
        let expectedLast = optInt(expected["last_idx"])

        let name = v["name"] ?? "?"
        #expect(got == expectedTspans, "vector \(name) tspans")
        #expect(firstIdx == expectedFirst, "vector \(name) first_idx")
        #expect(lastIdx == expectedLast, "vector \(name) last_idx")
    }
}

// MARK: - merge

@Test func tspanMergeMatchesFixtures() {
    let file = loadFixture("algorithms/tspan_merge.json")
    let vectors = file["vectors"] as? [[String: Any]] ?? []
    for v in vectors {
        let input = v["input"] as? [String: Any] ?? [:]
        let expected = v["expected"] as? [String: Any] ?? [:]
        let got = mergeTspans(parseTspans(input["tspans"]))
        let expectedTspans = parseTspans(expected["tspans"])
        #expect(got == expectedTspans, "vector \(v["name"] ?? "?")")
    }
}

// MARK: - Hand-written sanity tests (independent of fixtures)

@Test func tspanSplitPreservesAttributeOverridesOnBothSides() {
    let original = Tspan(id: 0, content: "Hello", fontWeight: "bold")
    let (got, _, _) = splitTspans([original], tspanIdx: 0, offset: 2)
    #expect(got.count == 2)
    #expect(got[0].fontWeight == "bold")
    #expect(got[1].fontWeight == "bold")
    #expect(got[0].content == "He")
    #expect(got[1].content == "llo")
    #expect(got[0].id == 0)
    #expect(got[1].id == 1)
}

@Test func tspanMergePreservesAttributeOverrides() {
    let a = Tspan(id: 0, content: "A", fontWeight: "bold")
    let b = Tspan(id: 1, content: "B", fontWeight: "bold")
    let got = mergeTspans([a, b])
    #expect(got.count == 1)
    #expect(got[0].content == "AB")
    #expect(got[0].fontWeight == "bold")
    #expect(got[0].id == 0)
}

@Test func tspanMergeDoesNotCombineDifferentOverrides() {
    let a = Tspan(id: 0, content: "A", fontWeight: "bold")
    let b = Tspan(id: 1, content: "B", fontWeight: "normal")
    let got = mergeTspans([a, b])
    #expect(got.count == 2)
}

@Test func tspanResolveIdAfterMergeLosesRightId() {
    let a = Tspan(id: 0, content: "A")
    let b = Tspan(id: 3, content: "B")
    let merged = mergeTspans([a, b])
    #expect(resolveTspanId(merged, id: 0) == 0)
    #expect(resolveTspanId(merged, id: 3) == nil)
}

@Test func tspanMergeOfAllEmptyReturnsSingleDefault() {
    let got = mergeTspans([Tspan(id: 5, content: ""), Tspan(id: 7, content: "")])
    #expect(got.count == 1)
    #expect(got[0].content.isEmpty)
    #expect(got[0].id == 0)
    #expect(got[0].hasNoOverrides)
}

// MARK: - reconcileTspanContent

private func boldTspan(_ s: String, id: UInt32 = 0) -> Tspan {
    Tspan(id: id, content: s, fontWeight: "bold")
}
private func plainTspan(_ s: String, id: UInt32 = 0) -> Tspan {
    Tspan(id: id, content: s)
}

@Test func reconcileIdentityPassesThrough() {
    let ts = [plainTspan("Hello "), boldTspan("world", id: 1)]
    #expect(reconcileTspanContent(ts, "Hello world") == ts)
}

@Test func reconcileAppendExtendsLastTspan() {
    let ts = [plainTspan("Hello "), boldTspan("world", id: 1)]
    let r = reconcileTspanContent(ts, "Hello world!")
    #expect(r.count == 2)
    #expect(r[0].content == "Hello ")
    #expect(r[1].content == "world!")
    #expect(r[1].fontWeight == "bold")
}

@Test func reconcilePrependExtendsFirstTspan() {
    let ts = [plainTspan("Hello "), boldTspan("world", id: 1)]
    let r = reconcileTspanContent(ts, "Say Hello world")
    #expect(r.count == 2)
    #expect(r[0].content == "Say Hello ")
    #expect(r[1].content == "world")
    #expect(r[1].fontWeight == "bold")
}

@Test func reconcileEditInsidePreservesNeighbour() {
    let ts = [plainTspan("Hello "), boldTspan("world", id: 1)]
    let r = reconcileTspanContent(ts, "Hellooo world")
    #expect(r.count == 2)
    #expect(r[0].content == "Hellooo ")
    #expect(r[0].fontWeight == nil)
    #expect(r[1].content == "world")
    #expect(r[1].fontWeight == "bold")
}

@Test func reconcileDeleteInside() {
    let ts = [plainTspan("Hello "), boldTspan("world", id: 1)]
    let r = reconcileTspanContent(ts, "Helo world")
    #expect(r.count == 2)
    #expect(r[0].content == "Helo ")
    #expect(r[1].content == "world")
}

@Test func reconcileBoundaryReplaceAbsorbsIntoFirstOverlapping() {
    let ts = [plainTspan("Hello "), boldTspan("world", id: 1)]
    let r = reconcileTspanContent(ts, "HelloXXworld")
    #expect(r.count == 2)
    #expect(r[0].content == "HelloXX")
    #expect(r[0].fontWeight == nil)
    #expect(r[1].content == "world")
    #expect(r[1].fontWeight == "bold")
}

@Test func reconcileDeleteAllYieldsSingleDefault() {
    let ts = [plainTspan("Hello "), boldTspan("world", id: 1)]
    let r = reconcileTspanContent(ts, "")
    #expect(r.count == 1)
    #expect(r[0].content == "")
    #expect(r[0].hasNoOverrides)
}

@Test func reconcileFullReplacementCollapses() {
    let ts = [plainTspan("abc"), boldTspan("def", id: 1)]
    let r = reconcileTspanContent(ts, "xyz")
    #expect(r.count == 1)
    #expect(r[0].content == "xyz")
}

@Test func reconcilePreservesUtf8Boundaries() {
    let ts = [plainTspan("café "), boldTspan("naïve", id: 1)]
    let r = reconcileTspanContent(ts, "café plus naïve")
    #expect(r.count == 2)
    #expect(r[0].content == "café plus ")
    #expect(r[1].content == "naïve")
    #expect(r[1].fontWeight == "bold")
}

@Test func reconcileRunsMergeCleanup() {
    let ts = [plainTspan("a"), plainTspan("b", id: 1), boldTspan("C", id: 2)]
    let r = reconcileTspanContent(ts, "ab")
    #expect(r.count == 1)
    #expect(r[0].content == "ab")
}

// MARK: - copyTspanRange

@Test func copyRangeEmptyReturnsEmpty() {
    let ts = [plainTspan("hello")]
    #expect(copyTspanRange(ts, charStart: 2, charEnd: 2).isEmpty)
    #expect(copyTspanRange(ts, charStart: 3, charEnd: 1).isEmpty)
}

@Test func copyRangeInsideSingleTspanPreservesOverrides() {
    let ts = [boldTspan("bold text")]
    let r = copyTspanRange(ts, charStart: 5, charEnd: 9)
    #expect(r.count == 1)
    #expect(r[0].content == "text")
    #expect(r[0].fontWeight == "bold")
}

@Test func copyRangeAcrossBoundaryReturnsPartialTspans() {
    let ts = [plainTspan("foo"), boldTspan("bar", id: 1)]
    let r = copyTspanRange(ts, charStart: 1, charEnd: 5)
    #expect(r.count == 2)
    #expect(r[0].content == "oo")
    #expect(r[0].fontWeight == nil)
    #expect(r[1].content == "ba")
    #expect(r[1].fontWeight == "bold")
}

@Test func copyRangeSaturatesToTotal() {
    let ts = [plainTspan("hi")]
    let r = copyTspanRange(ts, charStart: 0, charEnd: 999)
    #expect(r.count == 1)
    #expect(r[0].content == "hi")
}

// MARK: - insertTspansAt

@Test func insertTspansAtBoundaryBetweenTspans() {
    let base = [plainTspan("foo"), boldTspan("bar", id: 1)]
    let ins = [boldTspan("X")]
    let r = insertTspansAt(base, charPos: 3, ins)
    #expect(r.count == 2)
    #expect(r[0].content == "foo")
    #expect(r[1].content == "Xbar")
    #expect(r[1].fontWeight == "bold")
}

@Test func insertTspansAtInsideATspanSplits() {
    let base = [plainTspan("hello")]
    let ins = [boldTspan("X")]
    let r = insertTspansAt(base, charPos: 2, ins)
    #expect(r.count == 3)
    #expect(r[0].content == "he")
    #expect(r[0].fontWeight == nil)
    #expect(r[1].content == "X")
    #expect(r[1].fontWeight == "bold")
    #expect(r[2].content == "llo")
    #expect(r[2].fontWeight == nil)
}

@Test func insertTspansAtPrependAtZero() {
    let base = [plainTspan("hello")]
    let ins = [boldTspan("Say ")]
    let r = insertTspansAt(base, charPos: 0, ins)
    #expect(r.count == 2)
    #expect(r[0].content == "Say ")
    #expect(r[0].fontWeight == "bold")
    #expect(r[1].content == "hello")
}

@Test func insertTspansAtAppendAtEnd() {
    let base = [plainTspan("hello")]
    let ins = [boldTspan("!")]
    let r = insertTspansAt(base, charPos: 5, ins)
    #expect(r.count == 2)
    #expect(r[1].content == "!")
    #expect(r[1].fontWeight == "bold")
}

@Test func insertTspansAtReassignsIds() {
    let base = [Tspan(id: 0, content: "abc")]
    let ins = [Tspan(id: 0, content: "X", fontWeight: "bold")]
    let r = insertTspansAt(base, charPos: 1, ins)
    var ids = r.map(\.id)
    ids.sort()
    // All ids must be distinct.
    #expect(Set(ids).count == ids.count)
}

@Test func insertEmptyIsNoop() {
    let base = [plainTspan("hello")]
    #expect(insertTspansAt(base, charPos: 2, []) == base)
    #expect(insertTspansAt(base, charPos: 2, [plainTspan("")]) == base)
}

@Test func copyThenInsertRoundtripPreservesOverrides() {
    let base = [plainTspan("foo"), boldTspan("bar", id: 1)]
    let clipboard = copyTspanRange(base, charStart: 3, charEnd: 6)
    let r = insertTspansAt(base, charPos: 0, clipboard)
    #expect(concatTspanContent(r) == "barfoobar")
    // Original bold "bar" + clipboard bold "bar" both present.
    #expect(r.contains { $0.content.contains("bar") && $0.fontWeight == "bold" })
}
