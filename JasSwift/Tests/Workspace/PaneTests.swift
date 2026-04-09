import Testing
@testable import JasLib

// MARK: - Initialization & Lookup

@Test func defaultThreePaneFillsViewport() {
    let pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    #expect(pl.panes.count == 3)
    let toolbar = pl.paneByKind(.toolbar)!
    let canvas = pl.paneByKind(.canvas)!
    let dock = pl.paneByKind(.dock)!
    #expect(toolbar.x == 0)
    #expect(toolbar.width == defaultToolbarWidth)
    #expect(canvas.x == toolbar.x + toolbar.width)
    #expect(dock.x == canvas.x + canvas.width)
    let total = toolbar.width + canvas.width + dock.width
    #expect(abs(total - 1000) < 0.001)
    #expect(toolbar.height == 700)
    #expect(canvas.height == 700)
    #expect(dock.height == 700)
}

@Test func defaultThreePaneSnapCount() {
    let pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    #expect(pl.snaps.count == 10)
}

@Test func paneLookupById() {
    let pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    #expect(pl.pane(PaneId(0)) != nil)
    #expect(pl.pane(PaneId(1)) != nil)
    #expect(pl.pane(PaneId(2)) != nil)
}

@Test func paneLookupByKind() {
    let pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    #expect(pl.paneByKind(.toolbar)!.kind == .toolbar)
    #expect(pl.paneByKind(.canvas)!.kind == .canvas)
    #expect(pl.paneByKind(.dock)!.kind == .dock)
}

@Test func paneLookupInvalidId() {
    let pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    #expect(pl.pane(PaneId(99)) == nil)
}

@Test func paneConfigDefaults() {
    let tc = PaneConfig.forKind(.toolbar)
    #expect(tc.minWidth == minToolbarWidth)
    #expect(tc.fixedWidth)
    #expect(tc.closable)
    #expect(!tc.maximizable)

    let cc = PaneConfig.forKind(.canvas)
    #expect(cc.minWidth == minCanvasWidth)
    #expect(!cc.fixedWidth)
    #expect(!cc.closable)
    #expect(cc.maximizable)

    let dc = PaneConfig.forKind(.dock)
    #expect(dc.minWidth == minPaneDockWidth)
    #expect(!dc.fixedWidth)
    #expect(dc.closable)
    #expect(dc.collapsible)
}

// MARK: - Position & Sizing

@Test func setPanePositionMovesPane() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let id = pl.paneByKind(.canvas)!.id
    pl.setPanePosition(id, x: 100, y: 50)
    let p = pl.pane(id)!
    #expect(p.x == 100)
    #expect(p.y == 50)
}

@Test func setPanePositionClearsSnaps() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let canvasId = pl.paneByKind(.canvas)!.id
    let snapsBefore = pl.snaps.count
    #expect(snapsBefore > 0)
    pl.setPanePosition(canvasId, x: 200, y: 200)
    let hasCanvasSnap = pl.snaps.contains { s in
        s.pane == canvasId || {
            if case .pane(let pid, _) = s.target { return pid == canvasId }
            return false
        }()
    }
    #expect(!hasCanvasSnap)
    #expect(pl.snaps.count < snapsBefore)
}

@Test func resizePaneClampsMinToolbar() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let id = pl.paneByKind(.toolbar)!.id
    pl.resizePane(id, width: 10, height: 10)
    let p = pl.pane(id)!
    #expect(p.width == minToolbarWidth)
    #expect(p.height == minToolbarHeight)
}

@Test func resizePaneClampsMinCanvas() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let id = pl.paneByKind(.canvas)!.id
    pl.resizePane(id, width: 10, height: 10)
    let p = pl.pane(id)!
    #expect(p.width == minCanvasWidth)
    #expect(p.height == minCanvasHeight)
}

@Test func resizePaneClampsMinDock() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let id = pl.paneByKind(.dock)!.id
    pl.resizePane(id, width: 10, height: 10)
    let p = pl.pane(id)!
    #expect(p.width == minPaneDockWidth)
    #expect(p.height == minPaneDockHeight)
}

@Test func resizePaneAcceptsLargeValues() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let id = pl.paneByKind(.canvas)!.id
    pl.resizePane(id, width: 800, height: 600)
    let p = pl.pane(id)!
    #expect(p.width == 800)
    #expect(p.height == 600)
}

// MARK: - Snap Detection

@Test func detectSnapsNearWindowEdge() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let canvasId = pl.paneByKind(.canvas)!.id
    pl.setPanePosition(canvasId, x: 5, y: 0)
    let snaps = pl.detectSnaps(dragged: canvasId, viewportW: 1000, viewportH: 700)
    #expect(snaps.contains { s in
        s.pane == canvasId && s.edge == .left && s.target == .window(.left)
    })
}

@Test func detectSnapsNearOtherPane() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let canvasId = pl.paneByKind(.canvas)!.id
    let toolbar = pl.paneByKind(.toolbar)!
    let toolbarRight = toolbar.x + toolbar.width
    let toolbarId = toolbar.id
    pl.setPanePosition(canvasId, x: toolbarRight + 5, y: 0)
    let snaps = pl.detectSnaps(dragged: canvasId, viewportW: 1000, viewportH: 700)
    #expect(snaps.contains { s in
        s.pane == toolbarId && s.edge == .right && s.target == .pane(canvasId, .left)
    })
}

@Test func detectSnapsNoMatch() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let canvasId = pl.paneByKind(.canvas)!.id
    pl.setPanePosition(canvasId, x: 400, y: 300)
    pl.resizePane(canvasId, width: 200, height: 200)
    let snaps = pl.detectSnaps(dragged: canvasId, viewportW: 1000, viewportH: 700)
    #expect(snaps.isEmpty)
}

// MARK: - Snap Application

@Test func applySnapsAlignsPosition() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let canvasId = pl.paneByKind(.canvas)!.id
    pl.setPanePosition(canvasId, x: 5, y: 3)
    let newSnaps = [
        SnapConstraint(pane: canvasId, edge: .left, target: .window(.left)),
        SnapConstraint(pane: canvasId, edge: .top, target: .window(.top)),
    ]
    pl.applySnaps(canvasId, newSnaps: newSnaps, viewportW: 1000, viewportH: 700)
    let p = pl.pane(canvasId)!
    #expect(p.x == 0)
    #expect(p.y == 0)
}

@Test func applySnapsAlignsViaNormalizedPaneSnap() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let canvasId = pl.paneByKind(.canvas)!.id
    let toolbarId = pl.paneByKind(.toolbar)!.id
    pl.setPanePosition(canvasId, x: 80, y: 0)
    let newSnaps = [
        SnapConstraint(pane: toolbarId, edge: .right, target: .pane(canvasId, .left)),
    ]
    pl.applySnaps(canvasId, newSnaps: newSnaps, viewportW: 1000, viewportH: 700)
    let p = pl.pane(canvasId)!
    #expect(abs(p.x - 72) < 0.001)
}

@Test func dragCanvasSnapToToolbarFullWorkflow() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let canvasId = pl.paneByKind(.canvas)!.id

    // 1. Drag canvas away
    pl.setPanePosition(canvasId, x: 300, y: 100)
    #expect(pl.snaps.allSatisfy { s in
        s.pane != canvasId && {
            if case .pane(let pid, _) = s.target { return pid != canvasId }
            return true
        }()
    })

    // 2. Drag back near toolbar
    pl.setPanePosition(canvasId, x: 77, y: 0)

    // 3. Detect snaps
    let snaps = pl.detectSnaps(dragged: canvasId, viewportW: 1000, viewportH: 700)
    let toolbarSnap = snaps.first { s in
        s.edge == .right && {
            if case .pane(let pid, .left) = s.target { return pid == canvasId }
            return false
        }()
    }
    #expect(toolbarSnap != nil)

    // 4. Apply snaps
    pl.applySnaps(canvasId, newSnaps: snaps, viewportW: 1000, viewportH: 700)

    // 5. Canvas aligned to toolbar right edge
    let canvas = pl.pane(canvasId)!
    #expect(abs(canvas.x - 72) < 0.001)

    // 6. Shared border findable
    let border = pl.sharedBorderAt(x: 72, y: 350, tolerance: borderHitTolerance)
    #expect(border != nil)
}

@Test func applySnapsReplacesOld() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let canvasId = pl.paneByKind(.canvas)!.id
    let oldCount = pl.snaps.count
    let newSnaps = [
        SnapConstraint(pane: canvasId, edge: .left, target: .window(.left)),
    ]
    pl.applySnaps(canvasId, newSnaps: newSnaps, viewportW: 1000, viewportH: 700)
    #expect(pl.snaps.count < oldCount)
    #expect(pl.snaps.contains { $0.pane == canvasId && $0.edge == .left })
}

@Test func alignToSnapsDoesNotModifySnapList() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let canvasId = pl.paneByKind(.canvas)!.id
    let toolbarId = pl.paneByKind(.toolbar)!.id
    pl.setPanePosition(canvasId, x: 80, y: 5)
    let snapsBefore = pl.snaps.count
    let newSnaps = [
        SnapConstraint(pane: toolbarId, edge: .right, target: .pane(canvasId, .left)),
        SnapConstraint(pane: canvasId, edge: .top, target: .window(.top)),
    ]
    pl.alignToSnaps(canvasId, snaps: newSnaps, viewportW: 1000, viewportH: 700)
    #expect(pl.snaps.count == snapsBefore)
    let p = pl.pane(canvasId)!
    #expect(abs(p.x - 72) < 0.001)
    #expect(p.y == 0)
}

// MARK: - Shared Border

@Test func sharedBorderAtVertical() {
    let pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let toolbar = pl.paneByKind(.toolbar)!
    let borderX = toolbar.x + toolbar.width
    let result = pl.sharedBorderAt(x: borderX, y: 350, tolerance: borderHitTolerance)
    #expect(result != nil)
    let (_, orientation) = result!
    #expect(orientation == .left)
}

@Test func sharedBorderAtMiss() {
    let pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let result = pl.sharedBorderAt(x: 500, y: 350, tolerance: borderHitTolerance)
    #expect(result == nil)
}

@Test func dragSharedBorderWidensLeftNarrowsRight() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let canvas = pl.paneByKind(.canvas)!
    let borderX = canvas.x + canvas.width
    let (snapIdx, _) = pl.sharedBorderAt(x: borderX, y: 350, tolerance: borderHitTolerance)!

    let canvasWBefore = pl.paneByKind(.canvas)!.width
    let dockWBefore = pl.paneByKind(.dock)!.width
    let dockXBefore = pl.paneByKind(.dock)!.x

    pl.dragSharedBorder(snapIdx: snapIdx, delta: 30)

    let canvasWAfter = pl.paneByKind(.canvas)!.width
    let dockWAfter = pl.paneByKind(.dock)!.width
    let dockXAfter = pl.paneByKind(.dock)!.x

    #expect(abs(canvasWAfter - (canvasWBefore + 30)) < 0.001)
    #expect(abs(dockWAfter - (dockWBefore - 30)) < 0.001)
    #expect(abs(dockXAfter - (dockXBefore + 30)) < 0.001)
}

@Test func dragSharedBorderToolbarIsFixed() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let toolbar = pl.paneByKind(.toolbar)!
    let borderX = toolbar.x + toolbar.width
    let result = pl.sharedBorderAt(x: borderX, y: 350, tolerance: borderHitTolerance)
    #expect(result != nil)
    let (snapIdx, _) = result!
    let toolbarWBefore = pl.paneByKind(.toolbar)!.width
    pl.dragSharedBorder(snapIdx: snapIdx, delta: 30)
    let toolbarWAfter = pl.paneByKind(.toolbar)!.width
    #expect(abs(toolbarWAfter - toolbarWBefore) < 0.001)
}

@Test func dragSharedBorderRespectsMinSize() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let toolbar = pl.paneByKind(.toolbar)!
    let borderX = toolbar.x + toolbar.width
    let (snapIdx, _) = pl.sharedBorderAt(x: borderX, y: 350, tolerance: borderHitTolerance)!
    pl.dragSharedBorder(snapIdx: snapIdx, delta: -5000)
    let toolbar2 = pl.paneByKind(.toolbar)!
    #expect(toolbar2.width >= minToolbarWidth)
}

@Test func dragSharedBorderPropagatesToChainedPane() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let toolbar = pl.paneByKind(.toolbar)!
    let borderX = toolbar.x + toolbar.width
    let (snapIdx, _) = pl.sharedBorderAt(x: borderX, y: 350, tolerance: borderHitTolerance)!

    pl.dragSharedBorder(snapIdx: snapIdx, delta: 30)

    let canvas = pl.paneByKind(.canvas)!
    let dock = pl.paneByKind(.dock)!
    #expect(abs(canvas.x + canvas.width - dock.x) < 0.001)
}

// MARK: - Z-Order & Visibility

@Test func bringPaneToFront() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let toolbarId = pl.paneByKind(.toolbar)!.id
    let dockId = pl.paneByKind(.dock)!.id
    #expect(pl.zOrder.last == dockId)
    pl.bringPaneToFront(toolbarId)
    #expect(pl.zOrder.last == toolbarId)
}

@Test func paneZIndexOrdering() {
    let pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let canvasId = pl.paneByKind(.canvas)!.id
    let toolbarId = pl.paneByKind(.toolbar)!.id
    let dockId = pl.paneByKind(.dock)!.id
    #expect(pl.paneZIndex(canvasId) < pl.paneZIndex(toolbarId))
    #expect(pl.paneZIndex(toolbarId) < pl.paneZIndex(dockId))
}

@Test func hideShowPaneRoundTrip() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    #expect(pl.isPaneVisible(.toolbar))
    pl.hidePane(.toolbar)
    #expect(!pl.isPaneVisible(.toolbar))
    pl.showPane(.toolbar)
    #expect(pl.isPaneVisible(.toolbar))
}

@Test func hidePaneIdempotent() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    pl.hidePane(.dock)
    pl.hidePane(.dock)
    #expect(pl.hiddenPanes.count == 1)
}

@Test func showPaneNotHiddenIsNoop() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let countBefore = pl.hiddenPanes.count
    pl.showPane(.canvas)
    #expect(pl.hiddenPanes.count == countBefore)
}

// MARK: - Viewport Resize

@Test func onViewportResizeProportional() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let canvasWBefore = pl.paneByKind(.canvas)!.width
    pl.onViewportResize(newW: 2000, newH: 700)
    let canvasWAfter = pl.paneByKind(.canvas)!.width
    #expect(abs(canvasWAfter - canvasWBefore * 2) < 1)
}

@Test func onViewportResizeClampsMin() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    pl.onViewportResize(newW: 100, newH: 100)
    for p in pl.panes {
        #expect(p.width >= p.config.minWidth)
        #expect(p.height >= p.config.minHeight)
    }
}

// MARK: - Utilities

@Test func clampPanesOffscreen() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let id = pl.paneByKind(.canvas)!.id
    pl.setPanePosition(id, x: 5000, y: 5000)
    pl.clampPanes(viewportW: 1000, viewportH: 700)
    let p = pl.pane(id)!
    #expect(p.x <= 1000 - minPaneVisible)
    #expect(p.y <= 700 - minPaneVisible)
}

@Test func toggleCanvasMaximized() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    #expect(!pl.canvasMaximized)
    pl.toggleCanvasMaximized()
    #expect(pl.canvasMaximized)
    pl.toggleCanvasMaximized()
    #expect(!pl.canvasMaximized)
}

@Test func repairSnapsAddsMissing() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    pl.snaps.removeAll()
    pl.repairSnaps(viewportW: 1000, viewportH: 700)
    let toolbarId = pl.paneByKind(.toolbar)!.id
    let canvasId = pl.paneByKind(.canvas)!.id
    #expect(pl.snaps.contains { s in
        s.pane == toolbarId && s.edge == .right && s.target == .pane(canvasId, .left)
    })
}

@Test func repairSnapsNoDuplicates() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let countBefore = pl.snaps.count
    pl.repairSnaps(viewportW: 1000, viewportH: 700)
    #expect(pl.snaps.count == countBefore)
}

// MARK: - Tiling

@Test func tilePanesFillsViewport() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    pl.tilePanes(collapsedOverride: nil)
    let t = pl.paneByKind(.toolbar)!
    let c = pl.paneByKind(.canvas)!
    let d = pl.paneByKind(.dock)!
    #expect(t.x == 0)
    #expect(c.x == t.x + t.width)
    #expect(d.x == c.x + c.width)
    #expect(abs(t.width + c.width + d.width - 1000) < 0.001)
    #expect(t.height == 700)
    #expect(c.height == 700)
    #expect(d.height == 700)
    #expect(t.width == defaultToolbarWidth)
}

@Test func tilePanesCollapsedDock() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    let dockId = pl.paneByKind(.dock)!.id
    pl.tilePanes(collapsedOverride: (dockId, 36))
    let d = pl.paneByKind(.dock)!
    let c = pl.paneByKind(.canvas)!
    #expect(d.width == 36)
    #expect(abs(c.width - (1000 - defaultToolbarWidth - 36)) < 0.001)
    #expect(abs(d.x + d.width - 1000) < 0.001)
}

@Test func tilePanesClearsHidden() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    pl.hidePane(.toolbar)
    pl.hidePane(.dock)
    #expect(pl.hiddenPanes.count == 2)
    pl.tilePanes(collapsedOverride: nil)
    #expect(pl.hiddenPanes.isEmpty)
}

@Test func tilePanesRebuildsSnaps() {
    var pl = PaneLayout.defaultThreePane(viewportW: 1000, viewportH: 700)
    pl.snaps.removeAll()
    pl.tilePanes(collapsedOverride: nil)
    #expect(!pl.snaps.isEmpty)
    let toolbarId = pl.paneByKind(.toolbar)!.id
    let canvasId = pl.paneByKind(.canvas)!.id
    #expect(pl.snaps.contains { s in
        s.pane == toolbarId && s.edge == .right && s.target == .pane(canvasId, .left)
    })
}
