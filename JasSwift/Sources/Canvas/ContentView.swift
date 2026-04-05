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
}

// MARK: - Content View

public struct ContentView: View {
    @State private var currentTool: Tool = .selection
    @State private var canvases: [CanvasEntry] = [
        CanvasEntry(model: JasModel())
    ]
    @State private var selectedTab: UUID?

    public init() {}

    private var activeModel: JasModel {
        if let id = selectedTab, let entry = canvases.first(where: { $0.id == id }) {
            return entry.model
        }
        return canvases.first!.model
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Toolbar on the left
            ToolbarPanel(currentTool: $currentTool)

            // Tabbed canvas area
            TabView(selection: $selectedTab) {
                ForEach(canvases) { entry in
                    CanvasTab(
                        model: entry.model,
                        currentTool: $currentTool,
                        onFocus: { selectedTab = entry.id }
                    )
                    .tabItem {
                        Text(entry.model.isModified ? "\(entry.model.filename) *" : entry.model.filename)
                    }
                    .tag(entry.id)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .overlay {
            FocusedModelProvider(model: activeModel, addCanvas: addCanvas)
        }
        .onAppear {
            if selectedTab == nil {
                selectedTab = canvases.first?.id
            }
        }
    }

    private func addCanvas(_ model: JasModel) {
        let entry = CanvasEntry(model: model)
        canvases.append(entry)
        selectedTab = entry.id
    }
}

// MARK: - Focused model provider (observes the active model for menu state)

struct FocusedModelProvider: View {
    @ObservedObject var model: JasModel
    var addCanvas: (JasModel) -> Void

    var body: some View {
        Color.clear
            .focusedSceneValue(\.jasModel, model)
            .focusedSceneValue(\.hasSelection, !model.document.selection.isEmpty)
            .focusedSceneValue(\.canUndo, model.canUndo)
            .focusedSceneValue(\.canRedo, model.canRedo)
            .focusedSceneValue(\.addCanvas, { newModel in addCanvas(newModel) })
            .allowsHitTesting(false)
    }
}

// MARK: - Canvas Tab (observes model for document updates)

struct CanvasTab: View {
    @ObservedObject var model: JasModel
    @Binding var currentTool: Tool
    var onFocus: (() -> Void)?

    var body: some View {
        CanvasRepresentable(
            document: model.document,
            controller: Controller(model: model),
            currentTool: $currentTool,
            onFocus: onFocus
        )
    }
}

// MARK: - Toolbar Panel

struct ToolbarPanel: View {
    @Binding var currentTool: Tool
    @State private var arrowSlotTool: Tool = .directSelection
    @State private var textSlotTool: Tool = .text
    @State private var shapeSlotTool: Tool = .rect

    private let toolbarWidth: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            // Title
            ZStack {
                Color(nsColor: NSColor(white: 0.6, alpha: 1.0))
                Text("Tools")
                    .font(.system(size: 11))
                    .foregroundColor(.black)
            }
            .frame(width: toolbarWidth, height: 24)

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

            Spacer()
        }
        .frame(width: toolbarWidth)
        .background(Color(nsColor: NSColor(white: 0.25, alpha: 1.0)))
    }
}

