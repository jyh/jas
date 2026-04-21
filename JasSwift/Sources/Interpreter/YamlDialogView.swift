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

    // Evaluate init expressions (two-pass for dict order independence)
    if let initMap = dlgDef["init"] as? [String: Any] {
        var deferred: [(String, Any)] = []
        for (key, expr) in initMap {
            let exprStr = expr as? String ?? ""
            if exprStr.contains("dialog.") {
                deferred.append((key, expr))
            } else {
                let initCtx: [String: Any] = [
                    "state": liveState,
                    "dialog": dialogState,
                    "param": resolvedParams,
                ]
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
struct YamlDialogOverlay: View {
    @Binding var dialogState: YamlDialogState?
    let theme: Theme

    var body: some View {
        if let ds = dialogState {
            ZStack {
                // Backdrop
                SwiftUI.Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dialogState = nil
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
            }
        }
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

            Button(action: { dialogState = nil }) {
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
            let ctx = buildEvalContext(ds)
            YamlElementView(element: content, context: ctx)
                .padding(4)
        }
    }

    private func buildEvalContext(_ ds: YamlDialogState) -> [String: Any] {
        var ctx: [String: Any] = [
            "dialog": ds.state,
            "param": ds.params,
        ]
        if let ws = WorkspaceData.load() {
            ctx["state"] = ws.stateDefaults()
            ctx["icons"] = ws.icons()
        }
        return ctx
    }

    private func dialogWidth(_ ds: YamlDialogState) -> CGFloat {
        guard let ws = WorkspaceData.load(),
              let dlgDef = ws.dialog(ds.id),
              let w = dlgDef["width"] as? NSNumber else { return 500 }
        return CGFloat(w.doubleValue)
    }
}
