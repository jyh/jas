import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Tool enum

public enum Tool: String, CaseIterable {
    case selection
    case directSelection
    case groupSelection
    case pen
    case addAnchorPoint
    case deleteAnchorPoint
    case anchorPoint
    case pencil
    case pathEraser
    case smooth
    case typeTool
    case typeOnPath
    case line
    case rect
    case roundedRect
    case polygon
    case star
    case lasso
}

// MARK: - Canvas entry for multi-canvas workspace

public struct CanvasEntry: Identifiable {
    public let id = UUID()
    public let model: Model
}

// MARK: - Workspace state (shared with app delegate for quit-save prompt)

public class WorkspaceState: ObservableObject {
    @Published public var canvases: [CanvasEntry] = []
    @Published public var selectedTab: UUID?

    public init() {}

    public var activeModel: Model? {
        if let id = selectedTab, let entry = canvases.first(where: { $0.id == id }) {
            return entry.model
        }
        return canvases.first?.model
    }

    public var modifiedModels: [Model] {
        canvases.compactMap { $0.model.isModified ? $0.model : nil }
    }
}

// MARK: - Content View

public struct ContentView: View {
    @ObservedObject var workspace: WorkspaceState
    @State private var currentTool: Tool = .selection

    public init(workspace: WorkspaceState) {
        self.workspace = workspace
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Toolbar on the left
            ToolbarPanel(currentTool: $currentTool)

            // Tabbed canvas area — SwiftUI's TabView doesn't support closable
            // tabs, so we build a custom tab bar (CanvasTabLabel views in an
            // HStack) above a ZStack that shows only the selected canvas.
            VStack(spacing: 0) {
                if !workspace.canvases.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(workspace.canvases) { entry in
                                CanvasTabLabel(
                                    model: entry.model,
                                    isSelected: workspace.selectedTab == entry.id,
                                    onSelect: { workspace.selectedTab = entry.id },
                                    onClose: { closeCanvas(entry.id) }
                                )
                            }
                        }
                    }
                    .frame(height: 28)
                    .background(SwiftUI.Color(nsColor: NSColor(white: 0.20, alpha: 1.0)))
                }

                // Canvas content
                ZStack {
                    SwiftUI.Color(nsColor: NSColor(white: 0.50, alpha: 1.0))
                    ForEach(workspace.canvases) { entry in
                        if entry.id == workspace.selectedTab {
                            CanvasTab(
                                model: entry.model,
                                currentTool: $currentTool,
                                onFocus: { workspace.selectedTab = entry.id }
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .overlay {
            SwiftUI.Color.clear
                .focusedSceneValue(\.addCanvas, { newModel in addCanvas(newModel) })
                .allowsHitTesting(false)
        }
        .overlay {
            if let model = workspace.activeModel {
                FocusedModelProvider(model: model)
            }
        }
        .onAppear {
            if workspace.selectedTab == nil {
                workspace.selectedTab = workspace.canvases.first?.id
            }
        }
    }

    /// Add a canvas for the given model. If a canvas for the same file
    /// already exists (non-untitled), focus it instead of creating a duplicate.
    private func addCanvas(_ model: Model) {
        if !model.filename.hasPrefix("Untitled-"),
           let existing = workspace.canvases.first(where: { $0.model.filename == model.filename }) {
            workspace.selectedTab = existing.id
            return
        }
        let entry = CanvasEntry(model: model)
        workspace.canvases.append(entry)
        workspace.selectedTab = entry.id
    }

    /// Close a canvas tab, prompting to save unsaved changes.
    ///
    /// Uses NSAlert with Save/Don't Save/Cancel buttons. If the user
    /// chooses Save, we call saveModel which handles both named files and
    /// the Save-As flow for untitled documents. After saving, we re-check
    /// isModified: if still true the user cancelled the Save-As panel and
    /// the tab should remain open.
    private func closeCanvas(_ id: UUID) {
        guard let entry = workspace.canvases.first(where: { $0.id == id }) else { return }
        let model = entry.model
        if model.isModified {
            let alert = NSAlert()
            alert.messageText = "Do you want to save changes to \"\(model.filename)\"?"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertThirdButtonReturn { return }
            if response == .alertFirstButtonReturn {
                ContentView.saveModel(model)
                if model.isModified { return }
            }
        }
        workspace.canvases.removeAll { $0.id == id }
        if workspace.selectedTab == id {
            workspace.selectedTab = workspace.canvases.first?.id
        }
    }

    public static func saveModel(_ model: Model) {
        JasCommands.saveModel(model)
    }
}

// MARK: - Tab label with close button

struct CanvasTabLabel: View {
    @ObservedObject var model: Model
    var isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            SwiftUI.Text(model.isModified ? "\(model.filename) *" : model.filename)
                .font(.system(size: 11))
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isSelected
            ? SwiftUI.Color(nsColor: NSColor(white: 0.35, alpha: 1.0))
            : SwiftUI.Color(nsColor: NSColor(white: 0.25, alpha: 1.0)))
        .foregroundColor(.white)
        .onTapGesture { onSelect() }
    }
}

// MARK: - Focused model provider (observes the active model for menu state)

struct FocusedModelProvider: View {
    @ObservedObject var model: Model

    var body: some View {
        SwiftUI.Color.clear
            .focusedSceneValue(\.jasModel, model)
            .focusedSceneValue(\.hasSelection, !model.document.selection.isEmpty)
            .focusedSceneValue(\.canUndo, model.canUndo)
            .focusedSceneValue(\.canRedo, model.canRedo)
            .allowsHitTesting(false)
    }
}

// MARK: - Canvas Tab (observes model for document updates)

struct CanvasTab: View {
    @ObservedObject var model: Model
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
    @State private var penSlotTool: Tool = .pen
    @State private var pencilSlotTool: Tool = .pencil
    @State private var textSlotTool: Tool = .typeTool
    @State private var shapeSlotTool: Tool = .rect

    private let toolbarWidth: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            // Title
            ZStack {
                SwiftUI.Color(nsColor: NSColor(white: 0.6, alpha: 1.0))
                SwiftUI.Text("Tools")
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
                    ToolbarView.toolButtonWithAlternates(
                        currentTool: $currentTool,
                        visibleTool: $penSlotTool,
                        alternates: [.pen, .addAnchorPoint, .deleteAnchorPoint, .anchorPoint]
                    )
                    ToolbarView.toolButtonWithAlternates(
                        currentTool: $currentTool,
                        visibleTool: $pencilSlotTool,
                        alternates: [.pencil, .pathEraser, .smooth]
                    )
                }
                HStack(spacing: 2) {
                    ToolbarView.toolButtonWithAlternates(
                        currentTool: $currentTool,
                        visibleTool: $textSlotTool,
                        alternates: [.typeTool, .typeOnPath]
                    )
                    ToolbarView.toolButton(currentTool: $currentTool, tool: .line)
                }
                HStack(spacing: 2) {
                    ToolbarView.toolButtonWithAlternates(
                        currentTool: $currentTool,
                        visibleTool: $shapeSlotTool,
                        alternates: [.rect, .roundedRect, .polygon, .star]
                    )
                    ToolbarView.toolButton(currentTool: $currentTool, tool: .lasso)
                }
            }
            .padding(4)
            .frame(width: toolbarWidth)
            .background(SwiftUI.Color(nsColor: NSColor(white: 0.30, alpha: 1.0)))

            Spacer()
        }
        .frame(width: toolbarWidth)
        .background(SwiftUI.Color(nsColor: NSColor(white: 0.25, alpha: 1.0)))
    }
}

