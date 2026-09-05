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
    model: Model? = nil,
    actionName: String? = nil,
    diagnostics: inout [Diagnostic]
) {
    // OP_LOG.md §9 (Increment 3b-B): this batch OWNS the journal transaction
    // only if none was open when it started — so a reentrant nested runEffects
    // (let/in, then/else, foreach, dispatch, on_change) does NOT name or commit
    // the outer's transaction. The owner commits once at the end, spanning every
    // effect in this batch into a single undo step. `model` is nil on the
    // resolver-unaware call paths (panels that don't journal, the convenience
    // overload), where this whole bracket is inert. Mirrors Rust's `owns_txn`.
    let ownsTxn = model.map { !$0.isInTxn } ?? false
    // Thread ctx through sibling effects: `let:` extends ctx for
    // subsequent siblings; nested lists (then/else/do) recurse with
    // their own ctx so bindings don't leak back.
    var threadedCtx = ctx
    for effectAny in effects {
        // Bare-string effects (e.g. `- snapshot`, `- close_dialog`) normalize
        // to {name: nil}. Platform handlers take priority; otherwise the
        // effect is re-entered as a dict-form so the built-in cases below
        // (close_dialog, clear_dialog_snapshot, reset, ...) fire. Matches
        // the Python reference interpreter's bare-string normalization.
        var effect: [String: Any]
        if let effectStr = effectAny as? String {
            if let handler = platformEffects[effectStr] {
                _ = handler(NSNull(), threadedCtx, store)
                continue
            }
            effect = [effectStr: NSNull()]
        } else if let dict = effectAny as? [String: Any] {
            effect = dict
        } else {
            continue
        }
        // let: { name: expr, ... } — PHASE3 §5.1
        //
        // Two supported shapes:
        //   Sibling-threading: `let: { x: expr }` without `in:` extends
        //       the context for all later sibling effects in the same list.
        //   Scoped: `let: { x: expr } in: [...]` runs the nested effects
        //       with x bound, then drops the binding. Matches the form
        //       used in workspace/tools/*.yaml (e.g. selection's
        //       `let: { hit: hit_test(...) } in: [...]`).
        if let bindings = effect["let"] as? [String: Any] {
            // Store `.null` bindings as NSNull so the key survives the
            // dict round-trip — `dict[key] = nil` removes the entry,
            // which would make `x == null` fail to resolve downstream.
            func bind(_ extended: inout [String: Any], _ name: String, _ val: Value) {
                if case .closure = val {
                    extended[name] = val
                } else if case .null = val {
                    extended[name] = NSNull()
                } else {
                    extended[name] = valueToAny(val)
                }
            }
            if let inEffects = effect["in"] as? [Any] {
                var extended = threadedCtx
                for (name, exprV) in bindings {
                    let val = evalExpr(exprV, store: store, ctx: extended)
                    bind(&extended, name, val)
                }
                // Nested runEffects (let/in): `model` rides along so an op
                // applied here records into the owner's open transaction, but
                // `actionName: nil` (and `ownsTxn == false` here) keeps naming
                // + commit with the owning batch. OP_LOG.md §9.
                runEffects(inEffects, ctx: extended, store: store,
                           actions: actions, dialogs: dialogs,
                           platformEffects: platformEffects,
                           schema: schema, model: model, actionName: nil,
                           diagnostics: &diagnostics)
                continue
            }
            for (name, exprV) in bindings {
                let val = evalExpr(exprV, store: store, ctx: threadedCtx)
                bind(&threadedCtx, name, val)
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
                // Nested runEffects (foreach body): owner keeps naming/commit.
                runEffects(body, ctx: iterCtx, store: store,
                           actions: actions, dialogs: dialogs,
                           platformEffects: platformEffects,
                           schema: schema, model: model, actionName: nil,
                           diagnostics: &diagnostics)
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
               schema: schema, model: model, diagnostics: &diagnostics)
    }
    // Dialog on_change post-batch hook. Fires the action declared on
    // the open dialog's on_change field whenever this batch mutated
    // dialog state. Per-batch debounced (one fire per UI tick batch).
    // Re-entrancy guarded so the action's effects do not re-fire.
    // See SCALE_TOOL.md §Preview.
    if !store.isFiringOnChange() && store.takeDialogDirty() {
        if let onChangeAction = store.getDialogOnChange() {
            store.setFiringOnChange(true)
            let dispatchEffect: [String: Any] = ["dispatch": onChangeAction]
            // on_change runs inside the owning batch's transaction (model rides
            // along); it does not name/commit (ownsTxn is false in the nested
            // dispatch).
            runOne(dispatchEffect, ctx: threadedCtx, store: store,
                   actions: actions, dialogs: dialogs,
                   platformEffects: platformEffects,
                   schema: schema, model: model, diagnostics: &diagnostics)
            store.setFiringOnChange(false)
        }
    }
    // OP_LOG.md §9 (Increment 3b-B): commit the transaction this batch opened
    // (if any), making the whole action one undo step and stamping it with its
    // action/event verb so the journal's `name=None` legibility hole is closed
    // for ALL actions, not just the three op-journaled verbs. `nameTxn` /
    // `commitTxn` are no-ops if no transaction was opened in this batch (a
    // no-edit gesture stays anonymous), and inert when `model` is nil.
    if ownsTxn, let m = model {
        if let an = actionName { m.nameTxn(an) }
        m.commitTxn()
    }
}

/// Convenience overload for callers that don't need diagnostics. `model` /
/// `actionName` thread the OP_LOG.md §9 journal owner-bracket: the owning batch
/// (a tool gesture or a panel action dispatch) passes the live Model and the
/// gesture/action verb so the production transaction is journaled + named; all
/// other callers default to nil (no journaling, no behavior change).
func runEffects(
    _ effects: [Any],
    ctx: [String: Any],
    store: StateStore,
    actions: [String: Any]? = nil,
    dialogs: [String: Any]? = nil,
    platformEffects: [String: PlatformEffect] = [:],
    model: Model? = nil,
    actionName: String? = nil
) {
    var diags: [Diagnostic] = []
    runEffects(effects, ctx: ctx, store: store, actions: actions, dialogs: dialogs,
               platformEffects: platformEffects, schema: false,
               model: model, actionName: actionName, diagnostics: &diags)
}

/// Run an input/combo widget's `event: commit` behaviors after the native
/// two-way write. The Swift port of Rust `renderer.rs`
/// `run_input_commit_behavior`: it patches the just-committed value into
/// `panel.<field>` and `event.value` in the eval ctx — so effects reading
/// `panel.<field>` see the fresh value rather than the stale render-time
/// snapshot the panel scope was built from — then runs each commit
/// behavior's `effects` through the shared `runEffects` engine (no parallel
/// dispatcher). Scoped to the `commit` event, so `change`-event combos
/// (gradient angle / aspect) are untouched, exactly like Rust. No-op when
/// the widget declares no `commit` behavior. The caller owns the active
/// panel (`set_panel_state` targets it) — the combo hook sets it before
/// calling, and tests set it explicitly.
func runInputCommitBehavior(
    element: [String: Any],
    field: String,
    committed: Any?,
    context: [String: Any],
    store: StateStore,
    model: Model
) {
    guard let behavior = element["behavior"] as? [[String: Any]] else { return }
    let commitBehaviors = behavior.filter {
        ($0["event"] as? String) == "commit"
    }
    if commitBehaviors.isEmpty { return }
    var ctx = context
    if var panelScope = ctx["panel"] as? [String: Any] {
        panelScope[field] = committed
        ctx["panel"] = panelScope
    }
    ctx["event"] = ["value": committed as Any] as [String: Any]
    // Commit behaviors that write stroke render keys (the linked
    // arrowhead-scale mirror's `set` / `set_panel_state`) must re-apply the
    // panel to the selection — exactly as the panel's own commitPanelWrite
    // path does via notifyPanelStateChanged, and as Rust's
    // apply_set_panel_state_with_ctx unconditionally re-applies for the
    // arrowhead-scale keys (renderer.rs ~2042-2048). alignPlatformEffects
    // registers no such hook, so without it the mirror updated the panel /
    // global scopes but the sibling scale never reached the element (it
    // stayed at its stale value while only the edited field applied).
    // Generic: any stroke render-key write through set / set_panel_state
    // re-applies, not a scale-combo special case.
    var platformEffects = alignPlatformEffects(model: model)
    platformEffects["notify_panel_state_changed"] = { arg, _, store in
        if let (panelId, wroteField) = parseNotifyPayload(arg) {
            // Scope the apply to the field the write NAMES, falling back to
            // the field being committed. The linked-scale mirror writes the
            // SIBLING scale, which applies through that field's OWN group
            // (each scale is its own group); attributing it to the committed
            // field applied the wrong group and left the sibling stale.
            notifyPanelStateChanged(panelId, store: store, model: model,
                                    edited: wroteField ?? field)
        }
        return nil
    }
    for entry in commitBehaviors {
        let effects = (entry["effects"] as? [Any]) ?? []
        if !effects.isEmpty {
            runEffects(effects, ctx: ctx, store: store,
                       platformEffects: platformEffects)
        }
    }
}

// MARK: - Internal

/// Route a `set:` target to the right scope in the StateStore.
///
/// Target shapes (leading `$` stripped):
///   `tool.<id>.<key>[.<more>]` → `store.setTool(id, combined_key, value)`
///   `panel.<key>`              → active panel's scope
///   `state.<key>`              → global state (explicit scope)
///   `<key>`                    → global state (implicit scope, legacy)
///
/// Mirrors `set_by_scoped_target` in
/// `jas_dioxus/src/interpreter/effects.rs`.
private func setByScopedTarget(store: StateStore, rawTarget: String, value: Any?) {
    let target: String = rawTarget.hasPrefix("$")
        ? String(rawTarget.dropFirst())
        : rawTarget
    let segs = target.split(separator: ".", maxSplits: 1,
                            omittingEmptySubsequences: false)
        .map(String.init)
    guard let first = segs.first else { return }
    switch first {
    case "tool":
        guard segs.count == 2 else { return }
        let inner = segs[1].split(separator: ".", maxSplits: 1,
                                  omittingEmptySubsequences: false)
            .map(String.init)
        guard inner.count == 2 else { return }
        store.setTool(inner[0], inner[1], value)
    case "panel":
        guard segs.count == 2 else { return }
        if let panelId = store.getActivePanelId() {
            store.setPanel(panelId, segs[1], value)
        }
    case "dialog":
        // Dialog-scope write (e.g. a SCALE/SHEAR radio's on_check
        // `set: { dialog.uniform }`). setDialog no-ops when no dialog
        // is open; these targets only occur in dialog content so that
        // is the correct guard. Without this arm the write fell through
        // to the `default:` branch and landed in the GLOBAL state map
        // under a bogus key "dialog.<key>" that nothing reads back
        // (eval resolves `dialog.*` from the dialog scope), so the
        // radio's mode never switched. Mirrors the Python / Rust /
        // OCaml set_by_scoped_target dialog arm.
        guard segs.count == 2 else { return }
        store.setDialog(segs[1], value)
    case "state":
        guard segs.count == 2 else { return }
        store.set(segs[1], value)
    default:
        store.set(target, value)
    }
}

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
        // See intIfIntegral: the old `n == Double(Int(n))` guard evaluated the
        // trapping cast inside its own predicate (risk R9).
        if let i = intIfIntegral(n) { return i }
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
    model: Model? = nil,
    diagnostics: inout [Diagnostic]
) {
    // set: { key: expr, ... }
    //
    // YAML authors target state scopes via dotted paths with optional
    // `$` prefix: `$tool.selection.mode`, `$state.fill_color`,
    // `$panel.mode`. The non-schema branch strips `$`, then dispatches
    // on the first segment so writes land in the matching store
    // section. Unscoped keys (no leading `state.`/`panel.`/`tool.`)
    // continue to write to the global state map — preserves
    // call-site behavior from before the tool-state scope was
    // introduced.
    if let pairs = effect["set"] as? [String: Any] {
        // Evaluate every right-hand side ONCE, keeping an explicit YAML `null`
        // as `NSNull()` rather than as a Swift `nil`.
        //
        // The distinction cannot survive the store: `StateStore.set(k, nil)`
        // assigns nil into a `[String: Any]`, which DELETES the key, so a
        // write of null and a key nobody ever wrote read back identically.
        // Anything downstream that needs to know which of the two happened
        // must be told here, while the difference still exists — see the
        // colour hook below. The two writer branches unwrap NSNull back to nil
        // before they touch the store, so what the store holds is byte-for-byte
        // what it held before.
        var evaluated: [String: Any] = [:]
        for (key, expr) in pairs {
            evaluated[key] = valueToAny(evalExpr(expr, store: store, ctx: ctx))
                ?? NSNull()
        }
        if schema {
            // Schema-driven: coerce + validate. Null-valued keys were never
            // present in this dict (the old code built it with `nil` values,
            // which a Swift dictionary drops), so filter them back out.
            applySetSchemadriven(evaluated.filter { !($0.value is NSNull) },
                                 store: store, diagnostics: &diagnostics)
        } else {
            for (key, value) in evaluated {
                setByScopedTarget(store: store, rawTarget: key,
                                  value: value is NSNull ? nil : value)
            }
        }
        // Fire the panel-write hook if any `panel.X` key was touched.
        // The schema-driven writer resolves `panel.X` against the
        // active panel; non-schema writes don't touch panel scope.
        // Silent no-op when the host hasn't registered the effect.
        let panelKeys = pairs.keys.filter { $0.hasPrefix("panel.") }
        if !panelKeys.isEmpty,
           let panelId = store.getActivePanelId(),
           let hook = platformEffects["notify_panel_state_changed"] {
            // One notify per written field, each naming its own key so a
            // field-scoped apply writes the right group.
            for k in panelKeys.sorted() {
                _ = hook(notifyPayload(panelId,
                                       field: String(k.dropFirst("panel.".count))),
                         ctx, store)
            }
        }
        // Phase 5 follow-up: gradient_* writes trigger the apply
        // pipeline. Host provides "apply_gradient_panel" in its
        // platformEffects map pointing at applyGradientPanelToSelection.
        let wroteGradient = pairs.keys.contains { isGradientRenderKey($0) }
        if wroteGradient,
           let hook = platformEffects["apply_gradient_panel"] {
            _ = hook("", ctx, store)
        }
        // Active-color writes (set_active_color YAML action et al.)
        // need to propagate to the selected canvas element — the
        // Color Panel does this directly via ColorPanel.setActiveColor;
        // the YAML route writes through set: which lands here. Host
        // registers "apply_active_color" if it wants the propagation.
        //
        // The hook is fired ONCE PER COLOUR KEY WRITTEN, and is handed that
        // key together with the value just written, so it applies exactly the
        // attribute the effect named. It used to fire once, with nothing, and
        // apply whichever attribute `fill_on_top` pointed at after re-reading
        // the store — three ways wrong at once:
        //
        //   * `set_stroke_none` writes stroke_color, but with the fill on top
        //     the hook applied the FILL, so asking for no stroke removed the
        //     fill instead;
        //   * the re-read of a key the effect had just set to null came back
        //     ABSENT (the store deletes on a nil write) and the old code read
        //     absent as "none" — which is also what it read for a key nobody
        //     had ever written;
        //   * `reset_fill_stroke` writes both keys in one `set:` and had only
        //     one of them applied.
        //
        // Rust's `set_app_state_field` has always been called per key with the
        // value in hand; this is Swift agreeing (CPTRIAGE). Sorted so a
        // multi-key write applies in a deterministic order.
        let wroteColorKeys = evaluated.keys
            .filter { colorStateKey($0) != nil }
            .sorted()
        if !wroteColorKeys.isEmpty,
           let hook = platformEffects["apply_active_color"] {
            for key in wroteColorKeys {
                _ = hook(ColorWrite(key: colorStateKey(key)!,
                                    value: evaluated[key]!), ctx, store)
            }
        }
        // Active-tool writes (the tool-alternates flyout's
        // `set: { active_tool }`) must switch the live canvas tool.
        // The store now holds the new tool string; the host registers
        // "apply_active_tool" to mirror it into the native Tool binding
        // (ContentView's currentTool @State). Silent no-op when unset.
        let wroteActiveTool = pairs.keys.contains { $0 == "active_tool" }
        if wroteActiveTool,
           let hook = platformEffects["apply_active_tool"] {
            _ = hook("", ctx, store)
        }
        // Stroke render-key writes also trigger the stroke apply
        // pipeline. The notify hook uses stroke_panel_content as the
        // panel id; notifyPanelStateChanged dispatches to
        // applyStrokePanelToSelection (mirrors OCaml's
        // subscribe_stroke_panel which fires on every stroke_* global
        // write).
        let strokeKeys = pairs.keys.filter { isStrokeRenderKey($0) }
        if !strokeKeys.isEmpty,
           let hook = platformEffects["notify_panel_state_changed"] {
            // One notify per written stroke key, each naming itself: the
            // apply is field-scoped, so the key that changed is the key
            // whose group gets written.
            for k in strokeKeys.sorted() {
                _ = hook(notifyPayload("stroke_panel_content", field: k),
                         ctx, store)
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

    // if: two supported shapes
    //
    //   Flat (tool-YAML authoring convention):
    //     if: "<expr>"
    //     then: [...]
    //     else: [...]
    //
    //   Nested (legacy actions.yaml):
    //     if:
    //       condition: "<expr>"
    //       then: [...]
    //       else: [...]
    //
    // Both accepted so selection.yaml + action fixtures coexist.
    if let ifVal = effect["if"] {
        let condExpr: String
        let thenEffects: [Any]
        let elseEffects: [Any]
        if let s = ifVal as? String {
            condExpr = s
            thenEffects = (effect["then"] as? [Any]) ?? []
            elseEffects = (effect["else"] as? [Any]) ?? []
        } else if let cond = ifVal as? [String: Any] {
            condExpr = cond["condition"] as? String ?? "false"
            thenEffects = (cond["then"] as? [Any]) ?? []
            elseEffects = (cond["else"] as? [Any]) ?? []
        } else {
            return
        }
        let evalCtx = store.evalContext(extra: ctx)
        let result = evaluate(condExpr, context: evalCtx)
        if result.toBool() {
            if !thenEffects.isEmpty {
                // Nested branch: model rides along (ops join the owner's txn);
                // actionName: nil so the owner names/commits. OP_LOG.md §9.
                runEffects(thenEffects, ctx: ctx, store: store,
                           actions: actions, dialogs: dialogs,
                           platformEffects: platformEffects,
                           schema: schema, model: model, actionName: nil,
                           diagnostics: &diagnostics)
            }
        } else if !elseEffects.isEmpty {
            runEffects(elseEffects, ctx: ctx, store: store,
                       actions: actions, dialogs: dialogs,
                       platformEffects: platformEffects,
                       schema: schema, model: model, actionName: nil,
                       diagnostics: &diagnostics)
        }
        return
    }

    // select: { target, list, scope, scope_value, mode } — generic
    // tile-selection effect for swatch / brush / row panels. Plain
    // click replaces panel.{list} with [target] and resets
    // panel.{scope} to scope_value. Mode "auto" reads
    // event.shift / event.ctrl / event.meta from the click ctx for
    // shift-extend / ctrl-toggle behaviors. Mirrors the Rust
    // apply_select_effect.
    if let spec = effect["select"] as? [String: Any] {
        applySelectEffect(spec, ctx: ctx, store: store)
        return
    }

    // set_panel_state: { key, value, panel? }
    if let sps = effect["set_panel_state"] as? [String: Any] {
        let key = sps["key"] as? String ?? ""
        let value = evalExpr(sps["value"], store: store, ctx: ctx)
        let writtenPanel: String?
        if let rawPanelId = sps["panel"] as? String {
            // YAML actions name panels by their short kind ("swatches",
            // "color", "stroke"); the store canonicalises every spelling
            // to the content id at its boundary (`StateStore.panelContentId`),
            // so this write and a native verb's write on the short name
            // land in ONE bucket. The rule used to live here alone, which
            // is how the artboards selection came to have two.
            let panelId = StateStore.panelContentId(rawPanelId)
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
            _ = hook(notifyPayload(name, field: key), ctx, store)
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
            // The action's `effects:` is a heterogeneous YAML list — bare
            // string entries (`- snapshot`) coexist with map entries
            // (`- align_left: true`, `- dispatch: ...`). The previous
            // `as? [[String: Any]]` cast required every element to be a
            // dict and silently produced an empty array on mixed lists,
            // which is why dispatching the Align panel actions did
            // nothing despite resolving correctly.
            let actionEffects = actionDef["effects"] as? [Any] ?? []
            var dispatchCtx = ctx
            if !params.isEmpty {
                var resolved: [String: Any] = [:]
                for (k, v) in params {
                    let val = evalExpr(v, store: store, ctx: ctx)
                    if let any = valueToAny(val) {
                        resolved[k] = any
                    } else if let exprStr = v as? String {
                        // Bare-identifier convention used in YAML params
                        // like `{ target: artboard }`: when the
                        // expression evaluates to null, treat the raw
                        // string as a literal so the value flows through.
                        // Without this, dispatch param resolution dropped
                        // bare-identifier values and downstream
                        // `param.<key>` reads silently became nil.
                        resolved[k] = exprStr
                    }
                }
                dispatchCtx["param"] = resolved
            }
            // OP_LOG.md §9: name the transaction with the dispatched
            // actions.yaml verb. If this dispatch is the owner (no outer
            // transaction open), the inner runEffects' owner-bracket stamps the
            // verb; if it is nested under an outer owner, that bracket sees
            // ownsTxn == false and skips, so the outer owner names it.
            runEffects(actionEffects, ctx: dispatchCtx, store: store, actions: actions, dialogs: dialogs,
                       platformEffects: platformEffects,
                       schema: schema, model: model, actionName: actionName,
                       diagnostics: &diagnostics)
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

        // Extract per-state get / set props so dialog widget edits
        // route through the YAML setters (color picker channel
        // setters: `fun v -> color <- hsb(v, ...)`). Without this,
        // typing into H / S / B fields wrote h=N directly into the
        // dialog state map but never updated `color`, and the next
        // re-render evaluated `dialog.h` against the stored map
        // — which had no `h` entry, so the field snapped back to 0.
        var props: [String: [String: Any]] = [:]
        for (key, defn) in stateDefs {
            guard let d = defn as? [String: Any] else { continue }
            var p: [String: Any] = [:]
            if let g = d["get"] { p["get"] = g }
            if let s = d["set"] { p["set"] = s }
            if !p.isEmpty { props[key] = p }
        }
        // Init dialog
        store.initDialog(dlgId, defaults: defaults,
                         params: resolvedParams.isEmpty ? nil : resolvedParams,
                         props: props.isEmpty ? nil : props)

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
        // Document-level preview snapshot for transform-tool dialogs
        // (Scale Options / Rotate Options / Shear Options). Fired
        // through the doc.preview.capture platform effect to avoid
        // a direct Model handle in the interpreter.
        // See SCALE_TOOL.md §Preview.
        if let docPreview = dlgDef["doc_preview"] as? Bool, docPreview {
            if let cap = platformEffects["doc.preview.capture"] {
                _ = cap([:], ctx, store)
            }
        }
        // Wire the dialog's on_change action — fired by runEffects
        // after any batch that mutated dialog state.
        store.setDialogOnChange(dlgDef["on_change"] as? String)
        // Clear any leftover dirty flag from prior dialog sessions.
        _ = store.takeDialogDirty()
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
        // Document-level preview restore (Cancel path). Fired through
        // platform effects; the platform side is responsible for
        // checking has_preview_snapshot before doing work.
        if let restore = platformEffects["doc.preview.restore"] {
            _ = restore([:], ctx, store)
        }
        if let clear = platformEffects["doc.preview.clear"] {
            _ = clear([:], ctx, store)
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

/// Rendering-affecting stroke state keys — the flat GLOBAL spellings, which
/// are what a `set:` effect writes. Mirrors the reference
/// `STROKE_RENDER_KEYS` (effects.py) key for key.
///
/// Two of them used to be spellings nothing in workspace/ ever writes:
/// `stroke_weight` (the weight global is `stroke_width`) and
/// `stroke_align_stroke` (the align global is `stroke_align`). Both are
/// written by `reset_fill_stroke` and by the panel's own align buttons, so
/// the apply simply never fired for them.
private let strokeRenderKeys: Set<String> = [
    "stroke_cap", "stroke_join", "stroke_width", "stroke_miter_limit",
    "stroke_dashed", "stroke_dash_1", "stroke_gap_1",
    "stroke_dash_2", "stroke_gap_2", "stroke_dash_3", "stroke_gap_3",
    "stroke_dash_align_anchors",
    "stroke_align", "stroke_start_arrowhead", "stroke_end_arrowhead",
    "stroke_start_arrowhead_scale", "stroke_end_arrowhead_scale",
    "stroke_arrow_align", "stroke_profile", "stroke_profile_flipped",
]

/// Apply ONE Stroke-panel edit to the selected element(s).
///
/// `edited` is the panel field key the user just committed (`"cap"`,
/// `"end_arrowhead"`, `"weight"`, … — or the flat `"stroke_cap"` global
/// form). Only that field's ``StrokeEditGroup`` is taken from panel state;
/// every other stroke attribute is preserved from the element being
/// edited, per element. It is REQUIRED: a caller that cannot name the
/// field it committed has nothing to apply, and defaulting it to nil made
/// a forgotten argument a silent no-op (Rust's is required too).
///
/// Why field-scoped: this used to rebuild the whole Stroke from panel
/// state on every edit and take `width` from the panel `weight` key
/// (stale until the weight input is committed), so picking an arrowhead on
/// a selected 5pt line snapped it back to 1pt (JYH, 2026-07-24). Cap /
/// join were the same shape — the panel DISPLAYS them from the selected
/// element via `strokePanelLiveOverrides`, so re-imposing panel state on
/// an unrelated edit contradicted what the user saw — and the dash /
/// arrowhead / profile groups were re-stamped from stale panel state on
/// every edit. Gating the width write to the weight edit removes the
/// ordering problem entirely: nothing else reads the committed weight, so
/// nothing else can clobber the element's own width. Mirrors the Rust
/// reference `apply_stroke_panel_to_selection` (app_state.rs).
func applyStrokePanelToSelection(
    store: StateStore, controller: Controller, edited: String
) {
    guard let group = StrokeEditGroup.fromField(edited) else { return }
    let doc = controller.model.document
    let selStroke = doc.selection.first
        .flatMap { doc.tryGetElement($0.path) }
        .flatMap { $0.stroke }
    let defaultStroke = controller.model.defaultStroke
    // Nothing to build on: no selected stroke and no default.
    guard let fallback = selStroke ?? defaultStroke else { return }
    // The weight input's committed value lives in the panel scope (the
    // length_input commits it there via commitPanelWrite). Read ONLY for a
    // weight edit; numeric values arrive as Int / Double / NSNumber
    // depending on the commit path, which strokePanelNumber covers.
    // Rust reads the same panel-committed value from `StrokePanelState.weight`
    // (STROKEWIDTH repair 3 gave it a real field; it used to read the tab /
    // app default stroke width, which made a weight edit a silent no-op when
    // there was no default while this port applied it).
    let committedWidth = strokePanelNumber(store, "weight")
        ?? defaultStroke?.width
        ?? fallback.width
    if !doc.selection.isEmpty {
        // Width profiles are re-derived only when the edit can change
        // them: the profile shape / flip, or the weight they scale with.
        let profileEdit = group == .width || group == .profile
        let profileWidth = group == .width
            ? committedWidth
            : (selStroke?.width ?? committedWidth)
        // Stroke + width-profile as ONE undo step: withTxn opens the
        // bracket, each Controller mutator's editDocument joins it.
        controller.model.withTxn {
            controller.mapSelectionStroke { elStroke in
                strokeWithGroup(elStroke ?? fallback, store: store, group: group,
                                committedWidth: committedWidth)
            }
            if profileEdit {
                let profile = strokePanelField(store, "profile") as? String ?? "uniform"
                let flipped = strokePanelField(store, "profile_flipped") as? Bool ?? false
                controller.setSelectionWidthProfile(profileToWidthPoints(
                    profile: profile, width: profileWidth, flipped: flipped))
            }
        }
    }
    // The new-element default takes the SAME field-scoped edit, built on
    // the default stroke — never on the selected element, whose width /
    // colour must not leak into what the next element gets.
    controller.model.defaultStroke = strokeWithGroup(
        defaultStroke ?? fallback, store: store, group: group,
        committedWidth: committedWidth)
}

/// Sync stroke panel state from the first selected element's stroke.
///
/// Writes the flat GLOBAL spellings (`stroke_width`, `stroke_align`), the
/// same ones `strokePanelField` reads back and `set:` effects write. It used
/// to write `stroke_weight` / `stroke_align_stroke`, which nothing read.
func syncStrokePanelFromSelection(store: StateStore, controller: Controller) {
    let doc = controller.model.document
    guard let first = doc.selection.first else { return }
    guard let el = doc.tryGetElement(first.path), let s = el.stroke else { return }

    store.set("stroke_cap", s.linecap == .butt ? "butt" : s.linecap == .round ? "round" : "square")
    store.set("stroke_join", s.linejoin == .miter ? "miter" : s.linejoin == .round ? "round" : "bevel")
    store.set("stroke_width", s.width)
    store.set("stroke_miter_limit", s.miterLimit)
    let alignStr: String
    switch s.align { case .center: alignStr = "center"; case .inside: alignStr = "inside"; case .outside: alignStr = "outside" }
    store.set("stroke_align", alignStr)
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
    store.set("stroke_dash_align_anchors", s.dashAlignAnchors)
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

// MARK: - Gradient panel render-key predicate (Phase 5 follow-up)

public let gradientRenderKeys: Set<String> = [
    "gradient_type", "gradient_angle", "gradient_aspect_ratio",
    "gradient_method", "gradient_dither", "gradient_stroke_sub_mode",
]

public func isGradientRenderKey(_ key: String) -> Bool {
    gradientRenderKeys.contains(key)
}


// MARK: - Gradient panel writeback (Phase 5)

/// Apply the current gradient panel state to the selected element(s).
/// Builds a Gradient from store keys and writes it via the controller.
/// Mirrors jas_dioxus::AppState::apply_gradient_panel_to_selection.
public func applyGradientPanelToSelection(store: StateStore, controller: Controller) {
    let typeStr = (store.get("gradient_type") as? String) ?? "linear"
    let gType: GradientType
    switch typeStr {
    case "radial": gType = .radial
    case "freeform": gType = .freeform
    default: gType = .linear
    }
    let methodStr = (store.get("gradient_method") as? String) ?? "classic"
    let gMethod: GradientMethod
    switch methodStr {
    case "smooth": gMethod = .smooth
    case "points": gMethod = .points
    case "lines": gMethod = .lines
    default: gMethod = .classic
    }
    let subStr = (store.get("gradient_stroke_sub_mode") as? String) ?? "within"
    let gSub: StrokeSubMode
    switch subStr {
    case "along": gSub = .along
    case "across": gSub = .across
    default: gSub = .within
    }
    let g = Gradient(
        type: gType,
        angle: (store.get("gradient_angle") as? Double) ?? 0,
        aspectRatio: (store.get("gradient_aspect_ratio") as? Double) ?? 100,
        method: gMethod,
        dither: (store.get("gradient_dither") as? Bool) ?? false,
        strokeSubMode: gSub
        // Stops are panel-local working state; Phase 5 follow-up wires
        // panel.stops <-> store.gradient_stops binding. For the
        // foundation, an empty stops list still applies the type /
        // angle / etc.
    )
    let fillOnTop = (store.get("fill_on_top") as? Bool) ?? true
    if fillOnTop {
        controller.setSelectionFillGradient(g)
    } else {
        controller.setSelectionStrokeGradient(g)
    }
    store.set("gradient_preview_state", false)
}

/// Demote the selection's active-attribute gradient back to a solid.
/// The underlying solid Fill / Stroke value is left untouched.
public func demoteGradientPanelSelection(store: StateStore, controller: Controller) {
    let fillOnTop = (store.get("fill_on_top") as? Bool) ?? true
    if fillOnTop {
        controller.setSelectionFillGradient(nil)
    } else {
        controller.setSelectionStrokeGradient(nil)
    }
}

// MARK: - Gradient panel state binding (Phase 4: read direction)

/// Sync gradient panel state from the selection's active attribute
/// (fill or stroke per `state.fill_on_top`). Mirrors
/// jas_dioxus::AppState::sync_gradient_panel_from_selection.
///
/// Behavior per GRADIENT.md §Multi-selection and §Fill-type coupling:
///   - Empty selection: leave panel state alone (session defaults).
///   - Uniform with gradient: populate panel fields from the shared
///     gradient on the active attribute.
///   - Mixed (different gradients across selection, or some gradient
///     and some solid/none): leave panel fields alone; the renderer
///     handles blank-vs-uniform display per the multi-selection table.
///   - Uniform without gradient (solid/none on every selected
///     element's active attribute): seed a preview gradient (first
///     stop = current solid color, second stop = white) and set
///     `gradient_preview_state = true`. First edit (Phase 5) will
///     materialise this onto the elements.
public func syncGradientPanelFromSelection(store: StateStore, controller: Controller) {
    let doc = controller.model.document
    if doc.selection.isEmpty { return }

    let fillOnTop = (store.get("fill_on_top") as? Bool) ?? true

    var first: Gradient? = nil
    var firstSet = false
    var mixed = false
    var firstSolidColor: Color? = nil
    for es in doc.selection {
        guard let elem = doc.tryGetElement(es.path) else { continue }
        let g = fillOnTop ? elem.fillGradient : elem.strokeGradient
        if firstSolidColor == nil && g == nil {
            let solid = fillOnTop ? elem.fill?.color : elem.stroke?.color
            firstSolidColor = solid
        }
        if !firstSet {
            first = g
            firstSet = true
        } else if first != g {
            mixed = true
        }
    }
    if mixed {
        store.set("gradient_preview_state", false)
        return
    }
    if let g = first {
        let typeStr: String
        switch g.type {
        case .linear: typeStr = "linear"
        case .radial: typeStr = "radial"
        case .freeform: typeStr = "freeform"
        }
        let methodStr: String
        switch g.method {
        case .classic: methodStr = "classic"
        case .smooth: methodStr = "smooth"
        case .points: methodStr = "points"
        case .lines: methodStr = "lines"
        }
        let subModeStr: String
        switch g.strokeSubMode {
        case .within: subModeStr = "within"
        case .along: subModeStr = "along"
        case .across: subModeStr = "across"
        }
        store.set("gradient_type", typeStr)
        store.set("gradient_angle", g.angle)
        store.set("gradient_aspect_ratio", g.aspectRatio)
        store.set("gradient_method", methodStr)
        store.set("gradient_dither", g.dither)
        store.set("gradient_stroke_sub_mode", subModeStr)
        store.set("gradient_stops_count", Double(g.stops.count))
        store.set("gradient_preview_state", false)
        return
    }
    // Uniform without gradient — seed preview gradient.
    let seedHex: String
    if let c = firstSolidColor {
        seedHex = "#" + c.toHex()
    } else {
        seedHex = "#000000"
    }
    store.set("gradient_type", "linear")
    store.set("gradient_angle", 0.0)
    store.set("gradient_aspect_ratio", 100.0)
    store.set("gradient_method", "classic")
    store.set("gradient_dither", false)
    store.set("gradient_stroke_sub_mode", "within")
    // Seed first stop at the solid color, second stop white.
    store.set("gradient_seed_first_color", seedHex)
    store.set("gradient_preview_state", true)
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
    // Super/sub on a range can't ride as a "super"/"sub" keyword on
    // the tspan (Tspan.baselineShift is Double pt only), so encode the
    // same visual the canvas applies at element level: shrink fontSize
    // to 70%, shift baseline by ±35%/20% of the parent fontSize.
    // Numeric baseline_shift wins when super/sub is off.
    let superOn = panel["superscript"] as? Bool ?? false
    let subOn = panel["subscript"] as? Bool ?? false
    let bsNum = (panel["baseline_shift"] as? NSNumber)?.doubleValue ?? 0.0
    let effFontSize: Double = (superOn || subOn) ? fontSize * 0.7 : fontSize
    // CoreText draws our text with a flipped textMatrix, so positive
    // baselineOffset visually moves DOWN — encode super as a negative
    // shift (up) and sub as positive (down) so the panel buttons map
    // to the right direction. Numeric baseline_shift uses the same
    // convention (positive = up at the element level, mapped through
    // the same path).
    // Full overrides always carry a concrete baseline_shift when
    // super/sub is off (mirrors Rust build_panel_full_overrides, which
    // writes Some(cp.baseline_shift) unconditionally in that case);
    // a 0.0 value is meaningful — it explicitly clears any prior shift
    // on the range rather than leaving it untouched.
    let baselineShift: Double? = {
        if superOn { return -fontSize * 0.35 }
        if subOn { return fontSize * 0.20 }
        return -bsNum
    }()
    // Anti-aliasing → jas_aa_mode. "Sharp" / empty are the defaults.
    let aaRaw = (panel["anti_aliasing"] as? String) ?? "Sharp"
    let aaMode = (aaRaw == "Sharp" || aaRaw.isEmpty) ? "" : aaRaw
    return Tspan(
        id: 0, content: "",
        baselineShift: baselineShift,
        fontFamily: fontFamily, fontSize: effFontSize,
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

/// Push the Character panel state to the selected text element(s) —
/// FIELD-SCOPED.
///
/// `edited` names the panel field the user just committed. Only the
/// `CharacterEditGroup` that field owns is taken from panel state; every
/// other character attribute is preserved from the element being edited, per
/// element. A field that owns no element attribute (the seven `snap_*` flags,
/// the section-visibility flags) writes NOTHING — not even an undo step.
///
/// This is the law because the panel is not a picture of the selection:
/// nudging Tracking on a 30pt bold italic underlined Georgia run used to
/// reset it to the panel's 12pt sans-serif defaults — sixteen attributes
/// clobbered by one edit. The panel view's live-override push
/// (`commitPanelWrite`) mitigated that for edits arriving through the panel
/// widgets, but it is not the same thing as a field-scoped apply: it does
/// nothing for the per-range route or for any caller that applies without
/// going through the view. See `transcripts/CHARACTER.md` "The field-scoped
/// apply law"; the reference states the field → group table in
/// `workspace_interpreter/character_law.py`.
func applyCharacterPanelToSelection(
    store: StateStore, controller: Controller, edited: String
) {
    // A field owning no element attribute must not reach the document.
    guard let group = CharacterEditGroup.fromField(edited) else { return }
    applyCharacterPanelGroupToSelection(store: store, controller: controller,
                                        group: group)
}

private func applyCharacterPanelGroupToSelection(
    store: StateStore, controller: Controller, group: CharacterEditGroup
) {
    // Caret-only edit session: prime the session's pending override so
    // the next-typed character picks up the new attrs, then return
    // WITHOUT rewriting the element. A bare caret has no character range
    // to restyle, so the panel click is purely "set the next-typed
    // style"; the existing text in the element is left untouched.
    // Mirrors Rust apply_character_panel_to_selection's caret route,
    // which returns early after priming the pending override.
    if let session = controller.model.currentEditSession,
       !session.hasSelection {
        var p = store.getPanelState("character_panel_content")
        let doc = controller.model.document
        if pathIsValid(doc, session.path) {
            let elem = doc.getElement(session.path)
            // The group's SIBLING fields come from the element here too (see
            // characterPanelWithElementSiblings), so priming the next-typed
            // character cannot drop a decoration token the element has.
            // Restricting the template to the edited group is banked in
            // CHARACTER.md's follow-ups: replacing the WHOLE template is this
            // route's existing semantic.
            if let base = CharacterAttrs(element: elem) {
                p = characterPanelWithElementSiblings(p, base: base, group: group)
            }
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
        // A group with no tspan-level representation can express nothing on a
        // range, so it must not push an undo step that changes nothing — the
        // same clause a UI-only field gets.
        if !group.writesTspanField { return }
        var p = store.getPanelState("character_panel_content")
        let doc = controller.model.document
        if pathIsValid(doc, session.path) {
            let elem = doc.getElement(session.path)
            let (lo, hi) = session.selectionRange
            // Field-scoped here too: build the panel's override template,
            // then clear every field outside the edited group so
            // mergeTspanOverrides leaves the range's other attributes alone.
            // Without the restriction a Tracking edit on a selected range
            // stamped the panel's family / size / weight / decoration over
            // it — the same clobber as the whole-element route. The edited
            // group's SIBLING fields come from the ELEMENT, never from panel
            // state (characterPanelWithElementSiblings).
            if let base = CharacterAttrs(element: elem) {
                p = characterPanelWithElementSiblings(p, base: base, group: group)
            }
            let overrides = restrictTspanOverrides(buildPanelFullOverrides(p),
                                                   to: group)
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
                // controller.setDocument -> editDocument self-brackets one step.
                controller.setDocument(doc.replaceElement(session.path, with: ne))
            }
            return
        }
    }

    // Whole-element route. PER ELEMENT: the group's attributes come from
    // panel state and every other attribute is lifted from THIS element, so
    // a multi-element selection keeps each element's own values (and the
    // Leading group's Auto test reads each element's own font size).
    // setSelectionTextAttributes -> editDocument self-brackets one undo step,
    // and is a no-op when nothing in the selection is text.
    if !controller.model.document.selection.isEmpty {
        controller.setSelectionTextAttributes(perElement: { elem in
            guard let base = CharacterAttrs(element: elem) else { return [:] }
            return characterAttrsForGroup(base, store: store, group: group)
        })
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
        guard let el = doc.tryGetElement(es.path) else { return nil }
        switch el {
        case .text, .textPath: return es.path
        default: return nil
        }
    }
    if targetPaths.isEmpty { return }
    // controller.setDocument below -> editDocument self-brackets one undo step.
    var newDoc = doc
    for path in targetPaths {
        let elem = newDoc.getElement(path)
        let newElem: Element?
        switch elem {
        case .text(let t):
            var tspans = t.tspans
            // Insert empty wrapper (or repair a wrapper that has
            // accidentally accumulated body content) — see
            // `ensureParagraphWrapper` for rationale.
            let wrapperIdx = ensureParagraphWrapper(&tspans)
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
            let wrapperIdx = ensureParagraphWrapper(&tspans)
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
        guard let el = doc.tryGetElement(es.path) else { return nil }
        switch el {
        case .text, .textPath: return es.path
        default: return nil
        }
    }
    if targetPaths.isEmpty { return }
    // controller.setDocument below -> editDocument self-brackets one undo step.
    var newDoc = doc
    for path in targetPaths {
        let elem = newDoc.getElement(path)
        let newElem: Element?
        switch elem {
        case .text(let t):
            var tspans = t.tspans
            let wrapperIdx = ensureParagraphWrapper(&tspans)
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
            let wrapperIdx = ensureParagraphWrapper(&tspans)
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
        guard let el = doc.tryGetElement(es.path) else { return nil }
        switch el {
        case .text, .textPath: return es.path
        default: return nil
        }
    }
    if targetPaths.isEmpty { return }
    // controller.setDocument below -> editDocument self-brackets one undo step.
    var newDoc = doc
    for path in targetPaths {
        let elem = newDoc.getElement(path)
        let newElem: Element?
        switch elem {
        case .text(let t):
            var tspans = t.tspans
            let wrapperIdx = ensureParagraphWrapper(&tspans)
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
            let wrapperIdx = ensureParagraphWrapper(&tspans)
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

/// The payload the `notify_panel_state_changed` platform effect carries.
///
/// Either a bare panel id (the caller does not know which field changed) or
/// `["panel": id, "field": key]` when it does. The FIELD matters: the Stroke
/// panel's apply is field-scoped, so a write must be attributed to the key
/// it actually wrote — the linked arrowhead-scale mirror writes the SIBLING
/// scale, and blaming the committed field instead applied the wrong group.
/// Mirrors Rust's `apply_set_panel_state_with_ctx`, which re-applies with
/// its own `key`.
public func notifyPayload(_ panelId: String, field: String?) -> Any {
    guard let field else { return panelId }
    return ["panel": panelId, "field": field]
}

/// Unpack a `notify_panel_state_changed` payload into (panel id, field).
public func parseNotifyPayload(_ arg: Any?) -> (panel: String, field: String?)? {
    if let s = arg as? String { return (s, nil) }
    if let d = arg as? [String: Any], let p = d["panel"] as? String {
        return (p, d["field"] as? String)
    }
    return nil
}

/// Dispatch a panel-state change to the matching apply-to-selection
/// pipeline. Called after any widget write-back or `set: panel.X`
/// batch so the downstream surface (selected element, other views)
/// re-syncs. Silent no-op for panels without a subscriber.
///
/// `edited` names the panel field that just changed. The Stroke panel's
/// apply is field-scoped — it writes only that field's group and preserves
/// the rest from the element — so callers that know the key must pass it;
/// see `applyStrokePanelToSelection`.
///
/// `terminal` says the write is a finished edit (slider pointer-up, Enter or
/// blur in a value box) rather than a live drag tick. Only the Color branch
/// reads it: the two arms are `setActiveColor` (one undo step, pushes to the
/// recent strip, writes the app tier) and `setActiveColorLive`. Every other
/// panel's apply is the same either way, so they ignore it.
public func notifyPanelStateChanged(
    _ panelId: String, store: StateStore, model: Model, edited: String? = nil,
    terminal: Bool = false
) {
    switch panelId {
    case "character_panel_content":
        // Without a named field there is nothing to apply: the Character
        // apply is field-scoped, and guessing which control changed is
        // exactly what clobbered the element's font, size and decoration.
        if let edited {
            // Auto-leading is a DISPLAY concern, and it runs BEFORE the apply
            // — the same position Rust gives it (`set_character_field` →
            // `character_panel_post_write` → `apply_character_panel_to_
            // selection`, renderer.rs). It only ever rewrites stored
            // `leading`, which the FONT_SIZE group does not read, so the
            // order is observable in panel state and nowhere else.
            characterPanelPostWrite(store: store, model: model, key: edited)
            applyCharacterPanelToSelection(
                store: store, controller: Controller(model: model),
                edited: edited)
        }
    case "paragraph_panel_content":
        applyParagraphPanelToSelection(store: store, controller: Controller(model: model))
    case "stroke_panel_content":
        // Without a named field there is nothing to apply: the Stroke
        // apply is field-scoped, and guessing which control changed is
        // exactly what clobbered the element's width.
        if let edited {
            applyStrokePanelToSelection(store: store,
                                        controller: Controller(model: model),
                                        edited: edited)
        }
    case "color_panel_content":
        // Hex / sliders / mode all write to the same panel state; re-derive the
        // colour through ``colorPanelWriteColor`` — the store's channels with
        // the active paint's own channels overlaid, minus the one just edited —
        // and apply it. `terminal` picks the arm: a drag tick applies LIVE (no
        // push to recent, so dragging doesn't churn the strip), a pointer-up /
        // Enter commits (one undo step, pushes to recent, writes the app tier).
        //
        // Rust's twin is `compute_color_from_panel` over `ctx.get("panel")`,
        // with `set_active_color_live` on `oninput` and `set_active_color` on
        // `onchange` (renderer.rs render_slider / render_number_input).
        if let color = colorPanelWriteColor(store: store, model: model,
                                            edited: edited) {
            if terminal {
                ColorPanel.setActiveColor(color, model: model)
            } else {
                ColorPanel.setActiveColorLive(color, model: model)
            }
        }
    default:
        break
    }
}

/// Format a number for CSS length / value output: integers have no
/// decimal, fractions drop trailing zeros. Matches the Rust
/// `fmt_num` helper.
/// Internal rather than private so `R9GuardedCastTests` can hold it to that
/// mirror. (A verbatim second copy of CharacterPanelSync's `fmtNum`.)
func _fmtNum(_ n: Double) -> String {
    // saturatingInt mirrors Rust's `n as i64` — see fmtNum (risk R9).
    if n == n.rounded(.towardZero) {
        return String(saturatingInt(n))
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
/// Apply a `select: { target, list, scope, scope_value, mode }` effect
/// to the active panel's state. Used by tile-style panels (swatches,
/// brushes) for click-to-select semantics with optional shift / ctrl
/// modifiers. Writes through `store.setPanel(activePanelId, ...)`;
/// mirrors the Rust `apply_select_effect`.
public func applySelectEffect(_ spec: [String: Any], ctx: [String: Any], store: StateStore) {
    guard let panelId = store.getActivePanelId() else { return }
    let listField = spec["list"] as? String ?? ""
    guard !listField.isEmpty else { return }
    let scopeField = spec["scope"] as? String ?? ""
    let mode = spec["mode"] as? String ?? "auto"

    let target = valueToAny(evalExpr(spec["target"], store: store, ctx: ctx))
    let scopeValue = valueToAny(evalExpr(spec["scope_value"], store: store, ctx: ctx))

    // Read modifier state from the event ctx for mode "auto".
    let event = ctx["event"] as? [String: Any]
    let shift = (event?["shift"] as? Bool) ?? false
    let ctrlOrMeta = ((event?["ctrl"] as? Bool) ?? false)
        || ((event?["meta"] as? Bool) ?? false)
    let effectiveMode: String
    switch mode {
    case "auto":
        if shift { effectiveMode = "extend" }
        else if ctrlOrMeta { effectiveMode = "toggle" }
        else { effectiveMode = "single" }
    default: effectiveMode = mode
    }

    // Scope check — clicking into a different scope clears and resets.
    if !scopeField.isEmpty {
        let curScope = store.getPanel(panelId, scopeField)
        if !anyEqual(curScope, scopeValue) {
            store.setPanel(panelId, scopeField, scopeValue)
            store.setPanel(panelId, listField, [target as Any])
            return
        }
    }

    let curList = (store.getPanel(panelId, listField) as? [Any]) ?? []
    let newList: [Any]
    switch effectiveMode {
    case "toggle":
        if curList.contains(where: { anyEqual($0, target) }) {
            newList = curList.filter { !anyEqual($0, target) }
        } else {
            newList = curList + [target as Any]
        }
    case "extend":
        if let anchor = curList.first, let a = anchor as? Int, let t = target as? Int {
            let lo = min(a, t), hi = max(a, t)
            newList = (lo...hi).map { $0 as Any }
        } else if let anchorN = (curList.first as? NSNumber)?.intValue,
                  let targetN = (target as? NSNumber)?.intValue {
            let lo = min(anchorN, targetN), hi = max(anchorN, targetN)
            newList = (lo...hi).map { $0 as Any }
        } else {
            newList = [target as Any]
        }
    default: newList = [target as Any]
    }
    store.setPanel(panelId, listField, newList)
}

/// Loose equality for `Any` values used in select-effect comparisons —
/// covers the common types stored in panel state (strings, ints, doubles,
/// bools, NSNull).
private func anyEqual(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (is NSNull, is NSNull): return true
    case (let x as String, let y as String): return x == y
    case (let x as Bool, let y as Bool): return x == y
    case (let x as Int, let y as Int): return x == y
    case (let x as Double, let y as Double): return x == y
    case (let x as NSNumber, let y as NSNumber): return x == y
    default: return false
    }
}

/// One app-level colour write, as handed to the `apply_active_color` hook.
///
/// A struct rather than a dictionary so the key cannot be misspelled and the
/// `value`'s "NSNull means the user chose None" convention has one documented
/// home. `value` is the EVALUATED right-hand side of the `set:` pair — a hex
/// string, or `NSNull()` for an explicit null.
public struct ColorWrite {
    /// `"fill_color"` or `"stroke_color"`.
    public let key: String
    /// Hex string, or `NSNull()` for "no paint".
    public let value: Any
    public init(key: String, value: Any) {
        self.key = key
        self.value = value
    }
}

/// The app-level colour key a `set:` target names, or nil when it names
/// something else. Accepts the scoped spellings a YAML author may write
/// (`$state.fill_color`, `state.fill_color`) alongside the bare global, matching
/// what ``setByScopedTarget`` actually writes.
func colorStateKey(_ rawTarget: String) -> String? {
    var t = rawTarget
    if t.hasPrefix("$") { t = String(t.dropFirst()) }
    if t.hasPrefix("state.") { t = String(t.dropFirst("state.".count)) }
    return (t == "fill_color" || t == "stroke_color") ? t : nil
}

/// Apply ONE app-level colour write to both default tiers and the selection.
///
/// This is the propagation half of `set: { fill_color: … }` — the store holds
/// the value for expressions to read, and the paint has to reach the document.
/// Used by the `apply_active_color` platform-effect hook, so the YAML
/// `set_active_color` / `set_fill_none` / `set_stroke_none` /
/// `reset_fill_stroke` actions all land. Mirrors the inline behavior of
/// `ColorPanel.setActiveColor` and, key-for-key, the Rust
/// `set_app_state_field` `"fill_color"` / `"stroke_color"` arms.
///
/// The attribute comes from `write.key` — the key the effect WROTE. It used to
/// come from `fill_on_top`, which answers a different question (which swatch
/// the user is editing), and the value used to be re-read from the store, which
/// cannot report an explicit null. See the `apply_active_color` fan-out in
/// ``runOne`` for what that cost (CPTRIAGE).
public func applyActiveColorWrite(model: Model, write: ColorWrite) {
    let ctrl = Controller(model: model)
    let isFill = write.key == "fill_color"
    let color: Color? = (write.value as? String).flatMap(Color.fromHex)
    if color == nil && !(write.value is NSNull) {
        // Neither a parseable colour nor an explicit null — say nothing rather
        // than clear the paint. Matches Rust's "unparseable hex: leave
        // everything alone" arm.
        return
    }
    if isFill {
        if let color = color {
            // Colour-ONLY, exactly like ColorPanel.setActiveColor: the
            // element's fill opacity is preserved (STROKEWIDTH).
            model.appDefaultFill = ColorPanel.recolorFill(model.appDefaultFill, color)
            model.defaultFill = ColorPanel.recolorFill(model.defaultFill, color)
            if !model.document.selection.isEmpty {
                ctrl.mapSelectionFill { ColorPanel.recolorFill($0, color) }
            }
        } else {
            // BOTH tiers, as Rust's `fill_color` arm clears both: the app tier
            // is what a no-selection read falls back to, so leaving it standing
            // would answer the user's None with the seeded white.
            model.appDefaultFill = nil
            model.defaultFill = nil
            if !model.document.selection.isEmpty {
                ctrl.setSelectionFill(nil)
            }
        }
    } else {
        if let color = color {
            // Colour-ONLY: width / cap / join / dash / arrowheads and the
            // stroke opacity all stay as they are, per element.
            model.appDefaultStroke = ColorPanel.recolorStroke(model.appDefaultStroke, color)
            model.defaultStroke = ColorPanel.recolorStroke(model.defaultStroke, color)
            if !model.document.selection.isEmpty {
                ctrl.mapSelectionStroke { ColorPanel.recolorStroke($0, color) }
            }
        } else {
            model.appDefaultStroke = nil
            model.defaultStroke = nil
            if !model.document.selection.isEmpty {
                ctrl.setSelectionStroke(nil)
            }
        }
    }
}

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
        guard let el = doc.tryGetElement(es.path) else { continue }
        elements.append((es.path, el))
    }
    if elements.count < 2 { return }

    // Read align panel state.
    let usePreview = (store.get("align_use_preview_bounds") as? Bool) ?? false
    // RESOLVEDALIGN: pick the LEAF measurement per Use Preview Bounds, then wrap
    // it so the kinds whose geometry lives behind an id resolve. Both modes were
    // affected — each plain function is resolver-less.
    let leaf: (Element) -> BBox = usePreview ? alignPreviewBounds : alignGeometricBounds
    let resolver = IdIndexResolver(index: model.idIndex)
    let boundsFn: AlignBoundsFn = { alignResolvedBounds($0, resolver, leaf) }
    let alignTo = (store.get("align_to") as? String) ?? "selection"
    let keyPathRaw = store.get("align_key_object_path")

    // Build the reference.
    let reference: AlignReference
    switch alignTo {
    case "artboard":
        // ARTBOARDS.md §Selection semantics — current artboard =
        // topmost panel-selected, else first. The at-least-one
        // invariant guarantees doc.artboards[0] exists for any
        // loaded document; if the array is empty (pathological),
        // fall back to the selection union so the op still moves
        // elements.
        let selectedIds = (store.getPanel("artboards", "artboards_panel_selection") as? [String]) ?? []
        let currentAb = currentArtboard(doc.artboards, selection: selectedIds)
        if let ab = currentAb {
            reference = .artboard((ab.x, ab.y, ab.width, ab.height))
        } else {
            let refs = elements.map(\.1)
            reference = .artboard(alignUnionBounds(refs, boundsFn))
        }
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
        guard let keyElem = doc.tryGetElement(kp) else { return }
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
        // The number_input commits via commitPanelWrite which writes
        // to panel state under `distribute_spacing_value`. The global
        // `align_distribute_spacing` mirror is only updated by the
        // reset action's dual-write today, so reading it here returned
        // 0 for a freshly-typed value. Read panel state directly,
        // falling back to global for any code path that pre-seeds it.
        let pid = "align_panel_content"
        if let n = store.getPanel(pid, "distribute_spacing_value") as? NSNumber {
            return n.doubleValue
        }
        if let d = store.getPanel(pid, "distribute_spacing_value") as? Double { return d }
        if let i = store.getPanel(pid, "distribute_spacing_value") as? Int { return Double(i) }
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
        // Bake the offset into raw coords (vs `withTransformTranslated`,
        // which only updates the transform field). The bake keeps
        // `bounds`, hit-test, and selection-overlay consistent with
        // the rendered position — without it, a second align_left
        // click computes deltas off the original (un-aligned) bbox
        // and doubles the offset.
        let moved = elem.translated(dx: t.dx, dy: t.dy)
        newDoc = newDoc.replaceElement(t.path, with: moved)
    }
    // Undoable align. The snapshot effect already opened the txn, so
    // editDocument joins it (else it self-brackets one step). Mirrors Rust
    // apply_align_operation's edit_document.
    model.editDocument(newDoc)
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
    // RESOLVED: a symbol instance measures its TARGET, so the narrow form put
    // its box at the ORIGIN — Align To in key-object mode could not designate
    // a selected instance as the key, and a click near (0,0) designated one
    // that is drawn nowhere near there. Twin of Rust's
    // `try_designate_align_key_object`.
    let keyResolver = IdIndexResolver(index: rebuildIdIndex(doc))
    for es in doc.selection {
        guard let el = doc.tryGetElement(es.path) else { continue }
        guard let b = resolvedBoundsWith(el, keyResolver, { $0.bounds }) else { continue }
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
        // Click missed every currently-selected element: clear the
        // designation. Mirrors the Rust try_designate_align_key_object
        // `None` arm, which sets key_object_path = None and consumes
        // the click while in key-object mode.
        store.set("align_key_object_path", NSNull())
        store.setPanel(pid, "key_object_path", NSNull())
    }
    // Bump panelStateVersion so SwiftUI re-evaluates the align
    // button bind.disabled expressions — without this they
    // remained "disabled" until the next unrelated re-render.
    model.panelStateVersion &+= 1
    // While in key-object mode the intercept always consumes the click
    // (matches Rust: returns true once align_to == key_object).
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
        // THE GRADIENT PANEL'S WRITE PATH, and it was NEVER REGISTERED.
        //
        // `applySetEffects` looks up platformEffects["apply_gradient_panel"]
        // after any gradient_* render-key write. No site in JasSwift/Sources
        // registered that key, so the `if let` failed silently and EVERY
        // Gradient-panel edit was a no-op against the document — while
        // jas_dioxus wired the same path and applied it correctly, recursing
        // into group members. A prime-directive violation, and one that
        // presented as "the panel is wired" because nothing errored.
        //
        // `applyGradientPanelToSelection` already existed, already mirrored
        // Rust's `AppState::apply_gradient_panel_to_selection`, and was
        // reachable only from GradientPanelSyncTests — the FOURTH shape of the
        // same dead-code hazard found on 2026-07-29, and the subtlest: not "no
        // callers" but ONE CALLER BEHIND A HOOK NOBODY INSTALLS. Grepping the
        // function name finds the definition and its test and tells you nothing.
        //
        // Registered HERE because all four production panel-effect sites build
        // their map through this one function.
        "apply_gradient_panel": { _, _, store in
            applyGradientPanelToSelection(store: store,
                                          controller: Controller(model: model))
            return nil
        },
        "snapshot": { _, _, _ in
            // OP_LOG.md Increment 1: NO-OP on this map. These panel actions
            // (align / boolean / swatch) are dispatched through `runEffects`
            // WITHOUT a `model:`, so the owner-commit bracket is inert — a
            // beginTxn here would never be committed (leaked-open txn). Instead
            // each doc-mutating effect below self-brackets its own one undo step
            // via the Controller's editDocument, so the explicit `- snapshot`
            // YAML step is redundant and must not push a second checkpoint.
            return nil
        },
        "reset_align_panel": { _, _, store in
            resetAlignPanel(store: store)
            return nil
        },
        // Triggered when a YAML set: writes fill_color or stroke_color
        // (e.g. via the set_active_color action dispatched from the
        // Swatches Panel). Pushes the active-color change to the
        // selected canvas element so the YAML route matches the
        // direct ColorPanel.setActiveColor path.
        // The hook value is a ``ColorWrite`` — the colour key the effect wrote
        // plus the value it wrote; runEffects fires it once per such key.
        "apply_active_color": { write, _, _ in
            if let write = write as? ColorWrite {
                applyActiveColorWrite(model: model, write: write)
            }
            return nil
        },
        // Mirror a YAML `set: { active_tool }` write (tool-alternates
        // flyout pick) into the live canvas tool. ContentView installs
        // model.onActiveToolChange to map the bundle tool string onto
        // its currentTool @State. See ContentView.toolFromYamlString.
        "apply_active_tool": { _, _, store in
            if let s = store.get("active_tool") as? String {
                model.onActiveToolChange?(s)
            }
            return nil
        },
    ]
    for op in ops {
        effects[op] = { _, _, store in
            applyAlignOperation(model: model, store: store, op: op)
            return nil
        }
    }
    // Boolean panel destructive ops. See BOOLEAN.md §Panel actions.
    let booleanOps = [
        "union", "intersection", "exclude",
        "subtract_front", "subtract_back", "crop",
        "divide", "trim", "merge",
    ]
    func booleanOptionsFromStore(_ store: StateStore) -> BooleanOptions {
        let def = BooleanOptions()
        let precision: Double
        switch store.get("boolean_precision") {
        case let d as Double: precision = d
        case let i as Int: precision = Double(i)
        default: precision = def.precision
        }
        let rrp = (store.get("boolean_remove_redundant_points") as? Bool) ?? def.removeRedundantPoints
        let drup = (store.get("boolean_divide_remove_unpainted") as? Bool) ?? def.divideRemoveUnpainted
        return BooleanOptions(precision: precision,
                              removeRedundantPoints: rrp,
                              divideRemoveUnpainted: drup)
    }
    for op in booleanOps {
        effects["boolean_\(op)"] = { _, _, store in
            let opts = booleanOptionsFromStore(store)
            Controller(model: model).applyDestructiveBoolean(op, options: opts)
            return nil
        }
    }
    // Boolean panel compound-shape menu actions (also dispatched by
    // the hamburger menu path, but yaml-driven menu items route here).
    effects["make_compound_shape"] = { _, _, _ in
        Controller(model: model).makeCompoundShape()
        return nil
    }
    effects["release_compound_shape"] = { _, _, _ in
        Controller(model: model).releaseCompoundShape()
        return nil
    }
    effects["expand_compound_shape"] = { _, _, _ in
        Controller(model: model).expandCompoundShape()
        return nil
    }
    // Alt/Option+click compound-creating variants. See BOOLEAN.md
    // §Compound shapes. Each keyed effect creates a live compound
    // shape with the chosen operation instead of applying the
    // destructive equivalent.
    let compoundOps = ["union", "subtract_front", "intersection", "exclude"]
    for op in compoundOps {
        effects["boolean_\(op)_compound"] = { _, _, _ in
            Controller(model: model).applyCompoundCreation(op)
            return nil
        }
    }
    // Repeat Boolean Operation reads state.last_boolean_op (13-value
    // enum; see BOOLEAN.md §Repeat state) and re-dispatches via
    // applyRepeatBooleanOperation.
    effects["repeat_boolean_operation"] = { _, _, store in
        let last = store.get("last_boolean_op") as? String
        let opts = booleanOptionsFromStore(store)
        Controller(model: model).applyRepeatBooleanOperation(last, options: opts)
        return nil
    }
    // Reset Panel clears last_op only (handled by the yaml `set`
    // effect that pairs with this one); dialog defaults are not
    // reset here.
    effects["reset_boolean_panel"] = { _, _, _ in nil }

    // CAPREACH (2026-08-05): the panel-write hook belongs on the SHARED map,
    // not only on the text-input commit route.
    //
    // `set_panel_state` fires this hook so the host can push the written
    // attribute onto the selection, and its own comment warns it is a "silent
    // no-op if the host hasn't registered the effect". It was registered in
    // exactly ONE place — `runInputCommitBehavior` — so typing a stroke weight
    // applied to the selected element and CLICKING A CAP BUTTON DID NOTHING.
    // Every route that runs a YAML action without going through an input
    // commit (`runYamlActionByName`, which is how the cap/join radios and the
    // panel hamburger dispatch) built its map here and got no hook.
    //
    // JYH found it at the canvas: "in the stroke panel it is round, but it
    // comes up a square. Clicking on a different cap does not do anything."
    // Rust has never had this shape — `panels/stroke_panel.rs` calls
    // `apply_stroke_panel_to_selection("cap")` directly from the dispatch.
    //
    // No `field` fallback here, deliberately: this route has no
    // "field being committed" to fall back TO. A write that names its key
    // applies; one that does not is not this hook's business, and inventing a
    // guess is what applied the wrong group in the linked-scale case.
    // `runInputCommitBehavior` still overrides this with its richer version.
    effects["notify_panel_state_changed"] = { arg, _, store in
        if let (panelId, wroteField) = parseNotifyPayload(arg), let edited = wroteField {
            notifyPanelStateChanged(panelId, store: store, model: model, edited: edited)
        }
        return nil
    }
    return effects
}
