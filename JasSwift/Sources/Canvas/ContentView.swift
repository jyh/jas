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
    @Published public var dockLayout: DockLayout
    @Published public var appConfig: AppConfig

    public init() {
        let config = AppConfig.load()
        self.appConfig = config
        self.dockLayout = DockLayout.load(name: config.activeLayout)
    }

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
    @State private var paneDrag: (paneId: PaneId, offX: Double, offY: Double)?
    @State private var borderDrag: (snapIdx: Int, startCoord: Double)?
    @State private var edgeResize: (paneId: PaneId, edge: EdgeSide, startX: Double, startY: Double, startW: Double, startH: Double)?
    @State private var edgeSnappedCoord: Double?
    @State private var hoveredBorder: Int?
    @State private var snapPreview: [SnapConstraint] = []

    public init(workspace: WorkspaceState) {
        self.workspace = workspace
    }

    public var body: some View {
        GeometryReader { geometry in
            let dockCollapsed = workspace.dockLayout.anchoredDock(.right)?.collapsed ?? false
            let rs = RenderingState.from(workspace.dockLayout.panes(), dockCollapsed: dockCollapsed)
            let snapLines = RenderingState.snapLines(from: snapPreview,
                                                      paneLayout: workspace.dockLayout.panes())

            ZStack {
                // Background
                SwiftUI.Color(nsColor: NSColor(white: 0.18, alpha: 1.0))

                // Panes
                ForEach(rs.panes) { geo in
                    if geo.visible {
                        paneView(geo: geo, rs: rs)
                            .frame(width: geo.width, height: geo.height)
                            .position(x: geo.x + geo.width / 2, y: geo.y + geo.height / 2)
                            .zIndex(Double(geo.zIndex))
                    }
                }

                // Shared border handles
                ForEach(rs.borders) { border in
                    let isActive = borderDrag?.snapIdx == border.snapIdx
                        || hoveredBorder == border.snapIdx
                        || (edgeResize != nil && edgeSnappedCoord != nil && {
                            let center = border.isVertical ? border.x + 3 : border.y + 3
                            return abs(center - edgeSnappedCoord!) < 1
                        }())
                    BorderHandleView(border: border, isDragging: isActive, hoveredBorder: $hoveredBorder)
                        .frame(width: border.width, height: border.height)
                        .position(x: border.x + border.width / 2, y: border.y + border.height / 2)
                        .gesture(borderDragGesture(border: border))
                        .zIndex(100)
                }

                // Snap preview lines
                ForEach(snapLines) { line in
                    SwiftUI.Color(nsColor: snapLineColor)
                        .frame(width: line.width, height: line.height)
                        .position(x: line.x + line.width / 2, y: line.y + line.height / 2)
                        .allowsHitTesting(false)
                        .zIndex(200)
                }

                // Floating docks
                ForEach(Array(workspace.dockLayout.floating.enumerated()), id: \.offset) { _, fd in
                    FloatingDockView(
                        dockLayout: $workspace.dockLayout,
                        floatingDock: fd
                    )
                }
            }
            .coordinateSpace(name: "paneContainer")
            .frame(minWidth: 640, minHeight: 480)
            .overlay {
                SwiftUI.Color.clear
                    .focusedSceneValue(\.addCanvas, { newModel in addCanvas(newModel) })
                    .focusedSceneValue(\.workspace, workspace)
                    .allowsHitTesting(false)
            }
            .overlay {
                if let model = workspace.activeModel {
                    FocusedModelProvider(model: model)
                }
            }
            .onAppear {
                workspace.dockLayout.ensurePaneLayout(
                    viewportW: geometry.size.width,
                    viewportH: geometry.size.height)
                if workspace.selectedTab == nil {
                    workspace.selectedTab = workspace.canvases.first?.id
                }
            }
            .onChange(of: geometry.size) { newSize in
                workspace.dockLayout.panesMut { pl in
                    pl.onViewportResize(newW: newSize.width, newH: newSize.height)
                }
            }
        }
    }

    @ViewBuilder
    private func paneView(geo: PaneGeometry, rs: RenderingState) -> some View {
        switch geo.kind {
        case .toolbar:
            PaneFrameView(geo: geo, workspace: workspace, showTitleBar: true,
                          content: { ToolbarPanel(currentTool: $currentTool) },
                          paneDrag: $paneDrag, edgeResize: $edgeResize, edgeSnappedCoord: $edgeSnappedCoord, snapPreview: $snapPreview)
        case .canvas:
            PaneFrameView(geo: geo, workspace: workspace, showTitleBar: !(geo.config.maximizable && rs.canvasMaximized),
                          content: { canvasContent },
                          paneDrag: $paneDrag, edgeResize: $edgeResize, edgeSnappedCoord: $edgeSnappedCoord, snapPreview: $snapPreview)
        case .dock:
            PaneFrameView(geo: geo, workspace: workspace, showTitleBar: true,
                          content: { dockContent },
                          paneDrag: $paneDrag, edgeResize: $edgeResize, edgeSnappedCoord: $edgeSnappedCoord, snapPreview: $snapPreview)
        }
    }

    private var canvasContent: some View {
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

    @ViewBuilder
    private var dockContent: some View {
        if let rightDock = workspace.dockLayout.anchoredDock(.right),
           !rightDock.groups.isEmpty {
            DockPanelView(
                dockLayout: $workspace.dockLayout,
                dockId: rightDock.id,
                edge: .right
            )
        } else {
            SwiftUI.Color.clear
        }
    }

    private func borderDragGesture(border: SharedBorder) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("paneContainer"))
            .onChanged { value in
                let translation = border.isVertical ? value.translation.width : value.translation.height
                let newAccum = Double(translation)
                let prevAccum = borderDrag?.startCoord ?? 0
                let delta = newAccum - prevAccum
                borderDrag = (border.snapIdx, newAccum)
                if abs(delta) > 0.001 {
                    workspace.dockLayout.panesMut { pl in
                        pl.dragSharedBorder(snapIdx: border.snapIdx, delta: delta)
                    }
                }
            }
            .onEnded { _ in
                borderDrag = nil
                workspace.dockLayout.saveIfNeeded()
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

