/// Reactive state store for the workspace interpreter.
///
/// Manages global state, panel-scoped state, and dialog-scoped state.
/// Pure Swift, no SwiftUI dependency. Port of workspace_interpreter/state_store.py.

import Foundation

/// Manages global state, panel-scoped state, dialog-scoped state, and
/// builds evaluation contexts for the expression evaluator.
public class StateStore {

    // MARK: - Global state

    private var state: [String: Any]
    private var panels: [String: [String: Any]] = [:]
    private var activePanel: String?

    // MARK: - Dialog state

    private var dialog: [String: Any] = [:]
    private var dialogId: String?
    private var dialogParams: [String: Any]?
    private var dialogProps: [String: [String: Any]] = [:]  // {key: {"get": expr, "set": expr}}
    /// Captured original values of state keys named in the open dialog's
    /// preview_targets. Restored on closeDialog (via the close_dialog
    /// effect) unless first cleared by the clear_dialog_snapshot effect
    /// (used by OK actions).
    private var dialogSnapshot: [String: Any]?

    // MARK: - Init

    public init(defaults: [String: Any]? = nil) {
        self.state = defaults ?? [:]
    }

    // MARK: - Global state accessors

    public func get(_ key: String) -> Any? {
        state[key]
    }

    public func set(_ key: String, _ value: Any?) {
        state[key] = value
    }

    public func getAll() -> [String: Any] {
        state
    }

    // MARK: - Panel state

    public func initPanel(_ panelId: String, defaults: [String: Any]) {
        panels[panelId] = defaults
    }

    public func hasPanel(_ panelId: String) -> Bool {
        panels[panelId] != nil
    }

    public func getPanel(_ panelId: String, _ key: String) -> Any? {
        panels[panelId]?[key]
    }

    public func setPanel(_ panelId: String, _ key: String, _ value: Any?) {
        panels[panelId]?[key] = value
    }

    public func getPanelState(_ panelId: String) -> [String: Any] {
        panels[panelId] ?? [:]
    }

    public func setActivePanel(_ panelId: String?) {
        activePanel = panelId
    }

    public func getActivePanelId() -> String? {
        activePanel
    }

    public func getActivePanelState() -> [String: Any] {
        guard let pid = activePanel else { return [:] }
        return panels[pid] ?? [:]
    }

    public func destroyPanel(_ panelId: String) {
        panels.removeValue(forKey: panelId)
        if activePanel == panelId {
            activePanel = nil
        }
    }

    // MARK: - Dialog state

    public func initDialog(_ dialogId: String, defaults: [String: Any],
                           params: [String: Any]? = nil,
                           props: [String: [String: Any]]? = nil) {
        self.dialogId = dialogId
        self.dialog = defaults
        self.dialogParams = params
        self.dialogProps = props ?? [:]
    }

    public func getDialog(_ key: String) -> Any? {
        guard dialogId != nil else { return nil }
        if let prop = dialogProps[key], let getExpr = prop["get"] as? String {
            // Evaluate getter against sibling dialog state as bare names
            let local = dialog
            let result = evaluate(getExpr, context: local)
            return result.toAny()
        }
        return dialog[key]
    }

    public func setDialog(_ key: String, _ value: Any?) {
        guard dialogId != nil else { return }
        if let prop = dialogProps[key] {
            if let setExpr = prop["set"] as? String {
                // Parse the setter as a lambda and apply with the value
                var local = dialog
                let storeCb: (String, Value) -> Void = { [weak self] target, val in
                    self?.dialog[target] = val.toAny()
                }
                local["__store_cb__"] = storeCb
                let setterVal = evaluate(setExpr, context: local)
                if case .closure(let params, let body, let captured) = setterVal {
                    if params.count == 1 {
                        var callCtx = captured
                        for (k, v) in local { callCtx[k] = v }
                        callCtx[params[0]] = value
                        let _ = evalNode(body, callCtx)
                    }
                }
                return
            }
            if prop["get"] != nil {
                return  // read-only prop — ignore writes
            }
        }
        dialog[key] = value
    }

    public func getDialogState() -> [String: Any] {
        dialog
    }

    public func getDialogId() -> String? {
        dialogId
    }

    public func getDialogParams() -> [String: Any]? {
        dialogParams
    }

    public func closeDialog() {
        dialogId = nil
        dialog = [:]
        dialogParams = nil
        dialogProps = [:]
    }

    /// Capture the current value of every state key referenced by a
    /// dialog's preview_targets. Phase 0 supports only top-level state
    /// keys (no dots in the path); deep paths are silently skipped and
    /// will land alongside their first real consumer in Phase 8/9.
    /// `targets` maps `dialog_state_key` → `state_key`.
    public func captureDialogSnapshot(_ targets: [String: String]) {
        var snap: [String: Any] = [:]
        for stateKey in targets.values {
            if !stateKey.contains(".") {
                snap[stateKey] = state[stateKey] as Any
            }
        }
        dialogSnapshot = snap
    }

    public func getDialogSnapshot() -> [String: Any]? {
        dialogSnapshot
    }

    public func clearDialogSnapshot() {
        dialogSnapshot = nil
    }

    public func hasDialogSnapshot() -> Bool {
        dialogSnapshot != nil
    }

    // MARK: - List operations

    public func listPush(_ panelId: String, _ key: String, _ value: Any,
                         unique: Bool = false, maxLength: Int? = nil) {
        guard panels[panelId] != nil else { return }
        var lst = (panels[panelId]?[key] as? [Any]) ?? []
        if unique {
            lst.removeAll { item in
                "\(item)" == "\(value)"
            }
        }
        lst.insert(value, at: 0)
        if let max = maxLength, lst.count > max {
            lst = Array(lst.prefix(max))
        }
        panels[panelId]?[key] = lst
    }

    // MARK: - Context for expression evaluation

    /// Build an evaluation context dict for the expression evaluator.
    /// Returns ["state": [...], "panel": [...], ...].
    /// When a dialog is open, also includes "dialog" and "param" keys.
    public func evalContext(extra: [String: Any]? = nil) -> [String: Any] {
        var ctx: [String: Any] = ["state": state]

        if let pid = activePanel, let scope = panels[pid] {
            ctx["panel"] = scope
        } else {
            ctx["panel"] = [String: Any]()
        }

        if dialogId != nil {
            ctx["dialog"] = dialog
            if let params = dialogParams {
                ctx["param"] = params
            }
        }

        if let extra = extra {
            for (k, v) in extra {
                ctx[k] = v
            }
        }
        return ctx
    }
}
