import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import JasLib

// Point-text `text-anchor` (PARAGRAPH.md §Storage): read, normalised
// (`start` is the empty default), written back only when set, and applied
// through ONE law, `Text.anchorShift`, by the bounds, the PDF export and
// the canvas. Twin of Rust's `text_anchor_codec_tests` (svg.rs), the PDF
// arm `an_anchored_text_is_shown_at_its_anchored_left` (pdf.rs), and the
// renderer changes of the same PR, on the same inputs.

private func anchorSvg(_ attrs: String, x: Int = 100, y: Int = 50, size: Int = 10,
                       content: String = "ABCD", w: Int = 200, h: Int = 100) -> String {
    #"<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" width=""#
        + "\(w)\" height=\"\(h)\"><text x=\"\(x)\" y=\"\(y)\" font-size=\"\(size)\" \(attrs)>\(content)</text></svg>"
}

private func textOf(_ doc: Document) -> Text? {
    for l in doc.layers {
        for c in l.children { if case .text(let t) = c { return t } }
    }
    return nil
}

private func textOf(_ attrs: String) -> Text? { textOf(svgToDocument(anchorSvg(attrs))) }

@Test func textAnchorMiddleAndEndAreReadAndStartIsTheDefault() {
    #expect(textOf(#"text-anchor="middle""#)?.textAnchor == "middle")
    #expect(textOf(#"text-anchor="end""#)?.textAnchor == "end")
    #expect(textOf(#"text-anchor="start""#)?.textAnchor == "")
    #expect(textOf("")?.textAnchor == "")
    #expect(textOf(#"text-anchor="sideways""#)?.textAnchor == "")
}

@Test func textAnchorIsWrittenBackAndReadAgain() {
    for a in ["middle", "end"] {
        let out = documentToSvg(svgToDocument(anchorSvg("text-anchor=\"\(a)\"")))
        #expect(out.contains("text-anchor=\"\(a)\""), "writer dropped `\(a)`:\n\(out)")
        #expect(documentToSvg(svgToDocument(out)) == out, "`\(a)` is a fixpoint")
    }
}

@Test func textAnchorNoAnchorWritesNoAttribute() {
    let out = documentToSvg(svgToDocument(anchorSvg(#"text-anchor="start""#)))
    #expect(!out.contains("text-anchor"))
}

/// The box a selection draws is where the glyphs are: its left edge is
/// `x + anchorShift(width)`, the width from the same measurer the bounds
/// always used. Start keeps today's box exactly.
@Test func textAnchorBoundsSitWhereTheAnchorPutsTheLine() {
    guard let start = textOf("") else { Issue.record("no text"); return }
    let (sx, sy, sw, sh) = start.bounds
    #expect(sw > 1, "a measured width: \(sw)")
    for (attrs, k) in [(#"text-anchor="middle""#, 0.5), (#"text-anchor="end""#, 1.0)] {
        guard let t = textOf(attrs) else { Issue.record("no text"); continue }
        let (x, y, w, h) = t.bounds
        #expect(abs(x - (sx - k * sw)) < 1e-9, "\(attrs): left \(x), expected \(sx - k * sw)")
        #expect(y == sy && w == sw && h == sh, "\(attrs): only x moves")
    }
}

/// The canonical JSON the cross-language corpus compares omits an unset
/// anchor, so every existing golden is unchanged, and carries a set one.
@Test func textAnchorCanonicalJsonCarriesOnlyASetAnchor() {
    let plain = documentToTestJson(svgToDocument(anchorSvg("", x: 1, y: 5, content: "A")))
    #expect(!plain.contains("text_anchor"), "\(plain)")
    let set = documentToTestJson(svgToDocument(anchorSvg(#"text-anchor="end""#, x: 1, y: 5, content: "A")))
    #expect(set.contains(#""text_anchor":"end""#), "\(set)")
    #expect(documentToTestJson(testJsonToDocument(set)) == set, "JSON round trip")
}

/// An anchored point text is shown with its line's left edge where the
/// anchor puts it. Measured in the exported PDF itself (PDFKit's glyph
/// selection), against the start-anchored export of the same text, so the
/// glyph side bearing cancels: the shift must be `k * w`, `w` the width the
/// bounds report.
@Test func textAnchorPdfShowsAnAnchoredTextAtItsAnchoredLeft() {
    func glyphLeft(_ attrs: String) -> (Double, Double)? {
        let doc = svgToDocument(anchorSvg(attrs, x: 120, y: 260, size: 12, content: "HELLO", w: 400, h: 400))
        guard let t = textOf(doc),
              let pdf = PDFDocument(data: documentToPdf(doc)),
              let page = pdf.page(at: 0),
              let sel = pdf.findString("HELLO", withOptions: []).first
        else { return nil }
        return (Double(sel.bounds(for: page).minX), t.bounds.2)
    }
    guard let (l0, w) = glyphLeft("") else { Issue.record("no HELLO in the start PDF"); return }
    #expect(w > 1, "measured width \(w)")
    for (anchor, k) in [("middle", 0.5), ("end", 1.0)] {
        guard let (l, _) = glyphLeft("text-anchor=\"\(anchor)\"") else {
            Issue.record("no HELLO in the \(anchor) PDF"); continue
        }
        #expect(abs((l0 - l) - k * w) < 0.5, "\(anchor): shifted \(l0 - l), want \(k * w)")
    }
}

// MARK: - Canvas

private let canvasW = 300, canvasH = 80

/// The leftmost inked column of `t` drawn through `drawElement`, or nil.
private func inkLeft(_ t: Text) -> Int? {
    let bytes = canvasW * canvasH * 4
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
    defer { buf.deallocate() }
    buf.initialize(repeating: 0, count: bytes)
    guard let ctx = CGContext(data: buf, width: canvasW, height: canvasH, bitsPerComponent: 8,
                              bytesPerRow: canvasW * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    drawElement(ctx, .text(t))
    for x in 0..<canvasW {
        for y in 0..<canvasH where buf[(y * canvasW + x) * 4 + 3] > 64 { return x }
    }
    return nil
}

/// The canvas draws each point-text line from its anchored origin: the ink
/// moves left by `k * w` against the start-anchored draw of the same text.
@Test func textAnchorCanvasDrawsAnAnchoredLineFromItsAnchoredLeft() {
    func t(_ attrs: String) -> Text? {
        textOf(svgToDocument(anchorSvg(attrs, x: 200, y: 20, size: 20, content: "HELLO", w: 300, h: 80)))
    }
    guard let s = t(""), let l0 = inkLeft(s) else { Issue.record("start drew no ink"); return }
    let w = s.bounds.2
    for (attrs, k) in [(#"text-anchor="middle""#, 0.5), (#"text-anchor="end""#, 1.0)] {
        guard let a = t(attrs), let l = inkLeft(a) else { Issue.record("\(attrs) drew no ink"); continue }
        #expect(abs(Double(l0 - l) - k * w) <= 1.5, "\(attrs): ink moved \(l0 - l) px, want \(k * w)")
    }
}
