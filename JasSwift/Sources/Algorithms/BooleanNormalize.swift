import Foundation

// Ring normalizer: turn an arbitrary (possibly self-intersecting) ring
// into an equivalent set of SIMPLE rings under the non-zero winding fill
// rule. Port of jas_dioxus/src/algorithms/boolean_normalize.rs — keep the
// two in lockstep; the cross-language corpus pins them to the same rings.
//
// SCOPE: ONE RING AT A TIME. Each ring of the input is replaced by the
// simple rings bounding the same filled region CONSIDERED ALONE, under
// the non-zero winding rule — which is what a single self-intersecting
// subpath means (SVG fill-rule="nonzero"). How the resulting rings then
// combine is not this module's business: Boolean.swift defines a
// BoolPolygonSet as a flat list of rings under the EVEN-ODD rule, with
// orientation explicitly outside the contract, and its sweep resolves
// nesting and overlap. A ring-with-hole therefore passes through as two
// rings whatever their orientations, and two overlapping rings pass
// through as two rings; anything else would silently re-interpret the
// operand.
//
// SPEC NOTE for the council: the two rules meeting here — non-zero within
// a ring, even-odd between rings — disagree on exactly the cases one
// would call "inter-ring winding cancellation". Two nested
// same-orientation rings are a hole under even-odd but a solid under
// non-zero; two overlapping same-orientation rings are a symmetric
// difference under even-odd but a union under non-zero. This module
// follows the ratified even-odd contract for the between-rings question
// and does not touch it.
//
// TWO PATHS.
//
// Fast path: if the ring is already simple — no two of its edges meet
// except where consecutive edges share their one vertex — and it
// encloses a non-zero area, it is returned unchanged, orientation
// included. Keeping this a literal pass-through is what lets
// Boolean.swift call the normalizer on every operand without perturbing
// non-degenerate results.
//
// Arrangement path: otherwise the ring's region boundary is rebuilt.
//   1. Split every edge at every meeting with every other edge — proper
//      crossings, T-junctions and collinear-overlap ends — via
//      arrangementSplitPoints. The result is a CONFORMING arrangement.
//   2. Reduce to the set of undirected ATOMIC SPANS. Direction and
//      multiplicity are discarded on purpose: under the non-zero rule a
//      doubly-wound square fills the same region as a singly-wound one,
//      so what matters is whether the region differs ACROSS a span.
//   3. Classify each span by the winding of the ORIGINAL ring just left
//      and just right of it. A span is part of the output boundary iff
//      exactly one side is filled, and is oriented with the filled side
//      on its left. Spans filled the same on both sides are interior or
//      exterior and are dropped — which is how collinear self-overlap
//      and retrograde spans resolve, with no special case for either.
//   4. Chain the survivors into rings by always taking the first
//      outgoing span CLOCKWISE from the reversal of the incoming one.
//      That standard face-tracing rule keeps two lobes meeting at a
//      pinch vertex separate instead of fusing them.
//
// Output rings are simple and pairwise non-overlapping, oriented with
// the filled side on the left: outer boundaries CCW (positive signed
// area), holes CW. Collinear vertices are RETAINED — collapsing them is
// the Boolean panel's separate "Remove Redundant Points" option, which
// defaults to off (transcripts/BOOLEAN.md).
//
// EPSILON POLICY: inherited unchanged from Arrangement.swift for
// everything about WHETHER two edges meet. The one new tolerance is the
// winding-probe offset of step 3: for a span of length L whose midpoint
// is at distance d from the nearest other span, the probe sits at
// 0.25 * min(L, d) perpendicular to the span. Both terms matter — L
// keeps the probe from sliding past the span's own ends, d keeps it from
// crossing a neighbouring boundary — and the 0.25 leaves a
// factor-of-four margin. Geometry thinner than a quarter of the nearest
// feature is not resolved, but nothing legitimately thin is DROPPED,
// because the probe is sized relative to the local feature size rather
// than to a fixed absolute epsilon.

/// Normalize a polygon set: replace each ring by the simple rings that
/// bound the same region considered alone, under the non-zero winding
/// rule. Ring-to-ring relations are left to Boolean.swift's even-odd
/// sweep.
public func normalize(_ input: BoolPolygonSet) -> BoolPolygonSet {
    var out: BoolPolygonSet = []
    for ring in input {
        out.append(contentsOf: normalizeRing(ring))
    }
    return out
}

/// Normalize a single ring. Returns 0, 1, or more simple rings.
func normalizeRing(_ ring: BoolRing) -> [BoolRing] {
    let cleaned = dedupConsecutive(ring)
    if cleaned.count < 3 { return [] }
    // The two workers take a whole set so their geometry reads
    // naturally; here the set is always this one ring.
    let one: BoolPolygonSet = [cleaned]
    if isAlreadyNormalized(one) { return one }
    return rebuildFromArrangement(one)
}

// MARK: - Vertex cleanup

/// Remove consecutive duplicate vertices, including the wrap-around
/// duplicate if the ring closes back onto itself.
func dedupConsecutive(_ ring: BoolRing) -> BoolRing {
    var out: BoolRing = []
    out.reserveCapacity(ring.count)
    for p in ring {
        if out.last.map({ $0 == p }) != true {
            out.append(p)
        }
    }
    while out.count >= 2 && out.first! == out.last! {
        out.removeLast()
    }
    return out
}

// MARK: - Fast path

/// One directed edge of one ring, tagged with where it came from so the
/// "legitimately adjacent" exemption can be checked.
private struct TaggedEdge {
    let a: (Double, Double)
    let b: (Double, Double)
    let ring: Int
    let edge: Int
    let ringLen: Int
}

private func taggedEdges(_ rings: BoolPolygonSet) -> [TaggedEdge] {
    var out: [TaggedEdge] = []
    for (ri, ring) in rings.enumerated() {
        let n = ring.count
        for i in 0..<n {
            out.append(TaggedEdge(
                a: ring[i], b: ring[(i + 1) % n],
                ring: ri, edge: i, ringLen: n
            ))
        }
    }
    return out
}

/// True if `rings` already satisfies the normalizer's output contract, so
/// it can be returned untouched. Called with a one-ring set.
///
///   1. No edge meets another except where two consecutive edges of the
///      same ring share their one common vertex. Any other reported
///      meeting is a crossing, a T-junction, a pinch or a collinear
///      overlap — all of which need the arrangement.
///   2. The boundary really is a boundary: immediately inside the ring
///      and immediately outside it, the winding must differ in
///      filled-ness. True for any simple ring of either orientation;
///      false for a degenerate zero-area ring.
func isAlreadyNormalized(_ rings: BoolPolygonSet) -> Bool {
    let edges = taggedEdges(rings)
    for e in edges {
        // A degenerate edge survived dedup only if two vertices differ by
        // less than ARR_VERT_EPS without being bit-equal. Hand it to the
        // arrangement rather than reasoning about it here.
        if arrangementDist(e.a, e.b) <= ARR_VERT_EPS { return false }
    }
    for i in 0..<edges.count {
        for j in (i + 1)..<edges.count {
            let p = edges[i]
            let q = edges[j]
            let pts = arrangementSplitPoints(p.a, p.b, q.a, q.b)
            if pts.isEmpty { continue }
            let sameRing = p.ring == q.ring
            let n = p.ringLen
            let consecutive = sameRing
                && ((q.edge + 1) % n == p.edge || (p.edge + 1) % n == q.edge)
            // Consecutive edges legitimately meet at exactly one point:
            // their shared vertex. Anything else — two points (a
            // collinear overlap), or a single point that is not an
            // endpoint of both — is a degeneracy.
            let sharedVertexOnly = consecutive
                && pts.count == 1
                && (pts[0].1 == 0.0 || pts[0].1 == 1.0)
                && (pts[0].2 == 0.0 || pts[0].2 == 1.0)
            if !sharedVertexOnly { return false }
        }
    }
    for ring in rings {
        let inside = sampleInsideSimpleRing(ring)
        let wAll = windingOfSet(rings, inside)
        let wSelf = windingNumber(ring, inside)
        let wWithout = wAll - wSelf
        if (wAll != 0) == (wWithout != 0) { return false }
    }
    return true
}

// MARK: - Arrangement path

/// Rebuild the boundary of the non-zero-winding region of `rings` from a
/// conforming arrangement of their edges. Called with a one-ring set.
func rebuildFromArrangement(_ rings: BoolPolygonSet) -> BoolPolygonSet {
    // ----- 1. Conforming arrangement -----
    var segments: [((Double, Double), (Double, Double))] = []
    for ring in rings {
        let n = ring.count
        for i in 0..<n {
            let a = ring[i]
            let b = ring[(i + 1) % n]
            if arrangementDist(a, b) > ARR_VERT_EPS {
                segments.append((a, b))
            }
        }
    }
    if segments.isEmpty { return [] }

    var vertPts: [(Double, Double)] = []
    var segParams: [[(Double, Int)]] =
        Array(repeating: [], count: segments.count)
    for (si, seg) in segments.enumerated() {
        let va = arrangementAddOrFindVertex(&vertPts, seg.0)
        let vb = arrangementAddOrFindVertex(&vertPts, seg.1)
        segParams[si].append((0.0, va))
        segParams[si].append((1.0, vb))
    }
    for i in 0..<segments.count {
        for j in (i + 1)..<segments.count {
            let (a1, a2) = segments[i]
            let (b1, b2) = segments[j]
            for (p, s, t) in arrangementSplitPoints(a1, a2, b1, b2) {
                let v = arrangementAddOrFindVertex(&vertPts, p)
                segParams[i].append((s, v))
                segParams[j].append((t, v))
            }
        }
    }

    // ----- 2. Undirected atomic spans -----
    // Multiplicity and direction are dropped on purpose. Sorting the
    // spans also fixes the output ring order, so the Rust port — which
    // iterates a BTreeSet of the same pairs — agrees vertex for vertex.
    var spanSet: Set<UInt64> = []
    var spans: [(Int, Int)] = []
    for si in 0..<segParams.count {
        segParams[si].sort { $0.0 < $1.0 }
        var chain: [Int] = []
        for (_, v) in segParams[si] {
            if chain.last != v { chain.append(v) }
        }
        if chain.count >= 2 {
            for k in 0..<(chain.count - 1) {
                let u = chain[k]
                let v = chain[k + 1]
                if u == v { continue }
                let lo = min(u, v)
                let hi = max(u, v)
                let key = (UInt64(lo) << 32) | UInt64(hi)
                if spanSet.insert(key).inserted {
                    spans.append((lo, hi))
                }
            }
        }
    }
    if spans.isEmpty { return [] }
    spans.sort { a, b in a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }

    // ----- 3. Winding classification -----
    // Kept spans, each oriented so the filled region is on its left.
    var kept: [(Int, Int)] = []
    for (si, span) in spans.enumerated() {
        let (u, v) = span
        let (ax, ay) = vertPts[u]
        let (bx, by) = vertPts[v]
        let mx = (ax + bx) / 2.0
        let my = (ay + by) / 2.0
        let dx = bx - ax
        let dy = by - ay
        let len = (dx * dx + dy * dy).squareRoot()
        if len <= ARR_VERT_EPS { continue }
        // Probe offset: a quarter of the smaller of this span's length
        // and its midpoint's distance to the nearest other span.
        var nearest = Double.infinity
        for (sj, other) in spans.enumerated() {
            if sj == si { continue }
            let d = pointSegmentDistance(
                (mx, my), vertPts[other.0], vertPts[other.1])
            if d < nearest { nearest = d }
        }
        let limit = (nearest.isFinite && nearest > 0.0 && nearest < len)
            ? nearest : len
        let offset = 0.25 * limit
        // Unit left normal of u -> v.
        let nx = -dy / len
        let ny = dx / len
        let wLeft = windingOfSet(
            rings, (mx + nx * offset, my + ny * offset))
        let wRight = windingOfSet(
            rings, (mx - nx * offset, my - ny * offset))
        let leftFilled = wLeft != 0
        let rightFilled = wRight != 0
        if leftFilled == rightFilled { continue }
        kept.append(leftFilled ? (u, v) : (v, u))
    }
    if kept.isEmpty { return [] }

    // ----- 4. Chain into rings -----
    func angleOf(_ ki: Int) -> Double {
        let (u, v) = kept[ki]
        return atan2(vertPts[v].1 - vertPts[u].1, vertPts[v].0 - vertPts[u].0)
    }
    var outgoing: [[Int]] = Array(repeating: [], count: vertPts.count)
    for (ki, k) in kept.enumerated() {
        outgoing[k.0].append(ki)
    }
    for vi in 0..<outgoing.count {
        // Tie-break on span index, which is not decoration. Rust's
        // counterpart uses `sort_by`, which is STABLE, so equal angles
        // keep insertion order — and insertion above is by ascending
        // span index. Swift's `sort` is NOT stable, so without this the
        // two ports could order a tie differently and emit differently
        // rotated rings from the same input. A conforming arrangement
        // should never present a tie (two kept spans leaving one vertex
        // in the same direction would be an unsplit collinear overlap),
        // but "should never" is the sort of guarantee worth writing down
        // rather than depending on silently.
        outgoing[vi].sort {
            let (a, b) = (angleOf($0), angleOf($1))
            return a == b ? $0 < $1 : a < b
        }
    }

    var used = Array(repeating: false, count: kept.count)
    var out: BoolPolygonSet = []
    for start in 0..<kept.count {
        if used[start] { continue }
        var ring: BoolRing = []
        var e = start
        while true {
            used[e] = true
            ring.append(vertPts[kept[e].0])
            let v = kept[e].1
            // Angle looking back along the edge we just travelled.
            let (ox, oy) = vertPts[kept[e].0]
            let (vx, vy) = vertPts[v]
            let back = atan2(oy - vy, ox - vx)
            let list = outgoing[v]
            if list.isEmpty { break }
            // First span clockwise from `back`: the largest angle
            // strictly below it, wrapping to the largest overall.
            var pick = list[list.count - 1]
            for cand in list {
                if angleOf(cand) < back { pick = cand } else { break }
            }
            if pick == start { break }
            if used[pick] {
                // Defensive: a well-formed region boundary never
                // revisits a span, so this cannot fire for valid input.
                break
            }
            e = pick
        }
        let closed = dedupConsecutive(ring)
        if closed.count >= 3 { out.append(closed) }
    }
    return out
}

// MARK: - Winding and sampling

/// Winding number of `ring` around `point`: signed count of ring edges
/// crossed by a horizontal ray in the +x direction, upward crossings
/// counting +1 and downward ones -1. The half-open classification avoids
/// double-counting when the ray passes exactly through a vertex.
func windingNumber(_ ring: BoolRing, _ point: (Double, Double)) -> Int {
    let n = ring.count
    if n < 3 { return 0 }
    let (px, py) = point
    var w = 0
    for i in 0..<n {
        let (x1, y1) = ring[i]
        let (x2, y2) = ring[(i + 1) % n]
        let upward = y1 <= py && y2 > py
        let downward = y2 <= py && y1 > py
        if !upward && !downward { continue }
        let t = (py - y1) / (y2 - y1)
        let xCross = x1 + t * (x2 - x1)
        if xCross > px {
            if upward { w += 1 } else { w -= 1 }
        }
    }
    return w
}

/// Total winding of a whole polygon set: the sum over its rings.
func windingOfSet(_ rings: BoolPolygonSet, _ point: (Double, Double)) -> Int {
    rings.reduce(0) { $0 + windingNumber($1, point) }
}

/// Distance from `p` to the segment a-b (clamped at the ends).
func pointSegmentDistance(
    _ p: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)
) -> Double {
    let dx = b.0 - a.0
    let dy = b.1 - a.1
    let len2 = dx * dx + dy * dy
    if len2 <= 0.0 { return arrangementDist(p, a) }
    var t = ((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len2
    if t < 0.0 { t = 0.0 } else if t > 1.0 { t = 1.0 }
    return arrangementDist(p, (a.0 + t * dx, a.1 + t * dy))
}

/// Pick a point guaranteed to be strictly inside a simple ring: offset
/// the midpoint of the first edge perpendicular to it, on whichever side
/// has non-zero winding in the ring itself.
func sampleInsideSimpleRing(_ ring: BoolRing) -> (Double, Double) {
    precondition(ring.count >= 3)
    let (x0, y0) = ring[0]
    let (x1, y1) = ring[1]
    let mx = (x0 + x1) / 2.0
    let my = (y0 + y1) / 2.0
    let dx = x1 - x0
    let dy = y1 - y0
    let len = (dx * dx + dy * dy).squareRoot()
    if len == 0.0 {
        let (x2, y2) = ring[2]
        return ((x0 + x1 + x2) / 3.0, (y0 + y1 + y2) / 3.0)
    }
    let nx = -dy / len
    let ny = dx / len
    let offset = len * 1e-4
    let left = (mx + nx * offset, my + ny * offset)
    let right = (mx - nx * offset, my - ny * offset)
    return windingNumber(ring, left) != 0 ? left : right
}
