import Foundation

/// Geometry helpers for precise hit-testing.
///
/// Pure-geometry functions used by the controller for marquee selection,
/// element intersection tests, and control-point queries.  These do not
/// depend on the document model — only on element geometry.

// MARK: - Primitive geometry

public func pointInRect(_ px: Double, _ py: Double,
                        _ rx: Double, _ ry: Double, _ rw: Double, _ rh: Double) -> Bool {
    rx <= px && px <= rx + rw && ry <= py && py <= ry + rh
}

private func cross(_ ox: Double, _ oy: Double, _ ax: Double, _ ay: Double,
                   _ bx: Double, _ by: Double) -> Double {
    (ax - ox) * (by - oy) - (ay - oy) * (bx - ox)
}

private func onSegment(_ px1: Double, _ py1: Double, _ px2: Double, _ py2: Double,
                       _ qx: Double, _ qy: Double) -> Bool {
    min(px1, px2) <= qx && qx <= max(px1, px2) &&
    min(py1, py2) <= qy && qy <= max(py1, py2)
}

public func segmentsIntersect(_ ax1: Double, _ ay1: Double, _ ax2: Double, _ ay2: Double,
                              _ bx1: Double, _ by1: Double, _ bx2: Double, _ by2: Double) -> Bool {
    let d1 = cross(bx1, by1, bx2, by2, ax1, ay1)
    let d2 = cross(bx1, by1, bx2, by2, ax2, ay2)
    let d3 = cross(ax1, ay1, ax2, ay2, bx1, by1)
    let d4 = cross(ax1, ay1, ax2, ay2, bx2, by2)
    if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
       ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return true }
    let eps = 1e-10
    if abs(d1) < eps && onSegment(bx1, by1, bx2, by2, ax1, ay1) { return true }
    if abs(d2) < eps && onSegment(bx1, by1, bx2, by2, ax2, ay2) { return true }
    if abs(d3) < eps && onSegment(ax1, ay1, ax2, ay2, bx1, by1) { return true }
    if abs(d4) < eps && onSegment(ax1, ay1, ax2, ay2, bx2, by2) { return true }
    return false
}

public func segmentIntersectsRect(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
                                  _ rx: Double, _ ry: Double, _ rw: Double, _ rh: Double) -> Bool {
    if pointInRect(x1, y1, rx, ry, rw, rh) { return true }
    if pointInRect(x2, y2, rx, ry, rw, rh) { return true }
    let edges: [(Double, Double, Double, Double)] = [
        (rx, ry, rx + rw, ry),
        (rx + rw, ry, rx + rw, ry + rh),
        (rx + rw, ry + rh, rx, ry + rh),
        (rx, ry + rh, rx, ry),
    ]
    return edges.contains { e in
        segmentsIntersect(x1, y1, x2, y2, e.0, e.1, e.2, e.3)
    }
}

public func rectsIntersect(_ ax: Double, _ ay: Double, _ aw: Double, _ ah: Double,
                           _ bx: Double, _ by: Double, _ bw: Double, _ bh: Double) -> Bool {
    ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by
}

public func circleIntersectsRect(_ cx: Double, _ cy: Double, _ r: Double,
                                 _ rx: Double, _ ry: Double, _ rw: Double, _ rh: Double,
                                 filled: Bool) -> Bool {
    let closestX = max(rx, min(cx, rx + rw))
    let closestY = max(ry, min(cy, ry + rh))
    let distSq = pow(cx - closestX, 2) + pow(cy - closestY, 2)
    if !filled {
        let corners = [(rx, ry), (rx + rw, ry), (rx + rw, ry + rh), (rx, ry + rh)]
        let maxDistSq = corners.map { pow(cx - $0.0, 2) + pow(cy - $0.1, 2) }.max()!
        return distSq <= r * r && r * r <= maxDistSq
    }
    return distSq <= r * r
}

public func ellipseIntersectsRect(_ cx: Double, _ cy: Double, _ erx: Double, _ ery: Double,
                                  _ rx: Double, _ ry: Double, _ rw: Double, _ rh: Double,
                                  filled: Bool) -> Bool {
    if erx == 0 || ery == 0 { return false }
    return circleIntersectsRect(cx / erx, cy / ery, 1.0,
                                rx / erx, ry / ery, rw / erx, rh / ery,
                                filled: filled)
}

/// Squared distance from a point to the CLOSEST point of a segment (the
/// segment as a solid one-dimensional set, so the foot of the perpendicular
/// when it falls inside, an endpoint otherwise).
private func pointSegmentDistanceSq(_ px: Double, _ py: Double,
                                    _ x1: Double, _ y1: Double,
                                    _ x2: Double, _ y2: Double) -> Double {
    let dx = x2 - x1, dy = y2 - y1
    let lenSq = dx * dx + dy * dy
    if lenSq == 0 {
        return (px - x1) * (px - x1) + (py - y1) * (py - y1)
    }
    var t = ((px - x1) * dx + (py - y1) * dy) / lenSq
    t = max(0.0, min(1.0, t))
    let qx = x1 + t * dx, qy = y1 + t * dy
    return (px - qx) * (px - qx) + (py - qy) * (py - qy)
}

/// Ellipse against an arbitrary polygonal REGION — the exact counterpart of
/// `ellipseIntersectsRect`, and the reason the ellipse survives a transform.
///
/// Same normalisation as the rect form: divide every x by rx and every y by
/// ry, which carries the ellipse onto the UNIT CIRCLE and the polygon onto an
/// affine image of itself.  Point-in-polygon and min/max are all preserved by
/// that map, so the answer is the circle's.
///
/// Over a connected region the distance-to-centre function attains every value
/// between its minimum and its maximum, so:
///   - FILLED (the disc): hit iff the region reaches within r, i.e. `min <= 1`.
///   - UNFILLED (the outline only): hit iff the region straddles the radius,
///     i.e. `min <= 1 <= max` — a region wholly inside the outline misses, as
///     does one wholly outside.
/// The minimum is 0 when the centre is inside the polygon and otherwise the
/// nearest approach of an edge; the maximum is always attained at a vertex
/// (the region lies in the convex hull of its vertices and distance is convex).
/// On an axis-aligned rectangle both reduce exactly to `circleIntersectsRect`'s
/// clamped-closest-point and farthest-corner, which is what keeps the
/// transformed and untransformed answers identical.
public func ellipseIntersectsPolygon(_ cx: Double, _ cy: Double, _ erx: Double, _ ery: Double,
                                     _ poly: [(Double, Double)], filled: Bool) -> Bool {
    if erx == 0 || ery == 0 { return false }
    if poly.isEmpty { return false }

    let ncx = cx / erx, ncy = cy / ery
    let p = poly.map { ($0.0 / erx, $0.1 / ery) }

    var minSq = Double.infinity
    var maxSq = 0.0
    let n = p.count
    for i in 0..<n {
        let j = (i + 1) % n
        minSq = min(minSq, pointSegmentDistanceSq(ncx, ncy, p[i].0, p[i].1, p[j].0, p[j].1))
        let dx = ncx - p[i].0, dy = ncy - p[i].1
        maxSq = max(maxSq, dx * dx + dy * dy)
    }
    if pointInPolygon(ncx, ncy, p) { minSq = 0.0 }

    if filled { return minSq <= 1.0 }
    return minSq <= 1.0 && 1.0 <= maxSq
}

// MARK: - Element-level queries

// MARK: - RESOLVEDHIT: the kinds whose geometry lives behind a resolver
//
// `reference` (a symbol instance), `recorded` and `generated` hold no
// coordinates — only an id, a recipe, or a concept name. Their geometry exists
// only once something resolves that, which is why `bounds` is a hard-coded
// zero box for all three and `segmentsOfElement` returns [].
//
// The canvas resolves them, so an instance is DRAWN. Hit-testing did not, so an
// instance was not SELECTABLE. Each entry point below therefore comes in two
// forms, mirroring Rust's `algorithms/hit_test.rs` name for name:
//
//   * the plain form — the shared cross-language verb, resolver-less. It keeps
//     answering false for these three kinds, and that is CORRECT for the
//     question it is asked: with no document behind it a reference is
//     dangling, and a dangling reference evaluates to empty
//     (REFERENCE_GRAPH.md §3).
//   * the `...With(resolver:)` form — what document-level callers use.
//
// Spelled as two NAMES rather than one defaulted parameter, in both ports, so
// a caller that wants the resolving answer cannot get the narrow one by
// omission.

/// Append `ring`'s edges (closed) to `segs`. The shared tail of every arm that
/// turns an evaluated ring set into hit-test segments, so the resolver-needing
/// kinds and `compoundShape` cannot drift in how they close a ring.
private func pushRingSegments(_ ring: [(Double, Double)],
                              _ segs: inout [(Double, Double, Double, Double)]) {
    guard ring.count >= 2 else { return }
    for i in 0..<ring.count - 1 {
        segs.append((ring[i].0, ring[i].1, ring[i+1].0, ring[i+1].1))
    }
    let last = ring.last!, first = ring.first!
    segs.append((last.0, last.1, first.0, first.1))
}

/// `elem.bounds`, except for the resolver-needing kinds, whose own `bounds` is
/// a hard-coded zero box — for those, the bounding box of the RESOLVED rings.
/// Used by the filled arms, which compare against a bounding box: an instance
/// carrying a paint override took those arms and compared against a degenerate
/// box at the origin.
private func resolvedBounds(_ elem: Element, _ resolver: ElementResolver) -> BBox {
    // Not a resolver-backed kind: it carries its own coordinates. NOTE this is
    // the STROKE-INFLATED box, which is what every filled arm here compares
    // against; the geometric twin lives in `Element.swift` and must stay
    // separate (swapping one for the other would silently change hit-testing
    // for every stroked shape).
    guard let rings = resolvedRings(elem, resolver) else { return elem.bounds }
    // Resolved, but to nothing (dangling / cyclic / unknown). A zero box at the
    // ORIGIN would be a false claim about where it is; report what `bounds`
    // reports, so the genuinely-empty case is unchanged.
    return ringsBBox(rings) ?? elem.bounds
}

public func segmentsOfElement(_ elem: Element) -> [(Double, Double, Double, Double)] {
    segmentsOfElementWith(elem, NullResolver())
}

/// ``segmentsOfElement(_:)``, resolving live kinds through `resolver`.
public func segmentsOfElementWith(_ elem: Element,
                                  _ resolver: ElementResolver) -> [(Double, Double, Double, Double)] {
    if let rings = resolvedRings(elem, resolver) {
        var segs: [(Double, Double, Double, Double)] = []
        for ring in rings { pushRingSegments(ring, &segs) }
        return segs
    }
    switch elem {
    case .line(let v):
        return [(v.x1, v.y1, v.x2, v.y2)]
    case .rect(let v):
        let x = v.x, y = v.y, w = v.width, h = v.height
        return [(x, y, x+w, y), (x+w, y, x+w, y+h),
                (x+w, y+h, x, y+h), (x, y+h, x, y)]
    case .polyline(let v):
        guard v.points.count >= 2 else { return [] }
        return (0..<v.points.count-1).map { i in
            (v.points[i].0, v.points[i].1, v.points[i+1].0, v.points[i+1].1)
        }
    case .polygon(let v):
        guard v.points.count >= 2 else { return [] }
        var segs = (0..<v.points.count-1).map { i in
            (v.points[i].0, v.points[i].1, v.points[i+1].0, v.points[i+1].1)
        }
        let last = v.points.last!, first = v.points.first!
        segs.append((last.0, last.1, first.0, first.1))
        return segs
    case .path(let v):
        let pts = flattenPathCommands(v.d)
        guard pts.count >= 2 else { return [] }
        return (0..<pts.count-1).map { i in
            (pts[i].0, pts[i].1, pts[i+1].0, pts[i+1].1)
        }
    // A compound shape's segments are the edges of EVERY evaluated ring,
    // each ring closed — so a hole's boundary is a boundary and the hole's
    // interior is not part of the shape. Mirrors Rust's `Element::Live`
    // arm (algorithms/hit_test.rs). The other live variants contribute no
    // segments there either.
    case .live(let v):
        switch v {
        case .compoundShape(let cs):
            var segs: [(Double, Double, Double, Double)] = []
            for ring in cs.evaluate(precision: DEFAULT_PRECISION) {
                pushRingSegments(ring, &segs)
            }
            return segs
        // Unreachable from `segmentsOfElementWith`: `resolvedRings` takes
        // these three first, whatever the resolver. Reached only through the
        // resolver-less verb, where empty is the right answer — and left as an
        // explicit case rather than folded into `default` so a fifth live kind
        // has to state which side of that line it falls on.
        case .reference, .recorded, .generated:
            return []
        }
    default:
        return []
    }
}

// MARK: - The two paths, and why they must answer alike
//
// TRANSFORM BLINDNESS, and the repair (2026-07-30).
//
// `2bb65ca6` (2026-04-10, "All: transform-aware hit-testing for marquee and
// polygon selection") taught these two entry points about transforms, and in
// doing so it BROKE them.  Before it, a marquee always reached
// `elementIntersectsRectLocal`.  After it, an element carrying a transform has
// its selection geometry inverse-mapped into local space and is routed to
// `elementIntersectsPolygonLocal` instead — the marquee is no longer a
// rectangle down there, so a rectangle-shaped test cannot serve it.  The
// routing is right.  What was never checked is that the SECOND path covered
// every kind the FIRST one did.  It did not:
//
//   - Ellipse had a real arm on the rect path (`ellipseIntersectsRect`) and
//     NO arm on the polygon path.  It fell through to a body fed by
//     `segmentsOfElement`, which yields nothing for an ellipse, so a
//     transformed filled ellipse answered true only if a marquee corner
//     happened to land in its bounding box (true where the paint is not, false
//     where a marquee ENCLOSES the whole shape), and a transformed stroke-only
//     ellipse answered false always.  It is now `ellipseIntersectsPolygon`.
//   - Filled polygon / path / live had the "the region lies inside my paint"
//     clause on the POLYGON path and not on the rect path — the inverse
//     omission, in the other direction.  A marquee dropped strictly inside a
//     filled shape with no transform selected nothing.
//
// The class is a COVERAGE-ASYMMETRY defect: a fix that adds a second dispatch
// path for a new case makes that path the ONLY path for the case, and every
// kind the new switch forgets is silently downgraded — no compiler error, no
// crash, just a wrong answer for exactly the elements the fix was meant to
// serve.  It is the hit-test cousin of the Swift copy-site omission class.
// The standing guard is the control pair: for every kind, the same element and
// the same region with `transform: nil` and with `transform: identity` must
// agree, because identity moves no point.  Those pairs live in
// test_fixtures/algorithms/hit_test.json and are shared with the Rust port.
//
// Read the two `*_Local` functions below as one specification in two dialects.
// A change to an arm in either is a change owed to the other.

public func elementIntersectsRect(_ elem: Element,
                                  _ rx: Double, _ ry: Double, _ rw: Double, _ rh: Double) -> Bool {
    elementIntersectsRectWith(elem, rx, ry, rw, rh, NullResolver())
}

/// ``elementIntersectsRect(_:_:_:_:_:)``, resolving live kinds through `resolver`.
public func elementIntersectsRectWith(_ elem: Element,
                                      _ rx: Double, _ ry: Double, _ rw: Double, _ rh: Double,
                                      _ resolver: ElementResolver) -> Bool {
    if let t = elem.transform {
        guard let inv = t.inverse() else { return false }
        let corners = [
            inv.applyPoint(rx, ry),
            inv.applyPoint(rx + rw, ry),
            inv.applyPoint(rx + rw, ry + rh),
            inv.applyPoint(rx, ry + rh),
        ]
        return elementIntersectsPolygonLocal(elem, corners, resolver)
    }
    return elementIntersectsRectLocal(elem, rx, ry, rw, rh, resolver)
}

/// "The selection region lies inside my paint", the clause a filled element
/// needs when nothing of it crosses the region and nothing of the region
/// touches its outline — a small marquee dropped in the middle of a big filled
/// shape.  This is the rect-path mirror of the polygon path's
/// `poly.contains { pointInRect($0, bounds) }`: same test, same bounding-box
/// approximation of the fill, region corners instead of lasso vertices.  Keep
/// the two spelled the same way; they are one clause with two callers.
private func regionCornerInsideBounds(_ elem: Element,
                                      _ rx: Double, _ ry: Double, _ rw: Double, _ rh: Double,
                                      _ resolver: ElementResolver) -> Bool {
    let b = resolvedBounds(elem, resolver)
    let corners = [(rx, ry), (rx + rw, ry), (rx + rw, ry + rh), (rx, ry + rh)]
    return corners.contains { pointInRect($0.0, $0.1, b.x, b.y, b.width, b.height) }
}

private func elementIntersectsRectLocal(_ elem: Element,
                                        _ rx: Double, _ ry: Double, _ rw: Double, _ rh: Double,
                                        _ resolver: ElementResolver) -> Bool {
    switch elem {
    case .line(let v):
        return segmentIntersectsRect(v.x1, v.y1, v.x2, v.y2, rx, ry, rw, rh)
    case .rect(let v):
        if v.fill != nil {
            return rectsIntersect(v.x, v.y, v.width, v.height, rx, ry, rw, rh)
        }
        return segmentsOfElementWith(elem, resolver).contains { s in
            segmentIntersectsRect(s.0, s.1, s.2, s.3, rx, ry, rw, rh)
        }
    case .ellipse(let v):
        return ellipseIntersectsRect(v.cx, v.cy, v.rx, v.ry, rx, ry, rw, rh, filled: v.fill != nil)
    // A filled polyline paints as though its last point were joined back to
    // its first, so its painted area is not the open run the segments
    // describe: [[0,0],[0,100],[100,100],[100,0]] strokes as a U but fills as
    // the whole 100x100 square. The bounding box is the arm the reference
    // (jas/algorithms/hit_test.py, `case Polyline()`) uses; Rust's
    // `Element::Polyline` arm now matches. It is a BOX, not a point-in-fill
    // test — an open triangle's empty bbox corner answers true.
    case .polyline(let v):
        if v.fill != nil {
            let b = resolvedBounds(elem, resolver)
            return rectsIntersect(b.x, b.y, b.width, b.height, rx, ry, rw, rh)
        }
        return segmentsOfElementWith(elem, resolver).contains { s in
            segmentIntersectsRect(s.0, s.1, s.2, s.3, rx, ry, rw, rh)
        }
    case .polygon(let v):
        if v.fill != nil {
            if v.points.contains(where: { pointInRect($0.0, $0.1, rx, ry, rw, rh) }) {
                return true
            }
            if regionCornerInsideBounds(elem, rx, ry, rw, rh, resolver) { return true }
            return segmentsOfElementWith(elem, resolver).contains { s in
                segmentIntersectsRect(s.0, s.1, s.2, s.3, rx, ry, rw, rh)
            }
        }
        return segmentsOfElementWith(elem, resolver).contains { s in
            segmentIntersectsRect(s.0, s.1, s.2, s.3, rx, ry, rw, rh)
        }
    case .path(let v):
        let segs = segmentsOfElementWith(elem, resolver)
        if v.fill != nil {
            let endpoints = segs.flatMap { [(s: $0.0, t: $0.1), (s: $0.2, t: $0.3)] }
            if endpoints.contains(where: { pointInRect($0.s, $0.t, rx, ry, rw, rh) }) {
                return true
            }
            if regionCornerInsideBounds(elem, rx, ry, rw, rh, resolver) { return true }
            return segs.contains { s in
                segmentIntersectsRect(s.0, s.1, s.2, s.3, rx, ry, rw, rh)
            }
        }
        return segs.contains { s in
            segmentIntersectsRect(s.0, s.1, s.2, s.3, rx, ry, rw, rh)
        }
    case .text:
        let b = resolvedBounds(elem, resolver)
        return rectsIntersect(b.x, b.y, b.width, b.height, rx, ry, rw, rh)
    // A live element hit-tests against its own segments, not its bounding
    // box — otherwise a marquee inside a compound shape's hole selects it.
    // Same body as the `.path` arm, reading the fill generically. Mirrors
    // Rust's catch-all arm, which Element::Live falls into.
    case .live:
        let segs = segmentsOfElementWith(elem, resolver)
        if elem.fill != nil {
            let endpoints = segs.flatMap { [(s: $0.0, t: $0.1), (s: $0.2, t: $0.3)] }
            if endpoints.contains(where: { pointInRect($0.s, $0.t, rx, ry, rw, rh) }) {
                return true
            }
            if regionCornerInsideBounds(elem, rx, ry, rw, rh, resolver) { return true }
        }
        return segs.contains { s in
            segmentIntersectsRect(s.0, s.1, s.2, s.3, rx, ry, rw, rh)
        }
    default:
        let b = resolvedBounds(elem, resolver)
        return rectsIntersect(b.x, b.y, b.width, b.height, rx, ry, rw, rh)
    }
}

// MARK: - Polygon geometry

public func pointInPolygon(_ px: Double, _ py: Double, _ poly: [(Double, Double)]) -> Bool {
    let n = poly.count
    if n < 3 { return false }
    var inside = false
    var j = n - 1
    for i in 0..<n {
        let (xi, yi) = poly[i]
        let (xj, yj) = poly[j]
        if ((yi > py) != (yj > py)) && (px < (xj - xi) * (py - yi) / (yj - yi) + xi) {
            inside = !inside
        }
        j = i
    }
    return inside
}

public func segmentIntersectsPolygon(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
                                     _ poly: [(Double, Double)]) -> Bool {
    if pointInPolygon(x1, y1, poly) || pointInPolygon(x2, y2, poly) { return true }
    let n = poly.count
    for i in 0..<n {
        let j = (i + 1) % n
        if segmentsIntersect(x1, y1, x2, y2, poly[i].0, poly[i].1, poly[j].0, poly[j].1) {
            return true
        }
    }
    return false
}

public func elementIntersectsPolygon(_ elem: Element, _ poly: [(Double, Double)]) -> Bool {
    elementIntersectsPolygonWith(elem, poly, NullResolver())
}

/// ``elementIntersectsPolygon(_:_:)``, resolving live kinds through `resolver`.
public func elementIntersectsPolygonWith(_ elem: Element, _ poly: [(Double, Double)],
                                         _ resolver: ElementResolver) -> Bool {
    if let t = elem.transform {
        guard let inv = t.inverse() else { return false }
        let localPoly = poly.map { inv.applyPoint($0.0, $0.1) }
        return elementIntersectsPolygonLocal(elem, localPoly, resolver)
    }
    return elementIntersectsPolygonLocal(elem, poly, resolver)
}

private func elementIntersectsPolygonLocal(_ elem: Element, _ poly: [(Double, Double)],
                                           _ resolver: ElementResolver) -> Bool {
    switch elem {
    case .line(let v):
        return segmentIntersectsPolygon(v.x1, v.y1, v.x2, v.y2, poly)
    case .rect(let v):
        if v.fill != nil {
            let corners = [(v.x, v.y), (v.x + v.width, v.y),
                           (v.x + v.width, v.y + v.height), (v.x, v.y + v.height)]
            if corners.contains(where: { pointInPolygon($0.0, $0.1, poly) }) { return true }
            if poly.contains(where: { pointInRect($0.0, $0.1, v.x, v.y, v.width, v.height) }) { return true }
            return segmentsOfElementWith(elem, resolver).contains { s in
                segmentIntersectsPolygon(s.0, s.1, s.2, s.3, poly)
            }
        }
        return segmentsOfElementWith(elem, resolver).contains { s in
            segmentIntersectsPolygon(s.0, s.1, s.2, s.3, poly)
        }
    // The ellipse is CURVED, so it has no segments and never had any: the
    // generic segments-plus-bounding-box body this arm used to carry was an
    // empty suit.  `ellipseIntersectsPolygon` is the true test, and the exact
    // counterpart of the rect path's `ellipseIntersectsRect` — see the note
    // above `elementIntersectsRect` for how the two came to disagree.
    case .ellipse(let v):
        return ellipseIntersectsPolygon(v.cx, v.cy, v.rx, v.ry, poly, filled: v.fill != nil)
    case .polyline(let v):
        if v.fill != nil {
            let segs = segmentsOfElementWith(elem, resolver)
            let endpoints = segs.flatMap { [(s: $0.0, t: $0.1), (s: $0.2, t: $0.3)] }
            if endpoints.contains(where: { pointInPolygon($0.s, $0.t, poly) }) { return true }
            if poly.contains(where: { let b = resolvedBounds(elem, resolver); return pointInRect($0.0, $0.1, b.x, b.y, b.width, b.height) }) { return true }
            return segs.contains { s in segmentIntersectsPolygon(s.0, s.1, s.2, s.3, poly) }
        }
        return segmentsOfElementWith(elem, resolver).contains { s in
            segmentIntersectsPolygon(s.0, s.1, s.2, s.3, poly)
        }
    case .polygon(let v):
        if v.fill != nil {
            if v.points.contains(where: { pointInPolygon($0.0, $0.1, poly) }) { return true }
            if poly.contains(where: { let b = resolvedBounds(elem, resolver); return pointInRect($0.0, $0.1, b.x, b.y, b.width, b.height) }) { return true }
            return segmentsOfElementWith(elem, resolver).contains { s in
                segmentIntersectsPolygon(s.0, s.1, s.2, s.3, poly)
            }
        }
        return segmentsOfElementWith(elem, resolver).contains { s in
            segmentIntersectsPolygon(s.0, s.1, s.2, s.3, poly)
        }
    case .path(let v):
        let segs = segmentsOfElementWith(elem, resolver)
        if v.fill != nil {
            let endpoints = segs.flatMap { [(s: $0.0, t: $0.1), (s: $0.2, t: $0.3)] }
            if endpoints.contains(where: { pointInPolygon($0.s, $0.t, poly) }) { return true }
            if poly.contains(where: { let b = resolvedBounds(elem, resolver); return pointInRect($0.0, $0.1, b.x, b.y, b.width, b.height) }) { return true }
            return segs.contains { s in segmentIntersectsPolygon(s.0, s.1, s.2, s.3, poly) }
        }
        return segs.contains { s in
            segmentIntersectsPolygon(s.0, s.1, s.2, s.3, poly)
        }
    // A live element hit-tests against its own segments, not its bounding
    // box — otherwise a lasso inside a compound shape's hole selects it.
    // Same body as the `.path` arm, reading the fill generically. Mirrors
    // Rust's catch-all arm, which Element::Live falls into (its bbox arm
    // lists only Text | TextPath | Group | Layer).
    case .live:
        let segs = segmentsOfElementWith(elem, resolver)
        if elem.fill != nil {
            let endpoints = segs.flatMap { [(s: $0.0, t: $0.1), (s: $0.2, t: $0.3)] }
            if endpoints.contains(where: { pointInPolygon($0.s, $0.t, poly) }) { return true }
            if poly.contains(where: { let b = resolvedBounds(elem, resolver); return pointInRect($0.0, $0.1, b.x, b.y, b.width, b.height) }) { return true }
        }
        return segs.contains { s in segmentIntersectsPolygon(s.0, s.1, s.2, s.3, poly) }
    case .text, .textPath, .group, .layer:
        let b = resolvedBounds(elem, resolver)
        let corners = [(b.x, b.y), (b.x + b.width, b.y),
                       (b.x + b.width, b.y + b.height), (b.x, b.y + b.height)]
        if corners.contains(where: { pointInPolygon($0.0, $0.1, poly) }) { return true }
        if poly.contains(where: { pointInRect($0.0, $0.1, b.x, b.y, b.width, b.height) }) { return true }
        let rectSegs = [(b.x, b.y, b.x + b.width, b.y),
                        (b.x + b.width, b.y, b.x + b.width, b.y + b.height),
                        (b.x + b.width, b.y + b.height, b.x, b.y + b.height),
                        (b.x, b.y + b.height, b.x, b.y)]
        return rectSegs.contains { s in segmentIntersectsPolygon(s.0, s.1, s.2, s.3, poly) }
    }
}
