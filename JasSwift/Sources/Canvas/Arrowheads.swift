/// Arrowhead shape definitions and rendering.
///
/// Each shape is defined as a normalized path in a unit coordinate system:
/// - Pointing right (+x direction)
/// - Tip at origin (0, 0) for tip-at-end alignment
/// - Unit size (1.0 = stroke width at 100% scale)
///
/// At render time the shape is transformed: translate to endpoint,
/// rotate to match path tangent, scale by stroke_width × scale%.

import CoreGraphics

private enum ShapeStyle {
    case filled
    case outline
}

private struct ArrowShape {
    let cmds: [PathCommand]
    let style: ShapeStyle
    let back: Double
}

// MARK: - Shape definitions (unit coords, tip at (0,0), pointing right)

private let simpleArrowCmds: [PathCommand] = [
    .moveTo(0, 0), .lineTo(-4, -2), .lineTo(-4, 2), .closePath
]
private let openArrowCmds: [PathCommand] = [
    .moveTo(-4, -2), .lineTo(0, 0), .lineTo(-4, 2)
]
private let closedArrowCmds: [PathCommand] = [
    .moveTo(0, 0), .lineTo(-4, -2), .lineTo(-4, 2), .closePath,
    .moveTo(-4.5, -2), .lineTo(-4.5, 2)
]
private let stealthArrowCmds: [PathCommand] = [
    .moveTo(0, 0), .lineTo(-4.5, -1.8), .lineTo(-3, 0), .lineTo(-4.5, 1.8), .closePath
]
private let barbedArrowCmds: [PathCommand] = [
    .moveTo(0, 0),
    .curveTo(x1: -2, y1: -0.5, x2: -3.5, y2: -1.5, x: -4.5, y: -2),
    .lineTo(-3, 0), .lineTo(-4.5, 2),
    .curveTo(x1: -3.5, y1: 1.5, x2: -2, y2: 0.5, x: 0, y: 0),
    .closePath
]
private let halfArrowUpperCmds: [PathCommand] = [
    .moveTo(0, 0), .lineTo(-4, -2), .lineTo(-4, 0), .closePath
]
private let halfArrowLowerCmds: [PathCommand] = [
    .moveTo(0, 0), .lineTo(-4, 0), .lineTo(-4, 2), .closePath
]

private let circleR = 2.0
private let kk = 0.5522847498 // bezier circle constant
private let circleCmds: [PathCommand] = [
    .moveTo(0, 0),
    .curveTo(x1: 0, y1: -circleR * kk, x2: -circleR + circleR * kk, y2: -circleR, x: -circleR, y: -circleR),
    .curveTo(x1: -circleR - circleR * kk, y1: -circleR, x2: -2 * circleR, y2: -circleR * kk, x: -2 * circleR, y: 0),
    .curveTo(x1: -2 * circleR, y1: circleR * kk, x2: -circleR - circleR * kk, y2: circleR, x: -circleR, y: circleR),
    .curveTo(x1: -circleR + circleR * kk, y1: circleR, x2: 0, y2: circleR * kk, x: 0, y: 0),
    .closePath
]
private let squareCmds: [PathCommand] = [
    .moveTo(0, -2), .lineTo(-4, -2), .lineTo(-4, 2), .lineTo(0, 2), .closePath
]
private let diamondCmds: [PathCommand] = [
    .moveTo(0, 0), .lineTo(-2.5, -2), .lineTo(-5, 0), .lineTo(-2.5, 2), .closePath
]
private let slashCmds: [PathCommand] = [
    .moveTo(0.5, -2), .lineTo(-0.5, 2)
]

private func getShape(_ name: String) -> ArrowShape? {
    switch name {
    case "none", "":          return nil
    case "simple_arrow":      return ArrowShape(cmds: simpleArrowCmds, style: .filled, back: 4)
    case "open_arrow":        return ArrowShape(cmds: openArrowCmds, style: .outline, back: 4)
    case "closed_arrow":      return ArrowShape(cmds: closedArrowCmds, style: .filled, back: 4)
    case "stealth_arrow":     return ArrowShape(cmds: stealthArrowCmds, style: .filled, back: 3)
    case "barbed_arrow":      return ArrowShape(cmds: barbedArrowCmds, style: .filled, back: 3)
    case "half_arrow_upper":  return ArrowShape(cmds: halfArrowUpperCmds, style: .filled, back: 4)
    case "half_arrow_lower":  return ArrowShape(cmds: halfArrowLowerCmds, style: .filled, back: 4)
    case "circle":            return ArrowShape(cmds: circleCmds, style: .filled, back: 2 * circleR)
    case "open_circle":       return ArrowShape(cmds: circleCmds, style: .outline, back: 2 * circleR)
    case "square":            return ArrowShape(cmds: squareCmds, style: .filled, back: 4)
    case "open_square":       return ArrowShape(cmds: squareCmds, style: .outline, back: 4)
    case "diamond":           return ArrowShape(cmds: diamondCmds, style: .filled, back: 2.5)
    case "open_diamond":      return ArrowShape(cmds: diamondCmds, style: .outline, back: 2.5)
    case "slash":             return ArrowShape(cmds: slashCmds, style: .outline, back: 0.5)
    default:                  return nil
    }
}

/// Get the path shortening distance for an arrowhead (in canvas pixels).
func arrowSetback(_ name: String, strokeWidth: Double, scalePct: Double) -> Double {
    guard let shape = getShape(name) else { return 0 }
    return shape.back * strokeWidth * scalePct / 100.0
}

/// Collect significant points from path commands for tangent computation.
private func collectPoints(_ cmds: [PathCommand]) -> [(Double, Double)] {
    var pts: [(Double, Double)] = []
    for cmd in cmds {
        switch cmd {
        case .moveTo(let x, let y), .lineTo(let x, let y):
            pts.append((x, y))
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            pts.append((x1, y1)); pts.append((x2, y2)); pts.append((x, y))
        case .quadTo(let x1, let y1, let x, let y):
            pts.append((x1, y1)); pts.append((x, y))
        case .smoothCurveTo(let x2, let y2, let x, let y):
            pts.append((x2, y2)); pts.append((x, y))
        case .smoothQuadTo(let x, let y), .arcTo(_, _, _, _, _, let x, let y):
            pts.append((x, y))
        case .closePath:
            break
        }
    }
    return pts
}

/// Compute tangent angle at the start of a path (pointing away from path interior).
func startTangent(_ cmds: [PathCommand]) -> (Double, Double, Double) {
    let pts = collectPoints(cmds)
    if pts.isEmpty { return (0, 0, 0) }
    let (sx, sy) = pts[0]
    let threshold = 0.1
    for (nx, ny) in pts.dropFirst() {
        let dx = sx - nx, dy = sy - ny
        if dx * dx + dy * dy > threshold * threshold {
            return (sx, sy, atan2(dy, dx))
        }
    }
    return (sx, sy, Double.pi)
}

/// Compute tangent angle at the end of a path (pointing along path direction).
func endTangent(_ cmds: [PathCommand]) -> (Double, Double, Double) {
    let pts = collectPoints(cmds)
    if pts.isEmpty { return (0, 0, 0) }
    let (ex, ey) = pts.last!
    let threshold = 0.1
    for (px, py) in pts.dropLast().reversed() {
        let dx = ex - px, dy = ey - py
        if dx * dx + dy * dy > threshold * threshold {
            return (ex, ey, atan2(dy, dx))
        }
    }
    return (ex, ey, 0)
}

/// Shorten a path by moving start/end points inward along their tangent.
func shortenPath(_ cmds: [PathCommand], startSetback: Double, endSetback: Double) -> [PathCommand] {
    if cmds.isEmpty { return cmds }
    var result = cmds

    if startSetback > 0 {
        let (sx, sy, angle) = startTangent(cmds)
        let dx = -cos(angle) * startSetback
        let dy = -sin(angle) * startSetback
        for i in 0..<result.count {
            if case .moveTo(let x, let y) = result[i],
               abs(x - sx) < 1e-6 && abs(y - sy) < 1e-6 {
                result[i] = .moveTo(x + dx, y + dy)
                break
            }
        }
    }

    if endSetback > 0 {
        let (ex, ey, angle) = endTangent(cmds)
        let dx = -cos(angle) * endSetback
        let dy = -sin(angle) * endSetback
        for i in stride(from: result.count - 1, through: 0, by: -1) {
            switch result[i] {
            case .lineTo(let x, let y) where abs(x - ex) < 1e-6 && abs(y - ey) < 1e-6:
                result[i] = .lineTo(x + dx, y + dy); return result
            case .curveTo(let x1, let y1, let x2, let y2, let x, let y)
                where abs(x - ex) < 1e-6 && abs(y - ey) < 1e-6:
                result[i] = .curveTo(x1: x1, y1: y1, x2: x2, y2: y2, x: x + dx, y: y + dy); return result
            case .moveTo(let x, let y) where abs(x - ex) < 1e-6 && abs(y - ey) < 1e-6:
                result[i] = .moveTo(x + dx, y + dy); return result
            default: break
            }
        }
    }

    return result
}

/// Build a CGPath from PathCommand array.
private func buildCGPath(_ cmds: [PathCommand]) -> CGPath {
    let path = CGMutablePath()
    for cmd in cmds {
        switch cmd {
        case .moveTo(let x, let y): path.move(to: CGPoint(x: x, y: y))
        case .lineTo(let x, let y): path.addLine(to: CGPoint(x: x, y: y))
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            path.addCurve(to: CGPoint(x: x, y: y),
                          control1: CGPoint(x: x1, y: y1),
                          control2: CGPoint(x: x2, y: y2))
        case .quadTo(let x1, let y1, let x, let y):
            path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x1, y: y1))
        case .closePath: path.closeSubpath()
        default: break
        }
    }
    return path
}

/// Draw a single arrowhead shape at the given position and angle.
private func drawOne(_ ctx: CGContext, _ shape: ArrowShape,
                     x: Double, y: Double, angle: Double, scale: Double,
                     strokeColor: CGColor, centerAtEnd: Bool) {
    if scale <= 0 { return }
    ctx.saveGState()
    ctx.translateBy(x: CGFloat(x), y: CGFloat(y))
    ctx.rotate(by: CGFloat(angle))
    if centerAtEnd {
        ctx.translateBy(x: CGFloat(-2.0 * scale), y: 0)
    }
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    let path = buildCGPath(shape.cmds)
    ctx.addPath(path)

    switch shape.style {
    case .filled:
        ctx.setFillColor(strokeColor)
        ctx.fillPath()
    case .outline:
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(strokeColor)
        ctx.setLineWidth(CGFloat(1.0 / scale))
        ctx.strokePath()
    }

    ctx.restoreGState()
}

/// Draw arrowheads for a path element.
func drawArrowheads(_ ctx: CGContext, cmds: [PathCommand],
                    startName: String, endName: String,
                    startScale: Double, endScale: Double,
                    strokeWidth: Double, strokeColor: CGColor,
                    centerAtEnd: Bool) {
    if let shape = getShape(startName) {
        let (x, y, angle) = startTangent(cmds)
        let s = strokeWidth * startScale / 100.0
        drawOne(ctx, shape, x: x, y: y, angle: angle, scale: s,
                strokeColor: strokeColor, centerAtEnd: centerAtEnd)
    }
    if let shape = getShape(endName) {
        let (x, y, angle) = endTangent(cmds)
        let s = strokeWidth * endScale / 100.0
        drawOne(ctx, shape, x: x, y: y, angle: angle, scale: s,
                strokeColor: strokeColor, centerAtEnd: centerAtEnd)
    }
}

/// Draw arrowheads for a line element.
func drawArrowheadsLine(_ ctx: CGContext,
                        x1: Double, y1: Double, x2: Double, y2: Double,
                        startName: String, endName: String,
                        startScale: Double, endScale: Double,
                        strokeWidth: Double, strokeColor: CGColor,
                        centerAtEnd: Bool) {
    let dx = x2 - x1, dy = y2 - y1
    let endAngle = atan2(dy, dx)
    let startAngle = atan2(y1 - y2, x1 - x2)
    if let shape = getShape(startName) {
        let s = strokeWidth * startScale / 100.0
        drawOne(ctx, shape, x: x1, y: y1, angle: startAngle, scale: s,
                strokeColor: strokeColor, centerAtEnd: centerAtEnd)
    }
    if let shape = getShape(endName) {
        let s = strokeWidth * endScale / 100.0
        drawOne(ctx, shape, x: x2, y: y2, angle: endAngle, scale: s,
                strokeColor: strokeColor, centerAtEnd: centerAtEnd)
    }
}
