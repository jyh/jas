import AppKit
import Foundation

/// Pencil tool for freehand drawing with automatic Bezier curve fitting.
class PencilTool: CanvasTool {
    private let fitError: Double = 4.0
    private var points: [(Double, Double)] = []
    private var drawing = false

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        ctx.snapshot()
        drawing = true
        points = [(x, y)]
        ctx.requestUpdate()
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        if drawing {
            points.append((x, y))
            ctx.requestUpdate()
        }
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        guard drawing else { return }
        drawing = false
        points.append((x, y))
        finish(ctx)
    }

    private func finish(_ ctx: ToolContext) {
        guard points.count >= 2 else {
            points.removeAll()
            ctx.requestUpdate()
            return
        }
        let segments = fitCurve(points: points, error: fitError)
        guard !segments.isEmpty else {
            points.removeAll()
            ctx.requestUpdate()
            return
        }
        var cmds: [PathCommand] = []
        cmds.append(.moveTo(segments[0].p1x, segments[0].p1y))
        for seg in segments {
            cmds.append(.curveTo(x1: seg.c1x, y1: seg.c1y,
                                 x2: seg.c2x, y2: seg.c2y,
                                 x: seg.p2x, y: seg.p2y))
        }
        let elem = Element.path(Path(
            d: cmds,
            stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0)
        ))
        ctx.controller.addElement(elem)
        points.removeAll()
        ctx.requestUpdate()
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        guard drawing, points.count >= 2 else { return }
        cgCtx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        cgCtx.setLineWidth(1.0)
        cgCtx.move(to: CGPoint(x: points[0].0, y: points[0].1))
        for i in 1..<points.count {
            cgCtx.addLine(to: CGPoint(x: points[i].0, y: points[i].1))
        }
        cgCtx.strokePath()
    }
}
