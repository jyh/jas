import AppKit
import Foundation

// MARK: - Pen state

enum PenToolState {
    case idle       // no points placed yet
    case placing    // points placed, waiting for next click
    case dragging   // dragging a handle after placing a point
}

// MARK: - Pen point

/// A control point in the pen tool's in-progress path.
class PenPoint {
    var x: Double
    var y: Double
    var hxIn: Double
    var hyIn: Double
    var hxOut: Double
    var hyOut: Double
    var smooth: Bool

    init(x: Double, y: Double) {
        self.x = x; self.y = y
        self.hxIn = x; self.hyIn = y
        self.hxOut = x; self.hyOut = y
        self.smooth = false
    }
}

// MARK: - Pen tool

class PenTool: CanvasTool {
    private let penCloseRadius: Double = Double(hitRadius)
    private let handleSize: CGFloat = handleDrawSize
    var points: [PenPoint] = []
    var penState: PenToolState = .idle
    var mouseX: Double = 0
    var mouseY: Double = 0

    func finish(_ ctx: ToolContext, close: Bool = false) {
        guard points.count >= 2 else {
            points.removeAll()
            penState = .idle
            ctx.requestUpdate()
            return
        }
        let p0 = points[0]
        guard let pn = points.last else { return }
        let dist = hypot(pn.x - p0.x, pn.y - p0.y)
        let shouldClose = close || (points.count >= 3 && dist <= penCloseRadius)
        let skipLast = shouldClose && points.count >= 3 && dist <= penCloseRadius
        var cmds: [PathCommand] = []
        cmds.append(.moveTo(p0.x, p0.y))
        let n = skipLast ? points.count - 1 : points.count
        for i in 1..<n {
            let prev = points[i - 1]
            let curr = points[i]
            cmds.append(.curveTo(x1: prev.hxOut, y1: prev.hyOut,
                                 x2: curr.hxIn, y2: curr.hyIn,
                                 x: curr.x, y: curr.y))
        }
        if shouldClose {
            let last = points[n - 1]
            cmds.append(.curveTo(x1: last.hxOut, y1: last.hyOut,
                                 x2: p0.hxIn, y2: p0.hyIn,
                                 x: p0.x, y: p0.y))
            cmds.append(.closePath)
        }
        let elem = Element.path(Path(
            d: cmds,
            fill: ctx.model.defaultFill, stroke: ctx.model.defaultStroke
        ))
        ctx.controller.addElement(elem)
        points.removeAll()
        penState = .idle
        ctx.requestUpdate()
    }

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        ctx.snapshot()
        if points.count >= 2 {
            let p0 = points[0]
            if hypot(x - p0.x, y - p0.y) <= penCloseRadius {
                finish(ctx, close: true)
                return
            }
        }
        penState = .dragging
        points.append(PenPoint(x: x, y: y))
        ctx.requestUpdate()
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        mouseX = x
        mouseY = y
        if penState == .dragging, let pt = points.last {
            pt.hxOut = x
            pt.hyOut = y
            pt.hxIn = 2 * pt.x - x
            pt.hyIn = 2 * pt.y - y
            pt.smooth = true
        }
        ctx.requestUpdate()
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        if penState == .dragging { penState = .placing }
        ctx.requestUpdate()
    }

    func onDoubleClick(_ ctx: ToolContext, x: Double, y: Double) {
        if !points.isEmpty { points.removeLast() }
        finish(ctx)
    }

    func onKey(_ ctx: ToolContext, keyCode: UInt16) -> Bool {
        if !points.isEmpty && (keyCode == 53 || keyCode == 36 || keyCode == 76) {
            finish(ctx)
            return true
        }
        return false
    }

    func deactivate(_ ctx: ToolContext) {
        if !points.isEmpty {
            finish(ctx)
        }
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        guard !points.isEmpty else { return }
        let selColor = toolSelectionColor

        // Draw committed curve segments
        if points.count >= 2 {
            cgCtx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            cgCtx.setLineWidth(1.0)
            cgCtx.setLineDash(phase: 0, lengths: [])
            cgCtx.move(to: CGPoint(x: points[0].x, y: points[0].y))
            for i in 1..<points.count {
                let prev = points[i - 1]
                let curr = points[i]
                cgCtx.addCurve(to: CGPoint(x: curr.x, y: curr.y),
                               control1: CGPoint(x: prev.hxOut, y: prev.hyOut),
                               control2: CGPoint(x: curr.hxIn, y: curr.hyIn))
            }
            cgCtx.strokePath()
        }

        // Draw preview curve from last point to mouse
        if penState != .dragging, let last = points.last {
            let p0 = points[0]
            let nearStart = points.count >= 2 && hypot(mouseX - p0.x, mouseY - p0.y) <= penCloseRadius
            cgCtx.setStrokeColor(CGColor(gray: 0.4, alpha: 1))
            cgCtx.setLineWidth(1.0)
            cgCtx.setLineDash(phase: 0, lengths: [4, 4])
            cgCtx.move(to: CGPoint(x: last.x, y: last.y))
            if nearStart {
                cgCtx.addCurve(to: CGPoint(x: p0.x, y: p0.y),
                               control1: CGPoint(x: last.hxOut, y: last.hyOut),
                               control2: CGPoint(x: p0.hxIn, y: p0.hyIn))
            } else {
                cgCtx.addCurve(to: CGPoint(x: mouseX, y: mouseY),
                               control1: CGPoint(x: last.hxOut, y: last.hyOut),
                               control2: CGPoint(x: mouseX, y: mouseY))
            }
            cgCtx.strokePath()
            cgCtx.setLineDash(phase: 0, lengths: [])
        }

        // Draw handle lines and anchor points
        let half = handleSize / 2
        for pt in points {
            if pt.smooth {
                cgCtx.setStrokeColor(selColor)
                cgCtx.setLineWidth(1.0)
                cgCtx.move(to: CGPoint(x: pt.hxIn, y: pt.hyIn))
                cgCtx.addLine(to: CGPoint(x: pt.hxOut, y: pt.hyOut))
                cgCtx.strokePath()
                let r: CGFloat = 3.0
                for (hx, hy) in [(pt.hxIn, pt.hyIn), (pt.hxOut, pt.hyOut)] {
                    let rect = CGRect(x: hx - r, y: hy - r, width: r * 2, height: r * 2)
                    cgCtx.setFillColor(.white)
                    cgCtx.fillEllipse(in: rect)
                    cgCtx.setStrokeColor(selColor)
                    cgCtx.strokeEllipse(in: rect)
                }
            }
            let rect = CGRect(x: pt.x - half, y: pt.y - half, width: handleSize, height: handleSize)
            cgCtx.setFillColor(selColor)
            cgCtx.fill(rect)
            cgCtx.setStrokeColor(selColor)
            cgCtx.stroke(rect)
        }
    }
}
