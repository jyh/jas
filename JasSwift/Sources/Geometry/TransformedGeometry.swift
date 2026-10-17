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
