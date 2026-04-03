import SwiftUI
import AppKit
import MandelbrotLib

@main
struct MandelbrotExplorerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1200, height: 900)
    }
}
