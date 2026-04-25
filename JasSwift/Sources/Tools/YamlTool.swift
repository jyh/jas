// YAML-driven canvas tool — the Swift analogue of
// jas_dioxus/src/tools/yaml_tool.rs.
//
// Parses a tool spec (typically from workspace.json under `tools.<id>`)
// into a ToolSpec, seeds a private StateStore with its state defaults,
// and routes CanvasTool events through the declared handlers via
// runEffects + buildYamlToolEffects.
//
// Phase 5 of the Swift YAML tool-runtime migration (see
// SWIFT_TOOL_RUNTIME.md): CanvasTool conformance + event dispatch.
// Overlay rendering is a stub — overlay specs are parsed but not
// drawn (Phase 5b).

import AppKit
import Foundation

// MARK: - ToolSpec

/// Parsed shape of a tool YAML spec. Pure data — no evaluator or
/// model references.
struct ToolSpec {
    let id: String
    let cursor: String?
    let menuLabel: String?
    let shortcut: String?
    /// Initial values for `$tool.<id>.<var>` state.
    let stateDefaults: [String: Any]
    /// Event handlers keyed by event name (on_mousedown, on_mousemove,
    /// on_mouseup, on_enter, on_leave, on_dblclick, on_keydown). Each
    /// value is the raw effect list.
    let handlers: [String: [Any]]
    /// Overlay declarations. Most tools have zero or one entry; the
    /// transform-tool family (Scale / Rotate / Shear) uses multiple
    /// to layer the reference-point cross over the drag-time bbox
    /// ghost. Each entry's `guardExpr` is evaluated independently.
    let overlay: [OverlaySpec]

    /// Parse a workspace tool dict, typically from `workspace.json`
    /// under `tools.<id>`. Returns nil if required `id` is missing.
    static func fromWorkspaceTool(_ spec: [String: Any]) -> ToolSpec? {
        guard let id = spec["id"] as? String else { return nil }
        return ToolSpec(
            id: id,
            cursor: spec["cursor"] as? String,
            menuLabel: spec["menu_label"] as? String,
            shortcut: spec["shortcut"] as? String,
            stateDefaults: parseStateDefaults(spec["state"]),
            handlers: parseHandlers(spec["handlers"]),
            overlay: parseOverlay(spec["overlay"])
        )
    }

    /// Fetch a handler by event name. Returns an empty list when the
    /// event has no declared handler — callers treat that as a no-op.
    func handler(_ eventName: String) -> [Any] {
        handlers[eventName] ?? []
    }
}

/// Tool-overlay declaration — a guard expression plus a render dict.
struct OverlaySpec {
    /// Expression that must evaluate truthy for the overlay to draw.
    /// nil → always draw.
    let guardExpr: String?
    /// The `render:` subtree; shape depends on the overlay type.
    let render: [String: Any]
}

private func parseStateDefaults(_ val: Any?) -> [String: Any] {
    guard let map = val as? [String: Any] else { return [:] }
    var out: [String: Any] = [:]
    for (key, defn) in map {
        if let d = defn as? [String: Any] {
            // Long form `{ default: <value>, enum?: [...] }`.
            out[key] = d["default"] ?? NSNull()
        } else {
            // Shorthand: the value is the default directly.
            out[key] = defn
        }
    }
    return out
}

private func parseHandlers(_ val: Any?) -> [String: [Any]] {
    guard let map = val as? [String: Any] else { return [:] }
    var out: [String: [Any]] = [:]
    for (name, effects) in map {
        if let arr = effects as? [Any] { out[name] = arr }
    }
    return out
}

private func parseOverlayEntry(_ obj: [String: Any]) -> OverlaySpec? {
    guard let render = obj["render"] as? [String: Any] else { return nil }
    return OverlaySpec(guardExpr: obj["if"] as? String, render: render)
}

private func parseOverlay(_ val: Any?) -> [OverlaySpec] {
    // Accept either a single {if, render} object (most tools) or a
    // list of such objects (transform-tool family). Both produce
    // the same [OverlaySpec] downstream.
    if let obj = val as? [String: Any] {
        return parseOverlayEntry(obj).map { [$0] } ?? []
    }
    if let arr = val as? [Any] {
        return arr.compactMap { ($0 as? [String: Any]).flatMap(parseOverlayEntry) }
    }
    return []
}

// MARK: - YamlTool

/// YAML-driven tool. Holds a parsed ToolSpec and a private StateStore
/// seeded with the tool's defaults. CanvasTool methods build the
/// `$event` scope, register the current document for doc-aware
/// primitives, and dispatch through runEffects.
///
/// The store is self-contained — mutations persist between calls on
/// this tool's own store only. Integrating with the app-wide store
/// happens when the YAML tool runtime takes over tool dispatch.
final class YamlTool: CanvasTool {
    let spec: ToolSpec
    private let store: StateStore

    init(spec: ToolSpec) {
        self.spec = spec
        self.store = StateStore()
        self.store.initTool(spec.id, defaults: spec.stateDefaults)
    }

    /// Convenience: parse the workspace dict, returning nil on invalid
    /// spec (missing id).
    static func fromWorkspaceTool(_ spec: [String: Any]) -> YamlTool? {
        ToolSpec.fromWorkspaceTool(spec).map(YamlTool.init)
    }

    /// Read a tool-local state value. Primary use: tests observing
    /// what a handler wrote to `$tool.<id>.<key>`.
    func toolState(_ key: String) -> Any? {
        store.getTool(spec.id, key)
    }

    // MARK: Event payload builders

    private func pointerPayload(
        _ type: String, x: Double, y: Double,
        shift: Bool, alt: Bool, dragging: Bool? = nil
    ) -> [String: Any] {
        var mods: [String: Any] = [
            "shift": shift, "alt": alt,
            "ctrl": false, "meta": false,
        ]
        _ = mods
        var p: [String: Any] = [
            "type": type,
            "x": x, "y": y,
            "modifiers": [
                "shift": shift, "alt": alt,
                "ctrl": false, "meta": false,
            ],
        ]
        if let d = dragging { p["dragging"] = d }
        return p
    }

    /// Dispatch the handler for `eventName`. Registers the Model's
    /// document for doc-aware primitives, runs the handler's effects,
    /// then drops the registration. No-op when the event isn't declared.
    private func dispatch(
        _ eventName: String,
        payload: [String: Any],
        model: Model
    ) {
        let handlerEffects = spec.handler(eventName)
        if handlerEffects.isEmpty { return }
        let ctx: [String: Any] = ["event": payload]
        // Registration tears down on DocRegistration deinit — handler
        // panics still leave the doc-primitive slot clean.
        let _reg = registerDocument(model.document)
        let effects = buildYamlToolEffects(model: model)
        runEffects(handlerEffects, ctx: ctx, store: store,
                   platformEffects: effects)
        _ = _reg
    }

    // MARK: - CanvasTool

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        dispatch("on_mousedown",
                 payload: pointerPayload("mousedown", x: x, y: y,
                                         shift: shift, alt: alt),
                 model: ctx.model)
        ctx.requestUpdate()
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        dispatch("on_mousemove",
                 payload: pointerPayload("mousemove", x: x, y: y,
                                         shift: shift, alt: false,
                                         dragging: dragging),
                 model: ctx.model)
        ctx.requestUpdate()
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        dispatch("on_mouseup",
                 payload: pointerPayload("mouseup", x: x, y: y,
                                         shift: shift, alt: alt),
                 model: ctx.model)
        ctx.requestUpdate()
    }

    func onDoubleClick(_ ctx: ToolContext, x: Double, y: Double) {
        dispatch("on_dblclick",
                 payload: ["type": "dblclick", "x": x, "y": y],
                 model: ctx.model)
        ctx.requestUpdate()
    }

    func activate(_ ctx: ToolContext) {
        // Reset tool-local state to declared defaults, then fire on_enter.
        store.initTool(spec.id, defaults: spec.stateDefaults)
        dispatch("on_enter", payload: ["type": "enter"], model: ctx.model)
        ctx.requestUpdate()
    }

    func deactivate(_ ctx: ToolContext) {
        dispatch("on_leave", payload: ["type": "leave"], model: ctx.model)
        ctx.requestUpdate()
    }

    func cursorOverride() -> String? { spec.cursor }

    func onKeyEvent(_ ctx: ToolContext, _ key: String, _ mods: KeyMods) -> Bool {
        if spec.handler("on_keydown").isEmpty { return false }
        let payload: [String: Any] = [
            "type": "keydown",
            "key": key,
            "modifiers": [
                "shift": mods.shift, "alt": mods.alt,
                "ctrl": mods.ctrl, "meta": mods.cmd,
            ],
        ]
        dispatch("on_keydown", payload: payload, model: ctx.model)
        ctx.requestUpdate()
        return true
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        if spec.overlay.isEmpty { return }
        let _reg = registerDocument(ctx.model.document)
        let evalCtx = store.evalContext()
        for overlay in spec.overlay {
            // Guard evaluates in the same scope the handler used.
            if let guardExpr = overlay.guardExpr,
               !evaluate(guardExpr, context: evalCtx).toBool() {
                continue
            }
            let render = overlay.render
            let type = render["type"] as? String ?? ""
            switch type {
            case "rect": drawRectOverlay(cgCtx, render, evalCtx)
            case "line": drawLineOverlay(cgCtx, render, evalCtx)
            case "polygon": drawPolygonOverlay(cgCtx, render, evalCtx)
            case "star": drawStarOverlay(cgCtx, render, evalCtx)
            case "buffer_polygon": drawBufferPolygonOverlay(cgCtx, render)
            case "buffer_polyline":
                drawBufferPolylineOverlay(cgCtx, render, evalCtx)
            case "pen_overlay": drawPenOverlay(cgCtx, render, evalCtx)
            case "partial_selection_overlay":
                drawPartialSelectionOverlay(cgCtx, render, evalCtx,
                                             model: ctx.model)
            case "oval_cursor":
                drawOvalCursorOverlay(cgCtx, render, evalCtx)
            case "reference_point_cross":
                drawReferencePointCross(cgCtx, render, evalCtx,
                                         model: ctx.model)
            case "bbox_ghost":
                drawBBoxGhost(cgCtx, render, evalCtx, model: ctx.model)
            case "marquee_rect":
                drawMarqueeRectOverlay(cgCtx, render, evalCtx)
            case "artboard_resize_handles":
                drawArtboardResizeHandles(cgCtx, render, evalCtx,
                                          model: ctx.model)
            case "artboard_outline_preview":
                drawArtboardOutlinePreview(cgCtx, render, evalCtx,
                                           model: ctx.model)
            default: break
            }
        }
        _ = _reg
    }
}

// MARK: - Overlay rendering

/// Subset of SVG style properties the overlay renderer understands.
/// Internal (not private) so tests can observe parsed output.
struct OverlayStyle: Equatable {
    var fill: CGColor? = nil
    var stroke: CGColor? = nil
    var strokeWidth: CGFloat = 1
    var dash: [CGFloat] = []

    static func == (lhs: OverlayStyle, rhs: OverlayStyle) -> Bool {
        lhs.strokeWidth == rhs.strokeWidth
            && lhs.dash == rhs.dash
            && cgColorEquals(lhs.fill, rhs.fill)
            && cgColorEquals(lhs.stroke, rhs.stroke)
    }
}

private func cgColorEquals(_ a: CGColor?, _ b: CGColor?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (.some(let x), .some(let y)): return x == y
    default: return false
    }
}

/// Parse a CSS-like "key: value; key: value" string into OverlayStyle.
/// Internal so tests can inspect the result.
func parseOverlayStyle(_ s: String) -> OverlayStyle {
    var style = OverlayStyle()
    for rule in s.split(separator: ";") {
        let trimmed = rule.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { continue }
        let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        switch key {
        case "fill": style.fill = parseOverlayColor(value)
        case "stroke": style.stroke = parseOverlayColor(value)
        case "stroke-width":
            if let n = Double(value) { style.strokeWidth = CGFloat(n) }
        case "stroke-dasharray":
            let parts = value.split(whereSeparator: { $0 == " " || $0 == "," })
            style.dash = parts.compactMap { Double($0).map { CGFloat($0) } }
        default: break
        }
    }
    return style
}

/// Parse `#rgb`, `#rrggbb`, `rgba(r,g,b,a)`, `rgb(r,g,b)`, `none`.
/// Internal so overlay tests can inspect parsing.
func parseOverlayColor(_ s: String) -> CGColor? {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t == "none" { return nil }
    if t.hasPrefix("#") {
        // Expand 3-char hex (#rgb) to 6-char so Color.fromHex accepts it.
        var expanded = t
        let body = String(t.dropFirst())
        if body.count == 3, body.allSatisfy({ $0.isHexDigit }) {
            expanded = "#" + body.map { "\($0)\($0)" }.joined()
        }
        if let c = Color.fromHex(expanded) {
            let (r, g, b, a) = c.toRgba()
            return CGColor(red: r, green: g, blue: b, alpha: a)
        }
        return nil
    }
    if t.hasPrefix("rgba(") || t.hasPrefix("rgb(") {
        let open = t.firstIndex(of: "(")!
        let close = t.firstIndex(of: ")") ?? t.endIndex
        let inner = String(t[t.index(after: open)..<close])
        let parts = inner.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count >= 3,
              let r = Double(parts[0]), let g = Double(parts[1]),
              let b = Double(parts[2]) else { return nil }
        let a: Double = parts.count >= 4 ? (Double(parts[3]) ?? 1) : 1
        return CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
    return nil
}

/// Evaluate a render field that may be a number literal or a string
/// expression. Missing → 0.
private func evalOverlayNumber(_ field: Any?, _ ctx: [String: Any]) -> Double {
    if let n = field as? NSNumber { return n.doubleValue }
    if let d = field as? Double { return d }
    if let i = field as? Int { return Double(i) }
    if let s = field as? String {
        if case .number(let n) = evaluate(s, context: ctx) { return n }
    }
    return 0
}

/// Apply stroke + fill + dash from `style` to `cgCtx` and stroke/fill
/// the current path.
private func applyOverlayStyle(_ cgCtx: CGContext, _ style: OverlayStyle) {
    if let fill = style.fill {
        cgCtx.setFillColor(fill)
        cgCtx.fillPath()
    }
    if let stroke = style.stroke {
        cgCtx.setStrokeColor(stroke)
        cgCtx.setLineWidth(style.strokeWidth)
        if !style.dash.isEmpty {
            cgCtx.setLineDash(phase: 0, lengths: style.dash)
        }
        cgCtx.strokePath()
        cgCtx.setLineDash(phase: 0, lengths: [])
    }
}

/// Marquee zoom rectangle: thin dashed stroke between (x1, y1) and
/// (x2, y2). Used by the Zoom tool's drag overlay when scrubby_zoom
/// is off. Per ZOOM_TOOL.md §Drag — marquee zoom.
/// Draw the 8 resize handles on the single panel-selected artboard
/// per ARTBOARD_TOOL.md §Drag-to-resize. Mirrors the Rust
/// draw_artboard_resize_handles. Handles are 8 px screen-space
/// squares; coordinates transform from document to viewport via
/// model.zoomLevel + view_offset.
private func drawArtboardResizeHandles(
    _ cgCtx: CGContext, _ spec: [String: Any], _ ctx: [String: Any],
    model: Model
) {
    let idValue = evalExprString(spec["artboard_id"], ctx)
    guard !idValue.isEmpty,
          let ab = model.document.artboards.first(where: { $0.id == idValue })
    else { return }
    let zoom = model.zoomLevel
    let offx = model.viewOffsetX
    let offy = model.viewOffsetY
    let cx = ab.x + ab.width / 2.0
    let cy = ab.y + ab.height / 2.0
    let positions: [(Double, Double)] = [
        (ab.x, ab.y),
        (cx, ab.y),
        (ab.x + ab.width, ab.y),
        (ab.x + ab.width, cy),
        (ab.x + ab.width, ab.y + ab.height),
        (cx, ab.y + ab.height),
        (ab.x, ab.y + ab.height),
        (ab.x, cy),
    ]
    let handleSize: CGFloat = 8.0
    let half = handleSize / 2.0
    cgCtx.saveGState()
    cgCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    cgCtx.setStrokeColor(CGColor(red: 0, green: 120/255.0, blue: 1, alpha: 1))
    cgCtx.setLineWidth(1.5)
    for (dx, dy) in positions {
        let vx = CGFloat(dx * zoom + offx)
        let vy = CGFloat(dy * zoom + offy)
        let rect = CGRect(x: vx - half, y: vy - half,
                          width: handleSize, height: handleSize)
        cgCtx.fill(rect)
        cgCtx.stroke(rect)
    }
    cgCtx.restoreGState()
}

/// Draw the outline-preview rectangle for in-flight move / resize /
/// duplicate gestures when update_while_dragging is false. Phase 1
/// implementation: simple stroked rectangle around the artboard's
/// current bounds (post-restore_preview_snapshot, the in-flight
/// values are already on the model).
private func drawArtboardOutlinePreview(
    _ cgCtx: CGContext, _ spec: [String: Any], _ ctx: [String: Any],
    model: Model
) {
    let idValue = evalExprString(spec["artboard_id"], ctx)
    guard !idValue.isEmpty,
          let ab = model.document.artboards.first(where: { $0.id == idValue })
    else { return }
    let zoom = model.zoomLevel
    let offx = model.viewOffsetX
    let offy = model.viewOffsetY
    let vx = CGFloat(ab.x * zoom + offx)
    let vy = CGFloat(ab.y * zoom + offy)
    let vw = CGFloat(ab.width * zoom)
    let vh = CGFloat(ab.height * zoom)
    cgCtx.saveGState()
    cgCtx.setStrokeColor(CGColor(red: 0, green: 120/255.0, blue: 1, alpha: 1))
    cgCtx.setLineWidth(1.0)
    cgCtx.stroke(CGRect(x: vx, y: vy, width: vw, height: vh))
    cgCtx.restoreGState()
}

/// Evaluate a render-spec field as a string (handles bare strings,
/// expression strings, and Value results).
private func evalExprString(_ arg: Any?, _ ctx: [String: Any]) -> String {
    guard let s = arg as? String else { return "" }
    let v = evaluate(s, context: ctx)
    if case .string(let result) = v { return result }
    // Fallback: treat as literal.
    return s
}

private func drawMarqueeRectOverlay(
    _ cgCtx: CGContext, _ spec: [String: Any], _ ctx: [String: Any]
) {
    let x1 = evalOverlayNumber(spec["x1"], ctx)
    let y1 = evalOverlayNumber(spec["y1"], ctx)
    let x2 = evalOverlayNumber(spec["x2"], ctx)
    let y2 = evalOverlayNumber(spec["y2"], ctx)
    let x = min(x1, x2)
    let y = min(y1, y2)
    let w = abs(x1 - x2)
    let h = abs(y1 - y2)
    if w <= 0 || h <= 0 { return }
    cgCtx.saveGState()
    cgCtx.setStrokeColor(CGColor(gray: 0.4, alpha: 1.0))
    cgCtx.setLineWidth(1.0)
    cgCtx.setLineDash(phase: 0, lengths: [4, 2])
    cgCtx.stroke(CGRect(x: x, y: y, width: w, height: h))
    cgCtx.restoreGState()
}

private func drawRectOverlay(
    _ cgCtx: CGContext, _ spec: [String: Any], _ ctx: [String: Any]
) {
    let x = evalOverlayNumber(spec["x"], ctx)
    let y = evalOverlayNumber(spec["y"], ctx)
    let w = evalOverlayNumber(spec["width"], ctx)
    let h = evalOverlayNumber(spec["height"], ctx)
    let rx = evalOverlayNumber(spec["rx"], ctx)
    let ry = evalOverlayNumber(spec["ry"], ctx)
    let style = parseOverlayStyle((spec["style"] as? String) ?? "")
    let rect = CGRect(x: x, y: y, width: w, height: h)
    if rx > 0 || ry > 0 {
        // Fill + stroke both need a fresh path — draw fill first, then
        // re-add for stroke.
        if let fill = style.fill {
            let p = CGPath(roundedRect: rect,
                           cornerWidth: rx, cornerHeight: ry,
                           transform: nil)
            cgCtx.addPath(p)
            cgCtx.setFillColor(fill)
            cgCtx.fillPath()
        }
        if let stroke = style.stroke {
            let p = CGPath(roundedRect: rect,
                           cornerWidth: rx, cornerHeight: ry,
                           transform: nil)
            cgCtx.addPath(p)
            cgCtx.setStrokeColor(stroke)
            cgCtx.setLineWidth(style.strokeWidth)
            if !style.dash.isEmpty {
                cgCtx.setLineDash(phase: 0, lengths: style.dash)
            }
            cgCtx.strokePath()
            cgCtx.setLineDash(phase: 0, lengths: [])
        }
    } else {
        cgCtx.addRect(rect)
        if style.fill != nil && style.stroke != nil {
            // One path per draw op; duplicate.
            let fill = style.fill!
            cgCtx.setFillColor(fill)
            cgCtx.fillPath()
            cgCtx.addRect(rect)
        }
        applyOverlayStyle(cgCtx, style)
    }
}

private func drawLineOverlay(
    _ cgCtx: CGContext, _ spec: [String: Any], _ ctx: [String: Any]
) {
    let x1 = evalOverlayNumber(spec["x1"], ctx)
    let y1 = evalOverlayNumber(spec["y1"], ctx)
    let x2 = evalOverlayNumber(spec["x2"], ctx)
    let y2 = evalOverlayNumber(spec["y2"], ctx)
    let style = parseOverlayStyle((spec["style"] as? String) ?? "")
    cgCtx.move(to: CGPoint(x: x1, y: y1))
    cgCtx.addLine(to: CGPoint(x: x2, y: y2))
    applyOverlayStyle(cgCtx, style)
}

/// Shared polygon-path helper for polygon and star overlays.
private func strokePolygonOverlay(
    _ cgCtx: CGContext, _ pts: [(Double, Double)], _ style: OverlayStyle
) {
    guard let first = pts.first else { return }
    cgCtx.move(to: CGPoint(x: first.0, y: first.1))
    for p in pts.dropFirst() {
        cgCtx.addLine(to: CGPoint(x: p.0, y: p.1))
    }
    cgCtx.closePath()
    if let fill = style.fill {
        cgCtx.setFillColor(fill)
        cgCtx.fillPath()
        // Re-add for stroke.
        cgCtx.move(to: CGPoint(x: first.0, y: first.1))
        for p in pts.dropFirst() {
            cgCtx.addLine(to: CGPoint(x: p.0, y: p.1))
        }
        cgCtx.closePath()
    }
    if let stroke = style.stroke {
        cgCtx.setStrokeColor(stroke)
        cgCtx.setLineWidth(style.strokeWidth)
        if !style.dash.isEmpty {
            cgCtx.setLineDash(phase: 0, lengths: style.dash)
        }
        cgCtx.strokePath()
        cgCtx.setLineDash(phase: 0, lengths: [])
    }
}

private func drawPolygonOverlay(
    _ cgCtx: CGContext, _ spec: [String: Any], _ ctx: [String: Any]
) {
    let x1 = evalOverlayNumber(spec["x1"], ctx)
    let y1 = evalOverlayNumber(spec["y1"], ctx)
    let x2 = evalOverlayNumber(spec["x2"], ctx)
    let y2 = evalOverlayNumber(spec["y2"], ctx)
    let sidesRaw = Int(evalOverlayNumber(spec["sides"], ctx))
    let sides = sidesRaw <= 0 ? 5 : sidesRaw
    let pts = regularPolygonPoints(x1, y1, x2, y2, sides)
    let style = parseOverlayStyle((spec["style"] as? String) ?? "")
    strokePolygonOverlay(cgCtx, pts, style)
}

private func drawStarOverlay(
    _ cgCtx: CGContext, _ spec: [String: Any], _ ctx: [String: Any]
) {
    let x1 = evalOverlayNumber(spec["x1"], ctx)
    let y1 = evalOverlayNumber(spec["y1"], ctx)
    let x2 = evalOverlayNumber(spec["x2"], ctx)
    let y2 = evalOverlayNumber(spec["y2"], ctx)
    let raw = Int(evalOverlayNumber(spec["points"], ctx))
    let n = raw <= 0 ? 5 : raw
    let pts = starPoints(x1, y1, x2, y2, n)
    let style = parseOverlayStyle((spec["style"] as? String) ?? "")
    strokePolygonOverlay(cgCtx, pts, style)
}

/// Stroke/fill a closed polygon made of the named point buffer's
/// points. Used by the Lasso tool's overlay.
private func drawBufferPolygonOverlay(
    _ cgCtx: CGContext, _ spec: [String: Any]
) {
    guard let name = spec["buffer"] as? String else { return }
    let pts = pointBuffersPoints(name)
    guard pts.count >= 2 else { return }
    let style = parseOverlayStyle((spec["style"] as? String) ?? "")
    strokePolygonOverlay(cgCtx, pts, style)
}

/// Render the Pen tool's in-progress path: the committed curve
/// through placed anchors, handle markers on the last anchor, and
/// a dashed preview curve from the last anchor to the current
/// cursor (only when not actively dragging).
private func drawPenOverlay(
    _ cgCtx: CGContext, _ spec: [String: Any], _ ctx: [String: Any]
) {
    guard let name = spec["buffer"] as? String else { return }
    let anchors = anchorBuffersAnchors(name)
    guard !anchors.isEmpty else { return }
    let mouseX = evalOverlayNumber(spec["mouse_x"], ctx)
    let mouseY = evalOverlayNumber(spec["mouse_y"], ctx)
    let closeR = max(1.0, evalOverlayNumber(spec["close_radius"], ctx))
    let placing = evaluateOverlayBool(spec["placing"], ctx)

    let stroke = CGColor(red: 0, green: 0.47, blue: 1.0, alpha: 1)
    cgCtx.setStrokeColor(stroke)
    cgCtx.setLineWidth(1)

    // Committed curve: MoveTo(first) + CurveTo(...) through pairs.
    if anchors.count >= 2 {
        cgCtx.move(to: CGPoint(x: anchors[0].x, y: anchors[0].y))
        for i in 1..<anchors.count {
            let prev = anchors[i - 1]
            let curr = anchors[i]
            cgCtx.addCurve(
                to: CGPoint(x: curr.x, y: curr.y),
                control1: CGPoint(x: prev.hxOut, y: prev.hyOut),
                control2: CGPoint(x: curr.hxIn, y: curr.hyIn)
            )
        }
        cgCtx.strokePath()
    }

    // Anchor dots.
    cgCtx.setFillColor(stroke)
    for a in anchors {
        cgCtx.fillEllipse(in: CGRect(x: a.x - 3, y: a.y - 3,
                                      width: 6, height: 6))
    }

    // Handle bar for the last anchor (when smooth).
    if let last = anchors.last, last.smooth {
        cgCtx.move(to: CGPoint(x: last.hxIn, y: last.hyIn))
        cgCtx.addLine(to: CGPoint(x: last.hxOut, y: last.hyOut))
        cgCtx.strokePath()
        cgCtx.fillEllipse(in: CGRect(x: last.hxOut - 2, y: last.hyOut - 2,
                                      width: 4, height: 4))
    }

    // Preview curve: dashed segment from last anchor to cursor when
    // placing the next anchor (not during an active handle drag).
    if placing, let last = anchors.last {
        cgCtx.setLineDash(phase: 0, lengths: [3, 3])
        cgCtx.move(to: CGPoint(x: last.x, y: last.y))
        cgCtx.addLine(to: CGPoint(x: mouseX, y: mouseY))
        cgCtx.strokePath()
        cgCtx.setLineDash(phase: 0, lengths: [])
    }

    // Close-hit circle on the first anchor when within reach.
    if anchors.count >= 2, placing, let first = anchors.first {
        let dx = mouseX - first.x, dy = mouseY - first.y
        if (dx * dx + dy * dy).squareRoot() < closeR {
            cgCtx.setStrokeColor(CGColor(red: 1, green: 0.47, blue: 0, alpha: 1))
            cgCtx.strokeEllipse(in: CGRect(
                x: first.x - closeR, y: first.y - closeR,
                width: closeR * 2, height: closeR * 2))
        }
    }
}

/// Render the Partial Selection tool's combined overlay:
/// - per-selected-path: every anchor as a small square plus the in/out
///   bezier handle bars
/// - when mode == "marquee": a dashed rubber-band rectangle
private func drawPartialSelectionOverlay(
    _ cgCtx: CGContext, _ spec: [String: Any], _ ctx: [String: Any],
    model: Model
) {
    let stroke = CGColor(red: 0, green: 0.47, blue: 1, alpha: 1)
    cgCtx.setStrokeColor(stroke)
    cgCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    cgCtx.setLineWidth(1)

    // Anchor + handle markers on every selected Path.
    for es in model.document.selection {
        guard case .path(let pe) = model.document.getElement(es.path) else { continue }
        let anchors = Element.path(pe).controlPointPositions
        for (ai, pt) in anchors.enumerated() {
            let (hIn, hOut) = pathHandlePositions(pe.d, anchorIdx: ai)
            if let h = hIn {
                cgCtx.move(to: CGPoint(x: pt.0, y: pt.1))
                cgCtx.addLine(to: CGPoint(x: h.0, y: h.1))
                cgCtx.strokePath()
                cgCtx.fillEllipse(in: CGRect(x: h.0 - 2, y: h.1 - 2,
                                              width: 4, height: 4))
                cgCtx.strokeEllipse(in: CGRect(x: h.0 - 2, y: h.1 - 2,
                                                width: 4, height: 4))
            }
            if let h = hOut {
                cgCtx.move(to: CGPoint(x: pt.0, y: pt.1))
                cgCtx.addLine(to: CGPoint(x: h.0, y: h.1))
                cgCtx.strokePath()
                cgCtx.fillEllipse(in: CGRect(x: h.0 - 2, y: h.1 - 2,
                                              width: 4, height: 4))
                cgCtx.strokeEllipse(in: CGRect(x: h.0 - 2, y: h.1 - 2,
                                                width: 4, height: 4))
            }
            // Anchor square.
            cgCtx.fill(CGRect(x: pt.0 - 2.5, y: pt.1 - 2.5,
                              width: 5, height: 5))
            cgCtx.stroke(CGRect(x: pt.0 - 2.5, y: pt.1 - 2.5,
                                width: 5, height: 5))
        }
    }

    // Marquee rubber-band.
    if let mode = spec["mode"] as? String,
       evaluate(mode, context: ctx).toStringCoerce() == "marquee" {
        let x1 = evalOverlayNumber(spec["marquee_start_x"], ctx)
        let y1 = evalOverlayNumber(spec["marquee_start_y"], ctx)
        let x2 = evalOverlayNumber(spec["marquee_cur_x"], ctx)
        let y2 = evalOverlayNumber(spec["marquee_cur_y"], ctx)
        let rect = CGRect(x: min(x1, x2), y: min(y1, y2),
                          width: abs(x2 - x1), height: abs(y2 - y1))
        cgCtx.setStrokeColor(stroke)
        cgCtx.setLineDash(phase: 0, lengths: [4, 4])
        cgCtx.stroke(rect)
        cgCtx.setLineDash(phase: 0, lengths: [])
    }
}

/// Evaluate an overlay guard-style boolean (string expression or
/// JSON bool). Missing / unparseable → false.
private func evaluateOverlayBool(_ field: Any?, _ ctx: [String: Any]) -> Bool {
    if let b = field as? Bool { return b }
    if let s = field as? String {
        return evaluate(s, context: ctx).toBool()
    }
    return false
}

/// Stroke an open polyline made of the named point buffer's points.
/// Used by the Pencil tool's overlay. When the render spec carries a
/// truthy `close_hint` expression, additionally draws a 1 px dashed
/// line from the last buffer point back to the first — Paintbrush
/// close-at-release preview per PAINTBRUSH_TOOL.md §Overlay.
private func drawBufferPolylineOverlay(
    _ cgCtx: CGContext, _ spec: [String: Any],
    _ evalCtx: [String: Any]
) {
    guard let name = spec["buffer"] as? String else { return }
    let pts = pointBuffersPoints(name)
    guard let first = pts.first, pts.count >= 2 else { return }
    let style = parseOverlayStyle((spec["style"] as? String) ?? "")
    cgCtx.move(to: CGPoint(x: first.0, y: first.1))
    for p in pts.dropFirst() {
        cgCtx.addLine(to: CGPoint(x: p.0, y: p.1))
    }
    if let stroke = style.stroke {
        cgCtx.setStrokeColor(stroke)
        cgCtx.setLineWidth(style.strokeWidth)
        if !style.dash.isEmpty {
            cgCtx.setLineDash(phase: 0, lengths: style.dash)
        }
        cgCtx.strokePath()
        cgCtx.setLineDash(phase: 0, lengths: [])
    }

    // Close-at-release hint.
    let hintOn: Bool = {
        switch spec["close_hint"] {
        case let b as Bool: return b
        case let s as String:
            return evaluate(s, context: evalCtx).toBool()
        default: return false
        }
    }()
    if hintOn, let last = pts.last, let stroke = style.stroke {
        cgCtx.setStrokeColor(stroke)
        cgCtx.setLineWidth(1.0)
        cgCtx.setLineDash(phase: 0, lengths: [4, 4])
        cgCtx.move(to: CGPoint(x: last.0, y: last.1))
        cgCtx.addLine(to: CGPoint(x: first.0, y: first.1))
        cgCtx.strokePath()
        cgCtx.setLineDash(phase: 0, lengths: [])
    }
}

/// Blob Brush oval cursor + drag preview. BLOB_BRUSH_TOOL.md §Overlay.
///
/// Two responsibilities:
///   1. Hover cursor — oval outline at (x, y) using the effective tip
///      shape (size/angle/roundness). When `dashed` is truthy, the
///      stroke is dashed to signal erase mode.
///   2. Drag preview — when `mode != "idle"`, renders accumulated dabs
///      from `buffer` as semi-transparent filled ovals (painting) or
///      dashed outlines (erasing).
///
/// Fields (all optional unless noted):
///   x, y              current pointer position (required)
///   default_size      tip diameter in pt
///   default_angle     tip rotation in degrees
///   default_roundness tip aspect percent
///   stroke_color      outline color (defaults #000000)
///   dashed            boolean; erase-mode visual
///   buffer            point-buffer name (for drag preview)
///   mode              string tool mode (idle / painting / erasing)
private func drawOvalCursorOverlay(
    _ cgCtx: CGContext, _ spec: [String: Any], _ ctx: [String: Any]
) {
    let cx = evalOverlayNumber(spec["x"], ctx)
    let cy = evalOverlayNumber(spec["y"], ctx)
    let size = max(1.0, evalOverlayNumber(spec["default_size"], ctx))
    let angleDeg = evalOverlayNumber(spec["default_angle"], ctx)
    let roundness = max(1.0, evalOverlayNumber(spec["default_roundness"], ctx))
    let strokeColorStr: String = {
        if let s = spec["stroke_color"] as? String, !s.isEmpty {
            return s
        }
        return "#000000"
    }()
    let strokeColor = parseOverlayColor(strokeColorStr)
        ?? CGColor(red: 0, green: 0, blue: 0, alpha: 1)

    let dashed: Bool = {
        switch spec["dashed"] {
        case let b as Bool: return b
        case let s as String: return evaluate(s, context: ctx).toBool()
        default: return false
        }
    }()
    let mode: String = {
        switch spec["mode"] {
        case let s as String:
            if s.hasPrefix("'") || s.hasPrefix("\"") {
                return s.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
            if case .string(let rs) = evaluate(s, context: ctx) {
                return rs
            }
            return s
        default:
            return "idle"
        }
    }()

    let rx = size * 0.5
    let ry = size * (roundness / 100.0) * 0.5
    let rad = angleDeg * .pi / 180.0

    // Drag preview: if a buffer is named and mode != idle, draw each
    // buffered point as an oval. Painting = semi-transparent fill;
    // erasing = dashed outline.
    if mode != "idle",
       let bufferName = spec["buffer"] as? String {
        let pts = pointBuffersPoints(bufferName)
        if pts.count >= 2 {
            if mode == "painting" {
                cgCtx.saveGState()
                cgCtx.setAlpha(0.3)
                cgCtx.setFillColor(strokeColor)
                for p in pts {
                    addOvalPath(cgCtx,
                                cx: p.0, cy: p.1,
                                rx: rx, ry: ry, rad: rad)
                    cgCtx.fillPath()
                }
                cgCtx.restoreGState()
            } else if mode == "erasing" {
                cgCtx.setStrokeColor(strokeColor)
                cgCtx.setLineWidth(1.0)
                cgCtx.setLineDash(phase: 0, lengths: [3, 3])
                for p in pts {
                    addOvalPath(cgCtx,
                                cx: p.0, cy: p.1,
                                rx: rx, ry: ry, rad: rad)
                    cgCtx.strokePath()
                }
                cgCtx.setLineDash(phase: 0, lengths: [])
            }
        }
    }

    // Hover cursor outline at (cx, cy). Stroke dashed when Alt held.
    cgCtx.setStrokeColor(strokeColor)
    cgCtx.setLineWidth(1.0)
    if dashed {
        cgCtx.setLineDash(phase: 0, lengths: [4, 4])
    }
    addOvalPath(cgCtx, cx: cx, cy: cy, rx: rx, ry: ry, rad: rad)
    cgCtx.strokePath()
    if dashed {
        cgCtx.setLineDash(phase: 0, lengths: [])
    }
    // 1 px screen-space crosshair for precision aiming.
    cgCtx.move(to: CGPoint(x: cx - 3, y: cy))
    cgCtx.addLine(to: CGPoint(x: cx + 3, y: cy))
    cgCtx.move(to: CGPoint(x: cx, y: cy - 3))
    cgCtx.addLine(to: CGPoint(x: cx, y: cy + 3))
    cgCtx.strokePath()
}

/// Add a 24-segment rotated-ellipse path to `cgCtx`. Caller fills or
/// strokes the current path.
private func addOvalPath(
    _ cgCtx: CGContext,
    cx: Double, cy: Double, rx: Double, ry: Double, rad: Double
) {
    let segments = 24
    let cs = cos(rad), sn = sin(rad)
    for i in 0...segments {
        let t = 2.0 * .pi * Double(i) / Double(segments)
        let lx = rx * cos(t)
        let ly = ry * sin(t)
        let x = cx + lx * cs - ly * sn
        let y = cy + lx * sn + ly * cs
        if i == 0 {
            cgCtx.move(to: CGPoint(x: x, y: y))
        } else {
            cgCtx.addLine(to: CGPoint(x: x, y: y))
        }
    }
    cgCtx.closePath()
}

// MARK: - Transform-tool overlays

/// Resolve the reference-point coordinate for a transform-tool
/// overlay. Reads the `ref_point` field (typically the expression
/// `state.transform_reference_point`) — a Value.list of two
/// numbers when set, else falls back to the selection union bbox
/// center. Returns nil when there is no selection (overlay hides).
private func resolveOverlayRefPoint(
    _ render: [String: Any],
    _ evalCtx: [String: Any],
    model: Model
) -> (Double, Double)? {
    if let expr = render["ref_point"] as? String {
        let v = evaluate(expr, context: evalCtx)
        if case .list(let items) = v, items.count >= 2 {
            let rx = (items[0].value as? NSNumber)?.doubleValue ?? Double.nan
            let ry = (items[1].value as? NSNumber)?.doubleValue ?? Double.nan
            if !rx.isNaN && !ry.isNaN { return (rx, ry) }
        }
    }
    let doc = model.document
    let elements: [Element] = doc.selection.compactMap { es in
        isValidPath(doc, es.path) ? doc.getElement(es.path) : nil
    }
    if elements.isEmpty { return nil }
    let bb = alignUnionBounds(elements, alignGeometricBounds)
    return (bb.x + bb.width / 2, bb.y + bb.height / 2)
}

/// Draw the cyan-blue reference-point cross overlay used by Scale,
/// Rotate, Shear. 12 px crosshair + 2 px dot, color #4A9EFF. See
/// SCALE_TOOL.md §Reference-point cross overlay.
private func drawReferencePointCross(
    _ cgCtx: CGContext, _ render: [String: Any],
    _ evalCtx: [String: Any], model: Model
) {
    guard let (rx, ry) = resolveOverlayRefPoint(render, evalCtx, model: model)
    else { return }
    let color = CGColor(red: 0x4A / 255.0, green: 0x9E / 255.0,
                        blue: 0xFF / 255.0, alpha: 1)
    cgCtx.setStrokeColor(color)
    cgCtx.setLineWidth(1.0)
    let arm: CGFloat = 6.0
    cgCtx.beginPath()
    cgCtx.move(to: CGPoint(x: rx - arm, y: ry))
    cgCtx.addLine(to: CGPoint(x: rx + arm, y: ry))
    cgCtx.strokePath()
    cgCtx.beginPath()
    cgCtx.move(to: CGPoint(x: rx, y: ry - arm))
    cgCtx.addLine(to: CGPoint(x: rx, y: ry + arm))
    cgCtx.strokePath()
    cgCtx.setFillColor(color)
    cgCtx.beginPath()
    cgCtx.addArc(center: CGPoint(x: rx, y: ry), radius: 2,
                 startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    cgCtx.fillPath()
}

/// Draw the dashed post-transform bounding-box ghost during a drag.
/// Reads transform_kind ("scale" / "rotate" / "shear"), press +
/// cursor + shift_held, composes the matrix via TransformApply and
/// renders the union bbox of the selection under that matrix.
private func drawBBoxGhost(
    _ cgCtx: CGContext, _ render: [String: Any],
    _ evalCtx: [String: Any], model: Model
) {
    guard let (rx, ry) = resolveOverlayRefPoint(render, evalCtx, model: model)
    else { return }
    let kindExpr = (render["transform_kind"] as? String) ?? "''"
    let kind: String = {
        if case .string(let s) = evaluate(kindExpr, context: evalCtx) { return s }
        return ""
    }()
    let px = evalOverlayNumber(render["press_x"], evalCtx)
    let py = evalOverlayNumber(render["press_y"], evalCtx)
    let cx = evalOverlayNumber(render["cursor_x"], evalCtx)
    let cy = evalOverlayNumber(render["cursor_y"], evalCtx)
    let shift: Bool = {
        if let s = render["shift_held"] as? String,
           case .bool(let b) = evaluate(s, context: evalCtx) { return b }
        return false
    }()

    let matrix: Transform = {
        switch kind {
        case "scale":
            let denomX = px - rx
            let denomY = py - ry
            var sx = abs(denomX) < 1e-9 ? 1.0 : (cx - rx) / denomX
            var sy = abs(denomY) < 1e-9 ? 1.0 : (cy - ry) / denomY
            if shift {
                let prod = sx * sy
                let sign: Double = prod >= 0 ? 1.0 : -1.0
                let s = sign * sqrt(abs(prod))
                sx = s; sy = s
            }
            return TransformApply.scaleMatrix(sx: sx, sy: sy, rx: rx, ry: ry)
        case "rotate":
            let tp = atan2(py - ry, px - rx)
            let tc = atan2(cy - ry, cx - rx)
            var theta = (tc - tp) * 180.0 / .pi
            if shift { theta = (theta / 45.0).rounded() * 45.0 }
            return TransformApply.rotateMatrix(thetaDeg: theta, rx: rx, ry: ry)
        case "shear":
            let dx = cx - px
            let dy = cy - py
            if shift {
                if abs(dx) >= abs(dy) {
                    let denom = max(abs(py - ry), 1e-9)
                    let k = dx / denom
                    return TransformApply.shearMatrix(
                        angleDeg: atan(k) * 180.0 / .pi,
                        axis: "horizontal", axisAngleDeg: 0, rx: rx, ry: ry)
                } else {
                    let denom = max(abs(px - rx), 1e-9)
                    let k = dy / denom
                    return TransformApply.shearMatrix(
                        angleDeg: atan(k) * 180.0 / .pi,
                        axis: "vertical", axisAngleDeg: 0, rx: rx, ry: ry)
                }
            }
            let ax = px - rx
            let ay = py - ry
            let axisLen = max(sqrt(ax * ax + ay * ay), 1e-9)
            let perpX = -ay / axisLen
            let perpY = ax / axisLen
            let perpDist = (cx - px) * perpX + (cy - py) * perpY
            let k = perpDist / axisLen
            let axisAngleDeg = atan2(ay, ax) * 180.0 / .pi
            return TransformApply.shearMatrix(
                angleDeg: atan(k) * 180.0 / .pi,
                axis: "custom", axisAngleDeg: axisAngleDeg,
                rx: rx, ry: ry)
        default:
            return Transform.identity
        }
    }()

    let doc = model.document
    let elements: [Element] = doc.selection.compactMap { es in
        isValidPath(doc, es.path) ? doc.getElement(es.path) : nil
    }
    if elements.isEmpty { return }
    let bb = alignUnionBounds(elements, alignGeometricBounds)
    let corners = [
        matrix.applyPoint(bb.x,             bb.y),
        matrix.applyPoint(bb.x + bb.width,  bb.y),
        matrix.applyPoint(bb.x + bb.width,  bb.y + bb.height),
        matrix.applyPoint(bb.x,             bb.y + bb.height),
    ]
    cgCtx.setStrokeColor(CGColor(red: 0x4A / 255.0, green: 0x9E / 255.0,
                                  blue: 0xFF / 255.0, alpha: 1))
    cgCtx.setLineWidth(1.0)
    cgCtx.setLineDash(phase: 0, lengths: [4, 2])
    cgCtx.beginPath()
    cgCtx.move(to: CGPoint(x: corners[0].0, y: corners[0].1))
    for c in corners.dropFirst() {
        cgCtx.addLine(to: CGPoint(x: c.0, y: c.1))
    }
    cgCtx.closePath()
    cgCtx.strokePath()
    cgCtx.setLineDash(phase: 0, lengths: []) // reset
}
