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

    // MARK: - S-4: a leading ClosePath is a no-op
    //
    // Ruled by JYH at the fleet council, 2026-07-27. Honoured by
    // `flattenPathCommands` and `flattenPathToRings` since that ruling landed;
    // this flattener was the THIRD one and did not honour it, in BOTH ports
    // identically, so the equivalence gate was structurally blind. The
    // cross-language pin is test_fixtures/algorithms/art_flatten.json; these
    // are the in-port pins, and the FIRST is the artist-visible consequence the
    // fixture cannot reach (the fixture drives `flattenArtPath`, not the brush).

    /// THE CONSEQUENCE. A leading Z made the whole path flatten to nothing, so
    /// an art brush applied to it produced NO ribbon at all — a silently blank
    /// stroke. With the ruling honoured the output equals the same path without
    /// the leading Z (`straightPathWarpsToCenteredRibbon`).
    @Test func artAlongAPathWithALeadingCloseDrawsTheSameRibbon() {
        let withZ = artAlongPath([.closePath, .moveTo(0, 0), .lineTo(100, 0)], rhombus())
        let withoutZ = artAlongPath([.moveTo(0, 0), .lineTo(100, 0)], rhombus())
        #expect(withZ == withoutZ, "a leading Z changed the ribbon")
        // MANDATORY GEOMETRY PAIRING: equality to a possibly-empty value is not
        // enough — say where the ribbon actually is.
        #expect(withZ.count == 1, "one ribbon")
        guard withZ.count == 1, withZ[0].count == 4 else {
            Issue.record("expected one 4-point ribbon, got \(withZ)"); return
        }
        #expect(abs(withZ[0][1][0] - 50) < 1e-6 && abs(withZ[0][1][1] + 1) < 1e-6,
                "mid-top should be (50, -1), got \(withZ[0][1])")
    }

    /// The flattener, directly: a leading close is SKIPPED, not a bail-out.
    /// Without the guard this returns `[]`.
    @Test func flattenArtPathLeadingCloseIsSkippedNotABailOut() {
        let out = flattenArtPath([.closePath, .moveTo(3, 2), .lineTo(13, 2)])
        #expect(out.map { [$0.0, $0.1] } == [[3, 2], [13, 2]])
    }

    /// SCOPE BOUNDARY against the over-fix. A close that is NOT leading still
    /// closes and still ENDS the first subpath — art rides the first subpath
    /// only. This does NOT fail under the pre-fix code; it fails if the arm is
    /// turned into an unconditional `continue`, which would append the second
    /// subpath and silently redefine "the first subpath".
    @Test func flattenArtPathARealCloseStillEndsTheFirstSubpath() {
        let out = flattenArtPath([.moveTo(3, 2), .lineTo(13, 2), .closePath,
                                  .moveTo(23, 2), .lineTo(33, 2)])
        #expect(out.map { [$0.0, $0.1] } == [[3, 2], [13, 2], [3, 2]])
    }

    /// SCOPE BOUNDARY, and why the guard reads the ACCUMULATOR and not the
    /// coordinates: at `M(5,5) Z` we also have cx == sx and cy == sy, but a
    /// point has been established, so the close is real and ends the subpath. A
    /// guard written as `cx == sx && cy == sy` would pass the fixture's
    /// leading-close vectors and break this one.
    @Test func flattenArtPathMoveToThenImmediateCloseIsARealClose() {
        let out = flattenArtPath([.moveTo(5, 5), .closePath,
                                  .moveTo(50, 50), .lineTo(60, 50)])
        #expect(out.map { [$0.0, $0.1] } == [[5, 5]])
    }
}
