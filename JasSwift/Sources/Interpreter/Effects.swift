/// Effects interpreter for the workspace YAML schema.
///
/// Executes effect lists from actions and behaviors. Each effect is a
/// dict with a single key identifying the effect type. Pure Swift,
/// no SwiftUI dependency. Port of workspace_interpreter/effects.py.

import Foundation

/// Platform-specific effect handler (Phase 3). Key is effect name
/// (e.g. "snapshot"). Called with (effect_value, ctx, store). Registered
/// by the calling app — e.g. LayersPanel wires snapshot/doc.set to the
/// active Model. Return value (if non-nil) is bound to the effect's
/// optional `as: <name>` field for subsequent effects in the same list.
typealias PlatformEffect = (Any, [String: Any], StateStore) -> Any?

/// Execute a list of effects.
///
/// - Parameters:
///   - effects: Array of effect dicts.
///   - ctx: Additional evaluation context (params, event, etc.).
///   - store: The state store to read from and mutate.
///   - actions: The actions catalog for dispatch effects.
///   - dialogs: Dialog definitions dict for open_dialog effects.
///   - platformEffects: Map of effect name to handler for app-specific
///     primitives (snapshot, doc.set, etc.) that operate on the Model.
func runEffects(
    _ effects: [Any],
    ctx: [String: Any],
    store: StateStore,
    actions: [String: Any]? = nil,
    dialogs: [String: Any]? = nil,
    platformEffects: [String: PlatformEffect] = [:],
    schema: Bool = false,
    diagnostics: inout [Diagnostic]
) {
    // Thread ctx through sibling effects: `let:` extends ctx for
    // subsequent siblings; nested lists (then/else/do) recurse with
    // their own ctx so bindings don't leak back.
    var threadedCtx = ctx
    for effectAny in effects {
        // Bare-string effects (e.g. `- snapshot`) normalize to {name: nil}
        if let effectStr = effectAny as? String {
            if let handler = platformEffects[effectStr] {
                handler(NSNull(), threadedCtx, store)
            }
            continue
        }
        guard let effect = effectAny as? [String: Any] else { continue }
        // let: { name: expr, ... } — PHASE3 §5.1
        if let bindings = effect["let"] as? [String: Any] {
            for (name, exprV) in bindings {
                let val = evalExpr(exprV, store: store, ctx: threadedCtx)
                if case .closure = val {
                    threadedCtx[name] = val
                } else {
                    threadedCtx[name] = valueToAny(val)
                }
            }
            continue
        }
        // foreach: { source, as } do: [...] — PHASE3 §5.3
        if let spec = effect["foreach"] as? [String: Any] {
            let sourceExpr = spec["source"] ?? ""
            let varName = (spec["as"] as? String) ?? "item"
            let body = (effect["do"] as? [Any]) ?? []
            let itemsVal = evalExpr(sourceExpr, store: store, ctx: threadedCtx)
            guard case .list(let items) = itemsVal else { continue }
            for (i, item) in items.enumerated() {
                var iterCtx = threadedCtx
                iterCtx[varName] = item.value
                iterCtx["_index"] = i
                runEffects(body, ctx: iterCtx, store: store,
                           actions: actions, dialogs: dialogs,
                           platformEffects: platformEffects,
                           schema: schema, diagnostics: &diagnostics)
            }
            continue
        }
        // Platform-specific effects (snapshot, doc.set, etc.)
        // `as: <name>` binds the handler's return value in threadedCtx.
        let asName = effect["as"] as? String
        var handled = false
        for (key, value) in effect {
            if key == "as" { continue }
            if let handler = platformEffects[key] {
                let returned = handler(value, threadedCtx, store)
                if let name = asName, let r = returned {
                    threadedCtx[name] = r
                }
                handled = true
                break
            }
        }
        if handled { continue }
        runOne(effect, ctx: threadedCtx, store: store, actions: actions,
               dialogs: dialogs, platformEffects: platformEffects,
               schema: schema, diagnostics: &diagnostics)
    }
}

/// Convenience overload for callers that don't need diagnostics.
func runEffects(
    _ effects: [Any],
    ctx: [String: Any],
    store: StateStore,
    actions: [String: Any]? = nil,
    dialogs: [String: Any]? = nil,
    platformEffects: [String: PlatformEffect] = [:]
) {
    var diags: [Diagnostic] = []
    runEffects(effects, ctx: ctx, store: store, actions: actions, dialogs: dialogs,
               platformEffects: platformEffects, schema: false, diagnostics: &diags)
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
    platformEffects: [String: PlatformEffect] = [:],
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
        // Fire the panel-write hook if any `panel.X` key was touched.
        // The schema-driven writer resolves `panel.X` against the
        // active panel; non-schema writes don't touch panel scope.
        // Silent no-op when the host hasn't registered the effect.
        let wrotePanel = pairs.keys.contains { $0.hasPrefix("panel.") }
        if wrotePanel,
           let panelId = store.getActivePanelId(),
           let hook = platformEffects["notify_panel_state_changed"] {
            _ = hook(panelId, ctx, store)
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
            if let thenEffects = cond["then"] as? [Any] {
                runEffects(thenEffects, ctx: ctx, store: store, actions: actions, dialogs: dialogs,
                           platformEffects: platformEffects,
                           schema: schema, diagnostics: &diagnostics)
            }
        } else if let elseEffects = cond["else"] as? [Any] {
            runEffects(elseEffects, ctx: ctx, store: store, actions: actions, dialogs: dialogs,
                       platformEffects: platformEffects,
                       schema: schema, diagnostics: &diagnostics)
        }
        return
    }

    // set_panel_state: { key, value, panel? }
    if let sps = effect["set_panel_state"] as? [String: Any] {
        let key = sps["key"] as? String ?? ""
        let value = evalExpr(sps["value"], store: store, ctx: ctx)
        let writtenPanel: String?
        if let panelId = sps["panel"] as? String {
            store.setPanel(panelId, key, valueToAny(value))
            writtenPanel = panelId
        } else if let activeId = store.getActivePanelId() {
            store.setPanel(activeId, key, valueToAny(value))
            writtenPanel = activeId
        } else {
            writtenPanel = nil
        }
        // Fire the panel-write hook so the host can re-sync any
        // derived state (e.g. Character / Stroke panels pushing their
        // attributes onto the selected element). Silent no-op if
        // the host hasn't registered the effect.
        if let name = writtenPanel, let hook = platformEffects["notify_panel_state_changed"] {
            _ = hook(name, ctx, store)
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
                       platformEffects: platformEffects,
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
        // Capture preview snapshot if the dialog declares preview_targets.
        // Restored on close_dialog unless first cleared by an OK action via
        // clear_dialog_snapshot.
        if let targetsObj = dlgDef["preview_targets"] as? [String: Any] {
            var targets: [String: String] = [:]
            for (k, v) in targetsObj {
                if let s = v as? String { targets[k] = s }
            }
            store.captureDialogSnapshot(targets)
        }
        return
    }

    // close_dialog: null or dialog_id
    if effect.keys.contains("close_dialog") {
        // Preview restore: if a snapshot survived (i.e., no OK action
        // cleared it), revert each target to its captured original value.
        // Phase 0 handles only top-level state keys.
        if let snapshot = store.getDialogSnapshot() {
            for (key, value) in snapshot {
                if !key.contains(".") {
                    store.set(key, value)
                }
            }
            store.clearDialogSnapshot()
        }
        store.closeDialog()
        return
    }

    // clear_dialog_snapshot: drop the preview snapshot so close_dialog
    // does not restore. OK actions emit this before close_dialog to commit.
    if effect.keys.contains("clear_dialog_snapshot") {
        store.clearDialogSnapshot()
        return
    }

    // start_timer: { id, delay_ms, effects }
    if let st = effect["start_timer"] as? [String: Any] {
        let timerId = st["id"] as? String ?? ""
        let delayMs = (st["delay_ms"] as? NSNumber)?.intValue ?? 250
        let nestedEffects = st["effects"] as? [Any] ?? []
        TimerManager.shared.startTimer(id: timerId, delayMs: delayMs) {
            var timerDiags: [Diagnostic] = []
            runEffects(nestedEffects, ctx: ctx, store: store, actions: actions, dialogs: dialogs,
                       platformEffects: platformEffects,
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

// MARK: - Character panel state binding

/// Character-panel state keys stored under the `character_panel`
/// scope in the StateStore. Used by
/// `applyCharacterPanelToSelection` to build the attribute dict
/// that gets pushed onto selected Text / TextPath elements.
private let characterPanelKeys: Set<String> = [
    "font_family", "style_name", "font_size", "leading", "kerning",
    "tracking", "vertical_scale", "horizontal_scale",
    "baseline_shift", "character_rotation",
    "all_caps", "small_caps", "superscript", "subscript",
    "underline", "strikethrough",
    "language", "anti_aliasing",
]

/// Build the Text-attribute dict from the current Character-panel
/// state and apply it to every selected Text / TextPath. Mirrors the
/// Rust `apply_character_panel_to_selection` pipeline — for an
/// object-level selection (whole element), writes the panel's current
/// attributes directly to the parent element's fields.
///
/// Field mapping follows CHARACTER.md's SVG-attribute table:
/// - underline + strikethrough combine into `text_decoration`
///   (`"line-through underline"`, alphabetical).
/// - all_caps → `text_transform: uppercase`; small_caps
///   (when All Caps is off) → `font_variant: small-caps`.
/// - superscript / subscript → `baseline_shift: super/sub`; the
///   super/sub toggles take precedence over the numeric pt value.
/// - style_name parses into font_weight + font_style
///   (Regular / Italic / Bold / Bold Italic).
/// - Leading → line_height (`Npt`, empty at the 120% Auto default),
///   Tracking → letter_spacing (`Nem` from N/1000).
///
/// Called after any write to a character-panel key so the two
/// surfaces (in-panel controls and the selected element) stay in
/// sync.
/// Build a `Tspan` override template from the Character panel state
/// that forces every panel-scoped field onto the targeted tspans
/// regardless of the element-level defaults. Used by the per-range
/// Character-panel write path. Scope matches
/// `buildPanelPendingTemplate`: font-family, font-size, font-weight,
/// font-style, text-decoration, text-transform, font-variant,
/// xml-lang, rotate.
///
/// Unlike the pending template, this builder does NOT diff against
/// element values — clicking Regular with a bold range should clear
/// the bold explicitly, which requires emitting `"normal"`, not
/// "nothing changed".
func buildPanelFullOverrides(_ panel: [String: Any]) -> Tspan {
    let fontFamily = (panel["font_family"] as? String) ?? "sans-serif"
    let fontSize = (panel["font_size"] as? NSNumber)?.doubleValue ?? 12.0
    var fw: String? = nil
    var fst: String? = nil
    if let style = panel["style_name"] as? String {
        switch style.trimmingCharacters(in: .whitespaces) {
        case "Regular":       fw = "normal"; fst = "normal"
        case "Italic":        fw = "normal"; fst = "italic"
        case "Bold":          fw = "bold";   fst = "normal"
        case "Bold Italic", "Italic Bold": fw = "bold"; fst = "italic"
        default: break
        }
    }
    let underline = panel["underline"] as? Bool ?? false
    let strikethrough = panel["strikethrough"] as? Bool ?? false
    let td: [String] = [
        strikethrough ? "line-through" : nil,
        underline ? "underline" : nil,
    ].compactMap { $0 }
    let allCaps = panel["all_caps"] as? Bool ?? false
    let smallCaps = panel["small_caps"] as? Bool ?? false
    let tt = allCaps ? "uppercase" : ""
    let fv = (smallCaps && !allCaps) ? "small-caps" : ""
    let lang = panel["language"] as? String ?? ""
    let rot = (panel["character_rotation"] as? NSNumber)?.doubleValue ?? 0.0
    // Leading → line_height (pt). Always emitted; identity-omission TBD.
    let leading = (panel["leading"] as? NSNumber)?.doubleValue ?? (fontSize * 1.2)
    // Tracking → letter_spacing (em). Panel unit is 1/1000 em.
    let tracking = (panel["tracking"] as? NSNumber)?.doubleValue ?? 0.0
    let letterSpacing = tracking / 1000.0
    // Baseline shift numeric (pt), skipped when super / sub is on.
    let superOn = panel["superscript"] as? Bool ?? false
    let subOn = panel["subscript"] as? Bool ?? false
    let bsNum = (panel["baseline_shift"] as? NSNumber)?.doubleValue ?? 0.0
    let baselineShift: Double? = (superOn || subOn) ? nil : bsNum
    // Anti-aliasing → jas_aa_mode. "Sharp" / empty are the defaults.
    let aaRaw = (panel["anti_aliasing"] as? String) ?? "Sharp"
    let aaMode = (aaRaw == "Sharp" || aaRaw.isEmpty) ? "" : aaRaw
    return Tspan(
        id: 0, content: "",
        baselineShift: baselineShift,
        fontFamily: fontFamily, fontSize: fontSize,
        fontStyle: fst, fontVariant: fv,
        fontWeight: fw,
        jasAaMode: aaMode,
        letterSpacing: letterSpacing,
        lineHeight: leading,
        rotate: rot,
        textDecoration: td,
        textTransform: tt,
        xmlLang: lang)
}

/// Drop any tspan override field that matches the parent element's
/// effective value (TSPAN.md "Character attribute writes (from
/// panels)" step 3). After this pass, the tspan only retains
/// overrides whose stored value differs from what the element would
/// render on its own; mergeTspans can then collapse same-override
/// neighbours more aggressively.
func identityOmitTspan(_ t: Tspan, _ elem: Element) -> Tspan {
    let (ff, fs, fw, fst, td, tt, fv, xl, rot, lh, ls, bs, aa):
        (String, Double, String, String, String, String, String, String,
         String, String, String, String, String)
    switch elem {
    case .text(let te):
        (ff, fs, fw, fst, td, tt, fv, xl, rot, lh, ls, bs, aa) =
            (te.fontFamily, te.fontSize, te.fontWeight, te.fontStyle,
             te.textDecoration, te.textTransform, te.fontVariant,
             te.xmlLang, te.rotate, te.lineHeight, te.letterSpacing,
             te.baselineShift, te.aaMode)
    case .textPath(let tp):
        (ff, fs, fw, fst, td, tt, fv, xl, rot, lh, ls, bs, aa) =
            (tp.fontFamily, tp.fontSize, tp.fontWeight, tp.fontStyle,
             tp.textDecoration, tp.textTransform, tp.fontVariant,
             tp.xmlLang, tp.rotate, tp.lineHeight, tp.letterSpacing,
             tp.baselineShift, tp.aaMode)
    default:
        return t
    }
    var fontFamily = t.fontFamily
    if fontFamily == ff { fontFamily = nil }
    var fontSize = t.fontSize
    if let v = fontSize, abs(v - fs) < 1e-6 { fontSize = nil }
    var fontWeight = t.fontWeight
    if fontWeight == fw { fontWeight = nil }
    var fontStyle = t.fontStyle
    if fontStyle == fst { fontStyle = nil }
    // text-decoration: compare sorted parsed sets so "none" and ""
    // collapse, and token order doesn't matter.
    var textDecoration = t.textDecoration
    if let tokens = textDecoration {
        let a = tokens.sorted()
        let b = td.split(separator: " ")
            .map(String.init)
            .filter { $0 != "none" && !$0.isEmpty }
            .sorted()
        if a == b { textDecoration = nil }
    }
    var textTransform = t.textTransform
    if textTransform == tt { textTransform = nil }
    var fontVariant = t.fontVariant
    if fontVariant == fv { fontVariant = nil }
    var xmlLang = t.xmlLang
    if xmlLang == xl { xmlLang = nil }
    var rotate = t.rotate
    if let v = rotate {
        let elemRot = Double(rot) ?? 0.0
        if abs(v - elemRot) < 1e-6 { rotate = nil }
    }
    var lineHeight = t.lineHeight
    if let v = lineHeight {
        // Empty element line_height = Auto = 120% of font_size.
        let elemLh = _parsePtValue(lh) ?? (fs * 1.2)
        if abs(v - elemLh) < 1e-6 { lineHeight = nil }
    }
    var letterSpacing = t.letterSpacing
    if let v = letterSpacing {
        let elemLs = _parseEmValue(ls) ?? 0.0
        if abs(v - elemLs) < 1e-6 { letterSpacing = nil }
    }
    var baselineShift = t.baselineShift
    if let v = baselineShift {
        if let elemBs = _parsePtValue(bs) {
            if abs(v - elemBs) < 1e-6 { baselineShift = nil }
        } else if bs.isEmpty && v == 0.0 {
            baselineShift = nil
        }
    }
    var jasAaMode = t.jasAaMode
    if let v = jasAaMode {
        let elemAa = aa == "Sharp" ? "" : aa
        if v == elemAa { jasAaMode = nil }
    }
    return Tspan(
        id: t.id, content: t.content,
        baselineShift: baselineShift, dx: t.dx,
        fontFamily: fontFamily, fontSize: fontSize,
        fontStyle: fontStyle, fontVariant: fontVariant,
        fontWeight: fontWeight,
        jasAaMode: jasAaMode, jasFractionalWidths: t.jasFractionalWidths,
        jasKerningMode: t.jasKerningMode, jasNoBreak: t.jasNoBreak,
        letterSpacing: letterSpacing, lineHeight: lineHeight,
        rotate: rotate, styleName: t.styleName,
        textDecoration: textDecoration, textRendering: t.textRendering,
        textTransform: textTransform, transform: t.transform,
        xmlLang: xmlLang)
}

/// Apply `overrides` to every tspan covered by `[charStart, charEnd)`
/// of `tspans`. Runs TSPAN.md's per-range algorithm: splitTspanRange
/// to isolate the targeted tspans, mergeTspanOverrides to copy the
/// override fields onto each one, mergeTspans to collapse adjacent-
/// equal tspans. If `elem` is supplied, runs identity-omission
/// (TSPAN.md step 3) between the merge-overrides and merge steps so
/// fields matching the parent's effective value get dropped.
func applyOverridesToTspanRange(
    _ tspans: [Tspan], charStart: Int, charEnd: Int, overrides: Tspan,
    elem: Element? = nil
) -> [Tspan] {
    guard charStart < charEnd else { return tspans }
    let (split, first, last) = splitTspanRange(tspans,
                                                 charStart: charStart,
                                                 charEnd: charEnd)
    guard let f = first, let l = last else { return split }
    var out = split
    for i in f...l {
        var merged = mergeTspanOverrides(out[i], overrides)
        if let e = elem {
            merged = identityOmitTspan(merged, e)
        }
        out[i] = merged
    }
    return mergeTspans(out)
}

/// Build a `Tspan` override template from the Character panel state
/// that contains only the fields where the panel differs from the
/// currently-edited element. Returns `nil` when everything matches.
/// Scope (Phase 3 MVP, mirrors Rust 390513e): font-family, font-size,
/// font-weight, font-style, text-decoration, text-transform,
/// font-variant, xml-lang, rotate. Complex attributes (baseline-shift
/// with super/sub, kerning modes, scales, line-height) aren't yet
/// supported as pending overrides and are left out of the template.
func buildPanelPendingTemplate(_ panel: [String: Any], _ elem: Element) -> Tspan? {
    let (elemFF, elemFS, elemFW, elemFSt, elemTD, elemTT, elemFV, elemXL,
         elemRot, elemLH, elemLS, elemBS, elemAA):
        (String, Double, String, String, String, String, String, String,
         String, String, String, String, String)
    switch elem {
    case .text(let t):
        (elemFF, elemFS, elemFW, elemFSt, elemTD, elemTT, elemFV, elemXL,
         elemRot, elemLH, elemLS, elemBS, elemAA) =
            (t.fontFamily, t.fontSize, t.fontWeight, t.fontStyle,
             t.textDecoration, t.textTransform, t.fontVariant,
             t.xmlLang, t.rotate, t.lineHeight, t.letterSpacing,
             t.baselineShift, t.aaMode)
    case .textPath(let tp):
        (elemFF, elemFS, elemFW, elemFSt, elemTD, elemTT, elemFV, elemXL,
         elemRot, elemLH, elemLS, elemBS, elemAA) =
            (tp.fontFamily, tp.fontSize, tp.fontWeight, tp.fontStyle,
             tp.textDecoration, tp.textTransform, tp.fontVariant,
             tp.xmlLang, tp.rotate, tp.lineHeight, tp.letterSpacing,
             tp.baselineShift, tp.aaMode)
    default:
        return nil
    }
    var any = false
    var fontFamily: String? = nil
    var fontSize: Double? = nil
    var fontWeight: String? = nil
    var fontStyle: String? = nil
    var textDecoration: [String]? = nil
    var textTransform: String? = nil
    var fontVariant: String? = nil
    var xmlLang: String? = nil
    var rotate: Double? = nil
    var lineHeight: Double? = nil
    var letterSpacing: Double? = nil
    var baselineShift: Double? = nil
    var jasAaMode: String? = nil

    if let v = panel["font_family"] as? String, v != elemFF {
        fontFamily = v; any = true
    }
    if let v = (panel["font_size"] as? NSNumber)?.doubleValue,
       abs(v - elemFS) > 1e-6 {
        fontSize = v; any = true
    }
    if let style = panel["style_name"] as? String {
        let (fw, fst): (String?, String?) = {
            switch style.trimmingCharacters(in: .whitespaces) {
            case "Regular":      return ("normal", "normal")
            case "Italic":       return ("normal", "italic")
            case "Bold":         return ("bold",   "normal")
            case "Bold Italic", "Italic Bold": return ("bold", "italic")
            default: return (nil, nil)
            }
        }()
        if let fw = fw, fw != elemFW { fontWeight = fw; any = true }
        if let fst = fst, fst != elemFSt { fontStyle = fst; any = true }
    }
    // text-decoration: parse both sides into sorted sets so "none"
    // and "" (no decoration) collapse.
    let underline = panel["underline"] as? Bool ?? false
    let strikethrough = panel["strikethrough"] as? Bool ?? false
    let panelTd: [String] = [
        strikethrough ? "line-through" : nil,
        underline ? "underline" : nil,
    ].compactMap { $0 }.sorted()
    let elemTdParsed: [String] = elemTD
        .split(separator: " ")
        .map(String.init)
        .filter { $0 != "none" }
        .sorted()
    if panelTd != elemTdParsed {
        textDecoration = panelTd; any = true
    }
    // text-transform: All Caps flag.
    let allCaps = panel["all_caps"] as? Bool ?? false
    let tt = allCaps ? "uppercase" : ""
    if tt != elemTT { textTransform = tt; any = true }
    // font-variant: Small Caps flag (when All Caps is off).
    let smallCaps = panel["small_caps"] as? Bool ?? false
    let fv = (smallCaps && !allCaps) ? "small-caps" : ""
    if fv != elemFV { fontVariant = fv; any = true }
    if let v = panel["language"] as? String, v != elemXL {
        xmlLang = v; any = true
    }
    // Character rotation: Double on the panel, string on the element.
    let rot = (panel["character_rotation"] as? NSNumber)?.doubleValue ?? 0.0
    let rotStr = rot == 0.0 ? "" : _fmtNum(rot)
    if rotStr != elemRot {
        rotate = rot == 0.0 ? nil : rot
        if rotate != nil { any = true }
    }
    // Leading → line_height (pt). Element stores as CSS length
    // string; empty round-trips to auto (120% of font_size).
    let leading = (panel["leading"] as? NSNumber)?.doubleValue
    let elemLhVal = _parsePtValue(elemLH) ?? (elemFS * 1.2)
    if let leading = leading, abs(leading - elemLhVal) > 1e-6 {
        lineHeight = leading; any = true
    }
    // Tracking → letter_spacing (em). Panel unit is 1/1000 em.
    let tracking = (panel["tracking"] as? NSNumber)?.doubleValue ?? 0.0
    let elemTracking = (_parseEmValue(elemLS) ?? 0.0) * 1000.0
    if abs(tracking - elemTracking) > 1e-6 {
        letterSpacing = tracking / 1000.0; any = true
    }
    // Baseline shift numeric: skipped when super / sub is on.
    let superOn = panel["superscript"] as? Bool ?? false
    let subOn = panel["subscript"] as? Bool ?? false
    if !superOn && !subOn {
        let bs = (panel["baseline_shift"] as? NSNumber)?.doubleValue ?? 0.0
        let elemBsVal = _parsePtValue(elemBS) ?? 0.0
        if abs(bs - elemBsVal) > 1e-6 {
            baselineShift = bs; any = true
        }
    }
    // Anti-aliasing → jas_aa_mode.
    let aaRaw = (panel["anti_aliasing"] as? String) ?? "Sharp"
    let aaMode = (aaRaw == "Sharp" || aaRaw.isEmpty) ? "" : aaRaw
    if aaMode != elemAA {
        jasAaMode = aaMode; any = true
    }

    if !any { return nil }
    return Tspan(
        id: 0, content: "",
        baselineShift: baselineShift,
        fontFamily: fontFamily, fontSize: fontSize,
        fontStyle: fontStyle, fontVariant: fontVariant,
        fontWeight: fontWeight,
        jasAaMode: jasAaMode,
        letterSpacing: letterSpacing,
        lineHeight: lineHeight,
        rotate: rotate,
        textDecoration: textDecoration,
        textTransform: textTransform,
        xmlLang: xmlLang
    )
}

/// Parse a CSS pt-length ("5pt") into a Double. Empty → nil.
private func _parsePtValue(_ s: String) -> Double? {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    if trimmed.hasSuffix("pt") {
        return Double(trimmed.dropLast(2))
    }
    return Double(trimmed)
}

/// Parse a CSS em-length ("0.025em") into a Double. Empty → nil.
private func _parseEmValue(_ s: String) -> Double? {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    if trimmed.hasSuffix("em") {
        return Double(trimmed.dropLast(2))
    }
    return Double(trimmed)
}

func applyCharacterPanelToSelection(store: StateStore, controller: Controller) {
    // Phase 3: route to next-typed-character state when there is an
    // active edit session with a bare caret (no range selection).
    // The panel's widget click should prime the session's pending
    // override rather than rewrite the whole element.
    if let session = controller.model.currentEditSession,
       !session.hasSelection {
        let p = store.getPanelState("character_panel")
        let doc = controller.model.document
        if pathIsValid(doc, session.path) {
            let elem = doc.getElement(session.path)
            let template = buildPanelPendingTemplate(p, elem)
            session.clearPendingOverride()
            if let tpl = template {
                session.setPendingOverride(tpl)
            }
            return
        }
    }

    // Per-range write: when the active edit session has a range
    // selection, apply the panel state to that range only via
    // splitTspanRange + mergeTspanOverrides + mergeTspans. The
    // rest of the edited element is left untouched.
    if let session = controller.model.currentEditSession,
       session.hasSelection {
        let p = store.getPanelState("character_panel")
        let doc = controller.model.document
        if pathIsValid(doc, session.path) {
            let elem = doc.getElement(session.path)
            let (lo, hi) = session.selectionRange
            let overrides = buildPanelFullOverrides(p)
            let newElem: Element?
            switch elem {
            case .text(let t):
                let newTspans = applyOverridesToTspanRange(
                    t.tspans, charStart: lo, charEnd: hi,
                    overrides: overrides, elem: elem)
                newElem = .text(t.withTspans(newTspans))
            case .textPath(let tp):
                let newTspans = applyOverridesToTspanRange(
                    tp.tspans, charStart: lo, charEnd: hi,
                    overrides: overrides, elem: elem)
                newElem = .textPath(tp.withTspans(newTspans))
            default:
                newElem = nil
            }
            if let ne = newElem {
                controller.model.snapshot()
                controller.setDocument(doc.replaceElement(session.path, with: ne))
            }
            return
        }
    }

    let p = store.getPanelState("character_panel")
    var attrs: [String: Any] = [:]

    if let v = p["font_family"] as? String { attrs["font_family"] = v }
    if let v = (p["font_size"] as? NSNumber)?.doubleValue { attrs["font_size"] = NSNumber(value: v) }

    // style_name → font_weight + font_style
    if let style = p["style_name"] as? String {
        switch style.trimmingCharacters(in: .whitespaces) {
        case "Regular":
            attrs["font_weight"] = "normal"; attrs["font_style"] = "normal"
        case "Italic":
            attrs["font_weight"] = "normal"; attrs["font_style"] = "italic"
        case "Bold":
            attrs["font_weight"] = "bold"; attrs["font_style"] = "normal"
        case "Bold Italic", "Italic Bold":
            attrs["font_weight"] = "bold"; attrs["font_style"] = "italic"
        default: break
        }
    }

    // underline + strikethrough → text_decoration
    let underline = p["underline"] as? Bool ?? false
    let strikethrough = p["strikethrough"] as? Bool ?? false
    let tdTokens = [
        strikethrough ? "line-through" : nil,
        underline ? "underline" : nil,
    ].compactMap { $0 }
    attrs["text_decoration"] = tdTokens.isEmpty ? "" : tdTokens.joined(separator: " ")

    // all_caps / small_caps
    let allCaps = p["all_caps"] as? Bool ?? false
    let smallCaps = p["small_caps"] as? Bool ?? false
    attrs["text_transform"] = allCaps ? "uppercase" : ""
    attrs["font_variant"] = (smallCaps && !allCaps) ? "small-caps" : ""

    // super / sub + numeric baseline_shift
    let superOn = p["superscript"] as? Bool ?? false
    let subOn = p["subscript"] as? Bool ?? false
    let bsNum = (p["baseline_shift"] as? NSNumber)?.doubleValue ?? 0.0
    if superOn {
        attrs["baseline_shift"] = "super"
    } else if subOn {
        attrs["baseline_shift"] = "sub"
    } else if bsNum != 0.0 {
        attrs["baseline_shift"] = _fmtNum(bsNum) + "pt"
    } else {
        attrs["baseline_shift"] = ""
    }

    // leading → line_height: empty at 120% Auto default
    let fsNum = (p["font_size"] as? NSNumber)?.doubleValue ?? 12.0
    let leading = (p["leading"] as? NSNumber)?.doubleValue ?? (fsNum * 1.2)
    attrs["line_height"] = abs(leading - fsNum * 1.2) < 1e-6
        ? "" : _fmtNum(leading) + "pt"

    // tracking (1/1000 em) → letter_spacing
    let tracking = (p["tracking"] as? NSNumber)?.doubleValue ?? 0.0
    attrs["letter_spacing"] = tracking == 0.0 ? "" : _fmtNum(tracking / 1000.0) + "em"

    // kerning combo_box: Auto / Optical / Metrics pass through
    // verbatim; numeric-string entry is 1/1000 em. Empty / "0" /
    // "Auto" all omit (the element default). Legacy Number bindings
    // also land here via the NSNumber branch.
    if let s = p["kerning"] as? String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "", "0", "Auto": attrs["kerning"] = ""
        case "Optical", "Metrics": attrs["kerning"] = trimmed
        default:
            if let n = Double(trimmed) {
                attrs["kerning"] = n == 0.0 ? "" : _fmtNum(n / 1000.0) + "em"
            } else {
                attrs["kerning"] = ""
            }
        }
    } else {
        let kerning = (p["kerning"] as? NSNumber)?.doubleValue ?? 0.0
        attrs["kerning"] = kerning == 0.0 ? "" : _fmtNum(kerning / 1000.0) + "em"
    }

    // character_rotation (degrees)
    let rot = (p["character_rotation"] as? NSNumber)?.doubleValue ?? 0.0
    attrs["rotate"] = rot == 0.0 ? "" : _fmtNum(rot)

    // vertical / horizontal scale (percent; identity = 100)
    let vScale = (p["vertical_scale"] as? NSNumber)?.doubleValue ?? 100.0
    let hScale = (p["horizontal_scale"] as? NSNumber)?.doubleValue ?? 100.0
    attrs["vertical_scale"] = vScale == 100.0 ? "" : _fmtNum(vScale)
    attrs["horizontal_scale"] = hScale == 100.0 ? "" : _fmtNum(hScale)

    // language → xml_lang; anti_aliasing → aa_mode (Sharp default empties)
    if let v = p["language"] as? String { attrs["xml_lang"] = v }
    if let v = p["anti_aliasing"] as? String {
        attrs["aa_mode"] = (v == "Sharp" || v.isEmpty) ? "" : v
    }

    // Snapshot + apply. No-op when nothing in the selection is text.
    if !controller.model.document.selection.isEmpty {
        controller.model.snapshot()
        controller.setSelectionTextAttributes(attrs)
    }
}

/// Check if a state key lives under the Character-panel scope.
func isCharacterPanelKey(_ key: String) -> Bool {
    characterPanelKeys.contains(key)
}

/// Push the YAML-stored paragraph panel state onto every paragraph
/// wrapper tspan inside the selection. Per the identity-value rule,
/// attrs equal to their default are *omitted* (set to nil) rather
/// than written. The seven alignment radio bools collapse to one
/// `(text-align, text-align-last)` pair per the §Alignment
/// sub-mapping; bullets and numbered_list both write the single
/// `jasListStyle` attribute. Phase 4.
public func applyParagraphPanelToSelection(store: StateStore, controller: Controller) {
    let p = store.getPanelState("paragraph_panel_content")
    let pid = "paragraph_panel_content"
    _ = pid

    let leftIndent = (p["left_indent"] as? NSNumber)?.doubleValue ?? 0
    let rightIndent = (p["right_indent"] as? NSNumber)?.doubleValue ?? 0
    let firstLineIndent = (p["first_line_indent"] as? NSNumber)?.doubleValue ?? 0
    let spaceBefore = (p["space_before"] as? NSNumber)?.doubleValue ?? 0
    let spaceAfter = (p["space_after"] as? NSNumber)?.doubleValue ?? 0
    let hyph = (p["hyphenate"] as? Bool) ?? false
    let hangPunct = (p["hanging_punctuation"] as? Bool) ?? false
    let bullets = (p["bullets"] as? String) ?? ""
    let numbered = (p["numbered_list"] as? String) ?? ""
    let listStyle: String? = !bullets.isEmpty ? bullets
        : (!numbered.isEmpty ? numbered : nil)

    // Alignment radio → (text-align, text-align-last). Default
    // ALIGN_LEFT_BUTTON omits both attrs per identity rule.
    let alignCenter = (p["align_center"] as? Bool) ?? false
    let alignRight = (p["align_right"] as? Bool) ?? false
    let justifyLeft = (p["justify_left"] as? Bool) ?? false
    let justifyCenter = (p["justify_center"] as? Bool) ?? false
    let justifyRight = (p["justify_right"] as? Bool) ?? false
    let justifyAll = (p["justify_all"] as? Bool) ?? false
    let textAlign: String?
    let textAlignLast: String?
    if alignCenter { textAlign = "center"; textAlignLast = nil }
    else if alignRight { textAlign = "right"; textAlignLast = nil }
    else if justifyLeft { textAlign = "justify"; textAlignLast = "left" }
    else if justifyCenter { textAlign = "justify"; textAlignLast = "center" }
    else if justifyRight { textAlign = "justify"; textAlignLast = "right" }
    else if justifyAll { textAlign = "justify"; textAlignLast = "justify" }
    else { textAlign = nil; textAlignLast = nil }

    func optD(_ v: Double) -> Double? { v == 0 ? nil : v }
    func optB(_ v: Bool) -> Bool? { v ? true : nil }

    let model = controller.model
    let doc = model.document
    let targetPaths = doc.selection.compactMap { es -> [Int]? in
        switch doc.getElement(es.path) {
        case .text, .textPath: return es.path
        default: return nil
        }
    }
    if targetPaths.isEmpty { return }
    model.snapshot()
    var newDoc = doc
    for path in targetPaths {
        let elem = newDoc.getElement(path)
        let newElem: Element?
        switch elem {
        case .text(let t):
            var tspans = t.tspans
            var wrapperIdx = tspans.indices.filter { tspans[$0].jasRole == "paragraph" }
            if wrapperIdx.isEmpty, !tspans.isEmpty {
                tspans[0] = withJasRole(tspans[0], "paragraph")
                wrapperIdx = [0]
            }
            for i in wrapperIdx {
                tspans[i] = withParagraphAttrs(
                    tspans[i],
                    textAlign: textAlign, textAlignLast: textAlignLast,
                    textIndent: firstLineIndent == 0 ? nil : firstLineIndent,
                    jasLeftIndent: optD(leftIndent),
                    jasRightIndent: optD(rightIndent),
                    jasSpaceBefore: optD(spaceBefore),
                    jasSpaceAfter: optD(spaceAfter),
                    jasHyphenate: optB(hyph),
                    jasHangingPunctuation: optB(hangPunct),
                    jasListStyle: listStyle)
            }
            newElem = .text(t.withTspans(tspans))
        case .textPath(let tp):
            var tspans = tp.tspans
            var wrapperIdx = tspans.indices.filter { tspans[$0].jasRole == "paragraph" }
            if wrapperIdx.isEmpty, !tspans.isEmpty {
                tspans[0] = withJasRole(tspans[0], "paragraph")
                wrapperIdx = [0]
            }
            for i in wrapperIdx {
                tspans[i] = withParagraphAttrs(
                    tspans[i],
                    textAlign: textAlign, textAlignLast: textAlignLast,
                    textIndent: firstLineIndent == 0 ? nil : firstLineIndent,
                    jasLeftIndent: optD(leftIndent),
                    jasRightIndent: optD(rightIndent),
                    jasSpaceBefore: optD(spaceBefore),
                    jasSpaceAfter: optD(spaceAfter),
                    jasHyphenate: optB(hyph),
                    jasHangingPunctuation: optB(hangPunct),
                    jasListStyle: listStyle)
            }
            newElem = .textPath(tp.withTspans(tspans))
        default:
            newElem = nil
        }
        if let ne = newElem {
            newDoc = newDoc.replaceElement(path, with: ne)
        }
    }
    controller.setDocument(newDoc)
}

/// Reset every Paragraph panel control to its default per
/// PARAGRAPH.md §Reset Panel and remove the corresponding
/// `jas:*` / `text-*` attributes from every paragraph wrapper tspan
/// in the selection (defaults appear as absence, identity rule).
public func resetParagraphPanel(store: StateStore, controller: Controller) {
    let pid = "paragraph_panel_content"
    // Reset panel-local fields to their YAML defaults.
    store.setPanel(pid, "align_left", true)
    store.setPanel(pid, "align_center", false)
    store.setPanel(pid, "align_right", false)
    store.setPanel(pid, "justify_left", false)
    store.setPanel(pid, "justify_center", false)
    store.setPanel(pid, "justify_right", false)
    store.setPanel(pid, "justify_all", false)
    store.setPanel(pid, "bullets", "")
    store.setPanel(pid, "numbered_list", "")
    store.setPanel(pid, "left_indent", 0.0)
    store.setPanel(pid, "right_indent", 0.0)
    store.setPanel(pid, "first_line_indent", 0.0)
    store.setPanel(pid, "space_before", 0.0)
    store.setPanel(pid, "space_after", 0.0)
    store.setPanel(pid, "hyphenate", false)
    store.setPanel(pid, "hanging_punctuation", false)
    applyParagraphPanelToSelection(store: store, controller: controller)
}

/// 11 Justification-dialog field values, packed for one commit pass.
/// `nil` means the field was blank (mixed selection) and should not
/// write — the existing wrapper attr stays. Phase 8.
public struct JustificationDialogValues {
    public var wordSpacingMin: Double?
    public var wordSpacingDesired: Double?
    public var wordSpacingMax: Double?
    public var letterSpacingMin: Double?
    public var letterSpacingDesired: Double?
    public var letterSpacingMax: Double?
    public var glyphScalingMin: Double?
    public var glyphScalingDesired: Double?
    public var glyphScalingMax: Double?
    public var autoLeading: Double?
    public var singleWordJustify: String?

    public init(wordSpacingMin: Double? = nil, wordSpacingDesired: Double? = nil,
                wordSpacingMax: Double? = nil,
                letterSpacingMin: Double? = nil, letterSpacingDesired: Double? = nil,
                letterSpacingMax: Double? = nil,
                glyphScalingMin: Double? = nil, glyphScalingDesired: Double? = nil,
                glyphScalingMax: Double? = nil,
                autoLeading: Double? = nil, singleWordJustify: String? = nil) {
        self.wordSpacingMin = wordSpacingMin
        self.wordSpacingDesired = wordSpacingDesired
        self.wordSpacingMax = wordSpacingMax
        self.letterSpacingMin = letterSpacingMin
        self.letterSpacingDesired = letterSpacingDesired
        self.letterSpacingMax = letterSpacingMax
        self.glyphScalingMin = glyphScalingMin
        self.glyphScalingDesired = glyphScalingDesired
        self.glyphScalingMax = glyphScalingMax
        self.autoLeading = autoLeading
        self.singleWordJustify = singleWordJustify
    }
}

/// Commit the 11 Justification-dialog fields onto every paragraph
/// wrapper tspan in the selection. Per the identity-value rule each
/// value at its spec default (word-spacing 80/100/133, letter-
/// spacing 0/0/0, glyph-scaling 100/100/100, auto-leading 120,
/// single-word-justify 'justify') writes nil so the wrapper attr is
/// omitted. Phase 8.
public func applyJustificationDialogToSelection(
    _ v: JustificationDialogValues, controller: Controller
) {
    func optN(_ value: Double?, default def: Double) -> Double? {
        value.flatMap { abs($0 - def) < 1e-6 ? nil : $0 }
    }
    let wsMin = optN(v.wordSpacingMin, default: 80)
    let wsDes = optN(v.wordSpacingDesired, default: 100)
    let wsMax = optN(v.wordSpacingMax, default: 133)
    let lsMin = optN(v.letterSpacingMin, default: 0)
    let lsDes = optN(v.letterSpacingDesired, default: 0)
    let lsMax = optN(v.letterSpacingMax, default: 0)
    let gsMin = optN(v.glyphScalingMin, default: 100)
    let gsDes = optN(v.glyphScalingDesired, default: 100)
    let gsMax = optN(v.glyphScalingMax, default: 100)
    let auto = optN(v.autoLeading, default: 120)
    let swj = v.singleWordJustify.flatMap { $0 == "justify" ? nil : $0 }

    let model = controller.model
    let doc = model.document
    let targetPaths = doc.selection.compactMap { es -> [Int]? in
        switch doc.getElement(es.path) {
        case .text, .textPath: return es.path
        default: return nil
        }
    }
    if targetPaths.isEmpty { return }
    model.snapshot()
    var newDoc = doc
    for path in targetPaths {
        let elem = newDoc.getElement(path)
        let newElem: Element?
        switch elem {
        case .text(let t):
            var tspans = t.tspans
            var wrapperIdx = tspans.indices.filter { tspans[$0].jasRole == "paragraph" }
            if wrapperIdx.isEmpty, !tspans.isEmpty {
                tspans[0] = withJasRole(tspans[0], "paragraph")
                wrapperIdx = [0]
            }
            for i in wrapperIdx {
                tspans[i] = withJustificationAttrs(
                    tspans[i],
                    wsMin: wsMin, wsDes: wsDes, wsMax: wsMax,
                    lsMin: lsMin, lsDes: lsDes, lsMax: lsMax,
                    gsMin: gsMin, gsDes: gsDes, gsMax: gsMax,
                    autoLeading: auto, swj: swj)
            }
            newElem = .text(t.withTspans(tspans))
        case .textPath(let tp):
            var tspans = tp.tspans
            var wrapperIdx = tspans.indices.filter { tspans[$0].jasRole == "paragraph" }
            if wrapperIdx.isEmpty, !tspans.isEmpty {
                tspans[0] = withJasRole(tspans[0], "paragraph")
                wrapperIdx = [0]
            }
            for i in wrapperIdx {
                tspans[i] = withJustificationAttrs(
                    tspans[i],
                    wsMin: wsMin, wsDes: wsDes, wsMax: wsMax,
                    lsMin: lsMin, lsDes: lsDes, lsMax: lsMax,
                    gsMin: gsMin, gsDes: gsDes, gsMax: gsMax,
                    autoLeading: auto, swj: swj)
            }
            newElem = .textPath(tp.withTspans(tspans))
        default:
            newElem = nil
        }
        if let ne = newElem {
            newDoc = newDoc.replaceElement(path, with: ne)
        }
    }
    controller.setDocument(newDoc)
}

/// 8 Hyphenation-dialog field values (master + 7 sub-controls).
/// `nil` means the dialog field was blank (mixed selection) and
/// should not write. Phase 9.
public struct HyphenationDialogValues {
    public var hyphenate: Bool?
    public var minWord: Double?
    public var minBefore: Double?
    public var minAfter: Double?
    public var limit: Double?
    public var zone: Double?
    public var bias: Double?
    public var capitalized: Bool?

    public init(hyphenate: Bool? = nil,
                minWord: Double? = nil, minBefore: Double? = nil,
                minAfter: Double? = nil, limit: Double? = nil,
                zone: Double? = nil, bias: Double? = nil,
                capitalized: Bool? = nil) {
        self.hyphenate = hyphenate
        self.minWord = minWord
        self.minBefore = minBefore
        self.minAfter = minAfter
        self.limit = limit
        self.zone = zone
        self.bias = bias
        self.capitalized = capitalized
    }
}

/// Commit the master + 7 Hyphenation-dialog fields onto every paragraph
/// wrapper tspan in the selection. Per the identity-value rule each
/// value at its spec default (master off, 3/1/1, 0, 0, 0, off) writes
/// nil so the wrapper attr is omitted. Also mirrors the master toggle
/// to the panel.hyphenate state so the main panel checkbox reflects
/// the dialog commit immediately. Phase 9.
public func applyHyphenationDialogToSelection(
    _ v: HyphenationDialogValues, controller: Controller, store: StateStore
) {
    func optN(_ value: Double?, default def: Double) -> Double? {
        value.flatMap { abs($0 - def) < 1e-6 ? nil : $0 }
    }
    func optB(_ value: Bool?) -> Bool? {
        value.flatMap { $0 ? true : nil }
    }
    let hyph = optB(v.hyphenate)
    let minWord = optN(v.minWord, default: 3)
    let minBefore = optN(v.minBefore, default: 1)
    let minAfter = optN(v.minAfter, default: 1)
    let limit = optN(v.limit, default: 0)
    let zone = optN(v.zone, default: 0)
    let bias = optN(v.bias, default: 0)
    let cap = optB(v.capitalized)

    let model = controller.model
    let doc = model.document
    let targetPaths = doc.selection.compactMap { es -> [Int]? in
        switch doc.getElement(es.path) {
        case .text, .textPath: return es.path
        default: return nil
        }
    }
    if targetPaths.isEmpty { return }
    model.snapshot()
    var newDoc = doc
    for path in targetPaths {
        let elem = newDoc.getElement(path)
        let newElem: Element?
        switch elem {
        case .text(let t):
            var tspans = t.tspans
            var wrapperIdx = tspans.indices.filter { tspans[$0].jasRole == "paragraph" }
            if wrapperIdx.isEmpty, !tspans.isEmpty {
                tspans[0] = withJasRole(tspans[0], "paragraph")
                wrapperIdx = [0]
            }
            for i in wrapperIdx {
                tspans[i] = withHyphenationAttrs(
                    tspans[i],
                    hyphenate: hyph,
                    minWord: minWord, minBefore: minBefore, minAfter: minAfter,
                    limit: limit, zone: zone, bias: bias, capitalized: cap)
            }
            newElem = .text(t.withTspans(tspans))
        case .textPath(let tp):
            var tspans = tp.tspans
            var wrapperIdx = tspans.indices.filter { tspans[$0].jasRole == "paragraph" }
            if wrapperIdx.isEmpty, !tspans.isEmpty {
                tspans[0] = withJasRole(tspans[0], "paragraph")
                wrapperIdx = [0]
            }
            for i in wrapperIdx {
                tspans[i] = withHyphenationAttrs(
                    tspans[i],
                    hyphenate: hyph,
                    minWord: minWord, minBefore: minBefore, minAfter: minAfter,
                    limit: limit, zone: zone, bias: bias, capitalized: cap)
            }
            newElem = .textPath(tp.withTspans(tspans))
        default:
            newElem = nil
        }
        if let ne = newElem {
            newDoc = newDoc.replaceElement(path, with: ne)
        }
    }
    controller.setDocument(newDoc)
    if let h = v.hyphenate {
        store.setPanel("paragraph_panel_content", "hyphenate", h)
    }
}

/// Replace the master + 7 Hyphenation-dialog attrs on a Tspan;
/// preserve all other fields. Phase 9 helper.
private func withHyphenationAttrs(
    _ t: Tspan,
    hyphenate: Bool?,
    minWord: Double?, minBefore: Double?, minAfter: Double?,
    limit: Double?, zone: Double?, bias: Double?, capitalized: Bool?
) -> Tspan {
    Tspan(
        id: t.id, content: t.content,
        baselineShift: t.baselineShift, dx: t.dx,
        fontFamily: t.fontFamily, fontSize: t.fontSize,
        fontStyle: t.fontStyle, fontVariant: t.fontVariant,
        fontWeight: t.fontWeight,
        jasAaMode: t.jasAaMode, jasFractionalWidths: t.jasFractionalWidths,
        jasKerningMode: t.jasKerningMode, jasNoBreak: t.jasNoBreak,
        jasRole: t.jasRole,
        jasLeftIndent: t.jasLeftIndent, jasRightIndent: t.jasRightIndent,
        jasHyphenate: hyphenate,
        jasHangingPunctuation: t.jasHangingPunctuation,
        jasListStyle: t.jasListStyle,
        textAlign: t.textAlign, textAlignLast: t.textAlignLast,
        textIndent: t.textIndent,
        jasSpaceBefore: t.jasSpaceBefore, jasSpaceAfter: t.jasSpaceAfter,
        jasWordSpacingMin: t.jasWordSpacingMin,
        jasWordSpacingDesired: t.jasWordSpacingDesired,
        jasWordSpacingMax: t.jasWordSpacingMax,
        jasLetterSpacingMin: t.jasLetterSpacingMin,
        jasLetterSpacingDesired: t.jasLetterSpacingDesired,
        jasLetterSpacingMax: t.jasLetterSpacingMax,
        jasGlyphScalingMin: t.jasGlyphScalingMin,
        jasGlyphScalingDesired: t.jasGlyphScalingDesired,
        jasGlyphScalingMax: t.jasGlyphScalingMax,
        jasAutoLeading: t.jasAutoLeading,
        jasSingleWordJustify: t.jasSingleWordJustify,
        jasHyphenateMinWord: minWord,
        jasHyphenateMinBefore: minBefore,
        jasHyphenateMinAfter: minAfter,
        jasHyphenateLimit: limit,
        jasHyphenateZone: zone,
        jasHyphenateBias: bias,
        jasHyphenateCapitalized: capitalized,
        letterSpacing: t.letterSpacing, lineHeight: t.lineHeight,
        rotate: t.rotate, styleName: t.styleName,
        textDecoration: t.textDecoration, textRendering: t.textRendering,
        textTransform: t.textTransform, transform: t.transform,
        xmlLang: t.xmlLang)
}

/// Replace the 11 Justification-dialog attrs on a Tspan; preserve all
/// other fields. Phase 8 helper.
private func withJustificationAttrs(
    _ t: Tspan,
    wsMin: Double?, wsDes: Double?, wsMax: Double?,
    lsMin: Double?, lsDes: Double?, lsMax: Double?,
    gsMin: Double?, gsDes: Double?, gsMax: Double?,
    autoLeading: Double?, swj: String?
) -> Tspan {
    Tspan(
        id: t.id, content: t.content,
        baselineShift: t.baselineShift, dx: t.dx,
        fontFamily: t.fontFamily, fontSize: t.fontSize,
        fontStyle: t.fontStyle, fontVariant: t.fontVariant,
        fontWeight: t.fontWeight,
        jasAaMode: t.jasAaMode, jasFractionalWidths: t.jasFractionalWidths,
        jasKerningMode: t.jasKerningMode, jasNoBreak: t.jasNoBreak,
        jasRole: t.jasRole,
        jasLeftIndent: t.jasLeftIndent, jasRightIndent: t.jasRightIndent,
        jasHyphenate: t.jasHyphenate,
        jasHangingPunctuation: t.jasHangingPunctuation,
        jasListStyle: t.jasListStyle,
        textAlign: t.textAlign, textAlignLast: t.textAlignLast,
        textIndent: t.textIndent,
        jasSpaceBefore: t.jasSpaceBefore, jasSpaceAfter: t.jasSpaceAfter,
        jasWordSpacingMin: wsMin, jasWordSpacingDesired: wsDes,
        jasWordSpacingMax: wsMax,
        jasLetterSpacingMin: lsMin, jasLetterSpacingDesired: lsDes,
        jasLetterSpacingMax: lsMax,
        jasGlyphScalingMin: gsMin, jasGlyphScalingDesired: gsDes,
        jasGlyphScalingMax: gsMax,
        jasAutoLeading: autoLeading, jasSingleWordJustify: swj,
        jasHyphenateMinWord: t.jasHyphenateMinWord,
        jasHyphenateMinBefore: t.jasHyphenateMinBefore,
        jasHyphenateMinAfter: t.jasHyphenateMinAfter,
        jasHyphenateLimit: t.jasHyphenateLimit,
        jasHyphenateZone: t.jasHyphenateZone,
        jasHyphenateBias: t.jasHyphenateBias,
        jasHyphenateCapitalized: t.jasHyphenateCapitalized,
        letterSpacing: t.letterSpacing, lineHeight: t.lineHeight,
        rotate: t.rotate, styleName: t.styleName,
        textDecoration: t.textDecoration, textRendering: t.textRendering,
        textTransform: t.textTransform, transform: t.transform,
        xmlLang: t.xmlLang)
}

/// Dispatch a panel-state change to the matching apply-to-selection
/// pipeline. Called after any widget write-back or `set: panel.X`
/// batch so the downstream surface (selected element, other views)
/// re-syncs. Silent no-op for panels without a subscriber.
public func notifyPanelStateChanged(_ panelId: String, store: StateStore, model: Model) {
    switch panelId {
    case "character_panel":
        applyCharacterPanelToSelection(store: store, controller: Controller(model: model))
    case "paragraph_panel_content":
        applyParagraphPanelToSelection(store: store, controller: Controller(model: model))
    default:
        break
    }
}

/// Format a number for CSS length / value output: integers have no
/// decimal, fractions drop trailing zeros. Matches the Rust
/// `fmt_num` helper.
private func _fmtNum(_ n: Double) -> String {
    if n == n.rounded(.towardZero) {
        return String(Int(n))
    }
    var s = String(format: "%.4f", n)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

// MARK: - Align panel

/// Reset the four Align panel state fields to their defaults per
/// ALIGN.md §Panel menu Reset Panel. Writes through both the
/// global `state.align_*` surface (StateStore.set) and the
/// panel-local mirrors (StateStore.setPanel).
public func resetAlignPanel(store: StateStore) {
    let pid = "align_panel_content"
    store.set("align_to", "selection")
    store.set("align_key_object_path", NSNull())
    store.set("align_distribute_spacing", 0.0)
    store.set("align_use_preview_bounds", false)
    store.setPanel(pid, "align_to", "selection")
    store.setPanel(pid, "key_object_path", NSNull())
    store.setPanel(pid, "distribute_spacing_value", 0.0)
    store.setPanel(pid, "use_preview_bounds", false)
}

/// Execute one of the 14 Align panel operations by name. The
/// operation reads the current selection, builds an
/// `AlignReference` from the store's `align_*` keys, calls the
/// algorithm, and applies the resulting translations to each
/// moved element's transform.
///
/// Zero-delta outputs are discarded. The caller is responsible
/// for taking a snapshot first — the yaml-emitted `snapshot`
/// effect runs before this handler per ALIGN.md Undo semantics.
public func applyAlignOperation(model: Model, store: StateStore, op: String) {
    // Gather (path, element) pairs from the current selection.
    let doc = model.document
    var elements: [(ElementPath, Element)] = []
    for es in doc.selection {
        elements.append((es.path, doc.getElement(es.path)))
    }
    if elements.count < 2 { return }

    // Read align panel state.
    let usePreview = (store.get("align_use_preview_bounds") as? Bool) ?? false
    let boundsFn: AlignBoundsFn = usePreview ? alignPreviewBounds : alignGeometricBounds
    let alignTo = (store.get("align_to") as? String) ?? "selection"
    let keyPathRaw = store.get("align_key_object_path")

    // Build the reference.
    let reference: AlignReference
    switch alignTo {
    case "artboard":
        // No artboards in the document model yet; fall back to
        // selection-union bounds per ALIGN.md §Align To target
        // Deferred note.
        let refs = elements.map(\.1)
        reference = .artboard(alignUnionBounds(refs, boundsFn))
    case "key_object":
        // Decode the key object path marker.
        let keyPath: ElementPath? = {
            if let dict = keyPathRaw as? [String: Any],
               let arr = dict["__path__"] as? [Int] {
                return arr
            }
            if let arr = keyPathRaw as? [Int] { return arr }
            return nil
        }()
        guard let kp = keyPath else { return }
        // Guard the path is valid in the document.
        guard let _ = doc.selection.first(where: { $0.path == kp }) else { return }
        let keyElem = doc.getElement(kp)
        reference = .keyObject(bbox: boundsFn(keyElem), path: kp)
    default:
        let refs = elements.map(\.1)
        reference = .selection(alignUnionBounds(refs, boundsFn))
    }

    // Distribute Spacing explicit-gap: only in key-object mode
    // with a designated key.
    let explicitGap: Double? = {
        if alignTo != "key_object" { return nil }
        if reference.keyPath == nil { return nil }
        if let n = store.get("align_distribute_spacing") as? NSNumber {
            return n.doubleValue
        }
        if let d = store.get("align_distribute_spacing") as? Double { return d }
        if let i = store.get("align_distribute_spacing") as? Int { return Double(i) }
        return 0.0
    }()

    // Dispatch to the algorithm.
    let translations: [AlignTranslation]
    switch op {
    case "align_left": translations = alignLeft(elements, reference, boundsFn)
    case "align_horizontal_center": translations = alignHorizontalCenter(elements, reference, boundsFn)
    case "align_right": translations = alignRight(elements, reference, boundsFn)
    case "align_top": translations = alignTop(elements, reference, boundsFn)
    case "align_vertical_center": translations = alignVerticalCenter(elements, reference, boundsFn)
    case "align_bottom": translations = alignBottom(elements, reference, boundsFn)
    case "distribute_left": translations = distributeLeft(elements, reference, boundsFn)
    case "distribute_horizontal_center": translations = distributeHorizontalCenter(elements, reference, boundsFn)
    case "distribute_right": translations = distributeRight(elements, reference, boundsFn)
    case "distribute_top": translations = distributeTop(elements, reference, boundsFn)
    case "distribute_vertical_center": translations = distributeVerticalCenter(elements, reference, boundsFn)
    case "distribute_bottom": translations = distributeBottom(elements, reference, boundsFn)
    case "distribute_vertical_spacing":
        translations = distributeVerticalSpacing(elements, reference, explicitGap, boundsFn)
    case "distribute_horizontal_spacing":
        translations = distributeHorizontalSpacing(elements, reference, explicitGap, boundsFn)
    default: return
    }
    if translations.isEmpty { return }

    // Apply translations to the document. Swift elements are value
    // types so each translation produces a new Document via
    // replaceElement; the outer loop updates model.document at the
    // end.
    var newDoc = model.document
    for t in translations {
        let elem = newDoc.getElement(t.path)
        let moved = elem.withTransformTranslated(dx: t.dx, dy: t.dy)
        newDoc = newDoc.replaceElement(t.path, with: moved)
    }
    model.document = newDoc
}

/// Canvas-click intercept for key-object designation. Per
/// ALIGN.md §Align To target, when `align_to == "key_object"`
/// a canvas click at (x, y) designates the hit selected element
/// as the key, toggles off if it hits the current key, or clears
/// the key when the click falls outside any selected element.
///
/// Returns `true` when the click was consumed (the canvas tool
/// should not see it) and `false` when Align To is not in
/// key-object mode (click falls through).
public func tryDesignateAlignKeyObject(model: Model, store: StateStore,
                                        x: Double, y: Double) -> Bool {
    let alignTo = (store.get("align_to") as? String) ?? "selection"
    if alignTo != "key_object" { return false }
    let doc = model.document
    // Hit-test against the current selection using preview bounds
    // (matches what the user sees).
    var hit: ElementPath? = nil
    for es in doc.selection {
        let b = doc.getElement(es.path).bounds
        if x >= b.x && x <= b.x + b.width && y >= b.y && y <= b.y + b.height {
            hit = es.path
            break
        }
    }
    let currentKey: ElementPath? = {
        if let dict = store.get("align_key_object_path") as? [String: Any],
           let arr = dict["__path__"] as? [Int] { return arr }
        return nil
    }()
    let pid = "align_panel_content"
    if let p = hit {
        // Toggle: clicking the current key clears it.
        if let ck = currentKey, ck == p {
            store.set("align_key_object_path", NSNull())
            store.setPanel(pid, "key_object_path", NSNull())
        } else {
            let marker: [String: Any] = ["__path__": p]
            store.set("align_key_object_path", marker)
            store.setPanel(pid, "key_object_path", marker)
        }
    } else {
        // Click outside any selected element clears the key.
        store.set("align_key_object_path", NSNull())
        store.setPanel(pid, "key_object_path", NSNull())
    }
    return true
}

/// Clear the key-object path if the previously-designated key is
/// no longer part of the current selection. Call after any
/// selection change to uphold the spec guarantee that selection
/// changes clear a dangling designation automatically. Idempotent
/// — safe to call when no key is designated.
public func syncAlignKeyObjectFromSelection(model: Model, store: StateStore) {
    guard let dict = store.get("align_key_object_path") as? [String: Any],
          let keyPath = dict["__path__"] as? [Int] else { return }
    let stillSelected = model.document.selection.contains {
        $0.path == keyPath
    }
    if !stillSelected {
        store.set("align_key_object_path", NSNull())
        store.setPanel("align_panel_content", "key_object_path", NSNull())
    }
}

/// Build the platform-effects dictionary consumed by
/// `runEffects` when the Align panel fires operation or reset
/// actions. Registered per-call with a captured model reference.
func alignPlatformEffects(model: Model) -> [String: PlatformEffect] {
    let ops = [
        "align_left", "align_horizontal_center", "align_right",
        "align_top", "align_vertical_center", "align_bottom",
        "distribute_left", "distribute_horizontal_center", "distribute_right",
        "distribute_top", "distribute_vertical_center", "distribute_bottom",
        "distribute_vertical_spacing", "distribute_horizontal_spacing",
    ]
    var effects: [String: PlatformEffect] = [
        "snapshot": { _, _, _ in
            model.snapshot()
            return nil
        },
        "reset_align_panel": { _, _, store in
            resetAlignPanel(store: store)
            return nil
        },
    ]
    for op in ops {
        effects[op] = { _, _, store in
            applyAlignOperation(model: model, store: store, op: op)
            return nil
        }
    }
    return effects
}
