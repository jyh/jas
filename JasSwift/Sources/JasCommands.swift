import SwiftUI
import AppKit

// MARK: - FocusedValue for model access from commands

public struct FocusedModelKey: FocusedValueKey {
    public typealias Value = JasModel
}

public extension FocusedValues {
    var jasModel: JasModel? {
        get { self[FocusedModelKey.self] }
        set { self[FocusedModelKey.self] = newValue }
    }
}

/// Custom menu commands for Jas app (File, Edit, View menus).
public struct JasCommands: Commands {
    @FocusedValue(\.jasModel) private var model

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

        CommandMenu("Edit") {
            Button("Copy") {
                copySelection()
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(model?.document.selection.isEmpty ?? true)
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

    private func copySelection() {
        guard let model = model else { return }
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        var elements: [Element] = []
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            elements.append(elem)
        }
        guard !elements.isEmpty else { return }
        let tempDoc = JasDocument(layers: [JasLayer(children: elements)])
        let svg = documentToSvg(tempDoc)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(svg, forType: .string)
    }
}
