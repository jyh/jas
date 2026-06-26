import Foundation
import Darwin
import JasLib

// ── Test-only FIFO command channel ──────────────────────────────────────
// A GUI-test harness can't always reach a tool via synthetic keyboard
// (AppKit first-responder quirks), and the flyout-alternate tools
// (paintbrush / blob brush) need a deterministic activation path. When
// launched with `--test-fifo PATH`, the app reads newline commands from
// the FIFO and dispatches them through the SAME production paths the
// toolbar / menu use, so a test drives real tool selection / actions with
// zero reliance on synthetic input. Commands:
//     tool <id>                 -> select_tool {tool: <id>} (full activation
//                                  lifecycle, via Model.requestTool — the
//                                  same sink the keyboard / flyout toolbar
//                                  selection uses)
//     action <name> [json]      -> <name> with optional JSON params, run
//                                  through the shared YAML effects pipeline
//                                  (LayersPanel.dispatchYamlAction — the same
//                                  generic action runner the panels / menu
//                                  route through)
// Gated entirely behind the flag (no effect on normal launch): no flag,
// no FIFO, no DispatchSource, no log lines. Mirrors the Python reference
// (jas_app.py MainWindow._setup_test_fifo); Python uses a Qt
// QSocketNotifier on the FIFO fd, here it is a main-queue DispatchSource.
extension JasAppDelegate {
    /// Parse `--test-fifo <path>` from the command line, identical in
    /// shape to the `--title` parse in JasApp.swift. Returns nil when the
    /// flag is absent (the normal-launch fast path).
    static var testFifoPath: String? {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--test-fifo"), i + 1 < args.count {
            return args[i + 1]
        }
        return nil
    }

    /// Create + open the FIFO and arm a main-queue read source. Called once
    /// from applicationDidFinishLaunching, only when --test-fifo is present.
    func setupTestFifo(path: String) {
        // Create the FIFO if it does not exist (mkfifo). EEXIST is fine.
        if !FileManager.default.fileExists(atPath: path) {
            let rc = path.withCString { mkfifo($0, 0o600) }
            if rc != 0 && errno != EEXIST {
                NSLog("test-fifo: mkfifo failed for %@ (errno %d)", path, errno)
                return
            }
        }
        // O_RDWR keeps a writer end open so the fd never EOFs between
        // harness writes — the read source then fires only on real data.
        // O_NONBLOCK so the open() and reads never block the main loop.
        let fd = path.withCString { open($0, O_RDWR | O_NONBLOCK) }
        if fd < 0 {
            NSLog("test-fifo: open failed for %@ (errno %d)", path, errno)
            return
        }
        testFifoFd = fd
        testFifoBuffer = Data()
        // Read on the app's MAIN run loop: every command mutates the
        // tool / document, which must happen on the main thread.
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.onTestFifoReadable()
        }
        source.resume()
        testFifoSource = source  // retain (else cancelled on return)
        NSLog("test-fifo: listening on %@", path)
    }

    /// Read whatever bytes are available, buffer partial reads, split on
    /// '\n', trim, ignore blank lines, dispatch each command. Mirrors the
    /// Python _on_test_fifo_readable buffering.
    private func onTestFifoReadable() {
        guard testFifoFd >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(testFifoFd, &chunk, chunk.count)
        if n <= 0 { return }  // EAGAIN / no data / writer gap
        testFifoBuffer.append(contentsOf: chunk[0..<n])
        while let nlIdx = testFifoBuffer.firstIndex(of: 0x0A) {  // '\n'
            let lineData = testFifoBuffer.subdata(
                in: testFifoBuffer.startIndex..<nlIdx)
            // Drop through the newline.
            testFifoBuffer.removeSubrange(testFifoBuffer.startIndex...nlIdx)
            let raw = String(decoding: lineData, as: UTF8.self)
            let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cmd.isEmpty {
                dispatchTestCommand(cmd)
            }
        }
    }

    /// Dispatch one command line through the production runner. Logs one
    /// line per dispatched command so the verifier can confirm dispatch
    /// without a GUI draw. Mirrors Python _dispatch_test_command.
    private func dispatchTestCommand(_ cmd: String) {
        NSLog("test-fifo: %@", cmd)
        // Split into verb + remainder (the remainder may itself contain
        // spaces — an action name followed by a JSON blob).
        let parts = cmd.split(separator: " ", maxSplits: 1,
                              omittingEmptySubsequences: true).map(String.init)
        guard let verb = parts.first else { return }
        let rest = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch verb {
        case "tool":
            // The select_tool action: drive tool selection through the
            // SAME sink the keyboard / flyout toolbar selection uses
            // (Model.requestTool sets toolRequest, observed by ContentView
            // which runs the full activation lifecycle).
            workspace?.activeModel?.requestTool(rest)
        case "action":
            // action <name> [json]: dispatch a workspace action with optional
            // trailing JSON params. Routed NATIVE-FIRST (FifoActionRouting):
            // document-mutating menubar/edit actions (select_all,
            // delete_selection, ...) are native-intercepted — their
            // actions.yaml `effects` are log/if stubs, so the generic panel
            // dispatcher alone would no-op them. FifoActionRouting runs the
            // SAME native ops the menu/keyboard handlers use and falls through
            // to the generic dispatcher (LayersPanel.dispatchYamlAction) for
            // genuine panel / generic-effect actions.
            let ap = rest.split(separator: " ", maxSplits: 1,
                                omittingEmptySubsequences: true).map(String.init)
            guard let name = ap.first, !name.isEmpty else { return }
            var params: [String: Any] = [:]
            if ap.count > 1 {
                let json = ap[1].trimmingCharacters(in: .whitespaces)
                if let data = json.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data),
                   let dict = obj as? [String: Any] {
                    params = dict
                }
            }
            // new_document needs a fresh canvas appended + activated. The
            // active model is gone if there are no canvases yet, so handle it
            // before the activeModel guard (it does not need an active model).
            if name == "new_document" {
                // Document() defaults artboards: []; newEmptyDocument() seeds
                // the at-least-one-artboard invariant, matching
                // JasCommands' File>New (addCanvas(Model(...newEmptyDocument))).
                workspace?.addCanvas(Model(document: Document.newEmptyDocument()))
                return
            }
            guard let model = workspace?.activeModel else { return }
            FifoActionRouting.dispatch(name, model: model, params: params)
        default:
            NSLog("test-fifo: unknown command %@", cmd)
        }
    }
}
