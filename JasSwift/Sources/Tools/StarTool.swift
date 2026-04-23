import AppKit
import Foundation

// Star tool — drag to draw an N-pointed star inscribed in the bounding box.
// starPoints() + starInnerRatio live in Geometry/RegularShapes.swift.

/// Default number of outer vertices for new stars.
let defaultStarPoints = 5

class StarTool: DrawingToolBase {
    override func createElement(_ ctx: ToolContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> Element? {
        guard abs(ex - sx) > 0 && abs(ey - sy) > 0 else { return nil }
        let pts = starPoints(sx, sy, ex, ey, defaultStarPoints)
        return .polygon(Polygon(points: pts,
                                fill: ctx.model.defaultFill, stroke: ctx.model.defaultStroke))
    }

    override func drawPreview(_ cgCtx: CGContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) {
        let pts = starPoints(sx, sy, ex, ey, defaultStarPoints)
        guard let first = pts.first else { return }
        cgCtx.move(to: CGPoint(x: first.0, y: first.1))
        for i in 1..<pts.count {
            cgCtx.addLine(to: CGPoint(x: pts[i].0, y: pts[i].1))
        }
        cgCtx.closePath()
        cgCtx.strokePath()
    }
}
