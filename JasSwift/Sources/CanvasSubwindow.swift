import SwiftUI
import AppKit

/// Axis-aligned bounding box for the canvas coordinate space.
public struct CanvasBoundingBox: Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 800, height: Double = 600) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

// MARK: - Element drawing

private func nsColor(_ c: JasColor) -> NSColor {
    NSColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
}

private func cgColor(_ c: JasColor) -> CGColor {
    CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
}

private func applyTransform(_ ctx: CGContext, _ t: JasTransform?) {
    guard let t = t else { return }
    ctx.concatenate(CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.e, ty: t.f))
}

private func setFill(_ ctx: CGContext, _ fill: JasFill?) {
    if let fill = fill {
        ctx.setFillColor(cgColor(fill.color))
    }
}

private func setStroke(_ ctx: CGContext, _ stroke: JasStroke?) {
    guard let stroke = stroke else { return }
    ctx.setStrokeColor(cgColor(stroke.color))
    ctx.setLineWidth(stroke.width)
    switch stroke.linecap {
    case .butt: ctx.setLineCap(.butt)
    case .round: ctx.setLineCap(.round)
    case .square: ctx.setLineCap(.square)
    }
    switch stroke.linejoin {
    case .miter: ctx.setLineJoin(.miter)
    case .round: ctx.setLineJoin(.round)
    case .bevel: ctx.setLineJoin(.bevel)
    }
}

private func buildPath(_ ctx: CGContext, _ cmds: [PathCommand]) {
    var lastControl: CGPoint? = nil
    for cmd in cmds {
        switch cmd {
        case .moveTo(let x, let y):
            ctx.move(to: CGPoint(x: x, y: y))
            lastControl = nil
        case .lineTo(let x, let y):
            ctx.addLine(to: CGPoint(x: x, y: y))
            lastControl = nil
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            ctx.addCurve(to: CGPoint(x: x, y: y),
                         control1: CGPoint(x: x1, y: y1),
                         control2: CGPoint(x: x2, y: y2))
            lastControl = CGPoint(x: x2, y: y2)
        case .smoothCurveTo(let x2, let y2, let x, let y):
            let cur = ctx.currentPointOfPath
            let c1: CGPoint
            if let lc = lastControl {
                c1 = CGPoint(x: 2 * cur.x - lc.x, y: 2 * cur.y - lc.y)
            } else {
                c1 = cur
            }
            ctx.addCurve(to: CGPoint(x: x, y: y),
                         control1: c1,
                         control2: CGPoint(x: x2, y: y2))
            lastControl = CGPoint(x: x2, y: y2)
        case .quadTo(let x1, let y1, let x, let y):
            ctx.addQuadCurve(to: CGPoint(x: x, y: y),
                             control: CGPoint(x: x1, y: y1))
            lastControl = CGPoint(x: x1, y: y1)
        case .smoothQuadTo(let x, let y):
            let cur = ctx.currentPointOfPath
            let c1: CGPoint
            if let lc = lastControl {
                c1 = CGPoint(x: 2 * cur.x - lc.x, y: 2 * cur.y - lc.y)
            } else {
                c1 = cur
            }
            ctx.addQuadCurve(to: CGPoint(x: x, y: y), control: c1)
            lastControl = c1
        case .arcTo(_, _, _, _, _, let x, let y):
            // Approximate arc with line to endpoint
            ctx.addLine(to: CGPoint(x: x, y: y))
            lastControl = nil
        case .closePath:
            ctx.closePath()
            lastControl = nil
        }
    }
}

private func fillAndStroke(_ ctx: CGContext, _ fill: JasFill?, _ stroke: JasStroke?) {
    let hasFill = fill != nil
    let hasStroke = stroke != nil
    if hasFill && hasStroke {
        setFill(ctx, fill)
        setStroke(ctx, stroke)
        ctx.drawPath(using: .fillStroke)
    } else if hasFill {
        setFill(ctx, fill)
        ctx.fillPath()
    } else if hasStroke {
        setStroke(ctx, stroke)
        ctx.strokePath()
    }
}

private func drawElement(_ ctx: CGContext, _ elem: Element) {
    ctx.saveGState()
    switch elem {
    case .line(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        setStroke(ctx, v.stroke)
        ctx.move(to: CGPoint(x: v.x1, y: v.y1))
        ctx.addLine(to: CGPoint(x: v.x2, y: v.y2))
        ctx.strokePath()

    case .rect(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        let rect = CGRect(x: v.x, y: v.y, width: v.width, height: v.height)
        if v.rx > 0 || v.ry > 0 {
            let path = CGPath(roundedRect: rect, cornerWidth: v.rx, cornerHeight: v.ry, transform: nil)
            ctx.addPath(path)
        } else {
            ctx.addRect(rect)
        }
        fillAndStroke(ctx, v.fill, v.stroke)

    case .circle(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        let rect = CGRect(x: v.cx - v.r, y: v.cy - v.r, width: v.r * 2, height: v.r * 2)
        ctx.addEllipse(in: rect)
        fillAndStroke(ctx, v.fill, v.stroke)

    case .ellipse(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        let rect = CGRect(x: v.cx - v.rx, y: v.cy - v.ry, width: v.rx * 2, height: v.ry * 2)
        ctx.addEllipse(in: rect)
        fillAndStroke(ctx, v.fill, v.stroke)

    case .polyline(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        guard !v.points.isEmpty else { break }
        ctx.move(to: CGPoint(x: v.points[0].0, y: v.points[0].1))
        for i in 1..<v.points.count {
            ctx.addLine(to: CGPoint(x: v.points[i].0, y: v.points[i].1))
        }
        fillAndStroke(ctx, v.fill, v.stroke)

    case .polygon(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        guard !v.points.isEmpty else { break }
        ctx.move(to: CGPoint(x: v.points[0].0, y: v.points[0].1))
        for i in 1..<v.points.count {
            ctx.addLine(to: CGPoint(x: v.points[i].0, y: v.points[i].1))
        }
        ctx.closePath()
        fillAndStroke(ctx, v.fill, v.stroke)

    case .path(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        buildPath(ctx, v.d)
        fillAndStroke(ctx, v.fill, v.stroke)

    case .text(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        let font = NSFont(name: v.fontFamily, size: v.fontSize) ?? NSFont.systemFont(ofSize: v.fontSize)
        let color: NSColor
        if let fill = v.fill {
            color = nsColor(fill.color)
        } else {
            color = .black
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: v.content, attributes: attrs)
        ctx.saveGState()
        if v.isAreaText {
            // Area text: CTFrameDraw expects unflipped coordinates, so flip around the rect center
            ctx.translateBy(x: 0, y: v.y + v.height)
            ctx.scaleBy(x: 1, y: -1)
            let framesetter = CTFramesetterCreateWithAttributedString(str)
            let path = CGPath(rect: CGRect(x: v.x, y: 0, width: v.width, height: v.height), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
            CTFrameDraw(frame, ctx)
        } else {
            // Point text: single line
            ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
            let line = CTLineCreateWithAttributedString(str)
            ctx.textPosition = CGPoint(x: v.x, y: v.y)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()

    case .group(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        for child in v.children { drawElement(ctx, child) }

    case .layer(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        for child in v.children { drawElement(ctx, child) }
    }
    ctx.restoreGState()
}

// MARK: - Selection overlay drawing

private let selectionColor = CGColor(red: 0, green: 0.47, blue: 1.0, alpha: 1.0)
private let handleSize: CGFloat = 6.0

private func controlPoints(_ elem: Element) -> [(Double, Double)] {
    elem.controlPointPositions
}

private func drawElementOverlay(_ ctx: CGContext, _ elem: Element, selectedCPs: Set<Int> = []) {
    ctx.setStrokeColor(selectionColor)
    ctx.setLineWidth(1.0)
    ctx.setLineDash(phase: 0, lengths: [])

    switch elem {
    case .line(let v):
        ctx.move(to: CGPoint(x: v.x1, y: v.y1))
        ctx.addLine(to: CGPoint(x: v.x2, y: v.y2))
        ctx.strokePath()
    case .rect(let v):
        if v.rx > 0 || v.ry > 0 {
            let path = CGPath(roundedRect: CGRect(x: v.x, y: v.y, width: v.width, height: v.height),
                              cornerWidth: v.rx, cornerHeight: v.ry, transform: nil)
            ctx.addPath(path)
        } else {
            ctx.addRect(CGRect(x: v.x, y: v.y, width: v.width, height: v.height))
        }
        ctx.strokePath()
    case .circle(let v):
        ctx.addEllipse(in: CGRect(x: v.cx - v.r, y: v.cy - v.r, width: v.r * 2, height: v.r * 2))
        ctx.strokePath()
    case .ellipse(let v):
        ctx.addEllipse(in: CGRect(x: v.cx - v.rx, y: v.cy - v.ry, width: v.rx * 2, height: v.ry * 2))
        ctx.strokePath()
    case .polyline(let v):
        guard !v.points.isEmpty else { break }
        ctx.move(to: CGPoint(x: v.points[0].0, y: v.points[0].1))
        for i in 1..<v.points.count { ctx.addLine(to: CGPoint(x: v.points[i].0, y: v.points[i].1)) }
        ctx.strokePath()
    case .polygon(let v):
        guard !v.points.isEmpty else { break }
        ctx.move(to: CGPoint(x: v.points[0].0, y: v.points[0].1))
        for i in 1..<v.points.count { ctx.addLine(to: CGPoint(x: v.points[i].0, y: v.points[i].1)) }
        ctx.closePath()
        ctx.strokePath()
    case .path(let v):
        buildPath(ctx, v.d)
        ctx.strokePath()
    default:
        let b = elem.bounds
        ctx.addRect(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
        ctx.strokePath()
    }

    // Draw handles
    let half = handleSize / 2
    for (i, (px, py)) in controlPoints(elem).enumerated() {
        let r = CGRect(x: px - half, y: py - half, width: handleSize, height: handleSize)
        if selectedCPs.contains(i) {
            ctx.setFillColor(selectionColor)
        } else {
            ctx.setFillColor(.white)
        }
        ctx.fill(r)
        ctx.setStrokeColor(selectionColor)
        ctx.stroke(r)
    }
}

private func elemChildren(_ e: Element) -> [Element] {
    switch e {
    case .group(let g): return g.children
    case .layer(let l): return l.children
    default: return []
    }
}

private func drawSelectionOverlays(_ ctx: CGContext, _ doc: JasDocument) {
    for es in doc.selection {
        let path = es.path
        guard !path.isEmpty else { continue }
        ctx.saveGState()
        var node: Element = .layer(doc.layers[path[0]])
        if path.count > 1 {
            applyTransform(ctx, doc.layers[path[0]].transform)
            for idx in path[1..<path.count - 1] {
                let children = elemChildren(node)
                node = children[idx]
                switch node {
                case .group(let g): applyTransform(ctx, g.transform)
                case .layer(let l): applyTransform(ctx, l.transform)
                default: break
                }
            }
            node = elemChildren(node)[path.last!]
        }
        // Apply the selected element's own transform
        switch node {
        case .line(let v): applyTransform(ctx, v.transform)
        case .rect(let v): applyTransform(ctx, v.transform)
        case .circle(let v): applyTransform(ctx, v.transform)
        case .ellipse(let v): applyTransform(ctx, v.transform)
        case .polyline(let v): applyTransform(ctx, v.transform)
        case .polygon(let v): applyTransform(ctx, v.transform)
        case .path(let v): applyTransform(ctx, v.transform)
        case .text(let v): applyTransform(ctx, v.transform)
        case .group(let v): applyTransform(ctx, v.transform)
        case .layer(let v): applyTransform(ctx, v.transform)
        }
        drawElementOverlay(ctx, node, selectedCPs: es.controlPoints)
        ctx.restoreGState()
    }
}

// MARK: - Shift-constrain helper

private func constrainAngle(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> (Double, Double) {
    let dx = ex - sx, dy = ey - sy
    let dist = hypot(dx, dy)
    guard dist > 0 else { return (ex, ey) }
    let angle = atan2(dy, dx)
    let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
    return (sx + dist * cos(snapped), sy + dist * sin(snapped))
}

// MARK: - Regular polygon helper

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

// MARK: - Canvas NSView for CoreGraphics drawing

/// An NSView that draws the document's elements using CoreGraphics.
class CanvasNSView: NSView {
    var document: JasDocument = JasDocument()
    var controller: Controller?
    var currentTool: Tool = .selection
    var onToolRead: (() -> Tool)?

    // Drag state for drawing tools
    private var dragStart: NSPoint?
    private var dragEnd: NSPoint?
    // Move-drag state
    private var moving: Bool = false
    private let hitRadius: CGFloat = 6.0
    // Inline text editing state
    private var textEditor: NSTextField?
    private var editingPath: ElementPath?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // White background
        ctx.setFillColor(.white)
        ctx.fill(bounds)
        // Draw document layers
        for layer in document.layers {
            drawElement(ctx, .layer(layer))
        }
        // Draw selection overlays
        drawSelectionOverlays(ctx, document)
        // Draw drag preview
        if let start = dragStart, let end = dragEnd {
            if moving {
                let dx = end.x - start.x
                let dy = end.y - start.y
                for es in document.selection {
                    let elem = document.getElement(es.path)
                    let moved = elem.moveControlPoints(es.controlPoints, dx: dx, dy: dy)
                    ctx.setStrokeColor(selectionColor)
                    ctx.setLineWidth(1.0)
                    ctx.setLineDash(phase: 0, lengths: [4, 4])
                    drawElementOverlay(ctx, moved, selectedCPs: es.controlPoints)
                }
            } else {
                let tool = onToolRead?() ?? currentTool
                ctx.setStrokeColor(CGColor(gray: 0.4, alpha: 1.0))
                ctx.setLineWidth(1.0)
                ctx.setLineDash(phase: 0, lengths: [4, 4])
                if tool == .line {
                    ctx.move(to: start)
                    ctx.addLine(to: end)
                } else if tool == .polygon {
                    let pts = regularPolygonPoints(start.x, start.y, end.x, end.y, polygonSides)
                    if let first = pts.first {
                        ctx.move(to: CGPoint(x: first.0, y: first.1))
                        for i in 1..<pts.count {
                            ctx.addLine(to: CGPoint(x: pts[i].0, y: pts[i].1))
                        }
                        ctx.closePath()
                    }
                } else if tool == .text || tool == .rect || tool == .selection || tool == .directSelection || tool == .groupSelection {
                    let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                   width: abs(end.x - start.x), height: abs(end.y - start.y))
                    ctx.addRect(r)
                }
                ctx.strokePath()
            }
        }
    }

    private func hitTestSelection(_ pos: NSPoint) -> Bool {
        for es in document.selection {
            let elem = document.getElement(es.path)
            let cps = elem.controlPointPositions
            for (i, (px, py)) in cps.enumerated() {
                if es.controlPoints.contains(i) {
                    if abs(pos.x - px) <= hitRadius && abs(pos.y - py) <= hitRadius {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func hitTestText(_ pos: NSPoint) -> (ElementPath, JasText)? {
        for (li, layer) in document.layers.enumerated() {
            for (ci, child) in layer.children.enumerated() {
                if case .text(let v) = child {
                    let (bx, by, bw, bh) = v.bounds
                    if pos.x >= bx && pos.x <= bx + bw && pos.y >= by && pos.y <= by + bh {
                        return ([li, ci], v)
                    }
                }
            }
        }
        return nil
    }

    private func startTextEdit(path: ElementPath, textElem: JasText) {
        commitTextEdit()
        editingPath = path
        let bx, by, bw, bh: Double
        if textElem.isAreaText {
            bx = textElem.x; by = textElem.y
            bw = textElem.width; bh = textElem.height
        } else {
            bx = textElem.x; by = textElem.y - textElem.fontSize
            bw = max(Double(textElem.content.count) * textElem.fontSize * 0.6 + 20, 100)
            bh = textElem.fontSize + 4
        }
        let editor = NSTextField(frame: NSRect(x: bx, y: by, width: bw, height: bh))
        editor.stringValue = textElem.content
        editor.font = NSFont(name: textElem.fontFamily, size: textElem.fontSize)
            ?? NSFont.systemFont(ofSize: textElem.fontSize)
        editor.isBordered = true
        editor.backgroundColor = .white
        editor.focusRingType = .exterior
        if textElem.isAreaText {
            editor.usesSingleLineMode = false
            editor.cell?.wraps = true
            editor.cell?.isScrollable = false
        }
        editor.target = self
        editor.action = #selector(textEditorAction(_:))
        addSubview(editor)
        editor.selectText(nil)
        window?.makeFirstResponder(editor)
        textEditor = editor
    }

    @objc private func textEditorAction(_ sender: NSTextField) {
        commitTextEdit()
    }

    func commitTextEdit() {
        guard let editor = textEditor, let path = editingPath else { return }
        let newText = editor.stringValue
        let elem = document.getElement(path)
        if case .text(let v) = elem, v.content != newText {
            let newElem = Element.text(JasText(
                x: v.x, y: v.y, content: newText,
                fontFamily: v.fontFamily, fontSize: v.fontSize,
                width: v.width, height: v.height,
                fill: v.fill, stroke: v.stroke,
                opacity: v.opacity, transform: v.transform
            ))
            controller?.model.document = document.replaceElement(path, with: newElem)
        }
        editor.removeFromSuperview()
        textEditor = nil
        editingPath = nil
    }

    override func mouseDown(with event: NSEvent) {
        let tool = onToolRead?() ?? currentTool
        if tool == .selection || tool == .directSelection || tool == .groupSelection || tool == .text || tool == .line || tool == .rect || tool == .polygon {
            let pt = convert(event.locationInWindow, from: nil)
            if (tool == .selection || tool == .directSelection || tool == .groupSelection) && hitTestSelection(pt) {
                dragStart = pt
                dragEnd = pt
                moving = true
                return
            }
            dragStart = pt
            dragEnd = pt
            moving = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = dragStart {
            var pt = convert(event.locationInWindow, from: nil)
            if event.modifierFlags.contains(.shift) {
                let (cx, cy) = constrainAngle(start.x, start.y, pt.x, pt.y)
                pt = NSPoint(x: cx, y: cy)
            }
            dragEnd = pt
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        let end = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        commitDrag(to: end, shift: shift, option: option)
    }

    /// Test helper: simulate a complete drag from start to end point.
    func simulateDrag(from start: NSPoint, to end: NSPoint, extend: Bool = false) {
        let tool = onToolRead?() ?? currentTool
        guard tool == .selection || tool == .directSelection || tool == .groupSelection || tool == .text || tool == .line || tool == .rect || tool == .polygon else { return }
        dragStart = start
        dragEnd = end
        commitDrag(to: end, shift: extend)
    }

    private func commitDrag(to rawEnd: NSPoint, shift: Bool = false, option: Bool = false) {
        guard let start = dragStart, let controller = controller else {
            dragStart = nil
            dragEnd = nil
            moving = false
            return
        }
        let tool = onToolRead?() ?? currentTool
        let wasMoving = moving
        dragStart = nil
        dragEnd = nil
        moving = false

        if wasMoving {
            var end = rawEnd
            if shift {
                let (cx, cy) = constrainAngle(start.x, start.y, end.x, end.y)
                end = NSPoint(x: cx, y: cy)
            }
            let dx = end.x - start.x
            let dy = end.y - start.y
            if dx != 0 || dy != 0 {
                if option {
                    controller.copySelection(dx: dx, dy: dy)
                } else {
                    controller.moveSelection(dx: dx, dy: dy)
                }
            }
            needsDisplay = true
            return
        }

        // Selection tools: shift means extend
        let extend = shift
        if tool == .selection {
            let x = min(start.x, rawEnd.x)
            let y = min(start.y, rawEnd.y)
            let w = abs(rawEnd.x - start.x)
            let h = abs(rawEnd.y - start.y)
            controller.selectRect(x: x, y: y, width: w, height: h, extend: extend)
            return
        }

        if tool == .groupSelection {
            let x = min(start.x, rawEnd.x)
            let y = min(start.y, rawEnd.y)
            let w = abs(rawEnd.x - start.x)
            let h = abs(rawEnd.y - start.y)
            controller.groupSelectRect(x: x, y: y, width: w, height: h, extend: extend)
            return
        }

        if tool == .directSelection {
            let x = min(start.x, rawEnd.x)
            let y = min(start.y, rawEnd.y)
            let w = abs(rawEnd.x - start.x)
            let h = abs(rawEnd.y - start.y)
            controller.directSelectRect(x: x, y: y, width: w, height: h, extend: extend)
            return
        }

        // Text tool: edit existing, place point text, or drag area text
        if tool == .text {
            let w = abs(rawEnd.x - start.x)
            let h = abs(rawEnd.y - start.y)
            if w > 4 || h > 4 {
                // Dragged a marquee: create area text
                let tx = min(start.x, rawEnd.x)
                let ty = min(start.y, rawEnd.y)
                let elem = Element.text(JasText(
                    x: tx, y: ty,
                    content: "Lorem Ipsum",
                    width: w, height: h,
                    fill: JasFill(color: JasColor(r: 0, g: 0, b: 0))
                ))
                controller.addElement(elem)
            } else {
                // Click: edit existing or place point text
                if let (path, textElem) = hitTestText(start) {
                    startTextEdit(path: path, textElem: textElem)
                } else {
                    let elem = Element.text(JasText(
                        x: start.x, y: start.y,
                        content: "Lorem Ipsum",
                        fill: JasFill(color: JasColor(r: 0, g: 0, b: 0))
                    ))
                    controller.addElement(elem)
                }
            }
            return
        }

        // Drawing tools: shift means constrain angle
        var end = rawEnd
        if shift {
            let (cx, cy) = constrainAngle(start.x, start.y, end.x, end.y)
            end = NSPoint(x: cx, y: cy)
        }
        let elem: Element
        if tool == .line {
            elem = .line(JasLine(
                x1: start.x, y1: start.y, x2: end.x, y2: end.y,
                stroke: JasStroke(color: JasColor(r: 0, g: 0, b: 0), width: 1.0)
            ))
        } else if tool == .rect {
            elem = .rect(JasRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y),
                stroke: JasStroke(color: JasColor(r: 0, g: 0, b: 0), width: 1.0)
            ))
        } else if tool == .polygon {
            let pts = regularPolygonPoints(start.x, start.y, end.x, end.y, polygonSides)
            elem = .polygon(JasPolygon(
                points: pts,
                stroke: JasStroke(color: JasColor(r: 0, g: 0, b: 0), width: 1.0)
            ))
        } else {
            return
        }
        controller.addElement(elem)
    }
}

// MARK: - CanvasSubwindow

/// An embedded, draggable canvas subwindow within the workspace.
/// The view observes the model's document for its title.
public struct CanvasSubwindow: View {
    @ObservedObject var model: JasModel
    var controller: Controller
    @Binding var currentTool: Tool
    @Binding var position: CGPoint
    public let bbox: CanvasBoundingBox

    private let titleBarHeight: CGFloat = 24
    private var canvasSize: CGSize { CGSize(width: bbox.width, height: bbox.height) }

    public var body: some View {
        let totalWidth = canvasSize.width
        let totalHeight = titleBarHeight + canvasSize.height

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                // Title bar
                ZStack {
                    Color(nsColor: NSColor(white: 0.6, alpha: 1.0))
                    Text(model.document.title)
                        .font(.system(size: 12))
                        .foregroundColor(.black)
                }
                .frame(width: totalWidth, height: titleBarHeight)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            position.x += value.translation.width
                            position.y += value.translation.height
                        }
                )

                // Canvas drawing area
                CanvasRepresentable(document: model.document, controller: controller, currentTool: $currentTool)
                    .frame(width: totalWidth, height: canvasSize.height)
            }
            .border(Color(nsColor: NSColor(white: 0.4, alpha: 1.0)), width: 1)
        }
        .frame(width: totalWidth, height: totalHeight)
        .position(x: position.x + totalWidth / 2, y: position.y + totalHeight / 2)
    }
}

/// Bridges the CoreGraphics-based CanvasNSView into SwiftUI.
struct CanvasRepresentable: NSViewRepresentable {
    let document: JasDocument
    let controller: Controller
    @Binding var currentTool: Tool

    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView()
        view.document = document
        view.controller = controller
        view.currentTool = currentTool
        view.onToolRead = { [self] in self.currentTool }
        return view
    }

    func updateNSView(_ nsView: CanvasNSView, context: Context) {
        nsView.document = document
        nsView.controller = controller
        nsView.currentTool = currentTool
        nsView.onToolRead = { [self] in self.currentTool }
        nsView.needsDisplay = true
    }
}
