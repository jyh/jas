import Foundation

// Region metrics for the boolean conformance harness -- the *measuring
// instruments*, not the thing measured.
//
// Every `boolean` and `boolean_normalize` golden is expressed in these
// functions: a vector pins `area`, `ring_count`, `all_rings_simple` and a
// list of inside/outside sample answers, and all of those come from here.
// They were hand-copied -- once into ToolsAlgorithm/AlgorithmRoundtrip.swift
// and once into Tests/Algorithms/BooleanTests.swift -- with nothing
// comparing the copies, and mirrored again by hand from Rust. A drift in a
// measuring instrument silently rewrites what the boolean families appear
// to prove, so this file is the single Swift copy and the
// `polygon_metrics` corpus family pins its outputs against
// independently-derived expectations. Its Rust mirror is
// jas_dioxus/src/algorithms/polygon_metrics.rs.
//
// FILL RULE. These are even-odd metrics. transcripts/BOOLEAN.md clause 1
// fixes the standing convention that a bare polygon set crossing a
// function boundary inside the algorithm layer means even-odd, already
// canonical, and clause 4 makes every generated boolean result declare
// even-odd. Both things this file is pointed at -- a boolean result and a
// normalize output -- are therefore read under even-odd.

/// Shoelace signed area of one ring. The sign carries the winding
/// direction; the magnitude is the enclosed area only when the ring does
/// not cross itself (a self-crossing ring's lobes cancel).
public func ringSignedArea(_ ring: BoolRing) -> Double {
    guard ring.count >= 3 else { return 0 }
    var sum = 0.0
    let n = ring.count
    for i in 0..<n {
        let (x1, y1) = ring[i]
        let (x2, y2) = ring[(i + 1) % n]
        sum += x1 * y2 - x2 * y1
    }
    return sum * 0.5
}

/// Standard ray-casting point-in-ring test, treating the ring as closed
/// (last vertex joins the first). Points exactly on the boundary are
/// unspecified; callers pick sample points away from edges.
public func pointInRing(_ ring: BoolRing, _ pt: (Double, Double)) -> Bool {
    let (px, py) = pt
    let n = ring.count
    guard n >= 3 else { return false }
    var inside = false
    var j = n - 1
    for i in 0..<n {
        let (xi, yi) = ring[i]
        let (xj, yj) = ring[j]
        if ((yi > py) != (yj > py)) && (px < (xj - xi) * (py - yi) / (yj - yi) + xi) {
            inside.toggle()
        }
        j = i
    }
    return inside
}

/// Even-odd "is this point in the region" -- true iff `pt` lies inside an
/// odd number of rings.
public func pointInPolygonSet(_ ps: BoolPolygonSet, _ pt: (Double, Double)) -> Bool {
    var count = 0
    for ring in ps where pointInRing(ring, pt) { count += 1 }
    return count % 2 == 1
}

/// Every directed edge of every ring. Rings with fewer than three
/// vertices bound no region and are skipped.
private func polygonEdges(_ ps: BoolPolygonSet) -> [((Double, Double), (Double, Double))] {
    var out: [((Double, Double), (Double, Double))] = []
    for ring in ps {
        let n = ring.count
        if n < 3 { continue }
        for i in 0..<n { out.append((ring[i], ring[(i + 1) % n])) }
    }
    return out
}

/// The y at which two edges cross, if they do. Liberal on purpose:
/// endpoint touches count, and only exactly-parallel pairs are rejected.
/// The value is used solely to subdivide the scanline bands in
/// polygonSetArea, and an extra band boundary cannot change that
/// integral -- a missing one can.
private func edgeCrossingY(_ a: ((Double, Double), (Double, Double)),
                           _ b: ((Double, Double), (Double, Double))) -> Double? {
    let ((ax1, ay1), (ax2, ay2)) = a
    let ((bx1, by1), (bx2, by2)) = b
    let dxa = ax2 - ax1, dya = ay2 - ay1
    let dxb = bx2 - bx1, dyb = by2 - by1
    let denom = dxa * dyb - dya * dxb
    if denom == 0 { return nil }
    let dxab = ax1 - bx1, dyab = ay1 - by1
    let s = (dxb * dyab - dyb * dxab) / denom
    let t = (dxa * dyab - dya * dxab) / denom
    if s < 0 || s > 1 || t < 0 || t > 1 { return nil }
    return ay1 + s * dya
}

/// Total width of the odd-parity part of the horizontal line at `y`.
///
/// Every edge strictly straddling `y` contributes one crossing x. Sorted,
/// those crossings alternate outside/inside/outside/..., so the
/// odd-parity measure is the sum of the 1st-to-2nd, 3rd-to-4th, ... gaps.
/// Horizontal edges straddle nothing and drop out, which is what the
/// even-odd rule wants.
private func oddParityWidth(_ edges: [((Double, Double), (Double, Double))],
                            _ y: Double) -> Double {
    var xs: [Double] = []
    for ((x1, y1), (x2, y2)) in edges {
        let lo = min(y1, y2), hi = max(y1, y2)
        if y > lo && y < hi {
            xs.append(x1 + (y - y1) * (x2 - x1) / (y2 - y1))
        }
    }
    xs.sort()
    var total = 0.0
    var i = 0
    while i + 1 < xs.count {
        total += xs[i + 1] - xs[i]
        i += 2
    }
    return total
}

/// Even-odd net area of a ring set -- the true measure of the region, for
/// ANY ring set, including ones whose rings partially overlap each other
/// or cross themselves.
///
/// This replaces a nesting-depth heuristic that signed each ring by how
/// many other rings contained its FIRST VERTEX (even = plus, odd = minus)
/// and summed |shoelace|. That is right only for a canonical set --
/// pairwise disjoint or strictly nested simple rings -- and the two ways
/// it was wrong are exactly the two the boolean corpus most needs to see:
/// two partially overlapping rings both score depth 0, so it reported
/// A1 + A2 instead of A1 + A2 - 2*overlap, and because the probe is the
/// first vertex, the answer moved when a ring was merely LISTED from a
/// different vertex. Since isRingSimple is intra-ring only, the corpus
/// then had no instrument that could see inter-ring partial overlap at
/// all, and a normalizer regression leaving such an overlap in its output
/// could satisfy every golden.
///
/// Method: sweep in y. Cut the plane into bands at every vertex y and
/// every edge-edge crossing y. Inside one open band no edge starts, ends
/// or changes places with another, so oddParityWidth is LINEAR in y
/// there; the mean of a linear function over an interval is the average
/// of its values at the interval's quarter and three-quarter points, so
/// h * (w(1/4) + w(3/4)) / 2 is the band's exact contribution -- and both
/// samples sit strictly inside the band, which keeps every vertex off the
/// scanline. Only arithmetic is used: no arrangement, no planar, no
/// boolean, so the instrument does not lean on anything it measures.
///
/// Cost is O(E^2) for the crossing scan plus O(B*E) for the bands, where
/// B <= 2V + (number of crossings). The corpus's ring sets are tens of
/// vertices.
public func polygonSetArea(_ ps: BoolPolygonSet) -> Double {
    let edges = polygonEdges(ps)
    if edges.isEmpty { return 0 }
    var ys: [Double] = []
    ys.reserveCapacity(edges.count * 2)
    for (p, q) in edges {
        ys.append(p.1)
        ys.append(q.1)
    }
    for i in 0..<edges.count {
        for j in (i + 1)..<edges.count {
            if let y = edgeCrossingY(edges[i], edges[j]) { ys.append(y) }
        }
    }
    ys.sort()
    var bands: [Double] = []
    for y in ys where bands.last != y { bands.append(y) }
    var total = 0.0
    for k in 0..<max(bands.count - 1, 0) {
        let y0 = bands[k], y1 = bands[k + 1]
        let h = y1 - y0
        if !(h > 0) { continue }
        let a = oddParityWidth(edges, y0 + h * 0.25)
        let b = oddParityWidth(edges, y0 + h * 0.75)
        total += h * (a + b) * 0.5
    }
    return total
}

/// Check that a ring is simple: no two of its edges meet except where
/// consecutive edges share their one common vertex.
///
/// Deliberately the full arrangement predicate rather than a
/// proper-crossing test. A proper-crossing test reports true for a ring
/// carrying a T-junction (a vertex sitting in another edge's interior) or
/// a collinear self-overlap (an edge doubling back along itself), because
/// neither is a strict interior crossing -- so the corpus's
/// all_rings_simple flag used to stay green on exactly the degeneracies
/// the normalizer exists to remove.
///
/// INTRA-ring only: it says nothing about one ring overlapping another.
public func isRingSimple(_ ring: BoolRing) -> Bool {
    let n = ring.count
    guard n >= 3 else { return true }
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

public func allRingsSimple(_ ps: BoolPolygonSet) -> Bool {
    ps.allSatisfy { isRingSimple($0) }
}
