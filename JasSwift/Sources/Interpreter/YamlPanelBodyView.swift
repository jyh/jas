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
    var onStoreDialogOpened: (() -> Void)? = nil

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
            FillStrokeWidget(
                model: model ?? Model(),
                onDoubleClick: { _ in }
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
            case "toggle", "checkbox":
                renderToggle()
            case "combo_box":
                renderComboBox()
            case "color_swatch":
                renderColorSwatch()
            case "color_bar":
                renderColorBar()
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
        if pid == "character_panel",
           let overrides = characterPanelLiveOverrides(model: model) {
            for (k, v) in overrides { model.stateStore.setPanel(pid, k, v) }
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
            // Color panel hex commit: TextField fires the binding
            // on Enter / blur (not live). Push the typed hex onto
            // the recent-colors strip — notifyPanelStateChanged
            // already updated the active color live, but recent
            // is committed only on this terminal write.
            if panelId == "color_panel_content", target.key == "hex",
               let model = model,
               let hexStr = value as? String,
               let color = ColorPanel.colorFromHex(hexStr)
            {
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
                    YamlElementView(element: template, context: childScope.toDict(), model: model, panelId: panelId, onWidgetAction: onWidgetAction, theme: theme, onDialogWrite: onDialogWrite, onStoreDialogOpened: onStoreDialogOpened)
                }
            }
        } else if layout == "row" {
            HStack(spacing: gap) {
                ForEach(0..<items.count, id: \.self) { i in
                    let childScope = scope.extend(itemBindings(varName, item: items[i], index: i))
                    YamlElementView(element: template, context: childScope.toDict(), model: model, panelId: panelId, onWidgetAction: onWidgetAction, theme: theme, onDialogWrite: onDialogWrite, onStoreDialogOpened: onStoreDialogOpened)
                }
            }
        } else {
            VStack(spacing: gap) {
                ForEach(0..<items.count, id: \.self) { i in
                    let childScope = scope.extend(itemBindings(varName, item: items[i], index: i))
                    YamlElementView(element: template, context: childScope.toDict(), model: model, panelId: panelId, onWidgetAction: onWidgetAction, theme: theme, onDialogWrite: onDialogWrite, onStoreDialogOpened: onStoreDialogOpened)
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
                    theme: theme, onDialogWrite: onDialogWrite,
                    onStoreDialogOpened: onStoreDialogOpened
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
                YamlElementView(element: children[i], context: context, model: model, panelId: panelId, onWidgetAction: onWidgetAction, theme: theme, onDialogWrite: onDialogWrite, onStoreDialogOpened: onStoreDialogOpened)
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
        } else {
            Button(summary) { handleWidgetClick() }
                .buttonStyle(.plain)
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isChecked ? checkedBg : .clear)
                )
                .disabled(isDisabled)
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

    /// Read ``style.size`` from the icon_button element (default 20pt).
    /// Mirrors Rust's ``icon_size_px`` — used so dialogs / panels with
    /// a small style.size declaration get a small icon rather than a
    /// stretched one.
    private func resolvedIconSize() -> CGFloat {
        if let style = element["style"] as? [String: Any], let raw = style["size"] {
            if let n = raw as? Double { return CGFloat(n) }
            if let n = raw as? Int { return CGFloat(n) }
            if let s = raw as? String,
               let n = Double(s.trimmingCharacters(in: CharacterSet(charactersIn: "px "))) {
                return CGFloat(n)
            }
        }
        return 20
    }

    /// Resolve the icon name from ``bind.icon`` (if present, as a
    /// yaml expression returning a string) or the static ``icon``
    /// field, falling back to ``""``.
    private func resolvedIconName() -> String {
        if let bind = element["bind"] as? [String: Any],
           let expr = bind["icon"] as? String {
            if case .string(let s) = evaluate(expr, context: context) {
                return s
            }
        }
        return element["icon"] as? String ?? ""
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
        for entry in behavior where (entry["event"] as? String) == "click" {
            // A click behavior may carry `effects:` (a list run
            // through runEffects), or `action:` (an action name in
            // the YAML actions catalog). The Color panel's None /
            // Black / White swatches use the latter — without
            // dispatching it here those clicks were silent.
            let effects = (entry["effects"] as? [Any]) ?? []
            if !effects.isEmpty {
                runEffects(effects, ctx: ctxWithEvent, store: model.stateStore,
                           actions: actions, platformEffects: platformEffects)
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
            if model.fillOnTop {
                model.defaultFill = nil
            } else {
                model.defaultStroke = nil
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
            onStoreDialogOpened?()
        }
    }

    // MARK: - Slider

    @ViewBuilder
    private func renderSlider() -> some View {
        let minVal = element["min"] as? Double ?? 0
        let maxVal = element["max"] as? Double ?? 100
        let bind = element["bind"] as? [String: Any]
        let valueExpr = bind?["value"] as? String

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
        let bind = element["bind"] as? [String: Any]
        let valueExpr = bind?["value"] as? String
        let currentValue: Int = {
            if let e = valueExpr {
                let result = evaluate(e, context: context)
                if case .number(let n) = result { return Int(n) }
            }
            return minVal
        }()
        let writeTarget = writeBackTarget(valueExpr)

        TextField("", value: Binding<Int>(
            get: { currentValue },
            set: { newVal in
                if let t = writeTarget { commitWidgetWrite(target: t, value: newVal) }
            }
        ), format: .number)
            .frame(width: 45)
            .textFieldStyle(.roundedBorder)
            // Override the inherited foregroundColor — dialogs cascade
            // theme.text (light) over the body so labels read on the
            // dark backdrop, but TextFields keep a white system
            // background and inherit that light text, leaving the
            // typed digits low-contrast and barely legible.
            .foregroundColor(.black)
    }

    // MARK: - Text Input

    @ViewBuilder
    private func renderTextInput() -> some View {
        let placeholder = element["placeholder"] as? String ?? ""
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

        TextField(placeholder, text: Binding<String>(
            get: { currentValue },
            set: { newVal in
                if let t = writeTarget { commitWidgetWrite(target: t, value: newVal) }
            }
        ))
            .textFieldStyle(.roundedBorder)
            // Same rationale as renderNumberInput: keep the typed text
            // dark against the system white text-field background.
            .foregroundColor(.black)
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
                        commitWidgetWrite(target: t, value: nil as Any?)
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
            // Match number/text inputs — dark text on the system
            // white field background.
            .foregroundColor(.black)
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
    private func handleBehaviorClick(eventName: String) {
        guard let model = model else { return }
        guard let behavior = element["behavior"] as? [[String: Any]] else { return }
        let ws = WorkspaceData.load()
        let actions = ws?.data["actions"] as? [String: Any]
        let platformEffects = alignPlatformEffects(model: model)
        var ctxWithEvent = context
        ctxWithEvent["event"] = currentEventModifiers()
        if let pid = panelId {
            model.stateStore.setActivePanel(pid)
        }
        for entry in behavior where (entry["event"] as? String) == eventName {
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
            YamlElementView(element: content, context: context, model: model, panelId: panelId, onWidgetAction: onWidgetAction, theme: theme, onDialogWrite: onDialogWrite, onStoreDialogOpened: onStoreDialogOpened)
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
        Picker("", selection: Binding<String>(
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
        // SwiftUI Picker defaults to filling available row width on
        // macOS; the YAML rows in print.yaml put a select inside a
        // grid column that's wider than the dropdown's content needs,
        // so without this the dropdown stretches to absorb the empty
        // space and the dialog reads as button-bloat. Take intrinsic
        // width horizontally so the dropdown sits left-aligned in its
        // column with content-sized chrome.
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Toggle / Checkbox

    @ViewBuilder
    private func renderToggle() -> some View {
        let label = element["label"] as? String ?? ""
        let bind = element["bind"] as? [String: Any]
        let checkedExpr = bind?["checked"] as? String
        let isChecked: Bool = {
            if let e = checkedExpr {
                return evaluate(e, context: context).toBool()
            }
            return false
        }()
        let writeTarget = writeBackTarget(checkedExpr)
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
            switch checkedExpr?.trimmingCharacters(in: .whitespaces) {
            case "selection_mask_clip": return "clip"
            case "selection_mask_invert": return "invert"
            default: return nil
            }
        }()
        let capturedModel = model

        Toggle(label, isOn: Binding<Bool>(
            get: { isChecked },
            set: { newVal in
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
        ))
            .toggleStyle(.checkbox)
            .disabled(isDisabled)
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
        Picker("", selection: Binding<String>(
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
    }

    // MARK: - Children

    @ViewBuilder
    private func renderChildElements() -> some View {
        let children = element["children"] as? [[String: Any]] ?? []
        ForEach(0..<children.count, id: \.self) { i in
            YamlElementView(element: children[i], context: context, model: model, panelId: panelId, onWidgetAction: onWidgetAction, theme: theme, onDialogWrite: onDialogWrite, onStoreDialogOpened: onStoreDialogOpened)
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
                    YamlElementView(element: content, context: context, model: model, panelId: panelId, onWidgetAction: onWidgetAction, theme: theme, onDialogWrite: onDialogWrite, onStoreDialogOpened: onStoreDialogOpened)
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// A simple slider wrapper to avoid @State in the recursive view.
private struct SliderView: View {
    @State var value: Double
    let range: ClosedRange<Double>
    /// Live callback fired on every drag tick (passes the current
    /// value). Used by the Color panel's HSB / RGB / CMYK sliders
    /// to update the active fill or stroke color in real time
    /// without committing it to the recent strip.
    var onChange: ((Double) -> Void)? = nil
    /// Pointer-up callback. Commits the final value (e.g. pushes
    /// the resulting color onto the recent-colors strip).
    var onCommit: ((Double) -> Void)? = nil

    var body: some View {
        Slider(
            value: Binding(
                get: { value },
                set: { newValue in
                    value = newValue
                    onChange?(newValue)
                }
            ),
            in: range,
            onEditingChanged: { editing in
                if !editing { onCommit?(value) }
            }
        )
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
    case .live: return "Compound Shape"
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
        model.snapshot()
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
        model.document = doc
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
                // Unsolo: restore
                model.snapshot()
                var d = model.document
                for (sp, vis) in s.saved {
                    let e2 = d.getElement(sp)
                    d = d.replaceElement(sp, with: e2.withVisibility(vis))
                }
                model.document = d
                soloState = nil
            } else {
                var saved: [ElementPath: Visibility] = [:]
                for sp in siblings where sp != path {
                    saved[sp] = model.document.getElement(sp).visibility
                }
                model.snapshot()
                var d = model.document
                if e.visibility == .invisible {
                    d = d.replaceElement(path, with: e.withVisibility(.preview))
                }
                for sp in siblings where sp != path {
                    let e2 = d.getElement(sp)
                    d = d.replaceElement(sp, with: e2.withVisibility(.invisible))
                }
                model.document = d
                soloState = (path: path, saved: saved)
            }
        } else {
            soloState = nil
            let newVis = cycleVisibility(e.visibility)
            model.snapshot()
            model.document = model.document.replaceElement(path, with: e.withVisibility(newVis))
        }
    }

    private func performDeleteSelection() {
        guard !panelSelection.isEmpty else { return }
        let topDeletes = panelSelection.filter { $0.count == 1 }.count
        if topDeletes >= model.document.layers.count { return }
        LayersPanel.dispatchYamlAction(
            "delete_layer_selection",
            model: model,
            panelSelection: panelSelection.map { Array($0) }
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
                    model.snapshot()
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
                    model.document = doc
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
                        model.snapshot()
                        model.document = model.document.replaceElement(path, with: .layer(newLayer))
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
                    model.document = Document(
                        layers: model.document.layers,
                        selectedLayer: model.document.selectedLayer,
                        selection: [ElementSelection.all(path)],
                        artboards: model.document.artboards,
                        artboardOptions: model.document.artboardOptions
                    )
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
        LayersPanel.dispatchYamlAction(
            "delete_layer_selection",
            model: model,
            panelSelection: panelSelection.map { Array($0) }
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
        model.snapshot()
        var d = model.document
        for p in panelSelection.sorted(by: { $0.lexicographicallyPrecedes($1) }).reversed() {
            let e = d.getElement(p)
            if case .group(let g) = e {
                d = d.deleteElement(p)
                var insertPath = p
                var firstInsert = true
                for child in g.children {
                    if firstInsert && (insertPath.last ?? 0) == 0 {
                        d = d.insertElementAfter(insertPath, element: child)
                    } else if firstInsert {
                        var ia = insertPath
                        ia[ia.count - 1] = (ia.last ?? 1) - 1
                        d = d.insertElementAfter(ia, element: child)
                    } else {
                        d = d.insertElementAfter(insertPath, element: child)
                    }
                    firstInsert = false
                    insertPath[insertPath.count - 1] += 1
                }
            }
        }
        model.document = d
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
                    model.snapshot()
                    model.document = model.document.replaceElement(path, with: newE)
                }
            // Lock
            SwiftUI.Text(locked ? "\u{1F512}" : "\u{1F513}")
                .frame(width: 16, height: 16)
                .onTapGesture {
                    let e = model.document.getElement(path)
                    let newE = e.withLocked(!e.isLocked)
                    model.snapshot()
                    model.document = model.document.replaceElement(path, with: newE)
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
                        model.snapshot()
                        model.document = model.document.replaceElement(path, with: .layer(newLayer))
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
                    model.document = Document(
                        layers: model.document.layers,
                        selectedLayer: model.document.selectedLayer,
                        selection: [ElementSelection.all(path)],
                        artboards: model.document.artboards,
                        artboardOptions: model.document.artboardOptions
                    )
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
            model.snapshot()
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
            model.document = doc
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
    /// Dialog overlays supply this so dialog-bound widgets can write
    /// back to the SwiftUI dialog state. Panels leave it nil.
    var onDialogWrite: ((String, Any?) -> Void)? = nil
    /// Forwarded to ``YamlElementView/onStoreDialogOpened`` — fires
    /// after a widget effect transitions the store's dialog id, so
    /// DockPanelView can copy the new dialog state into its SwiftUI
    /// overlay binding (mirrors `dispatchWithDialogBridge` for the
    /// menu path).
    var onStoreDialogOpened: (() -> Void)? = nil

    var body: some View {
        YamlElementView(
            element: contentSpec, context: context, model: model,
            panelId: panelId, theme: theme,
            onDialogWrite: onDialogWrite,
            onStoreDialogOpened: onStoreDialogOpened
        )
            .padding(4)
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
