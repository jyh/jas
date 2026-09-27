import AppKit
import Foundation
import Testing
@testable import JasLib

// Bold and italic text is shown in the bold / italic face (twin of Rust's
// #266). The PDF embeds the face the canvas draws: the oracle is the
// TRAITS of `resolveFont`, the resolver the canvas and the text measurer
// use, never a typed font name.
//
// How the embedded face is read, and its limit: PDFKit's extracted text
// reports a substitute font, so the face is read from the embedded
// `/BaseFont` name. A static face says `Bold` / `Italic` there; a
// variable-font instance (the system font) carries its weight axis as
// 16.16 hex after `wght` (`wght2BC0000` = 700) and a bare `wght` at the
// default. That is CoreGraphics' naming, measured 2026-09-26; a face named
// any other way reads as regular and upright, which fails the bold and
// italic cases rather than passing them.

private let faces: [(weight: String, style: String)] =
    [("normal", "normal"), ("bold", "normal"), ("normal", "italic"), ("bold", "italic")]

/// The `/BaseFont` names embedded in `pdf`, subset prefixes removed.
private func baseFonts(_ pdf: Data) -> [String] {
    let s = String(decoding: pdf, as: UTF8.self)
    guard let re = try? NSRegularExpression(pattern: #"/BaseFont\s*/([^\s/<>\[\]()]+)"#) else { return [] }
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
        Range(m.range(at: 1), in: s).map { String(s[$0]) }.map { n in
            n.count > 7 && n.dropFirst(6).first == "+" ? String(n.dropFirst(7)) : n
        }
    }
}

/// (bold, italic) as the embedded `/BaseFont` name encodes it.
private func embeddedFace(_ name: String) -> (bold: Bool, italic: Bool) {
    var weight = 400.0
    if let r = name.range(of: #"wght[0-9A-F]+"#, options: .regularExpression),
       let v = Int(name[r].dropFirst(4), radix: 16) {
        weight = Double(v) / 65536
    }
    return (name.contains("Bold") || weight >= 600, name.contains("Italic") || name.contains("Oblique"))
}

private func canvasFace(_ w: String, _ st: String) -> (bold: Bool, italic: Bool) {
    let t = resolveFont(family: "sans-serif", bold: w == "bold", italic: st == "italic", size: 12)
        .fontDescriptor.symbolicTraits
    return (t.contains(.bold), t.contains(.italic))
}

@Test func pdfTheResolverDistinguishesTheFourFaces() {
    // The arm below can only tell faces apart if the oracle does.
    let got = faces.map { canvasFace($0.weight, $0.style) }
    #expect(got.map(\.bold) == [false, true, false, true] && got.map(\.italic) == [false, false, true, true],
            "\(got)")
}

@Test(arguments: faces.indices)
func pdfTextIsShownInItsOwnFace(_ i: Int) {
    let (w, st) = faces[i]
    let svg = ##"<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><text x="10" y="50" font-size="12" font-weight=""## + w + ##"" font-style=""## + st + ##"">HELLO</text></svg>"##
    let fonts = baseFonts(documentToPdf(documentForOpen(svg)))
    #expect(fonts.count == 1, "one embedded face: \(fonts)")
    let want = canvasFace(w, st)
    let got = fonts.first.map(embeddedFace)
    #expect(got?.bold == want.bold && got?.italic == want.italic,
            "\(w)/\(st): embedded \(fonts) reads \(String(describing: got)), the canvas face is \(want)")
}
