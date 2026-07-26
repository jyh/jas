import Foundation

// Ring normalizer: turn an arbitrary (possibly self-intersecting)
// polygon set into the CANONICAL set of simple rings bounding the same
// region, reading the input under the fill rule it CARRIES. Port of
// jas_dioxus/src/algorithms/boolean_normalize.rs — keep the two in
// lockstep; the cross-language corpus pins them to the same rings.
//
// INPUT CONTRACT: THE CARRIED RULE (JYH-ratified 2026-07-26).
// normalize takes rings AND the BoolFillRule that reads them. It does
// not assume one, and there is no rule-less entry point, because the
// two rules denote genuinely different regions and only the caller —
// who knows whether these rings came from a fill-rule="nonzero" path, a
// fill-rule="evenodd" path or a machine-made boolean result — can say
// which was meant. Boolean.swift's header states the full law; this
// file implements the half that consumes it.
//
// The rule applies to the WHOLE SET AT ONCE, exactly as SVG and PDF
// define it: insideness comes from the crossings/windings of every ring
// together, not ring by ring. Concretely:
//
//   nonzero — filled iff the winding summed over all rings is non-zero.
//     Two nested same-orientation rings are a SOLID; two overlapping
//     same-orientation rings are their UNION; a counter-wound inner
//     ring is a hole. This is inter-ring winding cancellation, now
//     implemented rather than deferred: with the rule carried it is no
//     longer us choosing a semantics, it is doing what the artist's
//     path says.
//   evenodd — filled iff a ray crosses the rings an odd number of
//     times. Two nested rings are a HOLE whatever their orientations;
//     two overlapping rings are their SYMMETRIC DIFFERENCE. Because
//     even-odd parity is additive across rings (the parity of the whole
//     is the XOR of the parts), resolving each ring alone and
//     concatenating IS the set-wide answer — which is why the even-odd
//     path here is still a per-ring loop, and why simple rings pass
//     through untouched however they nest.
//
// OUTPUT CONTRACT: canonical means EVEN-ODD-CORRECT. The returned rings
// are simple and denote the input's region read under EVEN-ODD,
// whatever rule came in. That is what lets the sweep, the renderer and
// the corpus all read the output as even-odd without lying about the
// input, and what Controller.applyDestructiveBoolean relies on when it
// stamps .evenodd on a multi-ring result. Two shades: from a nonzero
// input the whole set is rebuilt, so the output is additionally
// pairwise non-overlapping and its two readings coincide; from an
// evenodd input, rings that are already even-odd-correct are returned
// as given, so two of them may still overlap (their even-odd reading,
// the symmetric difference, is the point) — do not re-read such an
// output as non-zero.
//
// TWO PATHS.
//
// Fast path: if the input is already canonical UNDER ITS CARRIED RULE —
// no two edges meet except where consecutive edges of one ring share
// their vertex, and every ring really bounds a filled/unfilled
// transition when read under that rule — it is returned unchanged,
// orientation included. Keeping this a literal pass-through is what
// lets Boolean.swift call the normalizer on every operand without
// perturbing non-degenerate results. The rule enters even here: two
// nested same-orientation rings are canonical under evenodd (a hole)
// and are NOT canonical under nonzero (a solid), and
// isAlreadyNormalized separates the cases by asking whether removing a
// ring's own contribution changes filled-ness.
//
// Arrangement path: otherwise the region's boundary is rebuilt.
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

/// Is a point with winding number `w` inside the region, under `rule`?
/// The whole difference between the two rules, in one function.
func boolFilled(_ w: Int, _ rule: BoolFillRule) -> Bool {
    switch rule {
    case .nonzero: return w != 0
    case .evenodd: return w % 2 != 0
    }
}

/// Normalize a polygon set read under `rule`: the canonical simple
/// rings bounding the same region.
///
/// `rule` is mandatory by design — see the carried-rule contract in
/// this file's header. Callers holding a document element pass its
/// `fillRule`; callers holding a set this package produced pass
/// `.evenodd`.
public func normalize(_ input: BoolPolygonSet, _ rule: BoolFillRule) -> BoolPolygonSet {
    switch rule {
    // Even-odd parity is additive across rings — the parity of the
    // whole set is the XOR of the per-ring parities — so resolving each
    // ring alone and concatenating IS the set-wide answer, at a
    // fraction of the cost (the arrangement is O(E^2) in the edges
    // handed to it, so n small sets beat one big one).
    case .evenodd:
        var out: BoolPolygonSet = []
        for ring in input {
            out.append(contentsOf: normalizeRing(ring, rule))
        }
        return out
    // Non-zero winding does NOT decompose: the winding at a point is
    // the sum over every ring, so nesting and overlap between rings
    // change the answer and the whole set must be resolved together.
    // This is inter-ring winding cancellation.
    case .nonzero:
        let cleaned: BoolPolygonSet =
            input.map { dedupConsecutive($0) }.filter { $0.count >= 3 }
        if cleaned.isEmpty { return [] }
        if isAlreadyNormalized(cleaned, rule) { return cleaned }
        return rebuildFromArrangement(cleaned, rule)
    }
}

/// Normalize a single ring. Returns 0, 1, or more simple rings.
func normalizeRing(_ ring: BoolRing, _ rule: BoolFillRule) -> [BoolRing] {
    let cleaned = dedupConsecutive(ring)
    if cleaned.count < 3 { return [] }
    // The two workers take a whole set so their geometry reads
    // naturally; here the set is always this one ring.
    let one: BoolPolygonSet = [cleaned]
    if isAlreadyNormalized(one, rule) { return one }
    return rebuildFromArrangement(one, rule)
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
///   2. Every ring really is a boundary UNDER `rule`: at a point just
///      inside the ring, the filled-ness of the whole set must differ
///      from what it would be with this ring's own winding removed.
///      False for a degenerate zero-area ring.
///
///      This is the check that carries the rule between rings. Two
///      nested counter-wound rings (the SVG way to draw a donut) pass
///      under BOTH rules. Two nested same-orientation rings pass under
///      .evenodd — inside the inner ring the total winding is 2 (even,
///      unfilled) against 1 (odd, filled) without it, so the hole is
///      genuine — and FAIL under .nonzero, where 2 and 1 are both
///      non-zero so the inner ring bounds nothing and the arrangement
///      must dissolve it.
func isAlreadyNormalized(_ rings: BoolPolygonSet, _ rule: BoolFillRule) -> Bool {
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
        if boolFilled(wAll, rule) == boolFilled(wWithout, rule) { return false }
    }
    return true
}

// MARK: - Arrangement path

/// Rebuild the boundary of the region `rings` denotes UNDER `rule` from
/// a conforming arrangement of their edges. Called with a one-ring set
/// on the even-odd path and with the whole set on the non-zero path.
func rebuildFromArrangement(_ rings: BoolPolygonSet, _ rule: BoolFillRule) -> BoolPolygonSet {
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
        // Tie-break on the vertex index. Rust's `sort_by` is STABLE, so equal
            // params keep insertion order there; Swift's `sort` is not, and a tie
            // here is genuinely reachable — snap_param forces params to exactly
            // 0.0/1.0, so exact equality is routine, and two ties carrying
            // DIFFERENT vertex indices occur once |segment|*PARAM_EPS exceeds
            // VERT_EPS. Different chain order yields different atomic spans and
            // differently-built rings, so the order is pinned rather than left to
            // the sort's discretion (mirrors the outgoing-span tie-break below).
            segParams[si].sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
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
        let leftFilled = boolFilled(wLeft, rule)
        let rightFilled = boolFilled(wRight, rule)
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
