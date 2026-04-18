import AppKit
import Foundation

// MARK: - Type tool with native in-place text editing
//
// Click on existing unlocked text to edit; click on empty canvas to
// create a new empty Text element and enter editing immediately. Drag
// on empty canvas to create an area-text element. While editing, mouse
// drag extends the selection and standard editing keys flow through
// `onKeyEvent`.

private func nowMs() -> Double { textEditNowMs() }
private func cursorVisible(_ epochMs: Double) -> Bool { textEditCursorVisible(epochMs) }

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

/// Editing-overlay bounds for a Text element. `(x, y)` is the *top* of
/// the layout box (the baseline is `y + 0.8 * fontSize`); for area text
/// the bounds come from `(width, height)` directly, for point text from
/// the rendered line widths and the line count.
private func textDrawBounds(_ elem: Element) -> (Double, Double, Double, Double) {
    guard case .text(let t) = elem else { return (0, 0, 0, 0) }
    if t.width > 0 && t.height > 0 {
        return (t.x, t.y, max(t.width, 1), max(t.height, 1))
    }
    let raw = t.content.isEmpty ? " " : t.content
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    var maxW: Double = 0
    for l in lines {
        let w = renderedTextWidth(String(l), family: t.fontFamily,
                                  weight: t.fontWeight, style: t.fontStyle, size: t.fontSize)
        if w > maxW { maxW = w }
    }
    let h = Double(lines.count) * t.fontSize
    return (t.x, t.y, max(maxW, 1), h)
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

/// Drag-to-create state machine. Sealed so "dragging without a start"
/// is unrepresentable.
private enum DragState {
    case idle
    case dragging(startX: Double, startY: Double, curX: Double, curY: Double)
}

class TypeTool: CanvasTool {
    private var state: DragState = .idle
    private var session: TextEditSession?
    private var didSnapshot = false
    private var hoverText = false

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
        return lay.hitTest(x - tr.x, y - tr.y)
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
        ctx.model.currentEditSession = s
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
        ctx.model.currentEditSession = s
    }

    private func endSession(_ ctx: ToolContext? = nil) {
        session = nil
        didSnapshot = false
        state = .idle
        ctx?.model.currentEditSession = nil
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
                    ctx.requestUpdate()
                    return
                }
            }
            endSession(ctx)
        }
        if let (path, elem) = hitTestText(ctx.document, x, y) {
            beginSessionExisting(ctx, path: path, elem: elem, cursor: 0)
            if let s2 = session {
                let cursor = cursorAt(ctx, x, y)
                s2.setInsertion(cursor, extend: false)
                s2.dragActive = true
                s2.blinkEpochMs = nowMs()
                ctx.requestUpdate()
            }
        } else {
            state = .dragging(startX: x, startY: y, curX: x, curY: y)
        }
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        if let s = session, s.dragActive, dragging {
            let cursor = cursorAt(ctx, x, y)
            s.setInsertion(cursor, extend: true)
            s.blinkEpochMs = nowMs()
            ctx.requestUpdate()
            return
        }
        if case .dragging(let sx, let sy, _, _) = state {
            state = .dragging(startX: sx, startY: sy, curX: x, curY: y)
            ctx.requestUpdate()
        }
        if session == nil {
            hoverText = hitTestText(ctx.document, x, y) != nil
        } else {
            hoverText = false
        }
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        if let s = session {
            s.dragActive = false
            s.blinkEpochMs = nowMs()
            state = .idle
            ctx.requestUpdate()
            return
        }
        guard case .dragging(let sx, let sy, _, _) = state else { return }
        state = .idle
        let w = abs(x - sx)
        let h = abs(y - sy)
        if w > dragThreshold || h > dragThreshold {
            beginSessionNew(ctx, x: min(sx, x), y: min(sy, y), w: w, h: h)
        } else {
            beginSessionNew(ctx, x: sx, y: sy, w: 0, h: 0)
        }
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
        // While an edit session is active or the pointer is hovering an
        // unlocked Text element, switch to the system I-beam.
        if session != nil { return "ibeam" }
        if hoverText { return "ibeam" }
        return nil
    }

    func pasteText(_ ctx: ToolContext, _ text: String) -> Bool {
        guard let s = session else { return false }
        // Rich-paste preference:
        //   1. Session-scoped tspan clipboard (within-session copy/paste).
        //   2. Rich-format pasteboard (application/x-jas-tspans, then
        //      image/svg+xml) — survives cross-app paste too.
        //   3. Flat insert.
        let elemTspans = currentElementTspans(ctx)
        var newTspans: [Tspan]? = s.tryPasteTspans(elemTspans, text: text)
        if newTspans == nil, let payload = richClipboardReadTspans() {
            newTspans = insertTspansAt(elemTspans, charPos: s.insertion, payload)
        }
        if let new = newTspans {
            ensureSnapshot(ctx)
            replaceElementTspans(ctx, path: s.path, tspans: new)
            s.setContent(concatTspanContent(new),
                         insertion: s.insertion + text.count,
                         anchor: s.insertion + text.count)
            s.blinkEpochMs = nowMs()
            ctx.requestUpdate()
            return true
        }
        ensureSnapshot(ctx)
        s.insert(text)
        s.blinkEpochMs = nowMs()
        syncToModel(ctx)
        ctx.requestUpdate()
        return true
    }

    /// Read the current element's tspans from the doc for cut/copy/paste.
    private func currentElementTspans(_ ctx: ToolContext) -> [Tspan] {
        guard let s = session else { return [] }
        let elem = ctx.model.document.getElement(s.path)
        switch elem {
        case .text(let t): return t.tspans
        case .textPath(let tp): return tp.tspans
        default: return []
        }
    }

    /// Replace the tspans on the element at `path` in the model's
    /// document. Used by the tspan-aware paste path.
    private func replaceElementTspans(_ ctx: ToolContext, path: ElementPath, tspans: [Tspan]) {
        let elem = ctx.model.document.getElement(path)
        let newElem: Element
        switch elem {
        case .text(let t): newElem = .text(t.withTspans(tspans))
        case .textPath(let tp): newElem = .textPath(tp.withTspans(tspans))
        default: return
        }
        ctx.model.document = ctx.model.document.replaceElement(path, with: newElem)
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
            // Capture the selection's tspan overrides for both the
            // session-scoped fast path and the multi-format OS
            // pasteboard. Flat text goes as .string; the tspan list
            // rides on application/x-jas-tspans and image/svg+xml
            // for cross-element / cross-app paste.
            let elem = currentElementTspans(ctx)
            if let flat = s.copySelectionWithTspans(elem),
               let (_, payload) = s.tspanClipboard
            {
                richClipboardWrite(flat: flat, tspans: payload)
            }
            return true
        }
        if cmd && lower == "x" {
            let elem = currentElementTspans(ctx)
            if let flat = s.copySelectionWithTspans(elem),
               let (_, payload) = s.tspanClipboard
            {
                richClipboardWrite(flat: flat, tspans: payload)
                ensureSnapshot(ctx)
                s.backspace()
                bump(); syncToModel(ctx); ctx.requestUpdate()
            }
            return true
        }
        switch key {
        case "Escape":
            endSession(ctx); ctx.requestUpdate(); return true
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
        if session == nil, case .dragging(let sx, let sy, let ex, let ey) = state {
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

        // Layout-local origin: `(x, y)` is the top of the layout box for
        // both point text and area text.
        let originX = tr.x
        let originY = tr.y

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

        // The bounding box around the edited text is not drawn here —
        // the Type tool selects the element when it starts editing,
        // so the selection overlay (see `drawElementOverlay` /
        // `drawSelectionOverlays` in `Canvas/CanvasSubwindow.swift`)
        // is responsible for rendering the box. That keeps the rule
        // "area text shows its bbox iff the element is selected" in
        // a single place.

        // Caret
        if cursorVisible(s.blinkEpochMs) {
            let (cx, cy, ch) = lay.cursorXY(s.insertion)
            let color: Color
            if let f = tr.fill { color = f.color }
            else if let st = tr.stroke { color = st.color }
            else { color = Color(r: 0, g: 0, b: 0) }
            let (cr, cg, cb, _) = color.toRgba()
            cgCtx.setStrokeColor(CGColor(red: cr, green: cg, blue: cb, alpha: 1.0))
            cgCtx.setLineWidth(1.5)
            cgCtx.move(to: CGPoint(x: originX + cx, y: originY + cy - ch * 0.8))
            cgCtx.addLine(to: CGPoint(x: originX + cx, y: originY + cy + ch * 0.2))
            cgCtx.strokePath()
        }
    }
}
