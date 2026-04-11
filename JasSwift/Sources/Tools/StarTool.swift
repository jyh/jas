import AppKit
import Foundation

// Star tool — drag to draw an N-pointed star inscribed in the bounding box.

/// Default number of outer vertices for new stars.
let starPoints = 5

/// Ratio of inner radius to outer radius for stars.
private let starInnerRatio: Double = 0.4

/// Compute vertices of a star inscribed in the given bounding box. The star
/// has `n` outer vertices alternating with `n` inner vertices, for `2 * n`
/// total. The first outer vertex is at the top of the box.
func starShapePoints(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double,
                     _ n: Int) -> [(Double, Double)] {
    let cx = (sx + ex) / 2.0
    let cy = (sy + ey) / 2.0
    let rxOuter = abs(ex - sx) / 2.0
    let ryOuter = abs(ey - sy) / 2.0
    let rxInner = rxOuter * starInnerRatio
    let ryInner = ryOuter * starInnerRatio
    let theta0 = -Double.pi / 2.0
    return (0..<(2 * n)).map { k in
        let angle = theta0 + Double.pi * Double(k) / Double(n)
        let rx = (k % 2 == 0) ? rxOuter : rxInner
        let ry = (k % 2 == 0) ? ryOuter : ryInner
        return (cx + rx * cos(angle), cy + ry * sin(angle))
    }
}

class StarTool: DrawingToolBase {
    override func createElement(_ ctx: ToolContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> Element? {
        guard abs(ex - sx) > 0 && abs(ey - sy) > 0 else { return nil }
        let pts = starShapePoints(sx, sy, ex, ey, starPoints)
        return .polygon(Polygon(points: pts,
                                fill: ctx.model.defaultFill, stroke: ctx.model.defaultStroke))
    }

    override func drawPreview(_ cgCtx: CGContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) {
        let pts = starShapePoints(sx, sy, ex, ey, starPoints)
        guard let first = pts.first else { return }
        cgCtx.move(to: CGPoint(x: first.0, y: first.1))
        for i in 1..<pts.count {
            cgCtx.addLine(to: CGPoint(x: pts[i].0, y: pts[i].1))
        }
        cgCtx.closePath()
        cgCtx.strokePath()
    }
}
