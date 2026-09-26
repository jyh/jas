import Foundation

/// The Swift app's panel and dialog widget events.
///
/// `YamlPanelBodyView` routes a value widget's commit, and a boolean
/// widget's press, through here. This drives ``WidgetEvent`` (the contract,
/// `WIDGET_EVENTS.md`) with the app's host:
///
/// * **the scope** the view rendered the widget with, so the disabled check
///   and a press's current value read what the person saw;
/// * **the bind write** through ``commitPanelWidgetValue`` (the panel-write
///   host: the per-panel rules and `notifyPanelStateChanged`), or the dialog
///   overlay's write closure;
/// * **the dispatch** through ``dispatchPanelAction``, whose native
///   intercepts (`set_concept_param`, …) a catalog dispatch would miss.
///
/// It is a value the view builds per event and the tests build the same way,
/// so the wiring is driven without a view.
struct PanelWidgetEvents {
    let model: Model
    /// The panel the widget belongs to; nil for a dialog widget.
    let panelId: String?
    /// The view's render scope (`YamlElementView.context`).
    var scope: [String: Any] = [:]
    var onDialogWrite: ((String, Any?) -> Void)? = nil
    var onDialogOpened: (() -> Void)? = nil
    var onDialogClosed: (() -> Void)? = nil

    /// Commit `text` into an input widget. A nil `text` is a commit that
    /// carried no value.
    @discardableResult
    func commit(_ widget: [String: Any], text: String?) -> WidgetEvent.Result {
        run { host, panel, ws in
            WidgetEvent.commit(widget: widget, text: text, store: model.stateStore,
                               panel: panel, actions: ws?.actions(),
                               dialogs: ws?.dialogs(),
                               platformEffects: alignPlatformEffects(model: model),
                               host: host)
        }
    }

    /// Press a boolean widget.
    @discardableResult
    func press(_ widget: [String: Any]) -> WidgetEvent.Result {
        run { host, panel, ws in
            WidgetEvent.press(widget: widget, store: model.stateStore, panel: panel,
                              actions: ws?.actions(), dialogs: ws?.dialogs(),
                              platformEffects: alignPlatformEffects(model: model),
                              host: host)
        }
    }

    /// Pick a dropdown item by its `value`: `toggle`, or with Alt held
    /// `alt_toggle` (WIDGET_EVENTS.md, "Picking a dropdown item").
    @discardableResult
    func pick(_ widget: [String: Any], value: String, alt: Bool) -> WidgetEvent.Result {
        run { host, panel, ws in
            WidgetEvent.pick(widget: widget, itemValue: value,
                             event: alt ? "alt_toggle" : "toggle",
                             store: model.stateStore, panel: panel,
                             actions: ws?.actions(), dialogs: ws?.dialogs(),
                             platformEffects: alignPlatformEffects(model: model),
                             host: host)
        }
    }

    private func run(
        _ event: (WidgetEvent.Host, [String: Any]?, WorkspaceData?) -> WidgetEvent.Result
    ) -> WidgetEvent.Result {
        let store = model.stateStore
        let ws = WorkspaceData.load()
        let panel = panelId.flatMap { ws?.panel($0) }
        if let pid = panelId {
            // `panel.` targets and `set_panel_state` write the active panel.
            store.setActivePanel(pid)
            Self.seedTwoWayGlobals(panel: panel, panelId: pid, store: store)
        }
        let dialogBefore = store.getDialogId()
        let host = WidgetEvent.Host(scope: scope, writeBind: writeBind, dispatch: dispatch)
        let result = event(host, panel, ws)
        if result.outcome == "committed" {
            // A behavior's store writes bypass commitPanelField's bump, and
            // a bound widget re-reads only when the version moves.
            model.panelStateVersion &+= 1
        }
        if dialogBefore != nil, store.getDialogId() == nil {
            onDialogClosed?()
        }
        return result
    }

    private func writeBind(scope: String, key: String, value: Any?, global: String?) {
        guard scope == "panel" else {
            onDialogWrite?(key, value)
            return
        }
        guard let pid = panelId else { return }
        var value = value
        if value == nil, pid == "character_panel_content", key == "leading" {
            // Character `leading` is Auto when the element's line_height is
            // empty; clearing the field re-derives the Auto-tracked value
            // (font_size × 1.2) explicitly so the apply pipeline writes
            // line_height back as the empty element attribute and the next
            // render reads a concrete number into the input. Mirrors the
            // Rust `render_length_input` Character branch. font_size comes
            // from the live selection, so a freshly-opened panel (stored
            // defaults don't yet match the selection) still derives Auto
            // from the element's actual font size.
            let live = characterPanelLiveOverrides(model: model)
            let fs = (live?["font_size"] as? Double)
                ?? ((model.stateStore.getPanel("character_panel_content", "font_size")
                     as? NSNumber)?.doubleValue ?? 12.0)
            value = fs * 1.2
        }
        commitPanelWidgetValue(model: model, panelId: pid, key: key, value: value,
                               mirror: global)
    }

    private func dispatch(_ action: String, _ params: [String: Any], _ ctx: [String: Any]) {
        dispatchPanelAction(action, params: params,
                            actions: WorkspaceData.load()?.actions(), ctx: ctx,
                            store: model.stateStore, model: model,
                            onDialogOpened: onDialogOpened)
    }

    /// Swift hydrates a panel from its `state:` defaults and never runs its
    /// `init:`, and the app store is not seeded with the bundle's `state`
    /// defaults. So a field and the global it is two-way bound to can start
    /// with the global ABSENT, and a behavior that flips both
    /// (`not state.magic_wand_fill_color`) would flip a null and leave the
    /// two disagreeing. Before an event, each absent bound global takes its
    /// field's value: the one value the contract says they are.
    static func seedTwoWayGlobals(panel: [String: Any]?, panelId: String,
                                  store: StateStore) {
        guard let initMap = panel?["init"] as? [String: Any] else { return }
        for key in initMap.keys.sorted() {
            guard let global = WidgetEvent.mirroredGlobal(panel: panel, key: key),
                  store.get(global) == nil,
                  let field = store.getPanel(panelId, key), !(field is NSNull)
            else { continue }
            store.set(global, field)
        }
    }
}

// MARK: - The panel-write host and the panel action dispatcher

/// Commit a write to the panel state: store → bump version →
/// fire the `notify_panel_state_changed` hook. `mirror` is the global the
/// field is two-way bound to, written right after the field.
///
/// The Character panel used to PUSH `characterPanelLiveOverrides` into
/// the store here, so that the apply pipeline — which rebuilt the whole
/// attribute set from panel state — saw the selection's values for the
/// fields the user had not touched. That mitigation is gone: the apply is
/// field-scoped and reads a multi-field group's siblings from the ELEMENT
/// (CHARPANEL, `characterWithGroup`). Keeping the push would have left
/// this port with preservation semantics the law never stated and the Rust
/// port never had — which is how the two ports came to disagree about what
/// the same click meant. The live overrides remain a PULL, merged into the
/// panel's render scope by `DockPanelView.buildPanelCtx`.
/// `terminal` marks a finished edit (slider pointer-up, Enter / blur in a
/// value box) as opposed to a live drag tick; it is passed straight through
/// to ``notifyPanelStateChanged``, whose Color branch is the only reader.
func commitPanelField(
    model: Model, panelId pid: String, key: String, value: Any?,
    terminal: Bool = false, mirror: String? = nil
) {
    // Paragraph panel — Phase 4. Sync the live wrapper attrs
    // first so untouched fields hold the selection's current
    // values, then apply mutual exclusion side effects (clear
    // sibling alignment radios; clear bullets / numbered_list
    // sibling) so the panel state is internally coherent before
    // the apply pipeline writes it back to the wrappers.
    if pid == "paragraph_panel_content" {
        let overrides = paragraphPanelLiveOverrides(model: model)
        for (k, v) in overrides { model.stateStore.setPanel(pid, k, v) }
        applyParagraphPanelMutualExclusion(
            store: model.stateStore, key: key, value: value)
    }
    model.stateStore.setPanel(pid, key, value)
    // The two-way bind (WIDGET_EVENTS.md, "The bound target"): the global
    // this field is one value with, written in the same step, so the
    // apply below reads both halves fresh.
    if let mirror { model.stateStore.set(mirror, value) }
    // LINKSCALE: the Stroke arrowhead-scale combos bind `panel.<field>`
    // only, but applyStrokePanelToSelection reads the scale from the
    // GLOBAL `stroke_<field>`. Mirror the committed scale into the
    // global (matching Rust's unified two-way write) BEFORE the
    // notify/apply below so the fresh value reaches the selection.
    if pid == "stroke_panel_content" {
        mirrorStrokeScaleCommitToGlobal(
            store: model.stateStore, key: key, value: value)
    }
    // Properties panel field edit → apply to the selection (Part B.2).
    // Per-field: the key tells us which (prop_x moves, prop_w scales, …).
    // The display is pull (propertiesPanelLiveOverrides), so the mutated
    // selection re-renders the new value — no sync↔apply loop.
    if pid == "properties_panel_content", key.hasPrefix("prop_") {
        applyPropertiesField(controller: Controller(model: model),
                             field: String(key.dropFirst("prop_".count)),
                             value: value)
    }
    model.panelStateVersion &+= 1
    // Name the committed field: the Stroke panel's apply is
    // field-scoped (it writes only that field's group and preserves
    // the rest from the element). See applyStrokePanelToSelection.
    notifyPanelStateChanged(pid, store: model.stateStore, model: model,
                            edited: key, terminal: terminal)
}

/// A panel widget's edit: ``commitPanelField``, plus the Color panel's
/// channel and hex rules. (A dialog edit goes to the dialog overlay's
/// write closure instead, which the caller owns.)
func commitPanelWidgetValue(
    model: Model, panelId: String, key: String, value: Any?, mirror: String? = nil
) {
    // A Color panel channel box (H / S / B / R / G / Bl / C / M / Y / K)
    // commits on Enter / blur, which is a TERMINAL write: the store
    // holds the typed value, and commitPanelField's notify hook
    // recomputes the paint through the one overlaid reader and pushes it
    // with `setActiveColor` (one undo step, recent strip, app tier).
    // Mirrors Rust's `PanelKind::Color` arm in render_number_input's
    // onchange handler, which likewise computes from the overlaid panel
    // map and calls `set_active_color`.
    let colorChannelKeys: Set<String> = [
        "h", "s", "b", "r", "g", "bl", "c", "m", "y", "k",
    ]
    let isColorChannel = panelId == "color_panel_content"
        && colorChannelKeys.contains(key)
    commitPanelField(model: model, panelId: panelId, key: key, value: value,
                     terminal: isColorChannel, mirror: mirror)
    // The HEX field is not a channel: the typed string is the whole
    // colour, and a hex edit does not ripple back into h/s/b/r/g/bl, so
    // the channel reader would answer with the PREVIOUS colour. Parse
    // the string instead. In Web Safe RGB mode snap each channel to the
    // nearest multiple of 51 (0/51/102/153/204/255) first.
    if panelId == "color_panel_content", key == "hex",
       let hexStr = value as? String,
       var color = ColorPanel.colorFromHex(hexStr)
    {
        let mode = model.stateStore.getPanel(
            "color_panel_content", "mode") as? String
        if mode == "web_safe_rgb" {
            let (r, g, b, _) = color.toRgba()
            func snap(_ v: Double) -> Double {
                let n = (v * 255.0 / 51.0).rounded() * 51.0
                return min(max(n, 0), 255) / 255.0
            }
            color = Color.rgb(r: snap(r), g: snap(g), b: snap(b), a: 1.0)
        }
        ColorPanel.setActiveColor(color, model: model)
    }
}

/// Dispatch a YAML action by looking it up in the actions catalog
/// and running its effects, plus any native side-effects (e.g.
/// set_active_color updates ColorPanel state). Mirrors
/// run_yaml_effects in the Rust port. `onDialogOpened` bridges a dialog the
/// action opened to the SwiftUI overlay.
func dispatchPanelAction(
    _ name: String, params: [String: Any],
    actions: [String: Any]?, ctx: [String: Any],
    store: StateStore, model: Model, onDialogOpened: (() -> Void)?
) {
    // Native fast-path for color-panel actions — these need
    // model-level state changes (ColorPanel.setActiveColor pushes
    // to the recent strip and updates default fill / stroke)
    // that the generic effects pipeline doesn't know about.
    switch name {
    case "set_active_color":
        if let hexAny = params["color"],
           let hex = hexAny as? String,
           let color = ColorPanel.colorFromHex(hex)
        {
            ColorPanel.setActiveColor(color, model: model)
            return
        }
    case "set_active_color_none":
        // Mirror ColorPanel.setActiveColor: update both the
        // tab-level default and the active selection so clicking
        // the None swatch with a shape selected drops that shape's
        // fill (or stroke). Without the selection write, the swatch
        // appeared inert when the user expected the rectangle's
        // fill to clear.
        //
        // The APP tier goes too, as it does in `applyActiveColorWrite` and
        // in Rust's `fill_color` / `stroke_color` arms: it is what a
        // no-selection read falls back to, so clearing only the document
        // tier would answer this click with the seeded white whenever
        // nothing is selected (see `Model.appDefaultFill`).
        let ctrl = Controller(model: model)
        if model.fillOnTop {
            model.appDefaultFill = nil
            model.defaultFill = nil
            if !model.document.selection.isEmpty {
                // One undo step: withTxn opens the bracket, setSelectionFill
                // (editDocument) joins it.
                model.withTxn { ctrl.setSelectionFill(nil) }
            }
        } else {
            model.appDefaultStroke = nil
            model.defaultStroke = nil
            if !model.document.selection.isEmpty {
                model.withTxn { ctrl.setSelectionStroke(nil) }
            }
        }
        return
    case "new_symbol", "place_instance", "delete_symbol_action":
        // Symbols panel footer buttons. Native intercept: mint ids by
        // the value-in-op rule and call the shared symbol Controller
        // ops (the YAML actions are `log` stubs). Mirrors the Rust
        // `dispatch_action` symbol arms; the reference-aware delete
        // confirm is a synchronous native modal. The panel's
        // `selected_symbol` is already pinned in the store as the
        // active panel, so SymbolsPanel reads / writes it directly.
        SymbolsPanel.dispatchSymbolAction(name, model: model)
        return
    case "place_concept_instance", "promote_to_concept":
        // Concepts panel: native intercept (the YAML action is a `log`
        // stub). `place_concept_instance` builds a Generated from the
        // panel-selected concept + its default params (id minted value-in-op);
        // `promote_to_concept` (CONCEPTS.md §10 — the fitter / promote)
        // detects + replaces the single selected raw shape with a Generated.
        // WITHOUT this native arm, `promote_to_concept` falls through to its
        // YAML `log` stub and never fires — the Swift analogue of the Rust
        // dispatch-gate bug. Mirrors the Rust dispatch arm.
        ConceptsPanel.dispatch(name, model: model)
        return
    case "set_concept_param":
        // Concepts panel Slice 2: native intercept (the YAML action is a
        // `log` stub). The committed field value arrives as `event.value`
        // (params.value) alongside the declared `param.name` (params.name);
        // write it onto the single selected Generated instance so it
        // re-generates live. Mirrors the Rust `set_concept_param` arm.
        if let pname = params["name"] as? String {
            let value: Double = {
                if let d = params["value"] as? Double { return d }
                if let i = params["value"] as? Int { return Double(i) }
                if let s = params["value"] as? String, let d = Double(s) { return d }
                return 0
            }()
            ConceptsPanel.setParam(model: model, name: pname, value: value)
        }
        return
    case "apply_concept_operation":
        // Concepts panel Slice 3 (CONCEPTS.md §9): native intercept (the YAML
        // action is a `log` stub). The operation id arrives as `params.op_id`;
        // resolve its `set:` expressions over the single selected Generated
        // instance's current params and bake the result into the op.
        // Mirrors the Rust `apply_concept_operation` arm.
        if let opId = params["op_id"] as? String {
            ConceptsPanel.applyOperation(model: model, opId: opId)
        }
        return
    default:
        break
    }
    // Fall through to the generic YAML actions catalog.
    guard let actions = actions,
          let actionDef = actions[name] as? [String: Any],
          let effects = actionDef["effects"] as? [Any] else {
        return
    }
    var ctxWithParams = ctx
    // Declared param defaults under the caller's params, same law as the
    // other two generic dispatchers (``LayersPanel/dispatchYamlAction``,
    // ``runYamlActionByName``) and as Rust's `dispatch_action`. Stated once
    // in ``mergeDeclaredParamDefaults``.
    ctxWithParams["param"] = mergeDeclaredParamDefaults(
        params, actionDef: actionDef)
    let platformEffects = alignPlatformEffects(model: model)
    // Thread the dialogs catalog so open_dialog effects can
    // resolve their target id (e.g. swatch_options); without
    // this, double-clicking a swatch fired the action but the
    // dialog never opened.
    let ws = WorkspaceData.load()
    let dialogs = ws?.data["dialogs"] as? [String: Any]
    let beforeDlg = store.getDialogId()
    runEffects(effects, ctx: ctxWithParams, store: store,
               actions: actions, dialogs: dialogs,
               platformEffects: platformEffects)
    // Bridge a store-level dialog transition to the SwiftUI
    // overlay — without this, open_dialog effects from widget
    // clicks left the dialog state in the store but nothing
    // surfaced. Mirrors `dispatchWithDialogBridge` in
    // DockPanelView (used for hamburger-menu dispatches).
    if store.getDialogId() != beforeDlg {
        // No anchor: widget-action opens (e.g. swatch options) are
        // modal and stay centered.
        onDialogOpened?()
    }
}
