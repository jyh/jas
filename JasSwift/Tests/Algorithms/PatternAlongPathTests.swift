import Testing
import Foundation
@testable import JasLib

/// Equivalence vectors shared with the Rust reference
/// (jas_dioxus/src/algorithms/pattern_along_path.rs): a diamond side tile
/// tiled twice along a straight 100-long path (ribbon 10 -> tile_w 50).
private func brush() -> PatternBrush {
    PatternBrush(tileWidth: 100.0, tileHeight: 20.0,
                 side: [[[0.0, 10.0], [50.0, 0.0], [100.0, 10.0], [50.0, 20.0]]],
                 scale: 100.0, spacing: 0.0, flipAcross: false, flipAlong: false,
                 strokeWeight: 10.0)
}

@Suite struct PatternAlongPathTests {
    @Test func straightPathTilesTwice() {
        let out = patternAlongPath([.moveTo(0, 0), .lineTo(100, 0)], brush())
        #expect(out.count == 2)
        func close(_ a: [Double], _ x: Double, _ y: Double) -> Bool {
            abs(a[0] - x) < 1e-6 && abs(a[1] - y) < 1e-6
        }
        #expect(close(out[0][0], 0, 0))
        #expect(close(out[0][1], 25, -5))
        #expect(close(out[0][2], 50, 0))
        #expect(close(out[1][0], 50, 0))
        #expect(close(out[1][2], 100, 0))
    }

    @Test func emptyForDegenerate() {
        #expect(patternAlongPath([.moveTo(0, 0)], brush()).isEmpty)
    }
}
