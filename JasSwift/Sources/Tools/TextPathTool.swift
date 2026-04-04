import AppKit
import Foundation

// MARK: - Text-on-path tool

private let offsetHandleRadius = 5.0

class TextPathTool: CanvasTool {
    var dragStart: (Double, Double)?
    var dragEnd: (Double, Double)?
    var controlPt: (Double, Double)?
    // Offset handle drag state
    var offsetDragging = false
    var offsetDragPath: ElementPath?
    var offsetPreview: Double?

    // Find if (x,y) is near the start-offset handle of a selected TextPath.
    private func findSelectedTextPathHandle(_ ctx: ToolContext, x: Double, y: Double)
        -> (ElementPath, JasTextPath)? {
        let r = offsetHandleRadius + 2
        for es in ctx.document.selection {
            let elem = ctx.document.getElement(es.path)
            if case .textPath(let tp) = elem, !tp.d.isEmpty {
                let (hx, hy) = pathPointAtOffset(tp.d, t: tp.startOffset)
                if abs(x - hx) <= r && abs(y - hy) <= r {
                    return (es.path, tp)
                }
            }
        }
        return nil
    }

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        // 1) Check offset handle drag
        if let (path, _) = findSelectedTextPathHandle(ctx, x: x, y: y) {
            offsetDragging = true
            offsetDragPath = path
            offsetPreview = nil
            return
        }
        // 2) Start drag-create
        dragStart = (x, y)
        dragEnd = (x, y)
        controlPt = nil
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        // Offset handle drag
        if offsetDragging, let path = offsetDragPath {
            let elem = ctx.document.getElement(path)
            if case .textPath(let tp) = elem, !tp.d.isEmpty {
                offsetPreview = pathClosestOffset(tp.d, px: x, py: y)
                ctx.requestUpdate()
            }
            return
        }
        // Drag-create
        guard let (sx, sy) = dragStart else { return }
        dragEnd = (x, y)
        let dx = x - sx, dy = y - sy
        let dist = hypot(dx, dy)
        if dist > 4 {
            let nx = -dy / dist, ny = dx / dist
            let mx = (sx + x) / 2, my = (sy + y) / 2
            controlPt = (mx + nx * dist * 0.3, my + ny * dist * 0.3)
        }
        ctx.requestUpdate()
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        // Offset handle drag commit
        if offsetDragging, let path = offsetDragPath {
            if let newOffset = offsetPreview {
                let elem = ctx.document.getElement(path)
                if case .textPath(let tp) = elem {
                    let newElem = Element.textPath(JasTextPath(
                        d: tp.d, content: tp.content, startOffset: newOffset,
                        fontFamily: tp.fontFamily, fontSize: tp.fontSize,
                        fill: tp.fill, stroke: tp.stroke,
                        opacity: tp.opacity, transform: tp.transform
                    ))
                    let newDoc = ctx.document.replaceElement(path, with: newElem)
                    ctx.controller.setDocument(newDoc)
                }
            }
            offsetDragging = false
            offsetDragPath = nil
            offsetPreview = nil
            ctx.requestUpdate()
            return
        }

        guard let (sx, sy) = dragStart else { return }
        dragStart = nil
        dragEnd = nil
        let w = abs(x - sx), h = abs(y - sy)

        if w <= 4 && h <= 4 {
            // Click (not drag): check if we hit a Path to convert
            if let (path, elem) = ctx.hitTestPathCurve(x, y) {
                switch elem {
                case .path(let v):
                    let startOff = pathClosestOffset(v.d, px: x, py: y)
                    let tp = JasTextPath(
                        d: v.d, content: "", startOffset: startOff,
                        fontSize: 16.0,
                        fill: JasFill(color: JasColor(r: 0, g: 0, b: 0))
                    )
                    let newDoc = ctx.document.replaceElement(path, with: .textPath(tp))
                    ctx.controller.setDocument(newDoc)
                    ctx.controller.selectElement(path)
                    ctx.startTextEdit(path, .textPath(tp))
                    ctx.requestUpdate()
                case .textPath:
                    ctx.controller.selectElement(path)
                    ctx.startTextEdit(path, elem)
                    ctx.requestUpdate()
                default: break
                }
            }
        } else {
            // Drag: create a new text-on-path element
            let d: [PathCommand]
            if let (cx, cy) = controlPt {
                d = [.moveTo(sx, sy), .curveTo(x1: cx, y1: cy, x2: cx, y2: cy, x: x, y: y)]
            } else {
                d = [.moveTo(sx, sy), .lineTo(x, y)]
            }
            let tp = JasTextPath(
                d: d, content: "Lorem Ipsum",
                fill: JasFill(color: JasColor(r: 0, g: 0, b: 0))
            )
            let elem = Element.textPath(tp)
            ctx.controller.addElement(elem)
            // Select newly created element and start editing
            let doc = ctx.document
            let li = doc.selectedLayer
            let ci = doc.layers[li].children.count - 1
            let path: ElementPath = [li, ci]
            ctx.controller.selectElement(path)
            ctx.startTextEdit(path, elem)
        }
        controlPt = nil
        ctx.requestUpdate()
    }

    func onDoubleClick(_ ctx: ToolContext, x: Double, y: Double) {
        if let (path, elem) = ctx.hitTestPathCurve(x, y) {
            if case .textPath = elem {
                ctx.controller.selectElement(path)
                ctx.startTextEdit(path, elem)
                ctx.requestUpdate()
            }
        }
    }

    func deactivate(_ ctx: ToolContext) {
        ctx.commitTextEdit()
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        // Draw drag-create preview
        if let (sx, sy) = dragStart, let (ex, ey) = dragEnd {
            cgCtx.setStrokeColor(CGColor(gray: 0.4, alpha: 1.0))
            cgCtx.setLineWidth(1.0)
            cgCtx.setLineDash(phase: 0, lengths: [4, 4])
            cgCtx.move(to: CGPoint(x: sx, y: sy))
            if let (cx, cy) = controlPt {
                cgCtx.addCurve(to: CGPoint(x: ex, y: ey),
                               control1: CGPoint(x: cx, y: cy),
                               control2: CGPoint(x: cx, y: cy))
            } else {
                cgCtx.addLine(to: CGPoint(x: ex, y: ey))
            }
            cgCtx.strokePath()
            cgCtx.setLineDash(phase: 0, lengths: [])
        }

        // Draw offset handle for selected TextPath elements
        for es in ctx.document.selection {
            let elem = ctx.document.getElement(es.path)
            if case .textPath(let tp) = elem, !tp.d.isEmpty {
                let offset: Double
                if offsetDragging && offsetDragPath == es.path, let preview = offsetPreview {
                    offset = preview
                } else {
                    offset = tp.startOffset
                }
                let (hx, hy) = pathPointAtOffset(tp.d, t: offset)
                let r = offsetHandleRadius
                // Diamond shape
                cgCtx.setLineWidth(1.5)
                cgCtx.move(to: CGPoint(x: hx, y: hy - r))
                cgCtx.addLine(to: CGPoint(x: hx + r, y: hy))
                cgCtx.addLine(to: CGPoint(x: hx, y: hy + r))
                cgCtx.addLine(to: CGPoint(x: hx - r, y: hy))
                cgCtx.closePath()
                cgCtx.setFillColor(CGColor(red: 1.0, green: 0.78, blue: 0.31, alpha: 1.0))
                cgCtx.fillPath()
                cgCtx.move(to: CGPoint(x: hx, y: hy - r))
                cgCtx.addLine(to: CGPoint(x: hx + r, y: hy))
                cgCtx.addLine(to: CGPoint(x: hx, y: hy + r))
                cgCtx.addLine(to: CGPoint(x: hx - r, y: hy))
                cgCtx.closePath()
                cgCtx.setStrokeColor(CGColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1.0))
                cgCtx.strokePath()
            }
        }
    }
}
