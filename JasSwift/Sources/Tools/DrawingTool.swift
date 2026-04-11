import AppKit
import Foundation

// Drawing tool base class shared by line / rect / rounded_rect / polygon / star.
//
// The individual drawing tools live in their own per-tool files
// (`LineTool.swift`, `RectTool.swift`, etc.) and inherit from
// `DrawingToolBase` here. This file holds only the base class.

class DrawingToolBase: CanvasTool {
    var dragStart: (Double, Double)?
    var dragEnd: (Double, Double)?

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        ctx.snapshot()
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
        if let elem = createElement(ctx, sx, sy, fx, fy) {
            ctx.controller.addElement(elem)
        }
    }

    func createElement(_ ctx: ToolContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> Element? {
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
