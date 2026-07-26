import Foundation

// Boolean operations on planar polygons (union, intersection,
// difference, exclusive-or). Port of jas_dioxus/src/algorithms/boolean.rs.
// See that file for the design rationale and reference papers.
//
// Data model: a `BoolPolygonSet` is a flat list of rings; a ring is a
// closed polygon expressed as a list of (x, y) vertices without the
// implicit closing vertex.
//
// THE CARRIED-RULE LAW (JYH-ratified 2026-07-26). A polygon set does
// NOT have a fill rule of its own — it carries the one its source
// declared. Rings alone are geometry, not a region: it takes a fill
// rule to say which points they enclose, and the two rules disagree on
// exactly the inter-ring cases (nested same-orientation rings are a
// hole under even-odd and a solid under non-zero; two overlapping
// same-orientation rings are a symmetric difference under even-odd and
// a union under non-zero). Neither rule is universally more natural for
// an artist — even-odd matches deliberate holes, non-zero matches
// self-crossing freehand drawing — which is why SVG and PDF put
// fill-rule ON THE PATH. jas imports and exports SVG and Path carries
// fillRule, so a rule fixed in this layer would make the boundary LIE:
// a document declaring fill-rule="nonzero" would be silently
// reinterpreted by a boolean op. Hence BoolRuledPolygonSet, which pairs
// rings with the rule that reads them, and boolCanonicalize, which
// resolves that pair into rings the rest of this file can read without
// asking. See transcripts/BOOLEAN.md, "Fill rule: the polygon set
// carries it", and the Rust twin's module docs for the full reasoning.
//
// Two corollaries, both load-bearing:
//   1. CANONICAL FORM. boolCanonicalize returns simple rings denoting
//      the same region READ UNDER EVEN-ODD, whatever rule came in — so
//      the rule is fully consumed and nothing downstream needs it. The
//      sweep takes canonical rings and emits canonical rings.
//   2. RESULTS DECLARE EVEN-ODD. Every set this file emits is declared
//      even-odd (BoolFillRule's default, and the .evenodd Path stamped
//      by Controller.applyDestructiveBoolean on multi-ring results).
//      That is deliberate for machine-made compound shapes: even-odd
//      does not depend on the sweep emitting consistent winding. A bare
//      BoolPolygonSet crossing a function boundary here therefore means
//      "even-odd, already canonical".
//
// Inputs may be self-intersecting; they are resolved as a pre-pass by
// BooleanNormalize.swift, which is where the carried rule is consumed.

// MARK: - Public types

/// A single closed ring as an array of (x, y) vertices.
public typealias BoolRing = [(Double, Double)]

/// A flat list of rings. Rings alone are geometry, not a region: which
/// points they enclose is decided by a `BoolFillRule`, which this type
/// deliberately does not fix. See the carried-rule law above.
public typealias BoolPolygonSet = [BoolRing]

/// Which fill rule reads a `BoolPolygonSet`'s rings — the thing the
/// algorithm layer must carry rather than assume. Mirrors SVG/PDF
/// `fill-rule` and the document-side `FillRule`.
public enum BoolFillRule: Equatable {
    /// SVG `fill-rule="nonzero"`. Inside iff the winding summed over
    /// ALL rings is non-zero. What a self-crossing freehand stroke
    /// means, and the SVG document default.
    case nonzero
    /// SVG `fill-rule="evenodd"`. Inside iff a ray crosses the rings an
    /// odd number of times. The DEFAULT here, because this file's own
    /// emissions are even-odd (corollary 2). That is a statement about
    /// machine-made results, never about what artwork means.
    case evenodd
}

/// The fill rule a boolean RESULT declares. Clause 4 of the
/// carried-rule law, named rather than left incidental: every emitter
/// of a multi-ring boolean result stamps THIS constant, so the choice
/// is stated in one place.
///
/// Why even-odd for machine-made compound shapes: it does not depend on
/// the sweep emitting consistent winding. A hole stays a hole even if a
/// future connection step hands its ring back wound the other way,
/// whereas a non-zero declaration would silently fill it. Artwork the
/// artist drew keeps whatever rule the artist declared — this governs
/// only what jas itself generates. Twin of Rust's RESULT_FILL_RULE.
public let boolResultFillRule: BoolFillRule = .evenodd

/// A polygon set that carries the fill rule reading it: the operand
/// type the carried-rule law calls for. Build it where the rule is
/// still known (an element's `fillRule`, an SVG attribute, a corpus
/// vector's `fill_rule`) and resolve it with `boolCanonicalize` before
/// handing rings to anything that does not take a rule.
public struct BoolRuledPolygonSet {
    public var rings: BoolPolygonSet
    public var rule: BoolFillRule

    public init(_ rings: BoolPolygonSet, rule: BoolFillRule = .evenodd) {
        self.rings = rings
        self.rule = rule
    }

    public static func evenOdd(_ rings: BoolPolygonSet) -> BoolRuledPolygonSet {
        BoolRuledPolygonSet(rings, rule: .evenodd)
    }

    public static func nonZero(_ rings: BoolPolygonSet) -> BoolRuledPolygonSet {
        BoolRuledPolygonSet(rings, rule: .nonzero)
    }

    /// This set's `boolCanonicalize`d rings.
    public var canonical: BoolPolygonSet { boolCanonicalize(self) }
}

/// Consume the carried rule: the simple rings bounding exactly the
/// region `set` denotes, read under even-odd. The ONE place a declared
/// rule is interpreted; every other function here takes canonical rings.
public func boolCanonicalize(_ set: BoolRuledPolygonSet) -> BoolPolygonSet {
    normalize(set.rings, set.rule)
}

// MARK: - Public API
//
// The four bare-BoolPolygonSet entry points read BOTH operands as
// EVEN-ODD, per the standing convention for a bare ring list. Use the
// Ruled twins whenever the operands came from a document, where the
// declared rule is known and must be honoured.

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

/// `a union b`, honouring each operand's declared fill rule.
public func booleanUnionRuled(_ a: BoolRuledPolygonSet,
                              _ b: BoolRuledPolygonSet) -> BoolPolygonSet {
    runBooleanRuled(a, b, .union)
}

/// `a intersect b`, honouring each operand's declared fill rule.
public func booleanIntersectRuled(_ a: BoolRuledPolygonSet,
                                  _ b: BoolRuledPolygonSet) -> BoolPolygonSet {
    runBooleanRuled(a, b, .intersection)
}

/// `a minus b`, honouring each operand's declared fill rule.
public func booleanSubtractRuled(_ a: BoolRuledPolygonSet,
                                 _ b: BoolRuledPolygonSet) -> BoolPolygonSet {
    runBooleanRuled(a, b, .difference)
}

/// `a xor b`, honouring each operand's declared fill rule.
public func booleanExcludeRuled(_ a: BoolRuledPolygonSet,
                                _ b: BoolRuledPolygonSet) -> BoolPolygonSet {
    runBooleanRuled(a, b, .xor)
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
    runBooleanRuled(.evenOdd(a), .evenOdd(b), op)
}

func runBooleanRuled(_ a: BoolRuledPolygonSet,
                     _ b: BoolRuledPolygonSet,
                     _ op: BoolOperation) -> BoolPolygonSet {
    // Snap-round inputs onto a grid sized as a fixed fraction of the
    // combined bounding-box diagonal.
    let aSnap: BoolPolygonSet
    let bSnap: BoolPolygonSet
    if let grid = snapGrid(a.rings, b.rings) {
        aSnap = snapRound(a.rings, grid: grid)
        bSnap = snapRound(b.rings, grid: grid)
    } else {
        aSnap = cloneNondegenerate(a.rings)
        bSnap = cloneNondegenerate(b.rings)
    }

    // Consume each operand's DECLARED fill rule (the carried-rule law):
    // resolve self-intersections and inter-ring relations into canonical
    // rings, so the sweep can keep assuming simple input rings read
    // under one rule. No-op for input that is already canonical.
    let aNorm = normalize(aSnap, a.rule)
    let bNorm = normalize(bSnap, b.rule)

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

    // Split any ring that revisits a vertex. See splitPinchedRings: the
    // walk above cannot tell which of two regions touching at a pinch
    // vertex it is on, so it produces one self-touching ring where the
    // answer is two simple ones.
    return splitPinchedRings(result)
}

/// Cut every ring that visits the same vertex twice into the separate
/// loops it really is. Port of Rust `split_pinched_rings`.
///
/// WHY THE SWEEP NEEDS THIS. connectEdges walks the result boundary
/// edge by edge, and at a vertex where two output regions touch at a
/// single point it cannot tell which region it is on: both regions'
/// edges are incident to that one vertex. So it walks into one lobe,
/// back out through the pinch, and on into the other, returning ONE
/// ring that visits the pinch twice. The region is right - area and
/// every sample point are correct - but the ring is not simple, and
/// EVERY BoolPolygonSet consumer assumes simple rings (the normalizer's
/// fast path, the even-odd renderer, the refit). EXCLUDE of two squares
/// overlapping at a corner is the canonical case: twelve vertices
/// visiting (10,5) and (5,10) twice, where the answer is two L-shapes
/// of 75 touching only at those two isolated points.
///
/// WHY IT IS EXACT. Cutting at the repeat is region-preserving by
/// construction. If a ring reads `... a, X, b ... c, X, d ...` then the
/// span from the first X up to (not including) the second is a closed
/// loop on its own - it starts and ends at X - and the remainder, with
/// the duplicate X kept once, is another. No vertex is invented, none
/// is moved, and the two loops' signed areas sum to the original's.
/// The recursion handles a ring with several pinches (EXCLUDE has two).
///
/// Order is fixed - lobe before remainder, first repeat by (j, i) - so
/// Rust and Swift emit the same rings in the same sequence, which the
/// exact-comparison corpus requires.
///
/// COST. firstRepeatedVertex is O(n) expected, and each cut removes one
/// duplicate vertex, so a ring with p pinches costs O(p * n) expected -
/// O(n^2) in the pathological limit where a constant fraction of
/// vertices is a pinch, O(n) for the overwhelmingly common p = 0 (one
/// scan, no split) and O(n) for the EXCLUDE-corner p = 2. Worth stating
/// because this runs on EVERY boolean result, including curve-flattened
/// ones with thousands of vertices; the same bound is documented on the
/// normalizer's O(E^2) arrangement.
func splitPinchedRings(_ rings: BoolPolygonSet) -> BoolPolygonSet {
    var out: BoolPolygonSet = []
    for ring in rings {
        splitPinchedRing(ring, &out)
    }
    return out
}

private func splitPinchedRing(_ ring: BoolRing, _ out: inout BoolPolygonSet) {
    if ring.count < 3 { return }
    guard let (i, j) = firstRepeatedVertex(ring) else {
        out.append(ring)
        return
    }
    // ring[i] == ring[j], i < j.
    let lobe: BoolRing = Array(ring[i..<j])
    var rest: BoolRing = Array(ring[0..<i])
    rest.append(contentsOf: ring[j...])
    splitPinchedRing(lobe, &out)
    splitPinchedRing(rest, &out)
}

/// The hash key of a vertex. Nil-able at the call site: a NaN
/// coordinate has no key, because it can never equal anything.
///
/// The key must reproduce Double == EXACTLY, and a raw bitPattern does
/// not:
///
///  * -0.0 == 0.0 is true while the bit patterns differ, so a raw key
///    would MISS a pinch. `x + 0.0` maps -0.0 to +0.0 and is the
///    identity on every other value (no rounding), which fixes it.
///  * NaN != NaN, yet two NaNs of the same payload have equal bits, so
///    a raw key would INVENT a pinch. Keeping a NaN-bearing vertex out
///    of the map entirely makes it match nothing - exactly what == does.
///
/// firstRepeatedVertexMatchesTheQuadraticScan pins both cases against
/// the scan this replaced.
struct BoolVertexKey: Hashable {
    let x: UInt64
    let y: UInt64

    init?(_ v: (Double, Double)) {
        if v.0.isNaN || v.1.isNaN { return nil }
        x = (v.0 + 0.0).bitPattern
        y = (v.1 + 0.0).bitPattern
    }
}

/// The first repeated vertex of `ring` as (i, j) with i < j and
/// ring[i] == ring[j], scanning j ascending then i ascending so the
/// choice is total and port-independent. Exact equality is the right
/// test: the sweep's vertices come from snap-rounded input and
/// arrangement splits, so a revisited vertex is bit-identical.
///
/// COST. O(n) expected, one lookup and at most one insert per vertex,
/// replacing the O(n^2) pairwise scan this used to be. That matters
/// because the post-pass runs on EVERY boolean result, and a
/// curve-flattened one carries thousands of vertices.
///
/// The map holds the FIRST index at which each distinct vertex was seen
/// (insert only when absent), and j still ascends, so the pair returned
/// is the same (smallest j that repeats, smallest i equal to it) the
/// pairwise scan chose. That identity is load-bearing: splitPinchedRing
/// cuts at this pair, and the exact-comparison corpus pins the
/// resulting ring order across both ports. jas_dioxus carries the
/// identical reduction, key canonicalization included.
///
/// Internal (not private) only so the differential test can compare it
/// against the retired scan.
func firstRepeatedVertex(_ ring: BoolRing) -> (Int, Int)? {
    var seen: [BoolVertexKey: Int] = [:]
    seen.reserveCapacity(ring.count)
    for (j, v) in ring.enumerated() {
        guard let key = BoolVertexKey(v) else { continue }
        if let i = seen[key] { return (i, j) }
        seen[key] = j
    }
    return nil
}
