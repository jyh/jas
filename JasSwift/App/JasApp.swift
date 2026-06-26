import SwiftUI
import AppKit
import JasLib

/// App delegate that intercepts quit to prompt for unsaved changes.
///
/// When any canvas model is modified, shows an NSAlert with
/// Cancel / Don't Save / Save / Save All. "Save" saves only the
/// active model; "Save All" saves every modified model. If any
/// Save-As dialog is cancelled (model still modified after save
/// attempt), the quit is aborted.
class JasAppDelegate: NSObject, NSApplicationDelegate {
    var workspace: WorkspaceState?
    /// Strong refs so the DispatchSource isn't deallocated as soon as
    /// `applicationDidFinishLaunching` returns. Each entry is one
    /// installed signal handler.
    private var signalSources: [DispatchSourceSignal] = []

    // Test-only FIFO command channel (gated behind --test-fifo PATH).
    // State lives here because stored properties can't be added in the
    // extension (TestFifo.swift) that owns the logic. All zero / nil on a
    // normal launch — no FIFO is created unless the flag is present.
    var testFifoFd: Int32 = -1
    var testFifoBuffer = Data()
    /// Retained so the main-queue read source isn't cancelled when
    /// applicationDidFinishLaunching returns.
    var testFifoSource: DispatchSourceRead?

    /// Promote the process to a regular foreground app and steal the
    /// menu bar before any window is shown. When we relied on
    /// `WindowGroup`'s `.onAppear` for this, macOS sometimes left the
    /// menu bar on the previously-active app — `.onAppear` fires after
    /// the window is up, by which point another app can already own
    /// the menu bar. `applicationDidFinishLaunching` runs before
    /// scenes appear, so the promotion + activation happens during
    /// the launch handshake.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        // Pin a min content size on every Jas window so the right
        // dock + canvas + toolbar all stay on-screen, even after a
        // Window > Tile or other resize. SwiftUI's `.frame(minWidth:)`
        // doesn't reliably translate into an NSWindow contentMinSize,
        // so the dock chevron / hamburger could fall off the right
        // edge. Apply on launch and again whenever a new window
        // becomes key (covers File > New windows).
        applyContentMinSize()
        // The initial window isn't up yet at didFinishLaunching; apply the
        // optional --title override once it exists.
        DispatchQueue.main.async { JasAppDelegate.applyWindowTitle() }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { _ in
            JasAppDelegate.applyContentMinSize()
            JasAppDelegate.applyWindowTitle()
        }
        // SIGINT (^C from the terminal that launched `swift run Jas`)
        // and SIGTERM (orderly shutdown) bypass the AppDelegate quit
        // path entirely, so the session-save hook never fires. A
        // DispatchSource converts the signal into a main-queue event
        // we can safely run from. `signal(SIGINT, SIG_IGN)` keeps the
        // C-level handler from terminating the process before our
        // dispatch event runs.
        installSessionSaveSignalHandler(signal: SIGINT)
        installSessionSaveSignalHandler(signal: SIGTERM)

        // Test-only deterministic command channel for the GUI harness.
        // Entirely gated behind the flag: with no --test-fifo, nothing is
        // created and normal launch is byte-for-byte unaffected. See
        // TestFifo.swift for the protocol + dispatch.
        if let path = JasAppDelegate.testFifoPath {
            setupTestFifo(path: path)
        }
    }

    private func installSessionSaveSignalHandler(signal sig: Int32) {
        Darwin.signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { [weak self] in
            self?.workspace?.persistSession()
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }

    /// Persist the open canvases on quit. Fires after
    /// applicationShouldTerminate has returned `.terminateNow`, so
    /// we only get here when quit is actually proceeding (cancel /
    /// failed-save paths skip session-save). Best-effort: a failed
    /// session save logs and continues — quit isn't blocked.
    func applicationWillTerminate(_ notification: Notification) {
        workspace?.persistSession()
    }

    private static let minContentSize = NSSize(width: 800, height: 540)
    static func applyContentMinSize() {
        for window in NSApp.windows where window.isVisible {
            window.contentMinSize = minContentSize
        }
    }
    func applyContentMinSize() { JasAppDelegate.applyContentMinSize() }

    /// Optional window-title override from `--title <name>` on the command
    /// line. The OS window owner name is always "Jas", so several instances
    /// (or the menu-bar strips) are ambiguous to a screen-capture / UI-test
    /// harness; a unique title lets it find this window deterministically.
    /// Applied on launch and whenever a window becomes key (File > New).
    static let windowTitleOverride: String? = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--title"), i + 1 < args.count {
            return args[i + 1]
        }
        return nil
    }()
    static func applyWindowTitle() {
        guard let title = windowTitleOverride else { return }
        for window in NSApp.windows where window.isVisible {
            window.title = title
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace = workspace else { return .terminateNow }
        let modified = workspace.modifiedModels
        if modified.isEmpty { return .terminateNow }

        let names = modified.map { "\"\($0.filename)\"" }.joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes to \(names)?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save All")
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:  // Save (active model only)
            if let active = workspace.activeModel, active.isModified {
                ContentView.saveModel(active)
                if active.isModified { return .terminateCancel }
            }
            return .terminateNow
        case .alertSecondButtonReturn:  // Don't Save
            return .terminateNow
        case .alertThirdButtonReturn:  // Cancel
            return .terminateCancel
        default:  // Save All (4th button)
            for model in modified {
                ContentView.saveModel(model)
                if model.isModified { return .terminateCancel }
            }
            return .terminateNow
        }
    }
}

@main
struct JasApp: App {
    @NSApplicationDelegateAdaptor(JasAppDelegate.self) var appDelegate
    @StateObject private var workspace = WorkspaceState()

    var body: some Scene {
        WindowGroup {
            ContentView(workspace: workspace)
                .onAppear {
                    // Activation policy + foreground promotion live in
                    // JasAppDelegate.applicationDidFinishLaunching so
                    // they run before the window is shown — see comment
                    // there for why .onAppear was unreliable.
                    appDelegate.workspace = workspace
                    // Reload last session's canvases. Once restored —
                    // and only the first time, since `.onAppear` can
                    // re-fire on tab/window changes — the existing
                    // tabs are kept and the restore call short-
                    // circuits if there's nothing to read.
                    if workspace.canvases.isEmpty {
                        _ = workspace.restoreSession()
                    }
                    if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
                        ?? URL(string: "file://" + #file)
                            .flatMap({ URL(string: "../../../../assets/brand/icons/AppIcon.icns", relativeTo: $0.deletingLastPathComponent()) }) {
                        NSApp.applicationIconImage = NSImage(contentsOf: icnsURL)
                    }
                }
        }
        .defaultSize(width: 1200, height: 900)
        .commands {
            JasCommands()
            CommandGroup(replacing: .help) { }
        }
    }
}
