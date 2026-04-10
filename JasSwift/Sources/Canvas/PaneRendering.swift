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

    public static func from(_ pl: PaneLayout?, dockCollapsed: Bool = false) -> RenderingState {
        guard let pl = pl else {
            return RenderingState(panes: [], borders: [], canvasMaximized: false)
        }

        let maximized = pl.canvasMaximized

        // Build pane geometries
        var paneGeos: [PaneGeometry] = []
        for p in pl.panes {
            let visible = pl.isPaneVisible(p.kind)

            let (px, py, pw, ph, pz): (Double, Double, Double, Double, Int)
            if p.config.doubleClickAction == .maximize && maximized {
                (px, py, pw, ph, pz) = (0, 0, pl.viewportWidth, pl.viewportHeight, 0)
            } else if maximized {
                (px, py, pw, ph, pz) = (p.x, p.y, p.width, p.height, pl.paneZIndex(p.id) + 50)
            } else if dockCollapsed, let cw = p.config.collapsedWidth {
                (px, py, pw, ph, pz) = (p.x + p.width - cw, p.y, cw, p.height, pl.paneZIndex(p.id))
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
                // Skip borders involving collapsed panes
                if dockCollapsed && (paneA.config.collapsedWidth != nil || paneB.config.collapsedWidth != nil) { continue }

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
// BorderHandleView — shared border between snapped panes
// ---------------------------------------------------------------------------

struct BorderHandleView: View {
    let border: SharedBorder
    let isDragging: Bool
    @Binding var hoveredBorder: Int?

    var body: some View {
        let fillColor: SwiftUI.Color = isDragging
            ? SwiftUI.Color(red: 74/255, green: 144/255, blue: 217/255).opacity(0.5)
            : SwiftUI.Color.clear

        Rectangle()
            .fill(fillColor)
            .contentShape(Rectangle())
            .onHover { hovering in
                hoveredBorder = hovering ? border.snapIdx : nil
                if hovering {
                    (border.isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }
}

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
    @Binding var edgeResize: (paneId: PaneId, edge: EdgeSide, startX: Double, startY: Double, startW: Double, startH: Double)?
    @Binding var edgeSnappedCoord: Double?
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

            if geo.config.collapsedWidth != nil {
                Button(action: {
                    if let rightDock = workspace.dockLayout.anchoredDock(.right) {
                        workspace.dockLayout.toggleDockCollapsed(rightDock.id)
                        let collapsed = workspace.dockLayout.anchoredDock(.right)?.collapsed ?? false
                        let dockPaneId = geo.id
                        let cw = geo.config.collapsedWidth ?? 36
                        workspace.dockLayout.panesMut { pl in
                            pl.tilePanes(collapsedOverride: collapsed ? (dockPaneId, cw) : nil)
                        }
                    }
                }) {
                    SwiftUI.Text("\u{00AB}")
                        .font(.system(size: 12))
                        .foregroundColor(SwiftUI.Color(nsColor: paneButtonColor))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }

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
        .frame(height: paneTitleBarHeight)
        .frame(maxWidth: .infinity)
        .background(SwiftUI.Color(nsColor: paneTitleBgColor))
        .gesture(paneDragGesture)
        .if(geo.config.doubleClickAction == .maximize) { view in
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
                       w: paneEdgeHandleSize, h: geo.height)
            // Left edge
            edgeHandle(edge: .left,
                       x: 0, y: 0,
                       w: paneEdgeHandleSize, h: geo.height)
            // Bottom edge
            edgeHandle(edge: .bottom,
                       x: 0, y: geo.height - paneEdgeHandleSize,
                       w: geo.width, h: paneEdgeHandleSize)
            // Top edge
            edgeHandle(edge: .top,
                       x: 0, y: 0,
                       w: geo.width, h: paneEdgeHandleSize)
        }
    }

    private func edgeHandle(edge: EdgeSide, x: Double, y: Double,
                            w: Double, h: Double) -> some View {
        return SwiftUI.Color.clear
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .position(x: x + w / 2, y: y + h / 2)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("paneContainer"))
                    .onChanged { value in
                        // Capture initial geometry on first call
                        if edgeResize == nil {
                            workspace.dockLayout.panesMut { pl in
                                guard let p = pl.pane(geo.id) else { return }
                                edgeResize = (geo.id, edge, p.x, p.y, p.width, p.height)
                            }
                        }
                        guard let start = edgeResize else { return }
                        let dx = Double(value.translation.width)
                        let dy = Double(value.translation.height)
                        var snappedAt: Double? = nil
                        workspace.dockLayout.panesMut { pl in
                            let minW = pl.pane(geo.id)?.config.minWidth ?? 200
                            let minH = pl.pane(geo.id)?.config.minHeight ?? 200
                            // Compute raw (unsnapped) edge position
                            switch edge {
                            case .right:
                                let rawW = max(start.startW + dx, minW)
                                let rawRight = start.startX + rawW
                                let snapped = Self.findEdgeSnap(pl: pl, paneId: geo.id, edge: edge, coord: rawRight)
                                snappedAt = snapped
                                let finalW = (snapped ?? rawRight) - start.startX
                                pl.paneMut(geo.id) { pp in pp.width = max(finalW, minW) }
                            case .left:
                                let rawX = start.startX + dx
                                let snapped = Self.findEdgeSnap(pl: pl, paneId: geo.id, edge: edge, coord: rawX)
                                snappedAt = snapped
                                let finalX = snapped ?? rawX
                                let finalW = max(start.startX + start.startW - finalX, minW)
                                let clampedX = start.startX + start.startW - finalW
                                pl.paneMut(geo.id) { pp in pp.x = clampedX; pp.width = finalW }
                            case .bottom:
                                let rawH = max(start.startH + dy, minH)
                                let rawBottom = start.startY + rawH
                                let snapped = Self.findEdgeSnap(pl: pl, paneId: geo.id, edge: edge, coord: rawBottom)
                                snappedAt = snapped
                                let finalH = (snapped ?? rawBottom) - start.startY
                                pl.paneMut(geo.id) { pp in pp.height = max(finalH, minH) }
                            case .top:
                                let rawY = start.startY + dy
                                let snapped = Self.findEdgeSnap(pl: pl, paneId: geo.id, edge: edge, coord: rawY)
                                snappedAt = snapped
                                let finalY = snapped ?? rawY
                                let finalH = max(start.startY + start.startH - finalY, minH)
                                let clampedY = start.startY + start.startH - finalH
                                pl.paneMut(geo.id) { pp in pp.y = clampedY; pp.height = finalH }
                            }
                        }
                        edgeSnappedCoord = snappedAt
                    }
                    .onEnded { _ in
                        edgeResize = nil
                        edgeSnappedCoord = nil
                        workspace.dockLayout.saveIfNeeded()
                    }
            )
    }

    /// Find a snap target for a specific edge coordinate. Returns the snap
    /// coordinate if within snap distance, or nil if no snap found.
    static func findEdgeSnap(pl: PaneLayout, paneId: PaneId, edge: EdgeSide, coord: Double) -> Double? {
        let dist = snapDistance
        let vw = pl.viewportWidth
        let vh = pl.viewportHeight

        // Check window edges
        let windowCoord: Double
        switch edge {
        case .left: windowCoord = 0
        case .right: windowCoord = vw
        case .top: windowCoord = 0
        case .bottom: windowCoord = vh
        }
        if abs(coord - windowCoord) <= dist { return windowCoord }

        // Check other pane edges
        for other in pl.panes {
            if other.id == paneId { continue }
            let otherCoord: Double
            switch edge {
            case .right: otherCoord = other.x           // snap right edge to other's left
            case .left: otherCoord = other.x + other.width  // snap left edge to other's right
            case .bottom: otherCoord = other.y
            case .top: otherCoord = other.y + other.height
            }
            if abs(coord - otherCoord) <= dist { return otherCoord }
        }

        return nil
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
