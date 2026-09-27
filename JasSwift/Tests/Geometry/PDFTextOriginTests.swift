import Foundation
import Testing
@testable import JasLib

// The PDF shows a text's first line with its BASELINE at the model's
// `y + 0.8 * fontSize` (the SVG writer's `svgY` law), at `x` (plus the
// anchor shift). Twin of Rust's `pdf.rs` text-origin arm (#260). Measured
// in the exported file itself: the page content stream is inflated and the
// text-showing operator's origin is read from the `cm` and `Tm` before it.

/// Every Flate content stream in `pdf`, inflated.
func pdfInflatedStreams(_ pdf: Data) -> [String] {
    let bytes = [UInt8](pdf)
    var out: [String] = []
    let open = Array("stream".utf8), close = Array("endstream".utf8)
    var i = 0
    func match(_ at: Int, _ pat: [UInt8]) -> Bool {
        at + pat.count <= bytes.count && Array(bytes[at..<at + pat.count]) == pat
    }
    while i < bytes.count {
        if match(i, open) && !(i >= 3 && match(i - 3, close)) {
            var s = i + open.count
            if s < bytes.count, bytes[s] == 0x0D { s += 1 }
            if s < bytes.count, bytes[s] == 0x0A { s += 1 }
            var e = s
            while e < bytes.count && !match(e, close) { e += 1 }
            // zlib wrapper: 2-byte header, raw DEFLATE body, 4-byte Adler.
            if e - s > 6, let inflated = try? (Data(bytes[(s + 2)..<(e - 4)]) as NSData).decompressed(using: .zlib) {
                out.append(String(decoding: inflated as Data, as: UTF8.self))
            }
            i = e + close.count
        } else { i += 1 }
    }
    return out
}

/// The page-space origin (x, y-up) of the first text object: the last `cm`
/// translation before `BT`, plus the `Tm` translation inside it.
private func firstTextOrigin(_ pdf: Data) -> (Double, Double)? {
    for s in pdfInflatedStreams(pdf) {
        guard let bt = s.range(of: " BT ") ?? s.range(of: "BT ") else { continue }
        let before = String(s[..<bt.lowerBound]), after = String(s[bt.upperBound...])
        func nums(_ t: String, _ op: String) -> [Double]? {
            guard let r = t.range(of: " \(op)", options: .backwards, range: t.startIndex..<t.endIndex) else { return nil }
            let head = t[..<r.lowerBound].split(separator: " ").suffix(6).compactMap { Double($0) }
            return head.count == 6 ? head : nil
        }
        guard let cm = nums(before, "cm"),
              let tmEnd = after.range(of: " Tm"),
              let tm = nums(String(after[..<tmEnd.upperBound]), "Tm") else { continue }
        return (cm[4] + tm[4], cm[5] + tm[5])
    }
    return nil
}

@Test func pdfTextBaselineSitsWhereTheSvgWriterPutsIt() {
    // 400 x 400 px sheet = 300 pt. Baseline (svg y) 260 px = 195 pt from
    // the top, i.e. 105 pt up from the page's bottom edge; x 120 px = 90 pt.
    let svg = ##"<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" width="400" height="400"><text x="120" y="260" font-size="12">HELLO</text></svg>"##
    let doc = documentForOpen(svg)
    guard let ab = doc.artboards.first, case .text(let t)? = doc.layers.first?.children.first else {
        Issue.record("fixture"); return
    }
    let wantX = t.x - ab.x
    let wantY = ab.height - (t.y + t.fontSize * 0.8 - ab.y)
    guard let (x, y) = firstTextOrigin(documentToPdf(doc)) else { Issue.record("no text object in the PDF"); return }
    #expect(abs(x - wantX) < 1e-3 && abs(y - wantY) < 1e-3, "origin (\(x), \(y)), baseline law (\(wantX), \(wantY))")
}
