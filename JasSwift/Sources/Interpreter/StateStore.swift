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

    // MARK: - Tool state
    //
    // Parallels `panels` but keyed by tool id. YAML tool handlers
    // read/write via `$tool.<id>.<key>`; the `set` effect routes
    // those targets here via [`setTool`]. Populated when YamlTool
    // (Phase 5) constructs with a tool spec and seeds its defaults.

    private var tools: [String: [String: Any]] = [:]

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
    /// Action name fired by the post-run hook in runEffects when the
    /// dialog mutates. Set by openDialog from the dialog spec's
    /// on_change field. Cleared on closeDialog.
    private var dialogOnChange: String?
    /// Set by every setDialog write; consumed by the post-run hook
    /// to decide whether to fire the dialog's on_change action.
    private var dialogDirty: Bool = false
    /// Re-entrancy guard: true while the post-run hook is dispatching
    /// the on_change action. Prevents the action's own set effects
    /// from re-triggering the hook.
    private var dialogFiringOnChange: Bool = false

    // MARK: - Data namespace
    //
    // Workspace-loaded reference data (swatch_libraries,
    // brush_libraries, etc.). Mirrors the JS-side `data` namespace
    // from store.mjs and the Rust StateStore.data field. Mutated by
    // the brush.* effect handlers and read by the canvas brush
    // registry sync.

    private var data: [String: Any] = [:]

    public func setData(_ data: [String: Any]) {
        self.data = data
    }

    public func dataAll() -> [String: Any] {
        data
    }

    /// Read a dotted path inside `data`. Path may include the
    /// "data." prefix or omit it. Returns nil for any missing
    /// intermediate.
    public func getDataPath(_ rawPath: String) -> Any? {
        let path = rawPath.hasPrefix("data.") ? String(rawPath.dropFirst(5)) : rawPath
        if path.isEmpty { return data }
        var cur: Any = data
        for seg in path.split(separator: ".") {
            guard let dict = cur as? [String: Any], let next = dict[String(seg)] else {
                return nil
            }
            cur = next
        }
        return cur
    }

    /// Write a value at a dotted path inside `data`. Intermediate
    /// dicts are created on demand.
    public func setDataPath(_ rawPath: String, _ value: Any?) {
        let path = rawPath.hasPrefix("data.") ? String(rawPath.dropFirst(5)) : rawPath
        if path.isEmpty {
            if let map = value as? [String: Any] { data = map }
            return
        }
        let segs = path.split(separator: ".").map(String.init)
        // Walk-and-build. Build a new dictionary tree by reading from
        // root, splicing in the change at the leaf, and writing back.
        data = setPathInDict(data, segs: segs, value: value)
    }

    private func setPathInDict(_ dict: [String: Any], segs: [String], value: Any?) -> [String: Any] {
        var result = dict
        guard let head = segs.first else { return result }
        if segs.count == 1 {
            if let v = value {
                result[head] = v
            } else {
                result.removeValue(forKey: head)
            }
            return result
        }
        let inner = (result[head] as? [String: Any]) ?? [:]
        result[head] = setPathInDict(inner, segs: Array(segs.dropFirst()), value: value)
        return result
    }

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

    // MARK: - Tool state

    public func initTool(_ toolId: String, defaults: [String: Any]) {
        tools[toolId] = defaults
    }

    public func hasTool(_ toolId: String) -> Bool {
        tools[toolId] != nil
    }

    public func getTool(_ toolId: String, _ key: String) -> Any? {
        tools[toolId]?[key]
    }

    public func setTool(_ toolId: String, _ key: String, _ value: Any?) {
        // Create the tool namespace on first write — less friction for
        // callers that haven't explicitly run initTool. Mirrors the Rust
        // set_tool behavior.
        if tools[toolId] == nil {
            tools[toolId] = [:]
        }
        tools[toolId]?[key] = value
    }

    public func getToolState(_ toolId: String) -> [String: Any] {
        tools[toolId] ?? [:]
    }

    public func destroyTool(_ toolId: String) {
        tools.removeValue(forKey: toolId)
    }

    /// Return the whole tool scope (for tests / inspection).
    public func getToolScopes() -> [String: [String: Any]] {
        tools
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

    /// Get a dialog value, evaluating the getter if present.
    ///
    /// Dialog getters may reference cross-scope bindings (panel /
    /// state / active_document / param). Pass them via ``outer``.
    /// Artboard Options reference-point transforms require this.
    public func getDialogWithOuter(_ key: String, outer: [String: Any]) -> Any? {
        guard dialogId != nil else { return nil }
        if let prop = dialogProps[key], let getExpr = prop["get"] as? String {
            var local = outer
            for (k, v) in dialog { local[k] = v }
            let result = evaluate(getExpr, context: local)
            return result.toAny()
        }
        return dialog[key]
    }

    public func getDialog(_ key: String) -> Any? {
        getDialogWithOuter(key, outer: [:])
    }

    /// Set a dialog value, running the setter lambda if present.
    /// ``outer`` gives the setter access to cross-scope bindings.
    public func setDialogWithOuter(_ key: String, _ value: Any?, outer: [String: Any]) {
        guard dialogId != nil else { return }
        dialogDirty = true
        if let prop = dialogProps[key] {
            if let setExpr = prop["set"] as? String {
                // Parse the setter as a lambda and apply with the value
                var local = outer
                for (k, v) in dialog { local[k] = v }
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

    public func setDialog(_ key: String, _ value: Any?) {
        setDialogWithOuter(key, value, outer: [:])
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
        dialogOnChange = nil
        dialogDirty = false
        // dialogFiringOnChange is intentionally NOT cleared here —
        // closeDialog can be invoked from inside an on_change-fired
        // chain, and the guard must remain set until runEffects
        // unwinds.
    }

    public func setDialogOnChange(_ action: String?) {
        dialogOnChange = action
    }

    public func getDialogOnChange() -> String? { dialogOnChange }

    /// Take the dirty flag, leaving it false. Used by the post-run
    /// hook in runEffects to decide whether to fire on_change.
    public func takeDialogDirty() -> Bool {
        let was = dialogDirty
        dialogDirty = false
        return was
    }

    public func isFiringOnChange() -> Bool { dialogFiringOnChange }
    public func setFiringOnChange(_ firing: Bool) { dialogFiringOnChange = firing }

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

        // Tool scope — one nested dict per registered tool. Expressions
        // read as `tool.<id>.<key>`.
        ctx["tool"] = tools

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
