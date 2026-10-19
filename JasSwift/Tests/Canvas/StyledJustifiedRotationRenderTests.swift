import CoreGraphics
import Foundation
import Testing
@testable import JasLib

/// STYLED laid-out text on a justified or hyphenated line, the Swift twin of
/// jas_dioxus's shared plan (`text_runs::plan`): a stretched line draws word by
/// word at the layout's x, each word in ITS OWN tspan's attributes; a turned
/// glyph (the element's rotation, or a tspan's own) is cut at the layout's x
/// too, so justification survives a rotation; and a hyphenated break draws its
/// hyphen on a turned line as well, in the broken word's tspan.
///
/// This port draws straight into CoreGraphics, so the arms read PIXELS.

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

/// The columns holding any ink (alpha > 0).
private func inkColumns(_ buf: [UInt8]) -> [Int] {
    (0..<size).filter { x in (0..<size).contains { y in buf[(y * size + x) * 4 + 3] > 0 } }
}

/// Pixels with alpha over half: a heavier face inks more of them.
private func solidInk(_ buf: [UInt8]) -> Int {
    stride(from: 3, to: buf.count, by: 4).filter { buf[$0] > 127 }.count
}

/// Pixels with any ink.
private func anyInk(_ buf: [UInt8]) -> Int {
    stride(from: 3, to: buf.count, by: 4).filter { buf[$0] > 0 }.count
}

/// Area text 50 pt wide holding seven "HH" words: three fit line 1 at about
/// 39 pt, so a justified line 1 stretches its glue by about 11 pt (44 px).
/// Words two to six are a tspan of their own, bold when `bold`, so the text is
/// STYLED in every arm and takes the styled path.
private func justified(align: String, rotate: String = "", bold: Bool = true) -> Element {
    .text(Text(x: 2, y: 2, tspans: [
        Tspan(id: 0, content: "", jasRole: "paragraph", textAlign: align),
        Tspan(id: 1, content: "HH "),
        Tspan(id: 2, content: "HH HH HH HH HH", fontWeight: bold ? "bold" : nil),
        Tspan(id: 3, content: " HH"),
    ], fontFamily: "Helvetica", fontSize: 8, rotate: rotate,
       width: 50, height: 50, fill: Fill(color: .black)))
}

/// A turned justified line keeps its stretch: its last glyph draws at the
/// layout's x, as the upright justified line does, and not at the natural
/// advance a per-glyph walk from the line's start would give it. The margin is
/// 20 px against a stretch of about 44 px; a turned glyph's ink sits within its
/// cap height (about 23 px) of its origin, the same on both renders.
@Test func aTurnedJustifiedStyledLineKeepsItsStretch() {
    let uprightLeft = inkColumns(render(justified(align: "left"))).last!
    let uprightJust = inkColumns(render(justified(align: "justify"))).last!
    #expect(uprightJust > uprightLeft + 20,
            "CONTROL: line 1 stretches upright (\(uprightLeft) -> \(uprightJust))")
    let turnedLeft = inkColumns(render(justified(align: "left", rotate: "90"))).last!
    let turnedJust = inkColumns(render(justified(align: "justify", rotate: "90"))).last!
    #expect(turnedJust > turnedLeft + 20,
            "a turned justified line keeps its stretch (\(turnedLeft) -> \(turnedJust))")
}

/// A justified styled line draws each word in its own tspan's attributes: the
/// bold words ink heavier than the same words regular. The element's
/// attributes would draw both alike. The control is the same text unjustified.
@Test func aJustifiedStyledLineDrawsEachWordInItsTspansFont() {
    let regular = solidInk(render(justified(align: "justify", bold: false)))
    let bold = solidInk(render(justified(align: "justify", bold: true)))
    #expect(regular > 0, "the justified text draws")
    #expect(Double(bold) > Double(regular) * 1.05,
            "the bold words on the stretched line ink bold (\(regular) vs \(bold))")
    // CONTROL: unjustified, the line draws as one attributed string.
    let lRegular = solidInk(render(justified(align: "left", bold: false)))
    let lBold = solidInk(render(justified(align: "left", bold: true)))
    #expect(Double(lBold) > Double(lRegular) * 1.05, "CONTROL: \(lRegular) vs \(lBold)")
}

/// "go " then a bold "information", hyphenated in a box too narrow for the
/// word. Its line 1 is broken inside the word, at `breakAt`.
private func hyphenated(_ content: [String], rotate: String, hyphenate: Bool) -> Text {
    Text(x: 2, y: 2, tspans: [
        Tspan(id: 0, content: "", jasRole: "paragraph", jasHyphenate: hyphenate),
        Tspan(id: 1, content: content[0]),
        Tspan(id: 2, content: content[1], fontWeight: "bold"),
    ], fontFamily: "Helvetica", fontSize: 8, rotate: rotate,
       width: 40, height: 50, fill: Fill(color: .black))
}

/// Where line 1 of `t` ends, and whether it ends in a hyphen, by the same
/// layout the renderer runs.
private func firstLine(_ t: Text) -> (end: Int, hyphen: Bool) {
    let measure = makeMeasurer(family: t.fontFamily, weight: t.fontWeight, style: t.fontStyle, size: t.fontSize)
    let segs = buildParagraphSegments(tspans: t.tspans, content: t.content, isArea: true)
    let lay = layoutTextWithParagraphs(
        t.content, maxWidth: t.width, fontSize: t.fontSize, paragraphs: segs,
        measure: measure, perCharWidths: textPerCharWidths(t.tspans, element: t))
    return (lay.lines[0].end, lay.lines[0].trailingHyphen)
}

/// A turned hyphenated line draws its hyphen. The control text breaks at the
/// same character with a SPACE in place of the hyphen, so both renders put
/// every letter at the same x and differ by the hyphen's ink alone.
@Test func aTurnedHyphenatedLineDrawsItsHyphen() {
    let probe = hyphenated(["go ", "information"], rotate: "", hyphenate: true)
    let (end, hyphen) = firstLine(probe)
    #expect(hyphen, "precondition: line 1 is broken at a hyphenation point (it ends at \(end))")
    guard hyphen, end > 3 else { return }
    let word = Array("information")
    let split = ["go ", String(word[..<(end - 3)]) + " " + String(word[(end - 3)...])]
    #expect(firstLine(hyphenated(split, rotate: "", hyphenate: false)).end == end + 1,
            "precondition: the control breaks at the same letter, after its space")
    for rotate in ["", "90"] {
        let withHyphen = anyInk(render(.text(hyphenated(["go ", "information"], rotate: rotate, hyphenate: true))))
        let spaced = anyInk(render(.text(hyphenated(split, rotate: rotate, hyphenate: false))))
        #expect(withHyphen > spaced,
                "rotate '\(rotate)': the hyphen draws (\(spaced) -> \(withHyphen))")
    }
}
