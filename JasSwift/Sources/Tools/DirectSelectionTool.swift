import AppKit
import Foundation

// Direct Selection tool — select control points and drag Bezier handles.

class DirectSelectionTool: SelectionToolBase {
    /// Live Bezier-handle drag. Snapshotted once on press; mutated
    /// per move (no dashed ghost).
    private struct HandleDrag {
        let path: ElementPath
        let anchorIdx: Int
        let handleType: String
        var lastX: Double
        var lastY: Double
    }
    private var handleDrag: HandleDrag?

    override func selectRect(_ ctx: ToolContext, x: Double, y: Double, w: Double, h: Double, extend: Bool) {
        ctx.controller.directSelectRect(x: x, y: y, width: w, height: h, extend: extend)
    }

    override func checkHandleHit(_ ctx: ToolContext, x: Double, y: Double) -> Bool {
        let pt = NSPoint(x: x, y: y)
        if let hit = ctx.hitTestHandle(pt) {
            ctx.snapshot()
            handleDrag = HandleDrag(path: hit.path, anchorIdx: hit.anchorIdx,
                                    handleType: hit.handleType, lastX: x, lastY: y)
            return true
        }
        return false
    }

    override func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        if var hd = handleDrag {
            let dx = x - hd.lastX
            let dy = y - hd.lastY
            ctx.controller.movePathHandle(hd.path, anchorIdx: hd.anchorIdx,
                                          handleType: hd.handleType, dx: dx, dy: dy)
            hd.lastX = x
            hd.lastY = y
            handleDrag = hd
            ctx.requestUpdate()
            return
        }
        super.onMove(ctx, x: x, y: y, shift: shift, dragging: dragging)
    }

    override func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        if handleDrag != nil {
            handleDrag = nil
            ctx.requestUpdate()
            return
        }
        super.onRelease(ctx, x: x, y: y, shift: shift, alt: alt)
    }

    override func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        // Live edits — no ghost. Marquee overlay still comes from base.
        super.drawOverlay(ctx, cgCtx)
    }
}
