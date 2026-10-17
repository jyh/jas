import Foundation

// MARK: - Geometry for the live transform operation (council 2026-10-16, ruling 4)
//
// Pure helpers the canvas uses to draw a `TransformedElem` with Scale Strokes
// OFF: the child's coordinates are mapped through the matrix and the stroke
// keeps its authored width. jas_dioxus does the same job with a painter
// adapter (`MappedGeometry` in painter/element_render.rs); this port has no
// painter seam, so it maps the ELEMENT instead and draws the copy.

/// The axes of an ellipse's image under the linear part of `m`.
///
/// The ellipse is `A·(cos t, sin t)` with `A = L·R(rotation)·diag(rx, ry)`. A
/// mirroring `L` (det < 0) is first made rotation-only by
/// `A·(cos t, sin t) = (A·F)·(cos −t, sin −t)` with `F = diag(1, −1)`, which
/// negates the angles and flips the sweep. Then `A = R(φ)·diag(s1, s2)·R(θ)`
/// (the closed-form 2×2 SVD). Returns `(s1, s2, φ, θ, mirrored)`. The same
/// derivation as jas_dioxus `ellipse_axes_through`.
public func ellipseAxesThrough(_ m: Transform, rx: Double, ry: Double, rotation: Double)
    -> (rx: Double, ry: Double, rotation: Double, theta: Double, mirrored: Bool)
{
    let cr = cos(rotation), sr = sin(rotation)
    let a = (m.a * cr + m.c * sr) * rx
    var b = (-m.a * sr + m.c * cr) * ry
    let c = (m.b * cr + m.d * sr) * rx
    var d = (-m.b * sr + m.d * cr) * ry
    let mirrored = a * d - b * c < 0
    if mirrored {
        b = -b
        d = -d
    }
    let e = (a + d) / 2, f = (a - d) / 2, g = (c + b) / 2, h = (c - b) / 2
    let q = (e * e + h * h).squareRoot(), r = (f * f + g * g).squareRoot()
    let a1 = atan2(g, f), a2 = atan2(h, e)
    return (q + r, max(q - r, 0), (a2 + a1) / 2, (a2 - a1) / 2, mirrored)
}

/// Every coordinate of `d` mapped through `m`. Exact for every command: an
/// affine map preserves the reflections smooth segments imply, and an
/// elliptical arc's image is an elliptical arc (new axes from the SVD, the
/// same large-arc choice, the sweep flipped by a mirror).
public func mapPathCommands(_ d: [PathCommand], _ m: Transform) -> [PathCommand] {
    d.map { cmd in
        switch cmd {
        case .moveTo(let x, let y):
            let p = m.applyPoint(x, y); return .moveTo(p.0, p.1)
        case .lineTo(let x, let y):
            let p = m.applyPoint(x, y); return .lineTo(p.0, p.1)
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            let p1 = m.applyPoint(x1, y1), p2 = m.applyPoint(x2, y2), p = m.applyPoint(x, y)
            return .curveTo(x1: p1.0, y1: p1.1, x2: p2.0, y2: p2.1, x: p.0, y: p.1)
        case .smoothCurveTo(let x2, let y2, let x, let y):
            let p2 = m.applyPoint(x2, y2), p = m.applyPoint(x, y)
            return .smoothCurveTo(x2: p2.0, y2: p2.1, x: p.0, y: p.1)
        case .quadTo(let x1, let y1, let x, let y):
            let p1 = m.applyPoint(x1, y1), p = m.applyPoint(x, y)
            return .quadTo(x1: p1.0, y1: p1.1, x: p.0, y: p.1)
        case .smoothQuadTo(let x, let y):
            let p = m.applyPoint(x, y); return .smoothQuadTo(p.0, p.1)
        case .arcTo(let rx, let ry, let rot, let large, let sweep, let x, let y):
            let ax = ellipseAxesThrough(m, rx: rx, ry: ry, rotation: rot * (Double.pi / 180))
            let p = m.applyPoint(x, y)
            return .arcTo(rx: ax.rx, ry: ax.ry, rotation: ax.rotation * (180 / Double.pi),
                          largeArc: large, sweep: sweep != ax.mirrored, x: p.0, y: p.1)
        case .closePath:
            return .closePath
        }
    }
}

/// The bezier constant for a quarter ellipse, 4/3·(√2−1).
private let quarterKappa = 4.0 / 3.0 * (2.0.squareRoot() - 1.0)

/// A rectangle (with optional corner radii) as path commands.
public func rectPathCommands(x: Double, y: Double, w: Double, h: Double,
                             rx rxIn: Double, ry ryIn: Double) -> [PathCommand] {
    var rx = rxIn, ry = ryIn
    if rx <= 0 && ry <= 0 {
        return [.moveTo(x, y), .lineTo(x + w, y), .lineTo(x + w, y + h), .lineTo(x, y + h), .closePath]
    }
    if rx <= 0 { rx = ry }
    if ry <= 0 { ry = rx }
    rx = min(rx, w / 2); ry = min(ry, h / 2)
    let kx = rx * quarterKappa, ky = ry * quarterKappa
    return [
        .moveTo(x + rx, y),
        .lineTo(x + w - rx, y),
        .curveTo(x1: x + w - rx + kx, y1: y, x2: x + w, y2: y + ry - ky, x: x + w, y: y + ry),
        .lineTo(x + w, y + h - ry),
        .curveTo(x1: x + w, y1: y + h - ry + ky, x2: x + w - rx + kx, y2: y + h, x: x + w - rx, y: y + h),
        .lineTo(x + rx, y + h),
        .curveTo(x1: x + rx - kx, y1: y + h, x2: x, y2: y + h - ry + ky, x: x, y: y + h - ry),
        .lineTo(x, y + ry),
        .curveTo(x1: x, y1: y + ry - ky, x2: x + rx - kx, y2: y, x: x + rx, y: y),
        .closePath,
    ]
}

/// An axis-aligned ellipse as four cubic quarters. ⚠️ A bezier ring, so a
/// mapped ellipse here is within ~2.7e-4 of its radius of the conic, where
/// jas_dioxus maps the arc exactly; CoreGraphics draws its own ellipses as
/// beziers too.
public func ellipsePathCommands(cx: Double, cy: Double, rx: Double, ry: Double) -> [PathCommand] {
    let kx = rx * quarterKappa, ky = ry * quarterKappa
    return [
        .moveTo(cx + rx, cy),
        .curveTo(x1: cx + rx, y1: cy + ky, x2: cx + kx, y2: cy + ry, x: cx, y: cy + ry),
        .curveTo(x1: cx - kx, y1: cy + ry, x2: cx - rx, y2: cy + ky, x: cx - rx, y: cy),
        .curveTo(x1: cx - rx, y1: cy - ky, x2: cx - kx, y2: cy - ry, x: cx, y: cy - ry),
        .curveTo(x1: cx + kx, y1: cy - ry, x2: cx + rx, y2: cy - ky, x: cx + rx, y: cy),
        .closePath,
    ]
}

/// `stroke` with its width and dashes multiplied by `k` (the child's OWN
/// transforms' scale; never the wrapper's).
func scaledStroke(_ stroke: Stroke?, _ k: Double) -> Stroke? {
    guard let s = stroke, k != 1 else { return stroke }
    return Stroke(color: s.color, width: s.width * k, linecap: s.linecap, linejoin: s.linejoin,
                  miterLimit: s.miterLimit, align: s.align,
                  dashPattern: s.dashPattern.map { $0 * k }, dashAlignAnchors: s.dashAlignAnchors,
                  startArrow: s.startArrow, endArrow: s.endArrow,
                  startArrowScale: s.startArrowScale, endArrowScale: s.endArrowScale,
                  arrowAlign: s.arrowAlign, opacity: s.opacity)
}

/// √|det| of a transform: the uniform stroke scale it applies.
func uniformScale(_ t: Transform) -> Double { abs(t.a * t.d - t.b * t.c).squareRoot() }

/// A rect's outline as the path the renderer strokes for it, corner radii as
/// QUADRATIC corners — command for command the same as jas_dioxus
/// `rect_geometry_path` (`rounded_rect_path`), so a released rect that becomes
/// a path serializes identically in both ports.
public func rectGeometryPathCommands(_ r: Rect) -> [PathCommand] {
    let (x, y, w, h) = (r.x, r.y, r.width, r.height)
    if r.rx <= 0 && r.ry <= 0 {
        return [.moveTo(x, y), .lineTo(x + w, y), .lineTo(x + w, y + h), .lineTo(x, y + h), .closePath]
    }
    let rx = min(max(r.rx, 0), w / 2), ry = min(max(r.ry, 0), h / 2)
    return [
        .moveTo(x + rx, y),
        .lineTo(x + w - rx, y),
        .quadTo(x1: x + w, y1: y, x: x + w, y: y + ry),
        .lineTo(x + w, y + h - ry),
        .quadTo(x1: x + w, y1: y + h, x: x + w - rx, y: y + h),
        .lineTo(x + rx, y + h),
        .quadTo(x1: x, y1: y + h, x: x, y: y + h - ry),
        .lineTo(x, y + ry),
        .quadTo(x1: x, y1: y, x: x + rx, y: y),
        .closePath,
    ]
}

/// `elem` with `m` BAKED INTO ITS COORDINATES and its stroke left at the
/// authored width: the Scale Strokes OFF drawing as a static element. Kind by
/// kind the same as jas_dioxus `map_element_geometry`:
///
/// * a rect under an AXIS-ALIGNED matrix stays a rect (corner radii per axis);
///   under a rotation or shear it becomes a path;
/// * an ellipse stays an ellipse under ANY matrix (axes from
///   `ellipseAxesThrough`, the rotation on its transform, which scales no
///   stroke);
/// * lines, polylines, polygons and paths map their points; a group maps its
///   children;
/// * text, and any live kind but a wrapper, take the matrix on their transform.
///
/// The element's own transform folds into the mapping and scales the stroke by
/// its √|det|, as the renderer does: exact when that transform is uniform.
public func mapElementGeometry(_ elem: Element, _ m: Transform) -> Element {
    mapGeometry(elem, m, 1)
}

private func mapGeometry(_ elem: Element, _ mIn: Transform, _ kIn: Double) -> Element {
    var m = mIn, k = kIn
    if let t = elem.transform {
        m = mIn.multiply(t)
        k = kIn * uniformScale(t)
    }
    let axisAligned = m.b == 0 && m.c == 0
    switch elem {
    case .rect(var r) where axisAligned:
        let p0 = m.applyPoint(r.x, r.y), p1 = m.applyPoint(r.x + r.width, r.y + r.height)
        (r.rx, r.ry) = (r.rx * abs(m.a), r.ry * abs(m.d))
        (r.x, r.y, r.width, r.height) = (min(p0.0, p1.0), min(p0.1, p1.1), abs(p1.0 - p0.0), abs(p1.1 - p0.1))
        r.stroke = scaledStroke(r.stroke, k)
        r.transform = nil
        return .rect(r)
    case .rect(let r):
        return .path(Path(d: mapPathCommands(rectGeometryPathCommands(r), m), fill: r.fill,
                          stroke: scaledStroke(r.stroke, k), widthPoints: [], opacity: r.opacity,
                          transform: nil, locked: r.locked, visibility: r.visibility,
                          blendMode: r.blendMode, mask: r.mask, fillGradient: r.fillGradient,
                          strokeGradient: r.strokeGradient, strokeBrush: nil, strokeBrushOverrides: nil,
                          toolOrigin: nil, name: r.name, id: r.id, fillRule: .nonzero))
    case .ellipse(var e):
        let ax = ellipseAxesThrough(m, rx: e.rx, ry: e.ry, rotation: 0)
        let c = m.applyPoint(e.cx, e.cy)
        (e.cx, e.cy, e.rx, e.ry) = (c.0, c.1, ax.rx, ax.ry)
        e.stroke = scaledStroke(e.stroke, k)
        e.transform = ax.rotation == 0 ? nil
            : Transform.rotate(ax.rotation * (180 / Double.pi)).aroundPoint(c.0, c.1)
        return .ellipse(e)
    case .line(var v):
        let a = m.applyPoint(v.x1, v.y1), b = m.applyPoint(v.x2, v.y2)
        (v.x1, v.y1, v.x2, v.y2) = (a.0, a.1, b.0, b.1)
        v.stroke = scaledStroke(v.stroke, k)
        v.transform = nil
        return .line(v)
    case .polyline(var v):
        v.points = v.points.map { p in m.applyPoint(p.0, p.1) }
        v.stroke = scaledStroke(v.stroke, k)
        v.transform = nil
        return .polyline(v)
    case .polygon(var v):
        v.points = v.points.map { p in m.applyPoint(p.0, p.1) }
        v.stroke = scaledStroke(v.stroke, k)
        v.transform = nil
        return .polygon(v)
    case .path(var v):
        v.d = mapPathCommands(v.d, m)
        v.stroke = scaledStroke(v.stroke, k)
        v.transform = nil
        return .path(v)
    case .group(var g):
        g.children = g.children.map { mapGeometry($0, m, k) }
        g.transform = nil
        return .group(g)
    case .layer(var l):
        l.children = l.children.map { mapGeometry($0, m, k) }
        l.transform = nil
        return .layer(l)
    case .live(.transformed(var t)):
        // An OFF wrapper inside composes into one OFF wrapper (exact); an ON
        // one scales what it holds by its √|det|, the renderer's rule.
        if t.scaleStrokes {
            return mapGeometry(t.child, m.multiply(t.matrix), k * uniformScale(t.matrix))
        }
        t.matrix = m.multiply(t.matrix)
        t.transform = nil
        return .live(.transformed(t))
    default:
        // ⚠️ LIMIT: a stroke there is then scaled by the matrix.
        return elem.withTransformSet(m)
    }
}
