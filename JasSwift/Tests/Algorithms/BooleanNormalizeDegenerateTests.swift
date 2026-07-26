import Testing
@testable import JasLib

// The planar/boolean DEGENERATE cases for the ring normalizer. Mirrors
// the same-named tests in jas_dioxus/src/algorithms/boolean_normalize.rs,
// derivations included.
//
// Why these carry hand-derived expected values rather than leaning on the
// cross-language corpus: the degenerate classes below were SHARED
// limitations of both ports, so a differential comparison is blind to
// them — wrong-vs-wrong compares equal. The corpus gates AGREEMENT
// between Rust and Swift; these tests gate CORRECTNESS. Both are needed.

private let NEPS: Double = 1e-9

private func signedArea(_ ring: BoolRing) -> Double {
    if ring.count < 3 { return 0.0 }
    var sum = 0.0
    let n = ring.count
    for i in 0..<n {
        let (x1, y1) = ring[i]
        let (x2, y2) = ring[(i + 1) % n]
        sum += x1 * y2 - x2 * y1
    }
    return sum / 2.0
}

private func signedAreas(_ ps: BoolPolygonSet) -> [Double] {
    ps.map { signedArea($0) }.sorted()
}

private func absArea(_ ps: BoolPolygonSet) -> Double {
    ps.map { abs(signedArea($0)) }.reduce(0.0, +)
}

/// Rotate a ring so its lexicographically smallest vertex comes first,
/// without changing the cyclic order. Lets a test pin an exact vertex
/// sequence without also pinning where the traversal happened to start.
private func canonical(_ ring: BoolRing) -> BoolRing {
    let n = ring.count
    var best = 0
    for i in 1..<n {
        let b = ring[best]
        let p = ring[i]
        if p.0 < b.0 || (p.0 == b.0 && p.1 < b.1) { best = i }
    }
    return (0..<n).map { ring[(best + $0) % n] }
}

/// Every ring canonicalized, then ordered by first vertex, so a test can
/// compare a whole result set without pinning the traversal order.
private func canonicalSorted(_ ps: BoolPolygonSet) -> [BoolRing] {
    var rings: [BoolRing] = []
    for r in ps { rings.append(canonical(r)) }
    rings.sort { (a: BoolRing, b: BoolRing) -> Bool in
        let pa: (Double, Double) = a[0]
        let pb: (Double, Double) = b[0]
        if pa.0 != pb.0 { return pa.0 < pb.0 }
        return pa.1 < pb.1
    }
    return rings
}

private func ringsEqual(_ a: BoolRing, _ b: BoolRing) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
}

private func setsEqual(_ a: BoolPolygonSet, _ b: BoolPolygonSet) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { ringsEqual($0, $1) }
}

/// True if no two non-adjacent edges of `ring` meet — the normalizer's
/// whole contract.
private func isSimple(_ ring: BoolRing) -> Bool {
    let n = ring.count
    for i in 0..<n {
        for j in (i + 1)..<n {
            let adjacent = j == i + 1 || (i == 0 && j == n - 1)
            let pts = arrangementSplitPoints(
                ring[i], ring[(i + 1) % n], ring[j], ring[(j + 1) % n])
            if adjacent {
                // Consecutive edges legitimately meet at exactly their
                // shared vertex, and nowhere else.
                if pts.count != 1 { return false }
            } else if !pts.isEmpty {
                return false
            }
        }
    }
    return true
}

// MARK: - T-junction self-touch

@Test func normTJunctionSelfIntersection() {
    // The classic bowtie with (5,5) made an explicit VERTEX of the ring
    // rather than an interior crossing point:
    //   (0,0) -> (5,5) -> (10,10) -> (10,0) -> (0,10) -> close
    // The edge (10,0)-(0,10) now passes exactly through the ring's own
    // vertex (5,5). The old predicate demanded a strictly interior
    // parameter on BOTH edges, so it saw nothing, called the pentagon
    // simple and returned it whole.
    //
    // Derivation: inserting a vertex on a straight edge cannot change
    // the region, so the answer must equal the bowtie's — the two lobes
    //   left  (0,0),(5,5),(0,10): 2A = 0*5-5*0 + 5*10-0*5 + 0*0-0*10
    //                                = 50 -> +25
    //   right (5,5),(10,0),(10,10): 2A = 5*0-10*5 + 10*10-10*0
    //                                + 10*5-5*10 = 50 -> +25
    // Both lobes are filled (winding +1 left, -1 right of the original),
    // so both survive, both CCW because the filled side goes on the left.
    let input: BoolPolygonSet = [[
        (0.0, 0.0), (5.0, 5.0), (10.0, 10.0), (10.0, 0.0), (0.0, 10.0),
    ]]
    let out = normalize(input)
    #expect(out.count == 2)
    let areas = signedAreas(out)
    #expect(abs(areas[0] - 25.0) < NEPS)
    #expect(abs(areas[1] - 25.0) < NEPS)
    let got = canonicalSorted(out)
    #expect(ringsEqual(got[0], [(0.0, 0.0), (5.0, 5.0), (0.0, 10.0)]))
    #expect(ringsEqual(got[1], [(5.0, 5.0), (10.0, 0.0), (10.0, 10.0)]))
    for r in out { #expect(isSimple(r)) }
}

@Test func normPinchAtRevisitedVertexSplitsIntoTwoLobes() {
    // A ring that visits (5,5) twice — a "pinch" rather than a crossing:
    //   (0,0) -> (5,5) -> (10,0) -> (10,10) -> (5,5) -> (0,10)
    // Both meetings are at endpoints of both edges, so again the old
    // strict predicate saw nothing.
    //
    // Derivation: two triangles joined at (5,5), each of area 25 (same
    // shoelace sums as above), each wound exactly once, so both filled.
    let input: BoolPolygonSet = [[
        (0.0, 0.0), (5.0, 5.0), (10.0, 0.0),
        (10.0, 10.0), (5.0, 5.0), (0.0, 10.0),
    ]]
    let out = normalize(input)
    #expect(out.count == 2)
    #expect(abs(absArea(out) - 50.0) < NEPS)
    for r in out {
        #expect(r.count == 3)
        #expect(isSimple(r))
    }
}

// MARK: - Collinear self-overlap

@Test func normCollinearSelfRetrace() {
    // A 10x10 square whose top edge carries a SLIT: the path runs in to
    // (5,5) and straight back out along the same line.
    //   (0,0) -> (10,0) -> (10,10) -> (5,10) -> (5,5) -> (5,10)
    //         -> (0,10) -> close
    // The two slit edges are exact reverses: a collinear overlap over
    // their whole span. The determinant is zero, so the old predicate
    // returned nil and the ring came back whole — not simple, with a
    // zero-area spine hanging off its boundary.
    //
    // Derivation. A retraced span contributes nothing to the winding: on
    // its left the count is +1 (square) -1 +1 = +1, and on its right +1
    // as well, so the region is the same on both sides and the span is
    // not a boundary. What remains is the plain square with the vertex
    // (5,10) retained (collapsing collinear vertices is the Boolean
    // panel's separate opt-in). Shoelace on
    // (0,0),(10,0),(10,10),(5,10),(0,10): 0 + 100 + 50 + 50 + 0 = 200,
    // so area 100.
    let input: BoolPolygonSet = [[
        (0.0, 0.0), (10.0, 0.0), (10.0, 10.0),
        (5.0, 10.0), (5.0, 5.0), (5.0, 10.0), (0.0, 10.0),
    ]]
    let out = normalize(input)
    #expect(out.count == 1)
    #expect(ringsEqual(canonical(out[0]), [
        (0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (5.0, 10.0), (0.0, 10.0),
    ]))
    #expect(abs(signedAreas(out)[0] - 100.0) < NEPS)
    #expect(isSimple(out[0]))
}

// MARK: - Retrograde loop

@Test func normRetrogradeLoopCancelsUnderNonZeroWinding() {
    // A ring that traces a big square CCW and also, spliced in via a
    // slit from the corner (0,0), a small COUNTER-rotating loop inside:
    //   (0,0) -> (5,2) -> (5,4) -> (7,4) -> (7,2) -> (5,2)
    //         -> (0,0) -> (10,0) -> (10,10) -> (0,10) -> close
    // The inner loop runs CW: shoelace on (5,2),(5,4),(7,4),(7,2)
    // = 10 - 8 - 14 + 4 = -8, so signed area -4.
    //
    // Derivation. Inside the inner loop the winding is +1 (outer square)
    // + (-1) (inner CW loop) = 0, so that region is NOT filled: the loop
    // must survive as a HOLE, not vanish and not fill. Elsewhere in the
    // square the winding is +1. The slit (0,0)-(5,2) is traversed both
    // ways, so the winding is +1 on both of its sides and it is dropped
    // — the hole is not connected to the outer boundary by a hairline.
    //
    // Expected: two rings, the square CCW at +100 and the inner loop CW
    // at -4, net filled area 96. Both simple. The old recursive-split
    // normalizer found no proper crossing here at all and returned the
    // whole ten-vertex tangle as if it were one simple ring.
    let input: BoolPolygonSet = [[
        (0.0, 0.0), (5.0, 2.0), (5.0, 4.0), (7.0, 4.0), (7.0, 2.0),
        (5.0, 2.0), (0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0),
    ]]
    let out = normalize(input)
    #expect(out.count == 2)
    let areas = signedAreas(out)
    #expect(abs(areas[0] + 4.0) < NEPS)
    #expect(abs(areas[1] - 100.0) < NEPS)
    #expect(abs(areas.reduce(0.0, +) - 96.0) < NEPS)
    let got = canonicalSorted(out)
    #expect(ringsEqual(got[0], [
        (0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0),
    ]))
    #expect(ringsEqual(got[1], [
        (5.0, 2.0), (5.0, 4.0), (7.0, 4.0), (7.0, 2.0),
    ]))
    for r in out { #expect(isSimple(r)) }
}

@Test func normCoRotatingSplicedLoopFusesIntoOneRing() {
    // The same shape but with the inner loop running the SAME way as the
    // outer square (CCW). Inside it the winding is +1 + 1 = 2, non-zero,
    // so that region is filled — and being filled on both sides, the
    // loop is not a boundary at all.
    //
    // Derivation: the filled region is exactly the square, so one CCW
    // ring of area 100. Companion of the test above: same slit, same
    // loop, opposite winding, completely different answer — which is the
    // point of evaluating the winding rather than counting rings.
    let input: BoolPolygonSet = [[
        (0.0, 0.0), (5.0, 2.0), (7.0, 2.0), (7.0, 4.0), (5.0, 4.0),
        (5.0, 2.0), (0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0),
    ]]
    let out = normalize(input)
    #expect(out.count == 1)
    #expect(ringsEqual(canonical(out[0]), [
        (0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0),
    ]))
    #expect(abs(signedAreas(out)[0] - 100.0) < NEPS)
}

// MARK: - Inter-ring relations: NOT this module's call
//
// BoolPolygonSet is contractually a flat list of rings under the EVEN-ODD
// rule, with orientation explicitly outside the contract. So the
// normalizer must not read a set's rings as one non-zero-wound region:
// doing so re-interprets the operand. The tests below pin that, ring
// relation by ring relation, so a later widening of the scope cannot
// happen silently.

@Test func normNestedCoOrientedRingsKeepTheHole() {
    // Two CCW rings of one set, one nested inside the other. Under
    // even-odd the inner ring is a HOLE (a ray from inside it crosses
    // two ring edges); under non-zero it would be solid, winding 2. Both
    // rings are individually simple, so both pass through untouched and
    // the even-odd reading survives for the sweep to act on. A set-wide
    // non-zero reading here would delete every donut expressed the
    // natural way.
    let outer: BoolRing = [(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)]
    let inner: BoolRing = [(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)]
    #expect(setsEqual(normalize([outer, inner]), [outer, inner]))
}

@Test func normNestedOpposedRingsKeepTheHole() {
    // The same nesting with the inner ring wound the other way.
    // Even-odd ignores orientation, so the answer must be identical.
    let outer: BoolRing = [(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)]
    let inner: BoolRing = [(5.0, 5.0), (5.0, 15.0), (15.0, 15.0), (15.0, 5.0)]
    #expect(setsEqual(normalize([outer, inner]), [outer, inner]))
}

@Test func normOverlappingRingsAreLeftForTheSweep() {
    // Two CCW squares of one set that genuinely overlap: [0,10]^2 and
    // [5,15]^2. Their boundaries CROSS, at (10,5) and (5,10) — the case
    // where a set-wide reading is most tempting. Under even-odd the
    // overlap is outside the region, making the set a symmetric
    // difference; under non-zero it would be the union. Each ring is
    // simple alone, so both pass through and the sweep decides.
    let a: BoolRing = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    let b: BoolRing = [(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)]
    #expect(setsEqual(normalize([a, b]), [a, b]))
}

@Test func normRingsSharingCollinearEdgePassThrough() {
    // Two CCW squares of one set sharing a full edge: [0,10]x[0,10] and
    // [10,20]x[0,10]. The shared span x=10 is traced upward by the first
    // and downward by the second — an INTER-ring collinear overlap. Each
    // ring is still simple by itself, so both pass through; fusing them
    // across the shared span would be the non-zero reading of the set.
    let a: BoolRing = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    let b: BoolRing = [(10.0, 0.0), (20.0, 0.0), (20.0, 10.0), (10.0, 10.0)]
    #expect(setsEqual(normalize([a, b]), [a, b]))
}

@Test func normDisjointRingsTakeTheFastPathUntouched() {
    // Pins that widening the intersection predicate did not drag the
    // ordinary case onto the arrangement path — bit-identical, in input
    // order.
    let a: BoolRing = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    let b: BoolRing = [(20.0, 0.0), (30.0, 0.0), (30.0, 10.0), (20.0, 10.0)]
    #expect(setsEqual(normalize([a, b]), [a, b]))
}

@Test func normDegenerateRingDoesNotTakeItsSiblingsWithIt() {
    // One good ring plus one zero-area collinear ring. Per-ring scope
    // means the collinear one is dropped (it encloses nothing) and the
    // good one survives verbatim.
    let a: BoolRing = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    let flat: BoolRing = [(20.0, 0.0), (25.0, 0.0), (30.0, 0.0)]
    #expect(setsEqual(normalize([a, flat]), [a]))
}

@Test func normZeroAreaCollinearRingIsDropped() {
    // Three collinear vertices enclose nothing, so the non-zero region
    // is empty and the output must be empty too.
    #expect(normalize([[(0.0, 0.0), (5.0, 0.0), (10.0, 0.0)]]).isEmpty)
}

@Test func normCwSquarePassesThroughPreservingSignedArea() {
    // A lone CW ring is a well-formed region boundary — winding -1
    // inside, 0 outside — so it takes the fast path and comes back
    // untouched, sign included.
    let cw: BoolRing = [(0.0, 0.0), (0.0, 10.0), (10.0, 10.0), (10.0, 0.0)]
    let out = normalize([cw])
    #expect(out.count == 1)
    #expect(ringsEqual(out[0], cw))
    #expect(abs(signedAreas(out)[0] + 100.0) < NEPS)
}
