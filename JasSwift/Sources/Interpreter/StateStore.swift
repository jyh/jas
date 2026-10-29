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

    /// File writes an effect asked for, in order, for the HOST to drain
    /// (`brush.save_library`): the interpreter does no file I/O itself.
    /// Mirrors the reference's `StateStore.pending_writes`.
    public var pendingWrites: [[String: Any]] = []

    /// The host's writer, installed by the app (``BrushLibraryStore/live``),
    /// never in a test process. Called on every queued write; a write it
    /// reports done leaves the queue, a failed one stays.
    public var pendingWriteSink: (([String: Any]) -> Bool)?

    /// Queue a file write for the host and hand it to the sink if one is
    /// installed. The ONE way an effect queues a write, so every route drains.
    public func appendPendingWrite(_ w: [String: Any]) {
        pendingWrites.append(w)
        guard let sink = pendingWriteSink else { return }
        pendingWrites.removeAll { sink($0) }
    }

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
    /// A nested dialog (the Color Picker from Layer Options) is PUSHED over
    /// its parent: each entry is a parent's whole dialog frame, restored by
    /// `closeDialog`. `dialogResultTo` is the open dialog's own: the parent
    /// field its result lands in when it closes with one
    /// (`close_dialog: {result: ...}`). The reference's `push_dialog`.
    private struct DialogFrame {
        var id: String?
        var state: [String: Any]
        var params: [String: Any]?
        var props: [String: [String: Any]]
        var onChange: String?
        var dirty: Bool
        var snapshot: [String: Any]?
        var resultTo: String?
    }
    private var dialogStack: [DialogFrame] = []
    private var dialogResultTo: String?

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

    /// The panel CONTENT id a `panel:` reference names.
    ///
    /// The workspace YAML names a panel's state scope by its SHORT kind at
    /// every effect site (`set_panel_state: { panel: brushes, … }`) while
    /// every panel map in the compiled bundle — and so `panelStateDefaults`
    /// and the `panel.<key>` reads a panel's own widgets make — is keyed by
    /// the content id (`brushes_panel_content`). Appending the suffix when it
    /// is absent, and passing an id that already carries it through, is the
    /// one rule that makes both spellings address ONE scope. It is applied
    /// at THIS store's boundary (init, read, write, the active panel, the
    /// list verbs) so no caller can spell its way into a second bucket.
    ///
    /// This port used to apply it inside the `set_panel_state` effect and
    /// nowhere else: the YAML's `panel: artboards` writes landed in
    /// `artboards_panel_content` while the native artboard verbs, the
    /// artboards panel's dispatch and the dialog scope all read and wrote
    /// `"artboards"` — two buckets for one selection, and which one a
    /// reader saw depended on who had written last. Mirrors jas_dioxus
    /// `panel_menu::panel_content_id` and the reference's
    /// `state_store.panel_content_id`.
    public static func panelContentId(_ raw: String) -> String {
        raw.hasSuffix("_panel_content") ? raw : raw + "_panel_content"
    }

    public func initPanel(_ panelId: String, defaults: [String: Any]) {
        panels[Self.panelContentId(panelId)] = defaults
    }

    public func hasPanel(_ panelId: String) -> Bool {
        panels[Self.panelContentId(panelId)] != nil
    }

    public func getPanel(_ panelId: String, _ key: String) -> Any? {
        panels[Self.panelContentId(panelId)]?[key]
    }

    /// A nil VALUE is stored as `NSNull`, never as a missing key: assigning an
    /// optional nil into a dictionary REMOVES the key, so before this a
    /// `set_panel_state {value: null}` (Escape in an artboard rename) deleted a
    /// declared key that `initPanel` had seeded as `NSNull`, and the panel's
    /// scope no longer had it at all. The reference's `set_panel` stores None
    /// with the key present (the action corpus, `cancel_artboard_rename`).
    public func setPanel(_ panelId: String, _ key: String, _ value: Any?) {
        panels[Self.panelContentId(panelId)]?[key] = value ?? NSNull()
    }

    public func getPanelState(_ panelId: String) -> [String: Any] {
        panels[Self.panelContentId(panelId)] ?? [:]
    }

    public func setActivePanel(_ panelId: String?) {
        activePanel = panelId.map(Self.panelContentId)
    }

    public func getActivePanelId() -> String? {
        activePanel
    }

    public func getActivePanelState() -> [String: Any] {
        guard let pid = activePanel else { return [:] }
        return panels[pid] ?? [:]
    }

    public func destroyPanel(_ panelId: String) {
        let panelId = Self.panelContentId(panelId)
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
        // A nil value is stored as NSNull, as `setPanel` does: assigning nil
        // removes the key, and the reference's `set_dialog` keeps it as None.
        // Until 2026-10-13 an init that evaluated to null (Swatch Options in
        // create mode, with no swatch name passed) deleted the dialog's key.
        dialog[key] = value ?? NSNull()
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

    /// Keep the open dialog under the next one: the next `initDialog` opens
    /// the child over it, and `closeDialog` returns to it intact. The child
    /// starts with no preview snapshot, and `resultTo` names the parent's
    /// field that the child's result is written to.
    public func pushDialog(resultTo: String?) {
        dialogStack.append(DialogFrame(
            id: dialogId, state: dialog, params: dialogParams, props: dialogProps,
            onChange: dialogOnChange, dirty: dialogDirty, snapshot: dialogSnapshot,
            resultTo: dialogResultTo))
        dialogSnapshot = nil
        dialogResultTo = resultTo
    }

    public func getDialogResultTo() -> String? { dialogResultTo }

    /// How many dialogs are open: 0, 1, or more when nested.
    public func dialogDepth() -> Int { (dialogId == nil ? 0 : 1) + dialogStack.count }

    public func closeDialog() {
        if let parent = dialogStack.popLast() {
            dialogId = parent.id
            dialog = parent.state
            dialogParams = parent.params
            dialogProps = parent.props
            dialogOnChange = parent.onChange
            dialogDirty = parent.dirty
            dialogSnapshot = parent.snapshot
            dialogResultTo = parent.resultTo
            return
        }
        dialogResultTo = nil
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
        let panelId = Self.panelContentId(panelId)
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

    /// Add `value` to a panel-state list, or remove its FIRST occurrence if
    /// present: set membership, the checkbox primitive (council Q3.2).
    /// Appends, never prepends. A key holding no list starts from an empty
    /// one. Mirrors the reference's `StateStore.list_toggle` (Python's
    /// `list.remove`: the first occurrence only).
    ///
    /// With `keyField`, membership is `item[keyField] == value` over a list of
    /// objects: the first such item is removed, else `{keyField: value}` is
    /// appended beside the literal `insert` fields (the key wins).
    public func listToggle(_ panelId: String, _ key: String, _ value: Any,
                           keyField: String? = nil, insert: [String: Any]? = nil) {
        let panelId = Self.panelContentId(panelId)
        guard panels[panelId] != nil else { return }
        var lst = (panels[panelId]?[key] as? [Any]) ?? []
        if let keyField {
            let match: (Any) -> Bool = { item in
                guard let d = item as? [String: Any], let v = d[keyField] as? NSObject else { return false }
                return v.isEqual(value)
            }
            if let i = lst.firstIndex(where: match) {
                lst.remove(at: i)
            } else {
                var item = insert ?? [:]
                item[keyField] = value
                lst.append(item)
            }
        } else if let i = lst.firstIndex(where: { ($0 as? NSObject)?.isEqual(value) ?? false }) {
            lst.remove(at: i)
        } else {
            lst.append(value)
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

        // The data namespace (brush_libraries, swatch_libraries), so a dialog
        // init or an action reads `data.*` from the store the library effects
        // write, as `state_store.py` does. Until 2026-10-15 no port's context
        // carried it, so Brush Options' edit-mode inits were null everywhere.
        ctx["data"] = data

        if dialogId != nil {
            // Every `get` evaluated, so a derived key (the Color Picker's and
            // Swatch Options' r/g/b/h/s/b/c/m/y/k/hex) reads its computed
            // value beside the stored ones, as the reference's
            // `eval_context` does. Its scope is the dialog's stored values by
            // bare name plus `state`, the active panel's `panel` and `param`.
            var dlg = dialog
            if !dialogProps.isEmpty {
                var local: [String: Any] = dialog
                local["state"] = state
                local["panel"] = ctx["panel"]
                if let params = dialogParams { local["param"] = params }
                for (key, prop) in dialogProps {
                    if let getExpr = prop["get"] as? String {
                        dlg[key] = evaluate(getExpr, context: local).toAny() ?? NSNull()
                    }
                }
            }
            ctx["dialog"] = dlg
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
