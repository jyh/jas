import AppKit
import Foundation

// MARK: - Type-on-path tool with native in-place text editing
//
// Click on a Path to convert it to a TextPath and start editing; click
// on an existing TextPath to edit; drag to create a new TextPath along
// a curve; drag the orange diamond to reposition the start offset.
// While editing, mouse drag extends the selection and standard editing
// keys are routed via `onKeyEvent`.

private let offsetHandleRadius: Double = 5.0
private let blinkHalfPeriodMs: Double = 530.0

private func nowMs() -> Double {
    Date().timeIntervalSince1970 * 1000.0
}

private func cursorVisible(_ epochMs: Double) -> Bool {
    let elapsed = max(0, nowMs() - epochMs)
    let phase = Int(elapsed / blinkHalfPeriodMs)
    return phase % 2 == 0
}

private struct PathRender {
    let d: [PathCommand]
    let startOffset: Double
    let fontSize: Double
    let fill: Fill?
    let stroke: Stroke?
}

class TypeOnPathTool: CanvasTool {
    var dragStart: (Double, Double)?
    var dragEnd: (Double, Double)?
    var controlPt: (Double, Double)?
    // Offset handle drag
    var offsetDragging = false
    var offsetDragPath: ElementPath?
    var offsetPreview: Double?
    // Editing session
    private var session: TextEditSession?
    private var didSnapshot = false

    var currentSession: TextEditSession? { session }

    private func buildLayout(_ ctx: ToolContext) -> (PathRender, PathTextLayout)? {
        guard let s = session, s.target == .textPath else { return nil }
        guard pathIsValid(ctx.document, s.path) else { return nil }
        guard case .textPath(let tp) = ctx.document.getElement(s.path) else { return nil }
        let measure = makeMeasurer(family: tp.fontFamily, weight: tp.fontWeight,
                                   style: tp.fontStyle, size: tp.fontSize)
        let lay = layoutPathText(tp.d, content: s.content,
                                 startOffset: tp.startOffset,
                                 fontSize: tp.fontSize, measure: measure)
        let pr = PathRender(d: tp.d, startOffset: tp.startOffset,
                            fontSize: tp.fontSize, fill: tp.fill, stroke: tp.stroke)
        return (pr, lay)
    }

    private func cursorAt(_ ctx: ToolContext, _ x: Double, _ y: Double) -> Int {
        guard let (_, lay) = buildLayout(ctx) else { return 0 }
        return lay.hitTest(x, y)
    }

    private func ensureSnapshot(_ ctx: ToolContext) {
        if !didSnapshot {
            ctx.snapshot()
            didSnapshot = true
        }
    }

    private func syncToModel(_ ctx: ToolContext) {
        guard let s = session else { return }
        if let newDoc = s.applyToDocument(ctx.document) {
            ctx.controller.setDocument(newDoc)
        }
    }

    private func beginSessionExisting(_ ctx: ToolContext, path: ElementPath, elem: Element, cursor: Int) {
        let content: String
        if case .textPath(let tp) = elem { content = tp.content } else { content = "" }
        let s = TextEditSession(path: path, target: .textPath, content: content, insertion: cursor)
        s.blinkEpochMs = nowMs()
        session = s
        didSnapshot = false
        ctx.controller.selectElement(path)
    }

    private func endSession() {
        session = nil
        didSnapshot = false
        dragStart = nil
        dragEnd = nil
        controlPt = nil
    }

    private func findSelectedTextPathHandle(_ ctx: ToolContext, _ x: Double, _ y: Double)
        -> (ElementPath, TextPath)? {
        let r = offsetHandleRadius + 2
        for es in ctx.document.selection {
            guard pathIsValid(ctx.document, es.path) else { continue }
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
        // 1) If editing, click that stays on the edited element moves the caret
        if let s = session {
            let editedPath = s.path
            if let (path, _) = ctx.hitTestPathCurve(x, y), path == editedPath {
                let cursor = cursorAt(ctx, x, y)
                s.setInsertion(cursor, extend: false)
                s.dragActive = true
                s.blinkEpochMs = nowMs()
                ctx.requestUpdate()
                return
            }
            endSession()
        }
        beginPressNoSession(ctx, x: x, y: y)
    }

    private func beginPressNoSession(_ ctx: ToolContext, x: Double, y: Double) {
        // 2) Offset handle drag
        if let (path, _) = findSelectedTextPathHandle(ctx, x, y) {
            offsetDragging = true
            offsetDragPath = path
            offsetPreview = nil
            return
        }
        // 3) Hit existing Path or TextPath
        if let (path, elem) = ctx.hitTestPathCurve(x, y) {
            switch elem {
            case .textPath:
                beginSessionExisting(ctx, path: path, elem: elem, cursor: 0)
                if let s = session {
                    let cursor = cursorAt(ctx, x, y)
                    s.setInsertion(cursor, extend: false)
                    s.dragActive = true
                    s.blinkEpochMs = nowMs()
                    ctx.requestUpdate()
                }
            case .path(let v):
                ctx.snapshot()
                didSnapshot = true
                let startOff = pathClosestOffset(v.d, px: x, py: y)
                let tp = TextPath(d: v.d, content: "", startOffset: startOff,
                                  fontSize: 16.0,
                                  fill: Fill(color: Color(r: 0, g: 0, b: 0)))
                let newDoc = ctx.document.replaceElement(path, with: .textPath(tp))
                ctx.controller.setDocument(newDoc)
                ctx.controller.selectElement(path)
                let s = TextEditSession(path: path, target: .textPath, content: "", insertion: 0)
                s.blinkEpochMs = nowMs()
                session = s
                ctx.requestUpdate()
            default:
                break
            }
            return
        }
        // 4) Start drag-create
        dragStart = (x, y)
        dragEnd = (x, y)
        controlPt = nil
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        // Editing-session selection drag
        if let s = session, s.dragActive, dragging {
            let cursor = cursorAt(ctx, x, y)
            s.setInsertion(cursor, extend: true)
            s.blinkEpochMs = nowMs()
            ctx.requestUpdate()
            return
        }
        // Offset handle drag
        if offsetDragging, let path = offsetDragPath {
            if pathIsValid(ctx.document, path) {
                if case .textPath(let tp) = ctx.document.getElement(path), !tp.d.isEmpty {
                    offsetPreview = pathClosestOffset(tp.d, px: x, py: y)
                    ctx.requestUpdate()
                }
            }
            return
        }
        // Drag-create
        guard let (sx, sy) = dragStart else { return }
        dragEnd = (x, y)
        let dx = x - sx, dy = y - sy
        let dist = (dx * dx + dy * dy).squareRoot()
        if dist > dragThreshold {
            let nx = -dy / dist, ny = dx / dist
            let mx = (sx + x) / 2, my = (sy + y) / 2
            controlPt = (mx + nx * dist * 0.3, my + ny * dist * 0.3)
        }
        ctx.requestUpdate()
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        // Finish editing-session selection drag
        if let s = session, s.dragActive {
            s.dragActive = false
            s.blinkEpochMs = nowMs()
            ctx.requestUpdate()
            return
        }
        // Commit offset handle drag
        if offsetDragging {
            if let path = offsetDragPath, let newOffset = offsetPreview,
               pathIsValid(ctx.document, path) {
                ctx.snapshot()
                if case .textPath(let tp) = ctx.document.getElement(path) {
                    let new = TextPath(d: tp.d, content: tp.content, startOffset: newOffset,
                                       fontFamily: tp.fontFamily, fontSize: tp.fontSize,
                                       fontWeight: tp.fontWeight, fontStyle: tp.fontStyle,
                                       textDecoration: tp.textDecoration,
                                       fill: tp.fill, stroke: tp.stroke,
                                       opacity: tp.opacity, transform: tp.transform, locked: tp.locked)
                    ctx.controller.setDocument(ctx.document.replaceElement(path, with: .textPath(new)))
                }
            }
            offsetDragging = false
            offsetDragPath = nil
            offsetPreview = nil
            ctx.requestUpdate()
            return
        }
        // Drag-create commit
        guard let (sx, sy) = dragStart else { return }
        dragStart = nil
        dragEnd = nil
        let w = abs(x - sx), h = abs(y - sy)
        if w <= dragThreshold && h <= dragThreshold {
            controlPt = nil
            return
        }
        ctx.snapshot()
        didSnapshot = true
        let d: [PathCommand]
        if let (cx, cy) = controlPt {
            d = [.moveTo(sx, sy), .curveTo(x1: cx, y1: cy, x2: cx, y2: cy, x: x, y: y)]
        } else {
            d = [.moveTo(sx, sy), .lineTo(x, y)]
        }
        let tp = TextPath(d: d, content: "", startOffset: 0.0,
                          fontSize: 16.0,
                          fill: Fill(color: Color(r: 0, g: 0, b: 0)))
        ctx.controller.addElement(.textPath(tp))
        let doc = ctx.document
        let li = doc.selectedLayer
        let ci = doc.layers[li].children.count - 1
        let path: ElementPath = [li, ci]
        ctx.controller.selectElement(path)
        let s = TextEditSession(path: path, target: .textPath, content: "", insertion: 0)
        s.blinkEpochMs = nowMs()
        session = s
        controlPt = nil
        ctx.requestUpdate()
    }

    func onDoubleClick(_ ctx: ToolContext, x: Double, y: Double) {
        guard let s = session else { return }
        s.selectAll()
        s.blinkEpochMs = nowMs()
        ctx.requestUpdate()
    }

    func deactivate(_ ctx: ToolContext) {
        endSession()
    }

    func capturesKeyboard() -> Bool { session != nil }
    func isEditing() -> Bool { session != nil }
    func cursorOverride() -> String? {
        // While editing always use the system I-beam (matches TypeTool).
        session != nil ? "ibeam" : nil
    }

    func pasteText(_ ctx: ToolContext, _ text: String) -> Bool {
        guard let s = session else { return false }
        ensureSnapshot(ctx)
        s.insert(text)
        s.blinkEpochMs = nowMs()
        syncToModel(ctx)
        ctx.requestUpdate()
        return true
    }

    func onKeyEvent(_ ctx: ToolContext, _ key: String, _ mods: KeyMods) -> Bool {
        guard let s = session else { return false }
        let bump = { s.blinkEpochMs = nowMs() }
        let cmd = mods.cmd
        let lower = key.lowercased()

        if cmd && lower == "a" {
            s.selectAll(); bump(); ctx.requestUpdate(); return true
        }
        if cmd && lower == "z" {
            if mods.shift { s.redo() } else { s.undo() }
            bump(); syncToModel(ctx); ctx.requestUpdate(); return true
        }
        if cmd && lower == "c" {
            _ = s.copySelection()
            return true
        }
        if cmd && lower == "x" {
            if s.copySelection() != nil {
                ensureSnapshot(ctx)
                s.backspace()
                bump(); syncToModel(ctx); ctx.requestUpdate()
            }
            return true
        }
        switch key {
        case "Escape":
            endSession(); ctx.requestUpdate(); return true
        case "Backspace":
            ensureSnapshot(ctx); s.backspace()
            bump(); syncToModel(ctx); ctx.requestUpdate(); return true
        case "Delete":
            ensureSnapshot(ctx); s.deleteForward()
            bump(); syncToModel(ctx); ctx.requestUpdate(); return true
        case "ArrowLeft":
            s.setInsertion(s.insertion - 1, extend: mods.shift)
            bump(); ctx.requestUpdate(); return true
        case "ArrowRight":
            s.setInsertion(s.insertion + 1, extend: mods.shift)
            bump(); ctx.requestUpdate(); return true
        case "Home":
            s.setInsertion(0, extend: mods.shift)
            bump(); ctx.requestUpdate(); return true
        case "End":
            s.setInsertion(s.content.count, extend: mods.shift)
            bump(); ctx.requestUpdate(); return true
        default:
            if key.count == 1 && !cmd {
                ensureSnapshot(ctx); s.insert(key)
                bump(); syncToModel(ctx); ctx.requestUpdate(); return true
            }
            return false
        }
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        // Drag-create preview
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

        // Offset handle for selected TextPath elements
        for es in ctx.document.selection {
            guard pathIsValid(ctx.document, es.path) else { continue }
            let elem = ctx.document.getElement(es.path)
            guard case .textPath(let tp) = elem, !tp.d.isEmpty else { continue }
            let offset: Double
            if offsetDragging, offsetDragPath == es.path, let preview = offsetPreview {
                offset = preview
            } else {
                offset = tp.startOffset
            }
            let (hx, hy) = pathPointAtOffset(tp.d, t: offset)
            let r = offsetHandleRadius
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

        // Editing overlay: selection highlight + caret
        guard let s = session, let (pr, lay) = buildLayout(ctx) else { return }

        if s.hasSelection {
            let (lo, hi) = s.selectionRange
            cgCtx.setFillColor(CGColor(red: 0.529, green: 0.808, blue: 0.980, alpha: 0.45))
            for g in lay.glyphs where g.idx >= lo && g.idx < hi && !g.overflow {
                let half = g.width / 2
                let h = pr.fontSize
                let bx = g.cx - cos(g.angle) * half
                let by = g.cy - sin(g.angle) * half
                let ax = g.cx + cos(g.angle) * half
                let ay = g.cy + sin(g.angle) * half
                let nx = -sin(g.angle) * (h / 2)
                let ny = cos(g.angle) * (h / 2)
                cgCtx.move(to: CGPoint(x: bx + nx, y: by + ny))
                cgCtx.addLine(to: CGPoint(x: ax + nx, y: ay + ny))
                cgCtx.addLine(to: CGPoint(x: ax - nx, y: ay - ny))
                cgCtx.addLine(to: CGPoint(x: bx - nx, y: by - ny))
                cgCtx.closePath()
                cgCtx.fillPath()
            }
        }

        if cursorVisible(s.blinkEpochMs), let (cx, cy, angle) = lay.cursorPos(s.insertion) {
            let h = pr.fontSize
            let nx = -sin(angle), ny = cos(angle)
            let color: Color
            if let f = pr.fill { color = f.color }
            else if let st = pr.stroke { color = st.color }
            else { color = Color(r: 0, g: 0, b: 0) }
            cgCtx.setStrokeColor(CGColor(red: color.r, green: color.g, blue: color.b, alpha: 1.0))
            cgCtx.setLineWidth(1.5)
            cgCtx.move(to: CGPoint(x: cx + nx * (h * 0.7), y: cy + ny * (h * 0.7)))
            cgCtx.addLine(to: CGPoint(x: cx - nx * (h * 0.2), y: cy - ny * (h * 0.2)))
            cgCtx.strokePath()
        }
    }
}
