import SwiftUI
import AppKit

// MARK: - Tool enum

public enum Tool: String, CaseIterable {
    case selection
    case directSelection
    case groupSelection
    case pen
    case text
    case textPath
    case line
    case rect
    case polygon
}

// MARK: - Canvas entry for multi-canvas workspace

struct CanvasEntry: Identifiable {
    let id = UUID()
    let model: JasModel
    var position: CGPoint
}

// MARK: - Content View

public struct ContentView: View {
    @State private var currentTool: Tool = .selection
    @State private var toolbarPosition: CGPoint = CGPoint(x: 0, y: 0)
    @State private var canvases: [CanvasEntry] = [
        CanvasEntry(model: JasModel(), position: CGPoint(x: 84, y: 0))
    ]
    @State private var activeIndex: Int = 0

    public init() {}

    private var activeModel: JasModel { canvases[activeIndex].model }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // Workspace background
            Color(nsColor: NSColor(white: 0.235, alpha: 1.0))

            // Canvas subwindows
            ForEach(Array(canvases.enumerated()), id: \.element.id) { index, entry in
                CanvasSubwindow(
                    model: entry.model,
                    controller: Controller(model: entry.model),
                    currentTool: $currentTool,
                    position: $canvases[index].position,
                    bbox: CanvasBoundingBox()
                )
                .onTapGesture { activeIndex = index }
            }

            // Floating toolbar
            FloatingToolbar(
                currentTool: $currentTool,
                position: $toolbarPosition
            )
        }
        .frame(minWidth: 640, minHeight: 480)
        .clipped()
        .focusedSceneValue(\.jasModel, activeModel)
        .focusedSceneValue(\.hasSelection, !activeModel.document.selection.isEmpty)
        .focusedSceneValue(\.canUndo, activeModel.canUndo)
        .focusedSceneValue(\.canRedo, activeModel.canRedo)
        .focusedSceneValue(\.addCanvas, { newModel in
            addCanvas(newModel)
        })
        .background(
            KeyboardShortcutHandler(currentTool: $currentTool, model: activeModel)
        )
    }

    private func addCanvas(_ model: JasModel) {
        let offset = CGFloat(canvases.count) * 30.0
        let position = CGPoint(x: 84 + offset, y: offset)
        canvases.append(CanvasEntry(model: model, position: position))
        activeIndex = canvases.count - 1
    }
}

// MARK: - Floating Toolbar

struct FloatingToolbar: View {
    @Binding var currentTool: Tool
    @Binding var position: CGPoint
    @State private var arrowSlotTool: Tool = .directSelection
    @State private var textSlotTool: Tool = .text
    @State private var shapeSlotTool: Tool = .rect

    private let titleBarHeight: CGFloat = 24
    private let toolbarWidth: CGFloat = 80

    var body: some View {
        let contentHeight: CGFloat = 76
        let totalHeight = titleBarHeight + contentHeight

        VStack(spacing: 0) {
            // Title bar
            ZStack {
                Color(nsColor: NSColor(white: 0.6, alpha: 1.0))
                Text("Tools")
                    .font(.system(size: 11))
                    .foregroundColor(.black)
            }
            .frame(width: toolbarWidth, height: titleBarHeight)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        position.x += value.translation.width
                        position.y += value.translation.height
                    }
            )

            // Tool buttons
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    ToolbarView.toolButton(currentTool: $currentTool, tool: .selection)
                    ToolbarView.toolButtonWithAlternates(
                        currentTool: $currentTool,
                        visibleTool: $arrowSlotTool,
                        alternates: [.directSelection, .groupSelection]
                    )
                }
                HStack(spacing: 2) {
                    ToolbarView.toolButton(currentTool: $currentTool, tool: .pen)
                    ToolbarView.toolButtonWithAlternates(
                        currentTool: $currentTool,
                        visibleTool: $textSlotTool,
                        alternates: [.text, .textPath]
                    )
                }
                HStack(spacing: 2) {
                    ToolbarView.toolButton(currentTool: $currentTool, tool: .line)
                    ToolbarView.toolButtonWithAlternates(
                        currentTool: $currentTool,
                        visibleTool: $shapeSlotTool,
                        alternates: [.rect, .polygon]
                    )
                }
            }
            .padding(4)
            .frame(width: toolbarWidth)
            .background(Color(nsColor: NSColor(white: 0.30, alpha: 1.0)))
        }
        .border(Color(nsColor: NSColor(white: 0.4, alpha: 1.0)), width: 1)
        .frame(width: toolbarWidth, height: totalHeight)
        .position(x: position.x + toolbarWidth / 2, y: position.y + totalHeight / 2)
    }
}

// MARK: - Keyboard shortcuts

struct KeyboardShortcutHandler: NSViewRepresentable {
    @Binding var currentTool: Tool
    var model: JasModel

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onKey = { key, modifiers in
            let hasCmd = modifiers.contains(.command)
            let hasShift = modifiers.contains(.shift)
            if hasCmd && key.lowercased() == "z" {
                if hasShift {
                    model.redo()
                } else {
                    model.undo()
                }
                return
            }
            switch key {
            case "\u{7F}", "\u{F728}":  // Backspace, Forward Delete
                if !model.document.selection.isEmpty {
                    model.snapshot()
                    model.document = model.document.deleteSelection()
                }
            default:
                switch key.lowercased() {
                case "v": currentTool = .selection
                case "a": currentTool = .directSelection
                case "p": currentTool = .pen
                case "t": currentTool = .text
                case "\\": currentTool = .line
                case "m": currentTool = .rect
                default: break
                }
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
    var onKey: ((String, NSEvent.ModifierFlags) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let chars = event.charactersIgnoringModifiers {
            onKey?(chars, event.modifierFlags)
        } else {
            super.keyDown(with: event)
        }
    }
}
