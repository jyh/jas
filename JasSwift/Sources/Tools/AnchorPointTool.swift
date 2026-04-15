import AppKit
import Foundation

// MARK: - Anchor Point (Convert) Tool
//
// Three interactions, mirroring jas_dioxus/src/tools/anchor_point_tool.rs:
//
// - Drag on a corner anchor: pull out symmetric control handles → smooth.
// - Click on a smooth anchor (no drag): collapse handles to anchor → corner.
// - Drag on a control handle: move that handle independently → cusp.
//
// Hit-test priority: handles before anchors.

private enum AnchorPointState {
    case idle
    /// Dragging from a corner anchor to pull out handles.
    case draggingCorner(path: ElementPath, pe: Path, anchorIdx: Int, startX: Double, startY: Double)
    /// Dragging a control handle independently (cusp).
    case draggingHandle(path: ElementPath, pe: Path, anchorIdx: Int, handleType: String,
                        startHx: Double, startHy: Double)
    /// Pressed on a smooth anchor; converts to corner on release if no drag.
    case pressedSmooth(path: ElementPath, pe: Path, anchorIdx: Int, startX: Double, startY: Double)
}

final class AnchorPointTool: CanvasTool {
    private var state: AnchorPointState = .idle

    // MARK: - Hit testing

    /// Iterate every Path element in the document, walking into unlocked
    /// groups one level deep, and return the first one for which `body`
    /// produces a non-nil result. Returns `(elementPath, hit)`.
    private static func eachPath<R>(
        _ doc: Document,
        _ body: (Path) -> R?
    ) -> (ElementPath, Path, R)? {
        for (li, layer) in doc.layers.enumerated() {
            for (ci, child) in layer.children.enumerated() {
                if case .path(let pe) = child, let r = body(pe) {
                    return ([li, ci], pe, r)
                }
                if case .group(let g) = child, !g.locked {
                    for (gi, gc) in g.children.enumerated() {
                        if case .path(let pe) = gc, let r = body(pe) {
                            return ([li, ci, gi], pe, r)
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Anchor positions of a path, indexed by anchor index (skipping closePath).
    private static func anchorPoints(_ d: [PathCommand]) -> [(Double, Double)] {
        var pts: [(Double, Double)] = []
        for cmd in d {
            switch cmd {
            case .moveTo(let x, let y), .lineTo(let x, let y):
                pts.append((x, y))
            case .curveTo(_, _, _, _, let x, let y):
                pts.append((x, y))
            case .closePath:
                continue
            default:
                if let ep = cmd.endpoint { pts.append(ep) }
            }
        }
        return pts
    }

    /// Find an anchor index whose position is within `hitRadius` of (px, py).
    private static func findAnchorAt(_ pe: Path, px: Double, py: Double) -> Int? {
        let pts = anchorPoints(pe.d)
        for (i, p) in pts.enumerated() {
            if hypot(px - p.0, py - p.1) < Double(hitRadius) {
                return i
            }
        }
        return nil
    }

    /// Hit-test handles on a single path. Returns (anchorIdx, handleType, hx, hy).
    private static func findHandleAt(_ pe: Path, px: Double, py: Double)
        -> (Int, String, Double, Double)? {
        let anchorCount = anchorPoints(pe.d).count
        for ai in 0..<anchorCount {
            let (hIn, hOut) = pathHandlePositions(pe.d, anchorIdx: ai)
            if let (hx, hy) = hIn,
               hypot(px - hx, py - hy) < Double(hitRadius) {
                return (ai, "in", hx, hy)
            }
            if let (hx, hy) = hOut,
               hypot(px - hx, py - hy) < Double(hitRadius) {
                return (ai, "out", hx, hy)
            }
        }
        return nil
    }

    // MARK: - Selection helper

    private static func selectAllCps(_ ctx: ToolContext, path: ElementPath) {
        let doc = ctx.document
        var newSelection = doc.selection.filter { $0.path != path }
        newSelection.insert(ElementSelection.all(path))
        let newDoc = Document(layers: doc.layers,
                              selectedLayer: doc.selectedLayer,
                              selection: newSelection)
        ctx.controller.setDocument(newDoc)
    }

    /// Apply a path-command transformation to the path at `path` and push
    /// the result back into the model. Preserves all non-`d` Path fields.
    private static func replacePathCommands(_ ctx: ToolContext,
                                            path: ElementPath,
                                            pe: Path,
                                            newCmds: [PathCommand]) {
        let newElem = Element.path(Path(d: newCmds, fill: pe.fill, stroke: pe.stroke,
                                        widthPoints: pe.widthPoints,
                                        opacity: pe.opacity, transform: pe.transform,
                                        locked: pe.locked, visibility: pe.visibility))
        let newDoc = ctx.document.replaceElement(path, with: newElem)
        ctx.controller.setDocument(newDoc)
        ctx.requestUpdate()
    }

    // MARK: - CanvasTool protocol

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        let doc = ctx.document

        // 1. Handle hit takes priority (cusp behaviour).
        if let (path, pe, hit) = Self.eachPath(doc, { Self.findHandleAt($0, px: x, py: y) }) {
            let (ai, handleType, hx, hy) = hit
            state = .draggingHandle(path: path, pe: pe, anchorIdx: ai,
                                    handleType: handleType, startHx: hx, startHy: hy)
            return
        }

        // 2. Anchor hit.
        if let (path, pe, ai) = Self.eachPath(doc, { Self.findAnchorAt($0, px: x, py: y) }) {
            if isSmoothPoint(pe.d, anchorIdx: ai) {
                state = .pressedSmooth(path: path, pe: pe, anchorIdx: ai, startX: x, startY: y)
            } else {
                state = .draggingCorner(path: path, pe: pe, anchorIdx: ai, startX: x, startY: y)
            }
        }
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        guard dragging else { return }
        switch state {
        case .draggingCorner(let path, let pe, let ai, _, _):
            // Live preview: pull out symmetric handles toward (x, y).
            let newCmds = convertCornerToSmooth(pe.d, anchorIdx: ai, hx: x, hy: y)
            Self.replacePathCommands(ctx, path: path, pe: pe, newCmds: newCmds)

        case .draggingHandle(let path, let pe, let ai, let handleType, let startHx, let startHy):
            let dx = x - startHx
            let dy = y - startHy
            let newCmds = movePathHandleIndependent(pe.d, anchorIdx: ai,
                                                    handleType: handleType, dx: dx, dy: dy)
            Self.replacePathCommands(ctx, path: path, pe: pe, newCmds: newCmds)

        case .pressedSmooth(let path, let pe, let ai, let sx, let sy):
            // Once the user has dragged > 3px from a smooth point, behave
            // like a corner-drag: collapse handles to anchor first, then
            // pull out new handles toward the cursor.
            let dist = hypot(x - sx, y - sy)
            if dist > 3.0 {
                let cornerCmds = convertSmoothToCorner(pe.d, anchorIdx: ai)
                let newCmds = convertCornerToSmooth(cornerCmds, anchorIdx: ai, hx: x, hy: y)
                Self.replacePathCommands(ctx, path: path, pe: pe, newCmds: newCmds)
                let cornerPe = Path(d: cornerCmds, fill: pe.fill, stroke: pe.stroke,
                                    opacity: pe.opacity, transform: pe.transform,
                                    locked: pe.locked, visibility: pe.visibility)
                state = .draggingCorner(path: path, pe: cornerPe, anchorIdx: ai,
                                        startX: sx, startY: sy)
            }

        case .idle:
            break
        }
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        let s = state
        state = .idle
        switch s {
        case .pressedSmooth(let path, let pe, let ai, _, _):
            // Click on a smooth point → convert to corner.
            ctx.snapshot()
            let newCmds = convertSmoothToCorner(pe.d, anchorIdx: ai)
            Self.replacePathCommands(ctx, path: path, pe: pe, newCmds: newCmds)
            Self.selectAllCps(ctx, path: path)

        case .draggingCorner(let path, let pe, let ai, let sx, let sy):
            let dist = hypot(x - sx, y - sy)
            if dist > 1.0 {
                ctx.snapshot()
                let newCmds = convertCornerToSmooth(pe.d, anchorIdx: ai, hx: x, hy: y)
                Self.replacePathCommands(ctx, path: path, pe: pe, newCmds: newCmds)
                Self.selectAllCps(ctx, path: path)
            }

        case .draggingHandle(let path, let pe, let ai, let handleType, let startHx, let startHy):
            let dx = x - startHx
            let dy = y - startHy
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                ctx.snapshot()
                let newCmds = movePathHandleIndependent(pe.d, anchorIdx: ai,
                                                        handleType: handleType, dx: dx, dy: dy)
                Self.replacePathCommands(ctx, path: path, pe: pe, newCmds: newCmds)
                Self.selectAllCps(ctx, path: path)
            }

        case .idle:
            break
        }
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        // No overlay; the canvas already draws path handles for the active path.
    }
}
