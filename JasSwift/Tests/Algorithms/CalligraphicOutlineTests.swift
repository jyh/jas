import Testing
import Foundation
@testable import JasLib

/// S-4: a leading ClosePath is a no-op — ruled by JYH at the fleet council,
/// 2026-07-27.
///
/// `sampleStrokePath` is the FOURTH first-subpath walker in the tree and the
/// SECOND one that got the ruling wrong (`flattenArtPath` was the first). The
/// consequence here is louder: Calligraphic is the Phase-1 DEFAULT brush, so a
/// path whose `d` begins with Z stroked nothing at all. Wrong identically in
/// Rust and Swift, so the equivalence gate was structurally blind; the
/// cross-language pin is test_fixtures/algorithms/calligraphic_outline.json and
/// these are the in-port twins of
/// `calligraphic_outline_ignores_a_leading_close` /
/// `calligraphic_moveto_then_immediate_close_does_not_sample_the_next_subpath`.
@Suite struct CalligraphicOutlineLeadingCloseTests {
    private let brush = CalligraphicBrush(angle: 30, roundness: 40, size: 6)

    /// THE CONSEQUENCE, as an equality: a leading Z changes nothing.
    @Test func calligraphicOutlineIgnoresALeadingClose() {
        let withZ = calligraphicOutline([.closePath, .moveTo(0, 0), .lineTo(4, 0)], brush)
        let withoutZ = calligraphicOutline([.moveTo(0, 0), .lineTo(4, 0)], brush)
        #expect(withZ.map { [$0.0, $0.1] } == withoutZ.map { [$0.0, $0.1] },
                "a leading Z changed the outline")
        // MANDATORY GEOMETRY PAIRING: equality to a possibly-empty value proves
        // nothing, so say where the ribbon is. A 4pt horizontal line sampled at
        // 1pt gives 5 samples, so 10 outline points, and every one of them sits
        // at a constant offset from the baseline y = 0 (the brush angle is fixed
        // in screen space and the tangent never turns).
        #expect(withZ.count == 10, "5 samples -> 10 outline points, got \(withZ.count)")
        guard let off = withZ.first?.1 else {
            Issue.record("no outline points at all"); return
        }
        #expect(abs(off) > 1.0, "the ribbon must have real width, got \(off)")
        for (i, p) in withZ.enumerated() {
            #expect(p.0 >= 0 && p.0 <= 4, "point \(i) left the path's x span: \(p.0)")
            #expect(abs(abs(p.1) - abs(off)) < 1e-9,
                    "point \(i) is not at the constant offset \(off): \(p.1)")
        }
    }

    /// SCOPE BOUNDARY, and why the guard is "a current point has been
    /// established" and NOT `cx == sx && cy == sy`: at `M(5,5) Z` those
    /// coordinates are equal exactly as at a leading close, but the close is
    /// REAL and ends the subpath. A guard on the coordinates would fall through
    /// and sample the SECOND subpath — this asserts it does not.
    @Test func calligraphicMoveToThenImmediateCloseDoesNotSampleTheNextSubpath() {
        let pts = calligraphicOutline([.moveTo(5, 5), .closePath,
                                       .moveTo(50, 50), .lineTo(54, 50)], brush)
        #expect(pts.isEmpty,
                """
                a zero-length first subpath outlines to nothing; got \
                \(pts.count) points starting at \(String(describing: pts.first)) \
                — the walk ran on into the second subpath
                """)
    }
}
