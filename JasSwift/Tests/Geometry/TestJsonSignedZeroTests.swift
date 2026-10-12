import Testing
import Foundation
@testable import JasLib

/// A value that rounds to zero at six decimals is written `0.0`, never `-0.0`
/// (the shear gesture case's translation came out as -0.0 on the Windows lane
/// and 0.0 on macOS). Mirrors Rust's
/// `a_value_that_rounds_to_zero_is_written_without_a_sign`, through the
/// public writer because `fmt` is private.
@Test func aValueThatRoundsToZeroIsWrittenWithoutASign() {
    for v in [-0.0, -1e-9, -4e-7] {
        let doc = Document(layers: [Layer(children: [.rect(Rect(x: v, y: 0, width: 1, height: 1))])])
        let json = documentToTestJson(doc)
        #expect(json.contains("\"x\":0.0"), "x = \(v): \(json)")
        #expect(!json.contains("-0.0"), "x = \(v): \(json)")
    }
    // Control: a value past the precision keeps its sign.
    let doc = Document(layers: [Layer(children: [.rect(Rect(x: -6e-7, y: 0, width: 1, height: 1))])])
    #expect(documentToTestJson(doc).contains("\"x\":-0.000001"))
}
