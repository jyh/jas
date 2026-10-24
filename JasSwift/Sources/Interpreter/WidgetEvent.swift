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
        "select", "icon_select", "icon_button_group", "reference_point_widget",
        "combo_box", "slider", "color_bar",
    ]
    static let booleanKinds: Set<String> = ["toggle", "checkbox"]
    /// A plain pick and an Alt pick of one declared item. NOT synonyms.
    static let pickEvents = ["toggle", "alt_toggle"]
    static let itemKinds: Set<String> = ["dropdown"]
    /// The nine anchors a `reference_point_widget` takes, row by row. The KIND
    /// owns them (WIDGET_EVENTS.md, Parsing); no YAML declares them.
    static let referencePointAnchors = [
        "top_left", "top_center", "top_right",
        "middle_left", "center", "middle_right",
        "bottom_left", "bottom_center", "bottom_right",
    ]
    /// The check kind: a press CHECKS it and never unchecks it. Its events
    /// are the press synonyms.
    static let checkKinds: Set<String> = ["radio"]
    /// The option kind: a pick names one of its `options` by `id`.
    static let optionKinds: Set<String> = ["radio_group"]
    static let chooseEvents = ["toggle"]
    /// The click kinds (WIDGET_EVENTS.md, "Clicking a button"). `mouse_down`
    /// and `mouse_up` are named in the table, not defined; a click never runs them.
    static let clickKinds: Set<String> = ["button", "icon_button"]
    static let clickEvents = ["click"]

    /// Whether a click runs the widget's node-level `action`: a click kind
    /// with a string `action` and NO declared `click` behavior. A declared one
    /// IS the click, even when its condition skips it (the reference's
    /// `click`), so the action never runs beside it.
    static func clickRunsNodeAction(_ widget: [String: Any]) -> Bool {
        guard let kind = widget["type"] as? String, clickKinds.contains(kind),
              widget["action"] is String else { return false }
        return declared(widget, events: clickEvents).isEmpty
    }

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
        settle(store: store, actions: actions, dialogs: dialogs,
               platformEffects: platformEffects, model: model)
        return Result(outcome: target != nil || ran > 0 ? "committed" : "inert",
                      value: parsed.value, bindWritten: target != nil, behaviorsRun: ran)
    }

    /// The click's modifiers (the reference's `CLICK_MODIFIERS`).
    static let clickModifiers = ["shift", "ctrl", "meta", "alt"]

    /// Click a CLICK kind (`button`, `icon_button`): the reference's `click`
    /// (widget_event.py, WIDGET_EVENTS.md "Clicking a button").
    ///
    /// Refuse a wrong kind, an event other than `click` (`WrongEvent`) and a
    /// disabled widget. `event.*` is the four modifiers, each `false` when
    /// absent, and no value. A declared `click` behavior IS the click: those
    /// run in order and the node-level `action` does not, even when every
    /// condition is false. Otherwise the node-level `action` is dispatched
    /// with its `params`, as a behavior's `action` is. A click that runs
    /// nothing is `inert`. A click writes no bind.
    @discardableResult
    static func click(
        widget: [String: Any], event: String, store: StateStore,
        panel: [String: Any]?, modifiers: [String: Any] = [:],
        actions: [String: Any]? = nil, dialogs: [String: Any]? = nil,
        platformEffects: [String: PlatformEffect] = [:], model: Model? = nil,
        host: Host = Host()
    ) -> Result {
        _ = panel  // no bind write: accepted for the procedures' common signature
        guard let kind = widget["type"] as? String, clickKinds.contains(kind) else {
            return Result(outcome: "refused", reason: wrongKind)
        }
        guard clickEvents.contains(event) else {
            return Result(outcome: "refused", reason: wrongEvent)
        }
        if isDisabled(widget, store: store, host: host) {
            return Result(outcome: "refused", reason: disabled)
        }
        var mods: [String: Any] = [:]
        for k in clickModifiers { mods[k] = (modifiers[k] as? Bool) ?? false }
        let owners = declared(widget, events: clickEvents)
        if !owners.isEmpty {
            let ran = runBehaviors(owners, value: nil, store: store, actions: actions,
                                   dialogs: dialogs, platformEffects: platformEffects,
                                   model: model, host: host, event: mods)
            return Result(outcome: ran > 0 ? "committed" : "inert", behaviorsRun: ran)
        }
        guard let action = widget["action"] as? String else {
            return Result(outcome: "inert")
        }
        var node: [String: Any] = ["action": action]
        if let params = widget["params"] { node["params"] = params }
        let ran = runBehaviors([node], value: nil, store: store, actions: actions,
                               dialogs: dialogs, platformEffects: platformEffects,
                               model: model, host: host, event: mods)
        return Result(outcome: "committed", behaviorsRun: ran)
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
        settle(store: store, actions: actions, dialogs: dialogs,
               platformEffects: platformEffects, model: model)
        return Result(outcome: "committed", value: value, bindWritten: true)
    }

    /// Press the check kind (WIDGET_EVENTS.md, "Checking a radio"): check it,
    /// never uncheck it. A radio whose bound expression is true is `inert`.
    /// Its node-level `on_check` effects ARE the check (`event.value` is
    /// `true`, nothing written behind them); with none, `true` is written to a
    /// writable bind. Declared `click`/`change` behaviors run after.
    static func check(
        widget: [String: Any], store: StateStore, panel: [String: Any]?,
        actions: [String: Any]? = nil, dialogs: [String: Any]? = nil,
        platformEffects: [String: PlatformEffect] = [:], model: Model? = nil,
        host: Host = Host()
    ) -> Result {
        guard let kind = widget["type"] as? String, checkKinds.contains(kind) else {
            return Result(outcome: "refused", reason: wrongKind)
        }
        if isDisabled(widget, store: store, host: host) {
            return Result(outcome: "refused", reason: disabled)
        }
        let expr = boundTarget(widget)
        if let expr = expr,
           evaluate(expr, context: host.scope ?? store.evalContext()).toBool() {
            return Result(outcome: "inert", value: true)
        }
        var ran = 0
        var written = false
        if let onCheck = widget["on_check"] as? [Any], !onCheck.isEmpty {
            var ctx = scopeLocals(host.scope, store: store)
            ctx["event"] = ["value": true] as [String: Any]
            runEffects(onCheck, ctx: ctx, store: store, actions: actions, dialogs: dialogs,
                       platformEffects: platformEffects, model: model)
            ran = 1
        } else if let target = writableTarget(expr) {
            writeBind(target, value: true, store: store, panel: panel, host: host)
            written = true
        }
        ran += runBehaviors(declared(widget, events: pressEvents), value: true, store: store,
                            actions: actions, dialogs: dialogs,
                            platformEffects: platformEffects, model: model, host: host)
        settle(store: store, actions: actions, dialogs: dialogs,
               platformEffects: platformEffects, model: model)
        return Result(outcome: ran > 0 || written ? "committed" : "inert", value: true,
                      bindWritten: written, behaviorsRun: ran)
    }

    /// Pick one option of the option kind (WIDGET_EVENTS.md, "Picking a radio
    /// option") by its `id`. The option whose id equals the bound value as
    /// text (``choiceText(_:)``) is already checked: `inert`. Otherwise the id
    /// is written to a writable bind, then the `toggle` behaviors run with
    /// `event.value` the id.
    static func choose(
        widget: [String: Any], optionId: String?, event: String, store: StateStore,
        panel: [String: Any]?,
        actions: [String: Any]? = nil, dialogs: [String: Any]? = nil,
        platformEffects: [String: PlatformEffect] = [:], model: Model? = nil,
        host: Host = Host()
    ) -> Result {
        guard let kind = widget["type"] as? String, optionKinds.contains(kind) else {
            return Result(outcome: "refused", reason: wrongKind)
        }
        guard chooseEvents.contains(event) else {
            return Result(outcome: "refused", reason: wrongEvent)
        }
        if isDisabled(widget, store: store, host: host) {
            return Result(outcome: "refused", reason: disabled)
        }
        guard let optionId = optionId else {
            return Result(outcome: "refused", reason: missingValue)
        }
        let options = (widget["options"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        guard options.contains(where: { $0["id"] as? String == optionId }) else {
            return Result(outcome: "refused", reason: badValue)
        }
        let expr = boundTarget(widget)
        if let expr = expr,
           choiceText(evaluate(expr, context: host.scope ?? store.evalContext())) == optionId {
            return Result(outcome: "inert", value: optionId)
        }
        let target = writableTarget(expr)
        if let target = target {
            writeBind(target, value: optionId, store: store, panel: panel, host: host)
        }
        let ran = runBehaviors(declared(widget, events: chooseEvents), value: optionId,
                               store: store, actions: actions, dialogs: dialogs,
                               platformEffects: platformEffects, model: model, host: host)
        settle(store: store, actions: actions, dialogs: dialogs,
               platformEffects: platformEffects, model: model)
        return Result(outcome: target != nil || ran > 0 ? "committed" : "inert",
                      value: optionId, bindWritten: target != nil, behaviorsRun: ran)
    }

    /// A bound value as the text an option `id` is compared with: a string as
    /// itself, a number in its canonical text (a WHOLE number without its
    /// `.0`: a Swift Double prints 2.0 as "2.0"), a bool as `true`/`false`,
    /// anything else nil.
    static func choiceText(_ v: Value) -> String? {
        switch v {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return numberToCanonicalString(n)
        default: return nil
        }
    }

    /// Whether a dropdown's `toggle` item is checked (WIDGET_EVENTS.md,
    /// "Showing an item's check"): its value is an element of the list the
    /// dropdown's `bind.checked_in` resolves to in `scope`. Nil when there is
    /// no such list: the check is unknown, not unchecked.
    static func itemChecked(widget: [String: Any], value: String, scope: [String: Any]) -> Bool? {
        guard let expr = (widget["bind"] as? [String: Any])?["checked_in"] as? String,
              case .list(let list) = evaluate(expr, context: scope) else { return nil }
        return list.contains { ($0.value as? String) == value }
    }

    /// Whether a dropdown's `action` item is already IN FORCE: running its
    /// action now would change nothing (WIDGET_EVENTS.md, "Showing an item's
    /// check"). A dry run of the action's OWN effects, so the tick cannot
    /// disagree with what a pick does. Known only when the item has no
    /// `params` and every effect is a `set_panel_state` NAMING `panelId`; then
    /// true exactly when each value, evaluated in `scope`, equals
    /// `scope.panel[key]`, numbers by value. Nil otherwise, never false: an
    /// unseen effect could change something. Rust's `panel_plan::action_in_force`.
    static func itemInForce(item: [String: Any], panelId: String, actions: [String: Any],
                            scope: [String: Any]) -> Bool? {
        guard item["params"] == nil, !panelId.isEmpty,
              let name = item["action"] as? String,
              let effects = (actions[name] as? [String: Any])?["effects"] as? [Any],
              !effects.isEmpty else { return nil }
        let own = StateStore.panelContentId(panelId)
        let panel = scope["panel"] as? [String: Any] ?? [:]
        var inForce = true
        for effect in effects {
            guard let sps = (effect as? [String: Any])?["set_panel_state"] as? [String: Any],
                  let named = sps["panel"] as? String,
                  let key = sps["key"] as? String else { return nil }
            guard StateStore.panelContentId(named) == own else { return nil }
            // "null" is the runner's own default for an absent value.
            let next = evaluate(sps["value"] as? String ?? "null", context: scope).toAny()
            inForce = inForce && jsonValueEqual(next, panel[key])
        }
        return inForce
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
        case "slider":
            // A number, clamped; snapped to `step` from `min`; clamped again,
            // so a `max` off the step grid is unreachable (the reference's
            // `_snap`, WIDGET_EVENTS.md Parsing).
            guard let v = numberInputCommit(text: text, min: lo, max: hi) else { return refused }
            return (true, clampToDeclared(snapToStep(v, min: lo, step: declaredBound(widget["step"])),
                                          min: lo, max: hi))
        case "color_bar":
            // A point normalized to [0,1]² (fork B2): "u,v", each coordinate in
            // the number grammar, each clamped. The colour is
            // `colorBarRgb(u, v)`; the parse stops at the point.
            let parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2,
                  let u = numberInputCommit(text: parts[0], min: 0, max: 1),
                  let v = numberInputCommit(text: parts[1], min: 0, max: 1) else { return refused }
            return (true, [u, v])
        case "reference_point_widget":
            return referencePointAnchors.contains(text) ? (true, text) : (false, nil)
        case "select", "icon_select", "icon_button_group":
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
    /// End the event as one batch ends: a write to a field of the open dialog
    /// runs the dialog's `on_change` action, once (WIDGET_EVENTS.md, "The bound
    /// target"; the reference's `_settle`). An empty batch runs `runEffects`'
    /// post-batch hook, which fires only while the dialog is dirty, so after a
    /// behavior batch that already fired it this is a no-op.
    private static func settle(
        store: StateStore, actions: [String: Any]?, dialogs: [String: Any]?,
        platformEffects: [String: PlatformEffect], model: Model?
    ) {
        runEffects([], ctx: [:], store: store, actions: actions, dialogs: dialogs,
                   platformEffects: platformEffects, model: model)
    }

    private static func runBehaviors(
        _ behaviors: [[String: Any]], value: Any?, store: StateStore,
        actions: [String: Any]?, dialogs: [String: Any]?,
        platformEffects: [String: PlatformEffect], model: Model?, host: Host,
        extra: [String: Any] = [:], event: [String: Any]? = nil
    ) -> Int {
        let locals = scopeLocals(host.scope, store: store).merging(extra) { _, new in new }
        var ran = 0
        for b in behaviors {
            var ctx = locals
            // A click's event is its modifiers and carries no value.
            ctx["event"] = event ?? (["value": value ?? NSNull()] as [String: Any])
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
                    // the effects, against the store. A bare identifier that
                    // evaluates to null is its own NAME (`mode: create`), as
                    // in the catalog dispatch, the reference and Rust's
                    // `dispatch_param_value`; any other null stays a null.
                    var resolved: [String: Any] = [:]
                    for (k, v) in params {
                        guard let expr = v as? String else { resolved[k] = v; continue }
                        let result = evaluate(expr, context: store.evalContext(extra: ctx))
                        if let any = result.toAny() {
                            resolved[k] = any
                        } else {
                            resolved[k] = isBareIdentifier(expr) ? expr : NSNull()
                        }
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

/// JSON equality with numbers compared by value, so a store holding `45.0`
/// equals an expression's `45`. A JSON boolean is not a number.
/// Whether behavior `b` runs: true when it declares no `condition`, else the
/// condition's truth in `context` (WIDGET_EVENTS.md, "Committing a value",
/// step 3). For a view that dispatches a behavior list itself.
func behaviorConditionHolds(_ b: [String: Any], context: [String: Any]) -> Bool {
    guard let condition = b["condition"] as? String else { return true }
    return evaluate(condition, context: context).toBool()
}

private func jsonValueEqual(_ a: Any?, _ b: Any?) -> Bool {
    let a = a is NSNull ? nil : a, b = b is NSNull ? nil : b
    switch (a, b) {
    case (nil, nil): return true
    case (nil, _), (_, nil): return false
    default: break
    }
    if let x = a as? NSNumber, let y = b as? NSNumber {
        let isBool = { (n: NSNumber) in ["c", "B"].contains(String(cString: n.objCType)) }
        if isBool(x) != isBool(y) { return false }
        return isBool(x) ? x.boolValue == y.boolValue : x.doubleValue == y.doubleValue
    }
    if a is NSNumber || b is NSNumber { return false }
    if let x = a as? String, let y = b as? String { return x == y }
    if let x = a as? [Any], let y = b as? [Any] {
        return x.count == y.count && zip(x, y).allSatisfy { jsonValueEqual($0, $1) }
    }
    if let x = a as? [String: Any], let y = b as? [String: Any] {
        return x.count == y.count && x.allSatisfy { k, v in y[k].map { jsonValueEqual(v, $0) } ?? false }
    }
    return false
}

// MARK: - The stops kind (WIDGET_EVENTS.md §The stops kind)

extension WidgetEvent {
    /// The stops kind: a shell reports a slider gesture with its raw
    /// parameters, and the slider law applies it. Its one behavior event,
    /// `commit`, is "a gesture finished".
    static let stopsKinds: Set<String> = ["gradient_slider"]
    static let stopsEvents = ["commit"]
    static let stopsGestures = ["press", "drag", "release", "press_midpoint", "drag_midpoint",
                                "release_midpoint", "add", "key"]
    static let noPress = "NoPress"
    static let lawRefused = "LawRefused"
    static let notWritable = "NotWritable"
    /// The suffix of the panel key a press snapshots into (`panel.stops__press`).
    static let pressSuffix = "__press"

    /// Apply one slider gesture to a stops widget (the reference's
    /// `widget_event.gesture`). A press snapshots the CURRENT stops (the
    /// host scope's when the view supplies one, else the store's); a drag
    /// applies the law to the snapshot and writes the stops and selection,
    /// running no behavior; a release, an add and a key also run the `commit`
    /// behaviors with `event.value` the new stops. A refusal writes nothing.
    static func gesture(
        widget: [String: Any], name: String, params: [String: Any], store: StateStore,
        panel: [String: Any]?,
        actions: [String: Any]? = nil, dialogs: [String: Any]? = nil,
        platformEffects: [String: PlatformEffect] = [:], model: Model? = nil,
        host: Host = Host()
    ) -> Result {
        guard let kind = widget["type"] as? String, stopsKinds.contains(kind) else {
            return Result(outcome: "refused", reason: wrongKind)
        }
        guard stopsGestures.contains(name) else { return Result(outcome: "refused", reason: wrongEvent) }
        if isDisabled(widget, store: store, host: host) {
            return Result(outcome: "refused", reason: disabled)
        }
        let bind = widget["bind"] as? [String: Any] ?? [:]
        func key(_ name: String) -> String? {
            guard let t = writableTarget(bind[name] as? String), t.scope == "panel" else { return nil }
            return t.key
        }
        guard let pid = store.getActivePanelId(), let stopsKey = key("stops"),
              let stopKey = key("selected_stop_index"), let midKey = key("selected_midpoint_index") else {
            return Result(outcome: "refused", reason: notWritable)
        }
        let pressKey = stopsKey + pressSuffix
        let shown = (host.scope?["panel"] as? [String: Any]) ?? store.getPanelState(pid)
        let refused = Result(outcome: "refused", reason: lawRefused)
        guard let stops = gradientStopsFromJSON(shown[stopsKey]) else { return refused }
        func int(_ v: Any?) -> Int? {
            guard let n = v as? NSNumber, !n.isBool else { return nil }
            return n.intValue
        }
        // Through the bind write, so the app's panel-write host (which
        // notifies the view) sees every write, as a commit's bind write does.
        func put(_ key: String, _ value: Any) {
            writeBind(("panel", key), value: value, store: store, panel: panel, host: host)
        }
        func write(_ stops: [GradientStop], _ stop: Int, _ midpoint: Int) {
            put(stopsKey, gradientStopsToJSON(stops))
            put(stopKey, stop)
            put(midKey, midpoint)
        }
        func finish(_ out: [GradientStop], _ stop: Int, _ midpoint: Int) -> Result {
            write(out, stop, midpoint)
            let value = gradientStopsToJSON(out)
            let ran = runBehaviors(declared(widget, events: stopsEvents), value: value,
                                   store: store, actions: actions, dialogs: dialogs,
                                   platformEffects: platformEffects, model: model, host: host)
            return Result(outcome: "committed", value: value, bindWritten: true, behaviorsRun: ran)
        }

        switch name {
        case "press", "press_midpoint":
            let isStop = name == "press"
            let n = isStop ? stops.count : stops.count - 1
            guard let i = int(params[isStop ? "index" : "pair"]), i >= 0, i < n else { return refused }
            // The grab (WIDGET_EVENTS.md §The stops kind): how far the pointer
            // lay from the pressed marker. A press with no number is refused,
            // never read as a grab of 0.
            guard let at = gestureNumber(params["location"]) else { return refused }
            let here = isStop ? stops[i].location
                : stops[i].location + (stops[i + 1].location - stops[i].location) * stops[i].midpointToNext / 100
            put(pressKey, ["kind": isStop ? "stop" : "midpoint", "index": i,
                           "stops": gradientStopsToJSON(stops), "grab": at - here] as [String: Any])
            write(stops, isStop ? i : -1, isStop ? -1 : i)
            return Result(outcome: "committed", bindWritten: true)
        case "drag", "release", "drag_midpoint", "release_midpoint":
            let isStop = name == "drag" || name == "release"
            guard let snap = store.getPanel(pid, pressKey) as? [String: Any],
                  snap["kind"] as? String == (isStop ? "stop" : "midpoint"),
                  let at = int(snap["index"]), let press = gradientStopsFromJSON(snap["stops"]) else {
                return Result(outcome: "refused", reason: noPress)
            }
            // The pointer less the grab, so the marker moves by how far the
            // pointer moved; a location that is not a number goes to the law as is.
            let grab = gestureNumber(snap["grab"]) ?? 0
            let location: Any? = gestureNumber(params["location"]).map { $0 - grab } ?? params["location"]
            let out: [GradientStop], stop: Int, midpoint: Int
            if isStop {
                guard let (o, sel) = dragStop(press, index: at, location: location,
                                              dy: params["dy"]) else { return refused }
                (out, stop, midpoint) = (o, sel, -1)
            } else {
                guard let o = dragMidpoint(press, pair: at, location: location) else { return refused }
                (out, stop, midpoint) = (o, -1, at)
            }
            if name.hasPrefix("drag") {
                write(out, stop, midpoint)
                return Result(outcome: "committed", value: gradientStopsToJSON(out), bindWritten: true)
            }
            put(pressKey, NSNull())
            return finish(out, stop, midpoint)
        case "add":
            guard let (out, at) = addStop(stops, location: params["location"]) else { return refused }
            return finish(out, at, -1)
        default:
            // key: GRADIENT.md's keyboard table.
            let k = params["key"] as? String ?? ""
            let shift = (params["shift"] as? NSNumber)?.boolValue ?? false
            func to(_ here: Double) -> Double? {
                switch k {
                case "Home": return 0
                case "End": return 100
                case "Left": return here - (shift ? 10 : 1)
                case "Right": return here + (shift ? 10 : 1)
                default: return nil
                }
            }
            if let stop = int(shown[stopKey]) ?? int(store.getPanel(pid, stopKey)),
               stop >= 0, stop < stops.count {
                let got: ([GradientStop], Int)?
                if k == "Delete" || k == "Backspace" {
                    got = deleteStop(stops, index: stop)
                } else if let v = to(stops[stop].location) {
                    got = dragStop(stops, index: stop, location: v, dy: 0)
                } else {
                    return Result(outcome: "inert")
                }
                guard let (out, sel) = got else { return refused }
                return finish(out, sel, -1)
            }
            if let mid = int(shown[midKey]) ?? int(store.getPanel(pid, midKey)),
               mid >= 0, mid + 1 < stops.count {
                guard let v = to(stops[mid].midpointToNext) else { return Result(outcome: "inert") }
                guard let out = setMidpoint(stops, pair: mid, value: v) else { return refused }
                return finish(out, -1, mid)
            }
            return Result(outcome: "inert")
        }
    }
}

/// A gesture parameter as a number; nil for anything else, a JSON boolean
/// included (`JSONSerialization` hands one over as an NSNumber, and so does
/// a Swift `Bool`).
private func gestureNumber(_ value: Any?) -> Double? {
    guard let n = value as? NSNumber, !n.isBool else { return nil }
    return n.doubleValue
}
