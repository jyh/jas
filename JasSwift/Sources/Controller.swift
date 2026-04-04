import Foundation

/// Document controller (MVC pattern).
///
/// The Controller provides mutation operations on the Model's document.
/// Since Document is immutable (a struct), mutations produce a new
/// Document that replaces the old one in the Model.

// MARK: - Geometry helpers for precise hit-testing

private func pointInRect(_ px: Double, _ py: Double,
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

private func segmentsIntersect(_ ax1: Double, _ ay1: Double, _ ax2: Double, _ ay2: Double,
                               _ bx1: Double, _ by1: Double, _ bx2: Double, _ by2: Double) -> Bool {
    let d1 = cross(bx1, by1, bx2, by2, ax1, ay1)
    let d2 = cross(bx1, by1, bx2, by2, ax2, ay2)
    let d3 = cross(ax1, ay1, ax2, ay2, bx1, by1)
    let d4 = cross(ax1, ay1, ax2, ay2, bx2, by2)
    if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
       ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return true }
    if d1 == 0 && onSegment(bx1, by1, bx2, by2, ax1, ay1) { return true }
    if d2 == 0 && onSegment(bx1, by1, bx2, by2, ax2, ay2) { return true }
    if d3 == 0 && onSegment(ax1, ay1, ax2, ay2, bx1, by1) { return true }
    if d4 == 0 && onSegment(ax1, ay1, ax2, ay2, bx2, by2) { return true }
    return false
}

private func segmentIntersectsRect(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
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

private func rectsIntersect(_ ax: Double, _ ay: Double, _ aw: Double, _ ah: Double,
                            _ bx: Double, _ by: Double, _ bw: Double, _ bh: Double) -> Bool {
    ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by
}

private func circleIntersectsRect(_ cx: Double, _ cy: Double, _ r: Double,
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

private func ellipseIntersectsRect(_ cx: Double, _ cy: Double, _ erx: Double, _ ery: Double,
                                   _ rx: Double, _ ry: Double, _ rw: Double, _ rh: Double,
                                   filled: Bool) -> Bool {
    if erx == 0 || ery == 0 { return false }
    return circleIntersectsRect(cx / erx, cy / ery, 1.0,
                                rx / erx, ry / ery, rw / erx, rh / ery,
                                filled: filled)
}

private func segmentsOfElement(_ elem: Element) -> [(Double, Double, Double, Double)] {
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
        var segs: [(Double, Double, Double, Double)] = []
        var curX = 0.0, curY = 0.0
        for cmd in v.d {
            switch cmd {
            case .moveTo(let x, let y):
                curX = x; curY = y
            case .lineTo(let x, let y):
                segs.append((curX, curY, x, y)); curX = x; curY = y
            case .curveTo(_, _, _, _, let x, let y),
                 .smoothCurveTo(_, _, let x, let y),
                 .quadTo(_, _, let x, let y),
                 .smoothQuadTo(let x, let y):
                segs.append((curX, curY, x, y)); curX = x; curY = y
            case .arcTo(_, _, _, _, _, let x, let y):
                segs.append((curX, curY, x, y)); curX = x; curY = y
            case .closePath:
                break
            }
        }
        return segs
    default:
        return []
    }
}

private func elementIntersectsRect(_ elem: Element,
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

private func allCPs(_ elem: Element) -> Set<Int> {
    Set(0..<elem.controlPointCount)
}

public class Controller {
    public let model: JasModel

    public init(model: JasModel = JasModel()) {
        self.model = model
    }

    public var document: JasDocument {
        model.document
    }

    public func setDocument(_ document: JasDocument) {
        model.document = document
    }

    public func setTitle(_ title: String) {
        model.document = JasDocument(title: title, layers: model.document.layers)
    }

    public func addLayer(_ layer: JasLayer) {
        model.document = JasDocument(title: model.document.title, layers: model.document.layers + [layer])
    }

    public func removeLayer(at index: Int) {
        var layers = model.document.layers
        layers.remove(at: index)
        model.document = JasDocument(title: model.document.title, layers: layers)
    }

    public func addElement(_ element: Element) {
        let doc = model.document
        let idx = doc.selectedLayer
        let target = doc.layers[idx]
        let newLayer = JasLayer(name: target.name, children: target.children + [element],
                                opacity: target.opacity, transform: target.transform)
        var layers = doc.layers
        layers[idx] = newLayer
        model.document = JasDocument(title: doc.title, layers: layers, selectedLayer: idx,
                                     selection: doc.selection)
    }

    public func selectRect(x: Double, y: Double, width: Double, height: Double) {
        let doc = model.document
        var selection: Selection = []
        for (li, layer) in doc.layers.enumerated() {
            for (ci, child) in layer.children.enumerated() {
                if case .group(let g) = child {
                    let anyHit = g.children.contains { elementIntersectsRect($0, x, y, width, height) }
                    if anyHit {
                        for gi in 0..<g.children.count {
                            selection.insert(ElementSelection(path: [li, ci, gi],
                                                              controlPoints: allCPs(g.children[gi])))
                        }
                    }
                } else {
                    if elementIntersectsRect(child, x, y, width, height) {
                        selection.insert(ElementSelection(path: [li, ci],
                                                          controlPoints: allCPs(child)))
                    }
                }
            }
        }
        model.document = JasDocument(title: doc.title, layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: selection)
    }

    public func directSelectRect(x: Double, y: Double, width: Double, height: Double) {
        let doc = model.document
        var selection: Selection = []

        func check(_ path: [Int], _ elem: Element) {
            switch elem {
            case .layer(let v):
                for (i, child) in v.children.enumerated() { check(path + [i], child) }
            case .group(let v):
                for (i, child) in v.children.enumerated() { check(path + [i], child) }
            default:
                let cps = elem.controlPointPositions
                let hitCPs: Set<Int> = Set(cps.enumerated().compactMap { (i, pt) in
                    pointInRect(pt.0, pt.1, x, y, width, height) ? i : nil
                })
                let hit = !hitCPs.isEmpty || elementIntersectsRect(elem, x, y, width, height)
                if hit {
                    selection.insert(ElementSelection(path: path, controlPoints: hitCPs))
                }
            }
        }

        for (li, layer) in doc.layers.enumerated() {
            check([li], .layer(layer))
        }
        model.document = JasDocument(title: doc.title, layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: selection)
    }

    public func setSelection(_ selection: Selection) {
        let doc = model.document
        model.document = JasDocument(title: doc.title, layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: selection)
    }

    public func selectElement(_ path: ElementPath) {
        precondition(!path.isEmpty, "Path must be non-empty")
        let doc = model.document
        if path.count >= 2 {
            let parentPath = Array(path.dropLast())
            let parent = doc.getElement(parentPath)
            if case .group(let g) = parent {
                let selection: Selection = Set((0..<g.children.count).map {
                    ElementSelection(path: parentPath + [$0],
                                     controlPoints: allCPs(g.children[$0]))
                })
                model.document = JasDocument(title: doc.title, layers: doc.layers,
                                             selectedLayer: doc.selectedLayer, selection: selection)
                return
            }
        }
        let elem = doc.getElement(path)
        model.document = JasDocument(title: doc.title, layers: doc.layers,
                                     selectedLayer: doc.selectedLayer,
                                     selection: [ElementSelection(path: path,
                                                                   controlPoints: allCPs(elem))])
    }

    public func selectControlPoint(path: ElementPath, index: Int) {
        precondition(!path.isEmpty, "Path must be non-empty")
        let doc = model.document
        let es = ElementSelection(path: path, selected: true, controlPoints: [index])
        model.document = JasDocument(title: doc.title, layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: [es])
    }
}
