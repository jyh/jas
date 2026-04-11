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
    @Published public var workspaceLayout: WorkspaceLayout
    @Published public var appConfig: AppConfig

    public init() {
        let config = AppConfig.load()
        self.appConfig = config
        self.workspaceLayout = WorkspaceLayout.loadOrMigrateWorkspace(config: config)
    }

    public func switchLayout(_ name: String) {
        workspaceLayout.save()
        workspaceLayout = WorkspaceLayout.load(name: name)
        workspaceLayout.name = workspaceLayoutName
        appConfig.activeLayout = name
        appConfig.save()
        workspaceLayout.save()
    }

    public func revertToSaved() {
        guard appConfig.activeLayout != workspaceLayoutName else { return }
        workspaceLayout = WorkspaceLayout.load(name: appConfig.activeLayout)
        workspaceLayout.name = workspaceLayoutName
        workspaceLayout.save()
    }

    public func resetToDefault() {
        workspaceLayout = WorkspaceLayout.named(workspaceLayoutName)
        appConfig.activeLayout = workspaceLayoutName
        appConfig.save()
        workspaceLayout.save()
    }

    public func saveLayoutAs(_ name: String) {
        workspaceLayout.saveAs(name)
        appConfig.registerLayout(name)
        appConfig.activeLayout = name
        appConfig.save()
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
            let dockCollapsed = workspace.workspaceLayout.anchoredDock(.right)?.collapsed ?? false
            let rs = RenderingState.from(workspace.workspaceLayout.panes(), dockCollapsed: dockCollapsed, activeBorderSnap: borderDrag?.snapIdx)
            let snapLines = RenderingState.snapLines(from: snapPreview,
                                                      paneLayout: workspace.workspaceLayout.panes())

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
                ForEach(Array(workspace.workspaceLayout.floating.enumerated()), id: \.offset) { _, fd in
                    FloatingDockView(
                        workspaceLayout: $workspace.workspaceLayout,
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
                workspace.workspaceLayout.ensurePaneLayout(
                    viewportW: geometry.size.width,
                    viewportH: geometry.size.height)
                if workspace.selectedTab == nil {
                    workspace.selectedTab = workspace.canvases.first?.id
                }
            }
            .onChange(of: geometry.size) { newSize in
                workspace.workspaceLayout.panesMut { pl in
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
                          content: { ToolbarPanel(currentTool: $currentTool, model: workspace.activeModel) },
                          paneDrag: $paneDrag, edgeResize: $edgeResize, edgeSnappedCoord: $edgeSnappedCoord, snapPreview: $snapPreview)
        case .canvas:
            PaneFrameView(geo: geo, workspace: workspace, showTitleBar: !(geo.config.doubleClickAction == .maximize && rs.canvasMaximized),
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
        if let rightDock = workspace.workspaceLayout.anchoredDock(.right),
           !rightDock.groups.isEmpty {
            DockPanelView(
                workspaceLayout: $workspace.workspaceLayout,
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
                    workspace.workspaceLayout.panesMut { pl in
                        pl.dragSharedBorder(snapIdx: border.snapIdx, delta: delta)
                    }
                }
            }
            .onEnded { _ in
                borderDrag = nil
                workspace.workspaceLayout.saveIfNeeded()
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
    var model: Model?
    @State private var arrowSlotTool: Tool = .directSelection
    @State private var penSlotTool: Tool = .pen
    @State private var pencilSlotTool: Tool = .pencil
    @State private var textSlotTool: Tool = .typeTool
    @State private var shapeSlotTool: Tool = .rect
    @State private var colorPickerState: ColorPickerState?
    @State private var showColorPicker = false

    private let toolbarWidth: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
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

            // Fill/Stroke indicator
            if let model = model {
                FillStrokeWidget(model: model, onDoubleClick: { forFill in
                    let initial: Color
                    if forFill {
                        initial = model.defaultFill?.color ?? .white
                    } else {
                        initial = model.defaultStroke?.color ?? .black
                    }
                    colorPickerState = ColorPickerState(color: initial, forFill: forFill)
                    showColorPicker = true
                })
                .padding(.top, 8)
                .frame(width: toolbarWidth)

                // Mode buttons: Color, Gradient (disabled), None
                HStack(spacing: 2) {
                    fillModeButton(label: "C", tooltip: "Color") {
                        // Set to color mode (ensure non-nil)
                        if model.fillOnTop {
                            if model.defaultFill == nil {
                                model.defaultFill = Fill(color: .white)
                            }
                        } else {
                            if model.defaultStroke == nil {
                                model.defaultStroke = Stroke(color: .black)
                            }
                        }
                    }
                    fillModeButton(label: "G", tooltip: "Gradient") {
                        // Gradient mode -- not yet implemented
                    }
                    .disabled(true)
                    .opacity(0.4)
                    fillModeButton(label: "/", tooltip: "None") {
                        // Set to none
                        if model.fillOnTop {
                            model.defaultFill = nil
                        } else {
                            model.defaultStroke = nil
                        }
                    }
                }
                .padding(.top, 4)
            }

            Spacer()
        }
        .frame(width: toolbarWidth)
        .background(SwiftUI.Color(nsColor: NSColor(white: 0.25, alpha: 1.0)))
        .sheet(isPresented: $showColorPicker) {
            if let cpState = colorPickerState {
                let originalColor = cpState.color()
                ColorPickerView(
                    state: cpState,
                    onOK: { color in
                        if let model = model {
                            if cpState.forFill {
                                model.defaultFill = Fill(color: color)
                            } else {
                                model.defaultStroke = Stroke(color: color)
                            }
                        }
                        showColorPicker = false
                    },
                    onCancel: {
                        showColorPicker = false
                    },
                    originalColor: originalColor
                )
            }
        }
    }

    private func fillModeButton(label: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SwiftUI.Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 20, height: 16)
                .background(SwiftUI.Color(nsColor: NSColor(white: 0.35, alpha: 1.0)))
                .cornerRadius(2)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

/// Fill/Stroke overlapping squares widget for the toolbar.
struct FillStrokeWidget: View {
    @ObservedObject var model: Model
    var onDoubleClick: (Bool) -> Void

    private let squareSize: CGFloat = 28
    private let offset: CGFloat = 10
    private let totalSize: CGFloat = 46

    var body: some View {
        ZStack {
            // Swap arrow (top-right corner)
            Button(action: swapColors) {
                SwiftUI.Canvas { context, size in
                    // Draw a small swap arrow icon
                    var path = SwiftUI.Path()
                    path.move(to: CGPoint(x: 2, y: 8))
                    path.addLine(to: CGPoint(x: 10, y: 8))
                    path.addLine(to: CGPoint(x: 10, y: 4))
                    path.addLine(to: CGPoint(x: 14, y: 9))
                    path.addLine(to: CGPoint(x: 10, y: 14))
                    path.addLine(to: CGPoint(x: 10, y: 10))
                    path.addLine(to: CGPoint(x: 2, y: 10))
                    path.closeSubpath()
                    context.fill(path, with: .color(.white))
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .position(x: totalSize - 4, y: 4)

            // Default reset (bottom-left corner)
            Button(action: resetDefaults) {
                SwiftUI.Canvas { context, size in
                    // Small squares icon for reset
                    let fillRect = CGRect(x: 0, y: 4, width: 8, height: 8)
                    context.fill(SwiftUI.Path(fillRect), with: .color(.white))
                    let strokeRect = CGRect(x: 4, y: 0, width: 8, height: 8)
                    context.stroke(SwiftUI.Path(strokeRect), with: .color(.white), lineWidth: 1.5)
                }
                .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .position(x: 4, y: totalSize - 4)

            // Background square (behind)
            fillStrokeSquare(isFill: !model.fillOnTop)
                .position(x: offset + squareSize / 2, y: offset + squareSize / 2)

            // Foreground square (on top)
            fillStrokeSquare(isFill: model.fillOnTop)
                .position(x: squareSize / 2, y: squareSize / 2)
        }
        .frame(width: totalSize, height: totalSize)
    }

    @ViewBuilder
    private func fillStrokeSquare(isFill: Bool) -> some View {
        let color: SwiftUI.Color? = isFill
            ? model.defaultFill.map { swiftColor($0.color) }
            : model.defaultStroke.map { swiftColor($0.color) }

        ZStack {
            if let c = color {
                if isFill {
                    // Solid fill square
                    Rectangle()
                        .fill(c)
                        .frame(width: squareSize, height: squareSize)
                        .border(SwiftUI.Color.gray.opacity(0.5), width: 0.5)
                } else {
                    // Stroke square: thick border, transparent center
                    Rectangle()
                        .fill(SwiftUI.Color(nsColor: NSColor(white: 0.25, alpha: 1.0)))
                        .frame(width: squareSize, height: squareSize)
                        .overlay(
                            Rectangle()
                                .stroke(c, lineWidth: 5)
                        )
                }
            } else {
                // None state: white with red diagonal line
                ZStack {
                    Rectangle()
                        .fill(SwiftUI.Color.white)
                        .frame(width: squareSize, height: squareSize)
                    SwiftUI.Path { path in
                        path.move(to: CGPoint(x: 0, y: squareSize))
                        path.addLine(to: CGPoint(x: squareSize, y: 0))
                    }
                    .stroke(SwiftUI.Color.red, lineWidth: 2)
                    .frame(width: squareSize, height: squareSize)
                }
            }
        }
        .onTapGesture(count: 2) {
            onDoubleClick(isFill)
        }
        .onTapGesture(count: 1) {
            // Single click brings this square to front
            model.fillOnTop = isFill
        }
    }

    private func swapColors() {
        let oldFill = model.defaultFill
        let oldStroke = model.defaultStroke
        if let s = oldStroke {
            model.defaultFill = Fill(color: s.color)
        } else {
            model.defaultFill = nil
        }
        if let f = oldFill {
            model.defaultStroke = Stroke(color: f.color)
        } else {
            model.defaultStroke = nil
        }
    }

    private func resetDefaults() {
        model.defaultFill = nil
        model.defaultStroke = Stroke(color: .black)
    }

    private func swiftColor(_ c: Color) -> SwiftUI.Color {
        let (r, g, b, a) = c.toRgba()
        return SwiftUI.Color(nsColor: NSColor(red: r, green: g, blue: b, alpha: a))
    }
}

