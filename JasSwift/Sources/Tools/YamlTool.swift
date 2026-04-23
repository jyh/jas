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
    /// Optional overlay declaration.
    let overlay: OverlaySpec?

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

private func parseOverlay(_ val: Any?) -> OverlaySpec? {
    guard let obj = val as? [String: Any] else { return nil }
    guard let render = obj["render"] as? [String: Any] else { return nil }
    return OverlaySpec(guardExpr: obj["if"] as? String, render: render)
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
        guard let overlay = spec.overlay else { return }
        let _reg = registerDocument(ctx.model.document)
        let evalCtx = store.evalContext()
        // Guard evaluates in the same scope the handler used.
        if let guardExpr = overlay.guardExpr {
            if !evaluate(guardExpr, context: evalCtx).toBool() { return }
        }
        let render = overlay.render
        let type = render["type"] as? String ?? ""
        switch type {
        case "rect": drawRectOverlay(cgCtx, render, evalCtx)
        case "line": drawLineOverlay(cgCtx, render, evalCtx)
        case "polygon": drawPolygonOverlay(cgCtx, render, evalCtx)
        case "star": drawStarOverlay(cgCtx, render, evalCtx)
        default: break
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
