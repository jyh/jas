import AppKit
import Foundation

// MARK: - Tool context

/// Facade passed to tools giving access to model, controller, and canvas services.
class ToolContext {
    let model: JasModel
    let controller: Controller
    let hitTestSelection: (NSPoint) -> Bool
    let hitTestHandle: (NSPoint) -> (path: ElementPath, anchorIdx: Int, handleType: String)?
    let hitTestText: (NSPoint) -> (ElementPath, JasText)?
    let requestUpdate: () -> Void
    let startTextEdit: (ElementPath, JasText) -> Void
    let commitTextEdit: () -> Void
    let drawElementOverlayFn: (CGContext, Element, Set<Int>) -> Void

    init(model: JasModel,
         controller: Controller,
         hitTestSelection: @escaping (NSPoint) -> Bool,
         hitTestHandle: @escaping (NSPoint) -> (path: ElementPath, anchorIdx: Int, handleType: String)?,
         hitTestText: @escaping (NSPoint) -> (ElementPath, JasText)?,
         requestUpdate: @escaping () -> Void,
         startTextEdit: @escaping (ElementPath, JasText) -> Void,
         commitTextEdit: @escaping () -> Void,
         drawElementOverlay: @escaping (CGContext, Element, Set<Int>) -> Void) {
        self.model = model
        self.controller = controller
        self.hitTestSelection = hitTestSelection
        self.hitTestHandle = hitTestHandle
        self.hitTestText = hitTestText
        self.requestUpdate = requestUpdate
        self.startTextEdit = startTextEdit
        self.commitTextEdit = commitTextEdit
        self.drawElementOverlayFn = drawElementOverlay
    }

    var document: JasDocument { model.document }
}

// MARK: - CanvasTool protocol

/// Interface for canvas interaction tools.
protocol CanvasTool: AnyObject {
    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool)
    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool)
    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool)
    func onDoubleClick(_ ctx: ToolContext, x: Double, y: Double)
    func onKey(_ ctx: ToolContext, keyCode: UInt16) -> Bool
    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext)
    func activate(_ ctx: ToolContext)
    func deactivate(_ ctx: ToolContext)
}

/// Default implementations for optional protocol methods.
extension CanvasTool {
    func onDoubleClick(_ ctx: ToolContext, x: Double, y: Double) {}
    func onKey(_ ctx: ToolContext, keyCode: UInt16) -> Bool { false }
    func activate(_ ctx: ToolContext) {}
    func deactivate(_ ctx: ToolContext) {}
}

// MARK: - Helpers

private let toolSelectionColor = CGColor(red: 0, green: 0.47, blue: 1.0, alpha: 1.0)

private func constrainAngle(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> (Double, Double) {
    let dx = ex - sx, dy = ey - sy
    let dist = hypot(dx, dy)
    guard dist > 0 else { return (ex, ey) }
    let angle = atan2(dy, dx)
    let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
    return (sx + dist * cos(snapped), sy + dist * sin(snapped))
}

private let polygonSides = 5

private func regularPolygonPoints(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ n: Int) -> [(Double, Double)] {
    let ex = x2 - x1, ey = y2 - y1
    let s = hypot(ex, ey)
    guard s > 0 else { return Array(repeating: (x1, y1), count: n) }
    let mx = (x1 + x2) / 2, my = (y1 + y2) / 2
    let px = -ey / s, py = ex / s
    let d = s / (2 * tan(.pi / Double(n)))
    let cx = mx + d * px, cy = my + d * py
    let r = s / (2 * sin(.pi / Double(n)))
    let theta0 = atan2(y1 - cy, x1 - cx)
    return (0..<n).map { k in
        let angle = theta0 + 2 * .pi * Double(k) / Double(n)
        return (cx + r * cos(angle), cy + r * sin(angle))
    }
}

// MARK: - Pen tool support

/// A control point in the pen tool's in-progress path.
class PenPoint {
    var x: Double
    var y: Double
    var hxIn: Double
    var hyIn: Double
    var hxOut: Double
    var hyOut: Double
    var smooth: Bool

    init(x: Double, y: Double) {
        self.x = x; self.y = y
        self.hxIn = x; self.hyIn = y
        self.hxOut = x; self.hyOut = y
        self.smooth = false
    }
}

// MARK: - Selection tools

class SelectionToolBase: CanvasTool {
    var dragStart: (Double, Double)?
    var dragEnd: (Double, Double)?
    var moving: Bool = false

    func selectRect(_ ctx: ToolContext, x: Double, y: Double, w: Double, h: Double, extend: Bool) {
        fatalError("Subclasses must implement selectRect")
    }

    func checkHandleHit(_ ctx: ToolContext, x: Double, y: Double) -> Bool {
        return false
    }

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        if checkHandleHit(ctx, x: x, y: y) { return }
        let pt = NSPoint(x: x, y: y)
        if ctx.hitTestSelection(pt) {
            dragStart = (x, y)
            dragEnd = (x, y)
            moving = true
            return
        }
        dragStart = (x, y)
        dragEnd = (x, y)
        moving = false
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
        if shift && moving {
            (fx, fy) = constrainAngle(sx, sy, x, y)
        }
        dragStart = nil
        dragEnd = nil
        let wasMoving = moving
        moving = false
        if wasMoving {
            let dx = fx - sx, dy = fy - sy
            if dx != 0 || dy != 0 {
                if alt {
                    ctx.controller.copySelection(dx: dx, dy: dy)
                } else {
                    ctx.controller.moveSelection(dx: dx, dy: dy)
                }
            }
            ctx.requestUpdate()
            return
        }
        selectRect(ctx,
                   x: min(sx, fx), y: min(sy, fy),
                   w: abs(fx - sx), h: abs(fy - sy),
                   extend: shift)
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        guard let (sx, sy) = dragStart, let (ex, ey) = dragEnd else { return }
        if moving {
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

class SelectionTool: SelectionToolBase {
    override func selectRect(_ ctx: ToolContext, x: Double, y: Double, w: Double, h: Double, extend: Bool) {
        ctx.controller.selectRect(x: x, y: y, width: w, height: h, extend: extend)
    }
}

class GroupSelectionTool: SelectionToolBase {
    override func selectRect(_ ctx: ToolContext, x: Double, y: Double, w: Double, h: Double, extend: Bool) {
        ctx.controller.groupSelectRect(x: x, y: y, width: w, height: h, extend: extend)
    }
}

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
                let moved = Element.path(JasPath(d: newD, fill: v.fill, stroke: v.stroke,
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

// MARK: - Drawing tools

class DrawingToolBase: CanvasTool {
    var dragStart: (Double, Double)?
    var dragEnd: (Double, Double)?

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
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
        if let elem = createElement(sx, sy, fx, fy) {
            ctx.controller.addElement(elem)
        }
    }

    func createElement(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> Element? {
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

class LineTool: DrawingToolBase {
    override func createElement(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> Element? {
        .line(JasLine(x1: sx, y1: sy, x2: ex, y2: ey,
                      stroke: JasStroke(color: JasColor(r: 0, g: 0, b: 0), width: 1.0)))
    }

    override func drawPreview(_ cgCtx: CGContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) {
        cgCtx.move(to: CGPoint(x: sx, y: sy))
        cgCtx.addLine(to: CGPoint(x: ex, y: ey))
        cgCtx.strokePath()
    }
}

class RectTool: DrawingToolBase {
    override func createElement(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> Element? {
        .rect(JasRect(x: min(sx, ex), y: min(sy, ey),
                      width: abs(ex - sx), height: abs(ey - sy),
                      stroke: JasStroke(color: JasColor(r: 0, g: 0, b: 0), width: 1.0)))
    }

    override func drawPreview(_ cgCtx: CGContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) {
        let r = CGRect(x: min(sx, ex), y: min(sy, ey),
                       width: abs(ex - sx), height: abs(ey - sy))
        cgCtx.addRect(r)
        cgCtx.strokePath()
    }
}

class PolygonTool: DrawingToolBase {
    override func createElement(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> Element? {
        let pts = regularPolygonPoints(sx, sy, ex, ey, polygonSides)
        return .polygon(JasPolygon(points: pts,
                                    stroke: JasStroke(color: JasColor(r: 0, g: 0, b: 0), width: 1.0)))
    }

    override func drawPreview(_ cgCtx: CGContext, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) {
        let pts = regularPolygonPoints(sx, sy, ex, ey, polygonSides)
        guard let first = pts.first else { return }
        cgCtx.move(to: CGPoint(x: first.0, y: first.1))
        for i in 1..<pts.count {
            cgCtx.addLine(to: CGPoint(x: pts[i].0, y: pts[i].1))
        }
        cgCtx.closePath()
        cgCtx.strokePath()
    }
}

// MARK: - Pen tool

class PenTool: CanvasTool {
    private let penCloseRadius: Double = 6.0
    private let handleSize: CGFloat = 6.0
    var points: [PenPoint] = []
    var penDragging: Bool = false
    var mouseX: Double = 0
    var mouseY: Double = 0

    func finish(_ ctx: ToolContext, close: Bool = false) {
        guard points.count >= 2 else {
            points.removeAll()
            penDragging = false
            ctx.requestUpdate()
            return
        }
        let p0 = points[0]
        let pn = points.last!
        let dist = hypot(pn.x - p0.x, pn.y - p0.y)
        let shouldClose = close || (points.count >= 3 && dist <= penCloseRadius)
        let skipLast = shouldClose && points.count >= 3 && dist <= penCloseRadius
        var cmds: [PathCommand] = []
        cmds.append(.moveTo(p0.x, p0.y))
        let n = skipLast ? points.count - 1 : points.count
        for i in 1..<n {
            let prev = points[i - 1]
            let curr = points[i]
            cmds.append(.curveTo(x1: prev.hxOut, y1: prev.hyOut,
                                 x2: curr.hxIn, y2: curr.hyIn,
                                 x: curr.x, y: curr.y))
        }
        if shouldClose {
            let last = points[n - 1]
            cmds.append(.curveTo(x1: last.hxOut, y1: last.hyOut,
                                 x2: p0.hxIn, y2: p0.hyIn,
                                 x: p0.x, y: p0.y))
            cmds.append(.closePath)
        }
        let elem = Element.path(JasPath(
            d: cmds,
            stroke: JasStroke(color: JasColor(r: 0, g: 0, b: 0), width: 1.0)
        ))
        ctx.controller.addElement(elem)
        points.removeAll()
        penDragging = false
        ctx.requestUpdate()
    }

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        if points.count >= 2 {
            let p0 = points[0]
            if hypot(x - p0.x, y - p0.y) <= penCloseRadius {
                finish(ctx, close: true)
                return
            }
        }
        penDragging = true
        points.append(PenPoint(x: x, y: y))
        ctx.requestUpdate()
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        mouseX = x
        mouseY = y
        if penDragging, let pt = points.last {
            pt.hxOut = x
            pt.hyOut = y
            pt.hxIn = 2 * pt.x - x
            pt.hyIn = 2 * pt.y - y
            pt.smooth = true
        }
        ctx.requestUpdate()
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        penDragging = false
        ctx.requestUpdate()
    }

    func onDoubleClick(_ ctx: ToolContext, x: Double, y: Double) {
        if !points.isEmpty { points.removeLast() }
        finish(ctx)
    }

    func onKey(_ ctx: ToolContext, keyCode: UInt16) -> Bool {
        if !points.isEmpty && (keyCode == 53 || keyCode == 36 || keyCode == 76) {
            // Escape / Return / Enter
            finish(ctx)
            return true
        }
        return false
    }

    func deactivate(_ ctx: ToolContext) {
        if !points.isEmpty {
            finish(ctx)
        }
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        guard !points.isEmpty else { return }
        let selColor = toolSelectionColor

        // Draw committed curve segments
        if points.count >= 2 {
            cgCtx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            cgCtx.setLineWidth(1.0)
            cgCtx.setLineDash(phase: 0, lengths: [])
            cgCtx.move(to: CGPoint(x: points[0].x, y: points[0].y))
            for i in 1..<points.count {
                let prev = points[i - 1]
                let curr = points[i]
                cgCtx.addCurve(to: CGPoint(x: curr.x, y: curr.y),
                               control1: CGPoint(x: prev.hxOut, y: prev.hyOut),
                               control2: CGPoint(x: curr.hxIn, y: curr.hyIn))
            }
            cgCtx.strokePath()
        }

        // Draw preview curve from last point to mouse
        if !penDragging {
            let last = points.last!
            let p0 = points[0]
            let nearStart = points.count >= 2 && hypot(mouseX - p0.x, mouseY - p0.y) <= penCloseRadius
            cgCtx.setStrokeColor(CGColor(gray: 0.4, alpha: 1))
            cgCtx.setLineWidth(1.0)
            cgCtx.setLineDash(phase: 0, lengths: [4, 4])
            cgCtx.move(to: CGPoint(x: last.x, y: last.y))
            if nearStart {
                cgCtx.addCurve(to: CGPoint(x: p0.x, y: p0.y),
                               control1: CGPoint(x: last.hxOut, y: last.hyOut),
                               control2: CGPoint(x: p0.hxIn, y: p0.hyIn))
            } else {
                cgCtx.addCurve(to: CGPoint(x: mouseX, y: mouseY),
                               control1: CGPoint(x: last.hxOut, y: last.hyOut),
                               control2: CGPoint(x: mouseX, y: mouseY))
            }
            cgCtx.strokePath()
            cgCtx.setLineDash(phase: 0, lengths: [])
        }

        // Draw handle lines and anchor points
        let half = handleSize / 2
        for pt in points {
            if pt.smooth {
                cgCtx.setStrokeColor(selColor)
                cgCtx.setLineWidth(1.0)
                cgCtx.move(to: CGPoint(x: pt.hxIn, y: pt.hyIn))
                cgCtx.addLine(to: CGPoint(x: pt.hxOut, y: pt.hyOut))
                cgCtx.strokePath()
                let r: CGFloat = 3.0
                for (hx, hy) in [(pt.hxIn, pt.hyIn), (pt.hxOut, pt.hyOut)] {
                    let rect = CGRect(x: hx - r, y: hy - r, width: r * 2, height: r * 2)
                    cgCtx.setFillColor(.white)
                    cgCtx.fillEllipse(in: rect)
                    cgCtx.setStrokeColor(selColor)
                    cgCtx.strokeEllipse(in: rect)
                }
            }
            let rect = CGRect(x: pt.x - half, y: pt.y - half, width: handleSize, height: handleSize)
            cgCtx.setFillColor(selColor)
            cgCtx.fill(rect)
            cgCtx.setStrokeColor(selColor)
            cgCtx.stroke(rect)
        }
    }
}

// MARK: - Text tool

class TextTool: CanvasTool {
    var dragStart: (Double, Double)?
    var dragEnd: (Double, Double)?

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
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
                ctx.startTextEdit(path, textElem)
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

// MARK: - Tool registry

/// Create one instance of each tool, keyed by Tool enum.
func createTools() -> [Tool: CanvasTool] {
    [
        .selection: SelectionTool(),
        .directSelection: DirectSelectionTool(),
        .groupSelection: GroupSelectionTool(),
        .pen: PenTool(),
        .text: TextTool(),
        .line: LineTool(),
        .rect: RectTool(),
        .polygon: PolygonTool(),
    ]
}
