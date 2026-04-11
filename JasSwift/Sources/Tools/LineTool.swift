import AppKit
import Foundation

// Line tool — drag to draw a straight line segment.

class LineTool: DrawingToolBase {
    override func createElement(_ ctx: ToolContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> Element? {
        .line(Line(x1: sx, y1: sy, x2: ex, y2: ey,
                      stroke: ctx.model.defaultStroke))
    }

    override func drawPreview(_ cgCtx: CGContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) {
        cgCtx.move(to: CGPoint(x: sx, y: sy))
        cgCtx.addLine(to: CGPoint(x: ex, y: ey))
        cgCtx.strokePath()
    }
}
