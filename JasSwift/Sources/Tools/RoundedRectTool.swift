import AppKit
import Foundation

// Rounded Rectangle tool — drag to draw a rectangle with fixed corner radius.

/// Default corner radius (in points) for new rounded rectangles.
let roundedRectRadius: Double = 10.0

class RoundedRectTool: DrawingToolBase {
    override func createElement(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> Element? {
        let w = abs(ex - sx)
        let h = abs(ey - sy)
        guard w > 0 && h > 0 else { return nil }
        return .rect(Rect(x: min(sx, ex), y: min(sy, ey),
                          width: w, height: h,
                          rx: roundedRectRadius, ry: roundedRectRadius,
                          stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0)))
    }

    override func drawPreview(_ cgCtx: CGContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) {
        let r = CGRect(x: min(sx, ex), y: min(sy, ey),
                       width: abs(ex - sx), height: abs(ey - sy))
        let radius = min(roundedRectRadius, r.width / 2.0, r.height / 2.0)
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        cgCtx.addPath(path)
        cgCtx.strokePath()
    }
}
