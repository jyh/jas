import AppKit
import Foundation

// MARK: - Text tool

class TextTool: CanvasTool {
    var dragStart: (Double, Double)?
    var dragEnd: (Double, Double)?

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        ctx.snapshot()
        dragStart = (x, y)
        dragEnd = (x, y)
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        guard dragStart != nil else { return }
        dragEnd = (x, y)
        ctx.requestUpdate()
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        guard let (sx, sy) = dragStart else { return }
        dragStart = nil
        dragEnd = nil
        let w = abs(x - sx)
        let h = abs(y - sy)
        if w > 4 || h > 4 {
            let bx = min(sx, x), by = min(sy, y)
            let elem = Element.text(JasText(
                x: bx, y: by, content: "Lorem Ipsum",
                width: w, height: h,
                fill: JasFill(color: JasColor(r: 0, g: 0, b: 0))
            ))
            ctx.controller.addElement(elem)
        } else {
            let pt = NSPoint(x: sx, y: sy)
            if let (path, textElem) = ctx.hitTestText(pt) {
                ctx.startTextEdit(path, .text(textElem))
            } else {
                let elem = Element.text(JasText(
                    x: sx, y: sy, content: "Lorem Ipsum",
                    fill: JasFill(color: JasColor(r: 0, g: 0, b: 0))
                ))
                ctx.controller.addElement(elem)
            }
        }
    }

    func deactivate(_ ctx: ToolContext) {
        ctx.commitTextEdit()
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        guard let (sx, sy) = dragStart, let (ex, ey) = dragEnd else { return }
        cgCtx.setStrokeColor(CGColor(gray: 0.4, alpha: 1.0))
        cgCtx.setLineWidth(1.0)
        cgCtx.setLineDash(phase: 0, lengths: [4, 4])
        let r = CGRect(x: min(sx, ex), y: min(sy, ey),
                       width: abs(ex - sx), height: abs(ey - sy))
        cgCtx.addRect(r)
        cgCtx.strokePath()
        cgCtx.setLineDash(phase: 0, lengths: [])
    }
}
