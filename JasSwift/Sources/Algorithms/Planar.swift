import Foundation

// Planar graph extraction: turn a collection of polylines (open or
// closed) into a planar subdivision and enumerate the bounded faces.
// Port of jas_dioxus/src/algorithms/planar.rs.
//
// Pipeline:
//   1. Collect all line segments from all input polylines.
//   2. Split every segment at every arrangement-relevant meeting with
//      every other segment — proper crossings, T-junctions and
//      collinear-overlap ends alike — via arrangementSplitPoints
//      (naive O(n²)).
//   3. Snap nearby intersection points and shared endpoints into
//      single vertices.
//   4. Prune vertices of degree 1 iteratively.
//   5. Build a DCEL (doubly connected edge list).
//   6. Traverse half-edge cycles to enumerate faces.
//   7. Drop the unbounded outer face (signed area < 0 under the
//      CCW-interior convention).
//   8. Compute face containment to mark hole relationships.
//
// Degenerate input — handled, each pinned by a unit test in
// Tests/Algorithms/PlanarTests.swift with a hand-derived expectation:
//   - T-junctions: a polyline vertex landing in the interior of another
//     polyline's edge. Step 2 splits the edge there, so the junction
//     becomes a real degree-3 vertex.
//   - Collinear overlap: two polylines retracing the same span. Step 2
//     splits both at the overlap ends; step 5's undirected edge set then
//     fuses the doubled span into one edge.
//
// Deferred:
//   - Bezier curves (caller flattens to polylines first).
//   - Incremental rebuild on stroke add/remove.
//   - Spatial acceleration (R-tree / BVH) for hit testing.

// MARK: - Public types

/// A 2D point.
public typealias PlanarPoint = (Double, Double)

/// A polyline: an ordered list of points.
public typealias PlanarPolyline = [PlanarPoint]

/// Index into `PlanarGraph.vertices`.
public struct VertexId: Hashable, Comparable {
    public let value: Int
    public init(_ v: Int) { self.value = v }
    public static func < (a: VertexId, b: VertexId) -> Bool { a.value < b.value }
}

/// Index into `PlanarGraph.halfEdges`. Half-edges come in twin pairs.
public struct HalfEdgeId: Hashable, Comparable {
    public let value: Int
    public init(_ v: Int) { self.value = v }
    public static func < (a: HalfEdgeId, b: HalfEdgeId) -> Bool { a.value < b.value }
}

/// Index into `PlanarGraph.faces`. All face IDs in a returned graph
/// refer to bounded faces; the unbounded face is dropped.
public struct FaceId: Hashable, Comparable {
    public let value: Int
    public init(_ v: Int) { self.value = v }
    public static func < (a: FaceId, b: FaceId) -> Bool { a.value < b.value }
}

/// A vertex in the planar subdivision.
public struct PlanarVertex {
    public var pos: PlanarPoint
    /// One of the half-edges originating at this vertex.
    public var outgoing: HalfEdgeId
}

/// A directed half-edge. We deliberately do not store a `face` field;
/// the cycle structure carries that information.
public struct PlanarHalfEdge {
    public var origin: VertexId
    public var twin: HalfEdgeId
    public var next: HalfEdgeId
    public var prev: HalfEdgeId
}

/// A bounded face in the subdivision. Has one outer boundary cycle
/// (CCW) and zero or more hole boundary cycles (CW from this face's
/// perspective). `parent` is the immediately enclosing face, or nil
/// for top-level faces; `depth` is 1 for top-level, 2 for their
/// holes, and so on.
public struct PlanarFace {
    public var boundary: HalfEdgeId
    public var holes: [HalfEdgeId]
    public var parent: FaceId?
    public var depth: Int
}

/// A complete planar subdivision: vertices, half-edges, and faces.
public struct PlanarGraph {
    public var vertices: [PlanarVertex] = []
    public var halfEdges: [PlanarHalfEdge] = []
    public var faces: [PlanarFace] = []

    public init() {}

    /// Number of bounded faces.
    public var faceCount: Int { faces.count }

    /// All top-level faces (depth 1).
    public var topLevelFaces: [FaceId] {
        faces.enumerated().compactMap { (i, f) in
            f.depth == 1 ? FaceId(i) : nil
        }
    }

    /// Absolute area of a face's outer boundary, ignoring its holes.
    public func faceOuterArea(_ face: FaceId) -> Double {
        abs(cycleSignedArea(faces[face.value].boundary))
    }

    /// Net area of a face: outer boundary minus holes.
    public func faceNetArea(_ face: FaceId) -> Double {
        let outer = faceOuterArea(face)
        let holes = faces[face.value].holes
            .map { abs(cycleSignedArea($0)) }
            .reduce(0.0, +)
        return outer - holes
    }

    /// Hit test: deepest face containing `point`, or nil if outside.
    /// "Deepest" means a click in a hole returns the hole's face,
    /// not its parent.
    public func hitTest(_ point: PlanarPoint) -> FaceId? {
        var best: FaceId? = nil
        var bestDepth = 0
        for fi in 0..<faces.count {
            let poly = cyclePolygon(faces[fi].boundary)
            if planarWindingNumber(poly, point) != 0 && faces[fi].depth > bestDepth {
                bestDepth = faces[fi].depth
                best = FaceId(fi)
            }
        }
        return best
    }

    // MARK: - Internal cycle helpers

    func cycleSignedArea(_ start: HalfEdgeId) -> Double {
        var sum = 0.0
        var e = start.value
        repeat {
            let a = vertices[halfEdges[e].origin.value].pos
            let nextE = halfEdges[e].next.value
            let b = vertices[halfEdges[nextE].origin.value].pos
            sum += a.0 * b.1 - b.0 * a.1
            e = nextE
        } while e != start.value
        return sum / 2.0
    }

    func cyclePolygon(_ start: HalfEdgeId) -> [PlanarPoint] {
        var out: [PlanarPoint] = []
        var e = start.value
        repeat {
            out.append(vertices[halfEdges[e].origin.value].pos)
            e = halfEdges[e].next.value
        } while e != start.value
        return out
    }
}

// MARK: - Build

extension PlanarGraph {
    /// Build a planar graph from a set of polylines.
    public static func build(_ polylines: [PlanarPolyline]) -> PlanarGraph {
        // ----- 1. Collect non-degenerate segments -----
        var segments: [(PlanarPoint, PlanarPoint)] = []
        for poly in polylines {
            if poly.count < 2 { continue }
            for i in 0..<(poly.count - 1) {
                let a = poly[i]
                let b = poly[i + 1]
                if arrangementDist(a, b) > ARR_VERT_EPS {
                    segments.append((a, b))
                }
            }
        }
        if segments.isEmpty {
            return PlanarGraph()
        }

        // ----- 2-3. Per-segment vertex lists with snap-merging -----
        var vertPts: [PlanarPoint] = []
        var segParams: [[(Double, Int)]] = Array(repeating: [], count: segments.count)
        for (si, seg) in segments.enumerated() {
            let va = arrangementAddOrFindVertex(&vertPts, seg.0)
            let vb = arrangementAddOrFindVertex(&vertPts, seg.1)
            segParams[si].append((0.0, va))
            segParams[si].append((1.0, vb))
        }

        // ----- 4. Naive O(n²) pairwise splitting -----
        // arrangementSplitPoints reports every arrangement-relevant
        // meeting of two segments: proper interior crossings,
        // T-junctions, endpoint coincidences and collinear-overlap ends.
        // Splitting at all of them is what makes the arrangement
        // conforming.
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

        // ----- 5. Sort each segment's vertex list and emit atomic edges -----
        var edgeSet: Set<UInt64> = []
        var edges: [(Int, Int)] = []
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
            // Drop consecutive duplicates that snapped to the same vertex.
            var chain: [Int] = []
            var prev: Int? = nil
            for (_, v) in segParams[si] {
                if v != prev {
                    chain.append(v)
                    prev = v
                }
            }
            for k in 0..<(chain.count - 1) {
                let u = chain[k]
                let v = chain[k + 1]
                if u != v {
                    let lo = min(u, v)
                    let hi = max(u, v)
                    let key = (UInt64(lo) << 32) | UInt64(hi)
                    if edgeSet.insert(key).inserted {
                        edges.append((lo, hi))
                    }
                }
            }
        }
        edges.sort { a, b in a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }

        // ----- 6. Iteratively prune degree-1 vertices -----
        while !edges.isEmpty {
            var deg = Array(repeating: 0, count: vertPts.count)
            for (u, v) in edges {
                deg[u] += 1
                deg[v] += 1
            }
            let before = edges.count
            edges = edges.filter { deg[$0.0] >= 2 && deg[$0.1] >= 2 }
            if edges.count == before { break }
        }
        if edges.isEmpty {
            return PlanarGraph()
        }

        // Compact the vertex array.
        var used = Array(repeating: false, count: vertPts.count)
        for (u, v) in edges {
            used[u] = true
            used[v] = true
        }
        var newId = Array(repeating: -1, count: vertPts.count)
        var compacted: [PlanarPoint] = []
        for (i, p) in vertPts.enumerated() {
            if used[i] {
                newId[i] = compacted.count
                compacted.append(p)
            }
        }
        edges = edges.map { (newId[$0.0], newId[$0.1]) }
        vertPts = compacted

        // ----- 7. Build half-edges and DCEL links -----
        let nHE = edges.count * 2
        var heOrigin = Array(repeating: 0, count: nHE)
        var heTwin = Array(repeating: 0, count: nHE)
        for (k, (u, v)) in edges.enumerated() {
            let i = k * 2
            heOrigin[i] = u
            heOrigin[i + 1] = v
            heTwin[i] = i + 1
            heTwin[i + 1] = i
        }

        // Per-vertex outgoing half-edges, sorted CCW by angle.
        var outgoingAt: [[Int]] = Array(repeating: [], count: vertPts.count)
        for i in 0..<nHE {
            outgoingAt[heOrigin[i]].append(i)
        }
        for vIdx in 0..<vertPts.count {
            let origin = vertPts[vIdx]
            // Tie-break on the half-edge index. Rust's counterpart uses
            // `sort_by`, which is STABLE, so equal angles keep insertion
            // order — and insertion above is by ascending half-edge index.
            // Swift's `sort` is NOT guaranteed stable, so without this the
            // two ports could order a tie differently, and `next(e)` reads
            // the neighbour by POSITION in this list, so a different order
            // traces a different face. A conforming arrangement should
            // never present a tie (two half-edges leaving one vertex at
            // the same angle would be an unsplit collinear overlap), but
            // "should never" is the sort of guarantee worth writing down
            // rather than depending on silently — the same reasoning, and
            // the same spelling, as the outgoing-span tie-break in
            // BooleanNormalize.swift.
            outgoingAt[vIdx].sort { a, b in
                let ta = vertPts[heOrigin[heTwin[a]]]
                let tb = vertPts[heOrigin[heTwin[b]]]
                let aa = atan2(ta.1 - origin.1, ta.0 - origin.0)
                let ab = atan2(tb.1 - origin.1, tb.0 - origin.0)
                return aa == ab ? a < b : aa < ab
            }
        }

        // For each half-edge `e` ending at vertex `v`:
        //   next(e) = the outgoing half-edge from `v` immediately
        //             CW from `e.twin` in the angular order at `v`.
        var heNext = Array(repeating: 0, count: nHE)
        var hePrev = Array(repeating: 0, count: nHE)
        for e in 0..<nHE {
            let etwin = heTwin[e]
            let v = heOrigin[etwin]
            let list = outgoingAt[v]
            let idx = list.firstIndex(of: etwin)!
            let cwIdx = (idx + list.count - 1) % list.count
            let nextE = list[cwIdx]
            heNext[e] = nextE
            hePrev[nextE] = e
        }

        // ----- 8. Enumerate half-edge cycles -----
        var heCycle = Array(repeating: -1, count: nHE)
        var cycles: [[Int]] = []
        for start in 0..<nHE {
            if heCycle[start] != -1 { continue }
            var cyc: [Int] = []
            var e = start
            repeat {
                heCycle[e] = cycles.count
                cyc.append(e)
                e = heNext[e]
            } while e != start
            cycles.append(cyc)
        }

        // ----- 9. Signed area; classify positive vs negative.
        var areas: [Double] = []
        areas.reserveCapacity(cycles.count)
        for cyc in cycles {
            let n = cyc.count
            var sum = 0.0
            for i in 0..<n {
                let a = vertPts[heOrigin[cyc[i]]]
                let b = vertPts[heOrigin[cyc[(i + 1) % n]]]
                sum += a.0 * b.1 - b.0 * a.1
            }
            areas.append(sum / 2.0)
        }
        let posCycles: [Int] = (0..<cycles.count).filter { areas[$0] > 0.0 }
        let negCycles: [Int] = (0..<cycles.count).filter { areas[$0] < 0.0 }
        let nFaces = posCycles.count

        let cyclePolys: [[PlanarPoint]] = cycles.map { cyc in
            cyc.map { vertPts[heOrigin[$0]] }
        }

        // ----- 11. Parent of each face -----
        var parents: [FaceId?] = Array(repeating: nil, count: nFaces)
        for fi in 0..<nFaces {
            let cycF = posCycles[fi]
            let areaF = areas[cycF]
            let sample = sampleInside(cyclePolys[cycF])
            var best: Int? = nil
            var bestArea = Double.infinity
            for gi in 0..<nFaces {
                if gi == fi { continue }
                let cycG = posCycles[gi]
                let areaG = areas[cycG]
                if areaG <= areaF { continue }
                if planarWindingNumber(cyclePolys[cycG], sample) != 0 && areaG < bestArea {
                    bestArea = areaG
                    best = gi
                }
            }
            parents[fi] = best.map { FaceId($0) }
        }

        // ----- 12. Depth via topological propagation.
        var depth = Array(repeating: 0, count: nFaces)
        var changed = true
        while changed {
            changed = false
            for f in 0..<nFaces {
                if depth[f] != 0 { continue }
                if let p = parents[f] {
                    if depth[p.value] != 0 {
                        depth[f] = depth[p.value] + 1
                        changed = true
                    }
                } else {
                    depth[f] = 1
                    changed = true
                }
            }
        }

        // ----- 13. Hole assignment -----
        var faceHoles: [[Int]] = Array(repeating: [], count: nFaces)
        for negI in negCycles {
            let areaNeg = abs(areas[negI])
            let sample = sampleInside(cyclePolys[negI])
            var best: Int? = nil
            var bestArea = Double.infinity
            for fi in 0..<nFaces {
                let cycG = posCycles[fi]
                let areaF = areas[cycG]
                if areaF <= areaNeg { continue }
                if planarWindingNumber(cyclePolys[cycG], sample) != 0 && areaF < bestArea {
                    bestArea = areaF
                    best = fi
                }
            }
            if let fi = best {
                faceHoles[fi].append(negI)
            }
            // else: part of unbounded face, drop.
        }

        // ----- Materialize public structures -----
        var graph = PlanarGraph()
        graph.vertices = vertPts.enumerated().map { (i, p) in
            PlanarVertex(
                pos: p,
                outgoing: HalfEdgeId(outgoingAt[i].first ?? 0)
            )
        }
        graph.halfEdges = (0..<nHE).map { e in
            PlanarHalfEdge(
                origin: VertexId(heOrigin[e]),
                twin: HalfEdgeId(heTwin[e]),
                next: HalfEdgeId(heNext[e]),
                prev: HalfEdgeId(hePrev[e])
            )
        }
        graph.faces = (0..<nFaces).map { fi in
            let outerCycle = posCycles[fi]
            return PlanarFace(
                boundary: HalfEdgeId(cycles[outerCycle][0]),
                holes: faceHoles[fi].map { HalfEdgeId(cycles[$0][0]) },
                parent: parents[fi],
                depth: depth[fi]
            )
        }
        return graph
    }
}

// MARK: - Numerical helpers

/// Winding number with half-open upward/downward classification.
internal func planarWindingNumber(_ poly: [PlanarPoint], _ point: PlanarPoint) -> Int {
    let n = poly.count
    if n < 3 { return 0 }
    let (px, py) = point
    var w = 0
    for i in 0..<n {
        let (x1, y1) = poly[i]
        let (x2, y2) = poly[(i + 1) % n]
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

/// Pick a point strictly inside the polygon traced by `poly`,
/// regardless of CW/CCW orientation. Mirrors BooleanNormalize's
/// `sampleInsideSimpleRing`.
private func sampleInside(_ poly: [PlanarPoint]) -> PlanarPoint {
    precondition(poly.count >= 3)
    let (x0, y0) = poly[0]
    let (x1, y1) = poly[1]
    let mx = (x0 + x1) / 2.0
    let my = (y0 + y1) / 2.0
    let dx = x1 - x0
    let dy = y1 - y0
    let len = (dx * dx + dy * dy).squareRoot()
    if len == 0.0 {
        let (x2, y2) = poly[2]
        return ((x0 + x1 + x2) / 3.0, (y0 + y1 + y2) / 3.0)
    }
    let nx = -dy / len
    let ny = dx / len
    let offset = len * 1e-4
    let left = (mx + nx * offset, my + ny * offset)
    let right = (mx - nx * offset, my - ny * offset)
    return planarWindingNumber(poly, left) != 0 ? left : right
}
