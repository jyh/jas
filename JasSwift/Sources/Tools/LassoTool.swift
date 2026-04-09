import AppKit

/// Lasso tool — freehand polygon selection.

private let minPointDist: Double = 2.0

private enum LassoState {
    case idle
    case drawing(points: [(Double, Double)], shift: Bool)
}

class LassoTool: CanvasTool {
    private var state: LassoState = .idle

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        state = .drawing(points: [(x, y)], shift: shift)
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        guard case .drawing(var points, _) = state else { return }
        if let (lx, ly) = points.last {
            let dist = ((x - lx) * (x - lx) + (y - ly) * (y - ly)).squareRoot()
            if dist >= minPointDist {
                points.append((x, y))
                state = .drawing(points: points, shift: shift)
            } else {
                state = .drawing(points: points, shift: shift)
            }
        }
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        if case .drawing(let points, let s) = state {
            let extend = s || shift
            if points.count >= 3 {
                ctx.snapshot()
                ctx.controller.selectPolygon(polygon: points, extend: extend)
            } else if !extend {
                ctx.controller.setSelection([])
            }
        }
        state = .idle
    }

    func onDoubleClick(_ ctx: ToolContext, x: Double, y: Double) {}

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        guard case .drawing(let points, _) = state, points.count >= 2 else { return }
        cgCtx.setStrokeColor(CGColor(red: 0, green: 0.47, blue: 0.84, alpha: 0.8))
        cgCtx.setFillColor(CGColor(red: 0, green: 0.47, blue: 0.84, alpha: 0.1))
        cgCtx.setLineWidth(1.0)
        cgCtx.beginPath()
        cgCtx.move(to: CGPoint(x: points[0].0, y: points[0].1))
        for i in 1..<points.count {
            cgCtx.addLine(to: CGPoint(x: points[i].0, y: points[i].1))
        }
        cgCtx.closePath()
        cgCtx.drawPath(using: .fillStroke)
    }

    func activate(_ ctx: ToolContext) { state = .idle }
    func deactivate(_ ctx: ToolContext) { state = .idle }
    func cursorOverride() -> String? { nil }
    func capturesKeyboard() -> Bool { false }
    func isEditing() -> Bool { false }
    func pasteText(_ ctx: ToolContext, _ text: String) -> Bool { false }
    func onKeyEvent(_ ctx: ToolContext, _ key: String, _ mods: KeyMods) -> Bool { false }
}
