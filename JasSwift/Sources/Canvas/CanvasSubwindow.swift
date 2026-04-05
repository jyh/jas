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

/// Build path commands into a CGMutablePath (for text-on-path flattening).
private func buildCGPath(_ path: CGMutablePath, _ cmds: [PathCommand]) {
    var lastControl: CGPoint? = nil
    for cmd in cmds {
        switch cmd {
        case .moveTo(let x, let y):
            path.move(to: CGPoint(x: x, y: y))
            lastControl = nil
        case .lineTo(let x, let y):
            path.addLine(to: CGPoint(x: x, y: y))
            lastControl = nil
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            path.addCurve(to: CGPoint(x: x, y: y),
                          control1: CGPoint(x: x1, y: y1),
                          control2: CGPoint(x: x2, y: y2))
            lastControl = CGPoint(x: x2, y: y2)
        case .smoothCurveTo(let x2, let y2, let x, let y):
            let cur = path.currentPoint
            let c1: CGPoint
            if let lc = lastControl {
                c1 = CGPoint(x: 2 * cur.x - lc.x, y: 2 * cur.y - lc.y)
            } else {
                c1 = cur
            }
            path.addCurve(to: CGPoint(x: x, y: y),
                          control1: c1,
                          control2: CGPoint(x: x2, y: y2))
            lastControl = CGPoint(x: x2, y: y2)
        case .quadTo(let x1, let y1, let x, let y):
            path.addQuadCurve(to: CGPoint(x: x, y: y),
                              control: CGPoint(x: x1, y: y1))
            lastControl = CGPoint(x: x1, y: y1)
        case .smoothQuadTo(let x, let y):
            let cur = path.currentPoint
            let c1: CGPoint
            if let lc = lastControl {
                c1 = CGPoint(x: 2 * cur.x - lc.x, y: 2 * cur.y - lc.y)
            } else {
                c1 = cur
            }
            path.addQuadCurve(to: CGPoint(x: x, y: y), control: c1)
            lastControl = c1
        case .arcTo(_, _, _, _, _, let x, let y):
            path.addLine(to: CGPoint(x: x, y: y))
            lastControl = nil
        case .closePath:
            path.closeSubpath()
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
            ctx.translateBy(x: 0, y: v.y + v.height)
            ctx.scaleBy(x: 1, y: -1)
            let framesetter = CTFramesetterCreateWithAttributedString(str)
            let path = CGPath(rect: CGRect(x: v.x, y: 0, width: v.width, height: v.height), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
            CTFrameDraw(frame, ctx)
        } else {
            ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
            let line = CTLineCreateWithAttributedString(str)
            ctx.textPosition = CGPoint(x: v.x, y: v.y)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()

    case .textPath(let v):
        ctx.setAlpha(CGFloat(v.opacity))
        applyTransform(ctx, v.transform)
        let font = NSFont(name: v.fontFamily, size: v.fontSize) ?? NSFont.systemFont(ofSize: v.fontSize)
        let color: NSColor
        if let fill = v.fill {
            color = nsColor(fill.color)
        } else {
            color = .black
        }
        // Flatten path to polyline
        let cgPath = CGMutablePath()
        buildCGPath(cgPath, v.d)
        var points: [(Double, Double)] = []
        cgPath.applyWithBlock { elementPtr in
            let el = elementPtr.pointee
            switch el.type {
            case .moveToPoint, .addLineToPoint:
                points.append((el.points[0].x, el.points[0].y))
            case .addCurveToPoint:
                // Flatten cubic bezier
                let n = points.isEmpty ? 0 : points.count - 1
                let (sx, sy) = points.isEmpty ? (0.0, 0.0) : points[n]
                let steps = 20
                for i in 1...steps {
                    let t = Double(i) / Double(steps)
                    let mt = 1.0 - t
                    let px = mt*mt*mt*sx + 3*mt*mt*t*el.points[0].x + 3*mt*t*t*el.points[1].x + t*t*t*el.points[2].x
                    let py = mt*mt*mt*sy + 3*mt*mt*t*el.points[0].y + 3*mt*t*t*el.points[1].y + t*t*t*el.points[2].y
                    points.append((px, py))
                }
            case .addQuadCurveToPoint:
                let n = points.isEmpty ? 0 : points.count - 1
                let (sx, sy) = points.isEmpty ? (0.0, 0.0) : points[n]
                let steps = 20
                for i in 1...steps {
                    let t = Double(i) / Double(steps)
                    let mt = 1.0 - t
                    let px = mt*mt*sx + 2*mt*t*el.points[0].x + t*t*el.points[1].x
                    let py = mt*mt*sy + 2*mt*t*el.points[0].y + t*t*el.points[1].y
                    points.append((px, py))
                }
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }
        guard points.count >= 2 else { break }
        // Compute cumulative distances
        var dists = [0.0]
        for i in 1..<points.count {
            let dx = points[i].0 - points[i-1].0
            let dy = points[i].1 - points[i-1].1
            dists.append(dists[i-1] + hypot(dx, dy))
        }
        let totalLen = dists.last!
        guard totalLen > 0 else { break }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var offset = v.startOffset * totalLen
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        for ch in v.content {
            let chStr = NSAttributedString(string: String(ch), attributes: attrs)
            let line = CTLineCreateWithAttributedString(chStr)
            let cw = CTLineGetTypographicBounds(line, nil, nil, nil)
            let mid = offset + cw / 2
            if mid > totalLen { break }
            // Find segment containing mid
            var seg = 1
            while seg < points.count - 1 && dists[seg] < mid { seg += 1 }
            let d0 = dists[seg - 1], d1 = dists[seg]
            let frac = d1 > d0 ? (mid - d0) / (d1 - d0) : 0
            let (ax, ay) = points[seg - 1], (bx, by) = points[seg]
            let px = ax + frac * (bx - ax)
            let py = ay + frac * (by - ay)
            let angle = atan2(by - ay, bx - ax)
            ctx.saveGState()
            ctx.translateBy(x: px, y: py)
            ctx.rotate(by: angle)
            ctx.textPosition = CGPoint(x: -cw / 2, y: v.fontSize / 3)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
            offset += cw
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
private let handleSize: CGFloat = 10.0

/// Draw an element's selection overlay (outline + control handles).
/// Internal so tools can call it via the ToolContext.
func drawElementOverlay(_ ctx: CGContext, _ elem: Element, selectedCPs: Set<Int> = []) {
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
    case .textPath(let v):
        buildPath(ctx, v.d)
        ctx.strokePath()
    default:
        let b = elem.bounds
        ctx.addRect(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
        ctx.strokePath()
    }

    // Draw Bezier handles for selected path control points
    let handleCircleRadius: CGFloat = 3.0
    let pathD: [PathCommand]?
    switch elem {
    case .path(let v): pathD = v.d
    case .textPath(let v): pathD = v.d
    default: pathD = nil
    }
    if let d = pathD, !selectedCPs.isEmpty {
        let anchors = elem.controlPointPositions
        for cpIdx in selectedCPs {
            guard cpIdx < anchors.count else { continue }
            let (ax, ay) = anchors[cpIdx]
            let (hIn, hOut) = pathHandlePositions(d, anchorIdx: cpIdx)
            ctx.setStrokeColor(selectionColor)
            ctx.setLineWidth(1.0)
            if let (hx, hy) = hIn {
                ctx.move(to: CGPoint(x: ax, y: ay))
                ctx.addLine(to: CGPoint(x: hx, y: hy))
                ctx.strokePath()
                ctx.addEllipse(in: CGRect(x: hx - handleCircleRadius, y: hy - handleCircleRadius,
                                          width: handleCircleRadius * 2, height: handleCircleRadius * 2))
                ctx.setFillColor(.white)
                ctx.fillPath()
                ctx.addEllipse(in: CGRect(x: hx - handleCircleRadius, y: hy - handleCircleRadius,
                                          width: handleCircleRadius * 2, height: handleCircleRadius * 2))
                ctx.setStrokeColor(selectionColor)
                ctx.strokePath()
            }
            if let (hx, hy) = hOut {
                ctx.move(to: CGPoint(x: ax, y: ay))
                ctx.addLine(to: CGPoint(x: hx, y: hy))
                ctx.strokePath()
                ctx.addEllipse(in: CGRect(x: hx - handleCircleRadius, y: hy - handleCircleRadius,
                                          width: handleCircleRadius * 2, height: handleCircleRadius * 2))
                ctx.setFillColor(.white)
                ctx.fillPath()
                ctx.addEllipse(in: CGRect(x: hx - handleCircleRadius, y: hy - handleCircleRadius,
                                          width: handleCircleRadius * 2, height: handleCircleRadius * 2))
                ctx.setStrokeColor(selectionColor)
                ctx.strokePath()
            }
        }
    }

    // Draw handles
    let half = handleSize / 2
    for (i, (px, py)) in elem.controlPointPositions.enumerated() {
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
        case .textPath(let v): applyTransform(ctx, v.transform)
        case .group(let v): applyTransform(ctx, v.transform)
        case .layer(let v): applyTransform(ctx, v.transform)
        }
        drawElementOverlay(ctx, node, selectedCPs: es.controlPoints)
        ctx.restoreGState()
    }
}

// MARK: - Canvas NSView for CoreGraphics drawing

/// An NSView that draws the document's elements using CoreGraphics.
/// Dispatches mouse/key events through the CanvasTool protocol.
class CanvasNSView: NSView {
    var document: JasDocument = JasDocument()
    var controller: Controller?
    var currentTool: Tool = .selection {
        didSet {
            if oldValue != currentTool, let ctx = toolContext {
                let savedSelection = document.selection
                tools[oldValue]?.deactivate(ctx)
                tools[currentTool]?.activate(ctx)
                // Preserve selection across tool changes
                if document.selection != savedSelection {
                    var doc = document
                    doc = JasDocument(layers: doc.layers,
                                      selectedLayer: doc.selectedLayer,
                                      selection: savedSelection)
                    controller?.model.document = doc
                }
            }
        }
    }
    var onToolRead: (() -> Tool)?

    // Tool system
    let tools: [Tool: CanvasTool] = createTools()

    // Inline text editing state (managed by canvas, exposed via context)
    private var textEditor: NSTextField?
    private var editingPath: ElementPath?

    private let hitRadius: CGFloat = 8.0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var activeTool: CanvasTool {
        let tool = onToolRead?() ?? currentTool
        return tools[tool]!
    }

    var toolContext: ToolContext? {
        guard let controller = controller else { return nil }
        return ToolContext(
            model: controller.model,
            controller: controller,
            hitTestSelection: { [weak self] pos in self?.hitTestSelection(pos) ?? false },
            hitTestHandle: { [weak self] pos in self?.hitTestHandle(pos) },
            hitTestText: { [weak self] pos in self?.hitTestText(pos) },
            hitTestPathCurve: { [weak self] x, y in self?.hitTestPathCurve(x, y) },
            requestUpdate: { [weak self] in self?.needsDisplay = true },
            startTextEdit: { [weak self] path, elem in self?.startTextEdit(path: path, elem: elem) },
            commitTextEdit: { [weak self] in self?.commitTextEdit() },
            drawElementOverlay: { ctx, elem, cps in drawElementOverlay(ctx, elem, selectedCPs: cps) }
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

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
        // Draw active tool overlay
        if let toolCtx = toolContext {
            activeTool.drawOverlay(toolCtx, ctx)
        }
    }

    // MARK: - Hit tests

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

    private func hitTestHandle(_ pos: NSPoint) -> (path: ElementPath, anchorIdx: Int, handleType: String)? {
        for es in document.selection {
            let elem = document.getElement(es.path)
            guard case .path(let v) = elem else { continue }
            for cpIdx in es.controlPoints {
                let (hIn, hOut) = pathHandlePositions(v.d, anchorIdx: cpIdx)
                if let (hx, hy) = hIn {
                    if abs(pos.x - hx) <= hitRadius && abs(pos.y - hy) <= hitRadius {
                        return (es.path, cpIdx, "in")
                    }
                }
                if let (hx, hy) = hOut {
                    if abs(pos.x - hx) <= hitRadius && abs(pos.y - hy) <= hitRadius {
                        return (es.path, cpIdx, "out")
                    }
                }
            }
        }
        return nil
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

    private func hitTestPathCurve(_ x: Double, _ y: Double) -> (ElementPath, Element)? {
        let threshold = hitRadius + 2
        for (li, layer) in document.layers.enumerated() {
            for (ci, child) in layer.children.enumerated() {
                switch child {
                case .path(let v):
                    if pathDistanceToPoint(v.d, px: x, py: y) <= threshold {
                        return ([li, ci], child)
                    }
                case .textPath(let v):
                    if pathDistanceToPoint(v.d, px: x, py: y) <= threshold {
                        return ([li, ci], child)
                    }
                case .group(let g):
                    for (gi, gc) in g.children.enumerated() {
                        switch gc {
                        case .path(let v):
                            if pathDistanceToPoint(v.d, px: x, py: y) <= threshold {
                                return ([li, ci, gi], gc)
                            }
                        case .textPath(let v):
                            if pathDistanceToPoint(v.d, px: x, py: y) <= threshold {
                                return ([li, ci, gi], gc)
                            }
                        default: break
                        }
                    }
                default: break
                }
            }
        }
        return nil
    }

    // MARK: - Text editing

    private func startTextEdit(path: ElementPath, elem: Element) {
        commitTextEdit()
        editingPath = path
        let bx, by, bw, bh: Double
        let content: String
        let fontFamily: String
        let fontSize: Double
        var isArea = false
        switch elem {
        case .text(let textElem):
            content = textElem.content
            fontFamily = textElem.fontFamily
            fontSize = textElem.fontSize
            if textElem.isAreaText {
                isArea = true
                bx = textElem.x; by = textElem.y
                bw = textElem.width; bh = textElem.height
            } else {
                bx = textElem.x; by = textElem.y - textElem.fontSize
                bw = max(Double(textElem.content.count) * textElem.fontSize * 0.6 + 20, 100)
                bh = textElem.fontSize + 4
            }
        case .textPath(let tp):
            content = tp.content
            fontFamily = tp.fontFamily
            fontSize = tp.fontSize
            let (px, py) = pathPointAtOffset(tp.d, t: tp.startOffset)
            bx = px; by = py - tp.fontSize - 4
            bw = max(200, Double(tp.content.count) * tp.fontSize * 0.7)
            bh = tp.fontSize + 8
        default:
            return
        }
        let editor = NSTextField(frame: NSRect(x: bx, y: by, width: bw, height: bh))
        editor.stringValue = content
        editor.font = NSFont(name: fontFamily, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)
        editor.isBordered = true
        editor.backgroundColor = .white
        editor.focusRingType = .exterior
        if isArea {
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
        switch elem {
        case .text(let v) where v.content != newText:
            let newElem = Element.text(JasText(
                x: v.x, y: v.y, content: newText,
                fontFamily: v.fontFamily, fontSize: v.fontSize,
                width: v.width, height: v.height,
                fill: v.fill, stroke: v.stroke,
                opacity: v.opacity, transform: v.transform
            ))
            controller?.model.document = document.replaceElement(path, with: newElem)
        case .textPath(let v) where v.content != newText:
            let newElem = Element.textPath(JasTextPath(
                d: v.d, content: newText, startOffset: v.startOffset,
                fontFamily: v.fontFamily, fontSize: v.fontSize,
                fill: v.fill, stroke: v.stroke,
                opacity: v.opacity, transform: v.transform
            ))
            controller?.model.document = document.replaceElement(path, with: newElem)
        default: break
        }
        editor.removeFromSuperview()
        textEditor = nil
        editingPath = nil
    }

    // MARK: - Pen tool backward-compatibility

    func penFinish(forceClose: Bool = false) {
        guard let ctx = toolContext, let penTool = tools[.pen] as? PenTool else { return }
        penTool.finish(ctx, close: forceClose)
    }

    func penCancel() {
        guard let penTool = tools[.pen] as? PenTool else { return }
        penTool.points.removeAll()
        penTool.penDragging = false
        needsDisplay = true
    }

    // MARK: - Event dispatch

    override func keyDown(with event: NSEvent) {
        if let ctx = toolContext, activeTool.onKey(ctx, keyCode: event.keyCode) {
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let ctx = toolContext else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2 {
            activeTool.onDoubleClick(ctx, x: pt.x, y: pt.y)
            return
        }
        let shift = event.modifierFlags.contains(.shift)
        let alt = event.modifierFlags.contains(.option)
        activeTool.onPress(ctx, x: pt.x, y: pt.y, shift: shift, alt: alt)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let ctx = toolContext else { return }
        let pt = convert(event.locationInWindow, from: nil)
        activeTool.onMove(ctx, x: pt.x, y: pt.y, shift: false, dragging: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let ctx = toolContext else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        activeTool.onMove(ctx, x: pt.x, y: pt.y, shift: shift, dragging: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let ctx = toolContext else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        let alt = event.modifierFlags.contains(.option)
        activeTool.onRelease(ctx, x: pt.x, y: pt.y, shift: shift, alt: alt)
    }

    // MARK: - Test helper

    /// Test helper: simulate a complete drag from start to end point.
    func simulateDrag(from start: NSPoint, to end: NSPoint, extend: Bool = false) {
        guard let ctx = toolContext else { return }
        activeTool.onPress(ctx, x: start.x, y: start.y, shift: extend, alt: false)
        activeTool.onMove(ctx, x: end.x, y: end.y, shift: extend, dragging: true)
        activeTool.onRelease(ctx, x: end.x, y: end.y, shift: extend, alt: false)
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
                    Text(model.isModified ? "\(model.filename) *" : model.filename)
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
