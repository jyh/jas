import AppKit
import Foundation

// Selection tool — marquee select elements, drag-to-move, Alt+drag copies.
//
// This file also defines `SelectionToolBase`, the shared base class for
// the three selection variants. `DirectSelectionTool` and `GroupSelectionTool`
// live in their own files and inherit from `SelectionToolBase` here.

// MARK: - Selection state
//
// The selection tools use a live-edit model: the press records where
// the drag started, and on the first `onMove` past `dragThreshold`
// the document is snapshotted once and mutated per-move thereafter.
// No dashed ghost — the actual element re-renders on each frame.

enum SelectionToolState {
    case idle
    case marquee(start: (Double, Double), cur: (Double, Double))
    /// Press happened on a selectable target; first move past
    /// `dragThreshold` will transition to `.moving`.
    case pendingMove(start: (Double, Double))
    /// Live drag in progress. `last` is the previous mouse position
    /// so each move applies an incremental delta.
    case moving(last: (Double, Double), copied: Bool)
}

// MARK: - Selection tool base

class SelectionToolBase: CanvasTool {
    var state: SelectionToolState = .idle
    /// `alt` modifier captured at press time. The CanvasTool protocol
    /// passes alt to onPress and onRelease but not onMove, so we
    /// remember it here for the duration of the live drag.
    var altHeldAtPress: Bool = false

    func selectRect(_ ctx: ToolContext, x: Double, y: Double, w: Double, h: Double, extend: Bool) {
        fatalError("Subclasses must implement selectRect")
    }

    func checkHandleHit(_ ctx: ToolContext, x: Double, y: Double) -> Bool {
        return false
    }

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        altHeldAtPress = alt
        if checkHandleHit(ctx, x: x, y: y) { return }
        let pt = NSPoint(x: x, y: y)
        if ctx.hitTestSelection(pt) {
            state = .pendingMove(start: (x, y))
        } else {
            state = .marquee(start: (x, y), cur: (x, y))
        }
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        switch state {
        case .idle:
            break
        case .pendingMove(let start):
            let dist = hypot(x - start.0, y - start.1)
            if dist > dragThreshold {
                ctx.snapshot()
                state = .moving(last: start, copied: false)
                // Recurse with the same coordinates so the per-move
                // delta below applies the cumulative drag.
                onMove(ctx, x: x, y: y, shift: shift, dragging: dragging)
            }
        case .moving(let last, let copied):
            var fx = x, fy = y
            if shift {
                // shift constrains to the original press direction;
                // approximate it by passing the prior position as the
                // anchor. (Live edits make perfect angle-constraint
                // hard to express; this is a reasonable compromise.)
                (fx, fy) = constrainAngle(last.0, last.1, x, y)
            }
            let dx = fx - last.0, dy = fy - last.1
            if altHeldAtPress && !copied {
                ctx.controller.copySelection(dx: dx, dy: dy)
                state = .moving(last: (fx, fy), copied: true)
            } else {
                ctx.controller.moveSelection(dx: dx, dy: dy)
                state = .moving(last: (fx, fy), copied: copied)
            }
            ctx.requestUpdate()
        case .marquee(let start, _):
            state = .marquee(start: start, cur: (x, y))
            ctx.requestUpdate()
        }
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        let wasState = state
        state = .idle
        switch wasState {
        case .moving:
            // Live-edited in onMove; nothing more to do.
            ctx.requestUpdate()
        case .pendingMove:
            // Press without significant movement on a selectable —
            // selection already happened in onPress (via the
            // subclass's hitTestSelection). Nothing to do.
            break
        case .marquee(let start, _):
            let (sx, sy) = start
            let rw = abs(x - sx)
            let rh = abs(y - sy)
            if rw > 1.0 || rh > 1.0 {
                ctx.snapshot()
                selectRect(ctx,
                           x: min(sx, x), y: min(sy, y),
                           w: rw, h: rh,
                           extend: shift)
            } else if !shift {
                // Click on empty canvas — clear the selection.
                ctx.controller.setSelection([])
            }
        case .idle:
            break
        }
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        // Only the marquee needs an overlay; live moves render the
        // updated element on the next frame.
        if case .marquee(let start, let cur) = state {
            let (sx, sy) = start
            let (ex, ey) = cur
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
