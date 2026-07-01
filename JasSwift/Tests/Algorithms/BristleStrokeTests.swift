import Testing
import Foundation
@testable import JasLib

/// Equivalence vectors shared with the Rust reference
/// (jas_dioxus/src/algorithms/bristle_stroke.rs): width 4, density 25 ->
/// two bristles at ±2 along a straight horizontal path.
private func brush() -> BristleBrush {
    BristleBrush(size: 4.0, density: 25.0, thickness: 30.0, opacity: 30.0, strokeWeight: 1.0)
}

@Suite struct BristleStrokeTests {
    @Test func straightPathTwoOffsetBristles() {
        let out = bristleStroke([.moveTo(0, 0), .lineTo(100, 0)], brush())
        #expect(out.count == 2)
        func close(_ a: [Double], _ x: Double, _ y: Double) -> Bool {
            abs(a[0] - x) < 1e-6 && abs(a[1] - y) < 1e-6
        }
        #expect(close(out[0][0], 0, -2))
        #expect(close(out[0][1], 100, -2))
        #expect(close(out[1][0], 0, 2))
        #expect(close(out[1][1], 100, 2))
    }

    @Test func countAndAlpha() {
        #expect(brush().count() == 2)
        #expect(abs(brush().alpha() - 0.3) < 1e-9)
    }

    @Test func emptyForDegenerate() {
        #expect(bristleStroke([.moveTo(0, 0)], brush()).isEmpty)
    }
}
