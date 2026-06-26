/// Selection → Properties panel X/Y/W/H mirror (decision-5 Part B.1).
///
/// The Properties panel shows the selection's EVALUATED bounding box — each
/// element's geometric bbox mapped through its own transform and every ancestor
/// (group / layer) transform, then axis-aligned and unioned. This is the
/// effective geometry after any live scale / rotate / shear transform, in
/// document points. Mirrors the Python `selection_evaluated_bounds` and the
/// selection-highlight transform chain (`selectionHandleRects`), so the panel
/// numbers match the visible selection box.
///
/// Display-only — `propertiesPanelLiveOverrides` is merged into the panel render
/// scope in DockPanelView.buildPanelCtx (pull model, like the color / stroke
/// panels), never written to the selection. Keys are prop_-prefixed to match
/// properties.yaml (avoiding a leaf-key collision with the Color panel's y / h
/// in renderers that share one override map).

import Foundation

private func propChildren(_ e: Element) -> [Element] {
    switch e {
    case .group(let g): return g.children
    case .layer(let l): return l.children
    default: return []
    }
}

/// Document-space AABB of the element at `path` (its own + ancestor transforms
/// folded into the geometric-bounds corners). `nil` when `path` does not resolve.
func elementEvaluatedBBox(_ doc: Document, _ path: ElementPath) -> BBox? {
    guard !path.isEmpty, path[0] < doc.layers.count else { return nil }
    var node: Element = .layer(doc.layers[path[0]])
    var ancestors: [Transform?] = []  // outermost (layer) first
    if path.count > 1 {
        ancestors.append(node.transform)
        for idx in path[1..<path.count - 1] {
            let kids = propChildren(node)
            guard idx < kids.count else { return nil }
            node = kids[idx]
            ancestors.append(node.transform)
        }
        let kids = propChildren(node)
        guard let last = path.last, last < kids.count else { return nil }
        node = kids[last]
    }
    let b = node.geometricBounds
    // Apply innermost-first: the element's own transform, then each ancestor
    // outward (layer last) — matching the rendered combined CTM.
    let chain: [Transform?] = [node.transform] + ancestors.reversed()
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    let x0 = b.x, y0 = b.y
    let x1 = b.x + b.width, y1 = b.y + b.height
    let corners: [(Double, Double)] = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    for (cx, cy) in corners {
        var px = cx, py = cy
        for t in chain { if let t = t { (px, py) = t.applyPoint(px, py) } }
        minX = min(minX, px); minY = min(minY, py)
        maxX = max(maxX, px); maxY = max(maxY, py)
    }
    return (minX, minY, maxX - minX, maxY - minY)
}

/// Union AABB of every selected element's evaluated bbox, document space.
/// `(0, 0, 0, 0)` when the selection is empty or nothing resolves.
func selectionEvaluatedBounds(_ doc: Document) -> BBox {
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    var any = false
    for es in doc.selection {
        if let b = elementEvaluatedBBox(doc, es.path) {
            any = true
            minX = min(minX, b.x); minY = min(minY, b.y)
            maxX = max(maxX, b.x + b.width); maxY = max(maxY, b.y + b.height)
        }
    }
    if !any { return (0, 0, 0, 0) }
    return (minX, minY, maxX - minX, maxY - minY)
}

public func propertiesPanelLiveOverrides(model: Model) -> [String: Any] {
    let doc = model.document
    let b = selectionEvaluatedBounds(doc)
    func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    // Part B.3: rotation / opacity / blend from the FIRST selected element
    // (like the Stroke weight). Defaults 0deg / 100% / normal.
    var rotation = 0.0, opacity = 100.0, blend = "normal"
    if let first = doc.selection.first {
        let elem = doc.getElement(first.path)
        if let t = elem.transform {
            rotation = atan2(t.b, t.a) * 180.0 / .pi
        }
        opacity = elem.opacity * 100.0
        blend = elem.blendMode.rawValue
    }
    return ["prop_x": r2(b.x), "prop_y": r2(b.y),
            "prop_w": r2(b.width), "prop_h": r2(b.height),
            "prop_rotation": r2(rotation), "prop_opacity": r2(opacity),
            "prop_blend": blend]
}
