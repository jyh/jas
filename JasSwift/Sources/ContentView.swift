import SwiftUI
import AppKit

// MARK: - Tool enum

public enum Tool: String, CaseIterable {
    case selection
    case directSelection
}

// MARK: - Content View

public struct ContentView: View {
    @State private var currentTool: Tool = .selection
    @State private var canvasPosition: CGPoint = CGPoint(x: 50, y: 50)

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            ToolbarView(currentTool: $currentTool)

            ZStack(alignment: .topLeading) {
                // Workspace background
                Color(nsColor: NSColor(white: 0.235, alpha: 1.0))

                // Embedded canvas subwindow
                CanvasSubwindow(
                    title: "Untitled",
                    position: $canvasPosition,
                    bbox: CanvasBoundingBox()
                )
            }
            .frame(minWidth: 640, minHeight: 480)
            .clipped()
        }
        .background(
            KeyboardShortcutHandler(currentTool: $currentTool)
        )
    }
}

// MARK: - Keyboard shortcuts

struct KeyboardShortcutHandler: NSViewRepresentable {
    @Binding var currentTool: Tool

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onKey = { key in
            switch key.lowercased() {
            case "v": currentTool = .selection
            case "a": currentTool = .directSelection
            default: break
            }
        }
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

class KeyCaptureView: NSView {
    var onKey: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let chars = event.charactersIgnoringModifiers {
            onKey?(chars)
        } else {
            super.keyDown(with: event)
        }
    }
}
