// The hit test's law: a click hits what is painted, not a bounding box.
//
// The statement is `transcripts/SELECTION_TOOL.md` § Hit test: painted
// geometry; the executable meaning is the reference's
// `workspace_interpreter/hit_law.py`, which this file mirrors function for
// function (as does jas_dioxus `interpreter/hit_law.rs`). `docHitTest` and
// `docHitTestDeep` walk the document and ask `hitLawPaintedHit` /
// `hitLawDeepHit` about each element.

import Foundation

/// How far from a painted edge a click still hits, in document units.
let HIT_TOLERANCE: Double = 3.0

/// Line segments per Bezier segment; the path flattener's own count.
private let hitCurveSteps = 20

/// Sides of the polygon that stands in for an ellipse outline.
private let hitEllipseSides = 64

/// One flattened subpath: its points and whether it is closed.
typealias HitPolyline = (points: [(Double, Double)], closed: Bool)

// MARK: - Geometry helpers

private func distToSegment(_ px: Double, _ py: Double,
                           _ ax: Double, _ ay: Double,
                           _ bx: Double, _ by: Double) -> Double {
    let dx = bx - ax, dy = by - ay
    let len2 = dx * dx + dy * dy
    if len2 == 0 { return hypot(px - ax, py - ay) }
    let t = min(1.0, max(0.0, ((px - ax) * dx + (py - ay) * dy) / len2))
    return hypot(px - (ax + t * dx), py - (ay + t * dy))
}

/// Distance to the nearest segment of any polyline.
private func distToOutline(_ px: Double, _ py: Double, _ polylines: [HitPolyline]) -> Double {
    var best = Double.infinity
    for (pts, closed) in polylines {
        let n = pts.count
        if n == 1 {
            best = min(best, hypot(px - pts[0].0, py - pts[0].1))
            continue
        }
        let last = closed ? n : max(0, n - 1)
        for i in 0..<last {
            let (ax, ay) = pts[i]
            let (bx, by) = pts[(i + 1) % n]
            best = min(best, distToSegment(px, py, ax, ay, bx, by))
        }
    }
    return best
}

/// Winding number of `ring` (implicitly closed) around the point.
private func winding(_ px: Double, _ py: Double, _ ring: [(Double, Double)]) -> Int {
    var w = 0
    let n = ring.count
    for i in 0..<n {
        let (ax, ay) = ring[i]
        let (bx, by) = ring[(i + 1) % n]
        let cross = (bx - ax) * (py - ay) - (px - ax) * (by - ay)
        if ay <= py {
            if by > py && cross > 0 { w += 1 }
        } else if by <= py && cross < 0 {
            w -= 1
        }
    }
    return w
}

private func insideRings(_ px: Double, _ py: Double, _ outline: [HitPolyline], evenOdd: Bool) -> Bool {
    var total = 0
    for (pts, _) in outline where pts.count >= 3 {
        total += winding(px, py, pts)
    }
    return evenOdd ? (total % 2 != 0) : (total != 0)
}

private func ellipsePolygon(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> [(Double, Double)] {
    (0..<hitEllipseSides).map { k in
        let a = 2.0 * Double.pi * Double(k) / Double(hitEllipseSides)
        return (cx + rx * cos(a), cy + ry * sin(a))
    }
}

/// Flatten path commands to one polyline per subpath. Unlike
/// `flattenPathCommands`, a moveTo starts a NEW polyline, so nothing is
/// drawn between one subpath's end and the next one's start. Smooth curves
/// and arcs go straight to their end point, as in the path flattener.
func hitLawPathSubpaths(_ d: [PathCommand]) -> [HitPolyline] {
    var out: [HitPolyline] = []
    var cur: [(Double, Double)] = []
    var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0
    for cmd in d {
        switch cmd {
        case .moveTo(let x, let y):
            if !cur.isEmpty { out.append((cur, false)) }
            cur = [(x, y)]
            cx = x; cy = y; sx = x; sy = y
        case .closePath:
            if !cur.isEmpty { out.append((cur, true)) }
            cur = []
            cx = sx; cy = sy
        default:
            if cur.isEmpty { cur = [(cx, cy)] }
            switch cmd {
            case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
                for i in 1...hitCurveSteps {
                    let t = Double(i) / Double(hitCurveSteps)
                    let mt = 1.0 - t
                    cur.append((
                        mt * mt * mt * cx + 3 * mt * mt * t * x1
                            + 3 * mt * t * t * x2 + t * t * t * x,
                        mt * mt * mt * cy + 3 * mt * mt * t * y1
                            + 3 * mt * t * t * y2 + t * t * t * y))
                }
            case .quadTo(let x1, let y1, let x, let y):
                for i in 1...hitCurveSteps {
                    let t = Double(i) / Double(hitCurveSteps)
                    let mt = 1.0 - t
                    cur.append((
                        mt * mt * cx + 2 * mt * t * x1 + t * t * x,
                        mt * mt * cy + 2 * mt * t * y1 + t * t * y))
                }
            default:
                // lineTo, smoothCurveTo, smoothQuadTo, arcTo
                if let (x, y) = cmd.endpoint { cur.append((x, y)) }
            }
            if let (x, y) = cmd.endpoint { cx = x; cy = y }
        }
    }
    if !cur.isEmpty { out.append((cur, false)) }
    return out
}

// MARK: - The law

/// Polylines for a leaf, or nil when the leaf is hit by its bounding box
/// instead (text, and the resolver-backed live kinds).
private func hitOutline(_ elem: Element) -> [HitPolyline]? {
    switch elem {
    case .line(let e):
        return [([(e.x1, e.y1), (e.x2, e.y2)], false)]
    case .rect(let e):
        let (x, y, w, h) = (e.x, e.y, e.width, e.height)
        return [([(x, y), (x + w, y), (x + w, y + h), (x, y + h)], true)]
    case .ellipse(let e):
        return [(ellipsePolygon(e.cx, e.cy, e.rx, e.ry), true)]
    case .polyline(let e):
        return [(e.points, false)]
    case .polygon(let e):
        return [(e.points, true)]
    case .path(let e):
        return hitLawPathSubpaths(e.d)
    case .live(.compoundShape(let cs)):
        return cs.evaluate(precision: DEFAULT_PRECISION).map { ($0, true) }
    default:
        return nil
    }
}

private func insideFill(_ elem: Element, _ outline: [HitPolyline], _ px: Double, _ py: Double) -> Bool {
    switch elem {
    case .line:
        return false
    case .rect(let e):
        return e.x <= px && px <= e.x + e.width && e.y <= py && py <= e.y + e.height
    case .ellipse(let e):
        if e.rx <= 0 || e.ry <= 0 { return false }
        let nx = (px - e.cx) / e.rx, ny = (py - e.cy) / e.ry
        return nx * nx + ny * ny <= 1.0
    case .path(let e):
        return insideRings(px, py, outline, evenOdd: e.fillRule == .evenodd)
    case .live(.compoundShape):
        return insideRings(px, py, outline, evenOdd: true)
    default:
        return insideRings(px, py, outline, evenOdd: false)
    }
}

/// Map a point from the parent's coordinates into `elem`'s own; nil when
/// the element's transform cannot be inverted.
func hitLawToLocal(_ elem: Element, _ px: Double, _ py: Double) -> (Double, Double)? {
    guard let t = elem.transform else { return (px, py) }
    guard let inv = t.inverse() else { return nil }
    return inv.applyPoint(px, py)
}

/// Whether a non-container element is hit at (px, py), given in its
/// PARENT's coordinates.
func hitLawLeafPaintedHit(_ elem: Element, _ x: Double, _ y: Double, outlineMode: Bool) -> Bool {
    guard let (px, py) = hitLawToLocal(elem, x, y) else { return false }
    guard let outline = hitOutline(elem) else {
        let b = elem.bounds
        return b.x <= px && px <= b.x + b.width && b.y <= py && py <= b.y + b.height
    }
    if outlineMode {
        return distToOutline(px, py, outline) <= HIT_TOLERANCE
    }
    let hasFill = elem.fill != nil || elem.fillGradient != nil
    if hasFill && insideFill(elem, outline, px, py) { return true }
    if let s = elem.stroke {
        let reach = s.align == .center ? s.width / 2.0 : s.width
        return distToOutline(px, py, outline) <= reach + HIT_TOLERANCE
    }
    return false
}

/// The effective visibility of `elem` under `cap`, or nil when the element
/// (and everything inside it) cannot be hit.
func hitLawBlocksHit(_ elem: Element, _ cap: Visibility) -> Visibility? {
    if elem.isLocked { return nil }
    let vis = min(cap, elem.visibility)
    return vis == .invisible ? nil : vis
}

private func hitChildren(_ elem: Element) -> [Element]? {
    switch elem {
    case .group(let g): return g.children
    case .layer(let l): return l.children
    default: return nil
    }
}

/// Whether `elem` is hit at (px, py), given in its PARENT's coordinates,
/// under the inherited visibility `cap`. A group is hit when any child is.
func hitLawPaintedHit(_ elem: Element, _ px: Double, _ py: Double, _ cap: Visibility) -> Bool {
    guard let vis = hitLawBlocksHit(elem, cap) else { return false }
    if let children = hitChildren(elem) {
        guard let (lx, ly) = hitLawToLocal(elem, px, py) else { return false }
        return children.reversed().contains { hitLawPaintedHit($0, lx, ly, vis) }
    }
    return hitLawLeafPaintedHit(elem, px, py, outlineMode: vis == .outline)
}

/// The deepest painted leaf under (px, py) inside `elem`, as a path.
/// Coordinates are in `elem`'s PARENT's space.
func hitLawDeepHit(_ elem: Element, _ path: [Int], _ px: Double, _ py: Double,
                   _ cap: Visibility) -> [Int]? {
    guard let vis = hitLawBlocksHit(elem, cap) else { return nil }
    if let children = hitChildren(elem) {
        guard let (lx, ly) = hitLawToLocal(elem, px, py) else { return nil }
        for (i, child) in children.enumerated().reversed() {
            if let r = hitLawDeepHit(child, path + [i], lx, ly, vis) { return r }
        }
        return nil
    }
    return hitLawLeafPaintedHit(elem, px, py, outlineMode: vis == .outline) ? path : nil
}
