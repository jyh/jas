import AppKit
import Foundation

// Polygon tool — drag to draw a regular polygon with N sides.

class PolygonTool: DrawingToolBase {
    override func createElement(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> Element? {
        let pts = regularPolygonPoints(sx, sy, ex, ey, polygonSides)
        return .polygon(Polygon(points: pts,
                                    stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0)))
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
