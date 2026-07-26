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
    let out = normalize(input, .nonzero)
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
    let out = normalize(input, .nonzero)
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
    let out = normalize(input, .nonzero)
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
    let out = normalize(input, .nonzero)
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
    let out = normalize(input, .nonzero)
    #expect(out.count == 1)
    #expect(ringsEqual(canonical(out[0]), [
        (0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0),
    ]))
    #expect(abs(signedAreas(out)[0] - 100.0) < NEPS)
}

// MARK: - Inter-ring winding cancellation: THE CARRIED RULE
//
// These tests come in PAIRS: one input, both rules, two answers. That
// pairing is the point — it is what makes the carried rule observable
// rather than a comment. Each pair's expectation is derived from first
// principles (winding counts and shoelace sums written out below), never
// read back from the implementation, because these are SHARED
// limitations across the two ports: the differential referee compares
// wrong-with-wrong as equal, so correctness has to be argued here and
// the corpus only gates that Rust and Swift agree. Mirrors the
// same-named Rust tests.

@Test func normNestedCoOrientedRingsAreAHoleUnderEvenOdd() {
    // Two CCW rings, one nested in the other: [0,20]^2 and [5,15]^2.
    //
    // Derivation, even-odd. A ray from inside the inner ring crosses two
    // ring edges — even — so that region is NOT filled: the inner ring
    // is a genuine hole boundary. Between the rings a ray crosses once —
    // odd — filled. Both rings are simple, neither crosses the other,
    // and each is a real filled/unfilled transition, so the fast path
    // returns them bit-identically. Net filled area 400 - 100 = 300 over
    // 2 rings.
    let outer: BoolRing = [(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)]
    let inner: BoolRing = [(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)]
    #expect(setsEqual(normalize([outer, inner], .evenodd), [outer, inner]))
}

@Test func normNestedCoOrientedRingsFillSolidUnderNonZero() {
    // THE SAME INPUT, read as the artist's fill-rule="nonzero" path says
    // to read it. Inter-ring winding cancellation: the 4th degenerate
    // class, unblocked by the carried-rule ruling.
    //
    // Derivation, non-zero. Inside the inner ring the winding is +1
    // (outer, CCW) + 1 (inner, CCW) = 2, non-zero, so that region IS
    // filled. Between the rings it is +1, also filled. Filled-ness is
    // therefore the same on both sides of the inner ring's boundary, so
    // that boundary is not a boundary at all and all its spans drop.
    // What survives is the outer square alone: one CCW ring, shoelace
    // 2A = 800 -> area 400.
    //
    // Under the OLD fixed even-odd reading this input was
    // unrepresentable: a nonzero document was silently turned into a
    // donut. That is the boundary lie the ruling closed.
    let outer: BoolRing = [(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)]
    let inner: BoolRing = [(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)]
    let out = normalize([outer, inner], .nonzero)
    #expect(out.count == 1)
    #expect(ringsEqual(canonical(out[0]), outer))
    #expect(abs(signedAreas(out)[0] - 400.0) < NEPS)
}

@Test func normNestedOpposedRingsAreAHoleUnderBothRules() {
    // The same nesting with the inner ring wound the other way — the way
    // SVG's own examples draw a donut.
    //
    // Derivation. Even-odd ignores orientation, so: a hole. Non-zero
    // agrees for once, because inside the inner ring the winding is
    // +1 + (-1) = 0. The two rules AGREE here, which is precisely why
    // this shape is canonical, and both take the fast path: 2 rings,
    // net 400 - 100 = 300.
    let outer: BoolRing = [(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)]
    let inner: BoolRing = [(5.0, 5.0), (5.0, 15.0), (15.0, 15.0), (15.0, 5.0)]
    #expect(setsEqual(normalize([outer, inner], .evenodd), [outer, inner]))
    #expect(setsEqual(normalize([outer, inner], .nonzero), [outer, inner]))
}

@Test func normOverlappingRingsAreASymmetricDifferenceUnderEvenOdd() {
    // Two CCW squares that genuinely overlap: [0,10]^2 and [5,15]^2,
    // boundaries crossing at (10,5) and (5,10).
    //
    // Derivation, even-odd. A ray from inside the overlap [5,10]^2
    // crosses two edges — even — so the overlap is NOT filled and the
    // set means the symmetric difference. Each ring is simple alone and
    // each is a real transition, so the fast path returns both untouched
    // and the sweep sees the even-odd set it was handed. Net filled area
    // 100 + 100 - 2*25 = 150.
    let a: BoolRing = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    let b: BoolRing = [(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)]
    #expect(setsEqual(normalize([a, b], .evenodd), [a, b]))
}

@Test func normOverlappingRingsAreAUnionUnderNonZero() {
    // The same two squares under the rule a freehand scribble carries.
    //
    // Derivation, non-zero. Inside the overlap the winding is 1 + 1 = 2,
    // so the overlap IS filled and the set means the union — one
    // L-shaped octagon. The two crossings become vertices, and the arcs
    // of each square running through the other have winding 2 on one
    // side and 1 on the other: filled both ways, dropped. Survivors,
    // chained CCW:
    //   (0,0) (10,0) (10,5) (15,5) (15,15) (5,15) (5,10) (0,10)
    // Shoelace 2A = 0 + 50 - 25 + 150 + 150 - 25 + 50 + 0 = 350
    // -> area 175, which is 100 + 100 - 25 as it must be.
    let a: BoolRing = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    let b: BoolRing = [(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)]
    let out = normalize([a, b], .nonzero)
    #expect(out.count == 1)
    #expect(ringsEqual(canonical(out[0]), [
        (0.0, 0.0), (10.0, 0.0), (10.0, 5.0), (15.0, 5.0),
        (15.0, 15.0), (5.0, 15.0), (5.0, 10.0), (0.0, 10.0),
    ]))
    #expect(abs(signedAreas(out)[0] - 175.0) < NEPS)
    #expect(isSimple(out[0]))
}

@Test func normRingsSharingCollinearEdgeStayTwoUnderEvenOdd() {
    // Two CCW squares sharing a full edge: [0,10]x[0,10] and
    // [10,20]x[0,10] — an INTER-ring collinear overlap.
    //
    // Derivation, even-odd. Even-odd decomposes per ring, and alone each
    // is a simple ring that is a real transition. Fast path, both
    // untouched: 2 rings, 100 + 100 = 200.
    let a: BoolRing = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    let b: BoolRing = [(10.0, 0.0), (20.0, 0.0), (20.0, 10.0), (10.0, 10.0)]
    #expect(setsEqual(normalize([a, b], .evenodd), [a, b]))
}

@Test func normRingsSharingCollinearEdgeFuseUnderNonZero() {
    // The same pair read set-wide. Derivation, non-zero: to the left of
    // the shared span x=10 the winding is +1 (first square only); to its
    // right it is +1 (second square only). Filled on both sides, so the
    // span is interior and drops, and the squares fuse into the single
    // rectangle [0,20]x[0,10]. The collinear vertices (10,0) and (10,10)
    // are RETAINED — collapsing them is the Boolean panel's separate
    // opt-in — so the ring has six vertices and area 200 = 100 + 100.
    let a: BoolRing = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    let b: BoolRing = [(10.0, 0.0), (20.0, 0.0), (20.0, 10.0), (10.0, 10.0)]
    let out = normalize([a, b], .nonzero)
    #expect(out.count == 1)
    #expect(ringsEqual(canonical(out[0]), [
        (0.0, 0.0), (10.0, 0.0), (20.0, 0.0),
        (20.0, 10.0), (10.0, 10.0), (0.0, 10.0),
    ]))
    #expect(abs(signedAreas(out)[0] - 200.0) < NEPS)
    #expect(isSimple(out[0]))
}

@Test func normDisjointRingsTakeTheFastPathUntouchedUnderBothRules() {
    // Disjointness is the case where the two rules cannot disagree — no
    // point is enclosed twice — so this pins that carrying the rule did
    // not drag the ordinary case onto the arrangement path under either
    // reading. Bit-identical, in input order.
    let a: BoolRing = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    let b: BoolRing = [(20.0, 0.0), (30.0, 0.0), (30.0, 10.0), (20.0, 10.0)]
    #expect(setsEqual(normalize([a, b], .evenodd), [a, b]))
    #expect(setsEqual(normalize([a, b], .nonzero), [a, b]))
}

@Test func normDegenerateRingDoesNotTakeItsSiblingsWithIt() {
    // One good ring plus one zero-area collinear ring, under both rules.
    // The flat ring encloses nothing under either reading — its winding
    // is 0 everywhere — so it is dropped and the square survives with
    // its region intact.
    //
    // The two rules reach that answer by different routes: even-odd
    // decomposes per ring, so the square never leaves the fast path and
    // comes back BIT-IDENTICAL; non-zero must read the set together, so
    // the flat ring's self-overlap drags the whole set onto the
    // arrangement path and the square is rebuilt from its own spans —
    // same region and vertex sequence, possibly a different traversal
    // start, hence the canonical() comparison.
    let a: BoolRing = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    let flat: BoolRing = [(20.0, 0.0), (25.0, 0.0), (30.0, 0.0)]

    #expect(setsEqual(normalize([a, flat], .evenodd), [a]))

    let nz = normalize([a, flat], .nonzero)
    #expect(nz.count == 1)
    #expect(ringsEqual(canonical(nz[0]), canonical(a)))
    #expect(abs(signedAreas(nz)[0] - 100.0) < NEPS)
}

@Test func normMultiplyWoundRingIsARuleDisagreementToo() {
    // The carried rule is not only about ring-to-ring relations: a
    // SINGLE ring traced twice around the same square winds to 2
    // everywhere inside it.
    //
    // Derivation. Non-zero: 2 != 0, so the square is filled — one ring,
    // area 100. Even-odd: 2 is even, so the interior is NOT filled and
    // the region is empty — zero rings. Same vertices, opposite answers,
    // and no orientation convention can paper over it. This is why the
    // normalizer cannot pick a rule on the caller's behalf.
    let twice: BoolPolygonSet = [[
        (0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0),
        (0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0),
    ]]

    let nz = normalize(twice, .nonzero)
    #expect(nz.count == 1)
    #expect(abs(absArea(nz) - 100.0) < NEPS)

    #expect(normalize(twice, .evenodd).isEmpty)
}

@Test func normZeroAreaCollinearRingIsDropped() {
    // Three collinear vertices enclose nothing, so the non-zero region
    // is empty and the output must be empty too.
    #expect(normalize([[(0.0, 0.0), (5.0, 0.0), (10.0, 0.0)]], .nonzero).isEmpty)
}

@Test func normCwSquarePassesThroughPreservingSignedArea() {
    // A lone CW ring is a well-formed region boundary — winding -1
    // inside, 0 outside — so it takes the fast path and comes back
    // untouched, sign included.
    let cw: BoolRing = [(0.0, 0.0), (0.0, 10.0), (10.0, 10.0), (10.0, 0.0)]
    let out = normalize([cw], .nonzero)
    #expect(out.count == 1)
    #expect(ringsEqual(out[0], cw))
    #expect(abs(signedAreas(out)[0] + 100.0) < NEPS)
}
