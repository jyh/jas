import SwiftUI

/// Custom menu commands for Jas app (File, Edit, View menus).
public struct JasCommands: Commands {
    public init() {}

    public var body: some Commands {
        CommandMenu("File") {
            Button("New") {
                print("New document")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Open...") {
                print("Open document")
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Save") {
                print("Save document")
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Save As...") {
                print("Save as")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider()

            Button("Quit Jas") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }

        CommandMenu("View") {
            Button("Zoom In") {
                print("Zoom in")
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("Zoom Out") {
                print("Zoom out")
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Fit in Window") {
                print("Fit in window")
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}
