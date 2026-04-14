/// Reactive state store for the workspace interpreter.
///
/// Manages global state, panel-scoped state, and dialog-scoped state.
/// Pure Swift, no SwiftUI dependency. Port of workspace_interpreter/state_store.py.

import Foundation

/// Manages global state, panel-scoped state, dialog-scoped state, and
/// builds evaluation contexts for the expression evaluator.
class StateStore {

    // MARK: - Global state

    private var state: [String: Any]
    private var panels: [String: [String: Any]] = [:]
    private var activePanel: String?

    // MARK: - Dialog state

    private var dialog: [String: Any] = [:]
    private var dialogId: String?
    private var dialogParams: [String: Any]?
    private var dialogProps: [String: [String: Any]] = [:]  // {key: {"get": expr, "set": expr}}

    // MARK: - Init

    init(defaults: [String: Any]? = nil) {
        self.state = defaults ?? [:]
    }

    // MARK: - Global state accessors

    func get(_ key: String) -> Any? {
        state[key]
    }

    func set(_ key: String, _ value: Any?) {
        state[key] = value
    }

    func getAll() -> [String: Any] {
        state
    }

    // MARK: - Panel state

    func initPanel(_ panelId: String, defaults: [String: Any]) {
        panels[panelId] = defaults
    }

    func getPanel(_ panelId: String, _ key: String) -> Any? {
        panels[panelId]?[key]
    }

    func setPanel(_ panelId: String, _ key: String, _ value: Any?) {
        panels[panelId]?[key] = value
    }

    func getPanelState(_ panelId: String) -> [String: Any] {
        panels[panelId] ?? [:]
    }

    func setActivePanel(_ panelId: String?) {
        activePanel = panelId
    }

    func getActivePanelId() -> String? {
        activePanel
    }

    func getActivePanelState() -> [String: Any] {
        guard let pid = activePanel else { return [:] }
        return panels[pid] ?? [:]
    }

    func destroyPanel(_ panelId: String) {
        panels.removeValue(forKey: panelId)
        if activePanel == panelId {
            activePanel = nil
        }
    }

    // MARK: - Dialog state

    func initDialog(_ dialogId: String, defaults: [String: Any],
                    params: [String: Any]? = nil,
                    props: [String: [String: Any]]? = nil) {
        self.dialogId = dialogId
        self.dialog = defaults
        self.dialogParams = params
        self.dialogProps = props ?? [:]
    }

    func getDialog(_ key: String) -> Any? {
        guard dialogId != nil else { return nil }
        if let prop = dialogProps[key], let getExpr = prop["get"] as? String {
            // Evaluate getter against sibling dialog state as bare names
            let local = dialog
            let result = evaluate(getExpr, context: local)
            return result.toAny()
        }
        return dialog[key]
    }

    func setDialog(_ key: String, _ value: Any?) {
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

    func getDialogState() -> [String: Any] {
        dialog
    }

    func getDialogId() -> String? {
        dialogId
    }

    func getDialogParams() -> [String: Any]? {
        dialogParams
    }

    func closeDialog() {
        dialogId = nil
        dialog = [:]
        dialogParams = nil
        dialogProps = [:]
    }

    // MARK: - List operations

    func listPush(_ panelId: String, _ key: String, _ value: Any,
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
    func evalContext(extra: [String: Any]? = nil) -> [String: Any] {
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
