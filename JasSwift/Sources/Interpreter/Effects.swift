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
    dialogs: [String: Any]? = nil
) {
    for effect in effects {
        runOne(effect, ctx: ctx, store: store, actions: actions, dialogs: dialogs)
    }
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
    dialogs: [String: Any]?
) {
    // set: { key: expr, ... }
    if let pairs = effect["set"] as? [String: Any] {
        for (key, expr) in pairs {
            let value = evalExpr(expr, store: store, ctx: ctx)
            store.set(key, valueToAny(value))
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
                runEffects(thenEffects, ctx: ctx, store: store, actions: actions, dialogs: dialogs)
            }
        } else if let elseEffects = cond["else"] as? [[String: Any]] {
            runEffects(elseEffects, ctx: ctx, store: store, actions: actions, dialogs: dialogs)
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
            runEffects(actionEffects, ctx: dispatchCtx, store: store, actions: actions, dialogs: dialogs)
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

    // log: message (no-op)
    if effect.keys.contains("log") {
        return
    }
}
