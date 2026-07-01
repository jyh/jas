import Testing
import Foundation
@testable import JasLib

/// Equivalence vectors shared with the Rust reference
/// (jas_dioxus/src/algorithms/art_along_path.rs) — a tapered lens
/// (rhombus) warped along a straight horizontal path.
private func rhombus() -> ArtBrush {
    ArtBrush(artworkWidth: 100.0, artworkHeight: 20.0,
             artwork: [[[0.0, 10.0], [50.0, 0.0], [100.0, 10.0], [50.0, 20.0]]],
             scale: 100.0, flipAcross: false, flipAlong: false, strokeWeight: 2.0)
}

@Suite struct ArtAlongPathTests {
    @Test func straightPathWarpsToCenteredRibbon() {
        let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0)]
        let out = artAlongPath(cmds, rhombus())
        #expect(out.count == 1)
        let p = out[0]
        #expect(p.count == 4)
        func close(_ a: [Double], _ x: Double, _ y: Double) -> Bool {
            abs(a[0] - x) < 1e-6 && abs(a[1] - y) < 1e-6
        }
        #expect(close(p[0], 0, 0))
        #expect(close(p[1], 50, -1))
        #expect(close(p[2], 100, 0))
        #expect(close(p[3], 50, 1))
    }

    @Test func emptyForDegenerate() {
        #expect(artAlongPath([.moveTo(0, 0)], rhombus()).isEmpty)
    }

    @Test func flipAcrossMirrorsOffset() {
        let b = ArtBrush(artworkWidth: 100, artworkHeight: 20,
                         artwork: [[[0, 10], [50, 0], [100, 10], [50, 20]]],
                         scale: 100, flipAcross: true, flipAlong: false, strokeWeight: 2)
        let out = artAlongPath([.moveTo(0, 0), .lineTo(100, 0)], b)
        #expect(abs(out[0][1][1] - 1.0) < 1e-6)
    }
}
