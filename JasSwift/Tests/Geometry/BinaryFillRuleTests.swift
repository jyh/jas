import Foundation
import Testing
@testable import JasLib

/// A Path's declared `fillRule` must survive the binary codec, and the
/// bytes must match jas_dioxus exactly.
///
/// Twin of jas_dioxus `src/geometry/binary.rs` mod tests. The hex
/// literals below are the SAME literals that port asserts — that is what
/// makes "the two ports are byte-identical" a checked statement rather
/// than a claim. Both write the rule as a trailing TAG_PATH slot 11
/// integer (0 = nonzero, 1 = evenodd), always emitted.
///
/// The field is APPENDED, not versioned: the header stays at v2. A
/// version bump would make the frozen reference port — which rejects
/// `version > 2` — unable to read anything the active ports write, and
/// would orphan documents for no gain. Absent slot reads as `.nonzero`,
/// which is the value those documents were written with. This is the
/// same trailing-append convention already used for `widthPoints`
/// (slot 10) and Text's `tspans` (slot 19).

// MARK: - Fixture (identical geometry to the Rust twin's `donut_doc`)

private func donutCommands() -> [PathCommand] {
    [.moveTo(0, 0), .lineTo(100, 0), .lineTo(100, 100), .closePath,
     .moveTo(25, 25), .lineTo(75, 25), .lineTo(75, 75), .closePath]
}

private func donutDoc(_ rule: FillRule) -> Document {
    let path = Element.path(Path(d: donutCommands(),
                                 fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                                 fillRule: rule))
    return Document(layers: [Layer(children: [path])], selectedLayer: 0)
}

private func firstPathRule(_ doc: Document) -> FillRule? {
    guard case .path(let p) = doc.layers[0].children[0] else { return nil }
    return p.fillRule
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func unhex(_ s: String) -> Data {
    var out = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

/// The uncompressed blob for `donutDoc`, byte for byte — shared with
/// jas_dioxus (`DONUT_NON_ZERO_HEX` / `DONUT_EVEN_ODD_HEX`).
/// To regenerate after an intentional codec change: print
/// `documentToBinary(donutDoc(rule), compress: false)` as hex and update
/// BOTH ports.
private let donutNonZeroHex = "4a4153000200000094919b00c2cb3ff000000000000002c0c0c091dc001107c2cb3ff000000000000002c0c0c0989300cb0000000000000000cb00000000000000009301cb4059000000000000cb00000000000000009301cb4059000000000000cb405900000000000091079300cb4039000000000000cb40390000000000009301cb4052c00000000000cb40390000000000009301cb4052c00000000000cb4052c000000000009107929600cb0000000000000000cb0000000000000000cb0000000000000000cb0000000000000000cb3ff0000000000000cb3ff0000000000000c0c00000c0c0c0c000c0c0009090"
private let donutEvenOddHex = "4a4153000200000094919b00c2cb3ff000000000000002c0c0c091dc001107c2cb3ff000000000000002c0c0c0989300cb0000000000000000cb00000000000000009301cb4059000000000000cb00000000000000009301cb4059000000000000cb405900000000000091079300cb4039000000000000cb40390000000000009301cb4052c00000000000cb40390000000000009301cb4052c00000000000cb4052c000000000009107929600cb0000000000000000cb0000000000000000cb0000000000000000cb0000000000000000cb3ff0000000000000cb3ff0000000000000c0c00100c0c0c0c000c0c0009090"
/// The SAME document as written BEFORE the per-tag common extension
/// (RULED 2026-07-27) joined the codec: TAG_LAYER carries 8 slots (0x98)
/// and TAG_PATH 12 (0x9c), with no mode / mask / toolOrigin / strokeBrush
/// / strokeBrushOverrides tail. These were the pinned literals up to that
/// commit, kept verbatim -- the tolerant-read contract is only worth
/// something if it is checked against REAL old bytes rather than bytes the
/// current writer reconstructed. Shared with Rust's
/// `DONUT_PRE_EXT_NON_ZERO_HEX` / `DONUT_PRE_EXT_EVEN_ODD_HEX`.
private let donutPreExtNonZeroHex = "4a4153000200000094919800c2cb3ff000000000000002c0c0c0919c07c2cb3ff000000000000002c0c0c0989300cb0000000000000000cb00000000000000009301cb4059000000000000cb00000000000000009301cb4059000000000000cb405900000000000091079300cb4039000000000000cb40390000000000009301cb4052c00000000000cb40390000000000009301cb4052c00000000000cb4052c000000000009107929600cb0000000000000000cb0000000000000000cb0000000000000000cb0000000000000000cb3ff0000000000000cb3ff0000000000000c0c000009090"
private let donutPreExtEvenOddHex = "4a4153000200000094919800c2cb3ff000000000000002c0c0c0919c07c2cb3ff000000000000002c0c0c0989300cb0000000000000000cb00000000000000009301cb4059000000000000cb00000000000000009301cb4059000000000000cb405900000000000091079300cb4039000000000000cb40390000000000009301cb4052c00000000000cb40390000000000009301cb4052c00000000000cb4052c000000000009107929600cb0000000000000000cb0000000000000000cb0000000000000000cb0000000000000000cb3ff0000000000000cb3ff0000000000000c0c001009090"
/// The same document as written BEFORE fillRule joined the codec: the
/// TAG_PATH array header is 0x9b (11 slots) instead of 0x9c (12) and the
/// trailing tag byte is gone. Kept as a literal so the old-format read
/// path is pinned against real bytes, not against a value reconstructed
/// with the current writer. Shared with Rust's
/// `DONUT_PRE_FILL_RULE_HEX`.
private let donutPreFillRuleHex = "4a4153000200000094919800c2cb3ff000000000000002c0c0c0919b07c2cb3ff000000000000002c0c0c0989300cb0000000000000000cb00000000000000009301cb4059000000000000cb00000000000000009301cb4059000000000000cb405900000000000091079300cb4039000000000000cb40390000000000009301cb4052c00000000000cb40390000000000009301cb4052c00000000000cb4052c000000000009107929600cb0000000000000000cb0000000000000000cb0000000000000000cb0000000000000000cb3ff0000000000000cb3ff0000000000000c0c0009090"

// MARK: - Tests

@Test func binaryRoundTripsEvenOddFillRule() throws {
    for rule in [FillRule.nonzero, FillRule.evenodd] {
        let blob = documentToBinary(donutDoc(rule))
        let back = try binaryToDocument(blob)
        #expect(firstPathRule(back) == rule,
                "binary dropped the declared fill rule \(rule)")
    }
}

@Test func binaryBytesArePinnedForBothFillRules() {
    #expect(hex(documentToBinary(donutDoc(.nonzero), compress: false))
            == donutNonZeroHex)
    #expect(hex(documentToBinary(donutDoc(.evenodd), compress: false))
            == donutEvenOddHex)
    // Exactly one byte of difference: the appended tag.
    let a = [UInt8](unhex(donutNonZeroHex))
    let b = [UInt8](unhex(donutEvenOddHex))
    #expect(a.count == b.count)
    #expect((0..<a.count).filter { a[$0] != b[$0] }.count == 1,
            "the rule must cost exactly one byte")
}

@Test func binaryReadsAPreFillRuleBlob() throws {
    let doc = try binaryToDocument(unhex(donutPreFillRuleHex))
    #expect(firstPathRule(doc) == .nonzero,
            "an absent fillRule slot must read as the app default")
    // And it is otherwise the same document, so the read path is not
    // just returning a default-shaped husk.
    #expect(doc.layers[0].children.count == 1)
    guard case .path(let p) = doc.layers[0].children[0] else {
        Issue.record("expected Path")
        return
    }
    #expect(p.d.count == 8)
}

// MARK: - Tolerance of a hostile / corrupt fill-rule slot

/// A PRE-EXTENSION blob (8 layer slots, 12 path slots) with the fill-rule
/// slot's `00` replaced by `slotHex`. Built from the PRE-fillRule literal so the splice point is
/// derived from real bytes rather than an index counted by hand: bump the
/// TAG_PATH array header from 11 slots to 12, then insert the slot just
/// before the document's trailing `selected_layer` + two empty arrays.
private func donutWithFillRuleSlot(_ slotHex: String) -> Data {
    let tail = "009090"
    let head = donutPreFillRuleHex
        .replacingOccurrences(of: "919b07", with: "919c07")
    let body = String(head.dropLast(tail.count))
    return unhex(body + slotHex + tail)
}

/// The splice reproduces the PRE-EXTENSION writer exactly, which is what
/// makes the tolerance vectors below statements about a format that really
/// existed on disk rather than about a string we assembled. Twin of Rust's
/// `fill_rule_slot_splice_matches_the_pre_extension_writer`.
@Test func fillRuleSlotSpliceMatchesThePreExtensionWriter() {
    #expect(hex(donutWithFillRuleSlot("00")) == donutPreExtNonZeroHex)
    #expect(hex(donutWithFillRuleSlot("01")) == donutPreExtEvenOddHex)
}

/// A pre-extension blob loads with the fill rule it was written with AND the
/// documented defaults for every extension slot -- the tolerant read checked
/// against real old bytes, not a reconstruction. Twin of Rust's
/// `binary_reads_a_pre_extension_blob`.
@Test func binaryReadsAPreExtensionBlob() throws {
    for (literal, rule) in [(donutPreExtNonZeroHex, FillRule.nonzero),
                            (donutPreExtEvenOddHex, FillRule.evenodd)] {
        let doc = try binaryToDocument(unhex(literal))
        #expect(firstPathRule(doc) == rule)
        guard case .path(let p) = doc.layers[0].children[0] else {
            Issue.record("expected Path")
            return
        }
        #expect(p.blendMode == .normal)
        #expect(p.mask == nil)
        #expect(p.toolOrigin == nil)
        #expect(p.strokeBrush == nil)
        #expect(p.strokeBrushOverrides == nil)
        #expect(doc.layers[0].blendMode == .normal)
        // Geometry, so the rows above are not a statement about a husk.
        #expect(p.d.count == 8)
    }
}

/// A blob whose fill-rule slot is not an integer must read as `.nonzero`,
/// not trap.
///
/// Rust's `unpack_fill_rule` is `v.as_i64().or_else(as_u64)` with
/// `_ => NonZero`, so msgpack nil, a string, an array and even a float all
/// fall through to NonZero there. Swift's version guarded only the Swift
/// optional and then called `asInt`, which `fatalError`s on anything that
/// is not an int or a float — so a corrupt or hostile localStorage blob
/// TRAPPED the Swift app on a slot Rust merely shrugs at. jas_dioxus holds
/// a standing contract that a malformed-but-decodable blob errors rather
/// than panicking (`malformed_but_decodable_blob_errors_not_panics`);
/// this slot is Swift's side of it.
///
/// The float case is included because it diverged the other way: `asInt`
/// happily truncated a float64 1.0 to EvenOdd where Rust reads NonZero.
///
/// If the read ever traps again this test cannot report a failed
/// expectation — `fatalError` aborts the whole test process. A crashed
/// `swift test` run IS the signal.
@Test func binaryToleratesAMalformedFillRuleSlot() throws {
    let cases: [(String, String)] = [
        ("msgpack nil", "c0"),
        ("a string", "a178"),           // fixstr "x"
        ("an empty array", "90"),
        ("a float64 1.0", "cb3ff0000000000000"),
        ("an out-of-range tag", "07"),  // positive fixint 7
    ]
    for (label, slotHex) in cases {
        let doc = try binaryToDocument(donutWithFillRuleSlot(slotHex))
        #expect(firstPathRule(doc) == .nonzero,
                "a fill-rule slot holding \(label) must read as .nonzero")
        // Not a default-shaped husk: the rest of the element survived.
        guard case .path(let p) = doc.layers[0].children[0] else {
            Issue.record("expected Path for \(label)")
            return
        }
        #expect(p.d.count == 8, "\(label) lost the path geometry")
    }
}

// MARK: - The corpus JSON boundary

/// The corpus JSON boundary must round-trip the fill rule, not just emit
/// it. The serializer has written `fill_rule` since the rule joined Path,
/// but the parser hardcoded `.nonzero` — so a corpus vector COULD NOT
/// express an even-odd path: any fixture declaring one would fail its own
/// json -> doc -> json round trip. Symmetric with Rust (both ports
/// emitted and neither parsed), so this was a write-only boundary rather
/// than a parity break, and it is fixed in both ports together. Twin of
/// Rust's `fill_rule_round_trips_through_test_json`, whose doc records
/// exactly which corpus fixtures do mention a fill rule (three of them,
/// none reachable through this parser) and corrects an earlier commit
/// message that claimed there were none.
@Test func fillRuleRoundTripsThroughTestJson() {
    for rule in [FillRule.nonzero, FillRule.evenodd] {
        let path = Element.path(Path(d: [.moveTo(0, 0), .lineTo(10, 0),
                                         .lineTo(10, 10), .closePath],
                                     fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                                     fillRule: rule))
        let doc = Document(layers: [Layer(children: [path])], selectedLayer: 0)
        let json = documentToTestJson(doc)
        let back = testJsonToDocument(json)
        guard case .path(let p) = back.layers[0].children[0] else {
            Issue.record("expected Path")
            return
        }
        #expect(p.fillRule == rule, "test_json dropped \(rule)")
        // Canonicality: the fixture form is a fixed point, which is what
        // every corpus golden comparison relies on.
        #expect(documentToTestJson(back) == json)
    }
}
