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
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    appDelegate.workspace = workspace
                }
        }
        .defaultSize(width: 1200, height: 900)
        .commands {
            JasCommands()
        }
    }
}
