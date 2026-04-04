import AppKit
import Foundation

// MARK: - Drawing tool base

class DrawingToolBase: CanvasTool {
    var dragStart: (Double, Double)?
    var dragEnd: (Double, Double)?

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        dragStart = (x, y)
        dragEnd = (x, y)
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        guard dragStart != nil else { return }
        var fx = x, fy = y
        if shift, let s = dragStart {
            (fx, fy) = constrainAngle(s.0, s.1, x, y)
        }
        dragEnd = (fx, fy)
        ctx.requestUpdate()
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        guard let (sx, sy) = dragStart else { return }
        var fx = x, fy = y
        if shift {
            (fx, fy) = constrainAngle(sx, sy, x, y)
        }
        dragStart = nil
        dragEnd = nil
        if let elem = createElement(sx, sy, fx, fy) {
            ctx.controller.addElement(elem)
        }
    }

    func createElement(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> Element? {
        fatalError("Subclasses must implement createElement")
    }

    func drawPreview(_ cgCtx: CGContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) {
        fatalError("Subclasses must implement drawPreview")
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        guard let (sx, sy) = dragStart, let (ex, ey) = dragEnd else { return }
        cgCtx.setStrokeColor(CGColor(gray: 0.4, alpha: 1.0))
        cgCtx.setLineWidth(1.0)
        cgCtx.setLineDash(phase: 0, lengths: [4, 4])
        drawPreview(cgCtx, sx, sy, ex, ey)
        cgCtx.setLineDash(phase: 0, lengths: [])
    }
}

// MARK: - Line tool

class LineTool: DrawingToolBase {
    override func createElement(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> Element? {
        .line(JasLine(x1: sx, y1: sy, x2: ex, y2: ey,
                      stroke: JasStroke(color: JasColor(r: 0, g: 0, b: 0), width: 1.0)))
    }

    override func drawPreview(_ cgCtx: CGContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) {
        cgCtx.move(to: CGPoint(x: sx, y: sy))
        cgCtx.addLine(to: CGPoint(x: ex, y: ey))
        cgCtx.strokePath()
    }
}

// MARK: - Rect tool

class RectTool: DrawingToolBase {
    override func createElement(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> Element? {
        .rect(JasRect(x: min(sx, ex), y: min(sy, ey),
                      width: abs(ex - sx), height: abs(ey - sy),
                      stroke: JasStroke(color: JasColor(r: 0, g: 0, b: 0), width: 1.0)))
    }

    override func drawPreview(_ cgCtx: CGContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) {
        let r = CGRect(x: min(sx, ex), y: min(sy, ey),
                       width: abs(ex - sx), height: abs(ey - sy))
        cgCtx.addRect(r)
        cgCtx.strokePath()
    }
}

// MARK: - Polygon tool

class PolygonTool: DrawingToolBase {
    override func createElement(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> Element? {
        let pts = regularPolygonPoints(sx, sy, ex, ey, polygonSides)
        return .polygon(JasPolygon(points: pts,
                                    stroke: JasStroke(color: JasColor(r: 0, g: 0, b: 0), width: 1.0)))
    }

    override func drawPreview(_ cgCtx: CGContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) {
        let pts = regularPolygonPoints(sx, sy, ex, ey, polygonSides)
        guard let first = pts.first else { return }
        cgCtx.move(to: CGPoint(x: first.0, y: first.1))
        for i in 1..<pts.count {
            cgCtx.addLine(to: CGPoint(x: pts[i].0, y: pts[i].1))
        }
        cgCtx.closePath()
        cgCtx.strokePath()
    }
}
