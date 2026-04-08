import AppKit
import Foundation

// Rectangle tool — drag to draw an axis-aligned rectangle.

class RectTool: DrawingToolBase {
    override func createElement(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> Element? {
        .rect(Rect(x: min(sx, ex), y: min(sy, ey),
                      width: abs(ex - sx), height: abs(ey - sy),
                      stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0)))
    }

    override func drawPreview(_ cgCtx: CGContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) {
        let r = CGRect(x: min(sx, ex), y: min(sy, ey),
                       width: abs(ex - sx), height: abs(ey - sy))
        cgCtx.addRect(r)
        cgCtx.strokePath()
    }
}
