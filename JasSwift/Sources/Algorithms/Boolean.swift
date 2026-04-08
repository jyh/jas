import Foundation

// Boolean operations on planar polygons (union, intersection,
// difference, exclusive-or). Port of jas_dioxus/src/algorithms/boolean.rs.
// See that file for the design rationale and reference papers.
//
// Data model: a `BoolPolygonSet` is a flat list of rings; a ring is a
// closed polygon expressed as a list of (x, y) vertices without the
// implicit closing vertex. Multiple rings represent a region under the
// even-odd fill rule.
//
// Inputs may be self-intersecting; they are normalized as a pre-pass
// under the non-zero winding fill rule. See BooleanNormalize.swift.

// MARK: - Public types

/// A single closed ring as an array of (x, y) vertices.
public typealias BoolRing = [(Double, Double)]

/// A flat list of rings under the even-odd fill rule.
public typealias BoolPolygonSet = [BoolRing]

// MARK: - Public API

public func booleanUnion(_ a: BoolPolygonSet, _ b: BoolPolygonSet) -> BoolPolygonSet {
    runBoolean(a, b, .union)
}

public func booleanIntersect(_ a: BoolPolygonSet, _ b: BoolPolygonSet) -> BoolPolygonSet {
    runBoolean(a, b, .intersection)
}

public func booleanSubtract(_ a: BoolPolygonSet, _ b: BoolPolygonSet) -> BoolPolygonSet {
    runBoolean(a, b, .difference)
}

public func booleanExclude(_ a: BoolPolygonSet, _ b: BoolPolygonSet) -> BoolPolygonSet {
    runBoolean(a, b, .xor)
}

// MARK: - Internal types

enum BoolOperation {
    case union, intersection, difference, xor
}

enum BoolPolygonId: Int {
    case subject = 0
    case clipping = 1
}

enum BoolEdgeType {
    case normal
    case sameTransition
    case differentTransition
    case nonContributing
}

/// One endpoint of an edge in the sweep-line algorithm. Two events per edge.
struct BoolSweepEvent {
    var point: (Double, Double)
    var isLeft: Bool
    var polygon: BoolPolygonId
    var otherEvent: Int
    var inOut: Bool = false
    var otherInOut: Bool = false
    var inResult: Bool = false
    var edgeType: BoolEdgeType = .normal
    var prevInResult: Int? = nil

    init(point: (Double, Double), isLeft: Bool, polygon: BoolPolygonId) {
        self.point = point
        self.isLeft = isLeft
        self.polygon = polygon
        self.otherEvent = -1
    }
}

// MARK: - Geometric primitives

func pointLexLess(_ a: (Double, Double), _ b: (Double, Double)) -> Bool {
    if a.0 != b.0 { return a.0 < b.0 }
    return a.1 < b.1
}

func boolSignedArea(_ p0: (Double, Double), _ p1: (Double, Double), _ p2: (Double, Double)) -> Double {
    (p0.0 - p2.0) * (p1.1 - p2.1) - (p1.0 - p2.0) * (p0.1 - p2.1)
}

func pointsEq(_ a: (Double, Double), _ b: (Double, Double)) -> Bool {
    abs(a.0 - b.0) < 1e-9 && abs(a.1 - b.1) < 1e-9
}

/// Project `p` onto the segment `a → b`, clamped to the segment endpoints.
/// Used by `handleCollinear` to keep split points on the edge being split.
func projectOntoSegment(_ a: (Double, Double), _ b: (Double, Double), _ p: (Double, Double)) -> (Double, Double) {
    let dx = b.0 - a.0
    let dy = b.1 - a.1
    let lenSq = dx * dx + dy * dy
    if lenSq == 0.0 { return a }
    var t = ((p.0 - a.0) * dx + (p.1 - a.1) * dy) / lenSq
    t = max(0.0, min(1.0, t))
    return (a.0 + t * dx, a.1 + t * dy)
}

// MARK: - Event ordering

func eventLess(_ events: [BoolSweepEvent], _ a: Int, _ b: Int) -> Bool {
    let ea = events[a]
    let eb = events[b]
    if ea.point.0 != eb.point.0 { return ea.point.0 < eb.point.0 }
    if ea.point.1 != eb.point.1 { return ea.point.1 < eb.point.1 }
    if ea.isLeft != eb.isLeft { return !ea.isLeft }  // right before left
    let otherA = events[ea.otherEvent].point
    let otherB = events[eb.otherEvent].point
    let area = boolSignedArea(ea.point, otherA, otherB)
    if area != 0.0 { return area > 0.0 }
    return ea.polygon.rawValue < eb.polygon.rawValue
}

func statusLess(_ events: [BoolSweepEvent], _ a: Int, _ b: Int) -> Bool {
    if a == b { return false }
    let ea = events[a]
    let eb = events[b]
    let otherA = events[ea.otherEvent].point
    let otherB = events[eb.otherEvent].point
    if boolSignedArea(ea.point, otherA, eb.point) != 0.0
        || boolSignedArea(ea.point, otherA, otherB) != 0.0 {
        // Not collinear
        if ea.point == eb.point {
            return boolSignedArea(ea.point, otherA, otherB) > 0.0
        }
        if eventLess(events, a, b) {
            return boolSignedArea(ea.point, otherA, eb.point) > 0.0
        }
        return boolSignedArea(eb.point, otherB, ea.point) < 0.0
    }
    // Collinear: tie-break by polygon then by point order.
    if ea.polygon != eb.polygon {
        return ea.polygon.rawValue < eb.polygon.rawValue
    }
    if ea.point != eb.point {
        return pointLexLess(ea.point, eb.point)
    }
    return pointLexLess(otherA, otherB)
}

// MARK: - Result classification

func edgeInResult(_ event: BoolSweepEvent, _ op: BoolOperation) -> Bool {
    switch event.edgeType {
    case .normal:
        switch op {
        case .union: return event.otherInOut
        case .intersection: return !event.otherInOut
        case .difference:
            return event.polygon == .subject ? event.otherInOut : !event.otherInOut
        case .xor: return true
        }
    case .sameTransition:
        return op == .union || op == .intersection
    case .differentTransition:
        return op == .difference
    case .nonContributing:
        return false
    }
}

// MARK: - Snap-rounding

let SNAP_RATIO: Double = 1e-9

/// Compute the snap-rounding grid spacing as a power of 2 fraction of
/// the combined input bounding-box diagonal. Returns nil for empty or
/// degenerate input.
func snapGrid(_ a: BoolPolygonSet, _ b: BoolPolygonSet) -> Double? {
    var minX = Double.infinity
    var minY = Double.infinity
    var maxX = -Double.infinity
    var maxY = -Double.infinity
    var any = false
    for ring in a + b {
        for (x, y) in ring {
            if x < minX { minX = x }
            if y < minY { minY = y }
            if x > maxX { maxX = x }
            if y > maxY { maxY = y }
            any = true
        }
    }
    if !any { return nil }
    let dx = maxX - minX
    let dy = maxY - minY
    let diagonal = (dx * dx + dy * dy).squareRoot()
    if diagonal <= 0.0 { return nil }
    let target = diagonal * SNAP_RATIO
    if target <= 0.0 || !target.isFinite { return nil }
    let exponent = Int(ceil(log2(target)))
    return pow(2.0, Double(exponent))
}

/// Snap each vertex to the nearest point on a power-of-2 grid lattice,
/// drop consecutive duplicates, and drop rings of fewer than 3 distinct
/// vertices.
func snapRound(_ ps: BoolPolygonSet, grid: Double) -> BoolPolygonSet {
    let snap: (Double) -> Double = { x in (x / grid).rounded() * grid }
    var out: BoolPolygonSet = []
    for ring in ps {
        var newRing: BoolRing = []
        for (x, y) in ring {
            let p = (snap(x), snap(y))
            if newRing.last.map({ $0 == p }) != true {
                newRing.append(p)
            }
        }
        while newRing.count > 1 && newRing.first! == newRing.last! {
            newRing.removeLast()
        }
        if newRing.count >= 3 {
            out.append(newRing)
        }
    }
    return out
}

func cloneNondegenerate(_ ps: BoolPolygonSet) -> BoolPolygonSet {
    ps.filter { $0.count >= 3 }
}

// MARK: - Sweep state

struct BoolSweep {
    var events: [BoolSweepEvent] = []

    mutating func addEdge(_ p1: (Double, Double), _ p2: (Double, Double), _ polygon: BoolPolygonId) {
        if p1 == p2 { return }
        let lp: (Double, Double)
        let rp: (Double, Double)
        if pointLexLess(p1, p2) {
            lp = p1; rp = p2
        } else {
            lp = p2; rp = p1
        }
        let l = events.count
        let r = l + 1
        var le = BoolSweepEvent(point: lp, isLeft: true, polygon: polygon)
        var re = BoolSweepEvent(point: rp, isLeft: false, polygon: polygon)
        le.otherEvent = r
        re.otherEvent = l
        events.append(le)
        events.append(re)
    }

    mutating func addPolygonSet(_ ps: BoolPolygonSet, _ polygon: BoolPolygonId) {
        for ring in ps {
            let n = ring.count
            if n < 3 { continue }
            for i in 0..<n {
                addEdge(ring[i], ring[(i + 1) % n], polygon)
            }
        }
    }
}

// MARK: - Top-level dispatch

func runBoolean(_ a: BoolPolygonSet, _ b: BoolPolygonSet, _ op: BoolOperation) -> BoolPolygonSet {
    // Snap-round inputs onto a grid sized as a fixed fraction of the
    // combined bounding-box diagonal.
    let aSnap: BoolPolygonSet
    let bSnap: BoolPolygonSet
    if let grid = snapGrid(a, b) {
        aSnap = snapRound(a, grid: grid)
        bSnap = snapRound(b, grid: grid)
    } else {
        aSnap = cloneNondegenerate(a)
        bSnap = cloneNondegenerate(b)
    }

    // Resolve self-intersections under non-zero winding so the sweep
    // can keep assuming simple input rings. No-op for already-simple input.
    let aNorm = normalize(aSnap)
    let bNorm = normalize(bSnap)

    // Re-snap: normalize() may introduce off-grid intersection points.
    let aFinal: BoolPolygonSet
    let bFinal: BoolPolygonSet
    if let grid = snapGrid(aNorm, bNorm) {
        aFinal = snapRound(aNorm, grid: grid)
        bFinal = snapRound(bNorm, grid: grid)
    } else {
        aFinal = aNorm
        bFinal = bNorm
    }

    return runBooleanSweep(aFinal, bFinal, op)
}

/// Run just the Martinez sweep on already-prepared inputs. Tests call
/// this directly to bypass snap-rounding when needed.
func runBooleanSweep(_ a: BoolPolygonSet, _ b: BoolPolygonSet, _ op: BoolOperation) -> BoolPolygonSet {
    let aEmpty = a.allSatisfy { $0.count < 3 }
    let bEmpty = b.allSatisfy { $0.count < 3 }
    if aEmpty && bEmpty { return [] }
    if aEmpty {
        switch op {
        case .union, .xor: return cloneNondegenerate(b)
        case .intersection, .difference: return []
        }
    }
    if bEmpty {
        switch op {
        case .union, .xor, .difference: return cloneNondegenerate(a)
        case .intersection: return []
        }
    }

    var sweep = BoolSweep()
    sweep.addPolygonSet(a, .subject)
    sweep.addPolygonSet(b, .clipping)

    // Build the priority queue. Sorted descending by event_less so the
    // smallest is at the back where popLast() removes it in O(1).
    var queue: [Int] = Array(0..<sweep.events.count)
    queue.sort { eventLess(sweep.events, $1, $0) }

    var processed: [Int] = []
    processed.reserveCapacity(queue.count * 2)
    var status: [Int] = []

    while let idx = queue.popLast() {
        processed.append(idx)
        let isLeft = sweep.events[idx].isLeft
        if isLeft {
            let pos = statusInsertPos(sweep.events, status, idx)
            status.insert(idx, at: pos)
            computeFields(&sweep.events, status, pos)
            if pos + 1 < status.count {
                let above = status[pos + 1]
                possibleIntersection(&sweep.events, &queue, idx, above, op)
            }
            if pos > 0 {
                let below = status[pos - 1]
                possibleIntersection(&sweep.events, &queue, below, idx, op)
            }
            sweep.events[idx].inResult = edgeInResult(sweep.events[idx], op)
        } else {
            let other = sweep.events[idx].otherEvent
            if let pos = status.firstIndex(of: other) {
                let above: Int? = pos + 1 < status.count ? status[pos + 1] : nil
                let below: Int? = pos > 0 ? status[pos - 1] : nil
                status.remove(at: pos)
                if let bIdx = below, let aIdx = above {
                    possibleIntersection(&sweep.events, &queue, bIdx, aIdx, op)
                }
            }
            sweep.events[idx].inResult = sweep.events[other].inResult
        }
    }

    return connectEdges(sweep.events, processed)
}

// MARK: - Status & queue helpers

func statusInsertPos(_ events: [BoolSweepEvent], _ status: [Int], _ idx: Int) -> Int {
    // Linear search; status is small in practice.
    var lo = 0
    var hi = status.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if statusLess(events, status[mid], idx) {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo
}

func queuePush(_ queue: inout [Int], _ events: [BoolSweepEvent], _ idx: Int) {
    // Queue is sorted DESCENDING by eventLess so that popLast() gives
    // the smallest event in O(1). Insert idx at the first position
    // where the existing element is NOT strictly greater than idx —
    // i.e., walk past elements that are bigger and stop where they
    // are equal-or-smaller.
    var lo = 0
    var hi = queue.count
    while lo < hi {
        let mid = (lo + hi) / 2
        // queue[mid] > idx means "queue[mid] should come before idx"
        // in descending order, so look right past it.
        if eventLess(events, idx, queue[mid]) {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    queue.insert(idx, at: lo)
}

// MARK: - Intersection detection

enum BoolIntersection {
    case none
    case point((Double, Double))
    case overlap
}

func findIntersection(_ a1: (Double, Double), _ a2: (Double, Double),
                      _ b1: (Double, Double), _ b2: (Double, Double)) -> BoolIntersection {
    let dxA = a2.0 - a1.0
    let dyA = a2.1 - a1.1
    let dxB = b2.0 - b1.0
    let dyB = b2.1 - b1.1
    let denom = dxA * dyB - dyA * dxB
    if abs(denom) < 1e-12 {
        return .overlap
    }
    let dxAB = a1.0 - b1.0
    let dyAB = a1.1 - b1.1
    var s = (dxB * dyAB - dyB * dxAB) / denom
    let t = (dxA * dyAB - dyA * dxAB) / denom
    let eps = 1e-9
    if s < -eps || s > 1.0 + eps || t < -eps || t > 1.0 + eps {
        return .none
    }
    s = max(0.0, min(1.0, s))
    return .point((a1.0 + s * dxA, a1.1 + s * dyA))
}

func possibleIntersection(_ events: inout [BoolSweepEvent], _ queue: inout [Int],
                          _ e1: Int, _ e2: Int, _ op: BoolOperation) {
    if events[e1].polygon == events[e2].polygon { return }
    let a1 = events[e1].point
    let a2 = events[events[e1].otherEvent].point
    let b1 = events[e2].point
    let b2 = events[events[e2].otherEvent].point
    switch findIntersection(a1, a2, b1, b2) {
    case .none:
        break
    case .point(let p):
        if !pointsEq(p, a1) && !pointsEq(p, a2) {
            _ = divideSegment(&events, &queue, e1, p)
        }
        if !pointsEq(p, b1) && !pointsEq(p, b2) {
            _ = divideSegment(&events, &queue, e2, p)
        }
    case .overlap:
        handleCollinear(&events, &queue, e1, e2, op)
    }
}

// MARK: - Collinear handling

func handleCollinear(_ events: inout [BoolSweepEvent], _ queue: inout [Int],
                     _ e1: Int, _ e2: Int, _ op: BoolOperation) {
    let e1r = events[e1].otherEvent
    let e2r = events[e2].otherEvent
    let p1l = events[e1].point
    let p1r = events[e1r].point
    let p2l = events[e2].point
    let p2r = events[e2r].point

    // Re-check collinearity (find_intersection's overlap fires for
    // parallel-disjoint too).
    if abs(boolSignedArea(p1l, p1r, p2l)) > 1e-9
        || abs(boolSignedArea(p1l, p1r, p2r)) > 1e-9 {
        return
    }

    // Overlap extent on dominant axis.
    let dx = abs(p1r.0 - p1l.0)
    let dy = abs(p1r.1 - p1l.1)
    let proj: ((Double, Double)) -> Double = { p in dx >= dy ? p.0 : p.1 }
    let s1Lo = min(proj(p1l), proj(p1r))
    let s1Hi = max(proj(p1l), proj(p1r))
    let s2Lo = min(proj(p2l), proj(p2r))
    let s2Hi = max(proj(p2l), proj(p2r))
    let lo = max(s1Lo, s2Lo)
    let hi = min(s1Hi, s2Hi)
    if hi - lo <= 1e-9 { return }

    let leftCoincide = pointsEq(p1l, p2l)
    let rightCoincide = pointsEq(p1r, p2r)

    let sameDir = events[e1].inOut == events[e2].inOut
    let keptType: BoolEdgeType = sameDir ? .sameTransition : .differentTransition

    if leftCoincide && rightCoincide {
        // Case A — identical edges.
        events[e1].edgeType = .nonContributing
        events[e2].edgeType = keptType
        events[e1].inResult = edgeInResult(events[e1], op)
        events[e2].inResult = edgeInResult(events[e2], op)
        return
    }

    if leftCoincide {
        // Case B — shared left endpoint.
        let longerLeft: Int
        var shorterRightPt: (Double, Double)
        if eventLess(events, e1r, e2r) {
            longerLeft = e2; shorterRightPt = p1r
        } else {
            longerLeft = e1; shorterRightPt = p2r
        }
        let longerLeftPt = events[longerLeft].point
        let longerRightPt = events[events[longerLeft].otherEvent].point
        shorterRightPt = projectOntoSegment(longerLeftPt, longerRightPt, shorterRightPt)
        if longerLeft == e1 {
            events[e1].edgeType = .nonContributing
            events[e2].edgeType = keptType
        } else {
            events[e1].edgeType = keptType
            events[e2].edgeType = .nonContributing
        }
        events[e1].inResult = edgeInResult(events[e1], op)
        events[e2].inResult = edgeInResult(events[e2], op)
        _ = divideSegment(&events, &queue, longerLeft, shorterRightPt)
        return
    }

    if rightCoincide {
        // Case C — shared right endpoint.
        let longerLeft: Int
        var laterLeftPt: (Double, Double)
        if eventLess(events, e1, e2) {
            longerLeft = e1; laterLeftPt = p2l
        } else {
            longerLeft = e2; laterLeftPt = p1l
        }
        let longerLeftPt = events[longerLeft].point
        let longerRightPt = events[events[longerLeft].otherEvent].point
        laterLeftPt = projectOntoSegment(longerLeftPt, longerRightPt, laterLeftPt)
        let (_, nrIdx) = divideSegment(&events, &queue, longerLeft, laterLeftPt)
        events[nrIdx].edgeType = .nonContributing
        let shorter = longerLeft == e1 ? e2 : e1
        events[shorter].edgeType = keptType
        events[nrIdx].inResult = edgeInResult(events[nrIdx], op)
        events[shorter].inResult = edgeInResult(events[shorter], op)
        return
    }

    // Case D — neither coincide. Sort the four endpoints by event order.
    var endpoints = [e1, e1r, e2, e2r]
    endpoints.sort { eventLess(events, $0, $1) }
    let first = endpoints[0]
    let second = endpoints[1]
    let third = endpoints[2]
    let fourth = endpoints[3]

    if events[first].otherEvent == fourth {
        // Case D1 — containment. Split first twice.
        let firstPt = events[first].point
        let firstOtherPt = events[events[first].otherEvent].point
        let midLeft = projectOntoSegment(firstPt, firstOtherPt, events[second].point)
        let midRight = projectOntoSegment(firstPt, firstOtherPt, events[third].point)
        let (_, nr1) = divideSegment(&events, &queue, first, midLeft)
        let (_, _) = divideSegment(&events, &queue, nr1, midRight)
        events[nr1].edgeType = .nonContributing
        let shorter = first == e1 ? e2 : e1
        events[shorter].edgeType = keptType
        events[nr1].inResult = edgeInResult(events[nr1], op)
        events[shorter].inResult = edgeInResult(events[shorter], op)
    } else {
        // Case D2 — partial overlap.
        let firstPt = events[first].point
        let firstOtherPt = events[events[first].otherEvent].point
        let splitA = projectOntoSegment(firstPt, firstOtherPt, events[second].point)
        let otherLeft = events[fourth].otherEvent
        let otherLeftPt = events[otherLeft].point
        let otherRightPt = events[events[otherLeft].otherEvent].point
        let splitB = projectOntoSegment(otherLeftPt, otherRightPt, events[third].point)
        let (_, nr1) = divideSegment(&events, &queue, first, splitA)
        let (_, _) = divideSegment(&events, &queue, otherLeft, splitB)
        events[nr1].edgeType = .nonContributing
        let keptLeft = first == e1 ? e2 : e1
        events[keptLeft].edgeType = keptType
        events[nr1].inResult = edgeInResult(events[nr1], op)
        events[keptLeft].inResult = edgeInResult(events[keptLeft], op)
    }
}

// MARK: - Segment subdivision

func divideSegment(_ events: inout [BoolSweepEvent], _ queue: inout [Int],
                   _ edgeLeftIdx: Int, _ p: (Double, Double)) -> (Int, Int) {
    let edgeRightIdx = events[edgeLeftIdx].otherEvent
    let polygon = events[edgeLeftIdx].polygon

    let lIdx = events.count
    let nrIdx = lIdx + 1
    var lEvent = BoolSweepEvent(point: p, isLeft: false, polygon: polygon)
    lEvent.otherEvent = edgeLeftIdx
    var nrEvent = BoolSweepEvent(point: p, isLeft: true, polygon: polygon)
    nrEvent.otherEvent = edgeRightIdx
    events.append(lEvent)
    events.append(nrEvent)

    events[edgeLeftIdx].otherEvent = lIdx
    events[edgeRightIdx].otherEvent = nrIdx

    queuePush(&queue, events, lIdx)
    queuePush(&queue, events, nrIdx)

    return (lIdx, nrIdx)
}

// MARK: - Field computation

func computeFields(_ events: inout [BoolSweepEvent], _ status: [Int], _ pos: Int) {
    let idx = status[pos]
    if pos == 0 {
        events[idx].inOut = false
        events[idx].otherInOut = true
        return
    }
    let prev = status[pos - 1]
    let prevPolygon = events[prev].polygon
    let curPolygon = events[idx].polygon
    if curPolygon == prevPolygon {
        events[idx].inOut = !events[prev].inOut
        events[idx].otherInOut = events[prev].otherInOut
    } else {
        let prevVertical = events[prev].point.0 == events[events[prev].otherEvent].point.0
        events[idx].inOut = !events[prev].otherInOut
        events[idx].otherInOut = prevVertical ? !events[prev].inOut : events[prev].inOut
    }
    if events[prev].inResult {
        events[idx].prevInResult = prev
    } else {
        events[idx].prevInResult = events[prev].prevInResult
    }
}

// MARK: - Connection step

func connectEdges(_ events: [BoolSweepEvent], _ order: [Int]) -> BoolPolygonSet {
    var inResultList: [Int] = []
    for idx in order {
        let e = events[idx]
        let isIn = e.isLeft ? e.inResult : events[e.otherEvent].inResult
        if isIn {
            inResultList.append(idx)
        }
    }

    var posInResult: [Int: Int] = [:]
    posInResult.reserveCapacity(inResultList.count)
    for (i, idx) in inResultList.enumerated() {
        posInResult[idx] = i
    }

    var visited = [Bool](repeating: false, count: inResultList.count)
    var result: BoolPolygonSet = []

    for start in 0..<inResultList.count {
        if visited[start] { continue }
        var ring: BoolRing = []
        var i = start
        while true {
            visited[i] = true
            let curEvent = inResultList[i]
            ring.append(events[curEvent].point)
            let partner = events[curEvent].otherEvent
            guard let partnerPos = posInResult[partner] else { break }
            visited[partnerPos] = true
            let partnerPoint = events[partner].point
            var next: Int? = nil
            var j = partnerPos + 1
            while j < inResultList.count {
                if !visited[j] {
                    if events[inResultList[j]].point == partnerPoint {
                        next = j; break
                    }
                    if events[inResultList[j]].point.0 > partnerPoint.0 { break }
                }
                j += 1
            }
            if next == nil {
                var k = partnerPos
                while k > 0 {
                    k -= 1
                    if !visited[k] {
                        if events[inResultList[k]].point == partnerPoint {
                            next = k; break
                        }
                        if events[inResultList[k]].point.0 < partnerPoint.0 { break }
                    }
                }
            }
            guard let n = next else { break }
            i = n
            if i == start { break }
        }
        if ring.count >= 3 {
            result.append(ring)
        }
    }

    return result
}
