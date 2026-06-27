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
    var rotation = 0.0, shear = 0.0, opacity = 100.0, blend = "normal"
    if let first = doc.selection.first {
        let elem = doc.getElement(first.path)
        if let t = elem.transform {
            rotation = atan2(t.b, t.a) * 180.0 / .pi
            shear = propShearAngle(t)
        }
        opacity = elem.opacity * 100.0
        blend = elem.blendMode.rawValue
    }
    return ["prop_x": r2(b.x), "prop_y": r2(b.y),
            "prop_w": r2(b.width), "prop_h": r2(b.height),
            "prop_rotation": r2(rotation), "prop_shear": r2(shear),
            "prop_opacity": r2(opacity), "prop_blend": blend]
}

// MARK: - Part B.2: editing (apply a field edit back to the selection)

/// AABB of `local`'s four corners mapped through `m`.
private func propAABB(_ local: BBox, _ m: Transform) -> BBox {
    let x0 = local.x, y0 = local.y
    let x1 = local.x + local.width, y1 = local.y + local.height
    let pts: [(Double, Double)] = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    for (px, py) in pts {
        let (x, y) = m.applyPoint(px, py)
        minX = min(minX, x); minY = min(minY, y)
        maxX = max(maxX, x); maxY = max(maxY, y)
    }
    return (minX, minY, maxX - minX, maxY - minY)
}

/// Scale local axes by (rx, ry) keeping the evaluated bbox top-left fixed.
private func propScaledTransform(_ mat: Transform, _ local: BBox,
                                 _ rx: Double, _ ry: Double) -> Transform {
    // mat.multiply(scale) applies scale first (local), then mat (M·S).
    let scaled = mat.multiply(Transform(a: rx, b: 0, c: 0, d: ry, e: 0, f: 0))
    let old = propAABB(local, mat)
    let new = propAABB(local, scaled)
    return Transform(a: scaled.a, b: scaled.b, c: scaled.c, d: scaled.d,
                     e: scaled.e + (old.x - new.x), f: scaled.f + (old.y - new.y))
}

/// Decomposed shear angle of `mat` in DEGREES (M = R·ShearX(k)·Scale).
/// 0 for any shear-free or degenerate matrix — so this agrees with the
/// rotation-only path on every existing element.
private func propShearAngle(_ mat: Transform) -> Double {
    let sx = (mat.a * mat.a + mat.b * mat.b).squareRoot()
    let det = mat.a * mat.d - mat.b * mat.c
    if sx == 0 || det == 0 { return 0 }
    let k = (mat.a * mat.c + mat.b * mat.d) / det
    return atan(k) * 180.0 / .pi
}

/// Set rotation to `deg` (keeping decomposed scale AND shear) about the
/// evaluated bbox center. Upgraded from the shear-free form: `sy` is now
/// det-based and the c/d columns carry the shear factor `k`. For `k == 0`
/// this is byte-identical to the old formula, so rotation-only behaviour
/// (and its tests) is unchanged.
private func propRotatedTransform(_ mat: Transform, _ local: BBox,
                                  _ deg: Double) -> Transform {
    let sx = (mat.a * mat.a + mat.b * mat.b).squareRoot()
    let det = mat.a * mat.d - mat.b * mat.c
    let sy = sx != 0 ? det / sx : 0
    let k = det != 0 ? (mat.a * mat.c + mat.b * mat.d) / det : 0
    let rad = deg * .pi / 180.0
    let ca = cos(rad), sa = sin(rad)
    let rotated = Transform(a: sx * ca, b: sx * sa,
                            c: sy * (k * ca - sa), d: sy * (k * sa + ca),
                            e: mat.e, f: mat.f)
    let old = propAABB(local, mat)
    let new = propAABB(local, rotated)
    let ocx = old.x + old.width / 2, ocy = old.y + old.height / 2
    let ncx = new.x + new.width / 2, ncy = new.y + new.height / 2
    return Transform(a: rotated.a, b: rotated.b, c: rotated.c, d: rotated.d,
                     e: rotated.e + (ocx - ncx), f: rotated.f + (ocy - ncy))
}

/// Set shear to `deg` (keeping decomposed rotation AND scale) about the
/// evaluated bbox center — the single-object counterpart of
/// `shear_about_pivot` for the group path.
private func propShearedTransform(_ mat: Transform, _ local: BBox,
                                  _ deg: Double) -> Transform {
    let sx = (mat.a * mat.a + mat.b * mat.b).squareRoot()
    if sx == 0 { return mat }
    let theta = atan2(mat.b, mat.a)
    let det = mat.a * mat.d - mat.b * mat.c
    let sy = det / sx
    let k = tan(deg * .pi / 180.0)
    let ct = cos(theta), st = sin(theta)
    let sheared = Transform(a: sx * ct, b: sx * st,
                            c: sy * (k * ct - st), d: sy * (k * st + ct),
                            e: mat.e, f: mat.f)
    let old = propAABB(local, mat)
    let new = propAABB(local, sheared)
    let ocx = old.x + old.width / 2, ocy = old.y + old.height / 2
    let ncx = new.x + new.width / 2, ncy = new.y + new.height / 2
    return Transform(a: sheared.a, b: sheared.b, c: sheared.c, d: sheared.d,
                     e: sheared.e + (ocx - ncx), f: sheared.f + (ocy - ncy))
}

/// Apply a Properties-panel field edit to the selection (decision-5 Part B.2):
/// x/y move (any selection); w/h scale local axes (single); rotation absolute
/// about the bbox center (single); opacity/blend set on every selected element.
public func applyPropertiesField(controller: Controller, field: String, value: Any?) {
    let model = controller.model
    let doc = model.document
    guard !doc.selection.isEmpty else { return }
    let bbox = selectionEvaluatedBounds(doc)
    func num() -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
    switch field {
    case "x":
        if let v = num() { controller.moveSelection(dx: v - bbox.x, dy: 0) }
    case "y":
        if let v = num() { controller.moveSelection(dx: 0, dy: v - bbox.y) }
    case "opacity":
        if let v = num() {
            let op = max(0, min(100, v)) / 100
            var d = doc
            for es in doc.selection {
                d = d.replaceElement(es.path, with: doc.getElement(es.path).withCommon(opacity: op))
            }
            model.editDocument(d)
        }
    case "blend":
        if let s = value as? String, let bm = BlendMode(rawValue: s) {
            var d = doc
            for es in doc.selection {
                d = d.replaceElement(es.path, with: doc.getElement(es.path).withCommon(blendMode: bm))
            }
            model.editDocument(d)
        }
    case "w", "h", "rotation", "shear":
        guard !doc.selection.isEmpty else { return }
        // Constrain-proportions: when on, W/H scale BOTH axes by the ratio.
        let constrain = (model.stateStore.getPanel("properties_panel_content",
                                                   "prop_constrain") as? Bool) ?? false
        if doc.selection.count == 1, let es = doc.selection.first {
            // SINGLE: local-axes scale / absolute rotation about its center.
            let elem = doc.getElement(es.path)
            let local = elem.geometricBounds
            let mat = elem.transform ?? .identity
            let newT: Transform
            switch field {
            case "w":
                guard let v = num(), bbox.width > 0 else { return }
                let r = v / bbox.width
                newT = propScaledTransform(mat, local, r, constrain ? r : 1)
            case "h":
                guard let v = num(), bbox.height > 0 else { return }
                let r = v / bbox.height
                newT = propScaledTransform(mat, local, constrain ? r : 1, r)
            case "shear":
                guard let v = num() else { return }
                newT = propShearedTransform(mat, local, v)
            default:
                guard let v = num() else { return }
                newT = propRotatedTransform(mat, local, v)
            }
            model.editDocument(doc.replaceElement(es.path, with: elem.withCommon(transform: newT)))
            return
        }
        // MULTI: transform the whole selection as a group about its bbox
        // (doc-space). W/H scale about the bbox top-left; rotation rotates
        // rigidly about the bbox center by the delta from the first angle.
        let group: Transform
        switch field {
        case "w":
            guard let v = num(), bbox.width > 0 else { return }
            let r = v / bbox.width
            group = Transform.scale(r, constrain ? r : 1).aroundPoint(bbox.x, bbox.y)
        case "h":
            guard let v = num(), bbox.height > 0 else { return }
            let r = v / bbox.height
            group = Transform.scale(constrain ? r : 1, r).aroundPoint(bbox.x, bbox.y)
        case "shear":
            guard let v = num() else { return }
            var cur = 0.0
            if let f = doc.selection.first, let ft = doc.getElement(f.path).transform {
                cur = propShearAngle(ft)
            }
            let cy = bbox.y + bbox.height / 2
            // shear_about_pivot(value - cur, ., cy): a doc-space horizontal
            // shear about the bbox center y — (x,y) -> (x + k*(y - cy), y).
            let k = tan((v - cur) * .pi / 180.0)
            group = Transform(a: 1, b: 0, c: k, d: 1, e: -k * cy, f: 0)
        default:
            guard let v = num() else { return }
            var cur = 0.0
            if let f = doc.selection.first, let ft = doc.getElement(f.path).transform {
                cur = atan2(ft.b, ft.a) * 180 / .pi
            }
            let cx = bbox.x + bbox.width / 2, cy = bbox.y + bbox.height / 2
            group = Transform.rotate(v - cur).aroundPoint(cx, cy)
        }
        var d = doc
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let old = elem.transform ?? .identity
            d = d.replaceElement(es.path, with: elem.withCommon(transform: group.multiply(old)))
        }
        model.editDocument(d)
    default:
        break
    }
}
