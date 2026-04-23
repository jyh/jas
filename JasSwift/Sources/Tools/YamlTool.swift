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
        // Phase 5a: overlay rendering is stubbed. OverlaySpec is
        // parsed and the guard expression can be evaluated, but the
        // actual rect / line / pen / partial-selection renderers
        // land in Phase 5b (they mirror the Rust draw_*_overlay
        // functions in yaml_tool.rs).
        _ = cgCtx
        _ = ctx
    }
}
