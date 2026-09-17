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
enum WidgetEvent {
    static let commitEvents = ["commit", "change"]
    static let pressEvents = ["click", "change"]
    static let inputKinds: Set<String> = [
        "number_input", "length_input", "text_input",
        "select", "icon_select", "combo_box",
    ]
    static let booleanKinds: Set<String> = ["toggle", "checkbox"]

    static let badValue = "BadValue"
    static let missingValue = "MissingValue"
    static let disabled = "Disabled"
    static let wrongKind = "WrongKind"

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

    static func commit(
        widget: [String: Any], text: String?, store: StateStore,
        panel: [String: Any]?,
        actions: [String: Any]? = nil, dialogs: [String: Any]? = nil,
        platformEffects: [String: PlatformEffect] = [:], model: Model? = nil
    ) -> Result {
        guard let kind = widget["type"] as? String, inputKinds.contains(kind) else {
            return Result(outcome: "refused", reason: wrongKind)
        }
        if isDisabled(widget, store: store) {
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
            writeBind(target, value: parsed.value, store: store, panel: panel)
        }
        let ran = runBehaviors(declared(widget, events: commitEvents), value: parsed.value,
                               store: store, actions: actions, dialogs: dialogs,
                               platformEffects: platformEffects, model: model)
        return Result(outcome: target != nil || ran > 0 ? "committed" : "inert",
                      value: parsed.value, bindWritten: target != nil, behaviorsRun: ran)
    }

    static func press(
        widget: [String: Any], store: StateStore, panel: [String: Any]?,
        actions: [String: Any]? = nil, dialogs: [String: Any]? = nil,
        platformEffects: [String: PlatformEffect] = [:], model: Model? = nil
    ) -> Result {
        guard let kind = widget["type"] as? String, booleanKinds.contains(kind) else {
            return Result(outcome: "refused", reason: wrongKind)
        }
        if isDisabled(widget, store: store) {
            return Result(outcome: "refused", reason: disabled)
        }
        let expr = boundTarget(widget)
        let current = expr.map { evaluate($0, context: store.evalContext()).toBool() } ?? false
        let value = !current
        let owners = declared(widget, events: pressEvents)
        if !owners.isEmpty {
            // Declared, not merely run: a behavior skipped by its condition
            // still owns the press, so the field is not written behind it.
            let ran = runBehaviors(owners, value: value, store: store, actions: actions,
                                   dialogs: dialogs, platformEffects: platformEffects,
                                   model: model)
            return Result(outcome: ran > 0 ? "committed" : "inert", value: value,
                          behaviorsRun: ran)
        }
        guard let target = writableTarget(expr) else {
            return Result(outcome: "inert", value: value)
        }
        writeBind(target, value: value, store: store, panel: panel)
        return Result(outcome: "committed", value: value, bindWritten: true)
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
            guard let options = widget["options"] as? [Any] else {
                // Computed options: the shell offered what the expression
                // produced, so the text is the value.
                return (true, text)
            }
            for option in options {
                let value: Any? = option is [String: Any]
                    ? (option as? [String: Any])?["value"]
                    : option
                if let value = value, !(value is NSNull), referenceString(value) == text {
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

    /// An option value as the reference's `str()` writes it: `True`/`False`
    /// for a boolean, `3` for an integer, `2.0` for a float that is whole.
    private static func referenceString(_ v: Any) -> String {
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
                                  store: StateStore, panel: [String: Any]?) {
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

    private static func isDisabled(_ widget: [String: Any], store: StateStore) -> Bool {
        guard let expr = (widget["bind"] as? [String: Any])?["disabled"] as? String else {
            return false
        }
        return evaluate(expr, context: store.evalContext()).toBool()
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
        platformEffects: [String: PlatformEffect], model: Model?
    ) -> Int {
        var ran = 0
        for b in behaviors {
            let ctx: [String: Any] = ["event": ["value": value ?? NSNull()]]
            if let condition = b["condition"] as? String,
               !evaluate(condition, context: store.evalContext(extra: ctx)).toBool() {
                continue
            }
            if let effects = b["effects"] as? [Any] {
                runEffects(effects, ctx: ctx, store: store, actions: actions,
                           dialogs: dialogs, platformEffects: platformEffects, model: model)
            }
            if let action = b["action"] as? String {
                let dispatch: [String: Any] = [
                    "action": action,
                    "params": b["params"] as? [String: Any] ?? [:],
                ]
                runEffects([["dispatch": dispatch]], ctx: ctx, store: store, actions: actions,
                           dialogs: dialogs, platformEffects: platformEffects, model: model)
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
