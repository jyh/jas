/// Pane layout: floating, movable, resizable panes.
///
/// A `PaneLayout` manages the positions, sizes, and snap constraints
/// for the top-level panes (toolbar, canvas, dock). Each `Pane` carries
/// a `PaneConfig` that drives generic behavior like tiling, resizing,
/// and title bar chrome.
///
/// This file contains only pure data types and state operations — no
/// rendering code.

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

public let minToolbarWidth: Double = 72
public let minToolbarHeight: Double = 200
public let minCanvasHeight: Double = 200
public let minPaneDockWidth: Double = 150
public let minPaneDockHeight: Double = 100
public let defaultToolbarWidth: Double = 72
public let borderHitTolerance: Double = 6
public let minPaneVisible: Double = 50

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Stable identifier for a pane.
public struct PaneId: Hashable, Codable {
    public var value: Int
    public init(_ value: Int) { self.value = value }
}

/// Which top-level region a pane represents.
public enum PaneKind: Hashable, Codable {
    case toolbar, canvas, dock
}

/// How a pane's width is allocated during the Tile operation.
public enum TileWidth: Codable, Equatable {
    case fixed(Double)
    case keepCurrent
    case flex
}

/// Action triggered by double-clicking a pane's title bar.
public enum DoubleClickAction: Codable, Equatable {
    /// Toggle maximize (canvas).
    case maximize
    /// Merge floating dock back into nearest anchored dock.
    case redock
    /// No action.
    case none
}

/// Configuration that drives generic pane management behavior.
public struct PaneConfig: Codable {
    public var label: String
    public var minWidth: Double
    public var minHeight: Double
    public var fixedWidth: Bool
    /// Width when in collapsed state; nil means not collapsible.
    public var collapsedWidth: Double?
    /// Action triggered by double-clicking the title bar.
    public var doubleClickAction: DoubleClickAction
    public var tileOrder: Int
    public var tileWidth: TileWidth

    public static func forKind(_ kind: PaneKind) -> PaneConfig {
        switch kind {
        case .toolbar:
            return PaneConfig(
                label: "Tools", minWidth: minToolbarWidth, minHeight: minToolbarHeight,
                fixedWidth: true, collapsedWidth: nil,
                doubleClickAction: .none,
                tileOrder: 0, tileWidth: .fixed(defaultToolbarWidth))
        case .canvas:
            return PaneConfig(
                label: "Canvas", minWidth: minCanvasWidth, minHeight: minCanvasHeight,
                fixedWidth: false, collapsedWidth: nil,
                doubleClickAction: .maximize,
                tileOrder: 1, tileWidth: .flex)
        case .dock:
            return PaneConfig(
                label: "Panels", minWidth: minPaneDockWidth, minHeight: minPaneDockHeight,
                fixedWidth: false, collapsedWidth: 36.0,
                doubleClickAction: .redock,
                tileOrder: 2, tileWidth: .keepCurrent)
        }
    }
}

/// A floating pane with position, size, and configuration.
public struct Pane: Codable {
    public var id: PaneId
    public var kind: PaneKind
    public var config: PaneConfig
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
}

/// Which side of a rectangle.
public enum EdgeSide: Hashable, Codable {
    case left, right, top, bottom
}

/// What a pane edge is snapped to.
public enum SnapTarget: Codable, Equatable {
    case window(EdgeSide)
    case pane(PaneId, EdgeSide)
}

/// A snap constraint: one pane edge is attached to a target.
public struct SnapConstraint: Codable, Equatable {
    public var pane: PaneId
    public var edge: EdgeSide
    public var target: SnapTarget
}

// ---------------------------------------------------------------------------
// PaneLayout
// ---------------------------------------------------------------------------

/// Layout of the three top-level panes (toolbar, canvas, dock).
public struct PaneLayout: Codable {
    public var panes: [Pane]
    public var snaps: [SnapConstraint]
    public var zOrder: [PaneId]
    public var hiddenPanes: [PaneKind]
    public var canvasMaximized: Bool
    public var viewportWidth: Double
    public var viewportHeight: Double
    var nextPaneId: Int

    // MARK: - Construction

    /// Create the default three-pane layout filling the viewport left-to-right:
    /// toolbar(72px) | canvas(flex) | dock(240px).
    public static func defaultThreePane(viewportW: Double, viewportH: Double) -> PaneLayout {
        let toolbarW = defaultToolbarWidth
        let dockW = defaultDockWidth
        let canvasW = max(viewportW - toolbarW - dockW, minCanvasWidth)

        let toolbarId = PaneId(0)
        let canvasId = PaneId(1)
        let dockId = PaneId(2)

        let panes = [
            Pane(id: toolbarId, kind: .toolbar, config: .forKind(.toolbar),
                 x: 0, y: 0, width: toolbarW, height: viewportH),
            Pane(id: canvasId, kind: .canvas, config: .forKind(.canvas),
                 x: toolbarW, y: 0, width: canvasW, height: viewportH),
            Pane(id: dockId, kind: .dock, config: .forKind(.dock),
                 x: toolbarW + canvasW, y: 0, width: dockW, height: viewportH),
        ]

        let snaps = [
            // Toolbar: left to window, top/bottom to window, right to canvas
            SnapConstraint(pane: toolbarId, edge: .left, target: .window(.left)),
            SnapConstraint(pane: toolbarId, edge: .top, target: .window(.top)),
            SnapConstraint(pane: toolbarId, edge: .bottom, target: .window(.bottom)),
            SnapConstraint(pane: toolbarId, edge: .right, target: .pane(canvasId, .left)),
            // Canvas: top/bottom to window, right to dock
            SnapConstraint(pane: canvasId, edge: .top, target: .window(.top)),
            SnapConstraint(pane: canvasId, edge: .bottom, target: .window(.bottom)),
            SnapConstraint(pane: canvasId, edge: .right, target: .pane(dockId, .left)),
            // Dock: right to window, top/bottom to window
            SnapConstraint(pane: dockId, edge: .right, target: .window(.right)),
            SnapConstraint(pane: dockId, edge: .top, target: .window(.top)),
            SnapConstraint(pane: dockId, edge: .bottom, target: .window(.bottom)),
        ]

        return PaneLayout(
            panes: panes,
            snaps: snaps,
            zOrder: [canvasId, toolbarId, dockId],
            hiddenPanes: [],
            canvasMaximized: false,
            viewportWidth: viewportW,
            viewportHeight: viewportH,
            nextPaneId: 3
        )
    }

    // MARK: - Lookup

    public func pane(_ id: PaneId) -> Pane? {
        panes.first { $0.id == id }
    }

    public mutating func paneMut(_ id: PaneId, _ body: (inout Pane) -> Void) {
        if let idx = panes.firstIndex(where: { $0.id == id }) {
            body(&panes[idx])
        }
    }

    public func paneByKind(_ kind: PaneKind) -> Pane? {
        panes.first { $0.kind == kind }
    }

    public mutating func paneByKindMut(_ kind: PaneKind, _ body: (inout Pane) -> Void) {
        if let idx = panes.firstIndex(where: { $0.kind == kind }) {
            body(&panes[idx])
        }
    }

    // MARK: - Move

    /// Move a pane to a new position. Removes all snap constraints involving
    /// this pane (since the user manually repositioned it).
    public mutating func setPanePosition(_ id: PaneId, x: Double, y: Double) {
        paneMut(id) { p in
            p.x = x
            p.y = y
        }
        snaps.removeAll { s in
            s.pane == id || {
                if case .pane(let pid, _) = s.target { return pid == id }
                return false
            }()
        }
    }

    // MARK: - Resize

    /// Set a pane's size, clamped to its minimum.
    public mutating func resizePane(_ id: PaneId, width: Double, height: Double) {
        paneMut(id) { p in
            p.width = max(width, p.config.minWidth)
            p.height = max(height, p.config.minHeight)
        }
    }

    // MARK: - Snap Detection

    /// Return the coordinate of a pane edge.
    public static func paneEdgeCoord(_ pane: Pane, _ edge: EdgeSide) -> Double {
        switch edge {
        case .left: return pane.x
        case .right: return pane.x + pane.width
        case .top: return pane.y
        case .bottom: return pane.y + pane.height
        }
    }

    /// Return the coordinate of a window edge.
    private static func windowEdgeCoord(_ edge: EdgeSide, _ vw: Double, _ vh: Double) -> Double {
        switch edge {
        case .left, .top: return 0
        case .right: return vw
        case .bottom: return vh
        }
    }

    /// True if two edges are parallel and on opposite sides (can snap together).
    private static func edgesCanSnap(_ a: EdgeSide, _ b: EdgeSide) -> Bool {
        switch (a, b) {
        case (.right, .left), (.left, .right), (.bottom, .top), (.top, .bottom):
            return true
        default:
            return false
        }
    }

    /// Detect potential snap constraints for a pane at its current position.
    public func detectSnaps(dragged: PaneId, viewportW: Double, viewportH: Double) -> [SnapConstraint] {
        guard let dp = pane(dragged) else { return [] }
        var result: [SnapConstraint] = []

        let allEdges: [EdgeSide] = [.left, .right, .top, .bottom]

        // Check against window edges
        for edge in allEdges {
            let coord = Self.paneEdgeCoord(dp, edge)
            let windowCoord = Self.windowEdgeCoord(edge, viewportW, viewportH)
            if abs(coord - windowCoord) <= snapDistance {
                result.append(SnapConstraint(pane: dragged, edge: edge, target: .window(edge)))
            }
        }

        // Check against other panes
        for other in panes {
            if other.id == dragged { continue }
            for dEdge in allEdges {
                for oEdge in allEdges {
                    if !Self.edgesCanSnap(dEdge, oEdge) { continue }
                    let dCoord = Self.paneEdgeCoord(dp, dEdge)
                    let oCoord = Self.paneEdgeCoord(other, oEdge)
                    if abs(dCoord - oCoord) <= snapDistance {
                        // Check perpendicular overlap
                        let overlaps: Bool
                        switch dEdge {
                        case .left, .right:
                            overlaps = dp.y < other.y + other.height && dp.y + dp.height > other.y
                        case .top, .bottom:
                            overlaps = dp.x < other.x + other.width && dp.x + dp.width > other.x
                        }
                        if overlaps {
                            // Normalize: Right->Left / Bottom->Top canonical form
                            let snap: SnapConstraint
                            if dEdge == .right || dEdge == .bottom {
                                snap = SnapConstraint(pane: dragged, edge: dEdge, target: .pane(other.id, oEdge))
                            } else {
                                snap = SnapConstraint(pane: other.id, edge: oEdge, target: .pane(dragged, dEdge))
                            }
                            result.append(snap)
                        }
                    }
                }
            }
        }

        return result
    }

    // MARK: - Snap Application

    /// Align a pane's position to match snap constraint targets.
    private mutating func alignPaneImpl(
        _ paneId: PaneId,
        snaps: [SnapConstraint],
        viewportW: Double,
        viewportH: Double
    ) {
        for snap in snaps {
            if snap.pane == paneId {
                let targetCoord: Double
                switch snap.target {
                case .window(let we):
                    targetCoord = Self.windowEdgeCoord(we, viewportW, viewportH)
                case .pane(let otherId, let otherEdge):
                    guard let other = pane(otherId) else { continue }
                    targetCoord = Self.paneEdgeCoord(other, otherEdge)
                }
                paneMut(paneId) { p in
                    switch snap.edge {
                    case .left: p.x = targetCoord
                    case .right: p.x = targetCoord - p.width
                    case .top: p.y = targetCoord
                    case .bottom: p.y = targetCoord - p.height
                    }
                }
            } else if case .pane(let targetPid, let targetEdge) = snap.target, targetPid == paneId {
                guard let anchor = pane(snap.pane) else { continue }
                let anchorCoord = Self.paneEdgeCoord(anchor, snap.edge)
                paneMut(paneId) { p in
                    switch targetEdge {
                    case .left: p.x = anchorCoord
                    case .right: p.x = anchorCoord - p.width
                    case .top: p.y = anchorCoord
                    case .bottom: p.y = anchorCoord - p.height
                    }
                }
            }
        }
    }

    /// Align a pane's position to match snap targets without modifying
    /// the snap list. Used for live snapping during drag.
    public mutating func alignToSnaps(
        _ paneId: PaneId,
        snaps: [SnapConstraint],
        viewportW: Double,
        viewportH: Double
    ) {
        alignPaneImpl(paneId, snaps: snaps, viewportW: viewportW, viewportH: viewportH)
    }

    /// Remove old snaps for a pane and apply new ones, aligning the pane's
    /// position to match the snap targets exactly.
    public mutating func applySnaps(
        _ paneId: PaneId,
        newSnaps: [SnapConstraint],
        viewportW: Double,
        viewportH: Double
    ) {
        snaps.removeAll { s in
            s.pane == paneId || {
                if case .pane(let pid, _) = s.target { return pid == paneId }
                return false
            }()
        }
        alignPaneImpl(paneId, snaps: newSnaps, viewportW: viewportW, viewportH: viewportH)
        snaps.append(contentsOf: newSnaps)
    }

    // MARK: - Shared Border

    /// Find a snap constraint representing a shared border at (x, y).
    /// Returns the snap index and the orientation of the border.
    public func sharedBorderAt(x: Double, y: Double, tolerance: Double) -> (Int, EdgeSide)? {
        for (i, snap) in snaps.enumerated() {
            guard case .pane(let otherId, let otherEdge) = snap.target else { continue }

            let isVertical = snap.edge == .right && otherEdge == .left
            let isHorizontal = snap.edge == .bottom && otherEdge == .top
            if !isVertical && !isHorizontal { continue }

            guard let paneA = pane(snap.pane), let paneB = pane(otherId) else { continue }

            if isVertical {
                let borderX = paneA.x + paneA.width
                let minY = max(paneA.y, paneB.y)
                let maxY = min(paneA.y + paneA.height, paneB.y + paneB.height)
                if abs(x - borderX) <= tolerance && y >= minY && y <= maxY {
                    return (i, .left)
                }
            } else {
                let borderY = paneA.y + paneA.height
                let minX = max(paneA.x, paneB.x)
                let maxX = min(paneA.x + paneA.width, paneB.x + paneB.width)
                if abs(y - borderY) <= tolerance && x >= minX && x <= maxX {
                    return (i, .top)
                }
            }
        }
        return nil
    }

    /// Drag a shared border by `delta` pixels.
    public mutating func dragSharedBorder(snapIdx: Int, delta: Double) {
        guard snapIdx < snaps.count else { return }
        let snap = snaps[snapIdx]
        guard case .pane(let otherId, _) = snap.target else { return }

        guard let pA = pane(snap.pane), let pB = pane(otherId) else { return }
        let aFixed = pA.config.fixedWidth
        let bFixed = pB.config.fixedWidth

        let isVertical = snap.edge == .right

        if isVertical {
            let aW = pA.width
            let bX = pB.x
            let bW = pB.width

            let maxExpand = bFixed ? 0 : bW - pB.config.minWidth
            let maxShrink = aFixed ? 0 : aW - pA.config.minWidth
            let clamped = min(max(delta, -maxShrink), maxExpand)

            if !aFixed {
                paneMut(snap.pane) { a in a.width += clamped }
            }
            if !bFixed {
                paneMut(otherId) { b in
                    b.x = bX + clamped
                    b.width -= clamped
                }
            }
            propagateBorderShift(sourcePaneId: otherId, sourceEdge: .right, isVertical: true)
        } else {
            let aH = pA.height
            let bY = pB.y
            let bH = pB.height

            let maxExpand = bFixed ? 0 : bH - pB.config.minHeight
            let maxShrink = aFixed ? 0 : aH - pA.config.minHeight
            let clamped = min(max(delta, -maxShrink), maxExpand)

            if !aFixed {
                paneMut(snap.pane) { a in a.height += clamped }
            }
            if !bFixed {
                paneMut(otherId) { b in
                    b.y = bY + clamped
                    b.height -= clamped
                }
            }
            propagateBorderShift(sourcePaneId: otherId, sourceEdge: .bottom, isVertical: false)
        }

        // When one pane is fixed-width, unsnap the border.
        if (aFixed || bFixed) && !(aFixed && bFixed) {
            snaps.removeAll { s in
                s.pane == snap.pane && s.edge == snap.edge && s.target == snap.target
            }
        }
    }

    /// After a border drag, shift panes snapped to the source pane's far edge.
    private mutating func propagateBorderShift(sourcePaneId: PaneId, sourceEdge: EdgeSide, isVertical: Bool) {
        let chained: [(PaneId, EdgeSide)] = snaps.compactMap { s in
            guard s.pane == sourcePaneId && s.edge == sourceEdge else { return nil }
            if case .pane(let pid, let pe) = s.target { return (pid, pe) }
            return nil
        }

        guard let source = pane(sourcePaneId) else { return }
        let edgeCoord = Self.paneEdgeCoord(source, sourceEdge)

        for (pid, pe) in chained {
            paneMut(pid) { p in
                if isVertical {
                    switch pe {
                    case .left: p.x = edgeCoord
                    case .right: p.x = edgeCoord - p.width
                    default: break
                    }
                } else {
                    switch pe {
                    case .top: p.y = edgeCoord
                    case .bottom: p.y = edgeCoord - p.height
                    default: break
                    }
                }
            }
        }
    }

    // MARK: - Canvas Maximization

    public mutating func toggleCanvasMaximized() {
        canvasMaximized = !canvasMaximized
    }

    // MARK: - Tiling

    /// Tile all visible panes left-to-right, filling the viewport.
    public mutating func tilePanes(collapsedOverride: (PaneId, Double)?) {
        let vw = viewportWidth
        let vh = viewportHeight

        canvasMaximized = false
        hiddenPanes.removeAll()
        var visible: [(PaneId, TileWidth, Double)] = panes.map { ($0.id, $0.config.tileWidth, $0.width) }
        visible.sort { a, b in
            let orderA = pane(a.0)?.config.tileOrder ?? 0
            let orderB = pane(b.0)?.config.tileOrder ?? 0
            return orderA < orderB
        }
        if visible.isEmpty { return }

        // Compute widths
        var fixedTotal: Double = 0
        var flexCount = 0
        var widths: [Double] = visible.map { (id, tileW, currentW) in
            switch tileW {
            case .fixed(let w):
                fixedTotal += w; return w
            case .keepCurrent:
                let w: Double
                if let co = collapsedOverride, co.0 == id {
                    w = co.1
                } else {
                    w = currentW
                }
                fixedTotal += w; return w
            case .flex:
                flexCount += 1; return 0
            }
        }
        let flexEach: Double
        if flexCount > 0 {
            let minFlex = panes.filter { $0.config.tileWidth == .flex }.map(\.config.minWidth).max() ?? 0
            flexEach = max((vw - fixedTotal) / Double(flexCount), minFlex)
        } else {
            flexEach = 0
        }
        widths = zip(visible, widths).map { (entry, w) in
            if case .flex = entry.1 { return flexEach }
            return w
        }

        // Assign positions
        var x: Double = 0
        for (i, (id, _, _)) in visible.enumerated() {
            let w = widths[i]
            paneMut(id) { p in
                p.x = x
                p.y = 0
                p.width = w
                p.height = vh
            }
            x += w
        }

        // Rebuild snaps
        snaps.removeAll()
        for (i, (id, _, _)) in visible.enumerated() {
            if i == 0 {
                snaps.append(SnapConstraint(pane: id, edge: .left, target: .window(.left)))
            }
            if i == visible.count - 1 {
                snaps.append(SnapConstraint(pane: id, edge: .right, target: .window(.right)))
            }
            snaps.append(SnapConstraint(pane: id, edge: .top, target: .window(.top)))
            snaps.append(SnapConstraint(pane: id, edge: .bottom, target: .window(.bottom)))
            if i + 1 < visible.count {
                let nextId = visible[i + 1].0
                snaps.append(SnapConstraint(pane: id, edge: .right, target: .pane(nextId, .left)))
            }
        }
    }

    // MARK: - Pane Visibility

    /// Hide a pane (close it). If the pane is maximized, unmaximize first.
    public mutating func hidePane(_ kind: PaneKind) {
        if canvasMaximized, let p = paneByKind(kind),
           p.config.doubleClickAction == .maximize {
            canvasMaximized = false
        }
        if !hiddenPanes.contains(kind) {
            hiddenPanes.append(kind)
        }
    }

    /// Show a hidden pane and bring it to the front.
    public mutating func showPane(_ kind: PaneKind) {
        hiddenPanes.removeAll { $0 == kind }
        if let p = paneByKind(kind) {
            bringPaneToFront(p.id)
        }
    }

    public func isPaneVisible(_ kind: PaneKind) -> Bool {
        !hiddenPanes.contains(kind)
    }

    // MARK: - Z-Order

    public mutating func bringPaneToFront(_ id: PaneId) {
        if let pos = zOrder.firstIndex(of: id) {
            zOrder.remove(at: pos)
            zOrder.append(id)
        }
    }

    public func paneZIndex(_ id: PaneId) -> Int {
        zOrder.firstIndex(of: id) ?? 0
    }

    // MARK: - Viewport Resize

    /// Proportionally rescale all panes when the viewport changes size.
    public mutating func onViewportResize(newW: Double, newH: Double) {
        if viewportWidth <= 0 || viewportHeight <= 0 {
            viewportWidth = newW
            viewportHeight = newH
            return
        }
        let sx = newW / viewportWidth
        let sy = newH / viewportHeight
        for i in panes.indices {
            panes[i].x *= sx
            panes[i].y *= sy
            panes[i].width = max(panes[i].width * sx, panes[i].config.minWidth)
            panes[i].height = max(panes[i].height * sy, panes[i].config.minHeight)
        }
        viewportWidth = newW
        viewportHeight = newH
        clampPanes(viewportW: newW, viewportH: newH)
    }

    // MARK: - Clamping

    /// Ensure every pane has at least minPaneVisible pixels within the viewport.
    public mutating func clampPanes(viewportW: Double, viewportH: Double) {
        for i in panes.indices {
            panes[i].x = min(max(panes[i].x, -panes[i].width + minPaneVisible), viewportW - minPaneVisible)
            panes[i].y = min(max(panes[i].y, -panes[i].height + minPaneVisible), viewportH - minPaneVisible)
        }
    }

    // MARK: - Repair Snaps

    /// Re-establish snap constraints between panes whose edges are touching
    /// but have no existing snap. Call on load to repair layouts saved with
    /// missing snaps.
    public mutating func repairSnaps(viewportW: Double, viewportH: Double) {
        let tolerance = snapDistance
        let paneCopies = panes

        let allEdges: [EdgeSide] = [.left, .right, .top, .bottom]

        for a in paneCopies {
            // Check against window edges
            for edge in allEdges {
                let coord = Self.paneEdgeCoord(a, edge)
                let winCoord = Self.windowEdgeCoord(edge, viewportW, viewportH)
                if abs(coord - winCoord) <= tolerance {
                    let exists = snaps.contains { s in
                        s.pane == a.id && s.edge == edge && s.target == .window(edge)
                    }
                    if !exists {
                        snaps.append(SnapConstraint(pane: a.id, edge: edge, target: .window(edge)))
                    }
                }
            }

            // Check against other panes (canonical Right->Left / Bottom->Top)
            for b in paneCopies {
                if a.id == b.id { continue }

                // Vertical: a.Right near b.Left
                if abs(Self.paneEdgeCoord(a, .right) - Self.paneEdgeCoord(b, .left)) <= tolerance {
                    if a.y < b.y + b.height && a.y + a.height > b.y {
                        let exists = snaps.contains { s in
                            s.pane == a.id && s.edge == .right && s.target == .pane(b.id, .left)
                        }
                        if !exists {
                            snaps.append(SnapConstraint(pane: a.id, edge: .right, target: .pane(b.id, .left)))
                        }
                    }
                }

                // Horizontal: a.Bottom near b.Top
                if abs(Self.paneEdgeCoord(a, .bottom) - Self.paneEdgeCoord(b, .top)) <= tolerance {
                    if a.x < b.x + b.width && a.x + a.width > b.x {
                        let exists = snaps.contains { s in
                            s.pane == a.id && s.edge == .bottom && s.target == .pane(b.id, .top)
                        }
                        if !exists {
                            snaps.append(SnapConstraint(pane: a.id, edge: .bottom, target: .pane(b.id, .top)))
                        }
                    }
                }
            }
        }
    }
}
