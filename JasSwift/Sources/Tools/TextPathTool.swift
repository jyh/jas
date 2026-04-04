import AppKit
import Foundation

// MARK: - Text-on-path tool

class TextPathTool: CanvasTool {
    var dragStart: (Double, Double)?
    var dragEnd: (Double, Double)?
    var controlPt: (Double, Double)?

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        dragStart = (x, y)
        dragEnd = (x, y)
        controlPt = nil
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        guard let (sx, sy) = dragStart else { return }
        dragEnd = (x, y)
        let mx = (sx + x) / 2, my = (sy + y) / 2
        let dx = x - sx, dy = y - sy
        let dist = hypot(dx, dy)
        if dist > 4 {
            let nx = -dy / dist, ny = dx / dist
            controlPt = (mx + nx * dist * 0.3, my + ny * dist * 0.3)
        }
        ctx.requestUpdate()
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        guard let (sx, sy) = dragStart else { return }
        dragStart = nil
        dragEnd = nil
        let w = abs(x - sx), h = abs(y - sy)
        if w > 4 || h > 4 {
            let d: [PathCommand]
            if let (cx, cy) = controlPt {
                d = [.moveTo(sx, sy), .curveTo(x1: cx, y1: cy, x2: cx, y2: cy, x: x, y: y)]
            } else {
                d = [.moveTo(sx, sy), .lineTo(x, y)]
            }
            let elem = Element.textPath(JasTextPath(
                d: d, content: "Lorem Ipsum",
                fill: JasFill(color: JasColor(r: 0, g: 0, b: 0))
            ))
            ctx.controller.addElement(elem)
        }
        controlPt = nil
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        guard let (sx, sy) = dragStart, let (ex, ey) = dragEnd else { return }
        cgCtx.setStrokeColor(CGColor(gray: 0.4, alpha: 1.0))
        cgCtx.setLineWidth(1.0)
        cgCtx.setLineDash(phase: 0, lengths: [4, 4])
        cgCtx.move(to: CGPoint(x: sx, y: sy))
        if let (cx, cy) = controlPt {
            cgCtx.addCurve(to: CGPoint(x: ex, y: ey),
                           control1: CGPoint(x: cx, y: cy),
                           control2: CGPoint(x: cx, y: cy))
        } else {
            cgCtx.addLine(to: CGPoint(x: ex, y: ey))
        }
        cgCtx.strokePath()
        cgCtx.setLineDash(phase: 0, lengths: [])
    }
}
