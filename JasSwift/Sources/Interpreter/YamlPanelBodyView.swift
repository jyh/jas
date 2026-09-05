/// SwiftUI view that renders a panel body from its YAML content spec.
///
/// Maps YAML element types to SwiftUI views: container → VStack/HStack,
/// text → Text, slider → Slider, color_swatch → colored Rectangle, etc.

import SwiftUI
import AppKit

private struct PickerEntry: Identifiable {
    let id: Int
    let val: String
    let displayLabel: String
}

/// Does a NULL from this colour bind mean "explicitly no paint", or "no such
/// entry"?
///
/// The value cannot tell them apart, and they must render differently:
/// `state.fill_color` is null because the user set the attribute to None (draw
/// the red-diagonal indicator), while `panel.recent_colors.3` is null because
/// that slot has never been filled (draw a hollow placeholder). So decide from
/// the bind's own DECLARATION instead: a global `state.<key>` read whose
/// `workspace/state.yaml` schema entry is a NULLABLE COLOUR carries the "none"
/// meaning; every other bind keeps the placeholder.
///
/// Mirrors Rust's `null_color_means_none` (jas_dioxus interpreter/renderer.rs)
/// key-for-key, reading the same schema table.
func nullColorMeansNone(_ bindExpr: String) -> Bool {
    let key = bindExpr.hasPrefix("state.")
        ? String(bindExpr.dropFirst("state.".count))
        : bindExpr
    guard let entry = getSchemaEntry(key) else { return false }
    return entry.nullable && entry.fieldType == .color
}

/// Lower-right corner triangle marking a toolbar slot that carries
/// long-press ``alternates`` (so the user knows a long-press reveals more
/// tools). Mirrors jas_dioxus ``render_icon_button``'s 5x5 SVG
/// `M 5 5 L 0 5 L 5 0 Z` — a right triangle filling the lower-right half of
/// the box, filled with the theme text color (Rust's `var(--jas-text)`).
private struct FlyoutAlternatesTriangle: Shape {
    func path(in rect: CGRect) -> SwiftUI.Path {
        var p = SwiftUI.Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY))   // bottom-right
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)) // bottom-left
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)) // top-right
        p.closeSubpath()
        return p
    }
}

/// Resolve an icon_button glyph size (points) from its ``style`` map,
/// the eval ``context``, and an optional flyout-scoped default.
///
/// Three scopes, matching the OCaml app:
///   * TOOLBAR slots set ``style.size: "{{theme.sizes.tool_button}}"``;
///     the ``{{...}}`` template resolves through ``context`` to the
///     literal theme size (32). A bare numeric / "px"-suffixed string
///     also resolves here (panel dialogs that hard-code a size).
///   * FLYOUT (tool-alternates) items declare NO size; with
///     ``flyoutDefault == 28`` (set only by the non-modal dialog body)
///     they render at 28 — OCaml's ``nonmodal_icon_size := Some 28``.
///   * PANEL icon_buttons declare no size and get no flyout default, so
///     they fall through to the 20pt panel default — UNCHANGED.
///
/// An explicit ``style.size`` always wins over ``flyoutDefault``, so
/// hard-coded sizes (and any future ``size:`` added to shared YAML)
/// stay authoritative.
func resolveIconButtonSize(
    style: [String: Any], context: [String: Any], flyoutDefault: CGFloat?
) -> CGFloat {
    if let raw = style["size"] {
        if let n = raw as? Double { return CGFloat(n) }
        if let n = raw as? Int { return CGFloat(n) }
        if let s = raw as? String {
            // ``{{theme.sizes.tool_button}}`` and friends: resolve the
            // template against the eval context (the toolbar context
            // carries ``theme.sizes``), then parse the numeric result.
            let resolved = s.contains("{{") ? evaluateText(s, context: context) : s
            if let n = Double(
                resolved.trimmingCharacters(in: CharacterSet(charactersIn: "px "))) {
                return CGFloat(n)
            }
        }
    }
    return flyoutDefault ?? 20
}

/// Renders a YAML element tree as a SwiftUI view.
struct YamlElementView: View {
    let element: [String: Any]
    let context: [String: Any]
    var model: Model?
    /// ID of the enclosing panel — widget write-backs (onChange) route
    /// through `model.stateStore.setPanel(panelId, key, value)` when
    /// non-nil. `nil` in dialog / non-panel contexts; writes fall back
    /// to the legacy no-op for now.
    var panelId: String? = nil
    /// Called for widget-level ``action:`` dispatches (button / icon
    /// button clicks with an ``action:`` key rather than a
    /// ``behavior: [{event: click, effects: ...}]`` block). Receives
    /// the action name and the resolved param dict (param expressions
    /// already evaluated against ``context``).
    /// YAML dialogs set this to a closure that special-cases
    /// ``dismiss_dialog`` and otherwise routes through
    /// ``LayersPanel.dispatchYamlAction``. Nil elsewhere (panel
    /// content has no widget-level ``action:`` today).
    var onWidgetAction: ((String, [String: Any]) -> Void)? = nil
    /// Active theme, threaded for ``icon_button`` SVG rendering
    /// (``WorkspaceIcon`` tints ``currentColor`` with ``theme.text``).
    /// Nil call sites (e.g. early init) fall back to the text-stub
    /// rendering of ``icon_button``.
    var theme: Theme? = nil
    /// Flyout-scoped default icon size, in points. Set to 28 only by the
    /// non-modal tool-alternates flyout (``YamlDialogView.dialogBody``
    /// when ``!isModal``); nil everywhere else, so panel icon_buttons
    /// keep their 20pt default. Mirrors OCaml's
    /// ``Yaml_panel_view.nonmodal_icon_size := Some 28`` scoped around
    /// the non-modal dialog render. Propagated to child
    /// ``YamlElementView``s so nested flyout items inherit it.
    var flyoutIconDefault: CGFloat? = nil
    /// Set by YAML dialogs to receive widget write-backs whose
    /// ``bind.value`` / ``bind.checked`` expression starts with
    /// ``dialog.``. Without it, dialog widgets are read-only — typing
    /// into a number_input bound to ``dialog.bleed_top`` would resolve
    /// to a no-op and the rendered value would snap back to whatever
    /// the dialog state held when the field rendered. Mirrors the Rust
    /// dialog-signal write path (``dialog_signal.set(Some(ds))``).
    var onDialogWrite: ((String, Any?) -> Void)? = nil
    /// Called after dispatchYamlAction when a widget effect opens
    /// a dialog in the store; the closure is responsible for
    /// surfacing the dialog as a SwiftUI modal (DockPanelView
    /// supplies a closure that bridges to its yamlDialogState
    /// binding). Mirrors the menu-dispatch dialog bridge.
    ///
    /// The optional ``CGPoint`` is the popover anchor in window
    /// `.global` coords, supplied only by the toolbar long-press path
    /// (the press location captured at mouse_down). All other open
    /// paths pass nil → the bridge stamps no anchor → the overlay
    /// centers the dialog (matching Rust's anchor:None branch).
    var onStoreDialogOpened: ((CGPoint?) -> Void)? = nil
    /// Called after the click chain closes the dialog in the store
    /// (e.g. the color picker's OK / Cancel buttons). The closure
    /// owner clears its SwiftUI dialogState binding so the modal
    /// overlay dismisses too.
    var onStoreDialogClosed: (() -> Void)? = nil
    /// Double-clicking a TOOLBAR tool button opens the ACTIVE tool's
    /// options. Set only by the bundle toolbar pane; the closure reads
    /// ``state.active_tool``, looks the entry up in the bundle ``tools``
    /// map, and dispatches its options (panel / action / dialog). Nil
    /// everywhere else, so panel / dialog icon_buttons get no dblclick.
    /// The gesture is attached only on elements for which
    /// ``isToolButtonElement`` is true, so even inside the toolbar grid
    /// only the tool slots respond. Propagated through grid / container /
    /// repeat so the grid's icon_button children inherit it.
    var onToolOptionsRequest: (() -> Void)? = nil

    /// GUIEYES Swift lane: expose every YAML widget's `id` to the Accessibility
    /// API, so an out-of-process probe can ask "where is `lp_filter_button`, and
    /// is it checked?" without a screenshot.
    ///
    /// GUI_EYES.md §"Swift lane — partial, and the blocker" names this as THE
    /// unblock: *"one line per widget site ... after which the already-granted
    /// Accessibility API gives Swift the same id-addressed reflection CDP gives
    /// Rust."* It also records why it was not done then — *"that file is owned
    /// by a parallel wave, so it is deliberately untouched here"* — a
    /// precondition that expired when that wave landed.
    ///
    /// ATTACHED AT THE ONE SEAM, not at the twenty `render*` arms the note
    /// suggested. Every widget kind passes through this `body`, so a kind added
    /// tomorrow is addressable without anyone remembering to tag it. Tagging
    /// per-arm is the dispatch-ledger shape this repository keeps paying for.
    ///
    /// Anonymous widgets get `""`, which is the default anyway — the id is the
    /// YAML's own, so it is exactly the name a scenario file would use.
    var body: some View {
        bodyContent
            .accessibilityIdentifier((element["id"] as? String) ?? "")
    }

    @ViewBuilder
    private var bodyContent: some View {
        // Check bind.visible — if the expression evaluates to false, hide the element.
        if !isVisible() {
            EmptyView()
        } else if element["foreach"] != nil && element["do"] != nil {
            // Repeat directive: expand template for each item in source list.
            renderRepeat()
        } else if let tmpl = element["_template"] as? String,
                  tmpl == "fill_stroke_widget" {
            // Substitute the native FillStrokeWidget for the YAML
            // expansion so the Color panel and the toolbar render
            // the same geometry (overlapping squares + L-bend swap
            // arrow). When there's no open document, fall back to a
            // throwaway model with default white-fill / black-stroke
            // so the panel visualization stays consistent. Edits
            // disappear with the throwaway, which is fine — there's
            // no document to commit them to anyway.
            //
            // Double-click opens the color picker dialog for the
            // clicked attribute (fill or stroke), matching the YAML
            // template's `action: open_color_picker` behaviour.
            // Without this, the bypass shipped an empty closure and
            // double-click was a silent no-op.
            FillStrokeWidget(
                model: model ?? Model(),
                onDoubleClick: { [weak storeRef = model?.stateStore] forFill in
                    guard let m = model, let store = storeRef else { return }
                    let ws = WorkspaceData.load()
                    let actions = ws?.data["actions"] as? [String: Any]
                    dispatchYamlAction(
                        "open_color_picker",
                        params: ["target": forFill ? "fill" : "stroke"],
                        actions: actions,
                        ctx: colorPickerSeedContext(context, model: m),
                        store: store, model: m
                    )
                }
            )
        } else {
            let etype = element["type"] as? String ?? "placeholder"
            switch etype {
            case "container", "row", "col":
                renderContainer()
            case "grid":
                renderGrid()
            case "text":
                renderText()
            case "button":
                renderButton()
            case "icon_button":
                renderIconButton()
            case "slider":
                renderSlider()
            case "number_input":
                renderNumberInput()
            case "text_input":
                renderTextInput()
            case "length_input":
                renderLengthInput()
            case "select":
                renderSelect()
            case "icon_select":
                renderIconSelect()
            case "toggle", "checkbox":
                renderToggle()
            case "combo_box":
                renderComboBox()
            case "color_swatch":
                renderColorSwatch()
            case "color_bar":
                renderColorBar()
            case "radio_group":
                renderRadioGroup()
            case "radio":
                renderRadio()
            case "color_gradient":
                renderColorGradient()
            case "color_hue_bar":
                renderColorHueBar()
            case "gradient_tile":
                renderGradientTile()
            case "gradient_slider":
                renderGradientSlider()
            case "fill_stroke_widget":
                renderContainer()
            case "separator":
                renderSeparator()
            case "spacer":
                Spacer()
            case "disclosure":
                renderDisclosure()
            case "panel":
                renderPanel()
            case "tree_view":
                renderTreeView()
            case "element_preview":
                renderElementPreview()
            case "brush_preview":
                renderBrushPreview()
            case "tabs":
                renderTabs()
            case "icon":
                renderIcon()
            // Two of the three previously-undispatched kinds. `dropdown` stays
            // absent — see scripts/widget_dispatch_exemptions.json for the row
            // and its machine-checked justification.
            //
            // AN EARLIER VERSION OF THIS COMMENT WAS WRONG, and the way it was
            // wrong is worth keeping: it said the Layers element-type filter
            // "needs native state and tree filtering", implying this port had
            // neither. It has both, and has for months — `hiddenTypes`,
            // `layersTypeValue`, `layersTypeFilterKeep`. The false clause came
            // from the exemption row, was copied here, and then the two agreed
            // with each other; a seat read them and set out to build what
            // already shipped. Consensus among copies is not evidence.
            //
            // The real gap: this port draws the search field and the filter
            // menu NATIVELY inside `renderTreeView`, which `layers.yaml`
            // already declares as `lp_search_input` + `lp_filter_button`. So
            // the artist gets the search box twice and two filter controls, the
            // YAML one an inert placeholder. jas_dioxus renders both from the
            // YAML and duplicates neither. Adding an arm here alone would give
            // a THIRD control; the fix is to delete the native pair.
            case "dropdown":
                renderDropdown()
            case "icon_button_group":
                renderIconButtonGroup()
            case "reference_point_widget":
                renderReferencePointWidget()
            default:
                renderPlaceholder()
            }
        }
    }

    /// Evaluate bind.visible expression. Returns true if no binding or if expression is truthy.
    private func isVisible() -> Bool {
        guard let bind = element["bind"] as? [String: Any],
              let visExpr = bind["visible"] as? String else {
            return true
        }
        return evaluate(visExpr, context: context).toBool()
    }

    /// Extract the write-back key from a `bind.value` / `bind.checked`
    /// expression. Returns the bare panel-scoped key when the expression
    /// is the simple lookup form `panel.some_key`; returns `nil` for
    /// computed expressions (they are treated as read-only for widgets).
    private func writeBackKey(_ expr: String?) -> String? {
        guard let e = expr?.trimmingCharacters(in: .whitespaces),
              e.hasPrefix("panel.") else { return nil }
        let rest = String(e.dropFirst("panel.".count))
        guard !rest.isEmpty,
              rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }
        return rest
    }

    /// Classify a `bind.value` / `bind.checked` expression as either a
    /// panel-scoped write or a dialog-scoped write. Used by widget
    /// renderers to route edits into the right state container —
    /// without this, dialog widgets bound to ``dialog.X`` would resolve
    /// the writeBackKey panel-only fast path to nil and the field would
    /// behave read-only. Mirrors Rust's ``classify_bind`` /
    /// ``BindTarget``.
    private enum WriteScope { case panel, dialog }
    private struct WriteTarget {
        let scope: WriteScope
        let key: String
    }
    private func writeBackTarget(_ expr: String?) -> WriteTarget? {
        guard let e = expr?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let rest = stripIdentifierPrefix(e, prefix: "panel.") {
            return WriteTarget(scope: .panel, key: rest)
        }
        if let rest = stripIdentifierPrefix(e, prefix: "dialog.") {
            return WriteTarget(scope: .dialog, key: rest)
        }
        return nil
    }
    private func stripIdentifierPrefix(_ e: String, prefix: String) -> String? {
        guard e.hasPrefix(prefix) else { return nil }
        let rest = String(e.dropFirst(prefix.count))
        guard !rest.isEmpty,
              rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }
        return rest
    }

    /// Commit a write to the panel state: store → bump version →
    /// fire the `notify_panel_state_changed` hook. No-op when the
    /// target key / panelId / store isn't available.
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
    private func commitPanelWrite(
        key: String, value: Any?, terminal: Bool = false
    ) {
        guard let model = model, let pid = panelId else { return }
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

    /// Dispatch a widget edit to the right state container based on the
    /// classified bind target. Panel writes go through the existing
    /// commitPanelWrite path; dialog writes route to the YAML dialog
    /// overlay's onDialogWrite closure (which updates the SwiftUI
    /// binding so the dialog re-renders with the typed value, and
    /// pushes through to ``StateStore.setDialog`` so any setter prop
    /// or on_change hook fires).
    private func commitWidgetWrite(target: WriteTarget, value: Any?) {
        switch target.scope {
        case .panel:
            // A Color panel channel box (H / S / B / R / G / Bl / C / M / Y / K)
            // commits on Enter / blur, which is a TERMINAL write: the store
            // holds the typed value, and commitPanelWrite's notify hook
            // recomputes the paint through the one overlaid reader and pushes it
            // with `setActiveColor` (one undo step, recent strip, app tier).
            // Mirrors Rust's `PanelKind::Color` arm in render_number_input's
            // onchange handler, which likewise computes from the overlaid panel
            // map and calls `set_active_color`.
            let colorChannelKeys: Set<String> = [
                "h", "s", "b", "r", "g", "bl", "c", "m", "y", "k",
            ]
            let isColorChannel = panelId == "color_panel_content"
                && colorChannelKeys.contains(target.key)
            commitPanelWrite(key: target.key, value: value,
                             terminal: isColorChannel)
            // The HEX field is not a channel: the typed string is the whole
            // colour, and a hex edit does not ripple back into h/s/b/r/g/bl, so
            // the channel reader would answer with the PREVIOUS colour. Parse
            // the string instead. In Web Safe RGB mode snap each channel to the
            // nearest multiple of 51 (0/51/102/153/204/255) first.
            if panelId == "color_panel_content", target.key == "hex",
               let model = model, let hexStr = value as? String,
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
        case .dialog:
            onDialogWrite?(target.key, value)
        }
    }

    // MARK: - Repeat

    /// Expand a repeat directive: evaluate the source expression to get a list,
    /// then render the template element once per item with the loop variable
    /// injected via Scope for proper static scoping.
    @ViewBuilder
    private func renderRepeat() -> some View {
        let repeatSpec = element["foreach"] as? [String: Any] ?? [:]
        let template = element["do"] as? [String: Any] ?? [:]
        let sourceExpr = repeatSpec["source"] as? String ?? ""
        let varName = repeatSpec["as"] as? String ?? "item"

        // Build scope from context and evaluate source
        let scope = Scope(context)
        let items = evaluateToList(sourceExpr, context: context)

        let layout = element["layout"] as? String ?? "column"
        let gap = (element["style"] as? [String: Any])?["gap"] as? CGFloat ?? 0

        if layout == "wrap" {
            // Read the template's intrinsic width (e.g. swatch
            // tile size) so the adaptive grid packs cells tightly
            // — the previous fixed minimum of 20pt left a ~4pt
            // horizontal gap when cells were the default 16pt
            // swatch size, which read as a wide horizontal seam.
            let templateWidth: CGFloat = {
                if let style = template["style"] as? [String: Any] {
                    if let size = style["size"] as? CGFloat { return size }
                    if let size = style["size"] as? Int { return CGFloat(size) }
                    if let w = style["width"] as? CGFloat { return w }
                    if let w = style["width"] as? Int { return CGFloat(w) }
                }
                return 16
            }()
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: templateWidth), spacing: gap)],
                spacing: gap
            ) {
                ForEach(0..<items.count, id: \.self) { i in
                    let childScope = scope.extend(itemBindings(varName, item: items[i], index: i))
                    YamlElementView(element: template, context: childScope.toDict(), model: model, panelId: panelId, onWidgetAction: onWidgetAction, theme: theme, flyoutIconDefault: flyoutIconDefault, onDialogWrite: onDialogWrite, onStoreDialogOpened: onStoreDialogOpened, onStoreDialogClosed: onStoreDialogClosed)
                }
            }
        } else if layout == "row" {
            HStack(spacing: gap) {
                ForEach(0..<items.count, id: \.self) { i in
                    let childScope = scope.extend(itemBindings(varName, item: items[i], index: i))
                    YamlElementView(element: template, context: childScope.toDict(), model: model, panelId: panelId, onWidgetAction: onWidgetAction, theme: theme, flyoutIconDefault: flyoutIconDefault, onDialogWrite: onDialogWrite, onStoreDialogOpened: onStoreDialogOpened, onStoreDialogClosed: onStoreDialogClosed)
                }
            }
        } else {
            VStack(spacing: gap) {
                ForEach(0..<items.count, id: \.self) { i in
                    let childScope = scope.extend(itemBindings(varName, item: items[i], index: i))
                    YamlElementView(element: template, context: childScope.toDict(), model: model, panelId: panelId, onWidgetAction: onWidgetAction, theme: theme, flyoutIconDefault: flyoutIconDefault, onDialogWrite: onDialogWrite, onStoreDialogOpened: onStoreDialogOpened, onStoreDialogClosed: onStoreDialogClosed)
                }
            }
        }
    }

    private func itemBindings(_ varName: String, item: [String: Any], index: Int) -> [String: Any] {
        var data = item
        data["_index"] = index
        return [varName: data]
    }

    /// Evaluate a source expression and return the result as a list of dictionaries.
    /// Handles both direct array values and JSON-serialized results from the evaluator.
    private func evaluateToList(_ expr: String, context: [String: Any]) -> [[String: Any]] {
        let result = evaluate(expr, context: context)
        switch result {
        case .list(let arr):
            // Convert AnyJSON items to [String: Any] dicts
            return arr.map { item in
                if let dict = item.value as? [String: Any] {
                    return dict
                } else {
                    // Wrap scalar values so they can be used in the context
                    return ["value": item.value]
                }
            }
        case .string(let s):
            // The evaluator serializes dicts/arrays to JSON strings;
            // try parsing it back as an array of objects.
            if let data = s.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return parsed
            }
            // Try as array of any
            if let data = s.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                return parsed.map { item in
                    if let dict = item as? [String: Any] { return dict }
                    return ["value": item]
                }
            }
            return []
        default:
            return []
        }
    }

    /// Extend the eval context with the loop variable and its index.
    private func extendContext(_ ctx: [String: Any], varName: String, item: [String: Any], index: Int) -> [String: Any] {
        var extended = ctx
        var itemWithIndex = item
        itemWithIndex["_index"] = index
        extended[varName] = itemWithIndex
        return extended
    }

    // MARK: - Container

    /// True when this element declares a behavior for `target`. When `target`
    /// is `double_click` it additionally matches `click_and_wait` (its alias —
    /// mirrors jas_dioxus build_mouse_event_handler, where click_and_wait
    /// routes through the double-click handler). Used by renderContainer /
    /// renderText to decide which pointer gestures to attach.
    private func behaviorHasEvent(_ target: String) -> Bool {
        guard let behaviors = element["behavior"] as? [[String: Any]] else { return false }
        return behaviors.contains { behaviorEntryMatches($0, target) }
    }

    /// Whether a single behavior `entry` fires for `eventName`.
    /// `click_and_wait` is an alias for `double_click` (mirrors jas_dioxus
    /// build_mouse_event_handler), so a double-tap dispatches it too.
    private func behaviorEntryMatches(_ entry: [String: Any], _ eventName: String) -> Bool {
        let ev = (entry["event"] as? String) ?? "click"
        if ev == eventName { return true }
        return eventName == "double_click" && ev == "click_and_wait"
    }

    @ViewBuilder
    private func renderContainer() -> some View {
        // A container with `style.border` is a group box (the Scale / Shear
        // option dialogs frame their fields this way). Draw a 1px border with
        // the resolved color, inset by the container's padding. Borderless
        // containers render unchanged (the common panel case).
        //
        // Explicit numeric width/height are applied as a fixed frame BEFORE
        // the border so a childless styled box (e.g. a Brushes-panel brush
        // tile: 48x16 + border) draws at its declared size instead of
        // collapsing to zero and rendering an invisible border. Layout
        // containers (no numeric size, or width:"100%") get nil dimensions,
        // which SwiftUI treats as "inherit" — a no-op.
        let style = element["style"] as? [String: Any] ?? [:]
        let w = containerNumericDim(style["width"])
        let h = containerNumericDim(style["height"])

        // A container may carry its own `behavior` list — the Brushes-panel
        // brush tile is a `type: container` with click (select + set
        // stroke_brush + apply) and double_click (open options). Wire those
        // the same way icon_button / color_swatch do; without this the tile
        // rendered as an inert box and clicks did nothing at all (the
        // BRUSHDEAD bug). Gate on widgetHasPointerBehavior (plus any
        // mouse_down/up press behaviors) so plain layout containers — the
        // vast majority — keep the no-listener fast path. Mirrors jas_dioxus
        // render_container.
        let hasClick = behaviorHasEvent("click")
        let hasDouble = behaviorHasEvent("double_click")
        let hasMouseDown = behaviorHasEvent("mouse_down")
        let hasMouseUp = behaviorHasEvent("mouse_up")
        let hasPress = hasMouseDown || hasMouseUp
        let interactive = widgetHasPointerBehavior(element) || hasPress
        // bind.selected_in: draw the 2px accent outline when this tile's
        // identity is a member of the bound list (shared with color_swatch
        // via widgetSelectedIn). Overrides the base 1px group-box border,
        // matching render_container where selected_border is appended last.
        let selected = widgetSelectedIn(element, context: context)

        let styled = containerStyledBody(
            width: w, height: h, style: style, selected: selected)
        if interactive {
            styled
                .contentShape(Rectangle())
                .modifier(PointerBehaviorModifier(
                    hasClick: hasClick, hasDouble: hasDouble, hasPress: hasPress,
                    onSingle: { handleWidgetClick() },
                    onDouble: { handleBehaviorClick(eventName: "double_click") },
                    onPress: { loc in
                        handleBehaviorClick(eventName: "mouse_down", pressLocation: loc)
                    },
                    onRelease: { handleBehaviorClick(eventName: "mouse_up") }
                ))
        } else {
            styled
        }
    }

    /// Apply a container's frame + border. `bind.selected_in` membership
    /// (`selected`) draws a 2px accent outline that replaces the base 1px
    /// group-box border (the brush-tile highlight), matching
    /// renderColorSwatch's selected cue and jas_dioxus render_container's
    /// selected_border. Non-selected styled boxes keep the group-box border;
    /// borderless layout containers render unchanged.
    @ViewBuilder
    private func containerStyledBody(width w: CGFloat?, height h: CGFloat?,
                                     style: [String: Any], selected: Bool) -> some View {
        let hasBorder = style["border"] != nil
        if selected {
            if hasBorder {
                containerBody()
                    .frame(width: w, height: h)
                    .padding(containerPadding(style))
                    .border(SwiftUI.Color.accentColor, width: 2)
            } else {
                containerBody()
                    .frame(width: w, height: h)
                    .border(SwiftUI.Color.accentColor, width: 2)
            }
        } else if hasBorder {
            containerBody()
                .frame(width: w, height: h)
                .padding(containerPadding(style))
                .border(containerBorderColor(style), width: 1)
        } else {
            containerBody()
                .frame(width: w, height: h)
        }
    }

    /// A container style dimension as points, or nil when absent or
    /// non-numeric (e.g. "100%"). Used to fixed-size styled boxes.
    private func containerNumericDim(_ v: Any?) -> CGFloat? {
        if let n = v as? CGFloat { return n }
        if let n = v as? Double { return CGFloat(n) }
        if let n = v as? Int { return CGFloat(n) }
        return nil
    }

    /// Padding (points) declared on a container's style, used to inset content
    /// from a group-box border. 0 when absent.
    private func containerPadding(_ style: [String: Any]) -> CGFloat {
        if let p = style["padding"] as? Int { return CGFloat(p) }
        if let p = style["padding"] as? Double { return CGFloat(p) }
        if let p = style["padding"] as? CGFloat { return p }
        return 0
    }

    /// Resolve a container's `style.border` ("1px solid {{theme.colors.border}}")
    /// to a color. Falls back to #555555 (the theme.colors.border value, matching
    /// the OCaml group-box border) when the template does not resolve to a hex,
    /// so the box always draws.
    private func containerBorderColor(_ style: [String: Any]) -> SwiftUI.Color {
        if let b = style["border"] as? String {
            let resolved = evaluateText(b, context: context)
            if let last = resolved.split(separator: " ").last.map(String.init),
               last.hasPrefix("#") {
                return cssHexColor(last)
            }
        }
        return cssHexColor("#555555")
    }

    @ViewBuilder
    private func containerBody() -> some View {
        let layout = element["layout"] as? String ?? "column"
        let etype = element["type"] as? String ?? "container"
        let isRow = layout == "row" || etype == "row"
        let gap = (element["style"] as? [String: Any])?["gap"] as? CGFloat ?? 0

        if isRow {
            // Bootstrap-style: when row children declare `col: N`,
            // honor those weights as 12-track proportional widths
            // (LAYOUT.md §Bootstrap 12-column semantics). Children
            // without `col:` take their intrinsic width and don't
            // consume budget. The custom Layout (Bootstrap12Layout)
            // sizes the row to its tallest child instead of clamping
            // to a fixed line height — without that, panels with a
            // 60-pt fill/stroke widget or a 64-pt color gradient
            // collapsed and overflowed.
            let children = (element["children"] as? [[String: Any]]) ?? []
            let weights = children.map { ($0["col"] as? Int) ?? 0 }
            let hasWeights = weights.contains { $0 > 0 }
            if hasWeights {
                bootstrapRow(children: children, weights: weights, gap: gap)
            } else {
                HStack(alignment: .center, spacing: gap) {
                    renderChildElements()
                }
            }
        } else {
            // Column / col container: VStack defaults to .center
            // horizontal alignment, which centers each child
            // horizontally within the column. Bootstrap-style YAML
            // expects left-justified content (label sits at the
            // leading edge of its col, the input next to it sits at
            // the leading edge of its col), so override to .leading.
            VStack(alignment: .leading, spacing: gap) {
                renderChildElements()
            }
        }
    }

    /// Lay out a row whose children declare `col: N` weights via the
    /// Bootstrap-12 custom Layout. Each `col: N` child claims N/12 of
    /// the row's content width minus gaps; children without `col:`
    /// take their intrinsic width and don't consume the 12-track
    /// budget. See `transcripts/LAYOUT.md` §Bootstrap 12-column
    /// semantics and §Edge cases for the exact rules.
    @ViewBuilder
    private func bootstrapRow(children: [[String: Any]], weights: [Int],
                              gap: CGFloat) -> some View {
        Bootstrap12Layout(weights: weights, gap: gap) {
            ForEach(0..<children.count, id: \.self) { i in
                YamlElementView(
                    element: children[i], context: context, model: model,
                    panelId: panelId, onWidgetAction: onWidgetAction,
                    theme: theme, flyoutIconDefault: flyoutIconDefault,
                    onDialogWrite: onDialogWrite,
                    onStoreDialogOpened: onStoreDialogOpened,
                    onStoreDialogClosed: onStoreDialogClosed,
                    onToolOptionsRequest: onToolOptionsRequest
                )
            }
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private func renderGrid() -> some View {
        let cols = element["cols"] as? Int ?? 2
        let gap = element["gap"] as? CGFloat ?? 0
        let children = element["children"] as? [[String: Any]] ?? []

        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: cols),
            spacing: gap
        ) {
            ForEach(0..<children.count, id: \.self) { i in
                YamlElementView(element: children[i], context: context, model: model, panelId: panelId, onWidgetAction: onWidgetAction, theme: theme, flyoutIconDefault: flyoutIconDefault, onDialogWrite: onDialogWrite, onStoreDialogOpened: onStoreDialogOpened, onStoreDialogClosed: onStoreDialogClosed, onToolOptionsRequest: onToolOptionsRequest)
            }
        }
    }

    // MARK: - Text

    @ViewBuilder
    private func renderText() -> some View {
        let content = element["content"] as? String ?? ""
        let text = content.contains("{{")
            ? evaluateText(content, context: context)
            : content
        let style = element["style"] as? [String: Any]
        let fontSize = style?["font_size"] as? CGFloat ?? 12
        // Resolve style.color: hex literal, or `{{theme.colors.X}}`
        // template — without this, panel labels render with SwiftUI's
        // default Text color which is too dark for the dark gray
        // theme. Falls back to the panel's theme.text NSColor when
        // unset; if even that is missing, SwiftUI default applies.
        let resolvedColor: SwiftUI.Color? = {
            guard let raw = style?["color"] as? String else {
                if let t = theme { return SwiftUI.Color(nsColor: t.text) }
                return nil
            }
            let resolved = raw.contains("{{")
                ? evaluateText(raw, context: context)
                : raw
            if let nsc = parseHexColor(resolved) {
                return SwiftUI.Color(nsColor: nsc)
            }
            if let t = theme { return SwiftUI.Color(nsColor: t.text) }
            return nil
        }()
        // A `text` widget can carry its own `behavior` list — the
        // Artboards / Symbols / Concepts list rows put their
        // `*_panel_select` click (and ap_name's `click_and_wait` rename) on
        // the label itself. Wire click / double_click the same way
        // color_swatch does; without this the label rendered as an inert
        // span and the row-select click was silently dropped (the
        // BRUSHDEAD disease). Gate on widgetHasPointerBehavior so the vast
        // majority (static labels) stay listener-free. Mirrors jas_dioxus
        // render_text, which gates its span's onclick/ondoubleclick the
        // same way.
        let hasClick = behaviorHasEvent("click")
        let hasDouble = behaviorHasEvent("double_click")
        if hasClick || hasDouble {
            styledText(text, fontSize: fontSize, color: resolvedColor)
                .contentShape(Rectangle())
                .modifier(PointerBehaviorModifier(
                    hasClick: hasClick, hasDouble: hasDouble, hasPress: false,
                    onSingle: { handleWidgetClick() },
                    onDouble: { handleBehaviorClick(eventName: "double_click") },
                    onPress: { _ in }, onRelease: {}
                ))
        } else {
            styledText(text, fontSize: fontSize, color: resolvedColor)
        }
    }

    /// The styled label body (theme color when resolved, else the SwiftUI
    /// default) shared by renderText's inert and interactive branches.
    @ViewBuilder
    private func styledText(_ text: String, fontSize: CGFloat,
                            color: SwiftUI.Color?) -> some View {
        if let c = color {
            SwiftUI.Text(text)
                .font(.system(size: fontSize))
                .foregroundColor(c)
        } else {
            SwiftUI.Text(text)
                .font(.system(size: fontSize))
        }
    }

    /// Parse a `#rrggbb` (or `#rgb`) hex string into NSColor; nil on
    /// invalid input. Used by renderText's style.color resolution.
    private func parseHexColor(_ s: String) -> NSColor? {
        var hex = s.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else {
            return nil
        }
        let r = CGFloat((v >> 16) & 0xff) / 255.0
        let g = CGFloat((v >> 8) & 0xff) / 255.0
        let b = CGFloat(v & 0xff) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    // MARK: - Button

    @ViewBuilder
    private func renderButton() -> some View {
        let staticLabel = element["label"] as? String ?? ""
        // bind.label: expression whose evaluated string replaces the
        // static label. op_make_mask uses this to flip between
        // "Make Mask" and "Release" based on selection_has_mask per
        // OPACITY.md § States.
        let label: String = {
            if let bind = element["bind"] as? [String: Any],
               let expr = bind["label"] as? String {
                if case .string(let s) = evaluate(expr, context: context) {
                    return s
                }
            }
            return staticLabel
        }()
        let isDisabled = evalBindDisabled()
        return Button(label) { handleWidgetClick() }
            .disabled(isDisabled)
    }

    // MARK: - Icon Button

    /// Static icon (no click). Used as a row label in panels like
    /// Character / Paragraph where each control gets a small glyph
    /// instead of a text label. Renders the SVG via WorkspaceIcon
    /// when the theme + icon catalog resolve, else falls back to a
    /// small empty rectangle (sized like the icon would be) so the
    /// row layout doesn't shift.
    @ViewBuilder
    private func renderIcon() -> some View {
        let name = element["name"] as? String ?? ""
        let style = element["style"] as? [String: Any] ?? [:]
        let w: CGFloat = {
            if let n = style["width"] as? CGFloat { return n }
            if let n = style["width"] as? Double { return CGFloat(n) }
            if let n = style["width"] as? Int { return CGFloat(n) }
            return 20
        }()
        if let theme = theme, !name.isEmpty,
           WorkspaceIconCache.shared.lookup(name) != nil {
            WorkspaceIcon(name: name, size: w, tint: theme.text)
        } else {
            SwiftUI.Color.clear.frame(width: w, height: w)
        }
    }

    @ViewBuilder
    private func renderIconButton() -> some View {
        let summary = element["summary"] as? String ?? ""
        let isDisabled = evalBindDisabled()
        let isChecked = evalBindChecked()
        let iconName = resolvedIconName()
        let iconSize = resolvedIconSize()
        // The Align panel's "Align To" toggles, the Stroke panel's
        // dashed/cap radio rows, etc. set bind.checked so the
        // currently active option carries a highlight. Render the
        // checked state as a tinted rounded background — matches the
        // toolbar's selected-tool affordance.
        let checkedBg: SwiftUI.Color = theme.map {
            SwiftUI.Color(nsColor: $0.buttonChecked)
        } ?? SwiftUI.Color.gray.opacity(0.3)
        // When a theme is in scope and the icon resolves through
        // WorkspaceIcon's parser (rect/line/circle/ellipse/poly/path
        // subset), render the SVG glyph; otherwise fall back to a
        // text button using the summary so the click target stays
        // accessible. Mirrors jas_dioxus's render_icon_button which
        // embeds the SVG inline.
        // Long-press alternates: the toolbar's multi-tool slots carry
        // mouse_down / mouse_up behaviors (start_timer → open_dialog /
        // cancel_timer). Layer a press-and-hold gesture over the Button
        // so those fire; a plain Button is click-only. No-op for the
        // common case (panel buttons have only `click`).
        let behaviors = element["behavior"] as? [[String: Any]] ?? []
        let hasMouseDown = behaviors.contains { ($0["event"] as? String) == "mouse_down" }
        let hasMouseUp = behaviors.contains { ($0["event"] as? String) == "mouse_up" }
        let hasPress = hasMouseDown || hasMouseUp
        // Double-click a TOOLBAR tool slot → open the active tool's
        // options. Scoped to tool slots only: ``isToolButtonElement``
        // keys on a ``click`` event dispatching ``select_tool`` (the same
        // discriminator the toolbar icon-size path uses), and the
        // dispatch closure is only non-nil inside the bundle toolbar. The
        // dblclick rides a ``simultaneousGesture`` so the single-click
        // select_tool still fires, mirroring the prior native toolbar's
        // ``TapGesture(count: 2)`` over the same buttons.
        let wantsToolOptionsDblClick = isToolButtonElement(element) && onToolOptionsRequest != nil
        let toolOptionsAction = onToolOptionsRequest
        if let theme = theme, !iconName.isEmpty,
           WorkspaceIconCache.shared.lookup(iconName) != nil {
            Button(action: { handleWidgetClick() }) {
                WorkspaceIcon(name: iconName, size: iconSize, tint: theme.text)
                    .padding(2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isChecked ? checkedBg : .clear)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        alternatesFlyoutMarker(tint: SwiftUI.Color(nsColor: theme.text))
                    }
            }
            .buttonStyle(.plain)
            .help(summary)
            .disabled(isDisabled)
            .modifier(PressDispatchModifier(
                onPress: { loc in if hasPress { handleBehaviorClick(eventName: "mouse_down", pressLocation: loc) } },
                onRelease: { if hasPress { handleBehaviorClick(eventName: "mouse_up") } }
            ))
            .modifier(ToolOptionsDblClickModifier(
                enabled: wantsToolOptionsDblClick, onDoubleClick: toolOptionsAction))
        } else {
            Button(summary) { handleWidgetClick() }
                .buttonStyle(.plain)
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isChecked ? checkedBg : .clear)
                )
                .overlay(alignment: .bottomTrailing) {
                    alternatesFlyoutMarker(
                        tint: theme.map { SwiftUI.Color(nsColor: $0.text) }
                            ?? SwiftUI.Color(white: 0.8))
                }
                .disabled(isDisabled)
                .modifier(PressDispatchModifier(
                    onPress: { loc in if hasPress { handleBehaviorClick(eventName: "mouse_down", pressLocation: loc) } },
                    onRelease: { if hasPress { handleBehaviorClick(eventName: "mouse_up") } }
                ))
                .modifier(ToolOptionsDblClickModifier(
                    enabled: wantsToolOptionsDblClick, onDoubleClick: toolOptionsAction))
        }
    }

    /// Overlay content for an icon_button: the lower-right flyout triangle,
    /// shown only when this element declares long-press ``alternates:`` (the
    /// same data-driven predicate Rust's ``render_icon_button`` keys on).
    /// `tint` is the theme text color, matching Rust's `var(--jas-text)`.
    @ViewBuilder
    private func alternatesFlyoutMarker(tint: SwiftUI.Color) -> some View {
        if iconButtonHasAlternates(element) {
            FlyoutAlternatesTriangle()
                .fill(tint)
                .frame(width: 5, height: 5)
                .allowsHitTesting(false)
        }
    }

    /// Evaluate `bind.checked` if present; returns false when absent.
    /// Used to drive the "selected" highlight on icon buttons that
    /// behave as radio toggles (e.g. Align panel's Align To row).
    private func evalBindChecked() -> Bool {
        guard let bind = element["bind"] as? [String: Any],
              let expr = bind["checked"] as? String else { return false }
        return evaluate(expr, context: context).toBool()
    }

    /// Resolve the icon_button glyph size for this element, honoring the
    /// flyout-scoped default. Delegates to the free
    /// ``resolveIconButtonSize`` so the three scopes (toolbar / flyout /
    /// panel) share one resolution path and the logic is unit-testable.
    private func resolvedIconSize() -> CGFloat {
        let style = element["style"] as? [String: Any] ?? [:]
        return resolveIconButtonSize(
            style: style, context: context, flyoutDefault: flyoutIconDefault)
    }

    /// Resolve the icon name. Resolution order mirrors jas_dioxus
    /// ``render_icon_button``:
    ///   1. ``bind.icon`` (yaml expression returning a string).
    ///   2. ``alternates.items`` lookup by ``state.active_tool`` — a
    ///      multi-tool toolbar slot (pen / pencil / shape / arrow / text
    ///      / hand) shows the glyph of the ACTIVE alternate, so the slot
    ///      icon follows the live tool. Without this the slot stays stuck
    ///      on its default glyph after picking a different alternate from
    ///      the long-press menu or via a keyboard shortcut.
    ///   3. The static ``icon`` field (fallback).
    private func resolvedIconName() -> String {
        let staticIcon = element["icon"] as? String ?? ""
        if let bind = element["bind"] as? [String: Any],
           let expr = bind["icon"] as? String {
            if case .string(let s) = evaluate(expr, context: context) {
                return s
            }
            return staticIcon
        }
        if let alternates = element["alternates"] as? [String: Any],
           let items = alternates["items"] as? [Any] {
            var active = ""
            if case .string(let s) = evaluate("state.active_tool", context: context) {
                active = s
            }
            for itemAny in items {
                guard let item = itemAny as? [String: Any],
                      let id = item["id"] as? String,
                      let icon = item["icon"] as? String else { continue }
                if id == active {
                    return icon
                }
            }
            return staticIcon
        }
        return staticIcon
    }

    /// Evaluate `bind.disabled` if present; returns `false` when
    /// absent so click remains wired.
    private func evalBindDisabled() -> Bool {
        guard let bind = element["bind"] as? [String: Any],
              let expr = bind["disabled"] as? String else { return false }
        return evaluate(expr, context: context).toBool()
    }

    /// Handle a click on a button / icon_button. Two YAML widget
    /// shapes are supported:
    ///
    /// 1. ``action: <action_name>`` with optional ``params: {...}`` —
    ///    widget-level action dispatch. Param expressions are
    ///    evaluated against the current ``context`` (so ``dialog.*``
    ///    / ``param.*`` / ``active_document.*`` refs resolve), then
    ///    the caller-supplied ``onWidgetAction`` closure runs the
    ///    action. Used by dialog OK / Cancel / Delete buttons.
    ///
    /// 2. ``behavior: [{event: click, effects: [...]}]`` — inline
    ///    effects dispatched through ``runEffects`` with the current
    ///    platform-effect registry. Pre-existing path; kept for
    ///    buttons whose behavior is a short effect list rather than
    ///    a named action.
    private func handleWidgetClick() {
        // Opacity panel: op_make_mask dispatches Controller make or
        // release based on selection_has_mask. The button has no
        // ``action`` in yaml — routing is resolved here against the
        // panel id and the element id. Mirrors the Rust special-case
        // in ``render_button``.
        if panelId == "opacity_panel_content",
           let id = element["id"] as? String, id == "op_make_mask",
           let m = model {
            let hasMask = evaluate("selection_has_mask", context: context).toBool()
            let ctrl = Controller(model: m)
            if hasMask {
                ctrl.releaseMaskOnSelection()
            } else {
                let clip = (context["_opacity_new_masks_clipping"] as? Bool) ?? true
                let invert = (context["_opacity_new_masks_inverted"] as? Bool) ?? false
                ctrl.makeMaskOnSelection(clip: clip, invert: invert)
            }
            return
        }
        // Opacity panel: op_link_indicator toggles mask.linked on
        // every selected mask via Controller. OPACITY.md §Document
        // model. Mirrors the Rust special-case in
        // ``render_icon_button``.
        if panelId == "opacity_panel_content",
           let id = element["id"] as? String, id == "op_link_indicator",
           let m = model {
            Controller(model: m).toggleMaskLinkedOnSelection()
            return
        }
        if let actionName = element["action"] as? String {
            let rawParams = (element["params"] as? [String: Any]) ?? [:]
            var resolved: [String: Any] = [:]
            for (k, v) in rawParams {
                if let exprStr = v as? String {
                    let result = evaluate(exprStr, context: context)
                    if let any = result.toAny() {
                        resolved[k] = any
                    }
                } else {
                    resolved[k] = v
                }
            }
            onWidgetAction?(actionName, resolved)
            return
        }
        handleClickBehavior()
    }

    /// Build an `event` dict capturing the current keyboard modifier
    /// flags so click effects (e.g. `select` with `mode: auto`) can
    /// dispatch shift-extend / cmd-toggle behaviors. Mirrors the
    /// `event.shift` / `event.ctrl` / `event.meta` keys read by
    /// applySelectEffect in Effects.swift.
    private func currentEventModifiers() -> [String: Any] {
        let flags = NSEvent.modifierFlags
        return [
            "shift": flags.contains(.shift),
            "ctrl": flags.contains(.control),
            "meta": flags.contains(.command),
            "alt": flags.contains(.option),
        ]
    }

    /// Run the widget's `behavior: [{event: click, effects: [...]}]`
    /// effects through the shared `runEffects` pipeline. The
    /// platform-effects registry is scoped to Align for now; other
    /// panels can extend this when they wire up their own handlers.
    private func handleClickBehavior() {
        guard let model = model else { return }
        guard let behavior = element["behavior"] as? [[String: Any]] else { return }
        let ws = WorkspaceData.load()
        let actions = ws?.data["actions"] as? [String: Any]
        let dialogs = ws?.data["dialogs"] as? [String: Any]
        let platformEffects = alignPlatformEffects(model: model)
        var ctxWithEvent = context
        ctxWithEvent["event"] = currentEventModifiers()
        // Pin the active panel id before running effects so
        // panel-scoped writes (e.g. `select`) target this widget's
        // panel rather than whichever panel rendered most recently.
        // Without this, clicking a Swatches-panel swatch wrote
        // selected_swatches to (whatever panel rendered last —
        // typically the Layers panel below it).
        if let pid = panelId {
            model.stateStore.setActivePanel(pid)
        }
        // Capture the pre-effect dialog id so a `close_dialog`
        // effect inside the click chain (color picker OK button)
        // can be bridged back to whichever overlay binding owns
        // the modal — without this the store closes the dialog
        // but the SwiftUI overlay stays visible because nothing
        // tells the dialogState binding to clear.
        let beforeDlg = model.stateStore.getDialogId()
        for entry in behavior where (entry["event"] as? String) == "click" {
            // Honor `condition:` so behavior entries can branch on
            // modifier state (e.g. Boolean panel's "alt-click =
            // make compound shape" pattern). When the condition
            // evaluates to false against the click ctx, skip this
            // entry — without this every modifier-conditional pair
            // fired both branches and the second-listed one
            // unconditionally won.
            if let cond = entry["condition"] as? String,
               !evaluate(cond, context: ctxWithEvent).toBool() {
                continue
            }
            // A click behavior may carry `effects:` (a list run
            // through runEffects), or `action:` (an action name in
            // the YAML actions catalog). The Color panel's None /
            // Black / White swatches use the latter — without
            // dispatching it here those clicks were silent.
            let effects = (entry["effects"] as? [Any]) ?? []
            if !effects.isEmpty {
                runEffects(effects, ctx: ctxWithEvent, store: model.stateStore,
                           actions: actions, dialogs: dialogs, platformEffects: platformEffects)
                // Effects like `select` write via store.setPanel,
                // which bypasses the commitPanelWrite version bump.
                // Without this, the swatch's `selected_in` binding
                // wouldn't refresh after a click and the accent
                // border would never appear.
                model.panelStateVersion &+= 1
            }
            if let actionName = entry["action"] as? String {
                let rawParams = (entry["params"] as? [String: Any]) ?? [:]
                var resolved: [String: Any] = [:]
                for (k, v) in rawParams {
                    if let exprStr = v as? String {
                        let result = evaluate(exprStr, context: context)
                        if let any = result.toAny() {
                            resolved[k] = any
                        } else {
                            // Bare-identifier convention used by params
                            // like `{ color: "#000000" }`: when the
                            // expression evaluates to null, treat a
                            // simple alphanumeric string as a literal.
                            resolved[k] = exprStr
                        }
                    } else {
                        resolved[k] = v
                    }
                }
                dispatchYamlAction(
                    actionName, params: resolved,
                    actions: actions, ctx: context,
                    store: model.stateStore, model: model
                )
            }
        }
        // Bridge: if the click chain closed the dialog (e.g. OK or
        // Cancel button), notify the overlay so it dismisses too.
        // Mirrors the open-side bridge in dispatchYamlAction. Without
        // this, color picker OK / Cancel updated the store but the
        // SwiftUI modal stayed up.
        if beforeDlg != nil, model.stateStore.getDialogId() == nil {
            onStoreDialogClosed?()
        }
    }

    /// Dispatch a YAML action by looking it up in the actions catalog
    /// and running its effects, plus any native side-effects (e.g.
    /// set_active_color updates ColorPanel state). Mirrors
    /// run_yaml_effects in the Rust port.
    private func dispatchYamlAction(
        _ name: String, params: [String: Any],
        actions: [String: Any]?, ctx: [String: Any],
        store: StateStore, model: Model
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
            onStoreDialogOpened?(nil)
        }
    }

    // MARK: - Slider

    @ViewBuilder
    private func renderSlider() -> some View {
        let minVal = element["min"] as? Double ?? 0
        let maxVal = element["max"] as? Double ?? 100
        // step: snap stride; 0/absent = continuous. Web Safe RGB
        // sliders pass step: 51 so values snap to the web-safe palette.
        let stepVal = (element["step"] as? Double)
            ?? (element["step"] as? Int).map { Double($0) }
            ?? 0
        let bind = element["bind"] as? [String: Any]
        let valueExpr: String? = (element["bind"] as? String)
            ?? bind?["value"] as? String

        // Get initial value from bind expression
        let initialValue: Double = {
            if let valueExpr {
                let result = evaluate(valueExpr, context: context)
                if case .number(let n) = result { return n }
            }
            return minVal
        }()

        let isDisabled: Bool = {
            if let disExpr = bind?["disabled"] as? String {
                return evaluate(disExpr, context: context).toBool()
            }
            return false
        }()

        // Resolve the panel-state field this slider writes to and
        // capture the model so the live drag / commit callbacks can
        // mutate state without going through the dialog write path.
        let writeTarget = writeBackTarget(valueExpr)
        let panelIdLocal = panelId
        let modelLocal = model

        HStack(spacing: 4) {
            SliderView(
                value: initialValue,
                range: minVal...maxVal,
                step: stepVal,
                onChange: { newValue in
                    handleSliderWrite(
                        target: writeTarget, value: newValue,
                        panelId: panelIdLocal, model: modelLocal,
                        commit: false
                    )
                },
                onCommit: { newValue in
                    handleSliderWrite(
                        target: writeTarget, value: newValue,
                        panelId: panelIdLocal, model: modelLocal,
                        commit: true
                    )
                }
            )
            .disabled(isDisabled)
        }
    }

    /// Apply a slider write to the panel state. On a Color panel slider the
    /// stored value IS the colour edit: ``commitPanelWrite`` fires
    /// ``notifyPanelStateChanged``, whose Color branch recomputes the paint
    /// through the one overlaid reader and applies it — live on a drag tick,
    /// committed on release (`commit`). There is no colour arithmetic here; the
    /// slider knows only which field it writes.
    private func handleSliderWrite(
        target: WriteTarget?, value: Double,
        panelId: String?, model: Model?, commit: Bool
    ) {
        guard let target = target, model != nil else { return }
        switch target.scope {
        case .panel:
            // commitPanelWrite stores the value, bumps panelStateVersion (so
            // SwiftUI re-renders bound widgets like the matching number_input
            // next to the slider), and fires the notify hook. Skipping it left
            // the slider's value invisible to its sibling input.
            commitPanelWrite(key: target.key, value: value, terminal: commit)
        case .dialog:
            onDialogWrite?(target.key, value)
        }
    }

    // MARK: - Number Input

    @ViewBuilder
    private func renderNumberInput() -> some View {
        // Declared bounds drive clamp-on-commit. Without the clamp, typing 500
        // into an R-channel field (max=255) committed 500 verbatim — the
        // resulting color went past 0xff and produced a 7-character hex like
        // "1f4ff3b" instead of clamping to 255. UNDECLARED means no clamp: an
        // `as? Int ?? 0` min substituted 0 for an absent bound, so a typed -50
        // committed -50 in jas_dioxus (`min_clamp` stays None there) and 0 here.
        // Read as Double — YAML gives an integer literal as Int and a
        // fractional one as Double, and jas_dioxus reads both as f64.
        let minClamp = (element["min"] as? Double)
            ?? (element["min"] as? Int).map(Double.init)
        let maxClamp = (element["max"] as? Double)
            ?? (element["max"] as? Int).map(Double.init)
        // Bind may be a bare string ("dialog.h") or an object form
        // ({value: "panel.x"}). Color picker fields use the bare-string
        // form via the radio_field_row template; without the fallback
        // bind reads to nil, writeTarget stays nil, and commits silently
        // no-op (the field accepts typing but Enter resets to 0).
        let valueExpr: String? = (element["bind"] as? String)
            ?? (element["bind"] as? [String: Any])?["value"] as? String
        // Kept as a Double, like jas_dioxus's `value: f64`: this used to be
        // `saturatingInt(n)`, so a bound 12.5 DISPLAYED as 12 here and as 12.5
        // there (transcripts/CORPUS_CENSUS.md §7.1 item 2). The fallback for a
        // non-number binding is the declared min, or 0 when none is declared —
        // jas_dioxus's `min` with its `unwrap_or(0.0)`.
        let currentValue: Double = {
            if let e = valueExpr {
                let result = evaluate(e, context: context)
                if case .number(let n) = result { return n }
            }
            return minClamp ?? 0
        }()
        let writeTarget = writeBackTarget(valueExpr)

        // YAML style.width: "100%" → fill the parent column, so inputs
        // align with neighboring dropdowns sharing the same col cell.
        // Numeric/missing → fixed-width 45pt (legacy default for align /
        // opacity panels that don't declare a width).
        let fillsParent = (element["style"] as? [String: Any])?["width"] as? String == "100%"
        // Use BufferedTextField (not TextField+Binding<Int>+format)
        // because the Binding<Int>+format pair fires `set` whenever
        // the bound value changes externally (e.g. color picker hex
        // commit causes K to re-derive from the new color), which
        // re-runs the channel setter and round-trips the color
        // through cmyk()/hsb()/rgb() — losing precision and visibly
        // shifting the color. Buffering commits only on actual
        // user input (Enter / blur after typing).
        BufferedTextField(
            placeholder: "",
            // Same number → string rule the expression language uses (and so
            // the same string jas_dioxus's `value: "{value}"` renders from an
            // f64): 12 shows as "12", 12.5 as "12.5".
            externalValue: numberToCanonicalString(currentValue),
            commit: { newVal in
                // `Int(newVal)` here dropped EVERY non-integer entry silently —
                // "12.5" wrote nothing at all, where jas_dioxus committed 12.5.
                // The shared rule accepts what the reference accepts for a
                // number-typed field, clamps to the declared bounds, and writes
                // nothing for anything else.
                guard let clamped = numberInputCommit(
                    text: newVal, min: minClamp, max: maxClamp) else { return }
                if let t = writeTarget { commitWidgetWrite(target: t, value: clamped) }
                // Fields bound to a non-writable expression (e.g. a foreach
                // `p.value` in the Concepts param editor) drive their effect via
                // a `behavior: [{event: change, …}]` block instead of a
                // write-back target. Dispatch it with the committed value as
                // `event.value`, mirroring the Dioxus widget framework.
                handleChangeBehavior(value: clamped)
            }
        )
            .frame(maxWidth: fillsParent ? .infinity : 45)
            .textFieldStyle(.roundedBorder)
            // Let the typed text follow the window color scheme, which now
            // tracks the active appearance (JasApp .preferredColorScheme): the
            // rounded-border field background is light under a light theme and
            // dark under a dark theme, so the inherited theme.text stays
            // legible in both. (Previously this forced .black, which became
            // dark-on-dark once the field background turned dark.)
            // When filling the parent column, leave a trailing gap so
            // the input doesn't crowd the next col-2 icon to its right.
            .padding(.trailing, fillsParent ? 24 : 0)
    }

    // MARK: - Text Input

    @ViewBuilder
    private func renderTextInput() -> some View {
        let placeholder = element["placeholder"] as? String ?? ""
        // Bind may be bare string or {value: ...} (see renderNumberInput).
        let valueExpr: String? = (element["bind"] as? String)
            ?? (element["bind"] as? [String: Any])?["value"] as? String
        let currentValue: String = {
            if let e = valueExpr {
                let result = evaluate(e, context: context)
                if case .string(let s) = result { return s }
            }
            return ""
        }()
        let writeTarget = writeBackTarget(valueExpr)

        // Buffered text-input: a direct Binding<String> commits on
        // every keystroke, which makes the panel re-render and snap
        // the field back to the previous panel-state value — the user
        // sees their typed characters disappear. Buffer in a local
        // @State and commit only on Enter / blur so the typed text
        // survives the round-trip.
        BufferedTextField(
            placeholder: placeholder,
            externalValue: currentValue,
            commit: { newVal in
                if let t = writeTarget { commitWidgetWrite(target: t, value: newVal) }
            }
        )
            .textFieldStyle(.roundedBorder)
            // Text follows the window color scheme (see renderNumberInput):
            // legible on the light field under a light theme and the dark field
            // under a dark theme.
    }

    // MARK: - Length Input

    /// Unit-aware text input for length-valued fields. Display goes
    /// through `Length.format`; commit goes through `Length.parse` and
    /// honors `min` / `max` clamps and the `nullable` flag. The bound
    /// state and committed value are pt-valued; conversion happens at
    /// the widget edge.
    @ViewBuilder
    private func renderLengthInput() -> some View {
        let unit = element["unit"] as? String ?? "pt"
        let precision = element["precision"] as? Int ?? 2
        let placeholder = element["placeholder"] as? String ?? ""
        let nullable = element["nullable"] as? Bool ?? false
        let minClamp = (element["min"] as? Double)
            ?? (element["min"] as? Int).map(Double.init)
        let maxClamp = (element["max"] as? Double)
            ?? (element["max"] as? Int).map(Double.init)

        let bind = element["bind"] as? [String: Any]
        let valueExpr = bind?["value"] as? String
        let ptValue: Double? = {
            guard let e = valueExpr else { return nil }
            let result = evaluate(e, context: context)
            switch result {
            case .number(let n): return n
            case .null: return nil
            default: return nil
            }
        }()
        let displayValue = Length.format(ptValue, unit: unit, precision: precision)
        let writeTarget = writeBackTarget(valueExpr)

        // Identity-coupled key forces remount when the bound pt value
        // changes (clamp-on-commit, external writes), pulling the
        // displayed string back in lockstep.
        let keyValue = ptValue.map { String(format: "%.6f", $0) } ?? "null"
        let stableId = "\(element["id"] as? String ?? "")-\(keyValue)"

        TextField(placeholder, text: Binding<String>(
            get: { displayValue },
            set: { newVal in
                guard let t = writeTarget else { return }
                let trimmed = newVal.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    if nullable {
                        // Character panel ``leading`` is Auto when the
                        // element's line_height is empty; clearing the
                        // field re-derives the Auto-tracked value
                        // (font_size × 1.2) explicitly so the apply
                        // pipeline writes line_height back as the empty
                        // element attribute and the next render reads
                        // a concrete number into the input. Mirrors the
                        // Rust `render_length_input` Character branch.
                        // No other Character field is nullable yet.
                        // Read font_size from the live selection
                        // overrides rather than the stored panel state
                        // so a freshly-opened panel (stored defaults
                        // don't yet match the selection) still derives
                        // Auto from the element's actual font size.
                        if t.scope == .panel,
                           panelId == "character_panel_content",
                           t.key == "leading",
                           let model = model {
                            let live = characterPanelLiveOverrides(model: model)
                            let fs = (live?["font_size"] as? Double)
                                ?? ((model.stateStore.getPanel(
                                    "character_panel_content", "font_size")
                                    as? NSNumber)?.doubleValue ?? 12.0)
                            commitWidgetWrite(target: t, value: fs * 1.2)
                        } else {
                            commitWidgetWrite(target: t, value: nil as Any?)
                        }
                    }
                    // Non-nullable empty: drop the edit; the remount on
                    // any subsequent write will redisplay the prior value.
                    return
                }
                guard var newPt = Length.parse(newVal, defaultUnit: unit) else {
                    return
                }
                if let lo = minClamp, newPt < lo { newPt = lo }
                if let hi = maxClamp, newPt > hi { newPt = hi }
                commitWidgetWrite(target: t, value: newPt)
            }
        ))
            .id(stableId)
            .textFieldStyle(.roundedBorder)
            // Text follows the window color scheme (see renderNumberInput):
            // legible on the light field under a light theme and the dark field
            // under a dark theme.
    }

    // MARK: - Color Bar

    /// HSB color picker bar (Color panel cp_color_bar). Hue varies
    /// along x; saturation/brightness along y per the spec in
    /// `transcripts/COLOR.md`. Click or drag updates the active
    /// color live; pointer-up commits it to the recent strip.
    @ViewBuilder
    private func renderColorBar() -> some View {
        // Resolve bind.disabled — when fill_color/stroke_color is
        // null the bar disables along with the sliders / hex.
        let disabled: Bool = {
            if let bind = element["bind"] as? [String: Any],
               let expr = bind["disabled"] as? String {
                return evaluate(expr, context: context).toBool()
            }
            return false
        }()
        if let model = model {
            ColorBarView(model: model, isDisabled: disabled)
        } else {
            // Without a model the bar can't commit anything, but
            // keep the visual chrome so the panel layout stays
            // consistent. A throwaway model lets the user "pick"
            // colors that nothing acts on.
            ColorBarView(model: Model(), isDisabled: true)
        }
    }

    // MARK: - Radio Group / Color Picker widgets

    /// One-or-many radio buttons sharing a single bound value.
    /// Color picker uses one option per row (channel selector).
    @ViewBuilder
    private func renderRadioGroup() -> some View {
        // Bind may be a bare string ("dialog.radio_channel") or
        // an object {value: "..."} — the color picker uses bare.
        let bindExpr: String? = (element["bind"] as? String)
            ?? (element["bind"] as? [String: Any])?["value"] as? String
        let current: String = {
            guard let e = bindExpr else { return "" }
            let result = evaluate(e, context: context)
            if case .string(let s) = result { return s }
            return ""
        }()
        let options = (element["options"] as? [[String: Any]]) ?? []
        let writeTarget = bindExpr.flatMap { writeBackTarget($0) }

        HStack(spacing: 6) {
            ForEach(0..<options.count, id: \.self) { i in
                let opt = options[i]
                let oid = (opt["id"] as? String) ?? ""
                let label = (opt["label"] as? String) ?? ""
                let checked = oid == current
                Button(action: {
                    if let t = writeTarget {
                        commitWidgetWrite(target: t, value: oid)
                    }
                }) {
                    HStack(spacing: 4) {
                        SwiftUI.Image(systemName: checked ? "circle.inset.filled" : "circle")
                            .font(.system(size: 12))
                        if !label.isEmpty {
                            SwiftUI.Text(label).font(.system(size: 11))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Single radio button: a circular indicator filled when
    /// ``bind.checked`` is truthy, followed by a label. Clicking runs the
    /// element's ``on_check`` effects (e.g. ``set: { dialog.uniform }``)
    /// through the shared ``runEffects`` pipeline — so a
    /// ``set: { dialog.X }`` routes via ``setByScopedTarget``'s dialog
    /// arm into the open dialog's scope. Honors ``bind.disabled``. The
    /// Scale / Shear option dialogs use it for the Uniform / Non-Uniform
    /// / axis mode selector. Mirrors the Python ``_render_radio`` and the
    /// reactive circle drawing of ``renderRadioGroup``.
    @ViewBuilder
    private func renderRadio() -> some View {
        let bind = element["bind"] as? [String: Any]
        let checkedExpr = bind?["checked"] as? String
        let disabledExpr = bind?["disabled"] as? String
        let label = (element["label"] as? String) ?? ""
        let onCheck = (element["on_check"] as? [Any]) ?? []

        let checked: Bool = {
            guard let e = checkedExpr else { return false }
            return evaluate(e, context: context).toBool()
        }()
        let disabled: Bool = {
            guard let e = disabledExpr else { return false }
            return evaluate(e, context: context).toBool()
        }()

        // Mirror renderRadioGroup's circle glyph + the disabled-muting
        // used by toggle. The whole row is one tap target; the tap runs
        // on_check through runEffects (so dialog.* set targets reach the
        // dialog scope) and then re-syncs the SwiftUI dialog binding so
        // both radios repaint.
        Button(action: { runRadioOnCheck(onCheck) }) {
            HStack(spacing: 6) {
                SwiftUI.Image(systemName: checked ? "circle.inset.filled" : "circle")
                    .font(.system(size: 12))
                if !label.isEmpty {
                    SwiftUI.Text(label).font(.system(size: 11))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
    }

    /// Run a radio's ``on_check`` effects through the shared
    /// ``runEffects`` pipeline, then re-sync the SwiftUI dialog binding.
    ///
    /// The effects (``set: { dialog.X: "<expr>" }``) write the open
    /// dialog's scope via ``setByScopedTarget``'s dialog arm — values
    /// are EXPRESSION STRINGS ("true"/"false"/"'horizontal'") that the
    /// set-path evaluates like every other set value. Because the dialog
    /// body renders from the ``dialogState`` SwiftUI binding (a snapshot
    /// of the store's dialog map), the bound circle won't repaint until
    /// that binding is refreshed — so after running the effects we replay
    /// the now-committed value of each written ``dialog.X`` key through
    /// ``onDialogWrite`` (idempotent for ``set``), which re-syncs the
    /// binding. No-op when there's no model / no open dialog.
    private func runRadioOnCheck(_ onCheck: [Any]) {
        guard let model = model else { return }
        let ws = WorkspaceData.load()
        let actions = ws?.data["actions"] as? [String: Any]
        let dialogs = ws?.data["dialogs"] as? [String: Any]
        runEffects(onCheck, ctx: context, store: model.stateStore,
                   actions: actions, dialogs: dialogs)
        // Re-sync the dialog binding for each dialog.<key> the on_check
        // set: targets, reading back the value the effects just wrote.
        for key in dialogSetKeys(in: onCheck) {
            onDialogWrite?(key, model.stateStore.getDialog(key))
        }
    }

    /// Collect the dialog-scoped keys written by a radio's ``on_check``
    /// effect list (the ``dialog.<key>`` targets of any ``set:`` map).
    /// Used to drive the post-effect dialog-binding re-sync.
    private func dialogSetKeys(in effects: [Any]) -> [String] {
        var keys: [String] = []
        for e in effects {
            guard let dict = e as? [String: Any],
                  let setMap = dict["set"] as? [String: Any] else { continue }
            for rawTarget in setMap.keys {
                let t = rawTarget.hasPrefix("$")
                    ? String(rawTarget.dropFirst()) : rawTarget
                if t.hasPrefix("dialog.") {
                    keys.append(String(t.dropFirst("dialog.".count)))
                }
            }
        }
        return keys
    }

    /// Square 2D gradient — saturation along x, brightness along y,
    /// tinted by the current dialog.h. Click / drag updates dialog.s
    /// and dialog.b.
    @ViewBuilder
    private func renderColorGradient() -> some View {
        let size: CGFloat = 180
        let hue: Double = {
            guard let bind = element["bind"] as? [String: Any],
                  let expr = bind["hue"] as? String else { return 0 }
            if case .number(let n) = evaluate(expr, context: context) { return n }
            return 0
        }()
        let sat: Double = {
            guard let bind = element["bind"] as? [String: Any],
                  let expr = bind["saturation"] as? String else { return 0 }
            if case .number(let n) = evaluate(expr, context: context) { return n }
            return 0
        }()
        let bri: Double = {
            guard let bind = element["bind"] as? [String: Any],
                  let expr = bind["brightness"] as? String else { return 100 }
            if case .number(let n) = evaluate(expr, context: context) { return n }
            return 100
        }()
        let onDialogWriteCb = onDialogWrite
        let writeAt: (CGFloat, CGFloat) -> Void = { x, y in
            let s = max(0, min(100, Double(x) / Double(size) * 100))
            let b = max(0, min(100, (1.0 - Double(y) / Double(size)) * 100))
            onDialogWriteCb?("s", s.rounded())
            onDialogWriteCb?("b", b.rounded())
        }
        let (rH, gH, bH) = hsbToRgb(hue, 100, 100)
        let hueColor = SwiftUI.Color(
            red: Double(rH) / 255.0,
            green: Double(gH) / 255.0,
            blue: Double(bH) / 255.0)
        ZStack {
            // White → hue along x
            LinearGradient(
                gradient: SwiftUI.Gradient(colors: [.white, hueColor]),
                startPoint: .leading, endPoint: .trailing)
            // Transparent → black along y (overlay darkens bottom)
            LinearGradient(
                gradient: SwiftUI.Gradient(colors: [.clear, .black]),
                startPoint: .top, endPoint: .bottom)
            // Cursor circle
            SwiftUI.Circle()
                .strokeBorder(SwiftUI.Color.white, lineWidth: 2)
                .frame(width: 10, height: 10)
                .position(x: CGFloat(sat / 100.0) * size,
                          y: CGFloat((100.0 - bri) / 100.0) * size)
        }
        .frame(width: size, height: size)
        .border(SwiftUI.Color.gray.opacity(0.5))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in writeAt(value.location.x, value.location.y) }
        )
    }

    /// Vertical channel bar; click/drag updates the channel selected
    /// by `dialog.radio_channel`. Default H = rainbow hue; the other
    /// channels (S / B / R / G / B) ramp the chosen channel from 0 to
    /// max while holding the others at their current values.
    private func renderColorHueBar() -> some View {
        let height: CGFloat = 180
        let width: CGFloat = 32
        // Active channel determines bar appearance + value. Defaults
        // to "h" when no radio_channel set.
        let channel: String = {
            if case .string(let s) = evaluate("dialog.radio_channel",
                                              context: context) {
                return s
            }
            return "h"
        }()
        // Read every channel so the inactive ones stay fixed in the
        // ramp.
        func dnum(_ key: String, _ def: Double) -> Double {
            if case .number(let n) = evaluate("dialog.\(key)",
                                              context: context) {
                return n
            }
            return def
        }
        let h = dnum("h", 0)
        let s = dnum("s", 100)
        let b = dnum("b", 100)
        let r = Int(dnum("r", 255))
        let g = Int(dnum("g", 0))
        let bl = Int(dnum("bl", 0))

        func sui(_ rH: Int, _ gH: Int, _ bH: Int) -> SwiftUI.Color {
            SwiftUI.Color(red: Double(rH) / 255.0,
                          green: Double(gH) / 255.0,
                          blue: Double(bH) / 255.0)
        }
        func hsbCss(_ hh: Double, _ ss: Double, _ bb: Double) -> SwiftUI.Color {
            let (rH, gH, bH) = hsbToRgb(hh, ss, bb)
            return sui(Int(rH), Int(gH), Int(bH))
        }

        let stops: [SwiftUI.Color]
        let value: Double
        let maxValue: Double
        switch channel {
        case "s":
            stops = [hsbCss(h, 100, b), hsbCss(h, 0, b)]
            value = s; maxValue = 100
        case "b":
            stops = [hsbCss(h, s, 100), hsbCss(h, s, 0)]
            value = b; maxValue = 100
        case "r":
            stops = [sui(255, g, bl), sui(0, g, bl)]
            value = Double(r); maxValue = 255
        case "g":
            stops = [sui(r, 255, bl), sui(r, 0, bl)]
            value = Double(g); maxValue = 255
        case "bl":
            stops = [sui(r, g, 255), sui(r, g, 0)]
            value = Double(bl); maxValue = 255
        default:  // h: rainbow
            stops = [.red, .yellow, .green, .cyan, .blue, .purple, .red]
            value = h; maxValue = 359
        }

        let onDialogWriteCb = onDialogWrite
        let channelKey = channel
        let max = maxValue
        let writeAt: (CGFloat) -> Void = { y in
            let v = Swift.max(0, Swift.min(max, max - Double(y) / Double(height) * max))
            onDialogWriteCb?(channelKey, v.rounded())
        }
        // Indicator y from current channel value (top = max).
        let indicatorY = (maxValue - value) / maxValue * Double(height)
        return ZStack(alignment: .top) {
            LinearGradient(
                gradient: SwiftUI.Gradient(colors: stops),
                startPoint: .top, endPoint: .bottom)
            Rectangle()
                .fill(SwiftUI.Color.white)
                .frame(width: width + 4, height: 3)
                .border(SwiftUI.Color.black, width: 1)
                .offset(y: CGFloat(indicatorY) - 1)
        }
        .frame(width: width, height: height)
        .border(SwiftUI.Color.gray.opacity(0.5))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in writeAt(value.location.y) }
        )
    }

    // MARK: - Color Swatch

    /// The red-diagonal "no paint" indicator, drawn corner-to-corner across a
    /// swatch. Matches Rust's `NONE_DIAG_SVG` (bottom-left to top-right, red,
    /// 8% of the swatch) and the native ``FillStrokeWidget`` squares.
    /// `visible: false` renders nothing, so callers can overlay
    /// unconditionally.
    @ViewBuilder
    private func noneDiagonal(size: CGFloat, visible: Bool) -> some View {
        if visible {
            swatchNoneDiagonalPath(size: size)
                .stroke(SwiftUI.Color.red,
                        lineWidth: swatchNoneDiagonalLineWidth(size: size))
                .frame(width: size, height: size)
                .allowsHitTesting(false)
        }
    }

    /// The border for a swatch, drawn as an inset stroke so a dashed pattern is
    /// possible (SwiftUI's `.border` cannot dash). Rust's equivalents:
    /// `2px solid #007aff` (accentColor is #007aff on macOS in both
    /// appearances), `1px dashed var(--jas-border,#555)`, and
    /// `1px solid var(--jas-border,#666)`.
    @ViewBuilder
    private func swatchBorderOverlay(_ kind: SwatchBorder) -> some View {
        switch kind {
        case .selected:
            Rectangle().strokeBorder(SwiftUI.Color.accentColor, lineWidth: 2)
        case .placeholder:
            Rectangle().strokeBorder(
                SwiftUI.Color.gray,
                style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        case .solid:
            Rectangle().strokeBorder(SwiftUI.Color.gray, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func renderColorSwatch() -> some View {
        let size = (element["style"] as? [String: Any])?["size"] as? CGFloat ?? 16
        let hollow = element["hollow"] as? Bool ?? false

        // The colour and the "is this an explicit none" answer, decided by
        // ``swatchColorBind`` — a free function so it is testable without a
        // view, and so it can be read side by side with Rust's
        // `swatch_color_bind` (this panel is Path-B-excluded, so no widget_tree
        // golden covers this widget).
        let (color, explicitNone) = swatchColorBind(
            (element["bind"] as? [String: Any])?["color"] as? String,
            context: context)

        let selected = isSelectedInList()
        // Honor click / double_click behavior blocks (Color panel's
        // Black/White/recent swatches use click; Swatches panel's
        // library swatches use both — click selects + sets active
        // color, double_click opens the Swatch Options dialog).
        // Without these gestures the swatch is a static rectangle.
        let behaviors = element["behavior"] as? [[String: Any]] ?? []
        let hasClick = behaviors.contains { ($0["event"] as? String) == "click" }
        let hasDouble = behaviors.contains { ($0["event"] as? String) == "double_click" }
        // A no-paint swatch draws WHITE so the red diagonal reads against a
        // clean background — ``swatchFaceColor``, Rust's `swatch_face_color`.
        // `nil` means paint nothing (an empty slot's transparent face).
        let face = SwiftUI.Color(nsColor: swatchFaceColor(color, explicitNone: explicitNone)
                                    ?? .clear)
        // Three border kinds, decided by ``swatchBorder``. An EXPLICIT none is a
        // real swatch and takes the solid border, not the empty slot's dashed
        // one: Rust keyed that off `color.is_empty()` alone (true for an
        // explicit none too) and so wore the dashed placeholder border where
        // this port wore a solid one. Converged both ways in the COLORTIERS
        // repair — Rust's explicit none went solid, and the dashed PLACEHOLDER,
        // which this port did not draw at all, is drawn here.
        let borderKind = swatchBorder(color, explicitNone: explicitNone, selected: selected)
        let swatch: AnyView = {
            if hollow {
                return AnyView(
                    Rectangle()
                        .stroke(face, lineWidth: 3)
                        .frame(width: size, height: size)
                        .overlay(noneDiagonal(size: size, visible: explicitNone))
                )
            } else {
                return AnyView(
                    Rectangle()
                        .fill(face)
                        .frame(width: size, height: size)
                        .overlay(noneDiagonal(size: size, visible: explicitNone))
                        .overlay(swatchBorderOverlay(borderKind))
                )
            }
        }()
        if hasDouble && hasClick {
            // `exclusively(before:)` works in isolation but breaks down
            // here because `handleWidgetClick` (set_active_color)
            // mutates the doc on selection, which re-renders the
            // panel mid-gesture; the new view tree's tap-counter
            // resets and the second click registers as a fresh
            // single-tap. ClickDisambiguator defers the single-click
            // work via a DispatchWorkItem stored in @State so it
            // survives re-renders, and the count:2 handler cancels
            // the pending item before it fires.
            swatch
                .contentShape(Rectangle())
                .modifier(ClickDisambiguator(
                    onSingle: { handleWidgetClick() },
                    onDouble: { handleBehaviorClick(eventName: "double_click") }
                ))
        } else if hasDouble {
            swatch
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { handleBehaviorClick(eventName: "double_click") }
        } else if hasClick {
            swatch
                .contentShape(Rectangle())
                .onTapGesture { handleWidgetClick() }
        } else {
            swatch
        }
    }

    /// Dispatch behavior entries matching `eventName` — generic
    /// version of handleClickBehavior for non-click events such as
    /// `double_click`. Routes `effects:` through runEffects and
    /// `action:` through dispatchYamlAction.
    private func handleBehaviorClick(eventName: String, pressLocation: CGPoint? = nil) {
        guard let model = model else { return }
        guard let behavior = element["behavior"] as? [[String: Any]] else { return }
        let ws = WorkspaceData.load()
        let actions = ws?.data["actions"] as? [String: Any]
        let dialogs = ws?.data["dialogs"] as? [String: Any]
        let platformEffects = alignPlatformEffects(model: model)
        var ctxWithEvent = context
        ctxWithEvent["event"] = currentEventModifiers()
        if let pid = panelId {
            model.stateStore.setActivePanel(pid)
        }
        // Capture the bridge + pre-effect dialog id so a long-press
        // mouse_down → start_timer → open_dialog (the toolbar's tool-
        // alternates flyout) surfaces in the SwiftUI overlay. The
        // open happens asynchronously inside TimerManager, so we
        // schedule a main-queue bridge after the timer's delay rather
        // than checking synchronously (the store id hasn't changed yet
        // when runEffects returns).
        //
        // The press location (window `.global` coords, captured by the
        // PressDispatchModifier at mouse_down) is the popover anchor —
        // the Swift analogue of Rust threading the mouse event's page
        // coords through start_timer into open_dialog_at. It is forwarded
        // to the bridge so the overlay can place a non-modal flyout at
        // the press instead of centering it.
        let bridge = onStoreDialogOpened
        let anchor = pressLocation
        let beforeDlg = model.stateStore.getDialogId()
        for entry in behavior where behaviorEntryMatches(entry, eventName) {
            let effects = (entry["effects"] as? [Any]) ?? []
            if !effects.isEmpty {
                runEffects(effects, ctx: ctxWithEvent, store: model.stateStore,
                           actions: actions, dialogs: dialogs, platformEffects: platformEffects)
                // Synchronous open (no timer): bridge immediately.
                if let bridge = bridge,
                   model.stateStore.getDialogId() != beforeDlg,
                   model.stateStore.getDialogId() != nil {
                    bridge(anchor)
                }
                // Deferred open via start_timer: schedule a bridge
                // check after the timer fires. Find the longest delay
                // among any start_timer effects in this entry.
                if let bridge = bridge,
                   let delayMs = maxStartTimerDelay(in: effects) {
                    let capturedStore = model.stateStore
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + Double(delayMs) / 1000.0 + 0.03
                    ) {
                        if capturedStore.getDialogId() != beforeDlg,
                           capturedStore.getDialogId() != nil {
                            bridge(anchor)
                        }
                    }
                }
            }
            if let actionName = entry["action"] as? String {
                let rawParams = (entry["params"] as? [String: Any]) ?? [:]
                var resolved: [String: Any] = [:]
                for (k, v) in rawParams {
                    if let exprStr = v as? String {
                        let result = evaluate(exprStr, context: context)
                        if let any = result.toAny() {
                            resolved[k] = any
                        } else {
                            resolved[k] = exprStr
                        }
                    } else {
                        resolved[k] = v
                    }
                }
                dispatchYamlAction(
                    actionName, params: resolved,
                    actions: actions, ctx: context,
                    store: model.stateStore, model: model
                )
            }
        }
    }

    /// Scan an effect list for `start_timer` entries and return the
    /// longest `delay_ms` found (nil if none). Used by
    /// ``handleBehaviorClick`` to schedule the dialog-open bridge after
    /// a long-press timer fires its deferred `open_dialog`.
    private func maxStartTimerDelay(in effects: [Any]) -> Int? {
        var maxDelay: Int? = nil
        for e in effects {
            guard let dict = e as? [String: Any],
                  let st = dict["start_timer"] as? [String: Any] else { continue }
            let delay = (st["delay_ms"] as? NSNumber)?.intValue ?? 250
            maxDelay = max(maxDelay ?? 0, delay)
        }
        return maxDelay
    }

    /// Dispatch a widget's `behavior: [{event: change, action: …, params: …}]`
    /// on commit, injecting the committed numeric value as `event.value` (so
    /// `params: { value: "event.value" }` resolves). Mirrors the Dioxus widget
    /// framework, which already dispatches `change` with the committed value;
    /// the Swift `number_input` otherwise only writes a panel/dialog target, so
    /// a field bound to a non-writable expression (a foreach `p.value`) needs
    /// this path. No-op when the widget has no `change` behavior.
    private func handleChangeBehavior(value: Double) {
        handleChangeBehavior(eventValue: value)
    }

    /// As `handleChangeBehavior(value:)` but for a STRING-valued change.
    ///
    /// `icon_button_group` and `reference_point_widget` dispatch `change` with a
    /// string `event.value` (an orientation, a 3×3 anchor name), which the Double
    /// entry point cannot express. Both funnel into one implementation so the
    /// action / effect / params resolution stays in a single place.
    private func handleChangeBehavior(stringValue: String) {
        handleChangeBehavior(eventValue: stringValue)
    }

    private func handleChangeBehavior(eventValue value: Any) {
        guard let model = model else { return }
        guard let behavior = element["behavior"] as? [[String: Any]] else { return }
        let ws = WorkspaceData.load()
        let actions = ws?.data["actions"] as? [String: Any]
        let platformEffects = alignPlatformEffects(model: model)
        var ctxWithEvent = context
        ctxWithEvent["event"] = ["value": value] as [String: Any]
        if let pid = panelId { model.stateStore.setActivePanel(pid) }
        for entry in behavior where (entry["event"] as? String) == "change" {
            let effects = (entry["effects"] as? [Any]) ?? []
            if !effects.isEmpty {
                runEffects(effects, ctx: ctxWithEvent, store: model.stateStore,
                           actions: actions, platformEffects: platformEffects)
            }
            if let actionName = entry["action"] as? String {
                let rawParams = (entry["params"] as? [String: Any]) ?? [:]
                var resolved: [String: Any] = [:]
                for (k, v) in rawParams {
                    if let exprStr = v as? String {
                        let result = evaluate(exprStr, context: ctxWithEvent)
                        resolved[k] = result.toAny() ?? exprStr
                    } else {
                        resolved[k] = v
                    }
                }
                dispatchYamlAction(
                    actionName, params: resolved,
                    actions: actions, ctx: ctxWithEvent,
                    store: model.stateStore, model: model
                )
            }
        }
    }

    /// Evaluate `bind.selected_in` for this element. Thin wrapper over the
    /// shared free function `widgetSelectedIn`, which both color_swatch and
    /// the brush-tile container use so the accent-outline selection cue is
    /// computed identically. Mirrors the Rust implementation in renderer.rs.
    private func isSelectedInList() -> Bool {
        widgetSelectedIn(element, context: context)
    }

    // MARK: - Gradient primitives

    /// Parse a bind expression that resolves to an object value.
    /// Object values are serialized to JSON strings by the expression
    /// language (see ExprTypes.swift fromJson:object branch).
    private func evaluateBindObject(_ expr: String) -> Any? {
        let result = evaluate(expr, context: context)
        switch result {
        case .string(let s):
            guard let data = s.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        case .list(let arr):
            return arr.map { $0.value }
        default:
            return nil
        }
    }

    /// Parse a hex color like "#ff6600" into a SwiftUI Color.
    private func cssHexColor(_ hex: String, opacity: Double = 1.0) -> SwiftUI.Color {
        let (r, g, b) = parseHex(hex)
        return SwiftUI.Color(
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: opacity
        )
    }

    /// Build the list of (color, location) pairs for a gradient's stops.
    private func extractStops(_ stops: [[String: Any]]) -> [(SwiftUI.Color, Double)] {
        stops.compactMap { s in
            guard let color = s["color"] as? String else { return nil }
            let loc = (s["location"] as? Double) ?? (s["location"] as? NSNumber).map { $0.doubleValue } ?? 0.0
            let opacity = (s["opacity"] as? Double) ?? (s["opacity"] as? NSNumber).map { $0.doubleValue } ?? 100.0
            return (cssHexColor(color, opacity: opacity / 100.0), loc / 100.0)
        }
    }

    /// gradient_tile — click-to-apply gradient preview.
    @ViewBuilder
    private func renderGradientTile() -> some View {
        let sizeKey = element["size"] as? String ?? "large"
        let sz: CGFloat = {
            switch sizeKey {
            case "small": return 16
            case "medium": return 32
            default: return 64
            }
        }()
        let bind = element["bind"] as? [String: Any]
        let gradientExpr = bind?["gradient"] as? String
        let gradientObj = gradientExpr.flatMap { evaluateBindObject($0) } as? [String: Any]
        let gtype = (gradientObj?["type"] as? String) ?? "linear"
        let stopsArr = (gradientObj?["stops"] as? [[String: Any]]) ?? []
        let stops = extractStops(stopsArr)
        let angle = (gradientObj?["angle"] as? Double) ?? 0

        gradientTileBody(
            sz: sz, stops: stops, gtype: gtype, angle: angle
        )
        .onTapGesture {
            if let behaviors = element["behavior"] as? [[String: Any]] {
                for b in behaviors where (b["event"] as? String) == "click" {
                    if let action = b["action"] as? String {
                        let params = (b["params"] as? [String: Any]) ?? [:]
                        onWidgetAction?(action, params)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gradientTileBody(
        sz: CGFloat,
        stops: [(SwiftUI.Color, Double)],
        gtype: String,
        angle: Double
    ) -> some View {
        if stops.count >= 2 {
            if gtype == "radial" {
                Rectangle().fill(
                    RadialGradient(
                        gradient: SwiftUI.Gradient(stops: stops.map {
                            .init(color: $0.0, location: $0.1)
                        }),
                        center: .center,
                        startRadius: 0,
                        endRadius: sz / 2
                    )
                )
                .frame(width: sz, height: sz)
                .border(SwiftUI.Color.gray, width: 1)
            } else {
                // Angle convention: 0° = left-to-right; positive rotates CCW.
                let rad = angle * (Double.pi / 180)
                let start = UnitPoint(x: 0.5 - 0.5 * cos(rad), y: 0.5 + 0.5 * sin(rad))
                let end = UnitPoint(x: 0.5 + 0.5 * cos(rad), y: 0.5 - 0.5 * sin(rad))
                Rectangle().fill(
                    LinearGradient(
                        gradient: SwiftUI.Gradient(stops: stops.map {
                            .init(color: $0.0, location: $0.1)
                        }),
                        startPoint: start,
                        endPoint: end
                    )
                )
                .frame(width: sz, height: sz)
                .border(SwiftUI.Color.gray, width: 1)
            }
        } else {
            Rectangle().fill(SwiftUI.Color.gray)
                .frame(width: sz, height: sz)
                .border(SwiftUI.Color.gray, width: 1)
        }
    }

    /// gradient_slider — 1-D stops editor.
    ///
    /// Phase 0 scope: visual tree + tap-to-select gestures on stop and
    /// midpoint markers. Full drag state (drag, drag-off-bar delete) and
    /// keyboard handling are deferred to Phase 5.
    @ViewBuilder
    private func renderGradientSlider() -> some View {
        let bind = element["bind"] as? [String: Any]
        let stopsExpr = bind?["stops"] as? String
        let selStopExpr = bind?["selected_stop_index"] as? String
        let selMidExpr = bind?["selected_midpoint_index"] as? String

        let stopsRaw: [[String: Any]] = (stopsExpr.flatMap { evaluateBindObject($0) } as? [[String: Any]]) ?? []

        // saturatingInt mirrors Rust's `n as i64` (risk R9).
        let selStop: Int = selStopExpr.map {
            if case .number(let n) = evaluate($0, context: context) { return saturatingInt(n) }
            else { return -1 }
        } ?? -1
        let selMid: Int = selMidExpr.map {
            if case .number(let n) = evaluate($0, context: context) { return saturatingInt(n) }
            else { return -1 }
        } ?? -1

        let stops = extractStops(stopsRaw)

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Bar
                if stops.count >= 2 {
                    Rectangle().fill(
                        LinearGradient(
                            gradient: SwiftUI.Gradient(stops: stops.map {
                                .init(color: $0.0, location: $0.1)
                            }),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width, height: 16)
                    .border(SwiftUI.Color.gray, width: 1)
                    .offset(x: 0, y: 14)
                } else {
                    Rectangle().fill(SwiftUI.Color.gray)
                        .frame(width: geo.size.width, height: 16)
                        .offset(x: 0, y: 14)
                }

                // Midpoint markers (diamonds, above bar)
                ForEach(0..<max(stopsRaw.count - 1, 0), id: \.self) { i in
                    let left = (stopsRaw[i]["location"] as? Double) ?? 0.0
                    let right = (stopsRaw[i + 1]["location"] as? Double) ?? 100.0
                    let pct = (stopsRaw[i]["midpoint_to_next"] as? Double) ?? 50.0
                    let midLoc = left + (right - left) * (pct / 100.0)
                    let x = CGFloat(midLoc / 100.0) * geo.size.width - 5
                    Rectangle()
                        .fill(SwiftUI.Color(white: 0.55))
                        .border(SwiftUI.Color.black, width: 1)
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(45))
                        .offset(x: x, y: 2)
                        .overlay(
                            Rectangle()
                                .stroke(selMid == i ? SwiftUI.Color.accentColor : SwiftUI.Color.clear, lineWidth: 2)
                                .frame(width: 10, height: 10)
                                .rotationEffect(.degrees(45))
                                .offset(x: x, y: 2)
                        )
                        .onTapGesture {
                            onWidgetAction?("gradient_slider_midpoint_click", ["midpoint_index": i])
                        }
                }

                // Stop markers (circles, below bar)
                ForEach(0..<stopsRaw.count, id: \.self) { i in
                    stopMarker(
                        index: i,
                        stop: stopsRaw[i],
                        width: geo.size.width,
                        selected: selStop == i
                    )
                }
            }
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private func stopMarker(
        index: Int,
        stop: [String: Any],
        width: CGFloat,
        selected: Bool
    ) -> some View {
        let loc = (stop["location"] as? Double) ?? 0.0
        let colorHex = (stop["color"] as? String) ?? "#000000"
        let opacity = (stop["opacity"] as? Double) ?? 100.0
        let x = CGFloat(loc / 100.0) * width - 7
        SwiftUI.Circle()
            .fill(cssHexColor(colorHex, opacity: opacity / 100.0))
            .frame(width: 14, height: 14)
            .overlay(
                SwiftUI.Circle().stroke(
                    selected ? SwiftUI.Color.accentColor : SwiftUI.Color.black,
                    lineWidth: selected ? 2 : 1
                )
            )
            .offset(x: x, y: 30)
            .onTapGesture(count: 2) {
                onWidgetAction?("gradient_slider_stop_dblclick", ["stop_index": index])
            }
            .onTapGesture(count: 1) {
                onWidgetAction?("gradient_slider_stop_click", ["stop_index": index])
            }
    }

    // MARK: - Separator

    @ViewBuilder
    private func renderSeparator() -> some View {
        let orientation = element["orientation"] as? String ?? "horizontal"
        let style = element["style"] as? [String: Any]
        // Honor explicit height/width — without this a vertical
        // separator grows to fill the parent height (the Color
        // panel's swatch divider was blowing the row up to the
        // full panel height), and a horizontal one stretches across
        // its parent, which is fine but worth being explicit.
        let explicitHeight = (style?["height"] as? CGFloat)
            ?? (style?["height"] as? Double).map { CGFloat($0) }
            ?? (style?["height"] as? Int).map { CGFloat($0) }
        let explicitWidth = (style?["width"] as? CGFloat)
            ?? (style?["width"] as? Double).map { CGFloat($0) }
            ?? (style?["width"] as? Int).map { CGFloat($0) }
        if orientation == "vertical" {
            Rectangle()
                .fill(SwiftUI.Color.gray.opacity(0.5))
                .frame(width: 1, height: explicitHeight)
        } else {
            Rectangle()
                .fill(SwiftUI.Color.gray.opacity(0.5))
                .frame(width: explicitWidth, height: 1)
        }
    }

    // MARK: - Disclosure

    @ViewBuilder
    private func renderDisclosure() -> some View {
        let label = element["label"] as? String ?? ""
        let labelText = label.contains("{{")
            ? evaluateText(label, context: context)
            : label
        let labelColor: SwiftUI.Color = theme.map {
            SwiftUI.Color(nsColor: $0.text)
        } ?? .primary

        // Custom disclosure: SwiftUI's DisclosureGroup ignores tint
        // for the chevron on macOS, leaving it dark on dark themes.
        // Roll our own header so the chevron picks up theme.text.
        // Collapsed state lives in `bind.collapsed` (panel state);
        // we read it on render and toggle it on tap, falling back to
        // a local @State for unbound disclosures.
        DisclosureSection(
            label: labelText,
            labelColor: labelColor,
            initialCollapsed: evalDisclosureCollapsed(),
            onToggle: { newCollapsed in
                writeDisclosureCollapsed(newCollapsed)
            }
        ) {
            renderChildElements()
        }
    }

    /// Read the disclosure's `bind.collapsed` expression (if any)
    /// so the initial state matches whatever's in panel state.
    private func evalDisclosureCollapsed() -> Bool {
        guard let bind = element["bind"] as? [String: Any],
              let expr = bind["collapsed"] as? String
        else { return false }
        return evaluate(expr, context: context).toBool()
    }

    /// Write the disclosure's collapsed state back through the bind
    /// target so it persists in panel state. No-op when there's no
    /// bind expression (uncontrolled disclosure).
    private func writeDisclosureCollapsed(_ collapsed: Bool) {
        guard let bind = element["bind"] as? [String: Any],
              let expr = bind["collapsed"] as? String
        else { return }
        let target = writeBackTarget(expr)
        guard let t = target else { return }
        commitWidgetWrite(target: t, value: collapsed)
    }

    // MARK: - Panel

    @ViewBuilder
    private func renderPanel() -> some View {
        if let content = element["content"] as? [String: Any] {
            YamlElementView(element: content, context: context, model: model, panelId: panelId, onWidgetAction: onWidgetAction, theme: theme, flyoutIconDefault: flyoutIconDefault, onDialogWrite: onDialogWrite, onStoreDialogOpened: onStoreDialogOpened, onStoreDialogClosed: onStoreDialogClosed)
        } else {
            renderPlaceholder()
        }
    }

    // MARK: - Tree View

    @ViewBuilder
    private func renderTreeView() -> some View {
        if let model = model {
            TreeViewContent(model: model)
        } else {
            SwiftUI.Text("[Element hierarchy]")
                .foregroundColor(.gray)
                .frame(minHeight: 30)
        }
    }

    // MARK: - Element Preview

    @ViewBuilder
    private func renderElementPreview() -> some View {
        let sz = (element["style"] as? [String: Any])?["size"] as? Int ?? 32
        Rectangle()
            .fill(SwiftUI.Color.white)
            .overlay(Rectangle().stroke(SwiftUI.Color.gray, lineWidth: 1))
            .frame(width: CGFloat(sz), height: CGFloat(sz))
    }

    /// A brush tip / stroke preview drawn from the enclosing tile's `brush`
    /// loop variable. Calligraphic draws a nib ellipse — `size` scales the
    /// display diameter, `roundness` flattens the minor axis, `angle` rotates
    /// it; other types fall back to an empty box until their preview lands.
    /// Manual-floor GUI (widget_tree pins only the `brush_preview` kind).
    @ViewBuilder
    private func renderBrushPreview() -> some View {
        let brush = context["brush"] as? [String: Any] ?? [:]
        if (brush["type"] as? String) == "calligraphic" {
            let size = Double(containerNumericDim(brush["size"]) ?? 5)
            let roundness = Double(containerNumericDim(brush["roundness"]) ?? 100)
            let angle = Double(containerNumericDim(brush["angle"]) ?? 0)
            let major = min(max(size * 2.8, 4.0), 30.0)
            let minor = min(max(major * (roundness / 100.0), 1.5), major)
            let color: SwiftUI.Color = theme.map { SwiftUI.Color(nsColor: $0.text) } ?? .primary
            SwiftUI.Ellipse()
                .fill(color)
                .frame(width: CGFloat(major), height: CGFloat(minor))
                .rotationEffect(.degrees(angle))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if (brush["type"] as? String) == "art", let art = artBrushForPreview(brush) {
            // Art: warp the artwork along a short horizontal path across the
            // tile — a stroke sample (reuses artAlongPath, so the thumbnail
            // exercises the canvas algorithm).
            let color: SwiftUI.Color = theme.map { SwiftUI.Color(nsColor: $0.text) } ?? .primary
            let polys = artAlongPath([.moveTo(5, 20), .lineTo(35, 20)], art)
            SwiftUI.Path { p in
                for poly in polys where poly.count >= 3 {
                    p.move(to: CGPoint(x: poly[0][0], y: poly[0][1]))
                    for pt in poly.dropFirst() { p.addLine(to: CGPoint(x: pt[0], y: pt[1])) }
                    p.closeSubpath()
                }
            }
            .fill(color)
            .frame(width: 40, height: 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if (brush["type"] as? String) == "pattern", let pat = patternBrushForPreview(brush) {
            // Pattern: tile the side artwork along a short horizontal path.
            let color: SwiftUI.Color = theme.map { SwiftUI.Color(nsColor: $0.text) } ?? .primary
            let polys = patternAlongPath([.moveTo(4, 20), .lineTo(36, 20)], pat)
            SwiftUI.Path { p in
                for poly in polys where poly.count >= 3 {
                    p.move(to: CGPoint(x: poly[0][0], y: poly[0][1]))
                    for pt in poly.dropFirst() { p.addLine(to: CGPoint(x: pt[0], y: pt[1])) }
                    p.closeSubpath()
                }
            }
            .fill(color)
            .frame(width: 40, height: 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if (brush["type"] as? String) == "bristle" {
            // Bristle: stroke the offset bristle lines with per-bristle opacity.
            let color: SwiftUI.Color = theme.map { SwiftUI.Color(nsColor: $0.text) } ?? .primary
            let br = BristleBrush(size: containerNumericDim(brush["size"]).map(Double.init) ?? 3.0,
                                  density: containerNumericDim(brush["density"]).map(Double.init) ?? 50.0,
                                  thickness: containerNumericDim(brush["thickness"]).map(Double.init) ?? 30.0,
                                  opacity: containerNumericDim(brush["opacity"]).map(Double.init) ?? 30.0,
                                  strokeWeight: 6.0)
            let lines = bristleStroke([.moveTo(4, 20), .lineTo(36, 20)], br)
            SwiftUI.Path { p in
                for line in lines where line.count >= 2 {
                    p.move(to: CGPoint(x: line[0][0], y: line[0][1]))
                    for pt in line.dropFirst() { p.addLine(to: CGPoint(x: pt[0], y: pt[1])) }
                }
            }
            .stroke(color.opacity(br.alpha()),
                    style: StrokeStyle(lineWidth: br.lineWidth(), lineCap: .round))
            .frame(width: 40, height: 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SwiftUI.Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Build a PatternBrush for the tile preview (fixed ribbon height).
    private func patternBrushForPreview(_ brush: [String: Any]) -> PatternBrush? {
        guard let tiles = brush["tiles"] as? [String: Any],
              let side = tiles["side"] as? [String: Any],
              let width = containerNumericDim(side["width"]).map(Double.init),
              let height = containerNumericDim(side["height"]).map(Double.init),
              let polysAny = side["polygons"] as? [Any] else { return nil }
        let polys: [[[Double]]] = polysAny.compactMap { polyAny in
            guard let poly = polyAny as? [Any] else { return nil }
            return poly.compactMap { ptAny -> [Double]? in
                guard let pt = ptAny as? [Any], pt.count >= 2,
                      let x = containerNumericDim(pt[0]).map(Double.init),
                      let y = containerNumericDim(pt[1]).map(Double.init) else { return nil }
                return [x, y]
            }
        }
        return PatternBrush(tileWidth: width, tileHeight: height, side: polys,
                            scale: 100.0,
                            spacing: containerNumericDim(brush["spacing"]).map(Double.init) ?? 0.0,
                            flipAcross: (brush["flip_across"] as? Bool) ?? false,
                            flipAlong: (brush["flip_along"] as? Bool) ?? false,
                            strokeWeight: 10.0)
    }

    /// Build an ArtBrush for the tile preview (fixed ribbon height, the
    /// brush's own artwork + flips). Mirrors the canvas artFromJson parse.
    private func artBrushForPreview(_ brush: [String: Any]) -> ArtBrush? {
        guard let aw = brush["artwork"] as? [String: Any],
              let width = containerNumericDim(aw["width"]).map(Double.init),
              let height = containerNumericDim(aw["height"]).map(Double.init),
              let polysAny = aw["polygons"] as? [Any] else { return nil }
        let artwork: [[[Double]]] = polysAny.compactMap { polyAny in
            guard let poly = polyAny as? [Any] else { return nil }
            return poly.compactMap { ptAny -> [Double]? in
                guard let pt = ptAny as? [Any], pt.count >= 2,
                      let x = containerNumericDim(pt[0]).map(Double.init),
                      let y = containerNumericDim(pt[1]).map(Double.init) else { return nil }
                return [x, y]
            }
        }
        return ArtBrush(artworkWidth: width, artworkHeight: height, artwork: artwork,
                        scale: 100.0,
                        flipAcross: (brush["flip_across"] as? Bool) ?? false,
                        flipAlong: (brush["flip_along"] as? Bool) ?? false,
                        strokeWeight: 14.0)
    }

    // MARK: - icon_button_group / reference_point_widget (added 2026-07-29)
    //
    // Both kinds were UNDISPATCHED and fell through to `renderPlaceholder()`,
    // which renders the widget's `summary` text. Found by the jas/windows seat
    // counting dispatch arms against the 38 canonical kinds in
    // `workspace_interpreter/widget_tree.py`.
    //
    // BOTH ARE WIDGET-ONLY GAPS, which took tracing to establish and contradicted
    // this seat's first reading:
    //   * `set_artboard_reference_point` is PURE YAML — a generic
    //     `set_panel_state` effect, already handled here. Nothing native was ever
    //     missing; the claim that it was "absent from Swift" came from grepping a
    //     name that is not supposed to appear in either port's source.
    //   * `toggle_artboard_orientation` is unimplemented in BOTH ports — its YAML
    //     effect is a bare `log` marked "(native)" for work never done. Rendering
    //     the control therefore MATCHES jas_dioxus exactly: both show the buttons,
    //     neither swaps the dimensions. That is a shared gap, not a Swift defect.
    //
    // Written using only constructs this file already demonstrates. `Group` is
    // NOT among them: bare `Group` here resolves to jas's DOCUMENT Group
    // (`Element.group(Group(children:))`), so `Group { }` calls the model's
    // initialiser, the enclosing label fails to typecheck, and `ForEach` reports
    // a bogus `Binding` overload a dozen lines from the cause. `if`/`else` in a
    // ViewBuilder needs no wrapper.

    /// `icon_button_group` — a segmented row of icon buttons, exactly one active,
    /// dispatching `change` with the chosen option's `value`.
    ///
    /// Declared at `workspace/dialogs/artboard_options.yaml` (portrait /
    /// landscape). Twin: Rust `render_icon_button_group`.
    @ViewBuilder
    private func renderIconButtonGroup() -> some View {
        let options = (element["options"] as? [[String: Any]]) ?? []
        let bindMap = element["bind"] as? [String: Any]
        let valueExpr = bindMap?["value"] as? String
        let current = iconGroupCurrentValue(valueExpr)
        let isDisabled = evalBindDisabled()
        let writeTarget = valueExpr.flatMap { writeBackTarget($0) }

        HStack(spacing: 1) {
            ForEach(0..<options.count, id: \.self) { i in
                let opt = options[i]
                let value = (opt["value"] as? String) ?? ""
                let iconName = (opt["icon"] as? String) ?? ""
                let active = value == current
                Button(action: {
                    // Write the bound target when it is writable (the radio-row
                    // pattern above), THEN fire `change` — the YAML action is what
                    // applies, and for orientation that action is the shared stub.
                    if let t = writeTarget {
                        commitWidgetWrite(target: t, value: value)
                    }
                    handleChangeBehavior(stringValue: value)
                }) {
                    HStack(spacing: 0) {
                        if let theme = theme, !iconName.isEmpty,
                           WorkspaceIconCache.shared.lookup(iconName) != nil {
                            WorkspaceIcon(name: iconName, size: 14, tint: theme.text)
                        } else {
                            SwiftUI.Color.clear.frame(width: 14, height: 14)
                        }
                    }
                    .frame(width: 26, height: 22)
                    .background(active ? SwiftUI.Color(white: 0.31) : SwiftUI.Color.clear)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            }
        }
        .opacity(isDisabled ? 0.4 : 1.0)
    }

    /// The `icon_button_group`'s currently-active option value. Split out so the
    /// view body stays a chain of plain `let`s, which is what this file's other
    /// option-list widgets do.
    /// A `dropdown` widget: a menu of toggle items over one panel-state list,
    /// rendered from the YAML's own `items` (council Q3.2, 2026-07-30).
    ///
    /// GENERIC, and that is the point. This port drew the Layers type filter as
    /// a hardcoded eleven-pair SwiftUI `Menu` inside `renderTreeView`, while
    /// `layers.yaml` declared the same eleven as `lp_filter_button.items` and
    /// this dispatch fell through to a grey `[Filter by element type]`
    /// placeholder beside it. Adding a type to the YAML would have appeared in
    /// jas_dioxus and silently not here.
    ///
    /// CHECKED SEMANTICS: a ticked item means "list this type". Nothing ticked
    /// is the default and means everything, so the "All" row carries the tick
    /// instead of eleven meaningless ones. ALT-CLICK SOLOS, mirroring the
    /// Option-click solo on the eye button in this same panel.
    private func renderDropdown() -> AnyView {
        let items = (element["items"] as? [[String: Any]]) ?? []
        let bindKey = "type_filter"
        let panelId = "layers_panel_content"
        guard let model = model else { return AnyView(EmptyView()) }
        let store = model.stateStore
        let checked = Set((store.getPanel(panelId, bindKey) as? [String]) ?? [])
        // ONE LOOP, IN DECLARATION ORDER, each row rendered as the KIND its
        // `type` declares. The "All" row is the menu's own first item rather
        // than a hand-written twin of it, so its behaviour is the one
        // `layers.yaml` declares (`action: clear_layers_type_filter`) instead of
        // a literal that happens to agree.
        let rows = layersFilterMenuRows(items)

        return AnyView(Menu {
            ForEach(rows.indices, id: \.self) { i in
                let row = rows[i]
                switch row.kind {
                // AN ACTION IS NOT A TYPE. Its tick means "already in force",
                // not "checked": with an empty filter All is ticked, which is
                // what stops CHECKED semantics reading as twelve switched-off
                // boxes over a full tree.
                case .action(let action):
                    Button(action: {
                        // An action this port does not know leaves the state
                        // alone. Nothing is guessed here.
                        if let next = layersCheckedAfterAction(action, checked) {
                            store.setPanel(panelId, bindKey, Array(next).sorted())
                            model.panelStateVersion += 1
                        }
                    }) {
                        SwiftUI.Text(layersActionIsInForce(action, checked)
                                     ? "✓ \(row.label)" : row.label)
                    }
                    SwiftUI.Divider()
                case .toggle:
                    Button(action: {
                        var next = checked
                        // Option held: SOLO. A second Alt-click on an
                        // already-soloed type restores the full tree, exactly
                        // as a second Option-click un-solos the eye.
                        if NSEvent.modifierFlags.contains(.option) {
                            next = (next.count == 1 && next.contains(row.value)) ? [] : [row.value]
                        } else if next.contains(row.value) {
                            next.remove(row.value)
                        } else {
                            next.insert(row.value)
                        }
                        store.setPanel(panelId, bindKey, Array(next).sorted())
                        model.panelStateVersion += 1
                    }) {
                        SwiftUI.Text(checked.contains(row.value) ? "✓ \(row.label)" : row.label)
                    }
                }
            }
        } label: {
            SwiftUI.Text("▾").font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 20))
    }

    private func iconGroupCurrentValue(_ expr: String?) -> String {
        guard let e = expr else { return "" }
        if case .string(let v) = evaluate(e, context: context) { return v }
        return ""
    }

    /// `reference_point_widget` — a 3×3 anchor grid, exactly one cell active,
    /// dispatching `change` with the anchor name.
    ///
    /// Its own YAML description states the contract: "3×3 grid; exactly one
    /// anchor active. Changes X / Y display, not storage." Twin: Rust
    /// `render_reference_point_widget`.
    @ViewBuilder
    private func renderReferencePointWidget() -> some View {
        let bindMap = element["bind"] as? [String: Any]
        let valueExpr = bindMap?["value"] as? String
        // "center" is the widget's declared default anchor, matching Rust.
        let current = valueExpr == nil ? "center" : {
            let v = iconGroupCurrentValue(valueExpr)
            return v.isEmpty ? "center" : v
        }()
        let writeTarget = valueExpr.flatMap { writeBackTarget($0) }
        // Row-major, matching Rust's ordering so the ports agree on which cell
        // is which.
        let rows = referencePointAnchorRows

        VStack(spacing: 2) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 2) {
                    ForEach(rows[r], id: \.self) { anchor in
                        Button(action: {
                            if let t = writeTarget {
                                commitWidgetWrite(target: t, value: anchor)
                            }
                            handleChangeBehavior(stringValue: anchor)
                        }) {
                            SwiftUI.Rectangle()
                                .fill(anchor == current
                                      ? SwiftUI.Color.accentColor
                                      : SwiftUI.Color(white: 0.35))
                                .frame(width: 10, height: 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// The 3×3 reference-point anchors, ROW-MAJOR, matching Rust's ordering so
    /// the two ports agree on which cell is which.
    private var referencePointAnchorRows: [[String]] { referencePointAnchorRowsForTest }

    // MARK: - Placeholder

    @ViewBuilder
    private func renderPlaceholder() -> some View {
        let summary = element["summary"] as? String
            ?? element["type"] as? String
            ?? "?"
        // Opacity panel previews (OPACITY.md §Preview interactions):
        // op_preview / op_mask_preview handle click to switch the
        // editing target and render a persistent highlight on the
        // active target. Mirrors the Rust special-case in
        // ``render_placeholder``.
        let id = element["id"] as? String
        if panelId == "opacity_panel_content",
           let id, id == "op_preview" || id == "op_mask_preview" {
            let editingMask = evaluate("editing_target_is_mask", context: context).toBool()
            let hasMask = evaluate("selection_has_mask", context: context).toBool()
            let isMaskPreview = id == "op_mask_preview"
            // Highlight the preview that matches the current editing
            // target: op_preview when content-mode, op_mask_preview
            // when mask-mode.
            let highlight = editingMask == isMaskPreview
            // MASK_PREVIEW click requires the selection to have a
            // mask; otherwise the click is a no-op.
            let clickEnabled = !isMaskPreview || hasMask
            SwiftUI.Text("[\(summary)]")
                .foregroundColor(.gray)
                .frame(minHeight: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(highlight
                                ? SwiftUI.Color(red: 74 / 255, green: 144 / 255, blue: 217 / 255)
                                : SwiftUI.Color.clear,
                                lineWidth: 2)
                )
                .contentShape(SwiftUI.Rectangle())
                .onTapGesture {
                    guard clickEnabled, let m = model else { return }
                    // MASK_PREVIEW supports modifier-clicks per
                    // OPACITY.md §Preview interactions. Query the
                    // current NSEvent modifier flags at tap time.
                    let flags = NSEvent.modifierFlags
                    let shift = flags.contains(.shift)
                    let alt = flags.contains(.option)
                    if isMaskPreview && shift {
                        // Shift-click: toggle mask.disabled on every
                        // selected mask via Controller.
                        Controller(model: m).toggleMaskDisabledOnSelection()
                    } else if isMaskPreview && alt {
                        // Alt-click: toggle mask isolation on the
                        // first selected element's mask.
                        if m.maskIsolationPath != nil {
                            m.maskIsolationPath = nil
                        } else {
                            m.maskIsolationPath = m.document.selection.first?.path
                        }
                    } else {
                        // Plain click: flip editing target.
                        m.editingTarget = isMaskPreview
                            ? .mask(m.document.selection.first?.path ?? [])
                            : .content
                    }
                }
        } else {
            SwiftUI.Text("[\(summary)]")
                .foregroundColor(.gray)
                .frame(minHeight: 30)
        }
    }

    // MARK: - Select

    @ViewBuilder
    private func renderSelect() -> some View {
        let options = element["options"] as? [[String: Any]] ?? []
        let bind = element["bind"] as? [String: Any]
        let valueExpr = bind?["value"] as? String
        let currentValue: String = {
            if let e = valueExpr {
                let result = evaluate(e, context: context)
                if case .string(let s) = result { return s }
            }
            return ""
        }()
        let writeTarget = writeBackTarget(valueExpr)

        let entries = options.enumerated().map { i, opt -> PickerEntry in
            let v = opt["value"].map { "\($0)" } ?? ""
            let l = opt["label"] as? String ?? ""
            return PickerEntry(id: i, val: v, displayLabel: l.isEmpty ? v : l)
        }
        // When YAML declares ``style.width: "100%"`` (the convention for
        // panel rows where the select shares a col cell with sibling
        // inputs — Character panel font / language / anti-aliasing), fill
        // the parent column so widths line up. Otherwise take intrinsic
        // width so the picker doesn't balloon into empty space (Print
        // dialog's enum dropdowns rely on this).
        let fillsParent = (element["style"] as? [String: Any])?["width"] as? String == "100%"
        let picker = Picker("", selection: Binding<String>(
            get: { currentValue },
            set: { newVal in
                if let t = writeTarget { commitWidgetWrite(target: t, value: newVal) }
            }
        )) {
            ForEach(entries) { e in
                SwiftUI.Text(e.displayLabel).tag(e.val)
            }
        }
        .labelsHidden()
        if fillsParent {
            picker.frame(maxWidth: .infinity).padding(.trailing, 24)
        } else {
            picker.fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: - Icon Select

    /// `icon_select`: an icon-button-sized dropdown that shows either
    /// the per-option `glyph` (Unicode marker) of the selected option
    /// or, when the YAML supplies a workspace `icon:`, that SVG glyph
    /// as the button face. The native Menu surface handles popup
    /// rendering and keyboard nav. Used by Paragraph panel's Bullets
    /// and Numbered List rows. Mirrors `render_icon_select` in
    /// `jas_dioxus/src/interpreter/renderer.rs`.
    @ViewBuilder
    private func renderIconSelect() -> some View {
        let options = element["options"] as? [[String: Any]] ?? []
        let bind = element["bind"] as? [String: Any]
        let valueExpr = bind?["value"] as? String
        let currentValue: String = {
            if let e = valueExpr {
                if case .string(let s) = evaluate(e, context: context) { return s }
            }
            return ""
        }()
        let writeTarget = writeBackTarget(valueExpr)
        let isDisabled: Bool = {
            if let disExpr = bind?["disabled"] as? String {
                return evaluate(disExpr, context: context).toBool()
            }
            return false
        }()
        let summary = element["summary"] as? String ?? ""
        let iconName = element["icon"] as? String ?? ""
        let style = element["style"] as? [String: Any] ?? [:]
        let w: CGFloat = {
            if let n = style["width"] as? CGFloat { return n }
            if let n = style["width"] as? Double { return CGFloat(n) }
            if let n = style["width"] as? Int { return CGFloat(n) }
            return 48
        }()
        let h: CGFloat = {
            if let n = style["height"] as? CGFloat { return n }
            if let n = style["height"] as? Double { return CGFloat(n) }
            if let n = style["height"] as? Int { return CGFloat(n) }
            return 26
        }()

        // Resolve the visible glyph (when no SVG icon is supplied).
        let visibleGlyph: String = {
            for opt in options {
                let v = opt["value"].map { "\($0)" } ?? ""
                if v == currentValue {
                    if let g = opt["glyph"] as? String, !g.isEmpty { return g }
                    if let l = opt["label"] as? String,
                       let first = l.split(separator: " ").first { return String(first) }
                }
            }
            return "—"
        }()

        // SwiftUI's `Menu { } label: { … }` on macOS wraps the label
        // in a Picker-style chrome that strips custom views like
        // SwiftUI Canvas (used by WorkspaceIcon) — the visible icon
        // collapses to a tiny indicator. Use a stateful inner View
        // that owns a `@State` popover-open binding and renders the
        // icon explicitly inside a `Button`.
        IconSelectButton(
            iconName: iconName,
            visibleGlyph: visibleGlyph,
            options: options.map { opt in
                IconSelectOption(
                    value: opt["value"].map { "\($0)" } ?? "",
                    glyph: opt["glyph"] as? String ?? "",
                    label: opt["label"] as? String
                        ?? (opt["value"].map { "\($0)" } ?? "")
                )
            },
            width: w,
            height: h,
            theme: theme,
            summary: summary,
            isDisabled: isDisabled,
            onPick: { v in
                if let t = writeTarget { commitWidgetWrite(target: t, value: v) }
            }
        )
    }

    // MARK: - Toggle / Checkbox

    @ViewBuilder
    private func renderToggle() -> some View {
        let label = element["label"] as? String ?? ""
        let iconName = element["icon"] as? String ?? ""
        let bind = element["bind"] as? [String: Any]
        // Accept bind.value, bind.checked, or a bare-string bind:
        // panels prefer ``value``, dialogs / align / stroke radios use
        // ``checked``, color picker uses bare-string ("dialog.web_only").
        // Without the bare-string fallback the toggle stays inert
        // — clicks fire writeTarget=nil and the visual state never
        // flips.
        let stateExpr = (bind?["value"] as? String)
            ?? (bind?["checked"] as? String)
            ?? (element["bind"] as? String)
        let isChecked: Bool = {
            if let e = stateExpr {
                return evaluate(e, context: context).toBool()
            }
            return false
        }()
        let writeTarget = writeBackTarget(stateExpr)
        let isDisabled: Bool = {
            if let disExpr = bind?["disabled"] as? String {
                return evaluate(disExpr, context: context).toBool()
            }
            return false
        }()
        // Opacity panel selection-mask bindings route write-backs to
        // the document controller (the flag lives on the selected
        // element's mask, not on a panel-state key). See OPACITY.md §
        // States. Mirrors the Rust ``render_toggle`` special-case.
        let maskRoute: String? = {
            guard panelId == "opacity_panel_content" else { return nil }
            switch stateExpr?.trimmingCharacters(in: .whitespaces) {
            case "selection_mask_clip": return "clip"
            case "selection_mask_invert": return "invert"
            default: return nil
            }
        }()
        let capturedModel = model

        let onToggle: (Bool) -> Void = { newVal in
            if let route = maskRoute, let m = capturedModel {
                let ctrl = Controller(model: m)
                if route == "clip" {
                    ctrl.setMaskClipOnSelection(newVal)
                } else {
                    ctrl.setMaskInvertOnSelection(newVal)
                }
                return
            }
            if let t = writeTarget { commitWidgetWrite(target: t, value: newVal) }
        }

        if !iconName.isEmpty {
            // Icon-toggle: square button with the workspace icon glyph
            // and a highlighted background when checked. Matches the
            // Rust render_toggle icon-mode and CHARACTER.md "icon_toggle"
            // spec used by the 6 character-formatting toggles.
            let summary = element["summary"] as? String ?? ""
            let style = element["style"] as? [String: Any] ?? [:]
            let w: CGFloat = {
                if let n = style["width"] as? CGFloat { return n }
                if let n = style["width"] as? Double { return CGFloat(n) }
                if let n = style["width"] as? Int { return CGFloat(n) }
                return 28
            }()
            let checkedBg: SwiftUI.Color = theme.map {
                SwiftUI.Color(nsColor: $0.buttonChecked)
            } ?? SwiftUI.Color.gray.opacity(0.3)
            if let theme = theme,
               WorkspaceIconCache.shared.lookup(iconName) != nil {
                Button(action: { onToggle(!isChecked) }) {
                    WorkspaceIcon(name: iconName, size: w - 4, tint: theme.text)
                        .padding(2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isChecked ? checkedBg : .clear)
                        )
                }
                .buttonStyle(.plain)
                .help(summary)
                .disabled(isDisabled)
            } else {
                Button(summary.isEmpty ? label : summary) { onToggle(!isChecked) }
                    .buttonStyle(.plain)
                    .padding(2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isChecked ? checkedBg : .clear)
                    )
                    .disabled(isDisabled)
            }
        } else {
            // Custom checkbox + text label. SwiftUI's stock
            // Toggle(label,…).toggleStyle(.checkbox) renders the label
            // with the system's default color (dark on dark themes),
            // and `Toggle(label:)` lets the label wrap when the
            // container is narrow — both wrong for the dock-panel
            // theme. Build it explicitly so the label uses theme.text
            // and stays on a single line.
            let labelColor: SwiftUI.Color = theme.map {
                SwiftUI.Color(nsColor: $0.text)
            } ?? .primary
            Toggle(isOn: Binding<Bool>(
                get: { isChecked },
                set: onToggle
            )) {
                SwiftUI.Text(label)
                    .foregroundColor(labelColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
                .toggleStyle(.checkbox)
                .disabled(isDisabled)
        }
    }

    // MARK: - Combo Box

    @ViewBuilder
    private func renderComboBox() -> some View {
        let options = element["options"] as? [[String: Any]] ?? []
        let bind = element["bind"] as? [String: Any]
        let valueExpr = bind?["value"] as? String
        let currentValue: String = {
            if let e = valueExpr {
                let result = evaluate(e, context: context)
                switch result {
                case .string(let s): return s
                // saturatingInt mirrors Rust's `as i64` (risk R9). Rust renders
                // this value with `n.to_string()`, so a FRACTIONAL bound value
                // reads differently here — banked in §7.1.
                case .number(let n): return String(saturatingInt(n))
                default: return ""
                }
            }
            return ""
        }()
        let writeTarget = writeBackTarget(valueExpr)

        // SwiftUI doesn't have a native combo box with free entry;
        // use Picker as a dropdown with the current value displayed.
        let entries = options.enumerated().map { i, opt -> PickerEntry in
            let v = opt["value"].map { "\($0)" } ?? ""
            let l = opt["label"] as? String ?? ""
            return PickerEntry(id: i, val: v, displayLabel: l.isEmpty ? v : l)
        }
        // When the YAML declares style.width: "100%" (the convention for
        // panel rows where the dropdown shares a col cell with sibling
        // inputs), fill the parent column so widths line up. Otherwise
        // take intrinsic width so the combo doesn't ballow into empty
        // space.
        let fillsParent = (element["style"] as? [String: Any])?["width"] as? String == "100%"
        // The field shows the RAW value ("100"); the menu lists the option
        // LABELS ("100%"). Mirrors the Rust reference (input value = raw
        // value, datalist carries the labels). A plain Picker shows the
        // selected option's label in the closed field, so use a Menu whose
        // label is the raw value.
        let textColor: SwiftUI.Color = theme.map { SwiftUI.Color(nsColor: $0.text) } ?? .primary
        let menu = Menu {
            ForEach(entries) { e in
                Button(e.displayLabel) {
                    guard let t = writeTarget else { return }
                    switch t.scope {
                    case .panel:
                        // Match Rust render_combo_box's onchange Panel branch:
                        // parse the picked value to a number when possible
                        // (scale % presets, arrowhead selections); named
                        // values stay strings.
                        let committed: Any =
                            Double(e.val).map { $0 as Any } ?? (e.val as Any)
                        commitWidgetWrite(target: t, value: committed)
                        // Generic input-commit hook: run the widget's
                        // `event: commit` behaviors after the native two-way
                        // write (e.g. the linked arrowhead-scale mirror).
                        // Scoped to commit, so gradient `change` combos are
                        // untouched — mirrors Rust run_input_commit_behavior,
                        // which the Panel branch calls after the native write.
                        if let model = model, let pid = panelId {
                            model.stateStore.setActivePanel(pid)
                            runInputCommitBehavior(
                                element: element, field: t.key,
                                committed: committed, context: context,
                                store: model.stateStore, model: model)
                        }
                    case .dialog:
                        // Rust's Dialog branch commits the raw string (no
                        // parse, no commit behavior).
                        commitWidgetWrite(target: t, value: e.val)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                SwiftUI.Text(currentValue).lineLimit(1).foregroundColor(textColor)
                Spacer(minLength: 0)
                SwiftUI.Text("\u{2304}").foregroundColor(textColor).opacity(0.6)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(SwiftUI.Color(white: 0.33), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        if fillsParent {
            menu.frame(maxWidth: .infinity).padding(.trailing, 24)
        } else {
            menu.fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: - Children

    @ViewBuilder
    private func renderChildElements() -> some View {
        let children = element["children"] as? [[String: Any]] ?? []
        ForEach(0..<children.count, id: \.self) { i in
            YamlElementView(element: children[i], context: context, model: model, panelId: panelId, onWidgetAction: onWidgetAction, theme: theme, flyoutIconDefault: flyoutIconDefault, onDialogWrite: onDialogWrite, onStoreDialogOpened: onStoreDialogOpened, onStoreDialogClosed: onStoreDialogClosed, onToolOptionsRequest: onToolOptionsRequest)
        }
    }

    // MARK: - Tabs (PRINT.md §1B; matches Rust render_tabs)

    /// Tabs widget — left-rail tab list plus a content area showing
    /// the active tab. Active tab is read from `bind.value` (typically
    /// `dialog.<field>`); falls back to the first tab id when no bind
    /// or empty value. Click writes the tab id back through
    /// commitWidgetWrite (panel store or dialog binding, depending on
    /// the bind prefix).
    @ViewBuilder
    private func renderTabs() -> some View {
        let tabs = element["tabs"] as? [[String: Any]] ?? []
        let bind = element["bind"] as? [String: Any]
        let valueExpr = bind?["value"] as? String
        let writeTarget = writeBackTarget(valueExpr)
        let firstId = (tabs.first?["id"] as? String) ?? ""
        let activeId: String = {
            if let e = valueExpr {
                let r = evaluate(e, context: context)
                if case .string(let s) = r, !s.isEmpty { return s }
            }
            return firstId
        }()
        let activeContent = tabs.first(where: { ($0["id"] as? String) == activeId })?["content"] as? [String: Any]

        HStack(alignment: .top, spacing: 0) {
            // Left rail
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<tabs.count, id: \.self) { i in
                    let tab = tabs[i]
                    let tabId = tab["id"] as? String ?? ""
                    let label = tab["label"] as? String ?? ""
                    let isActive = tabId == activeId
                    Button(action: {
                        if let t = writeTarget {
                            commitWidgetWrite(target: t, value: tabId)
                        }
                    }) {
                        SwiftUI.Text(label)
                            .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(isActive ? SwiftUI.Color.gray.opacity(0.2) : SwiftUI.Color.clear)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            // Fixed left-rail width — `minWidth` lets the rail balloon
            // when the parent HStack hands it half the dialog. The
            // tab labels max out around 130pt; 160pt gives padding.
            .frame(width: 160)
            .background(SwiftUI.Color.gray.opacity(0.08))
            // Content
            VStack {
                if let content = activeContent {
                    YamlElementView(element: content, context: context, model: model, panelId: panelId, onWidgetAction: onWidgetAction, theme: theme, flyoutIconDefault: flyoutIconDefault, onDialogWrite: onDialogWrite, onStoreDialogOpened: onStoreDialogOpened, onStoreDialogClosed: onStoreDialogClosed)
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Shared pointer-behavior helpers

/// True when `element` declares any click-family pointer behavior
/// (`click` / `double_click` / `click_and_wait`) — the events that
/// renderContainer / renderText turn into live tap gestures. Those render
/// arms host arbitrary widgets and gate their interactive branch on this so a
/// declared behavior is never silently dropped (the BRUSHDEAD brush-tile bug,
/// where a click-bearing container rendered as an inert box). Mirrors
/// jas_dioxus renderer.rs `has_pointer_behavior`.
func widgetHasPointerBehavior(_ element: [String: Any]) -> Bool {
    guard let behaviors = element["behavior"] as? [[String: Any]] else { return false }
    return behaviors.contains { b in
        let ev = (b["event"] as? String) ?? "click"
        return ev == "click" || ev == "double_click" || ev == "click_and_wait"
    }
}

/// Evaluate a tile widget's `bind.selected_in` membership: true when the
/// element's per-item identity (read from its click behavior's first
/// `select.target`, so authors don't repeat it) is a member of the bound list
/// expression. Shared by tile-shaped widgets (`color_swatch` and the
/// Brushes-panel brush-tile `container`) so the accent-outline selection cue
/// is drawn identically wherever a `selected_in` bind appears. Mirrors
/// jas_dioxus renderer.rs `eval_selected_in`.
func widgetSelectedIn(_ element: [String: Any], context: [String: Any]) -> Bool {
    guard let bind = element["bind"] as? [String: Any],
          let listExpr = bind["selected_in"] as? String
    else { return false }
    let listVal = evaluate(listExpr, context: context)
    guard case .list(let items) = listVal else { return false }

    guard let behaviors = element["behavior"] as? [[String: Any]] else { return false }
    var idExpr: String? = nil
    outer: for b in behaviors {
        guard let effects = b["effects"] as? [[String: Any]] else { continue }
        for e in effects {
            if let sel = e["select"] as? [String: Any],
               let target = sel["target"] as? String {
                idExpr = target
                break outer
            }
        }
    }
    guard let expr = idExpr else { return false }
    let idVal = evaluate(expr, context: context)
    let idAny: Any? = idVal.toAny()
    return items.contains { item in
        widgetSelectedInIdEquals(item.value, idAny)
    }
}

/// Loose typed equality used by `selected_in` lookup. Compares numeric /
/// string / bool values from list members (stored as `Any`) against an
/// evaluated identity value. Mirrors the Rust `list_contains_value` compare.
func widgetSelectedInIdEquals(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (is NSNull, is NSNull): return true
    case (let x as String, let y as String): return x == y
    case (let x as Bool, let y as Bool): return x == y
    case (let x as Int, let y as Int): return x == y
    case (let x as Double, let y as Double): return x == y
    case (let x as Int, let y as Double): return Double(x) == y
    case (let x as Double, let y as Int): return x == Double(y)
    case (let x as NSNumber, let y as NSNumber): return x == y
    default: return false
    }
}

/// Wire a click-bearing widget's declared pointer behaviors. Applies the same
/// gesture patterns color_swatch (ClickDisambiguator / tap) and icon_button
/// (PressDispatchModifier) use, so a declared behavior on a container or text
/// label is never silently dropped (the BRUSHDEAD bug). Mirrors jas_dioxus
/// render_container's onclick / ondoubleclick / onmousedown / onmouseup
/// wiring. Only attached on the interactive branch, so plain layout
/// containers and static labels never pay for a gesture.
private struct PointerBehaviorModifier: ViewModifier {
    let hasClick: Bool
    let hasDouble: Bool
    let hasPress: Bool
    let onSingle: () -> Void
    let onDouble: () -> Void
    let onPress: (CGPoint) -> Void
    let onRelease: () -> Void

    func body(content: Content) -> some View {
        // The press (mouse_down/up) gesture is only layered on when the
        // widget actually declares those behaviors, so a tap-only tile
        // (the brush tile) doesn't carry a spurious drag recognizer.
        if hasPress {
            tapWired(content)
                .modifier(PressDispatchModifier(
                    onPress: { loc in onPress(loc) },
                    onRelease: { onRelease() }
                ))
        } else {
            tapWired(content)
        }
    }

    @ViewBuilder
    private func tapWired(_ content: Content) -> some View {
        if hasClick && hasDouble {
            // A tile carrying both: disambiguate single vs double the same
            // way renderColorSwatch does. The single-click work re-renders
            // the panel, so ClickDisambiguator defers it via a
            // DispatchWorkItem that survives the re-render and the
            // double-tap cancels the pending single.
            content.modifier(ClickDisambiguator(onSingle: onSingle, onDouble: onDouble))
        } else if hasDouble {
            content.onTapGesture(count: 2) { onDouble() }
        } else if hasClick {
            content.onTapGesture { onSingle() }
        } else {
            content
        }
    }
}

/// Dispatch `mouse_down` / `mouse_up` behavior events for a press-and-
/// hold gesture (the toolbar's tool-alternates long-press: mouse_down
/// starts a 250ms timer whose effect opens the alternates flyout;
/// mouse_up cancels it). A plain SwiftUI Button only fires on click, so
/// icon_buttons that carry mouse_down/mouse_up behaviors layer this
/// simultaneous gesture on top. Owns a `pressed` @State so mouse_down
/// fires once per press (not on every drag-change tick). The recursive
/// YamlElementView can't hold @State itself, so this lives in a
/// dedicated modifier. Mirrors the Rust toolbar's onmousedown /
/// onmouseup handlers that drive start_timer / cancel_timer.
private struct PressDispatchModifier: ViewModifier {
    /// Receives the press location in the window's `.global` coordinate
    /// space — captured here at mouse_down so it can seed the
    /// tool-alternates popover anchor, mirroring Rust's
    /// `evt.data().page_coordinates()` capture in build_mousedown_handler.
    let onPress: (CGPoint) -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            // Capture in the shared "jasRoot" coordinate space (defined
            // on ContentView's root, wrapping both the panes and the
            // dialog overlay) so the press location and the overlay's
            // popover positioning resolve in ONE explicit space. macOS
            // gesture `.global` and the overlay's layout space don't
            // reliably align, which put the flyout down-and-right of the
            // press; a shared named space is exact.
            DragGesture(minimumDistance: 0, coordinateSpace: .named("jasRoot"))
                .onChanged { value in
                    if !pressed {
                        pressed = true
                        onPress(value.location)
                    }
                }
                .onEnded { _ in
                    pressed = false
                    onRelease()
                }
        )
    }
}

/// Conditionally attach the toolbar tool-options double-click gesture.
/// Only the bundle toolbar's tool slots want it (``enabled``); every
/// other icon_button passes ``enabled: false`` and the view is returned
/// unchanged, so panel / dialog buttons keep their single-click-only
/// behavior. The gesture is `simultaneous`, so the slot's single-click
/// ``select_tool`` action still fires — the double-click only adds the
/// options dispatch on top. Mirrors the prior native toolbar's
/// ``TapGesture(count: 2)`` / ``.onTapGesture(count: 2)`` over the same
/// tool buttons.
private struct ToolOptionsDblClickModifier: ViewModifier {
    let enabled: Bool
    let onDoubleClick: (() -> Void)?

    func body(content: Content) -> some View {
        if enabled, let action = onDoubleClick {
            content.simultaneousGesture(
                TapGesture(count: 2).onEnded { action() }
            )
        } else {
            content
        }
    }
}

/// A simple slider wrapper to avoid @State in the recursive view.
/// Text input that buffers keystrokes locally and only fires `commit`
/// on Enter or blur. Mirrors the controlled-but-uncommitted pattern
/// from renderNumberInput's TextField/.number binding (which only
/// fires on Enter / Tab) for plain-string inputs like the Color
/// panel hex field. Without this, every keystroke went through
/// commitWidgetWrite → commitPanelWrite → re-render, and the field
/// snapped back to the previous panel-state value mid-typing.
private struct BufferedTextField: View {
    let placeholder: String
    let externalValue: String
    let commit: (String) -> Void
    @State private var text: String = ""
    @State private var syncOnNextChange: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .focused($focused)
            .onAppear { text = externalValue }
            .onChange(of: externalValue) { newValue in
                // After a commit we always pull the post-commit
                // (possibly transformed, e.g. Web Safe snap) value
                // back even if focus stayed (Enter). Outside of a
                // commit, only sync when unfocused so a re-render
                // mid-typing doesn't clobber the user's input.
                if syncOnNextChange {
                    text = newValue
                    syncOnNextChange = false
                } else if !focused, newValue != text {
                    text = newValue
                }
            }
            // Tab fires onSubmit AND focused→false; Enter fires only
            // onSubmit. The guard in commitIfChanged makes the Tab
            // double-call a no-op.
            .onSubmit { commitIfChanged() }
            .onChange(of: focused) { isFocused in
                if !isFocused { commitIfChanged() }
            }
    }

    private func commitIfChanged() {
        guard text != externalValue else { return }
        syncOnNextChange = true
        commit(text)
    }
}

private struct SliderView: View {
    @State var value: Double
    let range: ClosedRange<Double>
    /// Snap step. 0 = continuous (default). Web Safe RGB sliders use
    /// 51 to snap to 0 / 51 / 102 / 153 / 204 / 255.
    var step: Double = 0
    /// Live callback fired on every drag tick (passes the current
    /// value). Used by the Color panel's HSB / RGB / CMYK sliders
    /// to update the active fill or stroke color in real time
    /// without committing it to the recent strip.
    var onChange: ((Double) -> Void)? = nil
    /// Pointer-up callback. Commits the final value (e.g. pushes
    /// the resulting color onto the recent-colors strip).
    var onCommit: ((Double) -> Void)? = nil

    private func snap(_ v: Double) -> Double {
        guard step > 0 else { return v }
        let snapped = (v / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    var body: some View {
        let binding = Binding<Double>(
            get: { value },
            set: { newValue in
                let v = step > 0 ? snap(newValue) : newValue
                value = v
                onChange?(v)
            }
        )
        let onEdit: (Bool) -> Void = { editing in
            if !editing { onCommit?(value) }
        }
        if step > 0 {
            return AnyView(Slider(value: binding, in: range, step: step, onEditingChanged: onEdit))
        } else {
            return AnyView(Slider(value: binding, in: range, onEditingChanged: onEdit))
        }
    }
}

// MARK: - Tree View Content (live document)

private let layerColors = [
    "#4a90d9", "#d94a4a", "#4ad94a", "#4a4ad9", "#d9d94a",
    "#d94ad9", "#4ad9d9", "#b0b0b0", "#2a7a2a",
]

private func elementTypeLabel(_ elem: Element) -> String {
    switch elem {
    case .line: return "Line"
    case .rect: return "Rectangle"
    // DERIVED, so the auto-generated label agrees with the type token rather
    // than contradicting it: a round ellipse reads `<Circle>`. This does NOT
    // re-couple the two axes JYH separated -- the label is still just a label,
    // a user-given name still wins, and the filter still reads the ELEMENT.
    // They agree because both are computed from the same fact.
    case .ellipse(let e): return e.rx == e.ry ? "Circle" : "Ellipse"
    case .polyline: return "Polyline"
    case .polygon: return "Polygon"
    case .path: return "Path"
    case .text: return "Text"
    case .textPath: return "Text Path"
    case .group: return "Group"
    case .layer: return "Layer"
    case .live(let v):
        switch v {
        case .compoundShape: return "Compound Shape"
        case .reference: return "Reference"
        case .recorded: return "Recorded"
        case .generated: return "Generated"
        }
    }
}

/// The Layers-panel row label: the artist's own name when the element has
/// one, else a `<Type>` bracket placeholder.
///
/// EVERY element's name counts, not only a Layer's. This used to pattern-match
/// `.layer` alone, so a named Rect / Group / Path / Text — and, once live
/// elements gained a name slot at all, a named Compound Shape — showed
/// `<Rect>` / `<Compound Shape>` in this port while jas_dioxus showed the
/// name: `tree_elem_display_name` there has always read `elem.common().name`
/// generically. The empty-string guard is kept, and it is load-bearing: an
/// empty name is not a name, and falling through to the bracket label is what
/// Rust does too.
/// Internal rather than `private` so `LayersRowLabelTests` can assert its
/// VALUE directly: the widget-tree panel goldens turned out to be vacuous
/// here — no golden contains a NAMED non-layer element, so flipping this
/// function's behaviour moved not one golden byte.
func elementDisplayName(_ elem: Element) -> (String, Bool) {
    if let n = elem.name, !n.isEmpty {
        return (n, true)
    }
    return ("<\(elementTypeLabel(elem))>", false)
}

/// The token the Layers type filter matches an element against, in the
/// spelling `workspace/panels/layers.yaml`'s `lp_filter_button` uses for its
/// `items` values.
///
/// DERIVED FROM THE ELEMENT, NEVER FROM ITS DISPLAY NAME. This port has always
/// matched on the element; jas_dioxus recovered the type by parsing the row
/// label until 2026-07-29, matching `<Rectangle>` apart and letting anything
/// else fall through to `""`, so over there NAMING AN ELEMENT EXEMPTED IT FROM
/// THE FILTER. `layers.yaml` says "Unchecking a type hides all elements of
/// that type" — all of them, whatever the artist has called them.
///
/// The general shape is worth more than the instance: a display name is a
/// PRESENTATION of an element and its type is a FACT about it, so recovering
/// the fact from the presentation is lossy the moment presentation gains a
/// second form — which is precisely what `elementDisplayName` above did when
/// every element became nameable.
///
/// `.live` answers "live", which no menu item offers, so a live element is
/// unfilterable in BOTH ports. Spelled identically on both sides so that
/// stays a shared gap by agreement rather than a divergence waiting on
/// whoever adds the option.
/// Internal rather than `private` so `LayersTypeFilterTests` can assert it.
func layersTypeValue(_ elem: Element) -> String {
    switch elem {
    case .line: return "line"
    case .rect: return "rectangle"
    // ONE ROUND KIND, so `circle` is DERIVED (JYH, 2026-07-30). Before that the
    // token was whichever SVG tag the element arrived as, which is PROVENANCE:
    // scaling composes a matrix onto `transform` and never touches radii, so a
    // `circle` stayed typed `circle` while being drawn as an egg. The Circle
    // checkbox answered "which tag was this" -- a question no artist asks.
    //
    // AS AUTHORED, DELIBERATELY: `transform` is not consulted. No other token
    // accounts for transforms either -- a sheared rect is still `rectangle` --
    // and making this the one token that reads the matrix would be a second
    // rule nobody could predict from the first.
    case .ellipse(let e): return e.rx == e.ry ? "circle" : "ellipse"
    case .polyline: return "polyline"
    case .polygon: return "polygon"
    case .path: return "path"
    case .text: return "text"
    case .textPath: return "text_path"
    case .group: return "group"
    case .layer: return "layer"
    case .live: return "live"
    }
}

/// Every type token the filter menu can offer, in `layers.yaml` order. The twin
/// of jas_dioxus's `ALL_TYPE_TOKENS`; `scripts/check_layers_type_filter.py`
/// asserts both against the shipping YAML in one run.
let layersAllTypeTokens: [String] = [
    "layer", "group", "path", "rectangle", "circle", "ellipse",
    "polyline", "polygon", "text", "text_path", "line", "live",
]

/// The hidden-type set implied by a CHECKED set.
///
/// JYH's ruling, council 2026-07-30: a checked type lists all its elements plus
/// their ancestors; nothing checked — the default — is the same as checking
/// everything. Checked and unchecked are complements over the menu, so the
/// keep-computation below did not move; only the state's MEANING did.
///
/// The empty case is load-bearing: `type_filter` defaults to `[]`, so without
/// it the panel would open showing nothing.
func layersHiddenFromChecked(_ checked: Set<String>) -> Set<String> {
    if checked.isEmpty { return [] }
    return Set(layersAllTypeTokens.filter { !checked.contains($0) })
}

/// Paths surviving the Layers type filter, given each row as its path and the
/// token `layersTypeValue` answered for it.
///
/// An ancestor of a surviving row is kept even when its own type is hidden: a
/// tree cannot draw a child without its parent row. That makes hiding a
/// CONTAINER type inoperative whenever any descendant survives, which is not
/// obviously what `layers.yaml`'s "hides all elements of that type" intends.
/// jas_dioxus's `tree_type_filter_keep` does the identical thing, so it is a
/// shared question for council rather than a divergence.
func layersTypeFilterKeep(_ rows: [(path: ElementPath, typeValue: String)],
                          hidden: Set<String>) -> Set<ElementPath> {
    let visible = Set(rows.filter { !hidden.contains($0.typeValue) }.map { $0.path })
    var keep = visible
    for p in visible {
        for i in 1..<max(p.count, 1) { keep.insert(Array(p.prefix(i))) }
    }
    return keep
}

/// What a `lp_filter_button` item DOES when clicked, read from its declared
/// `type` and never inferred from the fields it happens to carry.
enum LayersMenuRowKind: Equatable {
    /// `type: toggle` — a type token that goes in or out of the CHECKED set.
    case toggle
    /// `type: action` — a named behaviour, carried verbatim from the item's
    /// `action` key and routed by `layersCheckedAfterAction`.
    case action(String)
}

/// One rendered row of the Layers filter menu.
struct LayersMenuRow: Equatable {
    let label: String
    let value: String
    let kind: LayersMenuRowKind
}

/// The menu rows a `lp_filter_button`-shaped `items` list declares, in
/// declaration order.
///
/// This port has dispatched on the declared `type` since `renderDropdown` was
/// written; jas_dioxus, written from it the same day, collected every item that
/// carried a `label` and a `value` — so its `All` row (an ACTION) rendered as a
/// thirteenth checkbox, clicking it checked the token `__all__`, and since
/// nothing answers `__all__` the complement over the menu was the whole
/// vocabulary and the tree went blank.
///
/// THE RULE MOVES OUT OF THE VIEW rather than being left correct-in-place,
/// because correct-in-place is what it already was and nothing could see it: the
/// menu was private render code in both ports, which is why they could disagree
/// for as long as it took someone to click All. Extracted, both ports answer the
/// `menu` block of `test_fixtures/view_state/layers_type_filter.json`.
///
/// AN UNRECOGNISED OR ABSENT `type` YIELDS NO ROW — reading `label` + `value` as
/// licence to render a checkbox is the defect itself. A missing menu item is a
/// loud, local failure; a blank tree is neither.
///
/// Twin: `menu_rows` in jas_dioxus/src/algorithms/layers_filter.rs.
func layersFilterMenuRows(_ items: [[String: Any]]) -> [LayersMenuRow] {
    items.compactMap { item in
        guard let label = item["label"] as? String,
              let value = item["value"] as? String else { return nil }
        let kind: LayersMenuRowKind
        switch item["type"] as? String {
        case "toggle":
            kind = .toggle
        case "action":
            guard let action = item["action"] as? String else { return nil }
            kind = .action(action)
        default:
            return nil
        }
        return LayersMenuRow(label: label, value: value, kind: kind)
    }
}

/// The CHECKED set after invoking a declared menu action, or `nil` when the
/// action is not one this port knows.
///
/// `nil` RATHER THAN A FALLBACK, deliberately. An unknown action answered with
/// the empty set would turn every future typo into *show everything*; answered
/// with the unchanged set it would make a real action silently inert. Refusing
/// lets the caller render the row without pretending it works — and guessing a
/// meaning for a token nobody defined is the move that made `__all__` a type in
/// the other port.
///
/// `checked` is unused today because the one declared action, `All`, does not
/// read the current set. It is a parameter because the next one will: solo,
/// invert and *check every type* are all functions of what is already checked.
func layersCheckedAfterAction(_ action: String, _ checked: Set<String>) -> Set<String>? {
    switch action {
    // `layers.yaml`: "The 'All' item at the top restores the default in one
    // click." The default is the empty set, which under the ruled semantics
    // means everything is listed.
    case "clear_layers_type_filter": return []
    default: return nil
    }
}

/// Whether an action's effect is ALREADY IN FORCE — what the tick on an action
/// row means, as against a toggle's tick, which means "this type is checked".
///
/// Stated as *invoking it would change nothing* rather than as a hand-written
/// per-action predicate, so a new action cannot arrive with a tick rule that
/// contradicts what its own invocation does. An unknown action is never in
/// force: it is inert, not satisfied.
func layersActionIsInForce(_ action: String, _ checked: Set<String>) -> Bool {
    layersCheckedAfterAction(action, checked) == checked
}

private func visIcon(_ vis: Visibility) -> String {
    switch vis {
    case .preview: return "\u{25C9}"
    case .outline: return "\u{25D0}"
    case .invisible: return "\u{25CB}"
    }
}

private func pathToString(_ path: ElementPath) -> String {
    path.map(String.init).joined(separator: ",")
}

private func cycleVisibility(_ vis: Visibility) -> Visibility {
    vis.cycled
}

/// Build a fitted-viewBox SVG fragment for a single element.
/// Internal rather than `private` so `LayersThumbnailNamespaceTests` can
/// assert its output. Being unreachable is why the undeclared-prefix defect
/// shipped: nothing could look at what this function emitted.
func buildPreviewSvg(_ elem: Element) -> String {
    let b = elem.bounds
    let w = b.width, h = b.height
    if !w.isFinite || !h.isFinite || w <= 0 || h <= 0 {
        return ""
    }
    let pad = max(max(w, h) * 0.02, 0.5)
    let vb = "\(b.x - pad) \(b.y - pad) \(w + 2 * pad) \(h + 2 * pad)"
    let inner = elementSvg(elem, indent: "")
    // DECLARES xmlns:inkscape: the element serializer emits `inkscape:label`
    // for any NAMED element, and an undeclared prefix is invalid XML that a
    // strict parser rejects whole. Same lesson this codebase already recorded
    // for `jas:`; found by JYH when console noise appeared right after
    // renaming became possible on every element.
    return #"<svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" viewBox=""# + vb + #"" preserveAspectRatio="xMidYMid meet">"# + inner + "</svg>"
}

/// SwiftUI view that renders an element as a fitted SVG thumbnail.
/// NSImage natively parses SVG data on recent macOS.
struct ElementThumbnail: View {
    let elem: Element
    let size: CGFloat

    var body: some View {
        let svg = buildPreviewSvg(elem)
        ZStack {
            Rectangle().fill(SwiftUI.Color.white)
            if let data = svg.data(using: .utf8),
               let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(1)
            }
        }
        .frame(width: size, height: size)
        .overlay(Rectangle().stroke(SwiftUI.Color.gray, lineWidth: 1))
    }
}

/// Wrapper that makes an ElementPath Identifiable for use with .sheet(item:).
struct IdentifiablePath: Identifiable {
    let id: String
    let path: ElementPath
}

/// Modal sheet for editing a layer's name, lock state, and visibility.
struct LayerOptionsSheet: View {
    @ObservedObject var model: Model
    let path: ElementPath
    let onClose: () -> Void

    @State private var name: String = ""
    @State private var lock: Bool = false
    @State private var show: Bool = true
    @State private var preview: Bool = true

    var body: some View {
        let e = model.document.getElement(path)
        VStack(alignment: .leading, spacing: 10) {
            SwiftUI.Text("Layer Options").font(.headline)
            HStack {
                SwiftUI.Text("Name:")
                TextField("", text: $name)
            }
            Toggle("Lock", isOn: $lock)
            Toggle("Show", isOn: $show)
            Toggle("Preview", isOn: $preview).disabled(!show)
            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                Button("OK") {
                    // Route through the YAML layer_options_confirm action
                    // so Swift shares the commit logic with the spec.
                    let layerIdStr = path.map(String.init)
                        .joined(separator: ".")
                    LayersPanel.dispatchYamlAction(
                        "layer_options_confirm",
                        model: model,
                        params: [
                            "layer_id": layerIdStr,
                            "name": name,
                            "lock": lock,
                            "show": show,
                            "preview": preview,
                        ],
                        onCloseDialog: onClose
                    )
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            if case .layer(let le) = e {
                name = le.name ?? ""
                lock = le.locked
                show = le.visibility != .invisible
                preview = le.visibility == .preview
            }
        }
    }
}

/// Flat row descriptor used when rendering the tree. Pre-computing this
/// list lets us apply filters (search, type, isolation) without recursive
/// SwiftUI views.
struct FlatRow: Identifiable {
    let id: String
    let path: ElementPath
    let elem: Element
    let depth: Int
    let isContainer: Bool
    let isCollapsed: Bool
    let layerColor: String
    /// True when this row survives only because a DESCENDANT needs it.
    ///
    /// Both filters carry ancestors of surviving rows, because a tree cannot
    /// draw a child without its parent. Those rows are scaffolding, not
    /// content: JYH ruled 2026-07-30 that they are CARRIED, NEVER MATCHED, and
    /// render dimmed. Twin of jas_dioxus's `TreeRow::ancestor_only`.
    ///
    /// layers.yaml has declared the convention since April and no port ever
    /// implemented it — the `opacity` bind lives in `row_template`, which NO
    /// port reads, so it has never executed anywhere.
    var ancestorOnly: Bool = false
}

struct TreeViewContent: View {
    @ObservedObject var model: Model
    @State private var collapsed: Set<ElementPath> = []
    @State private var panelSelection: Set<ElementPath> = []
    @State private var panelSelectionAnchor: ElementPath? = nil
    @State private var renamingPath: ElementPath? = nil
    /// The rename field must TAKE the keyboard when it appears. jas_dioxus sets
    /// `autofocus` on its rename input AND calls `.focus()` explicitly, with a
    /// comment noting the browser blocks autofocus when something else already
    /// holds focus. SwiftUI has the same problem and no default answer: without
    /// this the field appears, looks editable, and swallows every keystroke
    /// because focus is still on the tree.
    @FocusState private var renameFieldFocused: Bool
    @State private var editingName: String = ""
    @State private var dragSource: ElementPath? = nil
    @State private var dragTarget: ElementPath? = nil
    /// `panel.search_query` / `panel.type_filter`, read from the store rather
    /// than held in view-lived `@State`. lp_tree DECLARES both binds and this
    /// port honoured neither -- it drew its own search field and its own menu
    /// into a state no YAML write could reach (council Q3.1 / Q3.2).
    private var searchQuery: String {
        (model.stateStore.getPanel("layers_panel_content", "search_query") as? String) ?? ""
    }
    private var checkedTypes: Set<String> {
        Set((model.stateStore.getPanel("layers_panel_content", "type_filter")
             as? [String]) ?? [])
    }
    @State private var isolationStack: [ElementPath] = []
    @State private var soloState: (path: ElementPath, saved: [ElementPath: Visibility])? = nil
    @State private var showLayerOptionsFor: ElementPath? = nil
    @FocusState private var treeFocused: Bool
    // Tracks current modifier keys from an NSEvent monitor (macOS).
    @State private var modifierFlags: NSEvent.ModifierFlags = []

    private func elementChildrenStatic(_ elem: Element) -> [Element]? {
        switch elem {
        case .group(let g): return g.children
        case .layer(let l): return l.children
        default: return nil
        }
    }

    private func isContainerElem(_ elem: Element) -> Bool {
        switch elem {
        case .group, .layer: return true
        default: return false
        }
    }

    // The type token and the keep-set both live at module scope now, beside
    // `elementDisplayName`, so `LayersTypeFilterTests` can assert them — see
    // `layersTypeValue`. A private method here could only be reached by
    // rendering the view.

    private func flatten(_ doc: Document) -> [FlatRow] {
        var out: [FlatRow] = []
        func walk(_ children: [Element], depth: Int, prefix: ElementPath, color: String) {
            for i in children.indices.reversed() {
                let elem = children[i]
                let path = prefix + [i]
                let isCont = isContainerElem(elem)
                let isColl = collapsed.contains(path)
                let myColor: String = {
                    if case .layer = elem, path.count == 1 {
                        return layerColors[i % layerColors.count]
                    }
                    return color
                }()
                let id = path.map(String.init).joined(separator: "_")
                out.append(FlatRow(id: id, path: path, elem: elem, depth: depth,
                                   isContainer: isCont, isCollapsed: isColl, layerColor: myColor))
                if isCont && !isColl, let kids = elementChildrenStatic(elem) {
                    walk(kids, depth: depth + 1, prefix: path, color: myColor)
                }
            }
        }
        // Top-level layers as Element.layer
        let topElements = doc.layers.map { Element.layer($0) }
        walk(topElements, depth: 0, prefix: [], color: "#4a90d9")
        return out
    }

    private func applyFilters(_ rows: [FlatRow]) -> [FlatRow] {
        var result = rows
        // Type filter
        // `panel.type_filter` holds the CHECKED types (JYH, council
        // 2026-07-30); the keep-computation wants their complement. Empty stays
        // empty -- nothing checked means everything shown, the ruling's one
        // exception and the declared default.
        let hidden = layersHiddenFromChecked(checkedTypes)
        if !hidden.isEmpty {
            let keep = layersTypeFilterKeep(
                result.map { (path: $0.path, typeValue: layersTypeValue($0.elem)) },
                hidden: hidden)
            // Present on its OWN account = its type is checked. Anything else
            // that survived is here only to reach a descendant.
            for i in result.indices where hidden.contains(layersTypeValue(result[i].elem)) {
                result[i].ancestorOnly = true
            }
            result = result.filter { keep.contains($0.path) }
        }
        // Isolation filter
        if let root = isolationStack.last {
            result = result.compactMap { r in
                guard r.path.count > root.count,
                      Array(r.path.prefix(root.count)) == root else { return nil }
                return FlatRow(id: r.id, path: r.path, elem: r.elem,
                               depth: r.depth - root.count,
                               isContainer: r.isContainer, isCollapsed: r.isCollapsed,
                               layerColor: r.layerColor)
            }
        }
        // Search filter
        let q = searchQuery.lowercased()
        if !q.isEmpty {
            // ANCESTORS ARE CARRIED, NEVER MATCHED. Scaffolding must not
            // answer a search, or a group named "sunset" satisfies a query for
            // "sun" while the type filter says containers are not content —
            // and an artist asking for circles named sun gets a group row and
            // no circles.
            let matching = Set(result.filter {
                let (n, _) = elementDisplayName($0.elem)
                return !$0.ancestorOnly && n.lowercased().contains(q)
            }.map { $0.path })
            var keep = matching
            for p in matching {
                for i in 1..<p.count { keep.insert(Array(p.prefix(i))) }
            }
            for i in result.indices where !matching.contains(result[i].path) {
                result[i].ancestorOnly = true
            }
            result = result.filter { keep.contains($0.path) }
        }
        return result
    }

    var body: some View {
        let doc = model.document
        let selectedPaths = doc.selectedPaths
        // Auto-expand ancestors of selected paths
        for p in selectedPaths where p.count > 1 {
            for i in 1..<p.count {
                let anc = Array(p.prefix(i))
                if collapsed.contains(anc) {
                    // Note: mutating @State during body is discouraged; use a
                    // DispatchQueue hop to defer the change
                    DispatchQueue.main.async {
                        collapsed.remove(anc)
                    }
                }
            }
        }
        let rows = applyFilters(flatten(doc))
        let firstSelected = selectedPaths.sorted(by: { $0.lexicographicallyPrecedes($1) }).first
        return VStack(spacing: 0) {
            // NO SEARCH BAR HERE. `layers.yaml` declares `lp_search_bar` --
            // `lp_search_input` plus `lp_filter_button` -- as siblings of this
            // tree, and this view used to draw its OWN copies of both. The
            // artist saw the search box twice and two filter controls, one of
            // them the inert grey placeholder the YAML widget rendered as.
            // Council Q3.2: the declared widgets are the only ones now.

            if !isolationStack.isEmpty {
                breadcrumbBar
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row: row, selectedPaths: selectedPaths)
                                .id(row.id)
                        }
                    }
                }
                .onChange(of: firstSelected) { newVal in
                    if let p = newVal {
                        let rowId = p.map(String.init).joined(separator: "_")
                        withAnimation { proxy.scrollTo(rowId, anchor: .center) }
                    }
                }
            }
        }
        .focusable()
        .focused($treeFocused)
        // Mirror the tree selection into the store under the key layers.yaml
        // declares (`panel.panel_selection`), so readers outside this view —
        // the hamburger menu's `enabled_when` rows through
        // `layersPanelSelection(model:)`, the dock's body context — see the
        // selection the artist made. Sorted so the published list is
        // deterministic; a Set has no order and the YAML indexes `[0]`.
        .onChange(of: panelSelection) { sel in
            let store = model.stateStore
            if !store.hasPanel("layers_panel_content") {
                let defaults = WorkspaceData.load()?.panelStateDefaults("layers_panel_content") ?? [:]
                store.initPanel("layers_panel_content", defaults: defaults)
            }
            let paths = sel.map { Array($0) }
                .sorted(by: { $0.lexicographicallyPrecedes($1) })
            store.setPanel("layers_panel_content", "panel_selection", paths)
            model.panelStateVersion &+= 1
        }
        .onAppear {
            // NSEvent local monitor to capture modifier keys during mouse events.
            // Also handles Delete/Cmd-A/Escape key shortcuts when the tree is focused.
            NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .leftMouseDown, .keyDown]) { evt in
                modifierFlags = evt.modifierFlags
                if evt.type == .keyDown && treeFocused {
                    if evt.keyCode == 51 || evt.keyCode == 117 {
                        // 51 = Delete (backspace), 117 = Forward Delete
                        performDeleteSelection()
                        return nil
                    } else if evt.keyCode == 0 && evt.modifierFlags.contains(.command) {
                        // 0 = 'a' — Cmd-A selects all
                        selectAll()
                        return nil
                    } else if evt.keyCode == 53 {
                        // 53 = Escape
                        if renamingPath != nil { renamingPath = nil; return nil }
                        if !isolationStack.isEmpty { isolationStack.removeLast(); return nil }
                    }
                }
                return evt
            }
        }
        .sheet(item: Binding<IdentifiablePath?>(
            get: { showLayerOptionsFor.map { IdentifiablePath(id: $0.map(String.init).joined(separator: "_"), path: $0) } },
            set: { showLayerOptionsFor = $0?.path }
        )) { ip in
            LayerOptionsSheet(model: model, path: ip.path, onClose: { showLayerOptionsFor = nil })
        }
    }

    private func performDrop(onto target: ElementPath) -> Bool {
        guard let src = dragSource, src != target else {
            dragSource = nil; dragTarget = nil
            return false
        }
        // Constraints
        let isCycle = target.count >= src.count && Array(target.prefix(src.count)) == src
        let parentPath = Array(target.dropLast())
        var parentLocked = false
        if !parentPath.isEmpty {
            parentLocked = model.document.getElement(parentPath).isLocked
        }
        if isCycle || parentLocked {
            dragSource = nil; dragTarget = nil
            return false
        }
        let moved = model.document.getElement(src)
        var doc = model.document.deleteElement(src)
        var tgt = target
        let sameLevel = (src.count == tgt.count) && (Array(src.dropLast()) == Array(tgt.dropLast()))
        let srcLast = src.last ?? 0
        let tgtLast = tgt.last ?? 0
        if sameLevel && srcLast < tgtLast {
            tgt[tgt.count - 1] = tgtLast - 1
        }
        let tl = tgt.last ?? 0
        if tl > 0 {
            var insertAfter = tgt
            insertAfter[insertAfter.count - 1] = tl - 1
            doc = doc.insertElementAfter(insertAfter, element: moved)
        } else {
            doc = doc.insertElementAfter(tgt, element: moved)
        }
        // Undoable layer reorder: editDocument self-brackets one undo step.
        model.editDocument(doc)
        dragSource = nil; dragTarget = nil
        return true
    }

    private func handleRowTap(path: ElementPath) {
        let shift = modifierFlags.contains(.shift)
        let cmd = modifierFlags.contains(.command)
        if shift, let anchor = panelSelectionAnchor {
            // Range selection in visual order (flat row list).
            let rows = applyFilters(flatten(model.document))
            let allPaths = rows.map { $0.path }
            if let a = allPaths.firstIndex(of: anchor),
               let c = allPaths.firstIndex(of: path) {
                let (lo, hi) = a <= c ? (a, c) : (c, a)
                panelSelection = Set(allPaths[lo...hi])
            } else {
                panelSelection = [path]
            }
        } else if cmd {
            if panelSelection.contains(path) { panelSelection.remove(path) }
            else { panelSelection.insert(path) }
            panelSelectionAnchor = path
        } else {
            panelSelection = [path]
            panelSelectionAnchor = path
        }
    }

    private func handleEyeTap(path: ElementPath) {
        let opt = modifierFlags.contains(.option)
        let e = model.document.getElement(path)
        if opt {
            // Option-click: solo/unsolo among siblings
            let parentPrefix = Array(path.dropLast())
            let siblings: [ElementPath] = {
                if parentPrefix.isEmpty {
                    return (0..<model.document.layers.count).map { [$0] }
                }
                let parent = model.document.getElement(parentPrefix)
                let kids: [Element]
                switch parent {
                case .group(let g): kids = g.children
                case .layer(let l): kids = l.children
                default: return []
                }
                return (0..<kids.count).map { parentPrefix + [$0] }
            }()
            if let s = soloState, s.path == path {
                // Unsolo: restore. editDocument self-brackets one undo step.
                var d = model.document
                for (sp, vis) in s.saved {
                    let e2 = d.getElement(sp)
                    d = d.replaceElement(sp, with: e2.withVisibility(vis))
                }
                model.editDocument(d)
                soloState = nil
            } else {
                var saved: [ElementPath: Visibility] = [:]
                for sp in siblings where sp != path {
                    saved[sp] = model.document.getElement(sp).visibility
                }
                var d = model.document
                if e.visibility == .invisible {
                    d = d.replaceElement(path, with: e.withVisibility(.preview))
                }
                for sp in siblings where sp != path {
                    let e2 = d.getElement(sp)
                    d = d.replaceElement(sp, with: e2.withVisibility(.invisible))
                }
                model.editDocument(d)
                soloState = (path: path, saved: saved)
            }
        } else {
            soloState = nil
            // Cycle visibility + deselect-on-invisible, one undoable edit.
            model.editDocument(model.document.cyclingElementVisibility(at: path))
        }
    }

    private func performDeleteSelection() {
        guard !panelSelection.isEmpty else { return }
        let topDeletes = panelSelection.filter { $0.count == 1 }.count
        if topDeletes >= model.document.layers.count { return }
        // Reference-aware delete (warn-then-orphan): if deleting these tree
        // rows via the in-panel keyboard Delete/Backspace would leave live
        // instances pointing at a now-gone target, confirm first. Mirrors the
        // context-menu `deleteSelection()` guard. Empty orphan set -> delete as
        // today (no dialog). Uses the PANEL selection paths, not doc.selection.
        let paths = panelSelection.map { Array($0) }
        let orphaned = DependencyIndex.orphanedReferences(model.document, paths)
        if !orphaned.isEmpty && !JasCommands.confirmOrphaningDelete(orphaned.count) {
            return
        }
        LayersPanel.dispatchYamlAction(
            "delete_layer_selection",
            model: model,
            panelSelection: paths
        )
        panelSelection.removeAll()
    }

    private func selectAll() {
        panelSelection.removeAll()
        func collect(_ children: [Element], prefix: ElementPath) {
            for (i, e) in children.enumerated() {
                let p = prefix + [i]
                panelSelection.insert(p)
                switch e {
                case .group(let g): collect(g.children, prefix: p)
                case .layer(let l): collect(l.children, prefix: p)
                default: break
                }
            }
        }
        let tops = model.document.layers.map { Element.layer($0) }
        collect(tops, prefix: [])
    }

    @ViewBuilder
    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            SwiftUI.Text("⌂")
                .font(.system(size: 11))
                .onTapGesture { isolationStack.removeAll() }
            ForEach(Array(isolationStack.enumerated()), id: \.offset) { idx, p in
                SwiftUI.Text(">")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                let label: String = {
                    let e = model.document.getElement(p)
                    let (n, _) = elementDisplayName(e)
                    return n
                }()
                SwiftUI.Text(label)
                    .font(.system(size: 11))
                    .onTapGesture { isolationStack = Array(isolationStack.prefix(idx + 1)) }
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(SwiftUI.Color(white: 0.16))
    }

    @ViewBuilder
    private func rowView(row: FlatRow, selectedPaths: Set<ElementPath>) -> some View {
        let elem = row.elem
        let path = row.path
        // AT OR UNDER a selected path, not an exact match: selecting a group
        // marks its members' rows too (RULED 2026-07-29). The shorthand is
        // expanded here rather than in the stored selection. The identical
        // line in `treeRows_OLD` is deliberately NOT changed — it and its
        // only caller `treeRows_DEPRECATED` are unreferenced dead code, and
        // touching it would imply it is live.
        let isSelected = pathIsSelectedOrUnder(selectedPaths, path)
        let isPanelSelected = panelSelection.contains(path)
        let (name, isNamed) = elementDisplayName(elem)
        let vis = elem.visibility
        let locked = elem.isLocked
        HStack(spacing: 2) {
            if row.depth > 0 {
                Spacer().frame(width: CGFloat(row.depth * 16))
            }
            // Eye — supports Option-click for solo/unsolo
            SwiftUI.Text(visIcon(vis))
                .frame(width: 16, height: 16)
                .onTapGesture { handleEyeTap(path: path) }
            // Lock
            SwiftUI.Text(locked ? "\u{1F512}" : "\u{1F513}")
                .frame(width: 16, height: 16)
                .onTapGesture {
                    // The save/restore dance that used to stand here went with
                    // materialization (transcripts/LAYER_STRUCTURE.md §13): a
                    // lock now writes ONE flag and reaches the contents by
                    // inheritance, so there is nothing to remember — and the
                    // `@State` table it lived in was VIEW-lived, so a later
                    // unlock after the panel had been torn down silently failed
                    // to restore anything anyway (D5b).
                    // Undoable lock toggle: editDocument self-brackets one step.
                    model.editDocument(model.document.togglingElementLock(at: path))
                }
            // Twirl or gap
            if row.isContainer {
                let isColl = collapsed.contains(path)
                SwiftUI.Text(isColl ? "\u{25B6}" : "\u{25BC}")
                    .frame(width: 16, height: 16)
                    .onTapGesture {
                        if collapsed.contains(path) { collapsed.remove(path) }
                        else { collapsed.insert(path) }
                    }
            } else {
                Spacer().frame(width: 16)
            }
            // Preview thumbnail
            ElementThumbnail(elem: elem, size: 24)
            // Name — inline TextField when renaming, Text otherwise
            if renamingPath == path {
                TextField("", text: $editingName, onCommit: {
                    // ANY element kind, not just Layer (council O4, 2026-07-30).
                    // `Element.withName` is clone-then-mutate for every case and
                    // normalizes the empty string to nil, matching jas_dioxus's
                    // `elem.common_mut().name = if empty { None } else { Some }`.
                    // A rename speaks to the NAME and preserves the rest — the
                    // rebuild this pattern replaced named 6 of Layer's 11 stored
                    // fields and destroyed id, blend mode, mask and both opacity
                    // flags on every rename.
                    let e = model.document.getElement(path)
                    // Undoable rename: editDocument self-brackets one step.
                    model.editDocument(
                        model.document.replaceElement(path, with: e.withName(editingName)))
                    renamingPath = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($renameFieldFocused)
                .onAppear { renameFieldFocused = true }
                .onExitCommand { renamingPath = nil }
            } else {
                SwiftUI.Text(name)
                    .font(.system(size: 11))
                    .foregroundColor(isNamed ? SwiftUI.Color.white : SwiftUI.Color.gray)
                    // A row carried only to reach a descendant is SCAFFOLDING,
                    // not content. The convention layers.yaml has declared
                    // since April and no port has ever run:
                    // `opacity: if node.search_ancestor_only then 0.5 else 1.0`.
                    .opacity(row.ancestorOnly ? 0.5 : 1.0)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // WITHOUT THIS the tap target is the glyphs alone: a Text
                    // stretched by `.frame(maxWidth: .infinity)` does not accept
                    // taps across the space it occupies, so double-clicking a
                    // short name -- or anywhere right of it -- did nothing.
                    // renderColorSwatch in this same file has carried
                    // `.contentShape(Rectangle())` for its double-tap all along;
                    // the tree row never got it.
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        // Double-click renames ANY row. `elementDisplayName`
                        // has always SHOWN every element's name, so gating the
                        // edit to Layers meant this port displayed a name it
                        // refused to let you change.
                        editingName = elem.name ?? ""
                        renamingPath = path
                    }
            }
            // Select square
            Rectangle()
                .fill(isSelected ? SwiftUI.Color.blue : SwiftUI.Color.clear)
                .overlay(Rectangle().stroke(SwiftUI.Color.gray, lineWidth: 1))
                .frame(width: 12, height: 12)
                .onTapGesture {
                    // Selection-only row-select: non-undoable (OP_LOG.md §7/§8).
                    // Copy-with-selection so the row click carries the FULL
                    // document forward (symbols / documentSetup /
                    // printPreferences included) rather than defaulting away
                    // the fields the designated initializer does not name — the
                    // class of drop the `.selection` intent teeth catch.
                    model.setDocumentUnbracketed(
                        model.document.replacing(
                            selection: [ElementSelection.all(path)]),
                        intent: .selection)
                }
        }
        .frame(height: 24)
        .padding(.horizontal, 4)
        .background(isPanelSelected ? SwiftUI.Color.blue.opacity(0.3) : SwiftUI.Color.clear)
        .overlay(
            dragTarget == path && dragSource != nil && dragSource != path
                ? Rectangle().fill(SwiftUI.Color.blue).frame(height: 2)
                    .frame(maxHeight: .infinity, alignment: .top)
                : nil
        )
        .contentShape(Rectangle())
        .onTapGesture {
            handleRowTap(path: path)
        }
        .contextMenu {
            if case .layer = elem {
                Button("Options for Layer...") { showLayerOptionsFor = path }
            } else {
                Button("Options for Layer...") {}.disabled(true)
            }
            Button("Duplicate") { duplicateSelection() }
            Button("Delete Selection") { deleteSelection() }
            Divider()
            if isolationStack.isEmpty {
                Button("Enter Isolation Mode") { isolationStack.append(path) }
                    .disabled(!row.isContainer)
            } else {
                Button("Exit Isolation Mode") { isolationStack.removeLast() }
            }
            Divider()
            Button("Flatten Artwork") { flattenArtwork() }
            Button("Collect in New Layer") { collectInNewLayer() }
        }
        .onDrag {
            dragSource = path
            return NSItemProvider(object: pathToString(path) as NSString)
        }
        .onDrop(of: ["public.text"], isTargeted: Binding(
            get: { dragTarget == path },
            set: { isOver in
                if isOver && dragSource != nil && dragSource != path {
                    dragTarget = path
                    // Auto-expand collapsed containers after 500ms hover
                    let isCont = row.isContainer
                    let isColl = row.isCollapsed
                    if isCont && isColl {
                        let p = path
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let still = (dragTarget == p) && (dragSource != nil)
                            if still {
                                collapsed.remove(p)
                            }
                        }
                    }
                } else if !isOver && dragTarget == path {
                    dragTarget = nil
                }
            }
        )) { _ in
            return performDrop(onto: path)
        }
    }

    // MARK: - Context menu actions

    private func deleteSelection() {
        guard !panelSelection.isEmpty else { return }
        let topDeletes = panelSelection.filter { $0.count == 1 }.count
        if topDeletes >= model.document.layers.count { return }
        // Reference-aware delete (warn-then-orphan): if deleting these tree
        // rows would leave live instances pointing at a now-gone target,
        // confirm first. Empty orphan set -> delete as today (no dialog).
        let paths = panelSelection.map { Array($0) }
        let orphaned = DependencyIndex.orphanedReferences(model.document, paths)
        if !orphaned.isEmpty && !JasCommands.confirmOrphaningDelete(orphaned.count) {
            return
        }
        LayersPanel.dispatchYamlAction(
            "delete_layer_selection",
            model: model,
            panelSelection: paths
        )
        panelSelection.removeAll()
    }

    private func duplicateSelection() {
        guard !panelSelection.isEmpty else { return }
        LayersPanel.dispatchYamlAction(
            "duplicate_layer_selection",
            model: model,
            panelSelection: panelSelection.map { Array($0) }
        )
    }

    private func flattenArtwork() {
        guard !panelSelection.isEmpty else { return }
        // OP_LOG.md §9 Phase P5 — route through the `flatten_artwork` YAML action
        // (a foreach of `doc.unpack_group_at` over reverse(selection)) so the
        // gesture JOURNALS one `unpack_group_at` op per group through the SHARED
        // `opApply` dispatcher (one named undo step). Behavior is unchanged: the
        // action's reverse-order unpack matches the prior native loop, and the
        // shared `apply_unpack_group_at` body re-inserts children in place.
        LayersPanel.dispatchYamlAction(
            "flatten_artwork",
            model: model,
            panelSelection: panelSelection.map { Array($0) }
        )
        panelSelection.removeAll()
    }

    private func collectInNewLayer() {
        guard !panelSelection.isEmpty else { return }
        LayersPanel.dispatchYamlAction(
            "collect_in_new_layer",
            model: model,
            panelSelection: panelSelection.map { Array($0) }
        )
        panelSelection.removeAll()
    }

    @available(*, deprecated, message: "unused, kept as stub")
    @ViewBuilder
    private func treeRows_DEPRECATED() -> some View {
        EmptyView()
    }

    /* OLD BODY REMOVED:
    private func treeRows_OLD(elem: Element, path: ElementPath, depth: Int, layerColor: String, selectedPaths: Set<ElementPath>) -> some View {
        let isSelected = selectedPaths.contains(path)
        let isPanelSelected = panelSelection.contains(path)
        let (name, isNamed) = elementDisplayName(elem)
        let vis = elem.visibility
        let locked = elem.isLocked

        HStack(spacing: 2) {
            // Indent
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth * 16))
            }
            // Eye
            SwiftUI.Text(visIcon(vis))
                .frame(width: 16, height: 16)
                .onTapGesture {
                    let e = model.document.getElement(path)
                    let newE = e.withVisibility(cycleVisibility(e.visibility))
                    // Undoable: editDocument self-brackets one undo step.
                    model.editDocument(model.document.replaceElement(path, with: newE))
                }
            // Lock
            SwiftUI.Text(locked ? "\u{1F512}" : "\u{1F513}")
                .frame(width: 16, height: 16)
                .onTapGesture {
                    let e = model.document.getElement(path)
                    let newE = e.withLocked(!e.isLocked)
                    // Undoable: editDocument self-brackets one undo step.
                    model.editDocument(model.document.replaceElement(path, with: newE))
                }
            // Twirl or gap
            if isContainer(elem) {
                let isCollapsed = collapsed.contains(path)
                SwiftUI.Text(isCollapsed ? "\u{25B6}" : "\u{25BC}")
                    .frame(width: 16, height: 16)
                    .onTapGesture {
                        if collapsed.contains(path) {
                            collapsed.remove(path)
                        } else {
                            collapsed.insert(path)
                        }
                    }
            } else {
                Spacer().frame(width: 16)
            }
            // Preview — fitted-viewBox SVG thumbnail of the element
            ElementThumbnail(elem: elem, size: 24)
            // Name — inline TextField when renaming, Text otherwise
            if renamingPath == path {
                TextField("", text: $editingName, onCommit: {
                    // ANY element kind, not just Layer (council O4, 2026-07-30).
                    // `Element.withName` is clone-then-mutate for every case and
                    // normalizes the empty string to nil, matching jas_dioxus's
                    // `elem.common_mut().name = if empty { None } else { Some }`.
                    // A rename speaks to the NAME and preserves the rest — the
                    // rebuild this pattern replaced named 6 of Layer's 11 stored
                    // fields and destroyed id, blend mode, mask and both opacity
                    // flags on every rename.
                    let e = model.document.getElement(path)
                    // Undoable rename: editDocument self-brackets one step.
                    model.editDocument(
                        model.document.replaceElement(path, with: e.withName(editingName)))
                    renamingPath = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($renameFieldFocused)
                .onAppear { renameFieldFocused = true }
                .onExitCommand {
                    renamingPath = nil
                }
            } else {
                SwiftUI.Text(name)
                    .font(.system(size: 11))
                    .foregroundColor(isNamed ? SwiftUI.Color.white : SwiftUI.Color.gray)
                    // A row carried only to reach a descendant is SCAFFOLDING,
                    // not content. The convention layers.yaml has declared
                    // since April and no port has ever run:
                    // `opacity: if node.search_ancestor_only then 0.5 else 1.0`.
                    .opacity(row.ancestorOnly ? 0.5 : 1.0)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // WITHOUT THIS the tap target is the glyphs alone: a Text
                    // stretched by `.frame(maxWidth: .infinity)` does not accept
                    // taps across the space it occupies, so double-clicking a
                    // short name -- or anywhere right of it -- did nothing.
                    // renderColorSwatch in this same file has carried
                    // `.contentShape(Rectangle())` for its double-tap all along;
                    // the tree row never got it.
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        // Double-click renames ANY row. `elementDisplayName`
                        // has always SHOWN every element's name, so gating the
                        // edit to Layers meant this port displayed a name it
                        // refused to let you change.
                        editingName = elem.name ?? ""
                        renamingPath = path
                    }
            }
            // Select square
            Rectangle()
                .fill(isSelected ? SwiftUI.Color.blue : SwiftUI.Color.clear)
                .overlay(Rectangle().stroke(SwiftUI.Color.gray, lineWidth: 1))
                .frame(width: 12, height: 12)
                .onTapGesture {
                    // Selection-only row-select: non-undoable (OP_LOG.md §7/§8).
                    // Copy-with-selection so the row click carries the FULL
                    // document forward (symbols / documentSetup /
                    // printPreferences included) rather than defaulting away
                    // the fields the designated initializer does not name — the
                    // class of drop the `.selection` intent teeth catch.
                    model.setDocumentUnbracketed(
                        model.document.replacing(
                            selection: [ElementSelection.all(path)]),
                        intent: .selection)
                }
        }
        .frame(height: 24)
        .padding(.horizontal, 4)
        .background(isPanelSelected ? SwiftUI.Color.blue.opacity(0.3) : SwiftUI.Color.clear)
        .overlay(
            dragTarget == path && dragSource != nil && dragSource != path
                ? Rectangle().fill(SwiftUI.Color.blue).frame(height: 2)
                    .frame(maxHeight: .infinity, alignment: .top)
                : nil
        )
        .contentShape(Rectangle())
        .onTapGesture {
            panelSelection = [path]
        }
        .onDrag {
            dragSource = path
            return NSItemProvider(object: pathToString(path) as NSString)
        }
        .onDrop(of: ["public.text"], isTargeted: Binding(
            get: { dragTarget == path },
            set: { isOver in
                if isOver && dragSource != nil && dragSource != path {
                    dragTarget = path
                } else if !isOver && dragTarget == path {
                    dragTarget = nil
                }
            }
        )) { providers in
            guard let src = dragSource, src != path else {
                dragSource = nil; dragTarget = nil
                return false
            }
            let moved = model.document.getElement(src)
            var doc = model.document.deleteElement(src)
            // Adjust target if src was at same level and before
            var target = path
            if src.count == target.count, Array(src.dropLast()) == Array(target.dropLast()),
               let sl = src.last, let tl = target.last, sl < tl {
                target[target.count - 1] = tl - 1
            }
            // Insert before target: use insertElementAfter at target-1 or prepend
            if let tl = target.last, tl > 0 {
                var insertAfter = target
                insertAfter[insertAfter.count - 1] = tl - 1
                doc = doc.insertElementAfter(insertAfter, element: moved)
            } else {
                doc = doc.insertElementAfter(target, element: moved)
            }
            // Undoable reorder: editDocument self-brackets one undo step.
            model.editDocument(doc)
            dragSource = nil; dragTarget = nil
            return true
        }

        // Children (reversed) — skip if collapsed
        if !collapsed.contains(path), let children = elementChildren(elem) {
            ForEach(Array(children.indices.reversed()), id: \.self) { ci in
                let child = children[ci]
                let childPath = path + [ci]
                treeRows(elem: child, path: childPath, depth: depth + 1, layerColor: layerColor, selectedPaths: selectedPaths)
            }
        }
    }
    */
}

/// Top-level view that renders a panel's YAML content.
struct YamlPanelBodyView: View {
    let contentSpec: [String: Any]
    let context: [String: Any]
    var model: Model?
    /// ID of the panel whose scope is active in `context["panel"]`.
    /// Widget write-backs inside this body route to
    /// `model.stateStore.setPanel(panelId, ...)`.
    var panelId: String?
    /// Active theme — passed down to ``icon_button`` so it can tint
    /// `currentColor` SVG fills/strokes via ``WorkspaceIcon``.
    var theme: Theme? = nil
    /// Flyout-scoped icon default (28) forwarded to the body's
    /// ``YamlElementView``. Nil for panels (they keep the 20pt default);
    /// the non-modal tool-alternates flyout sets it. See
    /// ``YamlElementView/flyoutIconDefault``.
    var flyoutIconDefault: CGFloat? = nil
    /// Dialog overlays supply this so dialog-bound widgets can write
    /// back to the SwiftUI dialog state. Panels leave it nil.
    var onDialogWrite: ((String, Any?) -> Void)? = nil
    /// Forwarded to ``YamlElementView/onStoreDialogOpened`` — fires
    /// after a widget effect transitions the store's dialog id, so
    /// DockPanelView can copy the new dialog state into its SwiftUI
    /// overlay binding (mirrors `dispatchWithDialogBridge` for the
    /// menu path). The optional ``CGPoint`` carries a popover anchor
    /// (only the toolbar long-press path supplies one; panels pass nil).
    var onStoreDialogOpened: ((CGPoint?) -> Void)? = nil
    /// Forwarded close-side bridge — fires when a widget click chain
    /// closes the store's dialog (e.g. color picker OK / Cancel).
    var onStoreDialogClosed: (() -> Void)? = nil

    // MARK: - Path B (shared canonical layout) preview

    /// Whether to render panels from the shared Path B layout pass
    /// (absolute rects) instead of SwiftUI flex. Opt-in via JAS_PATH_B=1 —
    /// the human-viewable reference of the cross-app byte-gated layout pass
    /// (PATH_B_DESIGN.md §5 Phase 2). Mirrors the Rust / Flask flag.
    private func pathBEnabled() -> Bool {
        // Default-ON after the five-app sign-off; opt OUT with JAS_PATH_B=0.
        ProcessInfo.processInfo.environment["JAS_PATH_B"] != "0"
    }

    /// Panels whose composite / data-driven widgets (foreach expansions,
    /// tree rows) the v1 absolute pass cannot size yet, so they stay on the
    /// normal flex path. Matches the Rust / Flask unsupported set.
    private static let pathBExcluded: Set<String> = [
        "color_panel_content", "gradient_panel_content", "layers_panel_content",
        "swatches_panel_content", "brushes_panel_content",
    ]

    /// A leaf widget placed at its absolute rect by the Path B pass, carrying
    /// the per-leaf eval scope (`foreach`-expanded rows carry their per-row
    /// child scope) so it renders with the right data.
    private struct PathBLeaf: Identifiable {
        let id: Int
        let node: [String: Any]
        let ctx: [String: Any]
        let x: Int
        let y: Int
        let w: Int
        let h: Int
    }

    /// The full Path B layout for this panel: the chrome boxes (layout-only
    /// containers carrying a border/background, drawn behind), the placed
    /// leaves, and the computed panel height. Containers without chrome
    /// contribute layout only.
    private struct PathBLayout {
        let chrome: [PathBLeaf]
        let leaves: [PathBLeaf]
        let panelH: Int
    }

    /// Run the shared layout pass and project it into placeable leaves via
    /// ``PanelLayout/renderPlan``. The plan returns, for each renderable widget,
    /// the node + the (child) scope to render it with, so `foreach`-expanded
    /// rows — whose nodes come from the `do` template, not `children` — resolve
    /// correctly (the old `node_at_path` over `children` could not reach them).
    /// Mirrors Rust `render_panel_absolute` / Flask `_render_panel_absolute`.
    private func pathBLayout() -> PathBLayout {
        // Preview: pass the live eval scope `context` so foreach lists + text
        // bindings resolve to real data. availH=0 keeps the panel content-height.
        //
        // renderPlan expects a PANEL node and reads its `content`. In the dock,
        // `contentSpec` is already the content root (no `content` key), so wrap
        // it — otherwise renderPlan sees nil content and returns nothing (the
        // panel renders empty / looks collapsed). The cross-language gate feeds a
        // full panel node, which is why it stayed green and missed this.
        let panelNode: [String: Any] = contentSpec["content"] != nil
            ? contentSpec : ["content": contentSpec]
        let plan = PanelLayout.renderPlan(panelNode, availW: 228, availH: 0, ctx: context)
        let chrome = plan.chrome.enumerated().map { (idx, leaf) in
            PathBLeaf(id: idx, node: leaf.node, ctx: leaf.ctx,
                      x: leaf.x, y: leaf.y, w: leaf.w, h: leaf.h)
        }
        let leaves = plan.leaves.enumerated().map { (idx, leaf) in
            PathBLeaf(id: idx, node: leaf.node, ctx: leaf.ctx,
                      x: leaf.x, y: leaf.y, w: leaf.w, h: leaf.h)
        }
        return PathBLayout(chrome: chrome, leaves: leaves, panelH: plan.height)
    }

    /// Strip a chrome node's content keys (`children` / `do` / `foreach`) so the
    /// existing single-node renderer produces just the container's own
    /// border/background, not its content. Mirrors Python
    /// `_render_panel_absolute`'s chrome-node dict comprehension.
    private func strippedChromeNode(_ node: [String: Any]) -> [String: Any] {
        var cn = node
        cn.removeValue(forKey: "children")
        cn.removeValue(forKey: "do")
        cn.removeValue(forKey: "foreach")
        return cn
    }

    var body: some View {
        if pathBEnabled(), let pid = panelId, !Self.pathBExcluded.contains(pid) {
            let layout = pathBLayout()
            ZStack(alignment: .topLeading) {
                // Chrome boxes first (behind): a layout container's
                // border/background (incl. bind.background selection
                // highlights). The node is rendered with its content keys
                // stripped so the existing renderer resolves just its chrome.
                ForEach(layout.chrome) { box in
                    YamlElementView(
                        element: strippedChromeNode(box.node), context: box.ctx,
                        model: model, panelId: panelId, theme: theme,
                        flyoutIconDefault: flyoutIconDefault,
                        onDialogWrite: onDialogWrite,
                        onStoreDialogOpened: onStoreDialogOpened,
                        onStoreDialogClosed: onStoreDialogClosed
                    )
                    .frame(width: CGFloat(box.w), height: CGFloat(box.h), alignment: .topLeading)
                    .offset(x: CGFloat(box.x), y: CGFloat(box.y))
                }
                ForEach(layout.leaves) { leaf in
                    YamlElementView(
                        element: leaf.node, context: leaf.ctx, model: model,
                        panelId: panelId, theme: theme,
                        flyoutIconDefault: flyoutIconDefault,
                        onDialogWrite: onDialogWrite,
                        onStoreDialogOpened: onStoreDialogOpened,
                        onStoreDialogClosed: onStoreDialogClosed
                    )
                    .frame(width: CGFloat(leaf.w), height: CGFloat(leaf.h), alignment: .topLeading)
                    .offset(x: CGFloat(leaf.x), y: CGFloat(leaf.y))
                }
            }
            .frame(width: 228, height: CGFloat(layout.panelH), alignment: .topLeading)
            // Default foreground = theme.text, cascaded to all leaves. The flat
            // Path B ZStack has no ancestor container to inherit it from (unlike
            // the normal nested render), so widgets that rely on the inherited
            // color — selects / inputs / labels in Character & Paragraph — would
            // otherwise fall back to SwiftUI's dark default (dark-on-dark).
            // Mirrors the Rust render swap's color:var(--jas-text) on its
            // container. Widgets that set their own color still override this.
            .foregroundColor(theme.map { SwiftUI.Color(nsColor: $0.text) })
        } else {
            YamlElementView(
                element: contentSpec, context: context, model: model,
                panelId: panelId, theme: theme,
                flyoutIconDefault: flyoutIconDefault,
                onDialogWrite: onDialogWrite,
                onStoreDialogOpened: onStoreDialogOpened,
                onStoreDialogClosed: onStoreDialogClosed
            )
            .padding(4)
        }
    }
}

/// Disambiguate single-click from double-click without losing the
/// double-click when the single-click handler causes a re-render.
///
/// SwiftUI's `TapGesture(count:2).exclusively(before: TapGesture(count:1))`
/// works in isolation but breaks down when the count:1 callback
/// mutates state that triggers a panel re-render mid-gesture: the
/// new view tree's tap counter starts fresh and the second click of
/// the user's double-click is treated as a new single-tap. By
/// deferring the count:1 work via a `DispatchWorkItem` stored in
/// `@State`, the pending item survives the re-render and a count:2
/// callback can still cancel it. The result is a small (250 ms)
/// delay on every single-click, but a reliable double-click.
struct ClickDisambiguator: ViewModifier {
    let onSingle: () -> Void
    let onDouble: () -> Void
    @State private var pendingSingle: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .gesture(
                TapGesture(count: 2)
                    .onEnded {
                        pendingSingle?.cancel()
                        pendingSingle = nil
                        onDouble()
                    }
                    .exclusively(before:
                        TapGesture(count: 1)
                            .onEnded {
                                pendingSingle?.cancel()
                                let item = DispatchWorkItem { onSingle() }
                                pendingSingle = item
                                DispatchQueue.main.asyncAfter(
                                    deadline: .now() + 0.25, execute: item
                                )
                            }
                    )
            )
    }
}

/// Custom collapsible section used by ``YamlElementView/renderDisclosure``.
/// Built from scratch because SwiftUI's `DisclosureGroup` chevron stays
/// system-tinted on macOS regardless of `.tint(...)` / `.foregroundColor`,
/// which leaves it dark on dark themes. Rolling our own gives the
/// chevron the same theme.text color as the label.
struct DisclosureSection<Content: View>: View {
    let label: String
    let labelColor: SwiftUI.Color
    let initialCollapsed: Bool
    let onToggle: (Bool) -> Void
    @ViewBuilder let content: () -> Content
    @State private var collapsed: Bool

    init(label: String, labelColor: SwiftUI.Color,
         initialCollapsed: Bool, onToggle: @escaping (Bool) -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.labelColor = labelColor
        self.initialCollapsed = initialCollapsed
        self.onToggle = onToggle
        self.content = content
        _collapsed = State(initialValue: initialCollapsed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                let next = !collapsed
                collapsed = next
                onToggle(next)
            }) {
                HStack(spacing: 6) {
                    SwiftUI.Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(labelColor)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    SwiftUI.Text(label)
                        .foregroundColor(labelColor)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !collapsed {
                content()
            }
        }
    }
}

// MARK: - Icon-select popover button

/// One option entry shown in the IconSelectButton popover.
struct IconSelectOption: Identifiable {
    let id = UUID()
    let value: String
    let glyph: String
    let label: String
}

/// Custom popover-driven dropdown used by `icon_select` widgets in
/// the Paragraph panel (Bullets / Numbered List). SwiftUI's `Menu`
/// label rendering on macOS strips Canvas-based custom views like
/// WorkspaceIcon — the icon collapses to a tiny indicator. This
/// view explicitly draws the icon as the Button face and shows the
/// option list in a popover the user dismisses by selecting an entry
/// or clicking outside.
struct IconSelectButton: View {
    let iconName: String
    let visibleGlyph: String
    let options: [IconSelectOption]
    let width: CGFloat
    let height: CGFloat
    let theme: Theme?
    let summary: String
    let isDisabled: Bool
    let onPick: (String) -> Void
    @State private var isOpen: Bool = false

    var body: some View {
        Button(action: { isOpen.toggle() }) {
            HStack(spacing: 3) {
                if let theme = theme,
                   !iconName.isEmpty,
                   WorkspaceIconCache.shared.lookup(iconName) != nil
                {
                    WorkspaceIcon(name: iconName, size: min(width - 12, height - 4),
                                  tint: theme.text)
                } else {
                    SwiftUI.Text(visibleGlyph)
                        .font(.system(size: max(14, height - 8)))
                        .foregroundColor(theme.map { SwiftUI.Color(nsColor: $0.text) }
                                         ?? .primary)
                }
                SwiftUI.Text("\u{25BE}")
                    .font(.system(size: 9))
                    .opacity(0.65)
                    .foregroundColor(theme.map { SwiftUI.Color(nsColor: $0.text) }
                                     ?? .primary)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(summary)
        .disabled(isDisabled)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(options) { opt in
                    Button(action: {
                        onPick(opt.value)
                        isOpen = false
                    }) {
                        HStack {
                            SwiftUI.Text(opt.glyph.isEmpty ? "—" : opt.glyph)
                                .frame(width: 24, alignment: .center)
                            SwiftUI.Text(opt.label)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
