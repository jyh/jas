import Testing
@testable import JasLib

/// `firstRepeatedVertex` dispatches between an O(n^2) pairwise scan and an
/// O(n)-expected index map on ring length — the twin of the same
/// dispatcher in jas_dioxus/src/algorithms/boolean.rs.
///
/// Neither body is allowed to return a different (i, j) pair from the
/// other, in either direction: `splitPinchedRing` cuts at that pair and
/// the exact-comparison corpus pins the resulting ring order across both
/// ports. Which body is FASTER depends on the ring length — see
/// `pinchMapThreshold`, whose doc carries the measurements. So an
/// independent copy of the quadratic scan lives on here as the oracle,
/// and each body is checked against it DIRECTLY: the fixtures below are
/// short, so testing only the dispatcher would route all of them to the
/// scan and never exercise the map at all.
///
/// The two traps a bit-keyed map falls into, and why they are tested
/// rather than reasoned about:
///
///  * `-0.0 == 0.0` is TRUE while the bit patterns differ, so a raw
///    `bitPattern` key MISSES a pinch the scan finds.
///  * `NaN != NaN`, yet two NaNs of one payload have equal bits, so a
///    raw key INVENTS a pinch that is not there.

/// An independent copy of the pairwise scan, kept as the oracle so an
/// edit to the shipped `firstRepeatedVertexScan` has something to
/// disagree with.
private func firstRepeatedVertexQuadratic(_ ring: BoolRing) -> (Int, Int)? {
    guard ring.count > 1 else { return nil }
    for j in 1..<ring.count {
        for i in 0..<j {
            if ring[i] == ring[j] { return (i, j) }
        }
    }
    return nil
}

/// Deterministic PRNG in [-1, 1] — the same LCG the Rust twin uses.
private func lcg(_ seed: inout UInt64) -> Double {
    seed = seed &* 1664525 &+ 1013904223
    let v = Double(seed >> 11) / Double(UInt64(1) << 53)  // [0,1)
    return 2.0 * v - 1.0
}

private func adversarialRings() -> [BoolRing] {
    [
        // No repeat at all.
        [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)],
        // A plain pinch.
        [(0.0, 0.0), (5.0, 5.0), (10.0, 0.0), (5.0, 5.0), (0.0, 10.0)],
        // Signed zero on x: equal under ==, different bits.
        [(0.0, 1.0), (5.0, 5.0), (-0.0, 1.0), (9.0, 9.0)],
        // Signed zero on y.
        [(1.0, -0.0), (5.0, 5.0), (1.0, 0.0), (9.0, 9.0)],
        // Signed zero in BOTH coordinates.
        [(-0.0, -0.0), (5.0, 5.0), (0.0, 0.0), (9.0, 9.0)],
        // Two NaNs: equal bits, NOT equal values.
        [(Double.nan, 1.0), (5.0, 5.0), (Double.nan, 1.0), (9.0, 9.0)],
        // A NaN and a real repeat after it — the repeat must win.
        [(Double.nan, 0.0), (3.0, 3.0), (Double.nan, 0.0), (3.0, 3.0)],
        // Three occurrences: the FIRST pair (smallest j, then smallest
        // i) is the answer.
        [(1.0, 1.0), (2.0, 2.0), (1.0, 1.0), (1.0, 1.0)],
        // Degenerate lengths.
        [],
        [(1.0, 1.0)],
        [(1.0, 1.0), (1.0, 1.0)],
    ]
}

private func same(_ a: (Int, Int)?, _ b: (Int, Int)?) -> Bool {
    a?.0 == b?.0 && a?.1 == b?.1
}

/// Every body against the oracle, on every fixture, independently of the
/// length threshold.
@Test func firstRepeatedVertexMatchesTheQuadraticScan() {
    for (n, ring) in adversarialRings().enumerated() {
        let want = firstRepeatedVertexQuadratic(ring)
        #expect(same(firstRepeatedVertexMap(ring), want),
                "adversarial ring \(n), map body, disagrees with the oracle \(String(describing: want)): got \(String(describing: firstRepeatedVertexMap(ring)))")
        #expect(same(firstRepeatedVertexScan(ring), want),
                "adversarial ring \(n), scan body, disagrees with the oracle")
        #expect(same(firstRepeatedVertex(ring), want),
                "adversarial ring \(n), dispatcher, disagrees with the oracle")
    }
    // Random rings drawn from a small coordinate alphabet so repeats are
    // common, including signed zeros.
    let alphabet: [Double] = [0.0, -0.0, 1.0, 2.0, -1.0, 0.5]
    var seed: UInt64 = 0x5eed_1234
    for _ in 0..<4000 {
        let len = Int(abs(lcg(&seed)) * 12.0) + 1
        var ring: BoolRing = []
        for _ in 0..<len {
            let xi = Int(abs(lcg(&seed)) * Double(alphabet.count)) % alphabet.count
            let yi = Int(abs(lcg(&seed)) * Double(alphabet.count)) % alphabet.count
            ring.append((alphabet[xi], alphabet[yi]))
        }
        let want = firstRepeatedVertexQuadratic(ring)
        #expect(same(firstRepeatedVertexMap(ring), want),
                "random ring, map body, disagrees: \(ring)")
        #expect(same(firstRepeatedVertexScan(ring), want),
                "random ring, scan body, disagrees: \(ring)")
        #expect(same(firstRepeatedVertex(ring), want),
                "random ring, dispatcher, disagrees: \(ring)")
    }
}

/// The dispatcher must give the same answer on both sides of
/// `pinchMapThreshold`, so the switch is invisible in the output. Rings
/// are built at length T-1, T and T+1, each in three flavours: pinch-free,
/// a pinch in the first half, and a pinch at the very end (the case that
/// scans furthest). The pinch coordinate is a signed-zero pair, so the map
/// body's canonicalization is exercised at these lengths too. Twin of
/// Rust's first_repeated_vertex_agrees_across_the_threshold.
@Test func firstRepeatedVertexAgreesAcrossTheThreshold() {
    for len in [pinchMapThreshold - 1, pinchMapThreshold, pinchMapThreshold + 1] {
        // Distinct coordinates: i is unique, so no accidental repeat.
        let base: BoolRing = (0..<len).map { (Double($0), Double($0) * 2.0 + 0.5) }
        var pinchEarly = base
        pinchEarly[1] = (-0.0, 0.0)
        pinchEarly[len / 2] = (0.0, -0.0)
        var pinchLate = base
        pinchLate[0] = (-0.0, 0.0)
        pinchLate[len - 1] = (0.0, -0.0)
        for (label, ring) in [("pinch-free", base), ("pinch-early", pinchEarly),
                              ("pinch-late", pinchLate)] {
            let want = firstRepeatedVertexQuadratic(ring)
            #expect(same(firstRepeatedVertex(ring), want),
                    "len \(len) \(label): dispatcher disagrees with the oracle")
            #expect(same(firstRepeatedVertexMap(ring), want),
                    "len \(len) \(label): map body disagrees with the oracle")
            #expect(same(firstRepeatedVertexScan(ring), want),
                    "len \(len) \(label): scan body disagrees with the oracle")
        }
        // The fixtures must actually contain what they claim, or the
        // agreement above is vacuous.
        #expect(firstRepeatedVertexQuadratic(base) == nil,
                "the pinch-free fixture at len \(len) has a repeat")
        #expect(same(firstRepeatedVertexQuadratic(pinchLate), (0, len - 1)),
                "the pinch-late fixture at len \(len) does not end in the pinch")
    }
}
