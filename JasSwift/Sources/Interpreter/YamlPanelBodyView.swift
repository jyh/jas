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

    var body: some View {
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
                    // Augment the dialog-init context with the live
                    // selection's fill / stroke (uniform summary →
                    // tab default → app default) so the YAML init
                    // expression `if param.target == "fill" then
                    // state.fill_color else state.stroke_color` reads
                    // the actual canvas color the user is editing.
                    // Without this, state.X resolves to the workspace
                    // YAML default and the picker opens on white.
                    func liveHex(_ isFill: Bool) -> String? {
                        let resolved: Color? = {
                            if isFill {
                                switch selectionFillSummary(m.document) {
                                case .uniform(let f?): return f.color
                                case .uniform(nil): return nil
                                default: return m.defaultFill?.color
                                }
                            } else {
                                switch selectionStrokeSummary(m.document) {
                                case .uniform(let s?): return s.color
                                case .uniform(nil): return nil
                                default: return m.defaultStroke?.color
                                }
                            }
                        }()
                        return resolved.map { "#" + $0.toHex() }
                    }
                    var ctxAug = context
                    var stateMap = (ctxAug["state"] as? [String: Any]) ?? [:]
                    if let h = liveHex(true) { stateMap["fill_color"] = h }
                    if let h = liveHex(false) { stateMap["stroke_color"] = h }
                    ctxAug["state"] = stateMap
                    dispatchYamlAction(
                        "open_color_picker",
                        params: ["target": forFill ? "fill" : "stroke"],
                        actions: actions, ctx: ctxAug,
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
            case "tabs":
                renderTabs()
            case "icon":
                renderIcon()
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
    /// For panels whose visible state is driven by selection overrides
    /// (Character panel), sync the overrides into the store *first* so
    /// that the apply-to-selection pipeline sees the complete shown
    /// state. Without this the user's single-field edit would push
    /// stale stored defaults for every *other* attr back onto the
    /// selected element, undoing attrs they hadn't touched.
    private func commitPanelWrite(key: String, value: Any?) {
        guard let model = model, let pid = panelId else { return }
        if pid == "character_panel_content",
           let overrides = characterPanelLiveOverrides(model: model) {
            for (k, v) in overrides { model.stateStore.setPanel(pid, k, v) }
            // Auto-leading tracks font size unless explicitly
            // overridden. When the user edits font_size and the
            // selected element's line_height is empty (Auto), bump
            // panel.leading to newSize * 1.2 so the apply pipeline
            // still derives line_height = "" and Auto is preserved.
            // Without this, characterPanelLiveOverrides materialises
            // Auto into oldSize * 1.2; the apply then sees a stale
            // numeric leading and writes it as an explicit override.
            if key == "font_size",
               characterElementHasAutoLeading(model: model),
               let n = (value as? NSNumber)?.doubleValue {
                model.stateStore.setPanel(pid, "leading", n * 1.2)
            }
        }
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
        notifyPanelStateChanged(pid, store: model.stateStore, model: model)
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
            commitPanelWrite(key: target.key, value: value)
            // Color panel terminal commits push to the recent-colors
            // strip. notifyPanelStateChanged already updated the
            // active color via setActiveColorLive (no recent push);
            // here we re-fire setActiveColor with the post-commit
            // panel state so the entry lands in recent. Both the hex
            // text input and the H / S / B / R / G / B / C / M / Y / K
            // numeric inputs commit on Enter / blur via this path.
            if panelId == "color_panel_content", let model = model {
                // Hex commit: parse the typed hex directly so the
                // committed color reflects what the user typed
                // (colorFromPanelState reads h/s/b/r/g/bl per the
                // mode — those are stale after a hex edit since the
                // hex commit doesn't ripple back to the other
                // channels). In Web Safe RGB mode, snap each
                // channel to the nearest multiple of 51 first
                // (0/51/102/153/204/255).
                if target.key == "hex" {
                    if let hexStr = value as? String,
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
                            color = Color.rgb(
                                r: snap(r), g: snap(g), b: snap(b), a: 1.0)
                        }
                        ColorPanel.setActiveColor(color, model: model)
                    }
                } else {
                    let colorChannelKeys: Set<String> = [
                        "h", "s", "b", "r", "g", "bl",
                        "c", "m", "y", "k",
                    ]
                    if colorChannelKeys.contains(target.key),
                       let color = ColorPanel.colorFromPanelState(
                            store: model.stateStore)
                    {
                        ColorPanel.setActiveColor(color, model: model)
                    }
                }
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
        if style["border"] != nil {
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
        if let c = resolvedColor {
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
                .disabled(isDisabled)
                .modifier(PressDispatchModifier(
                    onPress: { loc in if hasPress { handleBehaviorClick(eventName: "mouse_down", pressLocation: loc) } },
                    onRelease: { if hasPress { handleBehaviorClick(eventName: "mouse_up") } }
                ))
                .modifier(ToolOptionsDblClickModifier(
                    enabled: wantsToolOptionsDblClick, onDoubleClick: toolOptionsAction))
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
            let ctrl = Controller(model: model)
            if model.fillOnTop {
                model.defaultFill = nil
                if !model.document.selection.isEmpty {
                    // One undo step: withTxn opens the bracket, setSelectionFill
                    // (editDocument) joins it.
                    model.withTxn { ctrl.setSelectionFill(nil) }
                }
            } else {
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
        ctxWithParams["param"] = params
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

    /// Apply a slider write to the panel state and, when this is a
    /// Color panel slider (panel.h / .s / .b / .r / .g / .bl /
    /// .c / .m / .y / .k / .hex), recompute the active color and
    /// either set it live (drag) or commit it (release).
    private func handleSliderWrite(
        target: WriteTarget?, value: Double,
        panelId: String?, model: Model?, commit: Bool
    ) {
        guard let target = target, let model = model else { return }
        switch target.scope {
        case .panel:
            // For color panel sliders: the panel store may hold stale
            // h/s/b/r/g/bl/c/m/y/k from before the live override
            // refreshed the eval ctx. Seed all the OTHER channels
            // from the active color first so the new color computed
            // from panel state mixes the dragged channel with the
            // current (live) sibling values, instead of the YAML
            // default zeros.
            if panelId == "color_panel_content",
               let active = activeColor(model: model)
            {
                let modeStr = (model.stateStore.getPanel(
                    "color_panel_content", "mode") as? String) ?? "hsb"
                let mode: ColorPanelMode = {
                    switch modeStr {
                    case "grayscale": return .grayscale
                    case "rgb": return .rgb
                    case "cmyk": return .cmyk
                    case "web_safe_rgb": return .webSafeRgb
                    default: return .hsb
                    }
                }()
                ColorPanel.seedSliders(from: active, mode: mode,
                                       store: model.stateStore)
            }
            // commitPanelWrite stores the value, bumps
            // panelStateVersion (so SwiftUI re-renders bound
            // widgets like the matching number_input next to the
            // slider), and fires the notify hook. Skipping it left
            // the slider's value invisible to its sibling input.
            commitPanelWrite(key: target.key, value: value)
            if panelId == "color_panel_content" {
                applyColorPanelStateToActiveColor(model: model, commit: commit)
            }
        case .dialog:
            onDialogWrite?(target.key, value)
        }
    }

    private func activeColor(model: Model) -> Color? {
        if model.fillOnTop {
            switch selectionFillSummary(model.document) {
            case .uniform(let f?): return f.color
            case .uniform(nil): return nil
            default: return model.defaultFill?.color
            }
        } else {
            switch selectionStrokeSummary(model.document) {
            case .uniform(let s?): return s.color
            case .uniform(nil): return nil
            default: return model.defaultStroke?.color
            }
        }
    }

    /// Read the Color panel's current mode + slider state, derive
    /// the corresponding RGB color, and push it through ColorPanel
    /// (live during drag, commit on release).
    private func applyColorPanelStateToActiveColor(
        model: Model, commit: Bool
    ) {
        let panelState = model.stateStore.getPanelState("color_panel_content")
        let mode = (panelState["mode"] as? String) ?? "hsb"
        func num(_ key: String) -> Double {
            (panelState[key] as? Double)
                ?? (panelState[key] as? Int).map { Double($0) }
                ?? 0
        }
        // Color enum stores components in [0, 1] for s/b/r/g/b/c/m/y/k
        // and hue in [0, 360). The YAML sliders run 0..100 (or 0..255
        // for r/g/b), so divide before constructing.
        let color: Color = {
            switch mode {
            case "grayscale":
                let k = num("k") / 100.0
                return Color.rgb(r: 1.0 - k, g: 1.0 - k, b: 1.0 - k, a: 1.0)
            case "rgb", "web_safe_rgb":
                return Color.rgb(
                    r: num("r") / 255.0,
                    g: num("g") / 255.0,
                    b: num("bl") / 255.0,
                    a: 1.0
                )
            case "cmyk":
                let c = num("c") / 100.0, mk = num("m") / 100.0
                let y = num("y") / 100.0, k = num("k") / 100.0
                let r = (1.0 - c) * (1.0 - k)
                let g = (1.0 - mk) * (1.0 - k)
                let b = (1.0 - y) * (1.0 - k)
                return Color.rgb(r: r, g: g, b: b, a: 1.0)
            default:  // hsb
                return Color.hsb(
                    h: num("h"),
                    s: num("s") / 100.0,
                    b: num("b") / 100.0,
                    a: 1.0
                )
            }
        }()
        if commit {
            ColorPanel.setActiveColor(color, model: model)
        } else {
            ColorPanel.setActiveColorLive(color, model: model)
        }
    }

    // MARK: - Number Input

    @ViewBuilder
    private func renderNumberInput() -> some View {
        let minVal = element["min"] as? Int ?? 0
        // YAML may declare max numerically; clamp commits to it. Without
        // this, typing 500 into an R-channel field (max=255) committed
        // 500 verbatim — the resulting color went past 0xff and produced
        // a 7-character hex like "1f4ff3b" instead of clamping to 255.
        let maxVal: Int? = (element["max"] as? Int)
            ?? (element["max"] as? Double).map { Int($0) }
        // Bind may be a bare string ("dialog.h") or an object form
        // ({value: "panel.x"}). Color picker fields use the bare-string
        // form via the radio_field_row template; without the fallback
        // bind reads to nil, writeTarget stays nil, and commits silently
        // no-op (the field accepts typing but Enter resets to 0).
        let valueExpr: String? = (element["bind"] as? String)
            ?? (element["bind"] as? [String: Any])?["value"] as? String
        let currentValue: Int = {
            if let e = valueExpr {
                let result = evaluate(e, context: context)
                if case .number(let n) = result { return Int(n) }
            }
            return minVal
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
            externalValue: String(currentValue),
            commit: { newVal in
                guard let parsed = Int(newVal) else { return }
                var clamped = max(parsed, minVal)
                if let m = maxVal { clamped = min(clamped, m) }
                if let t = writeTarget { commitWidgetWrite(target: t, value: clamped) }
                // Fields bound to a non-writable expression (e.g. a foreach
                // `p.value` in the Concepts param editor) drive their effect via
                // a `behavior: [{event: change, …}]` block instead of a
                // write-back target. Dispatch it with the committed value as
                // `event.value`, mirroring the Dioxus widget framework.
                handleChangeBehavior(value: Double(clamped))
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

    @ViewBuilder
    private func renderColorSwatch() -> some View {
        let size = (element["style"] as? [String: Any])?["size"] as? CGFloat ?? 16
        let hollow = element["hollow"] as? Bool ?? false

        let color: NSColor = {
            if let bind = element["bind"] as? [String: Any],
               let colorExpr = bind["color"] as? String {
                let result = evaluate(colorExpr, context: context)
                switch result {
                case .color(let c), .string(let c):
                    let (r, g, b) = parseHex(c)
                    return NSColor(
                        red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                        blue: CGFloat(b) / 255, alpha: 1
                    )
                default:
                    return .clear
                }
            }
            return .clear
        }()

        let selected = isSelectedInList()
        // Honor click / double_click behavior blocks (Color panel's
        // Black/White/recent swatches use click; Swatches panel's
        // library swatches use both — click selects + sets active
        // color, double_click opens the Swatch Options dialog).
        // Without these gestures the swatch is a static rectangle.
        let behaviors = element["behavior"] as? [[String: Any]] ?? []
        let hasClick = behaviors.contains { ($0["event"] as? String) == "click" }
        let hasDouble = behaviors.contains { ($0["event"] as? String) == "double_click" }
        let swatch: AnyView = {
            if hollow {
                return AnyView(
                    Rectangle()
                        .stroke(SwiftUI.Color(nsColor: color), lineWidth: 3)
                        .frame(width: size, height: size)
                )
            } else {
                return AnyView(
                    Rectangle()
                        .fill(SwiftUI.Color(nsColor: color))
                        .frame(width: size, height: size)
                        .border(
                            selected ? SwiftUI.Color.accentColor : SwiftUI.Color.gray,
                            width: selected ? 2 : 1
                        )
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
        for entry in behavior where (entry["event"] as? String) == eventName {
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

    /// Evaluate `bind.selected_in` against the per-item identity read
    /// from the click behavior's first `select.target` (so authors don't
    /// repeat themselves) and return whether this item is currently
    /// selected. Mirrors the Rust implementation in renderer.rs.
    private func isSelectedInList() -> Bool {
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
            selectedInIdEquals(item.value, idAny)
        }
    }

    /// Loose typed equality used by `selected_in` lookup. Compares
    /// numeric / string / bool values from list members (which are
    /// stored as `Any`) against an evaluated identity value.
    private func selectedInIdEquals(_ a: Any?, _ b: Any?) -> Bool {
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
                let rad = angle * .pi / 180.0
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

        let selStop: Int = selStopExpr.map {
            if case .number(let n) = evaluate($0, context: context) { return Int(n) } else { return -1 }
        } ?? -1
        let selMid: Int = selMidExpr.map {
            if case .number(let n) = evaluate($0, context: context) { return Int(n) } else { return -1 }
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
                case .number(let n): return String(Int(n))
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
            // Leave a trailing gap so the dropdown doesn't crowd the
            // next col-2 icon to its right (matches renderNumberInput).
            picker.frame(maxWidth: .infinity).padding(.trailing, 24)
        } else {
            picker.fixedSize(horizontal: true, vertical: false)
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
    case .circle: return "Circle"
    case .ellipse: return "Ellipse"
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

private func elementDisplayName(_ elem: Element) -> (String, Bool) {
    if case .layer(let le) = elem, let n = le.name, !n.isEmpty {
        return (n, true)
    }
    return ("<\(elementTypeLabel(elem))>", false)
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
    switch vis {
    case .preview: return .outline
    case .outline: return .invisible
    case .invisible: return .preview
    }
}

/// Build a fitted-viewBox SVG fragment for a single element.
private func buildPreviewSvg(_ elem: Element) -> String {
    let b = elem.bounds
    let w = b.width, h = b.height
    if !w.isFinite || !h.isFinite || w <= 0 || h <= 0 {
        return ""
    }
    let pad = max(max(w, h) * 0.02, 0.5)
    let vb = "\(b.x - pad) \(b.y - pad) \(w + 2 * pad) \(h + 2 * pad)"
    let inner = elementSvg(elem, indent: "")
    return #"<svg xmlns="http://www.w3.org/2000/svg" viewBox=""# + vb + #"" preserveAspectRatio="xMidYMid meet">"# + inner + "</svg>"
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
}

struct TreeViewContent: View {
    @ObservedObject var model: Model
    @State private var collapsed: Set<ElementPath> = []
    @State private var panelSelection: Set<ElementPath> = []
    @State private var panelSelectionAnchor: ElementPath? = nil
    @State private var renamingPath: ElementPath? = nil
    @State private var editingName: String = ""
    @State private var dragSource: ElementPath? = nil
    @State private var dragTarget: ElementPath? = nil
    @State private var searchQuery: String = ""
    @State private var isolationStack: [ElementPath] = []
    @State private var soloState: (path: ElementPath, saved: [ElementPath: Visibility])? = nil
    @State private var savedLockStates: [ElementPath: [Bool]] = [:]
    @State private var hiddenTypes: Set<String> = []
    @State private var showLayerOptionsFor: ElementPath? = nil
    @State private var showFilterMenu: Bool = false
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

    private func typeValue(_ elem: Element) -> String {
        switch elem {
        case .line: return "line"
        case .rect: return "rectangle"
        case .circle: return "circle"
        case .ellipse: return "ellipse"
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
        if !hiddenTypes.isEmpty {
            let visible = Set(result.filter { !hiddenTypes.contains(typeValue($0.elem)) }.map { $0.path })
            var keep = visible
            for p in visible {
                for i in 1..<p.count { keep.insert(Array(p.prefix(i))) }
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
            let matching = Set(result.filter {
                let (n, _) = elementDisplayName($0.elem)
                return n.lowercased().contains(q)
            }.map { $0.path })
            var keep = matching
            for p in matching {
                for i in 1..<p.count { keep.insert(Array(p.prefix(i))) }
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
            // Search/filter bar
            HStack(spacing: 4) {
                TextField("Search...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 4)
                Menu {
                    let types: [(String, String)] = [
                        ("Layer", "layer"), ("Group", "group"),
                        ("Path", "path"), ("Rectangle", "rectangle"),
                        ("Circle", "circle"), ("Ellipse", "ellipse"),
                        ("Polyline", "polyline"), ("Polygon", "polygon"),
                        ("Text", "text"), ("Text Path", "text_path"),
                        ("Line", "line"),
                    ]
                    ForEach(types, id: \.1) { (label, value) in
                        Button(action: {
                            if hiddenTypes.contains(value) { hiddenTypes.remove(value) }
                            else { hiddenTypes.insert(value) }
                        }) {
                            if hiddenTypes.contains(value) {
                                SwiftUI.Text(label)
                            } else {
                                SwiftUI.Text("✓ \(label)")
                            }
                        }
                    }
                } label: {
                    SwiftUI.Text("▾").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(SwiftUI.Color(white: 0.14))

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
            let newVis = cycleVisibility(e.visibility)
            model.editDocument(model.document.replaceElement(path, with: e.withVisibility(newVis)))
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
        let isSelected = selectedPaths.contains(path)
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
                    let e = model.document.getElement(path)
                    let wasUnlocked = !e.isLocked
                    let isCont = isContainerElem(e)
                    var doc = model.document
                    // Save child states when locking a container
                    if isCont && wasUnlocked, let kids = elementChildrenStatic(e) {
                        savedLockStates[path] = kids.map { $0.isLocked }
                    }
                    doc = doc.replaceElement(path, with: e.withLocked(wasUnlocked))
                    // Lock all children when container locked
                    if isCont && wasUnlocked, let kids = elementChildrenStatic(e) {
                        for (i, c) in kids.enumerated() {
                            let cp = path + [i]
                            doc = doc.replaceElement(cp, with: c.withLocked(true))
                        }
                    }
                    // Restore children on unlock
                    if isCont && !wasUnlocked, let saved = savedLockStates.removeValue(forKey: path) {
                        let e2 = doc.getElement(path)
                        if let kids2 = elementChildrenStatic(e2) {
                            for (i, c) in kids2.enumerated() where i < saved.count {
                                let cp = path + [i]
                                doc = doc.replaceElement(cp, with: c.withLocked(saved[i]))
                            }
                        }
                    }
                    // Undoable lock toggle: editDocument self-brackets one step.
                    model.editDocument(doc)
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
                    let e = model.document.getElement(path)
                    if case .layer(let le) = e {
                        let newLayer = Layer(name: editingName, children: le.children,
                                             opacity: le.opacity, transform: le.transform,
                                             locked: le.locked, visibility: le.visibility)
                        // Undoable rename: editDocument self-brackets one step.
                        model.editDocument(model.document.replaceElement(path, with: .layer(newLayer)))
                    }
                    renamingPath = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .onExitCommand { renamingPath = nil }
            } else {
                SwiftUI.Text(name)
                    .font(.system(size: 11))
                    .foregroundColor(isNamed ? SwiftUI.Color.white : SwiftUI.Color.gray)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) {
                        if case .layer(let le) = elem {
                            editingName = le.name ?? ""
                            renamingPath = path
                        }
                    }
            }
            // Select square
            Rectangle()
                .fill(isSelected ? SwiftUI.Color.blue : SwiftUI.Color.clear)
                .overlay(Rectangle().stroke(SwiftUI.Color.gray, lineWidth: 1))
                .frame(width: 12, height: 12)
                .onTapGesture {
                    // Selection-only row-select: non-undoable (OP_LOG.md §7/§8).
                    model.setDocumentUnbracketed(Document(
                        layers: model.document.layers,
                        selectedLayer: model.document.selectedLayer,
                        selection: [ElementSelection.all(path)],
                        artboards: model.document.artboards,
                        artboardOptions: model.document.artboardOptions
                    ))
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
                    let e = model.document.getElement(path)
                    if case .layer(let le) = e {
                        let newLayer = Layer(name: editingName, children: le.children,
                                             opacity: le.opacity, transform: le.transform,
                                             locked: le.locked, visibility: le.visibility)
                        // Undoable rename: editDocument self-brackets one step.
                        model.editDocument(model.document.replaceElement(path, with: .layer(newLayer)))
                    }
                    renamingPath = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .onExitCommand {
                    renamingPath = nil
                }
            } else {
                SwiftUI.Text(name)
                    .font(.system(size: 11))
                    .foregroundColor(isNamed ? SwiftUI.Color.white : SwiftUI.Color.gray)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) {
                        if case .layer(let le) = elem {
                            editingName = le.name ?? ""
                            renamingPath = path
                        }
                    }
            }
            // Select square
            Rectangle()
                .fill(isSelected ? SwiftUI.Color.blue : SwiftUI.Color.clear)
                .overlay(Rectangle().stroke(SwiftUI.Color.gray, lineWidth: 1))
                .frame(width: 12, height: 12)
                .onTapGesture {
                    // Selection-only row-select: non-undoable (OP_LOG.md §7/§8).
                    model.setDocumentUnbracketed(Document(
                        layers: model.document.layers,
                        selectedLayer: model.document.selectedLayer,
                        selection: [ElementSelection.all(path)],
                        artboards: model.document.artboards,
                        artboardOptions: model.document.artboardOptions
                    ))
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
