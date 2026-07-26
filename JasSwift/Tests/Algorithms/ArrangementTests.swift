import Testing
@testable import JasLib

// Mirrors the split_points test suite in
// jas_dioxus/src/algorithms/arrangement.rs, case for case.
//
// Arrangement.swift was previously covered only indirectly, through
// PlanarTests and BooleanNormalizeDegenerateTests. That is coverage of the
// callers, not of the predicate: a Swift-only slip in the parameter
// snapping or in the collinear-overlap branch could be masked by a caller
// that happens to dedup its way back to the right answer, and the
// cross-language corpus would only say the two ports disagree somewhere in
// a whole algorithm. These pin the predicate itself, at the same inputs as
// Rust, so a divergence names its own line.

private let PARAM_EPS: Double = 1e-12

/// Assert a returned split point equals `pt` exactly. Exactness is the
/// property under test in the T-junction and collinear cases: the point
/// must be the original endpoint, not a re-derived neighbour of it, or the
/// caller's vertex dedup cannot fuse the two into one vertex.
private func expectExact(
    _ got: (Double, Double), _ want: (Double, Double),
    _ label: Comment, sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(got.0 == want.0 && got.1 == want.1, label,
            sourceLocation: sourceLocation)
}

@Test func arrProperCrossingReportsInteriorParameters() {
    let pts = arrangementSplitPoints((0.0, 0.0), (10.0, 10.0),
                                     (10.0, 0.0), (0.0, 10.0))
    #expect(pts.count == 1)
    guard let (p, s, t) = pts.first else { return }
    #expect(abs(p.0 - 5.0) < PARAM_EPS && abs(p.1 - 5.0) < PARAM_EPS)
    #expect(abs(s - 0.5) < PARAM_EPS)
    #expect(abs(t - 0.5) < PARAM_EPS)
}

@Test func arrTJunctionReportsTheExactTouchingEndpoint() {
    // b's start (5,0) sits in the interior of a. The reported point must
    // be b1 itself, bit-exact, not 5.0000000001.
    let pts = arrangementSplitPoints((0.0, 0.0), (10.0, 0.0),
                                     (5.0, 0.0), (5.0, 5.0))
    #expect(pts.count == 1)
    guard let (p, s, t) = pts.first else { return }
    expectExact(p, (5.0, 0.0), "T-junction point must be b1 bit-exact")
    #expect(abs(s - 0.5) < PARAM_EPS)
    #expect(t == 0.0)
}

@Test func arrEndpointCoincidenceIsReportedAtTheSharedVertex() {
    let pts = arrangementSplitPoints((0.0, 0.0), (10.0, 0.0),
                                     (0.0, 0.0), (0.0, 10.0))
    #expect(pts.count == 1)
    guard let (p, s, t) = pts.first else { return }
    expectExact(p, (0.0, 0.0), "shared vertex must come back exact")
    #expect(s == 0.0)
    #expect(t == 0.0)
}

@Test func arrParallelButNotCollinearPairHasNoSplitPoints() {
    #expect(arrangementSplitPoints((0.0, 0.0), (10.0, 0.0),
                                   (0.0, 1.0), (10.0, 1.0)).isEmpty)
}

@Test func arrCrossingOutsideBothSegmentsHasNoSplitPoints() {
    // The lines meet at (20,0), beyond the end of both segments.
    #expect(arrangementSplitPoints((0.0, 0.0), (10.0, 0.0),
                                   (30.0, 10.0), (25.0, 5.0)).isEmpty)
}

@Test func arrCollinearPartialOverlapReportsBothOverlapEnds() {
    // a covers x in [0,10]; b covers x in [4,20]. Overlap [4,10].
    let pts = arrangementSplitPoints((0.0, 0.0), (10.0, 0.0),
                                     (4.0, 0.0), (20.0, 0.0))
    #expect(pts.count == 2)
    guard pts.count == 2 else { return }
    expectExact(pts[0].0, (4.0, 0.0), "overlap start is b1")
    #expect(abs(pts[0].1 - 0.4) < PARAM_EPS)
    #expect(pts[0].2 == 0.0)
    expectExact(pts[1].0, (10.0, 0.0), "overlap end is a2")
    #expect(pts[1].1 == 1.0)
    #expect(abs(pts[1].2 - 0.375) < PARAM_EPS)
}

@Test func arrCollinearReversedOverlapReportsBothOverlapEnds() {
    // Same spans as above but b runs the other way; the answer must not
    // depend on b's direction.
    let pts = arrangementSplitPoints((0.0, 0.0), (10.0, 0.0),
                                     (20.0, 0.0), (4.0, 0.0))
    #expect(pts.count == 2)
    guard pts.count == 2 else { return }
    expectExact(pts[0].0, (4.0, 0.0), "overlap start")
    expectExact(pts[1].0, (10.0, 0.0), "overlap end")
}

@Test func arrCollinearContainedSpanReportsTheInnerEnds() {
    // b sits strictly inside a: both of b's endpoints split a.
    let pts = arrangementSplitPoints((0.0, 0.0), (10.0, 0.0),
                                     (3.0, 0.0), (7.0, 0.0))
    #expect(pts.count == 2)
    guard pts.count == 2 else { return }
    expectExact(pts[0].0, (3.0, 0.0), "inner start")
    expectExact(pts[1].0, (7.0, 0.0), "inner end")
}

@Test func arrCollinearTouchingAtOnePointReportsOnePoint() {
    // a covers [0,10], b covers [10,20]: they meet only at x=10.
    let pts = arrangementSplitPoints((0.0, 0.0), (10.0, 0.0),
                                     (10.0, 0.0), (20.0, 0.0))
    #expect(pts.count == 1)
    guard let p = pts.first?.0 else { return }
    expectExact(p, (10.0, 0.0), "degenerate overlap collapses to one point")
}

@Test func arrCollinearDisjointSpansHaveNoSplitPoints() {
    #expect(arrangementSplitPoints((0.0, 0.0), (10.0, 0.0),
                                   (20.0, 0.0), (30.0, 0.0)).isEmpty)
}

@Test func arrCollinearFullRetraceReportsBothEndpoints() {
    // A segment and its exact reverse — the collinear self-overlap that a
    // retraced spike produces.
    let pts = arrangementSplitPoints((5.0, 10.0), (5.0, 5.0),
                                     (5.0, 5.0), (5.0, 10.0))
    #expect(pts.count == 2)
    guard pts.count == 2 else { return }
    expectExact(pts[0].0, (5.0, 10.0), "retrace reports a1")
    expectExact(pts[1].0, (5.0, 5.0), "retrace reports a2")
}
