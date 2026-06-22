import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Tool enum

public enum Tool: String, CaseIterable {
    case selection
    case partialSelection
    case interiorSelection
    case magicWand
    case pen
    case addAnchorPoint
    case deleteAnchorPoint
    case anchorPoint
    case pencil
    case paintbrush
    case blobBrush
    case pathEraser
    case smooth
    case typeTool
    case typeOnPath
    case line
    case rect
    case roundedRect
    case ellipse
    case polygon
    case star
    case lasso
    case scale
    case rotate
    case shear
    case hand
    case zoom
    case artboard
    case eyedropper
}

/// Map a Tool enum case to the matching workspace/tools/*.yaml
/// filename stem. Used to look up per-tool workspace metadata such
/// as the tool_options_dialog field (PAINTBRUSH_TOOL.md §Tool
/// options). Returns nil for native-only tools that have no YAML
/// spec (Type / TypeOnPath).
func toolYamlId(_ tool: Tool) -> String? {
    switch tool {
    case .selection: return "selection"
    case .partialSelection: return "partial_selection"
    case .interiorSelection: return "interior_selection"
    case .magicWand: return "magic_wand"
    case .pen: return "pen"
    case .addAnchorPoint: return "add_anchor_point"
    case .deleteAnchorPoint: return "delete_anchor_point"
    case .anchorPoint: return "anchor_point"
    case .pencil: return "pencil"
    case .paintbrush: return "paintbrush"
    case .blobBrush: return "blob_brush"
    case .pathEraser: return "path_eraser"
    case .smooth: return "smooth"
    case .line: return "line"
    case .rect: return "rect"
    case .roundedRect: return "rounded_rect"
    case .ellipse: return "ellipse"
    case .polygon: return "polygon"
    case .star: return "star"
    case .lasso: return "lasso"
    case .scale: return "scale"
    case .rotate: return "rotate"
    case .shear: return "shear"
    case .hand: return "hand"
    case .zoom: return "zoom"
    case .artboard: return "artboard"
    case .eyedropper: return "eyedropper"
    case .typeTool, .typeOnPath: return nil
    }
}

/// Map a bundle ``state.active_tool`` string to the native ``Tool``
/// enum. These are the tool identifiers used by the compiled
/// workspace.json toolbar — the ``select_tool`` action params, the
/// ``bind.checked`` ``mem(...)`` lists, and the tool-alternates
/// flyout's ``set: { active_tool }`` writes. They differ from
/// ``toolYamlId`` for a few cases (``add_anchor`` vs
/// ``add_anchor_point``, ``type`` vs ``type``-on-path, ``blob_brush``,
/// etc.) so the mapping is spelled out explicitly. Returns nil for an
/// unknown string. Inverse of ``yamlToolString``.
func toolFromYamlString(_ s: String) -> Tool? {
    switch s {
    case "selection": return .selection
    case "partial_selection": return .partialSelection
    case "interior_selection": return .interiorSelection
    case "magic_wand": return .magicWand
    case "pen": return .pen
    case "add_anchor": return .addAnchorPoint
    case "delete_anchor": return .deleteAnchorPoint
    case "anchor_point": return .anchorPoint
    case "pencil": return .pencil
    case "paintbrush": return .paintbrush
    case "blob_brush": return .blobBrush
    case "path_eraser": return .pathEraser
    case "smooth": return .smooth
    case "type": return .typeTool
    case "type_on_path": return .typeOnPath
    case "line": return .line
    case "rect": return .rect
    case "rounded_rect": return .roundedRect
    case "ellipse": return .ellipse
    case "polygon": return .polygon
    case "star": return .star
    case "lasso": return .lasso
    case "scale": return .scale
    case "rotate": return .rotate
    case "shear": return .shear
    case "hand": return .hand
    case "zoom": return .zoom
    case "artboard": return .artboard
    case "eyedropper": return .eyedropper
    default: return nil
    }
}

/// Map a native ``Tool`` to the bundle ``state.active_tool`` string.
/// Used to seed the toolbar's eval context so ``bind.checked`` (which
/// reads ``state.active_tool``) highlights the slot matching the live
/// canvas tool. Inverse of ``toolFromYamlString``.
func yamlToolString(_ tool: Tool) -> String {
    switch tool {
    case .selection: return "selection"
    case .partialSelection: return "partial_selection"
    case .interiorSelection: return "interior_selection"
    case .magicWand: return "magic_wand"
    case .pen: return "pen"
    case .addAnchorPoint: return "add_anchor"
    case .deleteAnchorPoint: return "delete_anchor"
    case .anchorPoint: return "anchor_point"
    case .pencil: return "pencil"
    case .paintbrush: return "paintbrush"
    case .blobBrush: return "blob_brush"
    case .pathEraser: return "path_eraser"
    case .smooth: return "smooth"
    case .typeTool: return "type"
    case .typeOnPath: return "type_on_path"
    case .line: return "line"
    case .rect: return "rect"
    case .roundedRect: return "rounded_rect"
    case .ellipse: return "ellipse"
    case .polygon: return "polygon"
    case .star: return "star"
    case .lasso: return "lasso"
    case .scale: return "scale"
    case .rotate: return "rotate"
    case .shear: return "shear"
    case .hand: return "hand"
    case .zoom: return "zoom"
    case .artboard: return "artboard"
    case .eyedropper: return "eyedropper"
    }
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
    @Published public var theme: Theme

    public init() {
        let config = AppConfig.load()
        self.appConfig = config
        self.workspaceLayout = WorkspaceLayout.loadOrMigrateWorkspace(config: config)
        self.theme = resolveAppearance(config.activeAppearance)
        WorkspaceState.installRecentColorsBridge()
    }

    /// Mirror model.recentColors into the YAML panel.recent_colors of
    /// every panel that defines it. Fires after any
    /// ColorPanel.pushRecentColor commit so a native-code push (Color
    /// Panel slider/hex/recent click) flows into the Swatches Panel
    /// YAML state, and a YAML push (Swatches Panel swatch click via
    /// list_push) flows back into the Color Panel via the listener
    /// the list_push handler triggers. Mirrors Python jas
    /// _setup_recent_colors_bridge.
    private static var _recentColorsBridgeInstalled = false
    private static let _recentColorsBridgeLock = NSLock()
    package static func installRecentColorsBridge() {
        // Atomic check-then-set: parallel callers (e.g. concurrent
        // tests) must not both pass the guard and register duplicate
        // listeners. The check and the flip happen under one lock.
        _recentColorsBridgeLock.lock()
        if _recentColorsBridgeInstalled {
            _recentColorsBridgeLock.unlock()
            return
        }
        _recentColorsBridgeInstalled = true
        _recentColorsBridgeLock.unlock()
        ColorPanel.addRecentColorsListener { model, _ in
            for pid in ["color_panel_content", "swatches_panel_content"] {
                if model.stateStore.getPanel(pid, "recent_colors") != nil {
                    model.stateStore.setPanel(
                        pid, "recent_colors", model.recentColors)
                }
            }
        }
    }

    public func switchAppearance(_ name: String) {
        objectWillChange.send()
        theme = resolveAppearance(name)
        toolbarCheckedBg = theme.buttonChecked
        toolbarIconColor = theme.text
        appConfig.activeAppearance = name
        appConfig.save()
    }

    public func switchLayout(_ name: String) {
        workspaceLayout.save()
        workspaceLayout = WorkspaceLayout.load(name: name)
        workspaceLayout.name = workspaceLayoutName
        appConfig.activeLayout = name
        appConfig.save()
        workspaceLayout.save()
        switchAppearance(workspaceLayout.appearance)
    }

    public func revertToSaved() {
        guard appConfig.activeLayout != workspaceLayoutName else { return }
        workspaceLayout = WorkspaceLayout.load(name: appConfig.activeLayout)
        workspaceLayout.name = workspaceLayoutName
        workspaceLayout.save()
    }

    public func resetToDefault() {
        let vw = workspaceLayout.panes()?.viewportWidth ?? 1200
        let vh = workspaceLayout.panes()?.viewportHeight ?? 800
        workspaceLayout = WorkspaceLayout.named(workspaceLayoutName)
        workspaceLayout.ensurePaneLayout(viewportW: vw, viewportH: vh)
        appConfig.activeLayout = workspaceLayoutName
        appConfig.save()
        workspaceLayout.save()
    }

    public func saveLayoutAs(_ name: String) {
        workspaceLayout.appearance = appConfig.activeAppearance
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
    @State private var paneState = PaneInteractionState()
    @State private var yamlDialogState: YamlDialogState?

    public init(workspace: WorkspaceState) {
        self.workspace = workspace
    }

    public var body: some View {
        GeometryReader { geometry in
            let dockCollapsed = workspace.workspaceLayout.anchoredDock(.right)?.collapsed ?? false
            let rs = RenderingState.from(workspace.workspaceLayout.panes(), dockCollapsed: dockCollapsed, activeBorderSnap: paneState.borderDrag?.snapIdx)
            let snapLines = RenderingState.snapLines(from: paneState.snapPreview,
                                                      paneLayout: workspace.workspaceLayout.panes())

            ZStack {
                // Background
                SwiftUI.Color(nsColor: workspace.theme.windowBg)

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
                    let isActive = paneState.borderDrag?.snapIdx == border.snapIdx
                        || paneState.hoveredBorder == border.snapIdx
                        || (paneState.edgeResize != nil && paneState.edgeSnappedCoord != nil && {
                            let center = border.isVertical ? border.x + 3 : border.y + 3
                            return abs(center - paneState.edgeSnappedCoord!) < 1
                        }())
                    BorderHandleView(border: border, isDragging: isActive, hoveredBorder: $paneState.hoveredBorder)
                        .frame(width: border.width, height: border.height)
                        .position(x: border.x + border.width / 2, y: border.y + border.height / 2)
                        .gesture(borderDragGesture(border: border))
                        .zIndex(100)
                }

                // Snap preview lines
                ForEach(snapLines) { line in
                    SwiftUI.Color(nsColor: workspace.theme.snapPreview)
                        .frame(width: line.width, height: line.height)
                        .position(x: line.x + line.width / 2, y: line.y + line.height / 2)
                        .allowsHitTesting(false)
                        .zIndex(200)
                }

                // Floating docks
                ForEach(Array(workspace.workspaceLayout.floating.enumerated()), id: \.offset) { _, fd in
                    FloatingDockView(
                        workspaceLayout: $workspace.workspaceLayout,
                        floatingDock: fd,
                        theme: workspace.theme,
                        model: workspace.activeModel
                    )
                }
            }
            .coordinateSpace(name: "paneContainer")
            // Catch dock-tab / dock-grip drags that release outside any
            // dock area (i.e. on the canvas) and convert the drop into
            // a detach-into-floating-dock at the cursor. Without this
            // the drag visually moves the tab but the drop is a no-op
            // — the user can't pop a panel out of the dock. Mirrors
            // OCaml's canvas-side drop-handler hook in dock_panel.ml.
            .onDrop(of: [dockDragUTType], delegate: DockDetachDropDelegate(
                workspaceLayout: $workspace.workspaceLayout))
            .frame(minWidth: 640, minHeight: 480)
            .overlay {
                SwiftUI.Color.clear
                    .focusedSceneValue(\.addCanvas, { newModel in addCanvas(newModel) })
                    .focusedSceneValue(\.workspace, workspace)
                    .focusedSceneValue(\.activeAppearance, workspace.appConfig.activeAppearance)
                    .focusedSceneValue(\.openYamlDialog, { dialogId in
                        openYamlDialogFromMenu(dialogId)
                    })
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
            .overlay {
                YamlDialogOverlay(
                    dialogState: $yamlDialogState,
                    theme: workspace.theme,
                    outerScope: { buildDialogOuterScope() },
                    model: workspace.activeModel,
                    onDismiss: {
                        // Keep the store's dialog tracker in sync with
                        // the overlay binding — otherwise re-opening
                        // the same dialog would be a no-op transition
                        // and the bridge in DockPanelView wouldn't fire.
                        workspace.activeModel?.stateStore.closeDialog()
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func paneView(geo: PaneGeometry, rs: RenderingState) -> some View {
        switch geo.kind {
        case .toolbar:
            // STEP A (toolbar YAML migration): the tool grid renders
            // from the compiled bundle (workspace.json layout →
            // toolbar_pane → tool_grid) via the generic YamlElementView,
            // mirroring Rust's YamlToolbarContent. The native
            // ToolbarPanel below is intentionally left in the file but
            // no longer mounted — Step B deletes it after GUI
            // verification, keeping this reversible.
            //
            // The fill/stroke widget under the grid stays native
            // (FillStrokeWidget): the bundle's toolbar_pane content does
            // carry a fill/stroke node, but it relies on color_swatch
            // actions (open_color_picker / swap_fill_stroke /
            // reset_fill_stroke / set_fill_type_* / set_fill_none) that
            // are not yet wired in Swift — a separate increment.
            PaneFrameView(geo: geo, workspace: workspace, showTitleBar: true,
                          content: {
                              BundleToolbarPane(
                                  currentTool: $currentTool,
                                  model: workspace.activeModel,
                                  theme: workspace.theme,
                                  yamlDialogState: $yamlDialogState,
                                  onOpenColorPicker: { forFill in openToolbarColorPicker(forFill: forFill) }
                              )
                              // TODO(toolbar-dblclick): deferred cross-app
                              // increment — double-clicking a tool icon
                              // should open its tool_options_dialog /
                              // tool_options_panel (the prior native
                              // onOpenToolOptions path). Not part of Step A.
                          },
                          paneDrag: $paneState.paneDrag, edgeResize: $paneState.edgeResize, edgeSnappedCoord: $paneState.edgeSnappedCoord, snapPreview: $paneState.snapPreview)
        case .canvas:
            PaneFrameView(geo: geo, workspace: workspace, showTitleBar: !(geo.config.doubleClickAction == .maximize && rs.canvasMaximized),
                          content: { canvasContent },
                          paneDrag: $paneState.paneDrag, edgeResize: $paneState.edgeResize, edgeSnappedCoord: $paneState.edgeSnappedCoord, snapPreview: $paneState.snapPreview)
        case .dock:
            PaneFrameView(geo: geo, workspace: workspace, showTitleBar: true,
                          content: { dockContent },
                          paneDrag: $paneState.paneDrag, edgeResize: $paneState.edgeResize, edgeSnappedCoord: $paneState.edgeSnappedCoord, snapPreview: $paneState.snapPreview)
        }
    }

    /// Open the color picker for the toolbar's fill/stroke widget,
    /// seeding the dialog with the active model's default fill / stroke.
    /// Extracted from the prior ToolbarPanel.onOpenColorPicker closure so
    /// the bundle-driven toolbar's native FillStrokeWidget keeps the same
    /// behavior.
    private func openToolbarColorPicker(forFill: Bool) {
        var liveState: [String: Any] = WorkspaceData.load()?.stateDefaults() ?? [:]
        if let model = workspace.activeModel {
            if let fill = model.defaultFill {
                liveState["fill_color"] = "#" + fill.color.toHex()
            }
            if let stroke = model.defaultStroke {
                liveState["stroke_color"] = "#" + stroke.color.toHex()
            }
        }
        yamlDialogState = openYamlDialog(
            dialogId: "color_picker",
            rawParams: ["target": forFill ? "fill" : "stroke"],
            liveState: liveState
        )
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
                                theme: workspace.theme,
                                onSelect: { workspace.selectedTab = entry.id },
                                onClose: { closeCanvas(entry.id) }
                            )
                        }
                    }
                }
                .frame(height: 28)
                .background(SwiftUI.Color(nsColor: workspace.theme.paneBgDark))
            }

            ZStack(alignment: .topTrailing) {
                SwiftUI.Color(nsColor: workspace.theme.windowBg)
                ForEach(workspace.canvases) { entry in
                    if entry.id == workspace.selectedTab {
                        CanvasTab(
                            model: entry.model,
                            currentTool: $currentTool,
                            onFocus: { workspace.selectedTab = entry.id }
                        )
                    }
                }
                if workspace.canvases.isEmpty {
                    if let logoURL = URL(string: "file://" + #file)
                        .flatMap({ URL(string: "../../../assets/brand/icons/icon_256.png", relativeTo: $0.deletingLastPathComponent()) }),
                       let img = NSImage(contentsOf: logoURL) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 270, height: 120)
                            .opacity(0.25)
                            .padding([.top, .trailing], 10)
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
                edge: .right,
                theme: workspace.theme,
                model: workspace.activeModel,
                yamlDialogState: $yamlDialogState
            )
        } else {
            SwiftUI.Color.clear
        }
    }

    /// Build the ``panel`` + ``active_document`` dictionary surfaced to
    /// the active dialog's render-time bind expressions. Recomputed on
    /// each overlay render so live model / panel-state changes are
    /// visible without tearing down the dialog.
    ///
    /// The Artboard Options Dialogue consumes this in two shapes:
    /// - ``panel.reference_point`` — the reference_point_widget's
    ///   selected anchor, cross-referenced by the x_rp / y_rp computed
    ///   props' getter / setter lambdas (handled by store.getDialog /
    ///   setDialog which read their own outer scope).
    /// - ``active_document.artboards_count`` — the "Artboards: N"
    ///   label at the dialog's bottom and the Delete button's
    ///   ``bind.disabled: active_document.artboards_count <= 1``.
    private func buildDialogOuterScope() -> [String: Any] {
        guard let model = workspace.activeModel else { return [:] }
        let store = model.stateStore
        let abPanel = store.getPanelState("artboards")
        let abSel = (abPanel["artboards_panel_selection"] as? [Any])?
            .compactMap { $0 as? String } ?? []
        let activeDoc = buildActiveDocumentView(
            model: model,
            layersPanelSelection: [],
            artboardsPanelSelection: abSel
        )
        return [
            "active_document": activeDoc,
            "panel": abPanel,
        ]
    }

    private func borderDragGesture(border: SharedBorder) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("paneContainer"))
            .onChanged { value in
                let translation = border.isVertical ? value.translation.width : value.translation.height
                let newAccum = Double(translation)
                let prevAccum = paneState.borderDrag?.startCoord ?? 0
                let delta = newAccum - prevAccum
                paneState.borderDrag = (border.snapIdx, newAccum)
                if abs(delta) > 0.001 {
                    workspace.workspaceLayout.panesMut { pl in
                        pl.dragSharedBorder(snapIdx: border.snapIdx, delta: delta)
                    }
                }
            }
            .onEnded { _ in
                paneState.borderDrag = nil
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

    /// Open a YAML dialog by id from a menu command. Builds liveState
    /// from workspace defaults and threads `active_document` into the
    /// outer scope so init: expressions can read persisted document
    /// fields (PRINT.md §Phase 1B; matches the Rust dispatch path).
    private func openYamlDialogFromMenu(_ dialogId: String) {
        guard let model = workspace.activeModel else { return }
        var liveState: [String: Any] = WorkspaceData.load()?.stateDefaults() ?? [:]
        if let fill = model.defaultFill {
            liveState["fill_color"] = "#" + fill.color.toHex()
        }
        if let stroke = model.defaultStroke {
            liveState["stroke_color"] = "#" + stroke.color.toHex()
        }
        let outer: [String: Any] = [
            "active_document": buildActiveDocumentView(model: model)
        ]
        yamlDialogState = openYamlDialogWithOuter(
            dialogId: dialogId,
            rawParams: [:],
            liveState: liveState,
            outerScope: outer
        )
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
    var theme: Theme
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
                    .foregroundColor(SwiftUI.Color(nsColor: theme.textButton))
            }
            .buttonStyle(.plain)
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isSelected
            ? SwiftUI.Color(nsColor: theme.tabActive)
            : SwiftUI.Color(nsColor: theme.tabInactive))
        .foregroundColor(SwiftUI.Color(nsColor: theme.text))
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

// MARK: - Bundle-driven Toolbar Pane (Step A)

/// Toolbar pane that renders the tool grid from the compiled bundle
/// (workspace.json layout → toolbar_pane → tool_grid) via the generic
/// ``YamlElementView``, then the native fill/stroke widget below it.
/// Mirrors Rust's ``YamlToolbarContent``.
///
/// Active-tool unification: the canvas tool (``currentTool`` @State in
/// ContentView) is the single source of truth. The grid's eval context
/// seeds ``state.active_tool`` from it so ``bind.checked`` highlights
/// the live slot. A ``select_tool`` click routes through
/// ``onWidgetAction`` and sets ``currentTool`` (and mirrors it into the
/// store). The tool-alternates flyout's ``set: { active_tool }`` write
/// fires the ``apply_active_tool`` platform effect, which calls
/// ``model.onActiveToolChange`` — installed here — to set
/// ``currentTool`` from the bundle tool string.
struct BundleToolbarPane: View {
    @Binding var currentTool: Tool
    var model: Model?
    var theme: Theme
    @Binding var yamlDialogState: YamlDialogState?
    var onOpenColorPicker: ((Bool) -> Void)?

    var body: some View {
        if let model = model {
            BundleToolbarPaneBody(
                currentTool: $currentTool,
                model: model,
                theme: theme,
                yamlDialogState: $yamlDialogState,
                onOpenColorPicker: onOpenColorPicker
            )
        } else {
            // No open document: render the grid against fresh defaults
            // with a throwaway model so the toolbar is still visible.
            BundleToolbarPaneBody(
                currentTool: $currentTool,
                model: Model(),
                theme: theme,
                yamlDialogState: $yamlDialogState,
                onOpenColorPicker: onOpenColorPicker
            )
        }
    }
}

/// Inner observer: holds the non-optional ``model`` as @ObservedObject so
/// store-driven writes (panelStateVersion) re-render the grid.
private struct BundleToolbarPaneBody: View {
    @Binding var currentTool: Tool
    @ObservedObject var model: Model
    var theme: Theme
    @Binding var yamlDialogState: YamlDialogState?
    var onOpenColorPicker: ((Bool) -> Void)?

    private let toolbarWidth: CGFloat = 80

    var body: some View {
        // Re-render when a widget commits a store write (e.g. the
        // alternates flyout). currentTool is @State upstream, so a
        // select_tool click already re-renders; this also catches the
        // flyout path that mutates the store.
        _ = model.panelStateVersion
        let capturedModel = model
        return VStack(spacing: 0) {
            toolGridView
                .padding(4)
                .frame(width: toolbarWidth)
                .background(SwiftUI.Color(nsColor: theme.paneBg))

            // Native fill/stroke widget (kept until the bundle's
            // color_swatch fill/stroke actions are wired — separate
            // increment). Matches the prior ToolbarPanel layout.
            FillStrokeWidget(model: capturedModel, onDoubleClick: { forFill in
                onOpenColorPicker?(forFill)
            })
            .padding(.top, 8)
            .frame(width: toolbarWidth)

            HStack(spacing: 2) {
                toolbarModeButton(label: "C", tooltip: "Color", iconName: "fill_solid") {
                    if capturedModel.fillOnTop {
                        if capturedModel.defaultFill == nil {
                            capturedModel.defaultFill = Fill(color: .white)
                        }
                    } else {
                        if capturedModel.defaultStroke == nil {
                            capturedModel.defaultStroke = Stroke(color: .black)
                        }
                    }
                }
                toolbarModeButton(label: "G", tooltip: "Gradient", iconName: "fill_gradient") {
                    // Gradient mode -- not yet implemented
                }
                .disabled(true)
                .opacity(0.4)
                toolbarModeButton(label: "/", tooltip: "None", iconName: "color_none") {
                    if capturedModel.fillOnTop {
                        capturedModel.defaultFill = nil
                    } else {
                        capturedModel.defaultStroke = nil
                    }
                }
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(width: toolbarWidth)
        .background(SwiftUI.Color(nsColor: theme.paneBgDark))
        .onAppear {
            // Install the active-tool mirror so the alternates flyout's
            // set:{active_tool} write switches the live canvas tool.
            installActiveToolMirror(on: capturedModel)
            // Seed the store so bind.checked resolves consistently.
            capturedModel.stateStore.set("active_tool", yamlToolString(currentTool))
        }
        .onChange(of: currentTool) { newTool in
            capturedModel.stateStore.set("active_tool", yamlToolString(newTool))
        }
    }

    /// Render the bundle's tool_grid element via the generic renderer.
    @ViewBuilder
    private var toolGridView: some View {
        if let grid = WorkspaceData.load()?.toolGrid() {
            let ctx = buildToolbarContext()
            let capturedModel = model
            let dialogBinding = $yamlDialogState
            // select_tool arrives as a widget-level `action:` on each
            // icon_button → handleWidgetClick → onWidgetAction. Map the
            // bundle tool string onto the native Tool and set
            // currentTool (the canvas source of truth), mirroring it
            // into the store so bind.checked re-evaluates.
            YamlElementView(
                element: grid,
                context: ctx,
                model: capturedModel,
                onWidgetAction: { actionName, params in
                    guard actionName == "select_tool" else { return }
                    guard let toolStr = params["tool"] as? String,
                          let tool = toolFromYamlString(toolStr) else { return }
                    currentTool = tool
                    capturedModel.stateStore.set("active_tool", toolStr)
                },
                theme: theme,
                onStoreDialogOpened: {
                    if let newState = yamlDialogStateFromStore(capturedModel.stateStore) {
                        dialogBinding.wrappedValue = newState
                    }
                }
            )
        } else {
            SwiftUI.Text("Toolbar not found")
                .foregroundColor(SwiftUI.Color(nsColor: theme.textDim))
        }
    }

    /// Build the eval context for the tool grid: live state with
    /// active_tool overridden to the current canvas tool, plus icons +
    /// theme colors so SVG glyphs and checked-bg resolve.
    private func buildToolbarContext() -> [String: Any] {
        let ws = WorkspaceData.load()
        var stateMap = ws?.stateDefaults() ?? [:]
        stateMap["active_tool"] = yamlToolString(currentTool)
        let icons = ws?.icons() ?? [:]
        let themeColors: [String: Any] = {
            guard let t = ws?.theme(),
                  let base = t["base"] as? [String: Any],
                  let colors = base["colors"] as? [String: Any] else { return [:] }
            return colors
        }()
        let themeSizes: [String: Any] = {
            guard let t = ws?.theme(),
                  let base = t["base"] as? [String: Any],
                  let sizes = base["sizes"] as? [String: Any] else { return [:] }
            return sizes
        }()
        return [
            "state": stateMap,
            "icons": icons,
            "theme": ["colors": themeColors, "sizes": themeSizes] as [String: Any],
        ]
    }

    private func installActiveToolMirror(on model: Model) {
        model.onActiveToolChange = { toolStr in
            if let tool = toolFromYamlString(toolStr) {
                currentTool = tool
            }
        }
    }

    /// Fill/stroke mode button (Color / Gradient / None), preserving the
    /// prior ToolbarPanel.fillModeButton appearance.
    private func toolbarModeButton(
        label: String, tooltip: String, iconName: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                SwiftUI.Color(nsColor: theme.buttonChecked)
                if WorkspaceIconCache.shared.lookup(iconName) != nil {
                    WorkspaceIcon(name: iconName, size: 14, tint: theme.text)
                } else {
                    SwiftUI.Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(SwiftUI.Color(nsColor: theme.text))
                }
            }
            .frame(width: 20, height: 16)
            .cornerRadius(2)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

// MARK: - Toolbar Panel

struct ToolbarPanel: View {
    @Binding var currentTool: Tool
    var model: Model?
    var theme: Theme
    var onOpenColorPicker: ((Bool) -> Void)?
    var onOpenToolOptions: ((Tool) -> Void)?
    @State private var arrowSlotTool: Tool = .partialSelection
    @State private var penSlotTool: Tool = .pen
    @State private var pencilSlotTool: Tool = .pencil
    @State private var textSlotTool: Tool = .typeTool
    @State private var shapeSlotTool: Tool = .rect
    @State private var transformSlotTool: Tool = .scale
    @State private var navSlotTool: Tool = .hand

    private let toolbarWidth: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            // Tool buttons
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    ToolbarView.toolButton(currentTool: $currentTool, tool: .selection,
                                           onRequestOptions: onOpenToolOptions)
                    ToolbarView.toolButtonWithAlternates(
                        currentTool: $currentTool,
                        visibleTool: $arrowSlotTool,
                        alternates: [.partialSelection, .interiorSelection, .magicWand],
                        onRequestOptions: onOpenToolOptions
                    )
                }
                HStack(spacing: 2) {
                    ToolbarView.toolButtonWithAlternates(
                        currentTool: $currentTool,
                        visibleTool: $penSlotTool,
                        alternates: [.pen, .addAnchorPoint, .deleteAnchorPoint, .anchorPoint],
                        onRequestOptions: onOpenToolOptions
                    )
                    ToolbarView.toolButtonWithAlternates(
                        currentTool: $currentTool,
                        visibleTool: $pencilSlotTool,
                        alternates: [.pencil, .paintbrush, .blobBrush, .pathEraser, .smooth],
                        onRequestOptions: onOpenToolOptions
                    )
                }
                HStack(spacing: 2) {
                    ToolbarView.toolButtonWithAlternates(
                        currentTool: $currentTool,
                        visibleTool: $textSlotTool,
                        alternates: [.typeTool, .typeOnPath],
                        onRequestOptions: onOpenToolOptions
                    )
                    ToolbarView.toolButton(currentTool: $currentTool, tool: .line,
                                           onRequestOptions: onOpenToolOptions)
                }
                HStack(spacing: 2) {
                    ToolbarView.toolButtonWithAlternates(
                        currentTool: $currentTool,
                        visibleTool: $shapeSlotTool,
                        alternates: [.rect, .roundedRect, .ellipse, .polygon, .star],
                        onRequestOptions: onOpenToolOptions
                    )
                    ToolbarView.toolButton(currentTool: $currentTool, tool: .lasso,
                                           onRequestOptions: onOpenToolOptions)
                }
                // Transform-tool family: Scale (with Shear as long-press
                // alternate) + Rotate. All three share the dialog
                // gesture and state.transform_reference_point. See
                // SCALE_TOOL.md / ROTATE_TOOL.md / SHEAR_TOOL.md.
                HStack(spacing: 2) {
                    ToolbarView.toolButtonWithAlternates(
                        currentTool: $currentTool,
                        visibleTool: $transformSlotTool,
                        alternates: [.scale, .shear],
                        onRequestOptions: onOpenToolOptions
                    )
                    ToolbarView.toolButton(currentTool: $currentTool, tool: .rotate,
                                           onRequestOptions: onOpenToolOptions)
                }
                // Navigation-tool family: Hand (primary, with Zoom as
                // long-press alternate). Hand-icon dblclick →
                // fit_active_artboard; Zoom-icon dblclick →
                // zoom_to_actual_size, both via tool_options_action
                // on the tool YAMLs. See HAND_TOOL.md / ZOOM_TOOL.md.
                HStack(spacing: 2) {
                    ToolbarView.toolButtonWithAlternates(
                        currentTool: $currentTool,
                        visibleTool: $navSlotTool,
                        alternates: [.hand, .zoom],
                        onRequestOptions: onOpenToolOptions
                    )
                    // Eyedropper — top-level slot, no alternates
                    // (Phase 1). Dblclick opens the Eyedropper Tool
                    // Options dialog via tool_options_dialog. See
                    // EYEDROPPER_TOOL.md.
                    ToolbarView.toolButton(
                        currentTool: $currentTool,
                        tool: .eyedropper,
                        onRequestOptions: onOpenToolOptions
                    )
                }
            }
            .padding(4)
            .frame(width: toolbarWidth)
            .background(SwiftUI.Color(nsColor: theme.paneBg))

            // Fill/Stroke indicator
            if let model = model {
                FillStrokeWidget(model: model, onDoubleClick: { forFill in
                    onOpenColorPicker?(forFill)
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
        .background(SwiftUI.Color(nsColor: theme.paneBgDark))
    }

    private func fillModeButton(label: String, tooltip: String, action: @escaping () -> Void) -> some View {
        // Map the mode label to its icon name (icons.yaml).
        let iconName: String? = {
            switch label {
            case "C": return "fill_solid"
            case "G": return "fill_gradient"
            case "/": return "color_none"
            default: return nil
            }
        }()
        return Button(action: action) {
            ZStack {
                SwiftUI.Color(nsColor: theme.buttonChecked)
                if let iconName, WorkspaceIconCache.shared.lookup(iconName) != nil {
                    WorkspaceIcon(name: iconName, size: 14, tint: theme.text)
                } else {
                    SwiftUI.Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(SwiftUI.Color(nsColor: theme.text))
                }
            }
            .frame(width: 20, height: 16)
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
            // Swap arrow — double-headed L bending around the
            // upper-right of the icon. The horizontal leg points
            // left (toward the fill square) with an arrow head;
            // the vertical leg points down (toward the stroke
            // square) with another arrow head. Mirrors Illustrator's
            // swap-fill-stroke affordance.
            Button(action: swapColors) {
                SwiftUI.Canvas { context, _ in
                    var path = SwiftUI.Path()
                    // Left arrow tip (4, 4) with head wings.
                    path.move(to: CGPoint(x: 7, y: 1))
                    path.addLine(to: CGPoint(x: 4, y: 4))    // tip
                    path.addLine(to: CGPoint(x: 7, y: 7))
                    path.move(to: CGPoint(x: 4, y: 4))       // back to tip
                    path.addLine(to: CGPoint(x: 12, y: 4))   // along top
                    path.addLine(to: CGPoint(x: 12, y: 12))  // down the right
                    // Bottom arrow tip (12, 12) with head wings.
                    path.move(to: CGPoint(x: 9, y: 9))
                    path.addLine(to: CGPoint(x: 12, y: 12))
                    path.addLine(to: CGPoint(x: 15, y: 9))
                    context.stroke(
                        path,
                        with: .color(.white),
                        style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                    )
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

            // Fill always at upper-left, stroke always at lower-right.
            // ZStack render order determines z-order: render the
            // INACTIVE one first (behind) and the active one second
            // (on top). Without this, switching active swapped the
            // squares' positions instead of just changing what's on
            // top — surprising and against Illustrator convention.
            if model.fillOnTop {
                fillStrokeSquare(isFill: false)
                    .position(x: offset + squareSize / 2, y: offset + squareSize / 2)
                fillStrokeSquare(isFill: true)
                    .position(x: squareSize / 2, y: squareSize / 2)
            } else {
                fillStrokeSquare(isFill: true)
                    .position(x: squareSize / 2, y: squareSize / 2)
                fillStrokeSquare(isFill: false)
                    .position(x: offset + squareSize / 2, y: offset + squareSize / 2)
            }
        }
        .frame(width: totalSize, height: totalSize)
    }

    @ViewBuilder
    private func fillStrokeSquare(isFill: Bool) -> some View {
        // Resolve from the selection first so the widget tracks the
        // canvas — selecting a differently-coloured shape should
        // surface its colors here, not the (potentially stale) tab
        // defaults. Falls back to defaults when no selection.
        let resolved: Color? = {
            if isFill {
                switch selectionFillSummary(model.document) {
                case .uniform(let f?): return f.color
                case .uniform(nil): return nil
                default: return model.defaultFill?.color
                }
            } else {
                switch selectionStrokeSummary(model.document) {
                case .uniform(let s?): return s.color
                case .uniform(nil): return nil
                default: return model.defaultStroke?.color
                }
            }
        }()
        let color: SwiftUI.Color? = resolved.map(swiftColor)

        ZStack {
            if let c = color {
                if isFill {
                    // Solid fill square
                    Rectangle()
                        .fill(c)
                        .frame(width: squareSize, height: squareSize)
                        .border(SwiftUI.Color.gray.opacity(0.5), width: 0.5)
                } else {
                    // Stroke square: thick colored border, transparent
                    // center (hollow ring). Matches Illustrator's
                    // stroke-swatch convention; the user can see the
                    // fill behind through the center when stroke is
                    // on top.
                    Rectangle()
                        .fill(SwiftUI.Color.clear)
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
        // Force the entire square's bounds to hit-test, even where
        // the fill is transparent (hollow stroke swatch). Without
        // contentShape, clicks on the stroke ring's center fell
        // through and the active-target switch never fired.
        .contentShape(Rectangle().size(width: squareSize, height: squareSize))
        .onTapGesture(count: 2) {
            onDoubleClick(isFill)
        }
        .onTapGesture(count: 1) {
            // Single click brings this square to front
            model.fillOnTop = isFill
        }
    }

    private func swapColors() {
        // Pull current colors from the SELECTION first (matching what
        // the widget displays — see fillStrokeSquare). Fall back to
        // tab defaults when no selection / non-uniform. Swapping based
        // on defaults alone produced "random" colors when the
        // defaults had drifted from the selection's actual fill /
        // stroke (e.g. the user changed colors via Color panel
        // slider edits that wrote to the selection).
        let curFill: Fill? = {
            switch selectionFillSummary(model.document) {
            case .uniform(let f?): return f
            case .uniform(nil): return nil
            default: return model.defaultFill
            }
        }()
        let curStroke: Stroke? = {
            switch selectionStrokeSummary(model.document) {
            case .uniform(let s?): return s
            case .uniform(nil): return nil
            default: return model.defaultStroke
            }
        }()
        let newFill: Fill? = curStroke.map { Fill(color: $0.color) }
        let newStroke: Stroke? = curFill.map { Stroke(color: $0.color) }
        model.defaultFill = newFill
        model.defaultStroke = newStroke
        if !model.document.selection.isEmpty {
            let ctrl = Controller(model: model)
            // Fill + stroke swap as ONE undo step (withTxn; each editDocument joins).
            model.withTxn {
                ctrl.setSelectionFill(newFill)
                ctrl.setSelectionStroke(newStroke)
            }
        }
    }

    private func resetDefaults() {
        // Reset both the tab default and the selection (if any) so
        // the canvas reflects the new defaults right away.
        model.defaultFill = nil
        let newStroke = Stroke(color: .black)
        model.defaultStroke = newStroke
        if !model.document.selection.isEmpty {
            let ctrl = Controller(model: model)
            // Fill + stroke reset as ONE undo step (withTxn; each editDocument joins).
            model.withTxn {
                ctrl.setSelectionFill(nil)
                ctrl.setSelectionStroke(newStroke)
            }
        }
    }

    private func swiftColor(_ c: Color) -> SwiftUI.Color {
        let (r, g, b, a) = c.toRgba()
        return SwiftUI.Color(nsColor: NSColor(red: r, green: g, blue: b, alpha: a))
    }
}

