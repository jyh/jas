import AppKit
import Foundation

// MARK: - Selection state

enum SelectionToolState {
    case idle
    case marquee    // drag-to-select rectangle
    case moving     // drag-to-move selection
}

// MARK: - Selection tool base

class SelectionToolBase: CanvasTool {
    var state: SelectionToolState = .idle
    var dragStart: (Double, Double)?
    var dragEnd: (Double, Double)?

    func selectRect(_ ctx: ToolContext, x: Double, y: Double, w: Double, h: Double, extend: Bool) {
        fatalError("Subclasses must implement selectRect")
    }

    func checkHandleHit(_ ctx: ToolContext, x: Double, y: Double) -> Bool {
        return false
    }

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        if checkHandleHit(ctx, x: x, y: y) { return }
        dragStart = (x, y)
        dragEnd = (x, y)
        let pt = NSPoint(x: x, y: y)
        state = ctx.hitTestSelection(pt) ? .moving : .marquee
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        guard state != .idle else { return }
        var fx = x, fy = y
        if shift, let s = dragStart {
            (fx, fy) = constrainAngle(s.0, s.1, x, y)
        }
        dragEnd = (fx, fy)
        ctx.requestUpdate()
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        guard state != .idle, let (sx, sy) = dragStart else { return }
        var fx = x, fy = y
        if shift && state == .moving {
            (fx, fy) = constrainAngle(sx, sy, x, y)
        }
        let wasState = state
        state = .idle
        dragStart = nil
        dragEnd = nil
        if wasState == .moving {
            let dx = fx - sx, dy = fy - sy
            if dx != 0 || dy != 0 {
                ctx.snapshot()
                if alt {
                    ctx.controller.copySelection(dx: dx, dy: dy)
                } else {
                    ctx.controller.moveSelection(dx: dx, dy: dy)
                }
            }
            ctx.requestUpdate()
            return
        }
        ctx.snapshot()
        selectRect(ctx,
                   x: min(sx, fx), y: min(sy, fy),
                   w: abs(fx - sx), h: abs(fy - sy),
                   extend: shift)
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        guard state != .idle, let (sx, sy) = dragStart, let (ex, ey) = dragEnd else { return }
        if state == .moving {
            let dx = ex - sx, dy = ey - sy
            cgCtx.setStrokeColor(toolSelectionColor)
            cgCtx.setLineWidth(1.0)
            cgCtx.setLineDash(phase: 0, lengths: [4, 4])
            for es in ctx.document.selection {
                let elem = ctx.document.getElement(es.path)
                let moved = elem.moveControlPoints(es.controlPoints, dx: dx, dy: dy)
                ctx.drawElementOverlayFn(cgCtx, moved, es.controlPoints)
            }
            cgCtx.setLineDash(phase: 0, lengths: [])
        } else {
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
}

// MARK: - Selection tool

class SelectionTool: SelectionToolBase {
    override func selectRect(_ ctx: ToolContext, x: Double, y: Double, w: Double, h: Double, extend: Bool) {
        ctx.controller.selectRect(x: x, y: y, width: w, height: h, extend: extend)
    }
}

// MARK: - Group selection tool

class GroupSelectionTool: SelectionToolBase {
    override func selectRect(_ ctx: ToolContext, x: Double, y: Double, w: Double, h: Double, extend: Bool) {
        ctx.controller.groupSelectRect(x: x, y: y, width: w, height: h, extend: extend)
    }
}

// MARK: - Direct selection tool

class DirectSelectionTool: SelectionToolBase {
    var handleDrag: (path: ElementPath, anchorIdx: Int, handleType: String)?
    var handleDragStart: (Double, Double)?
    var handleDragEnd: (Double, Double)?

    override func selectRect(_ ctx: ToolContext, x: Double, y: Double, w: Double, h: Double, extend: Bool) {
        ctx.controller.directSelectRect(x: x, y: y, width: w, height: h, extend: extend)
    }

    override func checkHandleHit(_ ctx: ToolContext, x: Double, y: Double) -> Bool {
        let pt = NSPoint(x: x, y: y)
        if let hit = ctx.hitTestHandle(pt) {
            handleDrag = hit
            handleDragStart = (x, y)
            handleDragEnd = (x, y)
            return true
        }
        return false
    }

    override func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        if handleDrag != nil {
            handleDragEnd = (x, y)
            ctx.requestUpdate()
            return
        }
        super.onMove(ctx, x: x, y: y, shift: shift, dragging: dragging)
    }

    override func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        if let hd = handleDrag, let (sx, sy) = handleDragStart {
            let dx = x - sx, dy = y - sy
            handleDrag = nil
            handleDragStart = nil
            handleDragEnd = nil
            if dx != 0 || dy != 0 {
                ctx.snapshot()
                ctx.controller.movePathHandle(hd.path, anchorIdx: hd.anchorIdx,
                                              handleType: hd.handleType, dx: dx, dy: dy)
            }
            ctx.requestUpdate()
            return
        }
        super.onRelease(ctx, x: x, y: y, shift: shift, alt: alt)
    }

    override func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        if let hd = handleDrag, let (sx, sy) = handleDragStart, let (ex, ey) = handleDragEnd {
            let dx = ex - sx, dy = ey - sy
            let elem = ctx.document.getElement(hd.path)
            if case .path(let v) = elem {
                let newD = movePathHandle(v.d, anchorIdx: hd.anchorIdx, handleType: hd.handleType, dx: dx, dy: dy)
                let moved = Element.path(Path(d: newD, fill: v.fill, stroke: v.stroke,
                                                  opacity: v.opacity, transform: v.transform))
                if let es = ctx.document.selection.first(where: { $0.path == hd.path }) {
                    cgCtx.setStrokeColor(toolSelectionColor)
                    cgCtx.setLineWidth(1.0)
                    cgCtx.setLineDash(phase: 0, lengths: [4, 4])
                    ctx.drawElementOverlayFn(cgCtx, moved, es.controlPoints)
                    cgCtx.setLineDash(phase: 0, lengths: [])
                }
            }
        }
        super.drawOverlay(ctx, cgCtx)
    }
}
