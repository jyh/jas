import Foundation

/// The widget event contract (`WIDGET_EVENTS.md`), headless: what a value
/// widget's commit or press does to the store, with no view in sight.
///
/// The executable meaning is the reference's
/// `workspace_interpreter/widget_event.py`, and this is its Swift port, held
/// to the reference-generated corpus
/// (`test_fixtures/widget_events/corpus.json`) by
/// `Tests/Interpreter/WidgetEventCorpusTests.swift`. The engine's panel door
/// is held to the same corpus in `jas_dioxus/src/ffi.rs`.
///
/// Two procedures, one per family of kinds:
///
/// * ``commit(widget:text:store:panel:actions:dialogs:platformEffects:model:)``
///   for the INPUT kinds. Refuse a disabled widget, a missing value and text
///   the kind refuses; write the parsed value to a `panel.`/`dialog.` bound
///   target (with the two-way bound global); THEN run the `commit`/`change`
///   behaviors with `event.value`.
/// * ``press(widget:store:panel:actions:dialogs:platformEffects:model:)``
///   for the BOOLEAN kinds. A declared `click`/`change` behavior IS the press
///   and the bind write is skipped; otherwise the negated value is written.
///
/// The caller owns the active panel: `panel.` targets and `set_panel_state`
/// both write the store's active panel.
///
/// A view passes a ``Host`` (the app's is `PanelWidgetEvents`). With the
/// default host, the store is the only scope, the bind write is a store
/// write, and an action dispatches through the catalog: the headless module
/// the corpus drives.
enum WidgetEvent {
    static let commitEvents = ["commit", "change"]
    static let pressEvents = ["click", "change"]
    static let inputKinds: Set<String> = [
        "number_input", "length_input", "text_input",
        "select", "icon_select", "combo_box",
    ]
    static let booleanKinds: Set<String> = ["toggle", "checkbox"]
    /// A plain pick and an Alt pick of one declared item. NOT synonyms.
    static let pickEvents = ["toggle", "alt_toggle"]
    static let itemKinds: Set<String> = ["dropdown"]

    static let badValue = "BadValue"
    static let missingValue = "MissingValue"
    static let disabled = "Disabled"
    static let wrongKind = "WrongKind"
    static let wrongEvent = "WrongEvent"

    /// What one event did. `outcome` is `committed`, `refused` (with
    /// `reason`) or `inert`. `value` is the parsed value, `nil` when there is
    /// none (a refusal, or a cleared nullable length).
    struct Result {
        let outcome: String
        var reason: String? = nil
        var value: Any? = nil
        var bindWritten: Bool = false
        var behaviorsRun: Int = 0
    }

    /// What a view supplies in place of the headless defaults.
    struct Host {
        /// The scope the view rendered the widget with, or nil.
        ///
        /// When set, the `bind.disabled` check and a press's current value
        /// read it, because that is what the person saw: a Swift panel scope
        /// overlays live selection values the store does not hold. Its names
        /// the store does not supply (a `foreach` item) reach the behaviors.
        /// Its store namespaces (`state`, `panel`, `dialog`, …) never do: a
        /// behavior reads the store, which already holds the bind write.
        var scope: [String: Any]? = nil
        /// The bind write, in place of the store write. It receives the
        /// target, the parsed value (nil for a cleared nullable length), and
        /// for a `panel.` field the global that field is two-way bound to.
        /// It writes the field, then the global, before it returns.
        var writeBind: ((_ scope: String, _ key: String, _ value: Any?,
                         _ global: String?) -> Void)? = nil
        /// Dispatch one behavior's action, in place of the catalog dispatch.
        /// `params` are already evaluated; `ctx` holds `event` and the
        /// scope's own names, never a store namespace.
        var dispatch: ((_ action: String, _ params: [String: Any],
                        _ ctx: [String: Any]) -> Void)? = nil
    }

    static func commit(
        widget: [String: Any], text: String?, store: StateStore,
        panel: [String: Any]?,
        actions: [String: Any]? = nil, dialogs: [String: Any]? = nil,
        platformEffects: [String: PlatformEffect] = [:], model: Model? = nil,
        host: Host = Host()
    ) -> Result {
        guard let kind = widget["type"] as? String, inputKinds.contains(kind) else {
            return Result(outcome: "refused", reason: wrongKind)
        }
        if isDisabled(widget, store: store, host: host) {
            return Result(outcome: "refused", reason: disabled)
        }
        guard let text = text else {
            return Result(outcome: "refused", reason: missingValue)
        }
        let parsed = parseCommit(widget: widget, text: text)
        guard parsed.accepted else {
            return Result(outcome: "refused", reason: badValue)
        }
        let target = writableTarget(boundTarget(widget))
        if let target = target {
            writeBind(target, value: parsed.value, store: store, panel: panel, host: host)
        }
        let ran = runBehaviors(declared(widget, events: commitEvents), value: parsed.value,
                               store: store, actions: actions, dialogs: dialogs,
                               platformEffects: platformEffects, model: model, host: host)
        return Result(outcome: target != nil || ran > 0 ? "committed" : "inert",
                      value: parsed.value, bindWritten: target != nil, behaviorsRun: ran)
    }

    static func press(
        widget: [String: Any], store: StateStore, panel: [String: Any]?,
        actions: [String: Any]? = nil, dialogs: [String: Any]? = nil,
        platformEffects: [String: PlatformEffect] = [:], model: Model? = nil,
        host: Host = Host()
    ) -> Result {
        guard let kind = widget["type"] as? String, booleanKinds.contains(kind) else {
            return Result(outcome: "refused", reason: wrongKind)
        }
        if isDisabled(widget, store: store, host: host) {
            return Result(outcome: "refused", reason: disabled)
        }
        let expr = boundTarget(widget)
        let current = expr.map {
            evaluate($0, context: host.scope ?? store.evalContext()).toBool()
        } ?? false
        let value = !current
        let owners = declared(widget, events: pressEvents)
        if !owners.isEmpty {
            // Declared, not merely run: a behavior skipped by its condition
            // still owns the press, so the field is not written behind it.
            let ran = runBehaviors(owners, value: value, store: store, actions: actions,
                                   dialogs: dialogs, platformEffects: platformEffects,
                                   model: model, host: host)
            return Result(outcome: ran > 0 ? "committed" : "inert", value: value,
                          behaviorsRun: ran)
        }
        guard let target = writableTarget(expr) else {
            return Result(outcome: "inert", value: value)
        }
        writeBind(target, value: value, store: store, panel: panel, host: host)
        return Result(outcome: "committed", value: value, bindWritten: true)
    }

    /// Pick one declared item of an item kind (`dropdown`), named by its
    /// `value` (WIDGET_EVENTS.md, "Picking a dropdown item"). An `action` item
    /// runs its own action; any other item runs the behaviors declared for
    /// `event` with `item` bound to the whole item. Nothing is bound or
    /// written by the pick itself.
    static func pick(
        widget: [String: Any], itemValue: String?, event: String, store: StateStore,
        panel: [String: Any]?,
        actions: [String: Any]? = nil, dialogs: [String: Any]? = nil,
        platformEffects: [String: PlatformEffect] = [:], model: Model? = nil,
        host: Host = Host()
    ) -> Result {
        guard let kind = widget["type"] as? String, itemKinds.contains(kind) else {
            return Result(outcome: "refused", reason: wrongKind)
        }
        guard pickEvents.contains(event) else {
            return Result(outcome: "refused", reason: wrongEvent)
        }
        if isDisabled(widget, store: store, host: host) {
            return Result(outcome: "refused", reason: disabled)
        }
        guard let itemValue = itemValue else {
            return Result(outcome: "refused", reason: missingValue)
        }
        let items = (widget["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        guard let item = items.first(where: { $0["value"] as? String == itemValue }) else {
            return Result(outcome: "refused", reason: badValue)
        }
        if item["type"] as? String == "action" {
            guard let action = item["action"] as? String else {
                return Result(outcome: "inert", value: itemValue)
            }
            let dispatch: [String: Any] = ["action": action,
                                           "params": item["params"] as? [String: Any] ?? [:]]
            runEffects([["dispatch": dispatch]], ctx: ["item": item], store: store,
                       actions: actions, dialogs: dialogs, platformEffects: platformEffects,
                       model: model)
            return Result(outcome: "committed", value: itemValue)
        }
        let ran = runBehaviors(declared(widget, events: [event]), value: itemValue, store: store,
                               actions: actions, dialogs: dialogs,
                               platformEffects: platformEffects, model: model, host: host,
                               extra: ["item": item])
        return Result(outcome: ran > 0 ? "committed" : "inert", value: itemValue,
                      behaviorsRun: ran)
    }

    // MARK: - Parsing

    /// Parse committed text by the widget's kind. A refused parse is
    /// `(false, nil)`; an accepted one may still carry a `nil` value (a
    /// cleared nullable length).
    static func parseCommit(widget: [String: Any], text: String) -> (accepted: Bool, value: Any?) {
        let refused: (accepted: Bool, value: Any?) = (false, nil)
        let lo = declaredBound(widget["min"])
        let hi = declaredBound(widget["max"])
        switch widget["type"] as? String {
        case "number_input":
            guard let v = numberInputCommit(text: text, min: lo, max: hi) else { return refused }
            return (true, v)
        case "length_input":
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Value.fromJson(widget["nullable"]) == .bool(true) ? (true, nil) : refused
            }
            let unit = widget["unit"] as? String ?? "pt"
            guard let v = Length.parse(text, defaultUnit: unit) else { return refused }
            return (true, clampToDeclared(v, min: lo, max: hi))
        case "text_input":
            return (true, text)
        case "select", "icon_select":
            guard let rows = optionRows(widget["options"]) else {
                // Computed options: the shell offered what the expression
                // produced, so the text is the value.
                return (true, text)
            }
            // A divider is not a row a commit can match (SCHEMA.md, `options`).
            for row in rows where !row.isDivider {
                if let value = row.value, optionText(value) == text {
                    return (true, value)
                }
            }
            return refused
        case "combo_box":
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return refused }
            if let n = numericStringValue(text) {
                return (true, clampToDeclared(n, min: lo, max: hi))
            }
            return (true, text)
        default:
            return refused
        }
    }

    /// A declared `min:`/`max:`, or nil. A boolean is not a bound.
    private static func declaredBound(_ v: Any?) -> Double? {
        guard let v = v, !(v is NSNull), case .number(let n) = Value.fromJson(v) else { return nil }
        return n
    }

    /// One row of a literal `options` list (SCHEMA.md, `options`): an option
    /// with its declared value, or a divider between groups.
    struct OptionRow {
        let isDivider: Bool
        let value: Any?
        let label: String
        let glyph: String?

        /// The row in the shared corpus's form (`option_rows.json`).
        func asJSON() -> [String: Any] {
            if isDivider { return ["kind": "separator"] }
            var d: [String: Any] = ["kind": "option", "value": value ?? NSNull(), "label": label]
            if let g = glyph { d["glyph"] = g }
            return d
        }
    }

    /// A bare list item that is a divider between groups, never a value. The
    /// same token a menubar's `items` use.
    static let optionDivider = "separator"

    /// How a literal `options` list reads, or nil for computed options (an
    /// expression), which have no declared rows. A bare item is an option
    /// labelled by its own text; the bare string `separator` is a divider; a
    /// map with no `value` cannot be written and is not offered. Pinned by
    /// `test_fixtures/algorithms/option_rows.json`.
    ///
    /// ⛔ READ AS `[Any]`, NEVER `[[String: Any]]`: that cast fails WHOLE on a
    /// list holding one bare item, and it drew op_mode's blend-mode menu and
    /// every numeric preset list empty.
    static func optionRows(_ options: Any?) -> [OptionRow]? {
        guard let list = options as? [Any] else { return nil }
        var rows: [OptionRow] = []
        for item in list {
            if let s = item as? String, s == optionDivider {
                rows.append(OptionRow(isDivider: true, value: nil, label: "", glyph: nil))
                continue
            }
            if let o = item as? [String: Any] {
                guard let v = o["value"], !(v is NSNull) else { continue }
                let text = optionText(v)
                rows.append(OptionRow(isDivider: false, value: v,
                                      label: o["label"] as? String ?? text,
                                      glyph: o["glyph"] as? String))
                continue
            }
            if item is NSNull { continue }
            rows.append(OptionRow(isDivider: false, value: item, label: optionText(item), glyph: nil))
        }
        return rows
    }

    /// An option value as the reference's `str()` writes it: `True`/`False`
    /// for a boolean, `3` for an integer, `2.0` for a float that is whole.
    /// It is the text a view commits for a picked option, so the parse
    /// matches the option by construction.
    static func optionText(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            switch String(cString: n.objCType) {
            case "c", "B": return n.boolValue ? "True" : "False"
            case "f", "d": return "\(n.doubleValue)"
            default: return n.stringValue
            }
        }
        return "\(v)"
    }

    // MARK: - Targets

    /// The bound expression: `bind.value`, else `bind.checked`, else a
    /// bare-string `bind`.
    static func boundTarget(_ widget: [String: Any]) -> String? {
        if let bind = widget["bind"] as? String { return bind }
        guard let bind = widget["bind"] as? [String: Any] else { return nil }
        return bind["value"] as? String ?? bind["checked"] as? String
    }

    /// `(scope, key)` when this layer may write `expr`: exactly
    /// `panel.<ident>` or `dialog.<ident>`, ASCII. Every other bind is read,
    /// never written, here.
    static func writableTarget(_ expr: String?) -> (scope: String, key: String)? {
        guard let expr = expr else { return nil }
        let t = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        for scope in ["panel", "dialog"] where t.hasPrefix(scope + ".") {
            let key = String(t.dropFirst(scope.count + 1))
            return isIdent(key) ? (scope, key) : nil
        }
        return nil
    }

    /// The global a panel field is two-way bound to: the `<ident>` of a bare
    /// `state.<ident>` in the panel's `init:` for `key`.
    static func mirroredGlobal(panel: [String: Any]?, key: String) -> String? {
        guard let expr = (panel?["init"] as? [String: Any])?[key] as? String else { return nil }
        let t = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("state.") else { return nil }
        let ident = String(t.dropFirst("state.".count))
        return isIdent(ident) ? ident : nil
    }

    private static func isIdent(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy {
            ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z")
                || ($0 >= "0" && $0 <= "9") || $0 == "_"
        }
    }

    /// The bind write: the field, and for a `panel.` field its two-way bound
    /// global in the same step. A `nil` value is written as a JSON null,
    /// since this store REMOVES a key assigned `nil`.
    private static func writeBind(_ target: (scope: String, key: String), value: Any?,
                                  store: StateStore, panel: [String: Any]?, host: Host) {
        if let write = host.writeBind {
            let global = target.scope == "panel"
                ? mirroredGlobal(panel: panel, key: target.key) : nil
            write(target.scope, target.key, value, global)
            return
        }
        let stored: Any = value ?? NSNull()
        if target.scope == "panel" {
            if let pid = store.getActivePanelId() {
                store.setPanel(pid, target.key, stored)
            }
            if let global = mirroredGlobal(panel: panel, key: target.key) {
                store.set(global, stored)
            }
        } else {
            store.setDialog(target.key, stored)
        }
    }

    private static func isDisabled(_ widget: [String: Any], store: StateStore,
                                   host: Host) -> Bool {
        guard let expr = (widget["bind"] as? [String: Any])?["disabled"] as? String else {
            return false
        }
        return evaluate(expr, context: host.scope ?? store.evalContext()).toBool()
    }

    /// The scope's own names: everything in it the store does not supply.
    static func scopeLocals(_ scope: [String: Any]?, store: StateStore) -> [String: Any] {
        guard let scope = scope else { return [:] }
        let supplied = Set(store.evalContext().keys).union(["event"])
        return scope.filter { !supplied.contains($0.key) }
    }

    // MARK: - Behaviors

    private static func declared(_ widget: [String: Any], events: [String]) -> [[String: Any]] {
        (widget["behavior"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            .filter { ($0["event"] as? String).map(events.contains) ?? false }
    }

    /// Run `behaviors` in order. Within one, its effects run first, then its
    /// action. The count excludes a behavior whose `condition` is false.
    private static func runBehaviors(
        _ behaviors: [[String: Any]], value: Any?, store: StateStore,
        actions: [String: Any]?, dialogs: [String: Any]?,
        platformEffects: [String: PlatformEffect], model: Model?, host: Host,
        extra: [String: Any] = [:]
    ) -> Int {
        let locals = scopeLocals(host.scope, store: store).merging(extra) { _, new in new }
        var ran = 0
        for b in behaviors {
            var ctx = locals
            ctx["event"] = ["value": value ?? NSNull()] as [String: Any]
            if let condition = b["condition"] as? String,
               !evaluate(condition, context: store.evalContext(extra: ctx)).toBool() {
                continue
            }
            if let effects = b["effects"] as? [Any] {
                runEffects(effects, ctx: ctx, store: store, actions: actions,
                           dialogs: dialogs, platformEffects: platformEffects, model: model)
            }
            if let action = b["action"] as? String {
                let params = b["params"] as? [String: Any] ?? [:]
                if let dispatch = host.dispatch {
                    // Evaluated as the catalog dispatch evaluates them: after
                    // the effects, against the store. A null stays a null.
                    var resolved: [String: Any] = [:]
                    for (k, v) in params {
                        guard let expr = v as? String else { resolved[k] = v; continue }
                        let result = evaluate(expr, context: store.evalContext(extra: ctx))
                        resolved[k] = result.toAny() ?? NSNull()
                    }
                    dispatch(action, resolved, ctx)
                } else {
                    let dispatch: [String: Any] = ["action": action, "params": params]
                    runEffects([["dispatch": dispatch]], ctx: ctx, store: store,
                               actions: actions, dialogs: dialogs,
                               platformEffects: platformEffects, model: model)
                }
            }
            ran += 1
        }
        return ran
    }

    /// The node whose `id` is `id`, searched depth-first through a panel's
    /// content (dictionaries and arrays). `nil` when there is none.
    static func findWidget(in node: Any?, id: String) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if dict["id"] as? String == id { return dict }
            for key in dict.keys.sorted() {
                if let found = findWidget(in: dict[key], id: id) { return found }
            }
        } else if let list = node as? [Any] {
            for item in list {
                if let found = findWidget(in: item, id: id) { return found }
            }
        }
        return nil
    }
}
