import SwiftUI
import AppKit

/// Axis-aligned bounding box for the canvas coordinate space.
public struct CanvasBoundingBox: Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 800, height: Double = 600) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

// MARK: - Element drawing

private func nsColor(_ c: Color) -> NSColor {
    NSColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
}

private func cgColor(_ c: Color) -> CGColor {
    CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
}

private func applyTransform(_ ctx: CGContext, _ t: Transform?) {
    guard let t = t else { return }
    ctx.concatenate(CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.e, ty: t.f))
}

private func setFill(_ ctx: CGContext, _ fill: Fill?) {
    if let fill = fill {
        ctx.setFillColor(cgColor(fill.color))
    }
}

private func setStroke(_ ctx: CGContext, _ stroke: Stroke?) {
    guard let stroke = stroke else { return }
    ctx.setStrokeColor(cgColor(stroke.color))
    ctx.setLineWidth(stroke.width)
    switch stroke.linecap {
    case .butt: ctx.setLineCap(.butt)
    case .round: ctx.setLineCap(.round)
    case .square: ctx.setLineCap(.square)
    }
    switch stroke.linejoin {
    case .miter: ctx.setLineJoin(.miter)
    case .round: ctx.setLineJoin(.round)
    case .bevel: ctx.setLineJoin(.bevel)
    }
}

/// Convert an SVG arc to cubic Bezier curves (W3C SVG F.6).
private func arcToBeziers(
    cx0: Double, cy0: Double,
    rx rxIn: Double, ry ryIn: Double, xRotation: Double,
    largeArc: Bool, sweep: Bool,
    x: Double, y: Double
) -> [(Double, Double, Double, Double, Double, Double)] {
    if (cx0 == x && cy0 == y) || (rxIn == 0 && ryIn == 0) { return [] }

    var rx = abs(rxIn)
    var ry = abs(ryIn)
    let phi = xRotation * .pi / 180.0
    let cosPhi = cos(phi), sinPhi = sin(phi)

    let dx2 = (cx0 - x) / 2.0, dy2 = (cy0 - y) / 2.0
    let x1p = cosPhi * dx2 + sinPhi * dy2
    let y1p = -sinPhi * dx2 + cosPhi * dy2

    let x1pSq = x1p * x1p, y1pSq = y1p * y1p
    let lam = x1pSq / (rx * rx) + y1pSq / (ry * ry)
    if lam > 1.0 {
        let s = sqrt(lam); rx *= s; ry *= s
    }
    let rxSq = rx * rx, rySq = ry * ry

    let num = max(0.0, rxSq * rySq - rxSq * y1pSq - rySq * x1pSq)
    let den = rxSq * y1pSq + rySq * x1pSq
    var sq = den > 0 ? sqrt(num / den) : 0.0
    if largeArc == sweep { sq = -sq }
    let cxp = sq * rx * y1p / ry
    let cyp = -sq * ry * x1p / rx

    let ccx = cosPhi * cxp - sinPhi * cyp + (cx0 + x) / 2.0
    let ccy = sinPhi * cxp + cosPhi * cyp + (cy0 + y) / 2.0

    func vecAngle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        let n = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
        if n == 0 { return 0 }
        let c = max(-1.0, min(1.0, (ux * vx + uy * vy) / n))
        let a = acos(c)
        return (ux * vy - uy * vx < 0) ? -a : a
    }

    var theta1 = vecAngle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    var dtheta = vecAngle(
        (x1p - cxp) / rx, (y1p - cyp) / ry,
        (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if !sweep && dtheta > 0 { dtheta -= 2 * .pi }
    else if sweep && dtheta < 0 { dtheta += 2 * .pi }

    let nSegs = max(1, Int(ceil(abs(dtheta) / (.pi / 2))))
    let segAngle = dtheta / Double(nSegs)
    let alpha = sin(segAngle) * (sqrt(4 + 3 * pow(tan(segAngle / 2), 2)) - 1) / 3

    var curves: [(Double, Double, Double, Double, Double, Double)] = []
    for _ in 0..<nSegs {
        let cosT = cos(theta1), sinT = sin(theta1)
        let cosT2 = cos(theta1 + segAngle), sinT2 = sin(theta1 + segAngle)

        let ex1 = rx * cosT, ey1 = ry * sinT
        let ex2 = rx * cosT2, ey2 = ry * sinT2
        let ddx1 = -rx * sinT, ddy1 = ry * cosT
        let ddx2 = -rx * sinT2, ddy2 = ry * cosT2

        let cp1x = cosPhi * (ex1 + alpha * ddx1) - sinPhi * (ey1 + alpha * ddy1) + ccx
        let cp1y = sinPhi * (ex1 + alpha * ddx1) + cosPhi * (ey1 + alpha * ddy1) + ccy
        let cp2x = cosPhi * (ex2 - alpha * ddx2) - sinPhi * (ey2 - alpha * ddy2) + ccx
        let cp2y = sinPhi * (ex2 - alpha * ddx2) + cosPhi * (ey2 - alpha * ddy2) + ccy
        let epx = cosPhi * ex2 - sinPhi * ey2 + ccx
        let epy = sinPhi * ex2 + cosPhi * ey2 + ccy

        curves.append((cp1x, cp1y, cp2x, cp2y, epx, epy))
        theta1 += segAngle
    }
    return curves
}

private func buildPath(_ ctx: CGContext, _ cmds: [PathCommand]) {
    var lastControl: CGPoint? = nil
    for cmd in cmds {
        switch cmd {
        case .moveTo(let x, let y):
            ctx.move(to: CGPoint(x: x, y: y))
            lastControl = nil
        case .lineTo(let x, let y):
            ctx.addLine(to: CGPoint(x: x, y: y))
            lastControl = nil
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            ctx.addCurve(to: CGPoint(x: x, y: y),
                         control1: CGPoint(x: x1, y: y1),
                         control2: CGPoint(x: x2, y: y2))
            lastControl = CGPoint(x: x2, y: y2)
        case .smoothCurveTo(let x2, let y2, let x, let y):
            let cur = ctx.currentPointOfPath
            let c1: CGPoint
            if let lc = lastControl {
                c1 = CGPoint(x: 2 * cur.x - lc.x, y: 2 * cur.y - lc.y)
            } else {
                c1 = cur
            }
            ctx.addCurve(to: CGPoint(x: x, y: y),
                         control1: c1,
                         control2: CGPoint(x: x2, y: y2))
            lastControl = CGPoint(x: x2, y: y2)
        case .quadTo(let x1, let y1, let x, let y):
            ctx.addQuadCurve(to: CGPoint(x: x, y: y),
                             control: CGPoint(x: x1, y: y1))
            lastControl = CGPoint(x: x1, y: y1)
        case .smoothQuadTo(let x, let y):
            let cur = ctx.currentPointOfPath
            let c1: CGPoint
            if let lc = lastControl {
                c1 = CGPoint(x: 2 * cur.x - lc.x, y: 2 * cur.y - lc.y)
            } else {
                c1 = cur
            }
            ctx.addQuadCurve(to: CGPoint(x: x, y: y), control: c1)
            lastControl = c1
        case .arcTo(let arx, let ary, let rot, let la, let sw, let x, let y):
            let cur = ctx.currentPointOfPath
            let beziers = arcToBeziers(
                cx0: cur.x, cy0: cur.y, rx: arx, ry: ary, xRotation: rot,
                largeArc: la, sweep: sw, x: x, y: y)
            if beziers.isEmpty {
                ctx.addLine(to: CGPoint(x: x, y: y))
            } else {
                for (bx1, by1, bx2, by2, bx, by) in beziers {
                    ctx.addCurve(to: CGPoint(x: bx, y: by),
                                 control1: CGPoint(x: bx1, y: by1),
                                 control2: CGPoint(x: bx2, y: by2))
                }
            }
            lastControl = nil
        case .closePath:
            ctx.closePath()
            lastControl = nil
        }
    }
}

/// Build path commands into a CGMutablePath (for text-on-path flattening).
private func buildCGPath(_ path: CGMutablePath, _ cmds: [PathCommand]) {
    var lastControl: CGPoint? = nil
    for cmd in cmds {
        switch cmd {
        case .moveTo(let x, let y):
            path.move(to: CGPoint(x: x, y: y))
            lastControl = nil
        case .lineTo(let x, let y):
            path.addLine(to: CGPoint(x: x, y: y))
            lastControl = nil
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            path.addCurve(to: CGPoint(x: x, y: y),
                          control1: CGPoint(x: x1, y: y1),
                          control2: CGPoint(x: x2, y: y2))
            lastControl = CGPoint(x: x2, y: y2)
        case .smoothCurveTo(let x2, let y2, let x, let y):
            let cur = path.currentPoint
            let c1: CGPoint
            if let lc = lastControl {
                c1 = CGPoint(x: 2 * cur.x - lc.x, y: 2 * cur.y - lc.y)
            } else {
                c1 = cur
            }
            path.addCurve(to: CGPoint(x: x, y: y),
                          control1: c1,
                          control2: CGPoint(x: x2, y: y2))
            lastControl = CGPoint(x: x2, y: y2)
        case .quadTo(let x1, let y1, let x, let y):
            path.addQuadCurve(to: CGPoint(x: x, y: y),
                              control: CGPoint(x: x1, y: y1))
            lastControl = CGPoint(x: x1, y: y1)
        case .smoothQuadTo(let x, let y):
            let cur = path.currentPoint
            let c1: CGPoint
            if let lc = lastControl {
                c1 = CGPoint(x: 2 * cur.x - lc.x, y: 2 * cur.y - lc.y)
            } else {
                c1 = cur
            }
            path.addQuadCurve(to: CGPoint(x: x, y: y), control: c1)
            lastControl = c1
        case .arcTo(let arx, let ary, let rot, let la, let sw, let x, let y):
            let cur = path.currentPoint
            let beziers = arcToBeziers(
                cx0: cur.x, cy0: cur.y, rx: arx, ry: ary, xRotation: rot,
                largeArc: la, sweep: sw, x: x, y: y)
            if beziers.isEmpty {
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                for (bx1, by1, bx2, by2, bx, by) in beziers {
                    path.addCurve(to: CGPoint(x: bx, y: by),
                                  control1: CGPoint(x: bx1, y: by1),
                                  control2: CGPoint(x: bx2, y: by2))
                }
            }
            lastControl = nil
        case .closePath:
            path.closeSubpath()
            lastControl = nil
        }
    }
}

private func fillAndStroke(_ ctx: CGContext, _ fill: Fill?, _ stroke: Stroke?) {
    let hasFill = fill != nil
    let hasStroke = stroke != nil
    if hasFill && hasStroke {
        setFill(ctx, fill)
        setStroke(ctx, stroke)
        ctx.drawPath(using: .fillStroke)
    } else if hasFill {
        setFill(ctx, fill)
        ctx.fillPath()
    } else if hasStroke {
        setStroke(ctx, stroke)
        ctx.strokePath()
    }
}

private func drawElement(_ ctx: CGContext, _ elem: Element) {
    ctx.saveGState()
    switch elem {
    case .line(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        setStroke(ctx, v.stroke)
        ctx.move(to: CGPoint(x: v.x1, y: v.y1))
        ctx.addLine(to: CGPoint(x: v.x2, y: v.y2))
        ctx.strokePath()

    case .rect(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        let rect = CGRect(x: v.x, y: v.y, width: v.width, height: v.height)
        if v.rx > 0 || v.ry > 0 {
            let path = CGPath(roundedRect: rect, cornerWidth: v.rx, cornerHeight: v.ry, transform: nil)
            ctx.addPath(path)
        } else {
            ctx.addRect(rect)
        }
        fillAndStroke(ctx, v.fill, v.stroke)

    case .circle(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        let rect = CGRect(x: v.cx - v.r, y: v.cy - v.r, width: v.r * 2, height: v.r * 2)
        ctx.addEllipse(in: rect)
        fillAndStroke(ctx, v.fill, v.stroke)

    case .ellipse(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        let rect = CGRect(x: v.cx - v.rx, y: v.cy - v.ry, width: v.rx * 2, height: v.ry * 2)
        ctx.addEllipse(in: rect)
        fillAndStroke(ctx, v.fill, v.stroke)

    case .polyline(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        guard !v.points.isEmpty else { break }
        ctx.move(to: CGPoint(x: v.points[0].0, y: v.points[0].1))
        for i in 1..<v.points.count {
            ctx.addLine(to: CGPoint(x: v.points[i].0, y: v.points[i].1))
        }
        fillAndStroke(ctx, v.fill, v.stroke)

    case .polygon(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        guard !v.points.isEmpty else { break }
        ctx.move(to: CGPoint(x: v.points[0].0, y: v.points[0].1))
        for i in 1..<v.points.count {
            ctx.addLine(to: CGPoint(x: v.points[i].0, y: v.points[i].1))
        }
        ctx.closePath()
        fillAndStroke(ctx, v.fill, v.stroke)

    case .path(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        buildPath(ctx, v.d)
        fillAndStroke(ctx, v.fill, v.stroke)

    case .text(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        var fontDesc = NSFontDescriptor(name: v.fontFamily, size: v.fontSize)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if v.fontWeight == "bold" { traits.insert(.bold) }
        if v.fontStyle == "italic" || v.fontStyle == "oblique" { traits.insert(.italic) }
        fontDesc = fontDesc.withSymbolicTraits(traits)
        let font = NSFont(descriptor: fontDesc, size: v.fontSize) ?? NSFont.systemFont(ofSize: v.fontSize)
        let color: NSColor
        if let fill = v.fill {
            color = nsColor(fill.color)
        } else {
            color = .black
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        if v.textDecoration == "underline" {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else if v.textDecoration == "line-through" {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        ctx.saveGState()
        // Both point and area text are rendered as one CTLine per visual
        // line in the NSView's flipped coordinate system. The element's
        // (x, y) is the *top* of the layout box; the baseline is
        // `y + 0.8 * fontSize` (the same ascent the editor uses). Per-line
        // y advances by `fontSize`.
        ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        let measure = makeMeasurer(family: v.fontFamily, weight: v.fontWeight,
                                   style: v.fontStyle, size: v.fontSize)
        let maxW = v.isAreaText ? v.width : 0.0
        let lay = layoutText(v.content, maxWidth: maxW,
                             fontSize: v.fontSize, measure: measure)
        let chars = Array(v.content)
        for line in lay.lines {
            let segChars = chars[line.start..<line.end]
            let segStr = String(segChars)
            let lineStr = NSAttributedString(string: segStr, attributes: attrs)
            let ctLine = CTLineCreateWithAttributedString(lineStr)
            ctx.textPosition = CGPoint(x: v.x, y: v.y + line.baselineY)
            CTLineDraw(ctLine, ctx)
        }
        ctx.restoreGState()

    case .textPath(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        var fontDesc = NSFontDescriptor(name: v.fontFamily, size: v.fontSize)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if v.fontWeight == "bold" { traits.insert(.bold) }
        if v.fontStyle == "italic" || v.fontStyle == "oblique" { traits.insert(.italic) }
        fontDesc = fontDesc.withSymbolicTraits(traits)
        let font = NSFont(descriptor: fontDesc, size: v.fontSize) ?? NSFont.systemFont(ofSize: v.fontSize)
        let color: NSColor
        if let fill = v.fill {
            color = nsColor(fill.color)
        } else {
            color = .black
        }
        // Flatten path to polyline
        let cgPath = CGMutablePath()
        buildCGPath(cgPath, v.d)
        var points: [(Double, Double)] = []
        cgPath.applyWithBlock { elementPtr in
            let el = elementPtr.pointee
            switch el.type {
            case .moveToPoint, .addLineToPoint:
                points.append((el.points[0].x, el.points[0].y))
            case .addCurveToPoint:
                // Flatten cubic bezier
                let n = points.isEmpty ? 0 : points.count - 1
                let (sx, sy) = points.isEmpty ? (0.0, 0.0) : points[n]
                let steps = flattenSteps
                for i in 1...steps {
                    let t = Double(i) / Double(steps)
                    let mt = 1.0 - t
                    let px = mt*mt*mt*sx + 3*mt*mt*t*el.points[0].x + 3*mt*t*t*el.points[1].x + t*t*t*el.points[2].x
                    let py = mt*mt*mt*sy + 3*mt*mt*t*el.points[0].y + 3*mt*t*t*el.points[1].y + t*t*t*el.points[2].y
                    points.append((px, py))
                }
            case .addQuadCurveToPoint:
                let n = points.isEmpty ? 0 : points.count - 1
                let (sx, sy) = points.isEmpty ? (0.0, 0.0) : points[n]
                let steps = flattenSteps
                for i in 1...steps {
                    let t = Double(i) / Double(steps)
                    let mt = 1.0 - t
                    let px = mt*mt*sx + 2*mt*t*el.points[0].x + t*t*el.points[1].x
                    let py = mt*mt*sy + 2*mt*t*el.points[0].y + t*t*el.points[1].y
                    points.append((px, py))
                }
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }
        guard points.count >= 2 else { break }
        // Compute cumulative distances
        var dists = [0.0]
        for i in 1..<points.count {
            let dx = points[i].0 - points[i-1].0
            let dy = points[i].1 - points[i-1].1
            dists.append(dists[i-1] + hypot(dx, dy))
        }
        let totalLen = dists.last!
        guard totalLen > 0 else { break }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var offset = v.startOffset * totalLen
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        for ch in v.content {
            let chStr = NSAttributedString(string: String(ch), attributes: attrs)
            let line = CTLineCreateWithAttributedString(chStr)
            let cw = CTLineGetTypographicBounds(line, nil, nil, nil)
            let mid = offset + cw / 2
            if mid > totalLen { break }
            // Find segment containing mid
            var seg = 1
            while seg < points.count - 1 && dists[seg] < mid { seg += 1 }
            let d0 = dists[seg - 1], d1 = dists[seg]
            let frac = d1 > d0 ? (mid - d0) / (d1 - d0) : 0
            let (ax, ay) = points[seg - 1], (bx, by) = points[seg]
            let px = ax + frac * (bx - ax)
            let py = ay + frac * (by - ay)
            let angle = atan2(by - ay, bx - ax)
            ctx.saveGState()
            ctx.translateBy(x: px, y: py)
            ctx.rotate(by: angle)
            ctx.textPosition = CGPoint(x: -cw / 2, y: v.fontSize / 3)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
            offset += cw
        }
        ctx.restoreGState()

    case .group(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        for child in v.children { drawElement(ctx, child) }

    case .layer(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        for child in v.children { drawElement(ctx, child) }
    }
    ctx.restoreGState()
}

// MARK: - Selection overlay drawing

private let selectionColor = CGColor(red: 0, green: 0.47, blue: 1.0, alpha: 1.0)
private let handleSize: CGFloat = handleDrawSize

/// Whether to draw the blue bounding-box outline + corner-square
/// handles around each selected element. Control-point handles for
/// path/textPath anchors are still drawn regardless. Defaults to
/// `false` so the selection bbox doesn't clutter the canvas; flip to
/// `true` to get the old behavior back.
public let showSelectionBBox: Bool = false

/// Draw an element's selection overlay (outline + control handles).
/// Internal so tools can call it via the ToolContext. `kind` decides
/// which control points are highlighted (and gets handle decoration);
/// pass `.partial(SortedCps())` for "outline but no highlighted CPs".
func drawElementOverlay(_ ctx: CGContext, _ elem: Element, kind: SelectionKind = .partial(SortedCps())) {
    // Text and TextPath selections never get the outline + corner
    // squares — the editing overlay (caret, area-text bbox) is
    // sufficient and the squares would clutter the rendered glyphs.
    if case .text = elem { return }
    if case .textPath = elem { return }

    ctx.setStrokeColor(selectionColor)
    ctx.setLineWidth(1.0)
    ctx.setLineDash(phase: 0, lengths: [])

    // Gate the bounding-box outline for non-text elements behind the
    // showSelectionBBox flag. Bezier handle decoration on path
    // anchors is drawn unconditionally below.
    if showSelectionBBox {
        switch elem {
        case .line(let v):
            ctx.move(to: CGPoint(x: v.x1, y: v.y1))
            ctx.addLine(to: CGPoint(x: v.x2, y: v.y2))
            ctx.strokePath()
        case .rect(let v):
            if v.rx > 0 || v.ry > 0 {
                let path = CGPath(roundedRect: CGRect(x: v.x, y: v.y, width: v.width, height: v.height),
                                  cornerWidth: v.rx, cornerHeight: v.ry, transform: nil)
                ctx.addPath(path)
            } else {
                ctx.addRect(CGRect(x: v.x, y: v.y, width: v.width, height: v.height))
            }
            ctx.strokePath()
        case .circle(let v):
            ctx.addEllipse(in: CGRect(x: v.cx - v.r, y: v.cy - v.r, width: v.r * 2, height: v.r * 2))
            ctx.strokePath()
        case .ellipse(let v):
            ctx.addEllipse(in: CGRect(x: v.cx - v.rx, y: v.cy - v.ry, width: v.rx * 2, height: v.ry * 2))
            ctx.strokePath()
        case .polyline(let v):
            guard !v.points.isEmpty else { break }
            ctx.move(to: CGPoint(x: v.points[0].0, y: v.points[0].1))
            for i in 1..<v.points.count { ctx.addLine(to: CGPoint(x: v.points[i].0, y: v.points[i].1)) }
            ctx.strokePath()
        case .polygon(let v):
            guard !v.points.isEmpty else { break }
            ctx.move(to: CGPoint(x: v.points[0].0, y: v.points[0].1))
            for i in 1..<v.points.count { ctx.addLine(to: CGPoint(x: v.points[i].0, y: v.points[i].1)) }
            ctx.closePath()
            ctx.strokePath()
        case .path(let v):
            buildPath(ctx, v.d)
            ctx.strokePath()
        default:
            let b = elem.bounds
            ctx.addRect(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
            ctx.strokePath()
        }
    }

    // Draw Bezier handles for selected path control points
    let handleCircleRadius: CGFloat = 3.0
    let pathD: [PathCommand]?
    switch elem {
    case .path(let v): pathD = v.d
    case .textPath(let v): pathD = v.d
    default: pathD = nil
    }
    let cpHighlight = kind.toSorted(total: elem.controlPointCount).toArray()
    if let d = pathD, !cpHighlight.isEmpty {
        let anchors = elem.controlPointPositions
        for cpIdx in cpHighlight {
            guard cpIdx < anchors.count else { continue }
            let (ax, ay) = anchors[cpIdx]
            let (hIn, hOut) = pathHandlePositions(d, anchorIdx: cpIdx)
            ctx.setStrokeColor(selectionColor)
            ctx.setLineWidth(1.0)
            if let (hx, hy) = hIn {
                ctx.move(to: CGPoint(x: ax, y: ay))
                ctx.addLine(to: CGPoint(x: hx, y: hy))
                ctx.strokePath()
                ctx.addEllipse(in: CGRect(x: hx - handleCircleRadius, y: hy - handleCircleRadius,
                                          width: handleCircleRadius * 2, height: handleCircleRadius * 2))
                ctx.setFillColor(.white)
                ctx.fillPath()
                ctx.addEllipse(in: CGRect(x: hx - handleCircleRadius, y: hy - handleCircleRadius,
                                          width: handleCircleRadius * 2, height: handleCircleRadius * 2))
                ctx.setStrokeColor(selectionColor)
                ctx.strokePath()
            }
            if let (hx, hy) = hOut {
                ctx.move(to: CGPoint(x: ax, y: ay))
                ctx.addLine(to: CGPoint(x: hx, y: hy))
                ctx.strokePath()
                ctx.addEllipse(in: CGRect(x: hx - handleCircleRadius, y: hy - handleCircleRadius,
                                          width: handleCircleRadius * 2, height: handleCircleRadius * 2))
                ctx.setFillColor(.white)
                ctx.fillPath()
                ctx.addEllipse(in: CGRect(x: hx - handleCircleRadius, y: hy - handleCircleRadius,
                                          width: handleCircleRadius * 2, height: handleCircleRadius * 2))
                ctx.setStrokeColor(selectionColor)
                ctx.strokePath()
            }
        }
    }

    // Draw control-point squares.
    //
    // - For "CP-shape" elements (Line, Polyline, Polygon, Path) the
    //   squares represent draggable per-vertex/anchor handles, so
    //   they are always shown.
    // - For "bbox-shape" elements (Rect, Circle, Ellipse, Group, ...)
    //   the squares represent bounding-box corner handles. They are
    //   drawn when the kind is `.partial(*)` (including empty) —
    //   the Direct Selection tool needs the user to see the
    //   grabbable handles even when none are highlighted — or when
    //   `showSelectionBBox` is on.
    let cpShape: Bool
    switch elem {
    case .line, .polyline, .polygon, .path: cpShape = true
    default: cpShape = false
    }
    let isPartial: Bool
    if case .partial = kind { isPartial = true } else { isPartial = false }
    if cpShape || isPartial || showSelectionBBox {
        let half = handleSize / 2
        for (i, (px, py)) in elem.controlPointPositions.enumerated() {
            let r = CGRect(x: px - half, y: py - half, width: handleSize, height: handleSize)
            if kind.contains(i) {
                ctx.setFillColor(selectionColor)
            } else {
                ctx.setFillColor(.white)
            }
            ctx.fill(r)
            ctx.setStrokeColor(selectionColor)
            ctx.stroke(r)
        }
    }
}

private func elemChildren(_ e: Element) -> [Element] {
    switch e {
    case .group(let g): return g.children
    case .layer(let l): return l.children
    default: return []
    }
}

private func drawSelectionOverlays(_ ctx: CGContext, _ doc: Document) {
    for es in doc.selection {
        let path = es.path
        guard !path.isEmpty else { continue }
        ctx.saveGState()
        var node: Element = .layer(doc.layers[path[0]])
        if path.count > 1 {
            applyTransform(ctx, doc.layers[path[0]].transform)
            for idx in path[1..<path.count - 1] {
                let children = elemChildren(node)
                node = children[idx]
                switch node {
                case .group(let g): applyTransform(ctx, g.transform)
                case .layer(let l): applyTransform(ctx, l.transform)
                default: break
                }
            }
            node = elemChildren(node)[path.last!]
        }
        // Apply the selected element's own transform
        switch node {
        case .line(let v): applyTransform(ctx, v.transform)
        case .rect(let v): applyTransform(ctx, v.transform)
        case .circle(let v): applyTransform(ctx, v.transform)
        case .ellipse(let v): applyTransform(ctx, v.transform)
        case .polyline(let v): applyTransform(ctx, v.transform)
        case .polygon(let v): applyTransform(ctx, v.transform)
        case .path(let v): applyTransform(ctx, v.transform)
        case .text(let v): applyTransform(ctx, v.transform)
        case .textPath(let v): applyTransform(ctx, v.transform)
        case .group(let v): applyTransform(ctx, v.transform)
        case .layer(let v): applyTransform(ctx, v.transform)
        }
        drawElementOverlay(ctx, node, kind: es.kind)
        ctx.restoreGState()
    }
}

/// Map an NSEvent to a stable key name string used by tools'
/// `onKeyEvent` (matches the Rust/JS naming used by the cross-language
/// type tools: "ArrowLeft", "Backspace", "Escape", etc., otherwise the
/// raw character string).
func canonicalKeyName(_ event: NSEvent) -> String {
    let keyCode = event.keyCode
    switch keyCode {
    case 36: return "Enter"          // Return
    case 76: return "Enter"          // numeric keypad Enter
    case 51: return "Backspace"
    case 117: return "Delete"         // forward delete
    case 53: return "Escape"
    case 123: return "ArrowLeft"
    case 124: return "ArrowRight"
    case 125: return "ArrowDown"
    case 126: return "ArrowUp"
    case 115: return "Home"
    case 119: return "End"
    case 48: return "Tab"
    default:
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            // Map control characters that some keyboards/layouts deliver
            // before the keyCode lookup hits.
            if chars == "\r" || chars == "\n" { return "Enter" }
            if chars == "\u{7F}" { return "Backspace" }
            if chars == "\u{F728}" { return "Delete" }
            if chars == "\u{1B}" { return "Escape" }
            return chars
        }
        return ""
    }
}

// MARK: - Canvas NSView for CoreGraphics drawing

/// An NSView that draws the document's elements using CoreGraphics.
/// Dispatches mouse/key events through the CanvasTool protocol.
class CanvasNSView: NSView {
    var document: Document = Document()
    var controller: Controller?
    var currentTool: Tool = .selection {
        didSet {
            guard oldValue != currentTool else { return }
            if let ctx = toolContext {
                let savedSelection = document.selection
                tools[oldValue]?.deactivate(ctx)
                tools[currentTool]?.activate(ctx)
                // Preserve selection across tool changes
                if document.selection != savedSelection {
                    var doc = document
                    doc = Document(layers: doc.layers,
                                      selectedLayer: doc.selectedLayer,
                                      selection: savedSelection)
                    controller?.model.document = doc
                }
            }
            window?.invalidateCursorRects(for: self)
        }
    }
    var onToolRead: (() -> Tool)?
    var onToolChange: ((Tool) -> Void)?
    var onFocus: (() -> Void)?

    // Tool system
    let tools: [Tool: CanvasTool] = createTools()

    // Blink timer that drives caret animation while a tool is editing.
    private var blinkTimer: Timer?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Start a 265 ms timer that bumps `needsDisplay` while the active tool
    /// is editing — drives the caret blink animation. The timer is created
    /// lazily on first need and torn down once no tool is editing.
    private func ensureBlinkTimer() {
        if blinkTimer != nil { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.265, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.tools.values.contains(where: { $0.isEditing() }) {
                self.needsDisplay = true
                // The cursor-hide-when-idle override depends on elapsed
                // wall clock time, so refresh cursor rects on each tick
                // too — this is what flips the pointer to "none" once
                // the user has stopped moving the mouse.
                self.window?.invalidateCursorRects(for: self)
            } else {
                self.blinkTimer?.invalidate()
                self.blinkTimer = nil
            }
        }
    }

    override func resetCursorRects() {
        discardCursorRects()
        // Active tool can override the per-tool cursor (e.g. the type
        // tool hides the cursor when the pointer is inside the text it
        // is currently editing, so the rendered caret is not occluded).
        if let override = tools[onToolRead?() ?? currentTool]?.cursorOverride() {
            switch override {
            case "none":
                addCursorRect(bounds, cursor: CanvasNSView.hiddenCursor)
                return
            case "ibeam":
                addCursorRect(bounds, cursor: NSCursor.iBeam)
                return
            default:
                break
            }
        }
        addCursorRect(bounds, cursor: cursorForTool(onToolRead?() ?? currentTool))
    }

    /// A 1×1 fully-transparent cursor used to "hide" the pointer over the
    /// text being edited without dropping out of the cursor-rect system.
    static let hiddenCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: img, hotSpot: .zero)
    }()

    private func cursorForTool(_ tool: Tool) -> NSCursor {
        switch tool {
        case .selection:
            return NSCursor.arrow
        case .directSelection:
            return makeArrowCursor(fill: .white, stroke: .black)
        case .groupSelection:
            return makeGroupSelectionCursor()
        case .pen:
            return makePenCursor()
        case .addAnchorPoint:
            return makeAddAnchorPointCursor()
        case .deleteAnchorPoint:
            return makeDeleteAnchorPointCursor()
        case .pencil:
            return makePencilCursor()
        case .pathEraser:
            return makePathEraserCursor()
        case .typeTool:
            return makeTypeCursor()
        case .typeOnPath:
            return makeTypeOnPathCursor()
        default:
            return NSCursor.crosshair
        }
    }

    private func makeArrowCursor(fill: NSColor, stroke: NSColor) -> NSCursor {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: true) { rect in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 4, y: 1))
            path.line(to: NSPoint(x: 4, y: 19))
            path.line(to: NSPoint(x: 8, y: 15))
            path.line(to: NSPoint(x: 12, y: 22))
            path.line(to: NSPoint(x: 15, y: 20))
            path.line(to: NSPoint(x: 11, y: 13))
            path.line(to: NSPoint(x: 16, y: 13))
            path.close()
            fill.setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 4, y: 1))
    }

    private func makeGroupSelectionCursor() -> NSCursor {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: true) { rect in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 4, y: 1))
            path.line(to: NSPoint(x: 4, y: 19))
            path.line(to: NSPoint(x: 8, y: 15))
            path.line(to: NSPoint(x: 12, y: 22))
            path.line(to: NSPoint(x: 15, y: 20))
            path.line(to: NSPoint(x: 11, y: 13))
            path.line(to: NSPoint(x: 16, y: 13))
            path.close()
            NSColor.white.setFill()
            path.fill()
            NSColor.black.setStroke()
            path.lineWidth = 1
            path.stroke()
            // Plus sign
            let plus = NSBezierPath()
            plus.move(to: NSPoint(x: 17, y: 20))
            plus.line(to: NSPoint(x: 23, y: 20))
            plus.move(to: NSPoint(x: 20, y: 17))
            plus.line(to: NSPoint(x: 20, y: 23))
            NSColor.black.setStroke()
            plus.lineWidth = 2
            plus.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 4, y: 1))
    }

    /// Load a 32×32 PNG from `assets/icons/<name>.png`, scale it down to a
    /// 16-pt @2x Retina cursor, and return an NSCursor with the given
    /// hot spot. Returns `fallback` if the file cannot be located.
    private func loadCursor(_ name: String, hotSpot: NSPoint, fallback: NSCursor) -> NSCursor {
        let bundle = Bundle.main
        let cwd = FileManager.default.currentDirectoryPath
        let rel = "assets/icons/\(name).png"
        let candidates: [String] = [
            (cwd as NSString).appendingPathComponent(rel),
            (cwd as NSString).appendingPathComponent("../\(rel)"),
            bundle.resourcePath.map { ($0 as NSString).appendingPathComponent(rel) },
            bundle.path(forResource: name, ofType: "png"),
        ].compactMap { $0 }
        for path in candidates {
            if let orig = NSImage(contentsOfFile: path) {
                // Draw at 32×32 pixels, set size to 16×16 points for @2x Retina.
                let pixelSize = NSSize(width: 32, height: 32)
                let image = NSImage(size: pixelSize)
                image.lockFocus()
                orig.draw(in: NSRect(origin: .zero, size: pixelSize),
                          from: NSRect(origin: .zero, size: orig.size),
                          operation: .sourceOver, fraction: 1.0)
                image.unlockFocus()
                image.size = NSSize(width: 16, height: 16)
                return NSCursor(image: image, hotSpot: hotSpot)
            }
        }
        return fallback
    }

    private func makePenCursor() -> NSCursor {
        loadCursor("pen tool", hotSpot: NSPoint(x: 1, y: 1), fallback: NSCursor.crosshair)
    }

    private func makeAddAnchorPointCursor() -> NSCursor {
        loadCursor("add anchor point", hotSpot: NSPoint(x: 1, y: 1), fallback: NSCursor.crosshair)
    }

    private func makePencilCursor() -> NSCursor {
        loadCursor("pencil tool", hotSpot: NSPoint(x: 1, y: 15), fallback: NSCursor.crosshair)
    }

    private func makePathEraserCursor() -> NSCursor {
        loadCursor("path eraser tool", hotSpot: NSPoint(x: 1, y: 15), fallback: NSCursor.crosshair)
    }

    private func makeTypeCursor() -> NSCursor {
        loadCursor("type cursor", hotSpot: NSPoint(x: 8, y: 8), fallback: NSCursor.iBeam)
    }

    private func makeTypeOnPathCursor() -> NSCursor {
        loadCursor("type on a path cursor", hotSpot: NSPoint(x: 8, y: 6), fallback: NSCursor.iBeam)
    }

    private func makeDeleteAnchorPointCursor() -> NSCursor {
        loadCursor("delete anchor point", hotSpot: NSPoint(x: 1, y: 1), fallback: NSCursor.crosshair)
    }

    var activeTool: CanvasTool {
        let tool = onToolRead?() ?? currentTool
        return tools[tool]!
    }

    var toolContext: ToolContext? {
        guard let controller = controller else { return nil }
        return ToolContext(
            model: controller.model,
            controller: controller,
            hitTestSelection: { [weak self] pos in self?.hitTestSelection(pos) ?? false },
            hitTestHandle: { [weak self] pos in self?.hitTestHandle(pos) },
            hitTestText: { [weak self] pos in self?.hitTestText(pos) },
            hitTestPathCurve: { [weak self] x, y in self?.hitTestPathCurve(x, y) },
            requestUpdate: { [weak self] in self?.needsDisplay = true },
            drawElementOverlay: { ctx, elem, kind in drawElementOverlay(ctx, elem, kind: kind) }
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // White background
        ctx.setFillColor(.white)
        ctx.fill(bounds)
        // Draw document layers
        for layer in document.layers {
            drawElement(ctx, .layer(layer))
        }
        // Draw selection overlays
        drawSelectionOverlays(ctx, document)
        // Draw active tool overlay
        if let toolCtx = toolContext {
            activeTool.drawOverlay(toolCtx, ctx)
        }
    }

    // MARK: - Hit tests

    private func hitTestSelection(_ pos: NSPoint) -> Bool {
        for es in document.selection {
            let elem = document.getElement(es.path)
            let cps = elem.controlPointPositions
            for (i, (px, py)) in cps.enumerated() {
                if es.kind.contains(i) {
                    if abs(pos.x - px) <= hitRadius && abs(pos.y - py) <= hitRadius {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func hitTestHandle(_ pos: NSPoint) -> (path: ElementPath, anchorIdx: Int, handleType: String)? {
        for es in document.selection {
            let elem = document.getElement(es.path)
            guard case .path(let v) = elem else { continue }
            for cpIdx in es.kind.toSorted(total: elem.controlPointCount).toArray() {
                let (hIn, hOut) = pathHandlePositions(v.d, anchorIdx: cpIdx)
                if let (hx, hy) = hIn {
                    if abs(pos.x - hx) <= hitRadius && abs(pos.y - hy) <= hitRadius {
                        return (es.path, cpIdx, "in")
                    }
                }
                if let (hx, hy) = hOut {
                    if abs(pos.x - hx) <= hitRadius && abs(pos.y - hy) <= hitRadius {
                        return (es.path, cpIdx, "out")
                    }
                }
            }
        }
        return nil
    }

    private func hitTestText(_ pos: NSPoint) -> (ElementPath, Text)? {
        for (li, layer) in document.layers.enumerated() {
            for (ci, child) in layer.children.enumerated() {
                if case .text(let v) = child {
                    let (bx, by, bw, bh) = v.bounds
                    if pos.x >= bx && pos.x <= bx + bw && pos.y >= by && pos.y <= by + bh {
                        return ([li, ci], v)
                    }
                }
            }
        }
        return nil
    }

    private func hitTestPathCurve(_ x: Double, _ y: Double) -> (ElementPath, Element)? {
        let threshold = hitRadius + 2
        for (li, layer) in document.layers.enumerated() {
            for (ci, child) in layer.children.enumerated() {
                switch child {
                case .path(let v):
                    if pathDistanceToPoint(v.d, px: x, py: y) <= threshold {
                        return ([li, ci], child)
                    }
                case .textPath(let v):
                    if pathDistanceToPoint(v.d, px: x, py: y) <= threshold {
                        return ([li, ci], child)
                    }
                case .group(let g):
                    for (gi, gc) in g.children.enumerated() {
                        switch gc {
                        case .path(let v):
                            if pathDistanceToPoint(v.d, px: x, py: y) <= threshold {
                                return ([li, ci, gi], gc)
                            }
                        case .textPath(let v):
                            if pathDistanceToPoint(v.d, px: x, py: y) <= threshold {
                                return ([li, ci, gi], gc)
                            }
                        default: break
                        }
                    }
                default: break
                }
            }
        }
        return nil
    }

    // MARK: - Pen tool backward-compatibility

    func penFinish(forceClose: Bool = false) {
        guard let ctx = toolContext, let penTool = tools[.pen] as? PenTool else { return }
        penTool.finish(ctx, close: forceClose)
    }

    func penCancel() {
        guard let penTool = tools[.pen] as? PenTool else { return }
        penTool.points.removeAll()
        penTool.penState = .idle
        needsDisplay = true
    }

    // MARK: - Event dispatch

    override func keyDown(with event: NSEvent) {
        // If the active tool is in an editing session, route ALL key events
        // (including shortcuts that would otherwise hit global handlers) to
        // it first. This is the "captures keyboard" path used by the type
        // tools' in-place editor.
        if let ctx = toolContext, activeTool.capturesKeyboard() {
            let key = canonicalKeyName(event)
            let mods = KeyMods(
                shift: event.modifierFlags.contains(.shift),
                ctrl: event.modifierFlags.contains(.control),
                alt: event.modifierFlags.contains(.option),
                cmd: event.modifierFlags.contains(.command)
            )
            if activeTool.onKeyEvent(ctx, key, mods) {
                ensureBlinkTimer()
                return
            }
        }
        if let ctx = toolContext, activeTool.onKey(ctx, keyCode: event.keyCode) {
            return
        }
        guard let chars = event.charactersIgnoringModifiers else {
            super.keyDown(with: event)
            return
        }
        let hasCmd = event.modifierFlags.contains(.command)
        let hasShift = event.modifierFlags.contains(.shift)
        if hasCmd && chars.lowercased() == "z" {
            if hasShift {
                controller?.model.redo()
            } else {
                controller?.model.undo()
            }
            return
        }
        switch chars {
        case "\u{7F}", "\u{F728}":  // Backspace, Forward Delete
            if let model = controller?.model, !model.document.selection.isEmpty {
                model.snapshot()
                model.document = model.document.deleteSelection()
            }
        default:
            switch chars {
            case "E": onToolChange?(.pathEraser)
            default:
                switch chars.lowercased() {
                case "v": onToolChange?(.selection)
                case "a": onToolChange?(.directSelection)
                case "p": onToolChange?(.pen)
                case "t": onToolChange?(.typeTool)
                case "\\": onToolChange?(.line)
                case "m": onToolChange?(.rect)
                case "=", "+": onToolChange?(.addAnchorPoint)
                case "-", "_": onToolChange?(.deleteAnchorPoint)
                default: super.keyDown(with: event)
                }
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if let ctx = toolContext, activeTool.onKeyUp(ctx, keyCode: event.keyCode) {
            return
        }
        super.keyUp(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        window?.makeFirstResponder(self)
        guard let ctx = toolContext else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2 {
            activeTool.onDoubleClick(ctx, x: pt.x, y: pt.y)
            ensureBlinkTimer()
            return
        }
        let shift = event.modifierFlags.contains(.shift)
        let alt = event.modifierFlags.contains(.option)
        activeTool.onPress(ctx, x: pt.x, y: pt.y, shift: shift, alt: alt)
        ensureBlinkTimer()
    }

    override func mouseMoved(with event: NSEvent) {
        guard let ctx = toolContext else { return }
        let pt = convert(event.locationInWindow, from: nil)
        activeTool.onMove(ctx, x: pt.x, y: pt.y, shift: false, dragging: false)
        // Cursor override (e.g. "none" inside the edited text) depends on
        // the live pointer position, so invalidate the cursor rects on
        // every move while a tool is editing.
        if activeTool.isEditing() {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let ctx = toolContext else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        activeTool.onMove(ctx, x: pt.x, y: pt.y, shift: shift, dragging: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let ctx = toolContext else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        let alt = event.modifierFlags.contains(.option)
        activeTool.onRelease(ctx, x: pt.x, y: pt.y, shift: shift, alt: alt)
    }

    // MARK: - Test helper

    /// Test helper: simulate a complete drag from start to end point.
    func simulateDrag(from start: NSPoint, to end: NSPoint, extend: Bool = false) {
        guard let ctx = toolContext else { return }
        activeTool.onPress(ctx, x: start.x, y: start.y, shift: extend, alt: false)
        activeTool.onMove(ctx, x: end.x, y: end.y, shift: extend, dragging: true)
        activeTool.onRelease(ctx, x: end.x, y: end.y, shift: extend, alt: false)
    }
}

/// Bridges the CoreGraphics-based CanvasNSView into SwiftUI.
struct CanvasRepresentable: NSViewRepresentable {
    let document: Document
    let controller: Controller
    @Binding var currentTool: Tool
    var onFocus: (() -> Void)?

    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView()
        view.document = document
        view.controller = controller
        view.currentTool = currentTool
        view.onToolRead = { [self] in self.currentTool }
        view.onToolChange = { [self] tool in self.currentTool = tool }
        view.onFocus = onFocus
        return view
    }

    func updateNSView(_ nsView: CanvasNSView, context: Context) {
        nsView.document = document
        nsView.controller = controller
        nsView.currentTool = currentTool
        nsView.onToolRead = { [self] in self.currentTool }
        nsView.onToolChange = { [self] tool in self.currentTool = tool }
        nsView.onFocus = onFocus
        nsView.needsDisplay = true
    }
}
