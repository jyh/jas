/// Effects interpreter for the workspace YAML schema.
///
/// Executes effect lists from actions and behaviors. Each effect is a
/// dict with a single key identifying the effect type. Pure Swift,
/// no SwiftUI dependency. Port of workspace_interpreter/effects.py.

import Foundation

/// Execute a list of effects.
///
/// - Parameters:
///   - effects: Array of effect dicts.
///   - ctx: Additional evaluation context (params, event, etc.).
///   - store: The state store to read from and mutate.
///   - actions: The actions catalog for dispatch effects.
///   - dialogs: Dialog definitions dict for open_dialog effects.
func runEffects(
    _ effects: [[String: Any]],
    ctx: [String: Any],
    store: StateStore,
    actions: [String: Any]? = nil,
    dialogs: [String: Any]? = nil,
    schema: Bool = false,
    diagnostics: inout [Diagnostic]
) {
    for effect in effects {
        runOne(effect, ctx: ctx, store: store, actions: actions, dialogs: dialogs,
               schema: schema, diagnostics: &diagnostics)
    }
}

/// Convenience overload for callers that don't need diagnostics.
func runEffects(
    _ effects: [[String: Any]],
    ctx: [String: Any],
    store: StateStore,
    actions: [String: Any]? = nil,
    dialogs: [String: Any]? = nil
) {
    var diags: [Diagnostic] = []
    runEffects(effects, ctx: ctx, store: store, actions: actions, dialogs: dialogs,
               schema: false, diagnostics: &diags)
}

// MARK: - Internal

private func evalExpr(_ expr: Any?, store: StateStore, ctx: [String: Any]) -> Value {
    let exprStr: String
    if let s = expr as? String {
        exprStr = s
    } else if let n = expr as? NSNumber {
        exprStr = n.stringValue
    } else {
        exprStr = ""
    }
    let evalCtx = store.evalContext(extra: ctx)
    return evaluate(exprStr, context: evalCtx)
}

private func valueToAny(_ v: Value) -> Any? {
    switch v {
    case .null: return nil
    case .bool(let b): return b
    case .number(let n):
        if n == Double(Int(n)) { return Int(n) }
        return n
    case .string(let s): return s
    case .color(let c): return c
    case .list(let l): return l.map { $0.value }
    case .path(let p): return ["__path__": p]
    case .closure: return v  // keep as Value for closure dispatch
    }
}

/// Extract default values from a dialog state definition dict.
private func stateDefaults(_ stateDefs: [String: Any]) -> [String: Any] {
    var defaults: [String: Any] = [:]
    for (key, defn) in stateDefs {
        if let d = defn as? [String: Any] {
            defaults[key] = d["default"]
        } else {
            defaults[key] = defn
        }
    }
    return defaults
}

private func runOne(
    _ effect: [String: Any],
    ctx: [String: Any],
    store: StateStore,
    actions: [String: Any]?,
    dialogs: [String: Any]?,
    schema: Bool = false,
    diagnostics: inout [Diagnostic]
) {
    // set: { key: expr, ... }
    if let pairs = effect["set"] as? [String: Any] {
        if schema {
            // Schema-driven: evaluate expressions first, then coerce+validate
            var evaluated: [String: Any] = [:]
            for (key, expr) in pairs {
                let val = evalExpr(expr, store: store, ctx: ctx)
                evaluated[key] = valueToAny(val)
            }
            applySetSchemadriven(evaluated, store: store, diagnostics: &diagnostics)
        } else {
            for (key, expr) in pairs {
                let value = evalExpr(expr, store: store, ctx: ctx)
                store.set(key, valueToAny(value))
            }
        }
        return
    }

    // pop: panel.field_name  or  pop: global_field_name
    if let target = effect["pop"] as? String {
        let parts = target.split(separator: ".", maxSplits: 1).map(String.init)
        if parts.count == 2 && parts[0] == "panel" {
            if let panelId = store.getActivePanelId() {
                if var lst = store.getPanel(panelId, parts[1]) as? [Any], !lst.isEmpty {
                    lst.removeLast()
                    store.setPanel(panelId, parts[1], lst)
                }
            }
        } else {
            if var lst = store.get(target) as? [Any], !lst.isEmpty {
                lst.removeLast()
                store.set(target, lst)
            }
        }
        return
    }

    // toggle: state_key
    if let key = effect["toggle"] as? String {
        let current = store.get(key) as? Bool ?? false
        store.set(key, !current)
        return
    }

    // swap: [key_a, key_b]
    if let keys = effect["swap"] as? [String], keys.count == 2 {
        let a = store.get(keys[0])
        let b = store.get(keys[1])
        store.set(keys[0], b)
        store.set(keys[1], a)
        return
    }

    // increment: { key, by }
    if let inc = effect["increment"] as? [String: Any] {
        let key = inc["key"] as? String ?? ""
        let by = (inc["by"] as? NSNumber)?.doubleValue ?? 1.0
        let current = (store.get(key) as? NSNumber)?.doubleValue ?? 0.0
        store.set(key, current + by)
        return
    }

    // decrement: { key, by }
    if let dec = effect["decrement"] as? [String: Any] {
        let key = dec["key"] as? String ?? ""
        let by = (dec["by"] as? NSNumber)?.doubleValue ?? 1.0
        let current = (store.get(key) as? NSNumber)?.doubleValue ?? 0.0
        store.set(key, current - by)
        return
    }

    // if: { condition, then, else }
    if let cond = effect["if"] as? [String: Any] {
        let condExpr = cond["condition"] as? String ?? "false"
        let evalCtx = store.evalContext(extra: ctx)
        let result = evaluate(condExpr, context: evalCtx)
        if result.toBool() {
            if let thenEffects = cond["then"] as? [[String: Any]] {
                runEffects(thenEffects, ctx: ctx, store: store, actions: actions, dialogs: dialogs,
                           schema: schema, diagnostics: &diagnostics)
            }
        } else if let elseEffects = cond["else"] as? [[String: Any]] {
            runEffects(elseEffects, ctx: ctx, store: store, actions: actions, dialogs: dialogs,
                       schema: schema, diagnostics: &diagnostics)
        }
        return
    }

    // set_panel_state: { key, value, panel? }
    if let sps = effect["set_panel_state"] as? [String: Any] {
        let key = sps["key"] as? String ?? ""
        let value = evalExpr(sps["value"], store: store, ctx: ctx)
        if let panelId = sps["panel"] as? String {
            store.setPanel(panelId, key, valueToAny(value))
        } else if let activeId = store.getActivePanelId() {
            store.setPanel(activeId, key, valueToAny(value))
        }
        return
    }

    // dispatch: action_name or { action, params }
    if let dispatch = effect["dispatch"] {
        let actionName: String
        var params: [String: Any] = [:]
        if let s = dispatch as? String {
            actionName = s
        } else if let d = dispatch as? [String: Any] {
            actionName = d["action"] as? String ?? ""
            params = d["params"] as? [String: Any] ?? [:]
        } else {
            return
        }
        if let actionsDef = actions, let actionDef = actionsDef[actionName] as? [String: Any] {
            let actionEffects = actionDef["effects"] as? [[String: Any]] ?? []
            var dispatchCtx = ctx
            if !params.isEmpty {
                var resolved: [String: Any] = [:]
                for (k, v) in params {
                    let val = evalExpr(v, store: store, ctx: ctx)
                    resolved[k] = valueToAny(val)
                }
                dispatchCtx["param"] = resolved
            }
            runEffects(actionEffects, ctx: dispatchCtx, store: store, actions: actions, dialogs: dialogs,
                       schema: schema, diagnostics: &diagnostics)
        }
        return
    }

    // open_dialog: { id, params }
    if let od = effect["open_dialog"] {
        let dlgId: String
        var rawParams: [String: Any] = [:]
        if let odDict = od as? [String: Any] {
            dlgId = odDict["id"] as? String ?? ""
            rawParams = odDict["params"] as? [String: Any] ?? [:]
        } else if let s = od as? String {
            dlgId = s
        } else {
            return
        }
        guard let dialogsDef = dialogs, let dlgDef = dialogsDef[dlgId] as? [String: Any] else { return }

        // Extract state defaults
        let stateDefs = dlgDef["state"] as? [String: Any] ?? [:]
        let defaults = stateDefaults(stateDefs)

        // Resolve params
        var resolvedParams: [String: Any] = [:]
        for (k, v) in rawParams {
            let val = evalExpr(v, store: store, ctx: ctx)
            resolvedParams[k] = valueToAny(val)
        }

        // Init dialog
        store.initDialog(dlgId, defaults: defaults, params: resolvedParams.isEmpty ? nil : resolvedParams)

        // Evaluate init expressions.
        // Two passes: Swift Dictionary doesn't preserve insertion order,
        // but later inits may reference dialog.* values set by earlier ones
        // (e.g. h: "hsb_h(dialog.color)" depends on color being set first).
        // Pass 1: expressions not referencing dialog.*
        // Pass 2: expressions referencing dialog.*
        if let initMap = dlgDef["init"] as? [String: Any] {
            var deferred: [(String, Any)] = []
            for (key, expr) in initMap {
                let exprStr = expr as? String ?? ""
                if exprStr.contains("dialog.") {
                    deferred.append((key, expr))
                } else {
                    let value = evalExpr(expr, store: store, ctx: ctx)
                    store.setDialog(key, valueToAny(value))
                }
            }
            for (key, expr) in deferred {
                let value = evalExpr(expr, store: store, ctx: ctx)
                store.setDialog(key, valueToAny(value))
            }
        }
        return
    }

    // close_dialog: null or dialog_id
    if effect.keys.contains("close_dialog") {
        store.closeDialog()
        return
    }

    // start_timer: { id, delay_ms, effects }
    if let st = effect["start_timer"] as? [String: Any] {
        let timerId = st["id"] as? String ?? ""
        let delayMs = (st["delay_ms"] as? NSNumber)?.intValue ?? 250
        let nestedEffects = st["effects"] as? [[String: Any]] ?? []
        TimerManager.shared.startTimer(id: timerId, delayMs: delayMs) {
            var timerDiags: [Diagnostic] = []
            runEffects(nestedEffects, ctx: ctx, store: store, actions: actions, dialogs: dialogs,
                       schema: schema, diagnostics: &timerDiags)
        }
        return
    }

    // cancel_timer: id
    if let ct = effect["cancel_timer"] {
        let timerId = ct as? String ?? ""
        TimerManager.shared.cancelTimer(id: timerId)
        return
    }

    // log: message (no-op)
    if effect.keys.contains("log") {
        return
    }
}

// MARK: - Stroke panel state binding

/// Rendering-affecting stroke state keys.
private let strokeRenderKeys: Set<String> = [
    "stroke_cap", "stroke_join", "stroke_weight", "stroke_miter_limit",
    "stroke_dashed", "stroke_dash_1", "stroke_gap_1",
    "stroke_dash_2", "stroke_gap_2", "stroke_dash_3", "stroke_gap_3",
    "stroke_align_stroke", "stroke_start_arrowhead", "stroke_end_arrowhead",
    "stroke_start_arrowhead_scale", "stroke_end_arrowhead_scale",
    "stroke_arrow_align", "stroke_profile", "stroke_profile_flipped",
]

/// Build a Stroke from the state store's stroke_* keys and apply to selection.
func applyStrokePanelToSelection(store: StateStore, controller: Controller) {
    let s = store.getAll()
    let cap: LineCap
    switch s["stroke_cap"] as? String {
    case "round": cap = .round
    case "square": cap = .square
    default: cap = .butt
    }
    let join: LineJoin
    switch s["stroke_join"] as? String {
    case "round": join = .round
    case "bevel": join = .bevel
    default: join = .miter
    }
    let miterLimit = (s["stroke_miter_limit"] as? NSNumber)?.doubleValue ?? 10.0
    let align: StrokeAlign
    switch s["stroke_align_stroke"] as? String {
    case "inside": align = .inside
    case "outside": align = .outside
    default: align = .center
    }
    let dashed = s["stroke_dashed"] as? Bool ?? false
    var dashPattern: [Double] = []
    if dashed {
        let d1 = (s["stroke_dash_1"] as? NSNumber)?.doubleValue ?? 12.0
        let g1 = (s["stroke_gap_1"] as? NSNumber)?.doubleValue ?? 12.0
        dashPattern = [d1, g1]
        if let d2 = s["stroke_dash_2"] as? NSNumber, let g2 = s["stroke_gap_2"] as? NSNumber {
            dashPattern.append(contentsOf: [d2.doubleValue, g2.doubleValue])
        }
        if let d3 = s["stroke_dash_3"] as? NSNumber, let g3 = s["stroke_gap_3"] as? NSNumber {
            dashPattern.append(contentsOf: [d3.doubleValue, g3.doubleValue])
        }
    }
    let startArrow = Arrowhead(fromString: s["stroke_start_arrowhead"] as? String ?? "none")
    let endArrow = Arrowhead(fromString: s["stroke_end_arrowhead"] as? String ?? "none")
    let startArrowScale = (s["stroke_start_arrowhead_scale"] as? NSNumber)?.doubleValue ?? 100.0
    let endArrowScale = (s["stroke_end_arrowhead_scale"] as? NSNumber)?.doubleValue ?? 100.0
    let arrowAlign: ArrowAlign
    switch s["stroke_arrow_align"] as? String {
    case "center_at_end": arrowAlign = .centerAtEnd
    default: arrowAlign = .tipAtEnd
    }

    // Get base stroke from selection or default
    let doc = controller.model.document
    let baseStroke: Stroke?
    if let first = doc.selection.first {
        baseStroke = doc.getElement(first.path).stroke
    } else {
        baseStroke = controller.model.defaultStroke
    }
    guard let base = baseStroke ?? controller.model.defaultStroke else { return }

    let width = controller.model.defaultStroke?.width ?? base.width
    let newStroke = Stroke(color: base.color, width: width, linecap: cap, linejoin: join,
                           miterLimit: miterLimit, align: align, dashPattern: dashPattern,
                           startArrow: startArrow, endArrow: endArrow,
                           startArrowScale: startArrowScale, endArrowScale: endArrowScale,
                           arrowAlign: arrowAlign, opacity: base.opacity)

    controller.model.defaultStroke = newStroke
    if !doc.selection.isEmpty {
        controller.model.snapshot()
        controller.setSelectionStroke(newStroke)
        let profile = s["stroke_profile"] as? String ?? "uniform"
        let flipped = s["stroke_profile_flipped"] as? Bool ?? false
        let widthPts = profileToWidthPoints(profile: profile, width: width, flipped: flipped)
        controller.setSelectionWidthProfile(widthPts)
    }
}

/// Sync stroke panel state from the first selected element's stroke.
func syncStrokePanelFromSelection(store: StateStore, controller: Controller) {
    let doc = controller.model.document
    guard let first = doc.selection.first else { return }
    guard let s = doc.getElement(first.path).stroke else { return }

    store.set("stroke_cap", s.linecap == .butt ? "butt" : s.linecap == .round ? "round" : "square")
    store.set("stroke_join", s.linejoin == .miter ? "miter" : s.linejoin == .round ? "round" : "bevel")
    store.set("stroke_weight", s.width)
    store.set("stroke_miter_limit", s.miterLimit)
    let alignStr: String
    switch s.align { case .center: alignStr = "center"; case .inside: alignStr = "inside"; case .outside: alignStr = "outside" }
    store.set("stroke_align_stroke", alignStr)
    store.set("stroke_dashed", !s.dashPattern.isEmpty)
    if s.dashPattern.count >= 2 {
        store.set("stroke_dash_1", s.dashPattern[0])
        store.set("stroke_gap_1", s.dashPattern[1])
    }
    if s.dashPattern.count >= 4 {
        store.set("stroke_dash_2", s.dashPattern[2])
        store.set("stroke_gap_2", s.dashPattern[3])
    }
    if s.dashPattern.count >= 6 {
        store.set("stroke_dash_3", s.dashPattern[4])
        store.set("stroke_gap_3", s.dashPattern[5])
    }
    store.set("stroke_start_arrowhead", s.startArrow.name)
    store.set("stroke_end_arrowhead", s.endArrow.name)
    store.set("stroke_start_arrowhead_scale", s.startArrowScale)
    store.set("stroke_end_arrowhead_scale", s.endArrowScale)
    store.set("stroke_arrow_align", s.arrowAlign == .tipAtEnd ? "tip_at_end" : "center_at_end")
}

/// Check if a state key is a rendering-affecting stroke key.
func isStrokeRenderKey(_ key: String) -> Bool {
    strokeRenderKeys.contains(key)
}
