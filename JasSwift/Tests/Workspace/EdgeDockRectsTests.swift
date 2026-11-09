import Testing
@testable import JasLib

// R1-3: WORKSPACE.md §"Anchored Docks by Edge", "Where each edge dock is
// drawn". These arms are written against the SPEC TEXT. Swift lands first
// while cargo is frozen (O54); the Rust half (R1-2) conforms to the same
// spec text and the same worked example, never to this port.

private func dock(_ id: Int, groups: Int = 1, width: Double,
                  collapsed: Bool = false, minWidth: Double = minDockWidth) -> Dock {
    Dock.fromParts(
        id: DockId(id),
        groups: (0..<groups).map { _ in PanelGroup(panels: [.layers]) },
        collapsed: collapsed, autoHide: false, width: width, minWidth: minWidth)
}

/// The worked example's canvas pane: viewport 1200×800, toolbar 72, Right
/// dock 240, so the canvas pane is x 72..960, y 0..800.
private let examplePane = EdgeRect(x: 72, y: 0, w: 888, h: 800)

private func rects(left: Dock? = nil, bottom: Dock? = nil,
                   pane: EdgeRect = examplePane, maximized: Bool = false) -> EdgeDockRects {
    edgeDockRects(left: left, bottom: bottom, canvasPane: pane,
                  maximized: maximized, viewportW: 1200, viewportH: 800)
}

// The spec's worked example, row by row.
@Test func edgeDockWorkedExample() {
    let r = rects(left: dock(1, width: 200), bottom: dock(2, width: 180))
    #expect(r.left == EdgeRect(x: 72, y: 0, w: 200, h: 800))
    #expect(r.bottom == EdgeRect(x: 272, y: 620, w: 688, h: 180))
    #expect(r.canvas == EdgeRect(x: 272, y: 0, w: 688, h: 620))
}

// The worked example's pane is the one the default three-pane layout
// builds, so the example is about the app's real starting state.
@Test func edgeDockExamplePaneIsTheDefaultCanvasPane() {
    let pl = PaneLayout.defaultThreePane(viewportW: 1200, viewportH: 800)
    let c = pl.paneByKind(.canvas)!
    #expect(EdgeRect(x: c.x, y: c.y, w: c.width, h: c.height) == examplePane)
}

// Rule 5: an empty or missing edge takes no space.
@Test func edgeDockNoEdgeDocksLeavesTheCanvasPaneWhole() {
    let r = rects()
    #expect(r.left == nil)
    #expect(r.bottom == nil)
    #expect(r.canvas == examplePane)
}

@Test func edgeDockWithNoGroupsTakesNoSpace() {
    let r = rects(left: dock(1, groups: 0, width: 200), bottom: dock(2, groups: 0, width: 180))
    #expect(r.left == nil)
    #expect(r.bottom == nil)
    #expect(r.canvas == examplePane)
}

// Rule 3: the bottom row starts at the pane's left side when there is no
// left column.
@Test func edgeDockBottomOnlyStartsAtThePaneLeft() {
    let r = rects(bottom: dock(2, width: 180))
    #expect(r.left == nil)
    #expect(r.bottom == EdgeRect(x: 72, y: 620, w: 888, h: 180))
    #expect(r.canvas == EdgeRect(x: 72, y: 0, w: 888, h: 620))
}

// Rule 2: the left column is the pane's full height with no bottom row.
@Test func edgeDockLeftOnlyRunsTheFullHeight() {
    let r = rects(left: dock(1, width: 200))
    #expect(r.left == EdgeRect(x: 72, y: 0, w: 200, h: 800))
    #expect(r.bottom == nil)
    #expect(r.canvas == EdgeRect(x: 272, y: 0, w: 688, h: 800))
}

// Rule 1: a collapsed edge dock is 36px thick, whatever its width.
@Test func edgeDockCollapsedIs36Thick() {
    let r = rects(left: dock(1, width: 200, collapsed: true),
                  bottom: dock(2, width: 180, collapsed: true))
    #expect(r.left == EdgeRect(x: 72, y: 0, w: 36, h: 800))
    #expect(r.bottom == EdgeRect(x: 108, y: 764, w: 852, h: 36))
    #expect(r.canvas == EdgeRect(x: 108, y: 0, w: 852, h: 764))
}

// Rule 1: thickness is clamped to the dock's OWN min_width (not
// MIN_DOCK_WIDTH) and to MAX_DOCK_WIDTH, as set_dock_width clamps it.
@Test func edgeDockThicknessClampsToItsOwnMinAndMax() {
    #expect(edgeDockThickness(dock(1, width: 10, minWidth: 120)) == 120)
    #expect(edgeDockThickness(dock(1, width: 10)) == minDockWidth)
    #expect(edgeDockThickness(dock(1, width: 9999)) == maxDockWidth)
    #expect(edgeDockThickness(dock(1, width: 200)) == 200)
    #expect(edgeDockThickness(dock(1, width: 10, collapsed: true)) == 36)
}

// Rule 8: canvas maximized — the canvas takes the whole viewport and the
// edge docks are drawn over it at the viewport's left and bottom edges.
@Test func edgeDockMaximizedDrawsOverTheWholeViewport() {
    let r = rects(left: dock(1, width: 200), bottom: dock(2, width: 180), maximized: true)
    #expect(r.left == EdgeRect(x: 0, y: 0, w: 200, h: 800))
    #expect(r.bottom == EdgeRect(x: 200, y: 620, w: 1000, h: 180))
    #expect(r.canvas == EdgeRect(x: 0, y: 0, w: 1200, h: 800))
}

// The no-reflow clause: a pane too small still gets the docks at their
// stated thickness; the canvas may go below MIN_CANVAS_WIDTH (never negative).
@Test func edgeDockTooSmallAPaneKeepsTheStatedThickness() {
    let pane = EdgeRect(x: 72, y: 0, w: 250, h: 800)
    let r = rects(left: dock(1, width: 200), pane: pane)
    #expect(r.left == EdgeRect(x: 72, y: 0, w: 200, h: 800))
    #expect(r.canvas == EdgeRect(x: 272, y: 0, w: 50, h: 800))
    #expect(r.canvas.w < minCanvasWidth)
}

// The layout-level entry reads the anchored Left and Bottom docks and the
// canvas pane; the Right dock never enters it.
@Test func edgeDockLayoutEntryReadsAnchoredDocksAndCanvasPane() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1200, viewportH: 800)
    pl.canvasMaximized = false
    let l = WorkspaceLayout.fromParts(
        version: layoutVersion, name: "T",
        anchored: [(.right, dock(0, width: 240)),
                   (.left, dock(1, width: 200)),
                   (.bottom, dock(2, width: 180))],
        floating: [], hiddenPanels: [], zOrder: [], focusedPanel: nil,
        appearance: "", paneLayout: pl, nextId: 3)
    let r = l.edgeDockRects()!
    #expect(r.left == EdgeRect(x: 72, y: 0, w: 200, h: 800))
    #expect(r.bottom == EdgeRect(x: 272, y: 620, w: 688, h: 180))
    #expect(r.canvas == EdgeRect(x: 272, y: 0, w: 688, h: 620))
}
