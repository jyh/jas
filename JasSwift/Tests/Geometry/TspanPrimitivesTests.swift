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

// MARK: - charToTspanPos / Affinity

@Test func charToTspanPosMidFirstTspan() {
    let base = [plainTspan("foo"), boldTspan("bar", id: 1)]
    #expect(charToTspanPos(base, 1, .left) == (0, 1))
    #expect(charToTspanPos(base, 1, .right) == (0, 1))
}

@Test func charToTspanPosMidLaterTspan() {
    let base = [plainTspan("foo"), boldTspan("bar", id: 1)]
    // char index 4 → (1, 1) — inside "bar"
    #expect(charToTspanPos(base, 4, .left) == (1, 1))
}

@Test func charToTspanPosBoundaryLeftAffinity() {
    let base = [plainTspan("foo"), boldTspan("bar", id: 1)]
    #expect(charToTspanPos(base, 3, .left) == (0, 3))
}

@Test func charToTspanPosBoundaryRightAffinity() {
    let base = [plainTspan("foo"), boldTspan("bar", id: 1)]
    #expect(charToTspanPos(base, 3, .right) == (1, 0))
}

@Test func charToTspanPosFinalBoundaryAlwaysEnd() {
    let base = [plainTspan("foo"), boldTspan("bar", id: 1)]
    #expect(charToTspanPos(base, 6, .left) == (1, 3))
    #expect(charToTspanPos(base, 6, .right) == (1, 3))
}

@Test func charToTspanPosBeyondEndClamps() {
    let base = [plainTspan("foo"), boldTspan("bar", id: 1)]
    #expect(charToTspanPos(base, 999, .left) == (1, 3))
}

@Test func charToTspanPosEmptyList() {
    let empty: [Tspan] = []
    #expect(charToTspanPos(empty, 0, .left) == (0, 0))
    #expect(charToTspanPos(empty, 5, .left) == (0, 0))
}

@Test func charToTspanPosSkipsEmptyTspans() {
    let base = [plainTspan("fo"), plainTspan("", id: 1), boldTspan("bar", id: 2)]
    #expect(charToTspanPos(base, 2, .left) == (0, 2))
    #expect(charToTspanPos(base, 2, .right) == (1, 0))
}

// MARK: - rich clipboard: JSON + SVG formats

@Test func jsonClipboardRoundtripPreservesContentAndOverrides() {
    let src = [plainTspan("foo"), boldTspan("bar", id: 1)]
    let json = tspansToJsonClipboard(src)
    let back = tspansFromJsonClipboard(json) ?? []
    #expect(back.count == 2)
    #expect(back[0].content == "foo")
    #expect(back[0].fontWeight == nil)
    #expect(back[1].content == "bar")
    #expect(back[1].fontWeight == "bold")
}

@Test func jsonClipboardStripsId() {
    let src = [Tspan(id: 42, content: "x")]
    let json = tspansToJsonClipboard(src)
    #expect(!json.contains("\"id\":42"))
    #expect(!json.contains("\"id\": 42"))
}

@Test func jsonClipboardStripsNullOverrides() {
    let src = [plainTspan("foo")]
    let json = tspansToJsonClipboard(src)
    #expect(!json.contains("null"))
}

@Test func jsonClipboardFromAssignsFreshIds() {
    let json = #"{"tspans":[{"content":"a"},{"content":"b"}]}"#
    let back = tspansFromJsonClipboard(json)!
    #expect(back.count == 2)
    #expect(back[0].id == 0)
    #expect(back[1].id == 1)
}

@Test func jsonClipboardRejectsBadPayload() {
    #expect(tspansFromJsonClipboard("not json") == nil)
    #expect(tspansFromJsonClipboard(#"{"not_tspans":[]}"#) == nil)
}

@Test func svgFragmentRoundtrip() {
    let src = [plainTspan("hello "), boldTspan("world", id: 1)]
    let svg = tspansToSvgFragment(src)
    #expect(svg.contains(#"<text xmlns="http://www.w3.org/2000/svg">"#))
    #expect(svg.contains("<tspan>hello </tspan>"))
    #expect(svg.contains(#"<tspan font-weight="bold">world</tspan>"#))
    let back = tspansFromSvgFragment(svg)!
    #expect(back.count == 2)
    #expect(back[0].content == "hello ")
    #expect(back[1].content == "world")
    #expect(back[1].fontWeight == "bold")
}

@Test func svgFragmentEscapesSpecialChars() {
    let src = [plainTspan("< & >")]
    let svg = tspansToSvgFragment(src)
    #expect(svg.contains("&lt; &amp; &gt;"))
    let back = tspansFromSvgFragment(svg)!
    #expect(back[0].content == "< & >")
}

@Test func svgFragmentRejectsMissingTextRoot() {
    #expect(tspansFromSvgFragment("<span>hi</span>") == nil)
}

// MARK: - jas:role wrapper tspan (Phase 1a)
//
// Paragraph wrapper tspans are tagged with jas:role="paragraph".
// Phase 1a only persists the role marker through clipboard SVG
// round-trips; paragraph attribute fields and Enter/Backspace edit
// primitives land in Phase 1b.

@Test func defaultTspanHasNoRole() {
    #expect(Tspan.defaultTspan().jasRole == nil)
}

@Test func hasNoOverridesFalseWhenJasRoleSet() {
    let t = Tspan(jasRole: "paragraph")
    #expect(!t.hasNoOverrides)
}

@Test func svgFragmentJasRoleRoundTrip() {
    let t = Tspan(content: "", jasRole: "paragraph")
    let svg = tspansToSvgFragment([t])
    #expect(svg.contains(#"jas:role="paragraph""#))
    let back = tspansFromSvgFragment(svg)!
    #expect(back.count == 1)
    #expect(back[0].jasRole == "paragraph")
}

// MARK: - Phase 3b panel-surface paragraph attrs

@Test func hasNoOverridesFalseWhenPhase3bAttrsSet() {
    #expect(!Tspan(jasLeftIndent: 12).hasNoOverrides)
    #expect(!Tspan(jasHyphenate: true).hasNoOverrides)
    #expect(!Tspan(jasListStyle: "bullet-disc").hasNoOverrides)
}

// MARK: - Phase 1b1 remaining panel-surface paragraph attrs

@Test func hasNoOverridesFalseWhenPhase1b1AttrsSet() {
    #expect(!Tspan(textAlign: "justify").hasNoOverrides)
    #expect(!Tspan(textIndent: -12).hasNoOverrides)
    #expect(!Tspan(jasSpaceBefore: 6).hasNoOverrides)
}

@Test func svgFragmentPhase1b1AttrsRoundTrip() {
    let t = Tspan(content: "",
                  jasRole: "paragraph",
                  textAlign: "justify",
                  textAlignLast: "center",
                  textIndent: -18,
                  jasSpaceBefore: 6,
                  jasSpaceAfter: 12)
    let svg = tspansToSvgFragment([t])
    #expect(svg.contains(#"text-align="justify""#))
    #expect(svg.contains(#"text-align-last="center""#))
    #expect(svg.contains(#"text-indent="-18""#))
    #expect(svg.contains(#"jas:space-before="6""#))
    #expect(svg.contains(#"jas:space-after="12""#))
    let back = tspansFromSvgFragment(svg)!
    #expect(back.count == 1)
    #expect(back[0].textAlign == "justify")
    #expect(back[0].textAlignLast == "center")
    #expect(back[0].textIndent == -18)
    #expect(back[0].jasSpaceBefore == 6)
    #expect(back[0].jasSpaceAfter == 12)
}

@Test func svgFragmentPhase3bAttrsRoundTrip() {
    let t = Tspan(content: "",
                  jasRole: "paragraph",
                  jasLeftIndent: 18,
                  jasRightIndent: 9,
                  jasHyphenate: true,
                  jasHangingPunctuation: true,
                  jasListStyle: "bullet-disc")
    let svg = tspansToSvgFragment([t])
    #expect(svg.contains(#"jas:left-indent="18""#))
    #expect(svg.contains(#"jas:right-indent="9""#))
    #expect(svg.contains(#"jas:hyphenate="true""#))
    #expect(svg.contains(#"jas:hanging-punctuation="true""#))
    #expect(svg.contains(#"jas:list-style="bullet-disc""#))
    let back = tspansFromSvgFragment(svg)!
    #expect(back.count == 1)
    #expect(back[0].jasLeftIndent == 18)
    #expect(back[0].jasRightIndent == 9)
    #expect(back[0].jasHyphenate == true)
    #expect(back[0].jasHangingPunctuation == true)
    #expect(back[0].jasListStyle == "bullet-disc")
}

// MARK: - Phase 1b2 / Phase 8 Justification dialog attrs

@Test func hasNoOverridesFalseWhenPhase8AttrsSet() {
    #expect(!Tspan(jasWordSpacingMin: 75).hasNoOverrides)
    #expect(!Tspan(jasLetterSpacingDesired: 5).hasNoOverrides)
    #expect(!Tspan(jasGlyphScalingMax: 105).hasNoOverrides)
    #expect(!Tspan(jasAutoLeading: 140).hasNoOverrides)
    #expect(!Tspan(jasSingleWordJustify: "left").hasNoOverrides)
}

@Test func svgFragmentPhase8AttrsRoundTrip() {
    let t = Tspan(content: "", jasRole: "paragraph",
                  jasWordSpacingMin: 75,
                  jasWordSpacingDesired: 95,
                  jasWordSpacingMax: 150,
                  jasLetterSpacingMin: -5,
                  jasLetterSpacingDesired: 0,
                  jasLetterSpacingMax: 10,
                  jasGlyphScalingMin: 95,
                  jasGlyphScalingDesired: 100,
                  jasGlyphScalingMax: 105,
                  jasAutoLeading: 140,
                  jasSingleWordJustify: "left")
    let svg = tspansToSvgFragment([t])
    #expect(svg.contains(#"jas:word-spacing-min="75""#))
    #expect(svg.contains(#"jas:letter-spacing-desired="0""#))
    #expect(svg.contains(#"jas:glyph-scaling-max="105""#))
    #expect(svg.contains(#"jas:auto-leading="140""#))
    #expect(svg.contains(#"jas:single-word-justify="left""#))
    let back = tspansFromSvgFragment(svg)!
    #expect(back.count == 1)
    #expect(back[0].jasWordSpacingMin == 75)
    #expect(back[0].jasWordSpacingDesired == 95)
    #expect(back[0].jasWordSpacingMax == 150)
    #expect(back[0].jasLetterSpacingMin == -5)
    #expect(back[0].jasLetterSpacingDesired == 0)
    #expect(back[0].jasLetterSpacingMax == 10)
    #expect(back[0].jasGlyphScalingMin == 95)
    #expect(back[0].jasGlyphScalingDesired == 100)
    #expect(back[0].jasGlyphScalingMax == 105)
    #expect(back[0].jasAutoLeading == 140)
    #expect(back[0].jasSingleWordJustify == "left")
}
