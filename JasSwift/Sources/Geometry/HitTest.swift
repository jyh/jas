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

// MARK: - Element-level queries

public func segmentsOfElement(_ elem: Element) -> [(Double, Double, Double, Double)] {
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
    default:
        return []
    }
}

public func allCPs(_ elem: Element) -> Set<Int> {
    Set(0..<elem.controlPointCount)
}

// TODO: This ignores the element's transform. If an element has a non-identity
// transform, its visual position differs from its raw coordinates. To fix,
// inverse-transform the selection rect into the element's local coordinate
// space before testing (inheriting transforms from parent groups).
public func elementIntersectsRect(_ elem: Element,
                                  _ rx: Double, _ ry: Double, _ rw: Double, _ rh: Double) -> Bool {
    switch elem {
    case .line(let v):
        return segmentIntersectsRect(v.x1, v.y1, v.x2, v.y2, rx, ry, rw, rh)
    case .rect(let v):
        if v.fill != nil {
            return rectsIntersect(v.x, v.y, v.width, v.height, rx, ry, rw, rh)
        }
        return segmentsOfElement(elem).contains { s in
            segmentIntersectsRect(s.0, s.1, s.2, s.3, rx, ry, rw, rh)
        }
    case .circle(let v):
        return circleIntersectsRect(v.cx, v.cy, v.r, rx, ry, rw, rh, filled: v.fill != nil)
    case .ellipse(let v):
        return ellipseIntersectsRect(v.cx, v.cy, v.rx, v.ry, rx, ry, rw, rh, filled: v.fill != nil)
    case .polyline(let v):
        if v.fill != nil {
            let b = elem.bounds
            return rectsIntersect(b.x, b.y, b.width, b.height, rx, ry, rw, rh)
        }
        return segmentsOfElement(elem).contains { s in
            segmentIntersectsRect(s.0, s.1, s.2, s.3, rx, ry, rw, rh)
        }
    case .polygon(let v):
        if v.fill != nil {
            if v.points.contains(where: { pointInRect($0.0, $0.1, rx, ry, rw, rh) }) {
                return true
            }
            return segmentsOfElement(elem).contains { s in
                segmentIntersectsRect(s.0, s.1, s.2, s.3, rx, ry, rw, rh)
            }
        }
        return segmentsOfElement(elem).contains { s in
            segmentIntersectsRect(s.0, s.1, s.2, s.3, rx, ry, rw, rh)
        }
    case .path(let v):
        let segs = segmentsOfElement(elem)
        if v.fill != nil {
            let endpoints = segs.flatMap { [(s: $0.0, t: $0.1), (s: $0.2, t: $0.3)] }
            if endpoints.contains(where: { pointInRect($0.s, $0.t, rx, ry, rw, rh) }) {
                return true
            }
            return segs.contains { s in
                segmentIntersectsRect(s.0, s.1, s.2, s.3, rx, ry, rw, rh)
            }
        }
        return segs.contains { s in
            segmentIntersectsRect(s.0, s.1, s.2, s.3, rx, ry, rw, rh)
        }
    case .text:
        let b = elem.bounds
        return rectsIntersect(b.x, b.y, b.width, b.height, rx, ry, rw, rh)
    default:
        let b = elem.bounds
        return rectsIntersect(b.x, b.y, b.width, b.height, rx, ry, rw, rh)
    }
}
