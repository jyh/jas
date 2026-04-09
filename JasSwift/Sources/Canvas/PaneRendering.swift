/// Pane rendering helpers: pure functions that compute rendering data
/// from PaneLayout state, plus the PaneFrameView that wraps content
/// with a title bar and edge resize handles.

import SwiftUI

// ---------------------------------------------------------------------------
// Rendering state (pure data, testable without UI)
// ---------------------------------------------------------------------------

/// Computed geometry for a single pane.
public struct PaneGeometry: Identifiable {
    public let id: PaneId
    public let kind: PaneKind
    public let config: PaneConfig
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let zIndex: Int
    public let visible: Bool
}

/// Computed geometry for a shared border handle.
public struct SharedBorder: Identifiable {
    public var id: Int { snapIdx }
    public let snapIdx: Int
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let isVertical: Bool
}

/// Computed geometry for a snap preview line.
public struct SnapLine: Identifiable {
    public let id: Int
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

/// All rendering data extracted from PaneLayout.
public struct RenderingState {
    public let panes: [PaneGeometry]
    public let borders: [SharedBorder]
    public let canvasMaximized: Bool

    public static func from(_ pl: PaneLayout?) -> RenderingState {
        guard let pl = pl else {
            return RenderingState(panes: [], borders: [], canvasMaximized: false)
        }

        let maximized = pl.canvasMaximized

        // Build pane geometries
        var paneGeos: [PaneGeometry] = []
        for p in pl.panes {
            let visible: Bool
            switch p.kind {
            case .canvas: visible = true
            default: visible = pl.isPaneVisible(p.kind)
            }

            let (px, py, pw, ph, pz): (Double, Double, Double, Double, Int)
            if p.kind == .canvas && maximized {
                (px, py, pw, ph, pz) = (0, 0, pl.viewportWidth, pl.viewportHeight, 0)
            } else {
                (px, py, pw, ph, pz) = (p.x, p.y, p.width, p.height, pl.paneZIndex(p.id))
            }

            paneGeos.append(PaneGeometry(
                id: p.id, kind: p.kind, config: p.config,
                x: px, y: py, width: pw, height: ph,
                zIndex: pz, visible: visible
            ))
        }

        // Build shared border handles
        var borders: [SharedBorder] = []
        if !maximized {
            for (i, snap) in pl.snaps.enumerated() {
                guard case .pane(let otherId, let otherEdge) = snap.target else { continue }
                let isVert = snap.edge == .right && otherEdge == .left
                let isHoriz = snap.edge == .bottom && otherEdge == .top
                if !isVert && !isHoriz { continue }

                guard let paneA = pl.pane(snap.pane), let paneB = pl.pane(otherId) else { continue }
                // Skip borders involving fixed-width panes
                if paneA.config.fixedWidth || paneB.config.fixedWidth { continue }

                if isVert {
                    let bx = paneA.x + paneA.width
                    let by = max(paneA.y, paneB.y)
                    let bh = min(paneA.y + paneA.height, paneB.y + paneB.height) - by
                    if bh > 0 {
                        borders.append(SharedBorder(snapIdx: i, x: bx - 3, y: by, width: 6, height: bh, isVertical: true))
                    }
                } else {
                    let by2 = paneA.y + paneA.height
                    let bx2 = max(paneA.x, paneB.x)
                    let bw = min(paneA.x + paneA.width, paneB.x + paneB.width) - bx2
                    if bw > 0 {
                        borders.append(SharedBorder(snapIdx: i, x: bx2, y: by2 - 3, width: bw, height: 6, isVertical: false))
                    }
                }
            }
        }

        return RenderingState(panes: paneGeos, borders: borders, canvasMaximized: maximized)
    }

    /// Compute snap preview lines from active snap constraints.
    public static func snapLines(from preview: [SnapConstraint], paneLayout pl: PaneLayout?) -> [SnapLine] {
        guard let pl = pl else { return [] }
        var lines: [SnapLine] = []
        for (i, snap) in preview.enumerated() {
            guard let pane = pl.pane(snap.pane) else { continue }
            let coord = PaneLayout.paneEdgeCoord(pane, snap.edge)
            switch snap.edge {
            case .left, .right:
                lines.append(SnapLine(id: i, x: coord - 2, y: pane.y, width: 4, height: pane.height))
            case .top, .bottom:
                lines.append(SnapLine(id: i, x: pane.x, y: coord - 2, width: pane.width, height: 4))
            }
        }
        return lines
    }
}

// ---------------------------------------------------------------------------
// Theme constants
// ---------------------------------------------------------------------------

let paneTitleBarHeight: Double = 20
let paneEdgeHandleSize: Double = 4
let paneBorderHandleSize: Double = 6

let paneTitleBgColor = NSColor(white: 0.22, alpha: 1.0)
let paneTitleTextColor = NSColor(white: 0.85, alpha: 1.0)
let paneButtonColor = NSColor(white: 0.65, alpha: 1.0)
let snapLineColor = NSColor(red: 50/255, green: 120/255, blue: 220/255, alpha: 0.8)

// ---------------------------------------------------------------------------
// PaneFrameView — wraps content with title bar + edge handles
// ---------------------------------------------------------------------------

struct PaneFrameView<Content: View>: View {
    let geo: PaneGeometry
    let workspace: WorkspaceState
    let showTitleBar: Bool
    @ViewBuilder let content: () -> Content

    // Drag state bindings (owned by parent)
    @Binding var paneDrag: (paneId: PaneId, offX: Double, offY: Double)?
    @Binding var snapPreview: [SnapConstraint]

    var body: some View {
        VStack(spacing: 0) {
            if showTitleBar {
                titleBar
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SwiftUI.Color(nsColor: NSColor(white: 0.25, alpha: 1.0)))
        .border(SwiftUI.Color(nsColor: NSColor(white: 0.33, alpha: 1.0)), width: 1)
        .overlay { edgeHandles }
        .simultaneousGesture(
            TapGesture().onEnded {
                workspace.dockLayout.panesMut { pl in
                    pl.bringPaneToFront(geo.id)
                }
            }
        )
    }

    private var titleBar: some View {
        HStack(spacing: 0) {
            SwiftUI.Text(geo.config.label)
                .font(.system(size: 11))
                .foregroundColor(SwiftUI.Color(nsColor: paneTitleTextColor))
                .padding(.leading, 6)

            Spacer()

            if geo.config.collapsible {
                Button(action: {
                    if let rightDock = workspace.dockLayout.anchoredDock(.right) {
                        workspace.dockLayout.toggleDockCollapsed(rightDock.id)
                    }
                }) {
                    SwiftUI.Text("\u{00AB}")
                        .font(.system(size: 12))
                        .foregroundColor(SwiftUI.Color(nsColor: paneButtonColor))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }

            if geo.config.closable {
                Button(action: {
                    workspace.dockLayout.panesMut { pl in
                        pl.hidePane(geo.kind)
                    }
                }) {
                    SwiftUI.Text("\u{00D7}")
                        .font(.system(size: 12))
                        .foregroundColor(SwiftUI.Color(nsColor: paneButtonColor))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }
        }
        .frame(height: paneTitleBarHeight)
        .frame(maxWidth: .infinity)
        .background(SwiftUI.Color(nsColor: paneTitleBgColor))
        .gesture(paneDragGesture)
        .if(geo.config.maximizable) { view in
            view.onTapGesture(count: 2) {
                workspace.dockLayout.panesMut { pl in
                    pl.toggleCanvasMaximized()
                }
            }
        }
    }

    private var paneDragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("paneContainer"))
            .onChanged { value in
                if paneDrag == nil {
                    // Start drag: capture offset from pane origin
                    let offX = value.startLocation.x - geo.x
                    let offY = value.startLocation.y - geo.y
                    paneDrag = (geo.id, offX, offY)
                }
                if let drag = paneDrag {
                    let newX = value.location.x - drag.offX
                    let newY = value.location.y - drag.offY
                    workspace.dockLayout.panesMut { pl in
                        pl.setPanePosition(geo.id, x: newX, y: newY)
                        let preview = pl.detectSnaps(dragged: geo.id,
                                                      viewportW: pl.viewportWidth,
                                                      viewportH: pl.viewportHeight)
                        if !preview.isEmpty {
                            pl.alignToSnaps(geo.id, snaps: preview,
                                           viewportW: pl.viewportWidth,
                                           viewportH: pl.viewportHeight)
                        }
                        snapPreview = preview
                    }
                }
            }
            .onEnded { _ in
                if paneDrag != nil {
                    let preview = snapPreview
                    if !preview.isEmpty {
                        workspace.dockLayout.panesMut { pl in
                            pl.applySnaps(geo.id, newSnaps: preview,
                                         viewportW: pl.viewportWidth,
                                         viewportH: pl.viewportHeight)
                        }
                    }
                    snapPreview = []
                    paneDrag = nil
                    workspace.dockLayout.saveIfNeeded()
                }
            }
    }

    private var edgeHandles: some View {
        ZStack {
            // Right edge
            edgeHandle(edge: .right,
                       x: geo.width - paneEdgeHandleSize, y: 0,
                       w: paneEdgeHandleSize, h: geo.height,
                       cursor: .resizeLeftRight)
            // Left edge
            edgeHandle(edge: .left,
                       x: 0, y: 0,
                       w: paneEdgeHandleSize, h: geo.height,
                       cursor: .resizeLeftRight)
            // Bottom edge
            edgeHandle(edge: .bottom,
                       x: 0, y: geo.height - paneEdgeHandleSize,
                       w: geo.width, h: paneEdgeHandleSize,
                       cursor: .resizeUpDown)
            // Top edge
            edgeHandle(edge: .top,
                       x: 0, y: 0,
                       w: geo.width, h: paneEdgeHandleSize,
                       cursor: .resizeUpDown)
        }
    }

    private func edgeHandle(edge: EdgeSide, x: Double, y: Double,
                            w: Double, h: Double, cursor: NSCursor) -> some View {
        SwiftUI.Color.clear
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .position(x: x + w / 2, y: y + h / 2)
            .onHover { hovering in
                if hovering { cursor.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("paneContainer"))
                    .onChanged { value in
                        let dx = value.location.x - value.startLocation.x
                        let dy = value.location.y - value.startLocation.y
                        workspace.dockLayout.panesMut { pl in
                            guard let p = pl.pane(geo.id) else { return }
                            switch edge {
                            case .right:
                                let startW = paneDrag == nil ? p.width : p.width
                                pl.resizePane(geo.id, width: p.width + dx - (paneDrag != nil ? 0 : 0), height: p.height)
                            case .left:
                                let newW = max(geo.width - dx, p.config.minWidth)
                                let actualDx = geo.width - newW
                                pl.paneMut(geo.id) { pp in
                                    pp.x = geo.x + actualDx
                                    pp.width = newW
                                }
                            case .bottom:
                                pl.resizePane(geo.id, width: p.width, height: p.height + dy)
                            case .top:
                                let newH = max(geo.height - dy, p.config.minHeight)
                                let actualDy = geo.height - newH
                                pl.paneMut(geo.id) { pp in
                                    pp.y = geo.y + actualDy
                                    pp.height = newH
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        workspace.dockLayout.saveIfNeeded()
                    }
            )
    }
}

// ---------------------------------------------------------------------------
// Conditional modifier helper
// ---------------------------------------------------------------------------

extension View {
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
