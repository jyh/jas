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

private func text(_ second: Double?, secondContent: String = "HHHH") -> Element {
    .text(Text(x: 2, y: 10, tspans: [
        Tspan(id: 0, content: "HHHH "),
        Tspan(id: 1, content: secondContent, rotate: second),
    ], fontFamily: "Helvetica", fontSize: 8, fill: Fill(color: .black)))
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
