import Foundation

// Shared arrangement primitives: the segment-splitting predicate and the
// epsilon policy that Planar.swift and BooleanNormalize.swift both build
// on. Port of jas_dioxus/src/algorithms/arrangement.rs — keep the two in
// lockstep; the cross-language corpus pins them to the same answers.
//
// Why one module. Both the planar-graph extractor and the ring
// normalizer need the same first stage: take a bag of line segments and
// split them until the result is a CONFORMING arrangement --
//
//   1. no segment's interior contains another segment's endpoint (no
//      T-junctions left unsplit), and
//   2. no two segments overlap over a span of positive length (no
//      collinear overlap left unsplit).
//
// Both properties are prerequisites for any winding argument: a
// T-junction that is not split hides a vertex from the topology, and an
// unsplit collinear overlap hides the fact that two boundaries coincide.
//
// Epsilon policy — deliberately unchanged from the pre-existing
// convention in these two modules, so that fixing the degenerate cases
// does not also shift the tolerance behaviour of the non-degenerate
// ones:
//
//   - ARR_VERT_EPS (1e-9, absolute, input units): two points are the
//     same vertex if closer than this; also the zero-length threshold.
//   - ARR_PARAM_EPS (1e-9, on the normalized segment parameter): a
//     parameter within this of 0 or 1 IS 0 or 1, i.e. the meeting is at
//     an endpoint rather than in the interior.
//   - ARR_DENOM_EPS (1e-12, on the raw 2x2 determinant): below this the
//     pair is treated as parallel.
//   - ARR_COLLINEAR_EPS (1e-9, absolute perpendicular distance): a
//     parallel pair is collinear if both of one segment's endpoints are
//     within this of the other's infinite line.
//
// The one deliberate change of BEHAVIOUR is inclusivity: the old
// predicate demanded a strictly interior crossing on both segments
// (0 < s < 1 and 0 < t < 1), which is exactly what made T-junctions
// invisible. `arrangementSplitPoints` accepts the closed range on both
// parameters and additionally reports collinear overlaps.

/// Vertex coincidence and zero-length tolerance, in input units.
let ARR_VERT_EPS: Double = 1e-9

/// Parameter-band epsilon: |s| <= ARR_PARAM_EPS means "at the start".
let ARR_PARAM_EPS: Double = 1e-9

/// Determinant tolerance for parallel-pair detection.
let ARR_DENOM_EPS: Double = 1e-12

/// Perpendicular-distance tolerance for collinearity of a parallel pair.
let ARR_COLLINEAR_EPS: Double = 1e-9

/// Euclidean distance.
func arrangementDist(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
    let dx = a.0 - b.0
    let dy = a.1 - b.1
    return (dx * dx + dy * dy).squareRoot()
}

/// Linear-search vertex dedup: return the index of an existing vertex
/// within `ARR_VERT_EPS` of `pt`, or append `pt` and return its index.
/// Public so the AlgorithmRoundtrip corpus tool can gate it directly:
/// it is the other half of the arrangement primitive, and its
/// first-match-wins order dependence is invisible through its callers.
public func arrangementAddOrFindVertex(
    _ verts: inout [(Double, Double)], _ pt: (Double, Double)
) -> Int {
    for (i, v) in verts.enumerated() {
        if arrangementDist(v, pt) < ARR_VERT_EPS {
            return i
        }
    }
    verts.append(pt)
    return verts.count - 1
}

private func arrClamp01(_ v: Double) -> Double {
    if v < 0.0 { return 0.0 }
    if v > 1.0 { return 1.0 }
    return v
}

/// Perpendicular distance from `p` to the infinite line through a1, a2.
private func arrLineDistance(
    _ a1: (Double, Double), _ a2: (Double, Double), _ p: (Double, Double)
) -> Double {
    let dx = a2.0 - a1.0
    let dy = a2.1 - a1.1
    let len = (dx * dx + dy * dy).squareRoot()
    if len <= ARR_VERT_EPS { return arrangementDist(a1, p) }
    return abs((p.0 - a1.0) * dy - (p.1 - a1.1) * dx) / len
}

/// Parameter of `p` projected onto segment a1-a2, clamped to [0,1].
private func arrProjectParam(
    _ a1: (Double, Double), _ a2: (Double, Double), _ p: (Double, Double)
) -> Double {
    let dx = a2.0 - a1.0
    let dy = a2.1 - a1.1
    let len2 = dx * dx + dy * dy
    if len2 <= 0.0 { return 0.0 }
    return arrClamp01(((p.0 - a1.0) * dx + (p.1 - a1.1) * dy) / len2)
}

/// Snap a parameter within ARR_PARAM_EPS of an endpoint onto it exactly.
private func arrSnapParam(_ v: Double) -> Double {
    if v <= ARR_PARAM_EPS { return 0.0 }
    if v >= 1.0 - ARR_PARAM_EPS { return 1.0 }
    return v
}

/// Every arrangement-relevant meeting point of segments a1-a2 and b1-b2,
/// as (point, s, t) where `s` is the point's parameter on `a` and `t` its
/// parameter on `b`.
///
/// Reports, in one predicate: proper interior crossings; T-junctions (one
/// parameter at an endpoint, the other interior — the cases the old
/// strict predicate dropped); endpoint coincidences; and, for a parallel
/// collinear pair whose spans overlap, the two ends of the overlap (one
/// point if the overlap degenerates to a single touch).
///
/// Returned points are taken from an existing endpoint whenever one of
/// the parameters sits at an endpoint, so a T-junction vertex lands
/// exactly on the vertex that caused it rather than on a rounded
/// re-computation of it. That exactness is what lets the caller's vertex
/// dedup fuse the two into one.
/// Public so the AlgorithmRoundtrip corpus tool can use the same
/// predicate for its ring-simplicity check.
public func arrangementSplitPoints(
    _ a1: (Double, Double), _ a2: (Double, Double),
    _ b1: (Double, Double), _ b2: (Double, Double)
) -> [((Double, Double), Double, Double)] {
    let dxA = a2.0 - a1.0
    let dyA = a2.1 - a1.1
    let dxB = b2.0 - b1.0
    let dyB = b2.1 - b1.1
    let denom = dxA * dyB - dyA * dxB

    if abs(denom) > ARR_DENOM_EPS {
        let dxAB = a1.0 - b1.0
        let dyAB = a1.1 - b1.1
        var s = (dxB * dyAB - dyB * dxAB) / denom
        var t = (dxA * dyAB - dyA * dxAB) / denom
        if s < -ARR_PARAM_EPS || s > 1.0 + ARR_PARAM_EPS
            || t < -ARR_PARAM_EPS || t > 1.0 + ARR_PARAM_EPS
        {
            return []
        }
        s = arrSnapParam(s)
        t = arrSnapParam(t)
        let p: (Double, Double)
        if s == 0.0 {
            p = a1
        } else if s == 1.0 {
            p = a2
        } else if t == 0.0 {
            p = b1
        } else if t == 1.0 {
            p = b2
        } else {
            p = (a1.0 + s * dxA, a1.1 + s * dyA)
        }
        return [(p, s, t)]
    }

    // Parallel. Only collinear pairs can overlap.
    let len2A = dxA * dxA + dyA * dyA
    if len2A <= 0.0 { return [] }
    if arrLineDistance(a1, a2, b1) > ARR_COLLINEAR_EPS
        || arrLineDistance(a1, a2, b2) > ARR_COLLINEAR_EPS
    {
        return []
    }

    // Project b's endpoints into a's parameter space (unclamped, so a
    // span starting before a1 or ending after a2 is detected).
    let tb1 = ((b1.0 - a1.0) * dxA + (b1.1 - a1.1) * dyA) / len2A
    let tb2 = ((b2.0 - a1.0) * dxA + (b2.1 - a1.1) * dyA) / len2A
    let lo = min(tb1, tb2)
    let hi = max(tb1, tb2)
    let start = lo > 0.0 ? lo : 0.0
    let end = hi < 1.0 ? hi : 1.0
    if end < start - ARR_PARAM_EPS { return [] }

    var out: [((Double, Double), Double, Double)] = []
    let ends: [Double] =
        abs(end - start) <= ARR_PARAM_EPS ? [start] : [start, end]
    for u in ends {
        let s = arrSnapParam(u)
        // The overlap end is always one of the four original endpoints;
        // pick it exactly rather than re-deriving it.
        let p: (Double, Double)
        if s == 0.0 {
            p = a1
        } else if s == 1.0 {
            p = a2
        } else if abs(u - tb1) <= ARR_PARAM_EPS {
            p = b1
        } else if abs(u - tb2) <= ARR_PARAM_EPS {
            p = b2
        } else {
            p = (a1.0 + u * dxA, a1.1 + u * dyA)
        }
        let t = arrSnapParam(arrProjectParam(b1, b2, p))
        out.append((p, s, t))
    }
    return out
}
