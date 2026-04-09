import Testing
@testable import JasLib

// MARK: - RenderingState tests

@Test func renderingStateFromDefaultLayout() {
    let pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let rs = RenderingState.from(pl)
    #expect(rs.panes.count == 3)
    #expect(!rs.canvasMaximized)
    // All panes visible
    #expect(rs.panes.allSatisfy { $0.visible })
}

@Test func renderingStatePanePositions() {
    let pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let rs = RenderingState.from(pl)
    let toolbar = rs.panes.first { $0.kind == .toolbar }!
    let canvas = rs.panes.first { $0.kind == .canvas }!
    let dock = rs.panes.first { $0.kind == .dock }!
    #expect(toolbar.x == 0)
    #expect(toolbar.width == defaultToolbarWidth)
    #expect(abs(canvas.x - (toolbar.x + toolbar.width)) < 0.001)
    #expect(abs(dock.x - (canvas.x + canvas.width)) < 0.001)
    #expect(toolbar.height == 700)
    #expect(canvas.height == 700)
    #expect(dock.height == 700)
}

@Test func renderingStateCanvasMaximized() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    pl.toggleCanvasMaximized()
    let rs = RenderingState.from(pl)
    #expect(rs.canvasMaximized)
    let canvas = rs.panes.first { $0.kind == .canvas }!
    #expect(canvas.x == 0)
    #expect(canvas.y == 0)
    #expect(canvas.width == 1000)
    #expect(canvas.height == 700)
    #expect(canvas.zIndex == 0)
}

@Test func renderingStateHiddenPane() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    pl.hidePane(.toolbar)
    let rs = RenderingState.from(pl)
    let toolbar = rs.panes.first { $0.kind == .toolbar }!
    #expect(!toolbar.visible)
    let canvas = rs.panes.first { $0.kind == .canvas }!
    #expect(canvas.visible)
}

@Test func renderingStateZOrder() {
    let pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let rs = RenderingState.from(pl)
    let canvas = rs.panes.first { $0.kind == .canvas }!
    let toolbar = rs.panes.first { $0.kind == .toolbar }!
    let dock = rs.panes.first { $0.kind == .dock }!
    // Default z-order: canvas(0) < toolbar(1) < dock(2)
    #expect(canvas.zIndex < toolbar.zIndex)
    #expect(toolbar.zIndex < dock.zIndex)
}

@Test func renderingStateSharedBorders() {
    let pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let rs = RenderingState.from(pl)
    // Default layout has toolbar|canvas and canvas|dock borders
    #expect(rs.borders.count == 2)
    #expect(rs.borders.allSatisfy { $0.isVertical })
    #expect(rs.borders.allSatisfy { $0.height == 700 })
}

@Test func renderingStateNoBordersWhenMaximized() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    pl.toggleCanvasMaximized()
    let rs = RenderingState.from(pl)
    #expect(rs.borders.isEmpty)
}

@Test func snapLinesComputation() {
    let pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let canvasId = pl.paneByKind(.canvas)!.id
    // Create snap preview with window left and top snaps
    let preview = [
        SnapConstraint(pane: canvasId, edge: .left, target: .window(.left)),
        SnapConstraint(pane: canvasId, edge: .top, target: .window(.top)),
    ]
    let lines = RenderingState.snapLines(from: preview, paneLayout: pl)
    #expect(lines.count == 2)
    // Left edge snap line: vertical line at pane's left edge
    let leftLine = lines.first { $0.width == 4 && $0.height > 4 }
    #expect(leftLine != nil)
}

@Test func renderingStateFromNilLayout() {
    let rs = RenderingState.from(nil)
    #expect(rs.panes.isEmpty)
    #expect(rs.borders.isEmpty)
    #expect(!rs.canvasMaximized)
}
