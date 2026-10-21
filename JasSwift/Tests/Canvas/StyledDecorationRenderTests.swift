import CoreGraphics
import Foundation
import Testing
@testable import JasLib

/// A decoration beside a shift or a turn (TSPAN.md "Decoration beside a shift or
/// a turn"): an underline is drawn in its GLYPH's frame. A tspan's
/// baseline shift moves the underline under it, whoever declares it, and a
/// turned glyph's piece turns with the glyph. Both browser engines draw this
/// for the same SVG; jas_dioxus's plan pins it in
/// `a_decoration_follows_its_glyphs_shift_and_turn`.
///
/// The arms read PIXELS: the underline's ink is where a decorated render
/// differs from the same text undecorated.

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

/// Styled area text on one line: "aaaa " + "BBBB" (bold, its own `shift` and
/// `rotate`) + " cccc", the ELEMENT's underline when `decorated`.
private func styled(decorated: Bool, shift: Double? = nil, rotate: Double? = nil) -> Element {
    .text(Text(x: 2, y: 20, tspans: [
        Tspan(id: 0, content: "", jasRole: "paragraph"),
        Tspan(id: 1, content: "aaaa "),
        Tspan(id: 2, content: "BBBB", baselineShift: shift, fontWeight: "bold", rotate: rotate),
        Tspan(id: 3, content: " cccc"),
    ], fontFamily: "Helvetica", fontSize: 6,
       textDecoration: decorated ? "underline" : "none",
       width: 55, height: 30, fill: Fill(color: .black)))
}

/// The underline's ink, per column: the topmost and bottommost rows where the
/// decorated render differs from the undecorated one.
private func underline(shift: Double? = nil, rotate: Double? = nil) -> [Int: (top: Int, bottom: Int)] {
    let a = render(styled(decorated: true, shift: shift, rotate: rotate))
    let b = render(styled(decorated: false, shift: shift, rotate: rotate))
    var cols: [Int: (top: Int, bottom: Int)] = [:]
    for y in 0..<size {
        for x in 0..<size where a[(y * size + x) * 4 + 3] != b[(y * size + x) * 4 + 3] {
            let c = cols[x] ?? (y, y)
            cols[x] = (min(c.top, y), max(c.bottom, y))
        }
    }
    return cols
}

/// The ELEMENT's underline rises with a tspan raised 3 pt (12 px): the
/// underline's top row takes two levels 12 px apart (margin 2 px for
/// antialiasing). The control, unshifted, is one level.
@Test func anElementsUnderlineFollowsATspansShift() {
    let flat = underline()
    #expect(!flat.isEmpty, "the underline draws")
    let flatTops = Set(flat.values.map(\.top))
    #expect(flatTops.max()! - flatTops.min()! <= 1, "CONTROL: one level unshifted (\(flatTops.sorted()))")
    let raised = underline(shift: 3)
    let tops = raised.values.map(\.top)
    let spread = tops.max()! - tops.min()!
    #expect(abs(spread - 12) <= 2, "the shifted run's piece is 12 px above the rest (spread \(spread))")
}

/// Under turned glyphs each piece turns with its glyph: at 30 degrees a piece
/// about 4 pt (16 px) long climbs about 9 px, so the underline's ink spans far
/// more rows under the turned run than its thickness. Margin: 5 px against
/// about 9. The control, unturned, spans no more than its thickness (2 px
/// plus antialiasing).
@Test func anElementsUnderlineTurnsWithATurnedGlyph() {
    let flat = underline()
    let flatSpan = flat.values.map { $0.bottom - $0.top }.max()!
    #expect(flatSpan <= 3, "CONTROL: an unturned underline is a thin line (\(flatSpan))")
    let turned = underline(rotate: 30)
    let rows = Set(turned.values.flatMap { [$0.top, $0.bottom] })
    let height = rows.max()! - rows.min()!
    #expect(height >= flatSpan + 5, "the turned run's pieces climb with their glyphs (height \(height))")
}

/// The ink rows of the columns holding a bold "B" and no "a" or "c":
/// `render` is a CoreGraphics bitmap, so a LARGER memory row is HIGHER on the
/// page (the document's y down is CG's y up, flipped by the canvas).
private func boldRows(_ buf: [UInt8], plain: [UInt8]) -> (low: Int, high: Int) {
    var low = Int.max, high = Int.min
    for x in 0..<size where !(0..<size).contains(where: { plain[($0 * size + x) * 4 + 3] > 0 }) {
        for y in 0..<size where buf[(y * size + x) * 4 + 3] > 0 { low = min(low, y); high = max(high, y) }
    }
    return (low, high)
}

/// A tspan's baseline shift is + UP (CHARACTER.md: "pt, signed; + = up"):
/// the bold run raised 3 pt draws 12 px higher on the page than unshifted,
/// with no decoration anywhere. The columns read are the bold run's alone.
@Test func aTspansBaselineShiftRaisesItsRun() {
    func text(_ shift: Double?, bold: String) -> Element {
        .text(Text(x: 2, y: 20, tspans: [
            Tspan(id: 0, content: "", jasRole: "paragraph"),
            Tspan(id: 1, content: "aaaa "),
            Tspan(id: 2, content: bold, baselineShift: shift, fontWeight: "bold"),
        ], fontFamily: "Helvetica", fontSize: 6, width: 55, height: 30, fill: Fill(color: .black)))
    }
    // The bold run is LAST, so the columns no render of "aaaa " alone inks
    // are the bold run's and nothing else's.
    let without = render(text(nil, bold: ""))
    let flat = boldRows(render(text(nil, bold: "BBBB")), plain: without)
    let raised = boldRows(render(text(3, bold: "BBBB")), plain: without)
    #expect(flat.low < flat.high, "precondition: the bold run inks (\(flat))")
    #expect(abs((raised.low - flat.low) - 12) <= 1 && abs((raised.high - flat.high) - 12) <= 1,
            "raised 3 pt draws 12 px HIGHER: \(flat) -> \(raised)")
}
