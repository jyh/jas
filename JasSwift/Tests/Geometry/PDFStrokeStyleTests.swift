import Foundation
import Testing
@testable import JasLib

// PDF strokes carry the element's dash, cap, join and miter limit (PDF 1.7
// §8.4.3), and a default stroke carries none of them. Twin of Rust's
// `pdf.rs` stroke-style arms (#265), read from the exported file's inflated
// content stream (`pdfInflatedStreams`, PDFTextOriginTests.swift).

/// A stroked-only line reaches `emitStrokeOnly`; a filled and stroked rect
/// reaches `emitPaint`. Both must carry the style.
private let lineElem = ##"<line x1="10" y1="10" x2="150" y2="10" stroke="#000000" stroke-width="4" "##
private let rectElem = ##"<rect x="10" y="10" width="100" height="60" fill="#cccccc" stroke="#000000" stroke-width="4" "##

private func strokeOps(_ attrs: String, _ elem: String = lineElem) -> [String] {
    let svg = ##"<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">"## + elem + attrs + "/></svg>"
    let pdf = documentToPdf(documentForOpen(svg))
    // Every operator token sequence up to and including the stroke.
    return pdfInflatedStreams(pdf).filter { $0.contains(" S") || $0.hasSuffix("S") }
}

private func has(_ streams: [String], _ pattern: String) -> Bool {
    streams.contains { $0.range(of: pattern, options: .regularExpression) != nil }
}

// One @Test per stroke path (not a parameterized test: the Swift execution
// gate reads each case back by name and does not model expansion).
@Test func pdfAStyledStrokedLineWritesItsCapJoinMiterAndDash() { expectStyled(lineElem) }
@Test func pdfAStyledFilledRectWritesItsCapJoinMiterAndDash() { expectStyled(rectElem) }
@Test func pdfADefaultStrokedLineWritesNoStyleOperator() { expectDefault(lineElem) }
@Test func pdfADefaultFilledRectWritesNoStyleOperator() { expectDefault(rectElem) }

private func expectStyled(_ elem: String) {
    let s = strokeOps(#"stroke-linecap="round" stroke-linejoin="bevel" stroke-miterlimit="4" stroke-dasharray="8 4""#, elem)
    #expect(!s.isEmpty, "a stroked content stream")
    #expect(has(s, #"(^|\s)1 J(\s|$)"#), "round cap: \(s)")
    #expect(has(s, #"(^|\s)2 j(\s|$)"#), "bevel join: \(s)")
    #expect(has(s, #"(^|\s)4 M(\s|$)"#), "miter limit 4: \(s)")
    // 8 px and 4 px are 6 pt and 3 pt.
    #expect(has(s, #"\[\s*6 3\s*\] 0 d"#), "dash [6 3]: \(s)")
}

private func expectDefault(_ elem: String) {
    let s = strokeOps("", elem)
    #expect(!s.isEmpty, "a stroked content stream")
    for op in [#"(^|\s)[12] J(\s|$)"#, #"(^|\s)[12] j(\s|$)"#, #"(^|\s)[0-9.]+ M(\s|$)"#, #"\[[^\]]+\] [0-9.]+ d"#] {
        #expect(!has(s, op), "default stroke wrote /\(op)/: \(s)")
    }
}
