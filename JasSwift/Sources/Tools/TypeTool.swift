import AppKit
import Foundation

// MARK: - Type tool with native in-place text editing
//
// Click on existing unlocked text to edit; click on empty canvas to
// create a new empty Text element and enter editing immediately. Drag
// on empty canvas to create an area-text element. While editing, mouse
// drag extends the selection and standard editing keys flow through
// `onKeyEvent`.

private let blinkHalfPeriodMs: Double = 530.0

private func nowMs() -> Double {
    Date().timeIntervalSince1970 * 1000.0
}

private func cursorVisible(_ epochMs: Double) -> Bool {
    let elapsed = max(0, nowMs() - epochMs)
    let phase = Int(elapsed / blinkHalfPeriodMs)
    return phase % 2 == 0
}

private struct TextRender {
    let x: Double
    let y: Double
    let fontSize: Double
    let textWidth: Double
    let textHeight: Double
    let fill: Fill?
    let stroke: Stroke?
    let content: String
}

/// Editing-overlay bounds for a Text element. Swift renders point text
/// with `(x, y)` as the *baseline* (glyphs grow upward), so the visible
/// box for non-area text starts at `y - fontSize`. Area text uses
/// `(x, y, width, height)` directly.
private func textDrawBounds(_ elem: Element) -> (Double, Double, Double, Double) {
    guard case .text(let t) = elem else { return (0, 0, 0, 0) }
    if t.width > 0 && t.height > 0 {
        return (t.x, t.y, max(t.width, 1), max(t.height, 1))
    }
    let raw = t.content.isEmpty ? " " : t.content
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    var maxChars = 1
    for l in lines { maxChars = max(maxChars, l.count) }
    let w = Double(maxChars) * t.fontSize * 0.55
    let h = Double(lines.count) * t.fontSize
    return (t.x, t.y - t.fontSize, w, h)
}

private func inBox(_ b: (Double, Double, Double, Double), _ x: Double, _ y: Double) -> Bool {
    x >= b.0 && x <= b.0 + b.2 && y >= b.1 && y <= b.1 + b.3
}

/// Hit-test all unlocked Text elements in the document, top-down.
private func hitTestText(_ doc: Document, _ x: Double, _ y: Double) -> (ElementPath, Element)? {
    var result: (ElementPath, Element)?
    func walk(_ elem: Element, _ path: ElementPath) {
        if result != nil { return }
        switch elem {
        case .layer(let l):
            for (i, c) in l.children.enumerated() { walk(c, path + [i]) }
        case .group(let g):
            if !g.locked {
                for (i, c) in g.children.enumerated() { walk(c, path + [i]) }
            }
        case .text:
            if !elem.isLocked && inBox(textDrawBounds(elem), x, y) {
                result = (path, elem)
            }
        default:
            break
        }
    }
    for (li, layer) in doc.layers.enumerated() {
        walk(.layer(layer), [li])
    }
    return result
}

class TypeTool: CanvasTool {
    private var dragStart: (Double, Double)?
    private var dragEnd: (Double, Double)?
    private var session: TextEditSession?
    private var didSnapshot = false
    private var hoverText = false
    private var pointerInsideEdited = false
    /// Wall-clock timestamp (ms) of the last mouse move; the pointer is
    /// hidden over the edited text only after a short idle interval, so
    /// the user always has feedback while moving.
    private var lastMoveMs: Double = 0

    /// Public test accessor.
    var currentSession: TextEditSession? { session }

    private func buildLayout(_ ctx: ToolContext) -> (TextRender, TextLayout)? {
        guard let s = session, s.target == .text else { return nil }
        guard pathIsValid(ctx.document, s.path) else { return nil }
        guard case .text(let t) = ctx.document.getElement(s.path) else { return nil }
        let measure = makeMeasurer(family: t.fontFamily, weight: t.fontWeight,
                                   style: t.fontStyle, size: t.fontSize)
        let maxW = (t.width > 0 && t.height > 0) ? t.width : 0.0
        let lay = layoutText(s.content, maxWidth: maxW, fontSize: t.fontSize, measure: measure)
        let tr = TextRender(x: t.x, y: t.y, fontSize: t.fontSize,
                            textWidth: t.width, textHeight: t.height,
                            fill: t.fill, stroke: t.stroke, content: s.content)
        return (tr, lay)
    }

    private func cursorAt(_ ctx: ToolContext, _ x: Double, _ y: Double) -> Int {
        guard let (tr, lay) = buildLayout(ctx) else { return 0 }
        let originY = (tr.textWidth > 0 && tr.textHeight > 0) ? tr.y : tr.y - tr.fontSize
        return lay.hitTest(x - tr.x, y - originY)
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
        if case .text(let t) = elem { content = t.content } else { content = "" }
        let s = TextEditSession(path: path, target: .text, content: content, insertion: cursor)
        s.blinkEpochMs = nowMs()
        session = s
        didSnapshot = false
        ctx.controller.selectElement(path)
    }

    private func beginSessionNew(_ ctx: ToolContext, x: Double, y: Double, w: Double, h: Double) {
        ctx.snapshot()
        didSnapshot = true
        let elem = Element.text(emptyTextElem(x: x, y: y, width: w, height: h))
        ctx.controller.addElement(elem)
        let doc = ctx.document
        let li = doc.selectedLayer
        let ci = doc.layers[li].children.count - 1
        let path: ElementPath = [li, ci]
        ctx.controller.selectElement(path)
        let s = TextEditSession(path: path, target: .text, content: "", insertion: 0)
        s.blinkEpochMs = nowMs()
        session = s
    }

    private func endSession() {
        session = nil
        didSnapshot = false
        dragStart = nil
        dragEnd = nil
        pointerInsideEdited = false
    }

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        if let s = session {
            if pathIsValid(ctx.document, s.path) {
                let elem = ctx.document.getElement(s.path)
                let inElem = inBox(textDrawBounds(elem), x, y)
                if inElem {
                    let cursor = cursorAt(ctx, x, y)
                    s.setInsertion(cursor, extend: false)
                    s.dragActive = true
                    s.blinkEpochMs = nowMs()
                    pointerInsideEdited = true
                    ctx.requestUpdate()
                    return
                }
            }
            endSession()
        }
        if let (path, elem) = hitTestText(ctx.document, x, y) {
            beginSessionExisting(ctx, path: path, elem: elem, cursor: 0)
            if let s2 = session {
                let cursor = cursorAt(ctx, x, y)
                s2.setInsertion(cursor, extend: false)
                s2.dragActive = true
                s2.blinkEpochMs = nowMs()
                pointerInsideEdited = true
                ctx.requestUpdate()
            }
        } else {
            dragStart = (x, y)
            dragEnd = (x, y)
        }
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        lastMoveMs = nowMs()
        if let s = session, s.dragActive, dragging {
            let cursor = cursorAt(ctx, x, y)
            s.setInsertion(cursor, extend: true)
            s.blinkEpochMs = nowMs()
            ctx.requestUpdate()
            return
        }
        if dragStart != nil {
            dragEnd = (x, y)
            ctx.requestUpdate()
        }
        if let s = session {
            hoverText = false
            if pathIsValid(ctx.document, s.path) {
                let elem = ctx.document.getElement(s.path)
                pointerInsideEdited = inBox(textDrawBounds(elem), x, y)
            } else {
                pointerInsideEdited = false
            }
        } else {
            hoverText = hitTestText(ctx.document, x, y) != nil
            pointerInsideEdited = false
        }
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        if let s = session {
            s.dragActive = false
            s.blinkEpochMs = nowMs()
            dragStart = nil
            dragEnd = nil
            ctx.requestUpdate()
            return
        }
        guard let (sx, sy) = dragStart else { return }
        dragStart = nil
        dragEnd = nil
        let w = abs(x - sx)
        let h = abs(y - sy)
        if w > dragThreshold || h > dragThreshold {
            beginSessionNew(ctx, x: min(sx, x), y: min(sy, y), w: w, h: h)
        } else {
            beginSessionNew(ctx, x: sx, y: sy, w: 0, h: 0)
        }
        pointerInsideEdited = true
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
        if session != nil {
            // While editing, always use the system I-beam. When the
            // pointer has been idle inside the edited text for a moment,
            // hide it so the rendered caret is not occluded.
            if pointerInsideEdited && nowMs() - lastMoveMs > 600 { return "none" }
            return "ibeam"
        }
        if hoverText { return "ibeam" }
        return nil
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
        case "Enter":
            ensureSnapshot(ctx); s.insert("\n")
            bump(); syncToModel(ctx); ctx.requestUpdate(); return true
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
        case "ArrowUp", "ArrowDown":
            if let (_, lay) = buildLayout(ctx) {
                let np = key == "ArrowUp" ? lay.cursorUp(s.insertion) : lay.cursorDown(s.insertion)
                s.setInsertion(np, extend: mods.shift)
                bump(); ctx.requestUpdate()
            }
            return true
        case "Home":
            if let (_, lay) = buildLayout(ctx) {
                let lineNo = lay.lineForCursor(s.insertion)
                s.setInsertion(lay.lines[lineNo].start, extend: mods.shift)
                bump(); ctx.requestUpdate()
            }
            return true
        case "End":
            if let (_, lay) = buildLayout(ctx) {
                let lineNo = lay.lineForCursor(s.insertion)
                s.setInsertion(lay.lines[lineNo].end, extend: mods.shift)
                bump(); ctx.requestUpdate()
            }
            return true
        default:
            if key.count == 1 && !cmd {
                ensureSnapshot(ctx); s.insert(key)
                bump(); syncToModel(ctx); ctx.requestUpdate(); return true
            }
            return false
        }
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        // Drag-create rect preview
        if session == nil, let (sx, sy) = dragStart, let (ex, ey) = dragEnd {
            cgCtx.setStrokeColor(CGColor(gray: 0.4, alpha: 1.0))
            cgCtx.setLineWidth(1.0)
            cgCtx.setLineDash(phase: 0, lengths: [4, 4])
            let r = CGRect(x: min(sx, ex), y: min(sy, ey),
                           width: abs(ex - sx), height: abs(ey - sy))
            cgCtx.addRect(r)
            cgCtx.strokePath()
            cgCtx.setLineDash(phase: 0, lengths: [])
        }

        guard let s = session, let (tr, lay) = buildLayout(ctx) else { return }

        // Layout-local origin: area text uses (x, y); point text uses
        // (x, y - fontSize) because the element y is the baseline.
        let originX = tr.x
        let originY = (tr.textWidth > 0 && tr.textHeight > 0) ? tr.y : tr.y - tr.fontSize

        // Selection highlight
        if s.hasSelection {
            let (lo, hi) = s.selectionRange
            cgCtx.setFillColor(CGColor(red: 0.529, green: 0.808, blue: 0.980, alpha: 0.45))
            for (lineIdx, line) in lay.lines.enumerated() {
                let lineLo = max(line.start, lo)
                let lineHi = min(line.end, hi)
                if lineLo >= lineHi { continue }
                func glyphX(_ i: Int) -> Double? {
                    for g in lay.glyphs where g.idx == i && g.line == lineIdx { return g.x }
                    return nil
                }
                let xLo = lineLo == line.start ? 0.0 : (glyphX(lineLo) ?? 0.0)
                let xHi = lineHi == line.end ? line.width : (glyphX(lineHi) ?? line.width)
                let r = CGRect(x: originX + xLo, y: originY + line.top,
                               width: xHi - xLo, height: line.height)
                cgCtx.fill(r)
            }
        }

        // Editing element bounding box. For area text use the explicit
        // (width, height); for point text derive both from the actual
        // layout (max line width × line count × fontSize) so the box
        // hugs the real rendered glyphs instead of a stub estimate.
        let bw: Double
        let bh: Double
        if tr.textWidth > 0 && tr.textHeight > 0 {
            bw = max(tr.textWidth, 1)
            bh = max(tr.textHeight, 1)
        } else {
            var maxW: Double = 0
            for l in lay.lines { maxW = max(maxW, l.width) }
            bw = max(maxW, tr.fontSize * 0.5)
            bh = max(Double(lay.lines.count) * tr.fontSize, tr.fontSize)
        }
        cgCtx.setStrokeColor(CGColor(red: 0.0, green: 0.47, blue: 0.84, alpha: 0.6))
        cgCtx.setLineWidth(1.0)
        cgCtx.stroke(CGRect(x: originX, y: originY, width: bw, height: bh))

        // Caret
        if cursorVisible(s.blinkEpochMs) {
            let (cx, cy, ch) = lay.cursorXY(s.insertion)
            let color: Color
            if let f = tr.fill { color = f.color }
            else if let st = tr.stroke { color = st.color }
            else { color = Color(r: 0, g: 0, b: 0) }
            cgCtx.setStrokeColor(CGColor(red: color.r, green: color.g, blue: color.b, alpha: 1.0))
            cgCtx.setLineWidth(1.5)
            cgCtx.move(to: CGPoint(x: originX + cx, y: originY + cy - ch * 0.8))
            cgCtx.addLine(to: CGPoint(x: originX + cx, y: originY + cy + ch * 0.2))
            cgCtx.strokePath()
        }
    }
}
