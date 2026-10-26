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
//   delete_selection -> shared opApply delete_selection in a named txn
//                       (== the keyboard-only native delete; one named
//                        undo step via the shared op_apply dispatcher,
//                        matching Python's _route_delete_selection)
// Everything else falls through to the generic panel dispatcher for
// genuine panel / generic-effect actions (panel toggles, etc.), and so does
// `select_all`: since 2026-10-25 its YAML is `doc.op: {op: select_all}`.
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

// ── `view` and `open`: the level-2 harness's two needs (TESTING.md §6) ──
// A level-2 harness on the Mac posts real pointer events at screen points, so
// it must know where a document point is on screen. The canvas has pan and
// zoom; the Windows shell has neither. `view 1 0 0` removes both, so a
// document unit is one canvas point, and the canvas reports the view it has
// (`report`) in its accessibility value, so the harness reads the mapping
// back rather than trusting that the command took. `open <path>` opens a
// script's setup file without File > Open's dialog. Both exist only behind
// `--test-fifo`. The frozen Python app has neither; they are a level-2 need,
// not a port of the reference.

/// The view a `view <zoom> <offx> <offy>` command sets.
public struct FifoView: Equatable {
    public let zoom: Double
    public let offsetX: Double
    public let offsetY: Double

    public init(zoom: Double, offsetX: Double, offsetY: Double) {
        self.zoom = zoom
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    /// Exactly three numbers; the zoom positive and finite, the offsets
    /// finite. Anything else is nil, so a typo never leaves the old view
    /// standing while the harness believes it moved.
    public static func parse(_ rest: String) -> FifoView? {
        let f = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard f.count == 3,
              let z = Double(f[0]), let x = Double(f[1]), let y = Double(f[2]),
              z.isFinite, z > 0, x.isFinite, y.isFinite
        else { return nil }
        return FifoView(zoom: z, offsetX: x, offsetY: y)
    }

    /// The same bare field writes `doc.zoom.apply` makes (view state is
    /// per-tab and not undoable).
    public func apply(to model: Model) {
        model.zoomLevel = zoom
        model.viewOffsetX = offsetX
        model.viewOffsetY = offsetY
    }

    /// The model's view as the command that would set it: `view z x y`.
    public static func report(_ model: Model) -> String {
        "view \(model.zoomLevel) \(model.viewOffsetX) \(model.viewOffsetY)"
    }

    /// Set by the app when `--test-fifo` is present, so the canvas reports
    /// its view only to a harness and never to a screen reader.
    nonisolated(unsafe) public static var reportsToAccessibility = false
}

/// `open <path>`: File > Open's document, without its dialog.
public enum FifoOpen {
    /// The model File > Open builds for this file: `documentForOpen` over
    /// its text, with the path as the filename. Throws if it cannot be read.
    public static func model(path: String) throws -> Model {
        let svg = try String(contentsOfFile: path, encoding: .utf8)
        return Model(document: documentForOpen(svg), filename: path)
    }
}

/// `read <path>`: the active document's canonical test JSON, written to `path`
/// byte for byte (atomically, replacing). The `jas://document` resource
/// re-encodes the same JSON through JSONSerialization, which keeps the values
/// and not the bytes; a level-2 comparison is of bytes, so it reads this.
public enum FifoRead {
    public static func write(_ model: Model, to path: String) throws {
        try Data(documentToTestJson(model.document).utf8)
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// What a `--test-fifo` launch changes beyond the FIFO itself.
public enum TestHarness {
    /// A harness launch neither restores nor saves the session
    /// (`~/Library/Application Support/Jas/session`). A level-2 run launches
    /// and quits the app once per script, so saving would overwrite the
    /// developer's open tabs, and restoring would hand one script's edited
    /// documents to the next. Read from the arguments, so launch order
    /// cannot matter.
    public static func isolatesSession(_ args: [String] = CommandLine.arguments) -> Bool {
        args.contains("--test-fifo")
    }
}
