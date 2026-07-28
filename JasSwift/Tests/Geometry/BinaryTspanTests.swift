import Foundation
import Testing
@testable import JasLib

/// The binary codec's TSPAN payload, field for field.
///
/// FOUND BY MEASUREMENT 2026-07-27, by the byte-level wire gate
/// (test_fixtures/expected/binary_wire.json) on its first run: jas_dioxus's
/// `pack_tspan` writes FIFTY-ONE slots per tspan and this port's `packTspan`
/// wrote TWENTY-TWO, with `unpackTspan` reading only 22. So at that commit the
/// two ports did NOT write the same bytes for any Text or TextPath -- measured;
/// whether they ever did is a history question nobody drove -- and this port's
/// binary codec silently dropped 29 tspan fields on a round trip although
/// `Tspan` HOLDS every one of them.
///
/// It was invisible to every existing gate for exactly the reason the byte gate
/// was ruled: `binaryRoundtripAllExpected` compares canonical test-JSON
/// STRINGS, `binaryReadPythonFixtures` reads PYTHON-written bytes, and both
/// ports read trailing slots tolerantly -- so each port round-tripped its OWN
/// blobs happily and neither noticed the other's.
///
/// Twin of `binary_round_trips_a_saturated_tspan` in
/// jas_dioxus/src/geometry/binary.rs.

/// A Tspan with every override field set to a distinct non-default value, so a
/// dropped slot cannot hide behind a coincidence with the default.
private func saturatedTspan() -> Tspan {
    Tspan(id: 7, content: "hi",
          baselineShift: 1.5, dx: 2.5,
          fontFamily: "Georgia", fontSize: 13.5,
          fontStyle: "italic", fontVariant: "small-caps", fontWeight: "700",
          jasAaMode: "crisp", jasFractionalWidths: true,
          jasKerningMode: "optical", jasNoBreak: true,
          jasRole: "paragraph",
          jasLeftIndent: 3.5, jasRightIndent: 4.5,
          jasHyphenate: true, jasHangingPunctuation: true,
          jasListStyle: "disc",
          textAlign: "justify", textAlignLast: "right",
          textIndent: 5.5,
          jasSpaceBefore: 6.5, jasSpaceAfter: 7.5,
          jasWordSpacingMin: 8.5, jasWordSpacingDesired: 9.5, jasWordSpacingMax: 10.5,
          jasLetterSpacingMin: 11.5, jasLetterSpacingDesired: 12.5, jasLetterSpacingMax: 13.5,
          jasGlyphScalingMin: 14.5, jasGlyphScalingDesired: 15.5, jasGlyphScalingMax: 16.5,
          jasAutoLeading: 17.5,
          jasSingleWordJustify: "center",
          jasHyphenateMinWord: 18.5, jasHyphenateMinBefore: 19.5,
          jasHyphenateMinAfter: 20.5, jasHyphenateLimit: 21.5,
          jasHyphenateZone: 22.5, jasHyphenateBias: 23.5,
          jasHyphenateCapitalized: true,
          letterSpacing: 24.5, lineHeight: 25.5,
          rotate: 26.5, styleName: "Heading",
          textDecoration: ["underline", "overline"], textRendering: "geometricPrecision",
          textTransform: "uppercase",
          transform: Transform(a: 2, b: 0, c: 0, d: 3, e: 5, f: 7),
          xmlLang: "fr")
}

@Test func binaryRoundTripsASaturatedTspan() throws {
    let before = saturatedTspan()
    let text = Text(x: 1, y: 2, tspans: [before], fontFamily: "Arial", fontSize: 12,
                    fontWeight: "normal", fontStyle: "normal", textDecoration: "none",
                    width: 0, height: 0)
    let doc = Document(layers: [Layer(children: [.text(text)])], selectedLayer: 0)
    let back = try binaryToDocument(documentToBinary(doc))
    guard case .text(let t) = back.layers[0].children[0] else {
        Issue.record("expected Text"); return
    }
    #expect(t.tspans.count == 1)
    guard let after = t.tspans.first else { return }
    // Whole-struct equality first, then the fields the 22-slot writer dropped,
    // named individually so a future regression says WHICH one went.
    #expect(after == before, "binary dropped at least one tspan field")
    #expect(after.jasRole == "paragraph")
    #expect(after.jasLeftIndent == 3.5)
    #expect(after.jasRightIndent == 4.5)
    #expect(after.jasHyphenate == true)
    #expect(after.jasHangingPunctuation == true)
    #expect(after.jasListStyle == "disc")
    #expect(after.textAlign == "justify")
    #expect(after.textAlignLast == "right")
    #expect(after.textIndent == 5.5)
    #expect(after.jasSpaceBefore == 6.5)
    #expect(after.jasSpaceAfter == 7.5)
    #expect(after.jasWordSpacingMin == 8.5)
    #expect(after.jasWordSpacingDesired == 9.5)
    #expect(after.jasWordSpacingMax == 10.5)
    #expect(after.jasLetterSpacingMin == 11.5)
    #expect(after.jasLetterSpacingDesired == 12.5)
    #expect(after.jasLetterSpacingMax == 13.5)
    #expect(after.jasGlyphScalingMin == 14.5)
    #expect(after.jasGlyphScalingDesired == 15.5)
    #expect(after.jasGlyphScalingMax == 16.5)
    #expect(after.jasAutoLeading == 17.5)
    #expect(after.jasSingleWordJustify == "center")
    #expect(after.jasHyphenateMinWord == 18.5)
    #expect(after.jasHyphenateMinBefore == 19.5)
    #expect(after.jasHyphenateMinAfter == 20.5)
    #expect(after.jasHyphenateLimit == 21.5)
    #expect(after.jasHyphenateZone == 22.5)
    #expect(after.jasHyphenateBias == 23.5)
    #expect(after.jasHyphenateCapitalized == true)
    // The 22 slots that DID exist, so this suite also guards the old half.
    #expect(after.content == "hi")
    #expect(after.textDecoration == ["underline", "overline"])
    #expect(after.transform == Transform(a: 2, b: 0, c: 0, d: 3, e: 5, f: 7))
    #expect(after.xmlLang == "fr")
}
