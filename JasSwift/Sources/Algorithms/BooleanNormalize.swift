import Foundation

// Ring normalizer: turn an arbitrary (possibly self-intersecting)
// polygon set into an equivalent set of simple rings under the non-zero
// winding fill rule. Port of jas_dioxus/src/algorithms/normalize.rs.
//
// Algorithm: recursive splitting. For each ring, find the first proper
// interior crossing between two non-adjacent edges; if none, the ring
// is simple. Otherwise split at the crossing into two sub-rings and
// recurse. Filter resulting sub-rings by the winding number of the
// original ring at a sample point inside each.
//
// Scope: handles simple rings, figure-8 / proper interior self-
// intersections, and multiple intersections (resolved recursively).
// Does not handle T-junctions, collinear self-retrace, or inter-ring
// cancellation.

/// Normalize a polygon set under the non-zero winding fill rule.
public func normalize(_ input: BoolPolygonSet) -> BoolPolygonSet {
    var out: BoolPolygonSet = []
    for ring in input {
        out.append(contentsOf: normalizeRing(ring))
    }
    return out
}

func normalizeRing(_ ring: BoolRing) -> [BoolRing] {
    let cleaned = dedupConsecutive(ring)
    if cleaned.count < 3 { return [] }
    let simple = splitRecursively(cleaned)
    var out: [BoolRing] = []
    for sub in simple {
        if sub.count < 3 { continue }
        let sample = sampleInsideSimpleRing(sub)
        if windingNumber(cleaned, sample) != 0 {
            out.append(sub)
        }
    }
    return out
}

// MARK: - Vertex cleanup

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

// MARK: - Self-intersection detection / splitting

func findFirstSelfIntersection(_ ring: BoolRing) -> (Int, Int, (Double, Double))? {
    let n = ring.count
    if n < 4 { return nil }
    for i in 0..<n {
        let a1 = ring[i]
        let a2 = ring[(i + 1) % n]
        if i + 2 >= n { continue }
        for j in (i + 2)..<n {
            if i == 0 && j == n - 1 { continue }  // skip wrap-around adjacent
            let b1 = ring[j]
            let b2 = ring[(j + 1) % n]
            if let p = segmentProperIntersection(a1, a2, b1, b2) {
                return (i, j, p)
            }
        }
    }
    return nil
}

func segmentProperIntersection(_ a1: (Double, Double), _ a2: (Double, Double),
                               _ b1: (Double, Double), _ b2: (Double, Double)) -> (Double, Double)? {
    let dxA = a2.0 - a1.0
    let dyA = a2.1 - a1.1
    let dxB = b2.0 - b1.0
    let dyB = b2.1 - b1.1
    let denom = dxA * dyB - dyA * dxB
    if abs(denom) < 1e-12 { return nil }
    let dxAB = a1.0 - b1.0
    let dyAB = a1.1 - b1.1
    let s = (dxB * dyAB - dyB * dxAB) / denom
    let t = (dxA * dyAB - dyA * dxAB) / denom
    let eps = 1e-9
    if s <= eps || s >= 1.0 - eps || t <= eps || t >= 1.0 - eps { return nil }
    return (a1.0 + s * dxA, a1.1 + s * dyA)
}

func splitRingAt(_ ring: BoolRing, _ i: Int, _ j: Int, _ p: (Double, Double)) -> (BoolRing, BoolRing) {
    let n = ring.count
    var a: BoolRing = []
    a.reserveCapacity(i + 2 + (n - j - 1))
    for k in 0...i { a.append(ring[k]) }
    a.append(p)
    for k in (j + 1)..<n { a.append(ring[k]) }

    var b: BoolRing = []
    b.reserveCapacity(j - i + 1)
    b.append(p)
    for k in (i + 1)...j { b.append(ring[k]) }

    return (a, b)
}

func splitRecursively(_ ring: BoolRing) -> [BoolRing] {
    var stack: [BoolRing] = [ring]
    var simple: [BoolRing] = []
    while let r = stack.popLast() {
        if r.count < 3 { continue }
        if let (i, j, p) = findFirstSelfIntersection(r) {
            let (a, b) = splitRingAt(r, i, j, p)
            stack.append(a)
            stack.append(b)
        } else {
            simple.append(r)
        }
    }
    return simple
}

// MARK: - Winding and sampling

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
