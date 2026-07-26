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
private let donutNonZeroHex = "4a4153000200000094919800c2cb3ff000000000000002c0c0c0919c07c2cb3ff000000000000002c0c0c0989300cb0000000000000000cb00000000000000009301cb4059000000000000cb00000000000000009301cb4059000000000000cb405900000000000091079300cb4039000000000000cb40390000000000009301cb4052c00000000000cb40390000000000009301cb4052c00000000000cb4052c000000000009107929600cb0000000000000000cb0000000000000000cb0000000000000000cb0000000000000000cb3ff0000000000000cb3ff0000000000000c0c000009090"
private let donutEvenOddHex = "4a4153000200000094919800c2cb3ff000000000000002c0c0c0919c07c2cb3ff000000000000002c0c0c0989300cb0000000000000000cb00000000000000009301cb4059000000000000cb00000000000000009301cb4059000000000000cb405900000000000091079300cb4039000000000000cb40390000000000009301cb4052c00000000000cb40390000000000009301cb4052c00000000000cb4052c000000000009107929600cb0000000000000000cb0000000000000000cb0000000000000000cb0000000000000000cb3ff0000000000000cb3ff0000000000000c0c001009090"
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

// MARK: - The corpus JSON boundary

/// The corpus JSON boundary must round-trip the fill rule, not just emit
/// it. The serializer has written `fill_rule` since the rule joined Path,
/// but the parser hardcoded `.nonzero` — so a corpus vector COULD NOT
/// express an even-odd path: any fixture declaring one would fail its own
/// json -> doc -> json round trip. Symmetric with Rust (both ports
/// emitted and neither parsed), so this was a write-only boundary rather
/// than a parity break, and it is fixed in both ports together. Twin of
/// Rust's `fill_rule_round_trips_through_test_json`.
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
