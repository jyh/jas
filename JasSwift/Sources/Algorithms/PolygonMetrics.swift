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
// to prove, so this file is the single Swift copy. Its Rust mirror is
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

/// Area of a region, as the harness has computed it up to now: sum
/// |shoelace| over the rings, signing each ring by its NESTING DEPTH --
/// the number of other rings that contain the ring's FIRST VERTEX, even
/// meaning plus and odd meaning minus.
///
/// Moved here verbatim from ToolsAlgorithm/AlgorithmRoundtrip.swift and
/// Tests/Algorithms/BooleanTests.swift so that there is one Swift copy;
/// behaviour is unchanged by the move. The depth heuristic is correct
/// only for a canonical set (pairwise disjoint or strictly nested simple
/// rings) and is replaced in the commit that follows.
public func polygonSetArea(_ ps: BoolPolygonSet) -> Double {
    var total = 0.0
    for (i, ring) in ps.enumerated() {
        let a = abs(ringSignedArea(ring))
        var depth = 0
        if let pt = ring.first {
            for (j, other) in ps.enumerated() where i != j {
                if pointInRing(other, pt) { depth += 1 }
            }
        }
        total += depth % 2 == 0 ? a : -a
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
