import CoreGraphics
import Foundation
import Testing
@testable import JasLib

/// A TSPAN's own rotation (TSPAN.md "Rotation"), the Swift twin of jas_dioxus
/// `a_tspans_rotation_draws_each_of_its_glyphs_at_the_layouts_x`: each glyph of
/// the rotated tspan turns about its own baseline origin, the pen advancing
/// un-rotated, so the text BEFORE it draws exactly as it would without the
/// rotation and the rotated word itself draws differently.
///
/// This port draws straight into CoreGraphics, so the arm reads PIXELS: two
/// renders of one point text, "HHHH " + "HHHH", with and without a 90 degree
/// rotation on the second tspan. The first tspan's columns must be
/// byte-identical, and the second's must differ. The renders being equal
/// overall (the rotation dropped) fails the second half.

private let pxPerPt = 4.0
private let size = 240

private func render(_ elem: Element) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: size * size * 4)
    buf.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(pxPerPt), y: CGFloat(pxPerPt))
        drawElement(ctx, elem)
    }
    return buf
}

private func text(_ second: Double?, secondContent: String = "HHHH", third: String = "") -> Element {
    .text(Text(x: 2, y: 10, tspans: [
        Tspan(id: 0, content: "HHHH "),
        Tspan(id: 1, content: secondContent, rotate: second),
        Tspan(id: 2, content: third),
    ], fontFamily: "Helvetica", fontSize: 8, fill: Fill(color: .black)))
}

/// The bytes of rows `rows` in columns `cols`.
private func band(_ buf: [UInt8], rows: Range<Int>, cols: Range<Int>) -> [UInt8] {
    var out: [UInt8] = []
    for y in rows { for x in cols { out.append(contentsOf: buf[(y * size + x) * 4 ..< (y * size + x) * 4 + 4]) } }
    return out
}

/// The columns holding any ink (alpha > 0).
private func inkColumns(_ buf: [UInt8]) -> [Int] {
    (0..<size).filter { x in (0..<size).contains { y in buf[(y * size + x) * 4 + 3] > 0 } }
}

/// The bytes of columns `cols`, every row.
private func columns(_ buf: [UInt8], _ cols: Range<Int>) -> [UInt8] {
    var out: [UInt8] = []
    for y in 0..<size { for x in cols { out.append(contentsOf: buf[(y * size + x) * 4 ..< (y * size + x) * 4 + 4]) } }
    return out
}

@Test func aTspansOwnRotationTurnsItsGlyphsAndLeavesTheTextBeforeIt() {
    // The first tspan alone fixes where its ink ends.
    let firstOnly = inkColumns(render(text(nil, secondContent: "")))
    #expect(!firstOnly.isEmpty, "the first tspan draws")
    let cut = (firstOnly.last ?? 0) + 1
    let plain = render(text(nil))
    let turned = render(text(90))
    #expect(inkColumns(plain).last! > cut, "the second tspan draws past the first's ink")
    #expect(columns(plain, 0..<cut) == columns(turned, 0..<cut),
            "the text before the rotated tspan draws as it would without it")
    #expect(columns(plain, cut..<size) != columns(turned, cut..<size),
            "the rotated tspan's glyphs draw turned")
}

/// The tspan AFTER a rotated one stays where the un-rotated pen put it. A 90
/// degree clockwise turn puts every rotated glyph below its baseline (the
/// glyph's up becomes +x and its advance +y), so the CAP BAND above the
/// baseline holds only un-rotated ink: there the third tspan's columns must
/// match. The band is the rows the upright first tspan inks, less two rows at
/// each end for antialiasing. ⚠️ Taken from ink, never from a typed row
/// number: the bitmap's memory rows run bottom-up, and a typed band compared
/// two empty regions until the control below caught it.
@Test func theTspanAfterARotatedOneKeepsItsPlace() {
    let firstOnly = render(text(nil, secondContent: ""))
    let inked = (0..<size).filter { y in (0..<size).contains { x in firstOnly[(y * size + x) * 4 + 3] > 0 } }
    #expect(inked.count > 8, "the first tspan inks a cap band: \(inked.count) rows")
    let rows = (inked.first! + 2)..<(inked.last! - 1)
    let firstTwo = inkColumns(render(text(nil, third: "")))
    let cut = (firstTwo.last ?? 0) + 1
    let plain = render(text(nil, third: " HHHH"))
    let turned = render(text(90, third: " HHHH"))
    #expect(inkColumns(plain).last! > cut + 8, "the third tspan draws past the second's ink")
    #expect(band(plain, rows: rows, cols: cut..<size) == band(turned, rows: rows, cols: cut..<size),
            "the third tspan sits where the un-rotated pen put it")
    #expect(band(plain, rows: rows, cols: 0..<cut) != band(turned, rows: rows, cols: 0..<cut),
            "CONTROL: the rotated tspan leaves the cap band when turned")
}

/// The ELEMENT's rotation on styled text, the Swift twin of jas_dioxus
/// `an_element_rotation_turns_every_glyph_and_a_tspans_own_overrides_it`:
/// every glyph turns, each in ITS OWN tspan's font, and a tspan's own
/// rotation overrides the element's for its glyphs.
private func turnedText(bold: Bool, own: Double?) -> Element {
    .text(Text(x: 2, y: 10, tspans: [
        Tspan(id: 0, content: "HHHH "),
        Tspan(id: 1, content: "HHHH", fontWeight: bold ? "bold" : nil, rotate: own),
    ], fontFamily: "Helvetica", fontSize: 8, rotate: "90", fill: Fill(color: .black)))
}

private func inkCount(_ buf: [UInt8]) -> Int {
    stride(from: 3, to: buf.count, by: 4).filter { buf[$0] > 0 }.count
}

@Test func anElementRotationTurnsEachGlyphInItsOwnTspansFont() {
    let regular = render(turnedText(bold: false, own: nil))
    let bold = render(turnedText(bold: true, own: nil))
    #expect(inkCount(regular) > 0, "the turned text draws")
    #expect(inkCount(bold) > inkCount(regular), "the bold tspan's glyphs turn in bold")
}

/// Both renders are STYLED (the bold tspan), so both take the styled path and
/// differ only in the override: with no override on either tspan the text is
/// FLAT and draws by the flat per-glyph branch, which made this arm pass
/// whatever the styled path did (a mutant dropping the inherited angle
/// survived it).
@Test func aTspansOwnRotationOverridesTheElements() {
    let inherited = render(turnedText(bold: true, own: nil))
    let upright = render(turnedText(bold: true, own: 0))
    #expect(inherited != upright, "a tspan's rotate 0 keeps its glyphs upright under a turned element")
}
