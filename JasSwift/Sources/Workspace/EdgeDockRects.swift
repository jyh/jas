/// Where the `Left` and `Bottom` anchored docks are drawn.
///
/// WORKSPACE.md §"Anchored Docks by Edge", "Where each edge dock is drawn".
/// The pane layout has no pane for these two edges, so they are cut from the
/// canvas pane's rectangle: no snap constraint, toolbar or Right-dock
/// position changes. The `Right` dock is the `Dock` pane and is not handled
/// here.
///
/// This is a pure function of the layout so that every app draws the same
/// rectangles. Swift implements it first (cargo frozen, O54); the Rust half
/// conforms to the spec text and its worked example, not to this file.

/// An axis-aligned rectangle in viewport coordinates.
public struct EdgeRect: Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

/// The rectangles of the left column, the bottom row and the canvas. An edge
/// that takes no space (no dock, or a dock with no groups) is `nil`.
public struct EdgeDockRects: Equatable {
    public var left: EdgeRect?
    public var bottom: EdgeRect?
    public var canvas: EdgeRect
}

/// A collapsed edge dock's thickness (rule 1).
public let collapsedEdgeDockThickness: Double = 36.0

/// A dock's extent across its edge (rule 1): its `width`, clamped to its own
/// `minWidth`...`maxDockWidth` as `setDockWidth` clamps it, or 36 when
/// collapsed.
public func edgeDockThickness(_ dock: Dock) -> Double {
    if dock.collapsed { return collapsedEdgeDockThickness }
    return max(dock.minWidth, min(dock.width, maxDockWidth))
}

/// Rules 2–5 and 8. `canvasPane` is the canvas pane's rectangle; when
/// `maximized`, the base is the whole viewport and the canvas keeps all of
/// it, with the edge docks drawn over it.
///
/// No reflow (the section's last paragraph): a pane too small for the docks
/// still gets them at their stated thickness. The canvas's extent is floored
/// at 0 so it is never negative.
public func edgeDockRects(left: Dock?, bottom: Dock?, canvasPane: EdgeRect,
                          maximized: Bool, viewportW: Double, viewportH: Double) -> EdgeDockRects {
    let base = maximized ? EdgeRect(x: 0, y: 0, w: viewportW, h: viewportH) : canvasPane
    let tL: Double? = left.flatMap { $0.groups.isEmpty ? nil : edgeDockThickness($0) }
    let tB: Double? = bottom.flatMap { $0.groups.isEmpty ? nil : edgeDockThickness($0) }

    // Rule 2: the left column, at the base's full height.
    let leftRect = tL.map { EdgeRect(x: base.x, y: base.y, w: $0, h: base.h) }
    // Rule 3: the bottom row starts at the left column's right side; the
    // bottom-left corner belongs to the left column.
    let rowX = base.x + (tL ?? 0)
    let rowW = max(0, base.x + base.w - rowX)
    let bottomRect = tB.map { EdgeRect(x: rowX, y: base.y + base.h - $0, w: rowW, h: $0) }

    // Rule 4 (and rule 8: a maximized canvas keeps the whole viewport).
    let canvas = maximized
        ? base
        : EdgeRect(x: rowX, y: base.y, w: rowW, h: max(0, base.h - (tB ?? 0)))
    return EdgeDockRects(left: leftRect, bottom: bottomRect, canvas: canvas)
}

extension WorkspaceLayout {
    /// The edge-dock rectangles for this layout's anchored `Left` and
    /// `Bottom` docks and its canvas pane, or `nil` with no pane layout or
    /// no canvas pane.
    public func edgeDockRects() -> EdgeDockRects? {
        guard let pl = paneLayout, let c = pl.paneByKind(.canvas) else { return nil }
        return JasLib.edgeDockRects(
            left: anchoredDock(.left), bottom: anchoredDock(.bottom),
            canvasPane: EdgeRect(x: c.x, y: c.y, w: c.width, h: c.height),
            maximized: pl.canvasMaximized,
            viewportW: pl.viewportWidth, viewportH: pl.viewportHeight)
    }

    /// The edge-dock rectangles cut from an APP's own canvas cell (jas 823),
    /// for an app whose pane layout is not its real geometry. Rule 8 reads
    /// this layout's `canvasMaximized`, `false` with no pane layout; the cell
    /// needs no pane layout, since it is the app's. Rust's
    /// `edge_dock_rects_in`; the corpus is `edge_dock_rects.json`.
    public func edgeDockRects(inCell cell: EdgeRect, viewportW: Double, viewportH: Double) -> EdgeDockRects {
        JasLib.edgeDockRects(
            left: anchoredDock(.left), bottom: anchoredDock(.bottom),
            canvasPane: cell,
            maximized: paneLayout?.canvasMaximized ?? false,
            viewportW: viewportW, viewportH: viewportH)
    }
}

/// The accessibility identifier of an edge dock's drawn container. It is the
/// web app's DOM id for the same dock (`jas-edge-dock-left` / `-bottom`), so
/// the two level-2 `--dock` checks read the drawing half by one name.
public func edgeDockAccessibilityId(_ edge: DockEdge) -> String {
    switch edge {
    case .left: return "jas-edge-dock-left"
    case .right: return "jas-edge-dock-right"
    case .bottom: return "jas-edge-dock-bottom"
    }
}
