import Foundation

// Native-first routing for the test-only `--test-fifo` `action <name>`
// command channel. JasSwift port of the Python reference
// (jas_app.py MainWindow._dispatch_action_by_name, commit eae9c2f9).
//
// WHY native-first: document-mutating menubar / edit / file actions
// (`new_document`, `select_all`, `delete_selection`, ...) are
// NATIVE-INTERCEPTED. Their actions.yaml `effects` are deliberate
// `log` / `if` STUBS — the real behavior lives natively (JasCommands'
// private menu router + keyboard-only natives). The FIFO `action` verb
// used to route every name through the GENERIC panel dispatcher
// (`LayersPanel.dispatchYamlAction`), which runs only those `effects`,
// so `action select_all` / `delete_selection` logged-and-no-op'd while a
// real menu click / keystroke mutated the document. `tool <id>` is fine
// because select_tool's real behavior IS its generic `set: active_tool`
// effect, so it does NOT go through here.
//
// JasCommands.dispatchMenuAction is a PRIVATE method on a SwiftUI
// `struct JasCommands: Commands` (@FocusedValue model + injected
// closures) and is NOT reachable from the app delegate's FIFO handler.
// So this dispatcher performs the SAME document-mutation ops the
// JasCommands handlers use, directly on the active model:
//   select_all       -> Controller.selectAll()      (== JasCommands.selectAll)
//   delete_selection -> shared opApply delete_selection in a named txn
//                       (== the keyboard-only native delete; one named
//                        undo step via the shared op_apply dispatcher,
//                        matching Python's _route_delete_selection)
// Everything else falls through to the generic panel dispatcher for
// genuine panel / generic-effect actions (panel toggles, etc.).
public enum FifoActionRouting {
    /// Native-first dispatch of a named action for the FIFO `action`
    /// channel. Routes document-mutating natives directly on `model`,
    /// else calls `fallthrough` (the generic panel dispatcher).
    ///
    /// `fallthrough` is injectable so the routing decision is unit-
    /// testable without standing up the YAML effects pipeline (the Swift
    /// analog of Python monkeypatching dock_panel._dispatch_yaml_action).
    /// It defaults to `LayersPanel.dispatchYamlAction`, exactly what the
    /// FIFO handler used before this native-first layer.
    public static func dispatch(
        _ name: String,
        model: Model,
        params: [String: Any] = [:],
        fallthrough fallthroughDispatch:
            (_ name: String, _ model: Model, _ params: [String: Any]) -> Void
            = { name, model, params in
                LayersPanel.dispatchYamlAction(name, model: model, params: params)
            }
    ) {
        switch name {
        case "select_all":
            // Same op JasCommands.selectAll() runs (selection-only,
            // non-undoable per OP_LOG.md §7/§8).
            Controller(model: model).selectAll()
        case "delete_selection":
            // Keyboard-only native delete: journals ONE named
            // `delete_selection` op via the shared opApply dispatcher
            // (OP_LOG.md §9), matching Python's _route_delete_selection.
            // No-op when nothing is selected (opApply handles the empty
            // case). The orphan-confirm NSAlert that JasCommands shows is
            // intentionally skipped here: the FIFO channel is headless
            // test-only input with no UI to confirm against.
            guard !model.document.selection.isEmpty else { return }
            model.withTxn {
                model.nameTxn("delete_selection")
                opApply(model, Controller(model: model), ["op": "delete_selection"])
            }
        default:
            // Genuine panel / generic-effect action.
            fallthroughDispatch(name, model, params)
        }
    }
}
