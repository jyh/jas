import Testing
@testable import JasLib

/// `firstRepeatedVertex` reduced from an O(n^2) pairwise scan to an
/// O(n)-expected index map — the twin of the same reduction in
/// jas_dioxus/src/algorithms/boolean.rs.
///
/// The reduction is only allowed to be faster. It must return the SAME
/// (i, j) pair, because `splitPinchedRing` cuts at that pair and the
/// exact-comparison corpus pins the resulting ring order across both
/// ports. So the retired quadratic scan lives on here as the oracle.
///
/// The two traps a bit-keyed map falls into, and why they are tested
/// rather than reasoned about:
///
///  * `-0.0 == 0.0` is TRUE while the bit patterns differ, so a raw
///    `bitPattern` key MISSES a pinch the scan finds.
///  * `NaN != NaN`, yet two NaNs of one payload have equal bits, so a
///    raw key INVENTS a pinch that is not there.

/// The O(n^2) scan the implementation replaced, kept as the oracle.
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

@Test func firstRepeatedVertexMatchesTheQuadraticScan() {
    for (n, ring) in adversarialRings().enumerated() {
        let fast = firstRepeatedVertex(ring)
        let slow = firstRepeatedVertexQuadratic(ring)
        #expect(fast?.0 == slow?.0 && fast?.1 == slow?.1,
                "adversarial ring \(n) disagrees: fast \(String(describing: fast)) vs scan \(String(describing: slow))")
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
        let fast = firstRepeatedVertex(ring)
        let slow = firstRepeatedVertexQuadratic(ring)
        #expect(fast?.0 == slow?.0 && fast?.1 == slow?.1,
                "random ring disagrees: \(ring)")
    }
}
