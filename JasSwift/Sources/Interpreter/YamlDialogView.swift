/// YAML-interpreted dialog component for SwiftUI.
///
/// Renders a modal dialog from workspace YAML definitions, reusing the
/// existing YamlElementView for the content tree.

import SwiftUI

/// Dialog state held in a binding.
struct YamlDialogState {
    /// Dialog ID (matches a key in workspace dialogs).
    var id: String
    /// Dialog-local state values.
    var state: [String: Any]
    /// Parameters passed when the dialog was opened.
    var params: [String: Any]
    /// Popover anchor in the window's `.global` coordinate space —
    /// the page coordinates of the press that opened the dialog.
    /// Mirrors Rust's ``DialogState.anchor`` (page coords captured at
    /// the slot button's mouse_down, threaded through the long-press
    /// timer). Only consulted for non-modal dialogs; modal dialogs
    /// stay centered regardless. Default nil → centered fallback,
    /// matching Rust's ``anchor: None`` branch.
    var anchor: CGPoint? = nil
}

/// Open a dialog by ID, initializing its state from the workspace
/// definition. Back-compatible shim over openYamlDialogWithOuter
/// without a cross-scope namespace — dialogs whose init expressions
/// reference `panel.*` or `active_document.*` (Artboard Options)
/// must call the `_withOuter` variant directly.
func openYamlDialog(
    dialogId: String,
    rawParams: [String: Any],
    liveState: [String: Any]
) -> YamlDialogState? {
    openYamlDialogWithOuter(
        dialogId: dialogId,
        rawParams: rawParams,
        liveState: liveState,
        outerScope: [:]
    )
}

/// As ``openYamlDialog`` but threads an ``outerScope`` dictionary whose
/// top-level keys (e.g. ``panel``, ``active_document``) are visible to
/// init expressions alongside ``state``, ``dialog``, ``param``. Required
/// by the Artboard Options Dialogue whose init expressions call
/// ``filter(active_document.artboards, ...)`` and
/// ``panel.reference_point``.
func openYamlDialogWithOuter(
    dialogId: String,
    rawParams: [String: Any],
    liveState: [String: Any],
    outerScope: [String: Any]
) -> YamlDialogState? {
    guard let ws = WorkspaceData.load() else { return nil }
    guard let dlgDef = ws.dialog(dialogId) else { return nil }

    // Extract state defaults
    var defaults: [String: Any] = [:]
    if let stateDefs = dlgDef["state"] as? [String: Any] {
        for (key, defn) in stateDefs {
            if let d = defn as? [String: Any] {
                defaults[key] = d["default"]
            } else {
                defaults[key] = defn
            }
        }
    }

    // Resolve param expressions against current state
    var resolvedParams: [String: Any] = [:]
    let stateCtx: [String: Any] = ["state": liveState]
    for (k, v) in rawParams {
        if let exprStr = v as? String {
            let result = evaluate(exprStr, context: stateCtx)
            resolvedParams[k] = valueToAnyDlg(result)
        } else {
            resolvedParams[k] = v
        }
    }

    var dialogState = defaults

    // Evaluate init expressions (two-pass for dict order independence).
    // Both passes get outerScope so non-dialog-referencing init exprs
    // can still read `active_document.*` and `panel.*` (matches Rust's
    // build_dialog_outer_scope behavior; without this fix any init
    // that reads e.g. `active_document.print_preferences.copies`
    // would silently resolve to null and the dialog would open with
    // the YAML state defaults instead of the persisted document
    // values).
    if let initMap = dlgDef["init"] as? [String: Any] {
        var deferred: [(String, Any)] = []
        for (key, expr) in initMap {
            let exprStr = expr as? String ?? ""
            if exprStr.contains("dialog.") {
                deferred.append((key, expr))
            } else {
                var initCtx: [String: Any] = outerScope
                initCtx["state"] = liveState
                initCtx["dialog"] = dialogState
                initCtx["param"] = resolvedParams
                let result = evaluate(exprStr, context: initCtx)
                dialogState[key] = valueToAnyDlg(result)
            }
        }
        for (key, expr) in deferred {
            let exprStr = expr as? String ?? ""
            var initCtx: [String: Any] = outerScope
            initCtx["state"] = liveState
            initCtx["dialog"] = dialogState
            initCtx["param"] = resolvedParams
            let result = evaluate(exprStr, context: initCtx)
            dialogState[key] = valueToAnyDlg(result)
        }
    }

    return YamlDialogState(
        id: dialogId,
        state: dialogState,
        params: resolvedParams
    )
}

/// Build a ``YamlDialogState`` snapshot from a StateStore that has a
/// dialog open. Returns nil when the store has no active dialog.
///
/// Used by the action → overlay bridge: after running YAML effects,
/// if ``store.getDialogId()`` transitioned from nil to an id, the
/// dispatcher calls this helper and assigns the result to the
/// SwiftUI `yamlDialogState` binding. The Artboard Options Dialogue
/// is opened this way (via the `open_dialog` effect); the color
/// picker uses the direct `openYamlDialog` path instead.
func yamlDialogStateFromStore(_ store: StateStore) -> YamlDialogState? {
    guard let id = store.getDialogId() else { return nil }
    return YamlDialogState(
        id: id,
        state: store.getDialogState(),
        params: store.getDialogParams() ?? [:]
    )
}

/// Build the evaluation context surfaced to a dialog's content-tree
/// renderer. Outer-scope keys (``panel``, ``active_document``) are
/// merged first; the dialog's own ``dialog`` / ``param`` / ``state``
/// / ``icons`` keys win on collision so dialog-local state is never
/// stomped by a like-named outer key.
///
/// Exposed at file scope so Phase F tests can verify merge order
/// without standing up a SwiftUI view.
func buildDialogEvalContext(
    state: [String: Any],
    params: [String: Any],
    outer: [String: Any]
) -> [String: Any] {
    var ctx: [String: Any] = outer
    ctx["dialog"] = state
    ctx["param"] = params
    if let ws = WorkspaceData.load() {
        ctx["state"] = ws.stateDefaults()
        ctx["icons"] = ws.icons()
    }
    return ctx
}

/// Dialog ctx that also resolves YAML-defined getters via the store.
///
/// Color picker H/S/B/R/G/B/C/M/Y/K/hex are declared with `get:`
/// expressions in the YAML state block; they aren't stored in the
/// dialog map. Plain `state["h"]` lookup returns nil, so a widget
/// bound to `dialog.h` would render 0. This variant computes each
/// getter via `StateStore.getDialogWithOuter` and merges the values
/// into the `dialog` map so renderer expressions see them.
func buildDialogEvalContextWithGetters(
    store: StateStore?,
    state: [String: Any],
    params: [String: Any],
    outer: [String: Any]
) -> [String: Any] {
    var dialog = state
    if let store = store, let dlgId = store.getDialogId(),
       let ws = WorkspaceData.load(),
       let dlgDef = ws.dialog(dlgId),
       let stateDefs = dlgDef["state"] as? [String: Any]
    {
        for (key, defn) in stateDefs {
            guard let d = defn as? [String: Any], d["get"] != nil else { continue }
            if let v = store.getDialogWithOuter(key, outer: outer) {
                dialog[key] = v
            }
        }
    }
    return buildDialogEvalContext(state: dialog, params: params, outer: outer)
}

/// Convert a Value to Any? for storage.
private func valueToAnyDlg(_ v: Value) -> Any? {
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

/// SwiftUI view that renders a YAML dialog as a modal overlay.
///
/// ``outerScope`` is a closure evaluated on each render that returns a
/// dictionary merged under the dialog's own ``dialog`` / ``param`` keys.
/// It exposes ``panel`` + ``active_document`` namespaces to render-time
/// bind expressions — e.g. the Artboard Options Dialogue uses
/// ``bind.disabled: active_document.artboards_count <= 1`` on its
/// Delete button and interpolates ``{{active_document.artboards_count}}``
/// into a "Artboards: N" label. Default: an empty closure, matching
/// the back-compat path for dialogs (like color_picker) that read only
/// ``dialog.*`` / ``state.*``.
struct YamlDialogOverlay: View {
    @Binding var dialogState: YamlDialogState?
    let theme: Theme
    var outerScope: () -> [String: Any] = { [:] }
    /// Active Model used for dialog-body widget dispatch. Needs to
    /// be the same Model whose StateStore holds the dialog state
    /// that this overlay is mirroring so that ``close_dialog``
    /// effects (e.g. via ``artboard_options_confirm``'s tail) zero
    /// the store we're watching.
    var model: Model? = nil
    /// Fired when the overlay is dismissed from the UI (X button or
    /// backdrop tap). Callers pair it with `model.stateStore.closeDialog()`
    /// so the SwiftUI binding and the store's dialog tracker stay in
    /// sync — otherwise a subsequent `open_dialog: <same-id>` effect
    /// would be a no-op transition and the bridge would miss it.
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        if let ds = dialogState {
            if !isModal(ds), let anchor = ds.anchor {
                // Popover branch (non-modal + anchored): transparent
                // full-screen backdrop (click-outside dismiss) + a
                // container pinned next to the press location. Mirrors
                // Rust's `!is_modal && anchor==Some` branch
                // (dialog_view.rs:452-457): position:absolute; left/top
                // at the cursor's page coords, no flex centering, no
                // title bar. The slot button is ~28pt wide; offset the
                // popover a touch to the right of the press so it sits
                // beside the button rather than under the cursor.
                anchoredPopover(ds, anchor: anchor)
            } else {
                // Modal (and non-modal-without-anchor) branch: dimmed,
                // flex-centered overlay exactly as before. Color
                // picker / tool-options / print / artboard options all
                // land here and are visually unchanged.
                centeredModal(ds)
            }
        }
    }

    /// Read the dialog spec's `modal` flag, defaulting to true (matches
    /// Rust's ``dlg_def.get("modal")...unwrap_or(true)``). Only
    /// ``modal: false`` dialogs (the toolbar tool-alternates flyouts)
    /// are eligible for at-cursor placement.
    private func isModal(_ ds: YamlDialogState) -> Bool {
        guard let ws = WorkspaceData.load(),
              let dlgDef = ws.dialog(ds.id),
              let m = dlgDef["modal"] as? Bool else { return true }
        return m
    }

    /// Centered modal/backdrop overlay (the pre-existing presentation).
    @ViewBuilder
    private func centeredModal(_ ds: YamlDialogState) -> some View {
        ZStack {
            // Backdrop
            SwiftUI.Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture {
                    dialogState = nil
                    onDismiss?()
                }

            // Dialog container
            VStack(spacing: 0) {
                // Title bar
                titleBar(ds)

                // Body
                dialogBody(ds)
            }
            .background(SwiftUI.Color(nsColor: theme.paneBg))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(SwiftUI.Color(nsColor: theme.border), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
            .frame(maxWidth: dialogWidth(ds))
            // Without this the outer VStack expands vertically to
            // fill the ZStack — Spacer()s in the tabs renderer
            // (used for the left rail and the content column)
            // push the dialog to full window height. Forcing
            // intrinsic vertical sizing fits the dialog to its
            // content; the inner Spacers still let tab content
            // top-align within the available rail height.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Non-modal popover pinned at `anchor` (window `.global` coords).
    /// The transparent backdrop fills the window and dismisses on tap
    /// (mirrors Rust's transparent `inset:0` backdrop whose onmousedown
    /// clears the dialog). The container is placed with `.position` in
    /// the SAME `.global` coordinate space the anchor was captured in,
    /// so left/top math matches Rust's `position:absolute; left/top`.
    @ViewBuilder
    private func anchoredPopover(_ ds: YamlDialogState, anchor: CGPoint) -> some View {
        // `anchor` is the press point in the shared "jasRoot" coordinate
        // space. Convert it into THIS overlay container's local space
        // (via the container's own frame in "jasRoot") and pin the
        // popover's TOP-LEFT there with `.offset` from a topLeading
        // ZStack — so the flyout lands exactly at the press point no
        // matter where the overlay sits in the window. A small nudge
        // keeps the first item clear of the release point. Matches
        // Rust's at-cursor `position:absolute; left/top` flyout.
        let dx: CGFloat = 8
        let dy: CGFloat = 8
        GeometryReader { geo in
            let o = geo.frame(in: .named("jasRoot")).origin
            ZStack(alignment: .topLeading) {
                // Transparent full-area click-outside dismiss target.
                SwiftUI.Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dialogState = nil
                        onDismiss?()
                    }
                popoverContainer(ds)
                    .offset(x: anchor.x - o.x + dx, y: anchor.y - o.y + dy)
            }
        }
    }

    /// The popover's content container: bare (no title bar), shadowed,
    /// width-constrained. Reuses ``dialogBody`` so flyout items render
    /// through the same YamlElementView path as every other dialog.
    @ViewBuilder
    private func popoverContainer(_ ds: YamlDialogState) -> some View {
        VStack(spacing: 0) {
            dialogBody(ds)
        }
        .background(SwiftUI.Color(nsColor: theme.paneBg))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SwiftUI.Color(nsColor: theme.border), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
        // Size the flyout to its intrinsic content (a compact tool list)
        // rather than the 500pt default dialog width. The alternates
        // items are width:"100%", so a wide frame made the popover a
        // 500px box whose bulk read as ~300px to the right of the cursor
        // even though its top-left was pinned at the press point.
        .fixedSize()
    }

    private func titleBar(_ ds: YamlDialogState) -> some View {
        let ws = WorkspaceData.load()
        let dlgDef = ws?.dialog(ds.id)
        let summary = (dlgDef?["summary"] as? String) ?? ds.id

        return HStack {
            SwiftUI.Text(summary)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SwiftUI.Color(nsColor: theme.titleBarText))

            Spacer()

            Button(action: {
                dialogState = nil
                onDismiss?()
            }) {
                SwiftUI.Text("\u{00d7}")
                    .font(.system(size: 16))
                    .foregroundColor(SwiftUI.Color(nsColor: theme.textDim))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SwiftUI.Color(nsColor: theme.titleBarBg))
    }

    @ViewBuilder
    private func dialogBody(_ ds: YamlDialogState) -> some View {
        let ws = WorkspaceData.load()
        let dlgDef = ws?.dialog(ds.id)
        let content = dlgDef?["content"] as? [String: Any]

        if let content = content {
            let ctx = buildDialogEvalContextWithGetters(
                store: model?.stateStore,
                state: ds.state,
                params: ds.params,
                outer: outerScope()
            )
            YamlElementView(
                element: content,
                context: ctx,
                model: model,
                onWidgetAction: handleDialogWidgetAction,
                theme: theme,
                onDialogWrite: handleDialogStateWrite,
                onStoreDialogClosed: { dialogState = nil }
            )
                .foregroundColor(SwiftUI.Color(nsColor: theme.text))
                .padding(4)
        }
    }

    /// Receive a write from a dialog-body widget bound to ``dialog.X``.
    /// Updates the underlying StateStore (which runs the prop's set
    /// lambda when present) and re-syncs the SwiftUI ``dialogState``
    /// binding from the post-write store snapshot. The earlier
    /// implementation also wrote `value` into `ds.state[key]`
    /// directly, which bypassed the setter — fields with get/set
    /// (color picker H/S/B/R/G/B/C/M/Y/K) ended up with the typed
    /// value in `state[key]` but stale derived values everywhere
    /// else, and the field snapped back to its computed-from-color
    /// value on the next render.
    private func handleDialogStateWrite(_ key: String, _ value: Any?) {
        guard let store = model?.stateStore else {
            guard var ds = dialogState else { return }
            ds.state[key] = value
            dialogState = ds
            return
        }
        store.setDialog(key, value)
        // Color picker "Only Web Colors": when toggled on, snap each
        // RGB channel to multiples of 51 (0/51/102/153/204/255). The
        // r/g/bl setters route through the YAML lambdas which rebuild
        // dialog.color, so subsequent reads of h/s/b/r/g/bl/c/m/y/k/hex
        // see the snapped value.
        if key == "web_only", let on = value as? Bool, on {
            func snap(_ v: Int) -> Int {
                let n = (Double(v) / 51.0).rounded() * 51.0
                return min(max(Int(n), 0), 255)
            }
            func ival(_ k: String) -> Int {
                if let any = store.getDialog(k) {
                    if let i = any as? Int { return i }
                    if let d = any as? Double { return Int(d.rounded()) }
                }
                return 0
            }
            store.setDialog("r", snap(ival("r")))
            store.setDialog("g", snap(ival("g")))
            store.setDialog("bl", snap(ival("bl")))
        }
        if var ds = dialogState {
            ds.state = store.getDialogState()
            dialogState = ds
        }
    }

    /// Dispatch a dialog-body widget-level ``action:`` click. Params
    /// are already resolved against the dialog ctx by YamlElementView.
    ///
    /// Two action shapes:
    /// - ``dismiss_dialog`` — close the store and zero the binding.
    ///   Matches the Python YamlDialogView._dispatch_dialog_action
    ///   special case (Cancel button idiom).
    /// - any other action name — route through
    ///   ``LayersPanel.dispatchYamlAction`` with the resolved params.
    ///   If the action's effects include ``close_dialog``, the store's
    ///   dialog id becomes nil; we mirror that by zeroing the binding.
    private func handleDialogWidgetAction(_ actionName: String,
                                           _ params: [String: Any]) {
        if actionName == "dismiss_dialog" {
            model?.stateStore.closeDialog()
            dialogState = nil
            return
        }
        guard let m = model else { return }
        let abSel = (m.stateStore.getPanelState("artboards")["artboards_panel_selection"] as? [Any])?
            .compactMap { $0 as? String } ?? []
        LayersPanel.dispatchYamlAction(
            actionName, model: m,
            artboardsPanelSelection: abSel,
            params: params
        )
        // The action's effects may have run close_dialog — sync the
        // SwiftUI binding so the overlay dismisses.
        if m.stateStore.getDialogId() == nil {
            dialogState = nil
        }
    }

    private func dialogWidth(_ ds: YamlDialogState) -> CGFloat {
        guard let ws = WorkspaceData.load(),
              let dlgDef = ws.dialog(ds.id),
              let w = dlgDef["width"] as? NSNumber else { return 500 }
        return CGFloat(w.doubleValue)
    }
}

