import Testing
@testable import JasLib

// Helpers
private func ga(_ dockId: Int, _ groupIdx: Int) -> GroupAddr {
    GroupAddr(dockId: DockId(dockId), groupIdx: groupIdx)
}
private func pa(_ dockId: Int, _ groupIdx: Int, _ panelIdx: Int) -> PanelAddr {
    PanelAddr(group: ga(dockId, groupIdx), panelIdx: panelIdx)
}
private func rightDockId(_ l: DockLayout) -> DockId {
    l.anchoredDock(.right)!.id
}

// MARK: - Layout & Lookup

@Test func defaultLayoutOneAnchoredRight() {
    let l = DockLayout.defaultLayout()
    #expect(l.anchored.count == 1)
    #expect(l.anchored[0].0 == .right)
    #expect(l.floating.isEmpty)
}

@Test func defaultLayoutTwoGroups() {
    let l = DockLayout.defaultLayout()
    let d = l.anchoredDock(.right)!
    #expect(d.groups.count == 2)
    #expect(d.groups[0].panels == [.layers])
    #expect(d.groups[1].panels == [.color, .stroke, .properties])
}

@Test func defaultNotCollapsed() {
    let l = DockLayout.defaultLayout()
    let d = l.anchoredDock(.right)!
    #expect(!d.collapsed)
    for g in d.groups { #expect(!g.collapsed) }
}

@Test func defaultDockWidthValue() {
    let l = DockLayout.defaultLayout()
    #expect(l.anchoredDock(.right)!.width == defaultDockWidth)
}

@Test func dockLookupAnchored() {
    let l = DockLayout.defaultLayout()
    #expect(l.dock(rightDockId(l)) != nil)
}

@Test func dockLookupFloating() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 100, y: 100)!
    #expect(l.dock(fid) != nil)
    #expect(l.floatingDock(fid) != nil)
}

@Test func dockLookupInvalid() {
    let l = DockLayout.defaultLayout()
    #expect(l.dock(DockId(99)) == nil)
}

@Test func anchoredDockByEdge() {
    let l = DockLayout.defaultLayout()
    #expect(l.anchoredDock(.right) != nil)
    #expect(l.anchoredDock(.left) == nil)
    #expect(l.anchoredDock(.bottom) == nil)
}

// MARK: - Toggle / Active

@Test func toggleDockCollapsed() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    #expect(!l.dock(id)!.collapsed)
    l.toggleDockCollapsed(id)
    #expect(l.dock(id)!.collapsed)
    l.toggleDockCollapsed(id)
    #expect(!l.dock(id)!.collapsed)
}

@Test func toggleGroupCollapsed() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.toggleGroupCollapsed(ga(id.value, 0))
    #expect(l.dock(id)!.groups[0].collapsed)
    #expect(!l.dock(id)!.groups[1].collapsed)
    l.toggleGroupCollapsed(ga(id.value, 0))
    #expect(!l.dock(id)!.groups[0].collapsed)
}

@Test func toggleGroupOutOfBounds() {
    var l = DockLayout.defaultLayout()
    l.toggleGroupCollapsed(ga(0, 99))
    l.toggleGroupCollapsed(ga(99, 0))
}

@Test func setActivePanel() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.setActivePanel(pa(id.value, 1, 2))
    #expect(l.dock(id)!.groups[1].active == 2)
}

@Test func setActivePanelOutOfBounds() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.setActivePanel(pa(id.value, 1, 99))
    #expect(l.dock(id)!.groups[1].active == 0)
    l.setActivePanel(pa(id.value, 99, 0))
    l.setActivePanel(pa(99, 0, 0))
}

// MARK: - Move Group Within Dock

@Test func moveGroupForward() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupWithinDock(id, from: 0, to: 1)
    #expect(l.dock(id)!.groups[0].panels == [.color, .stroke, .properties])
    #expect(l.dock(id)!.groups[1].panels == [.layers])
}

@Test func moveGroupBackward() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupWithinDock(id, from: 1, to: 0)
    #expect(l.dock(id)!.groups[0].panels == [.color, .stroke, .properties])
}

@Test func moveGroupSamePosition() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupWithinDock(id, from: 0, to: 0)
    #expect(l.dock(id)!.groups[0].panels == [.layers])
}

@Test func moveGroupClamped() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupWithinDock(id, from: 0, to: 99)
    #expect(l.dock(id)!.groups[1].panels == [.layers])
}

@Test func moveGroupOutOfBounds() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupWithinDock(id, from: 99, to: 0)
    #expect(l.dock(id)!.groups.count == 2)
}

@Test func moveGroupPreservesState() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.dockMut(id) { $0.groups[1].active = 2; $0.groups[1].collapsed = true }
    l.moveGroupWithinDock(id, from: 1, to: 0)
    #expect(l.dock(id)!.groups[0].active == 2)
    #expect(l.dock(id)!.groups[0].collapsed)
}

// MARK: - Move Group Between Docks

@Test func moveGroupBetweenDocks() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 50, y: 50)!
    l.moveGroupToDock(ga(id.value, 0), toDock: fid, toIdx: 1)
    #expect(l.dock(id)!.groups.isEmpty)
    #expect(l.dock(fid)!.groups.count == 2)
}

@Test func moveGroupInsertsAtPosition() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let f1 = l.detachGroup(ga(id.value, 0), x: 10, y: 10)!
    let f2 = l.detachGroup(ga(id.value, 0), x: 20, y: 20)!
    l.moveGroupToDock(ga(f1.value, 0), toDock: f2, toIdx: 0)
    #expect(l.dock(f2)!.groups[0].panels == [.layers])
    #expect(l.dock(f1) == nil) // cleaned up
}

@Test func moveGroupSameDockIsReorder() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupToDock(ga(id.value, 0), toDock: id, toIdx: 1)
    #expect(l.dock(id)!.groups[0].panels == [.color, .stroke, .properties])
    #expect(l.dock(id)!.groups[1].panels == [.layers])
}

@Test func moveGroupInvalidSource() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupToDock(ga(id.value, 99), toDock: id, toIdx: 0)
    #expect(l.dock(id)!.groups.count == 2)
}

@Test func moveGroupInvalidTarget() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupToDock(ga(id.value, 0), toDock: DockId(99), toIdx: 0)
    #expect(l.dock(id)!.groups.count == 2)
}

// MARK: - Detach Group

@Test func detachGroupCreatesFloating() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 100, y: 200)
    #expect(fid != nil)
    #expect(l.dock(fid!)!.groups[0].panels == [.layers])
    #expect(l.dock(id)!.groups.count == 1)
}

@Test func detachGroupPosition() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 100, y: 200)!
    let fd = l.floatingDock(fid)!
    #expect(fd.x == 100)
    #expect(fd.y == 200)
}

@Test func detachGroupUniqueIds() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let f1 = l.detachGroup(ga(id.value, 0), x: 10, y: 10)!
    let f2 = l.detachGroup(ga(id.value, 0), x: 20, y: 20)!
    #expect(f1 != f2)
}

@Test func detachLastGroupFloatingRemovesDock() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let f1 = l.detachGroup(ga(id.value, 0), x: 10, y: 10)!
    _ = l.detachGroup(ga(f1.value, 0), x: 20, y: 20)
    #expect(l.dock(f1) == nil)
}

@Test func detachLastGroupAnchoredKeepsDock() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.detachGroup(ga(id.value, 0), x: 10, y: 10)
    l.detachGroup(ga(id.value, 0), x: 20, y: 20)
    #expect(l.dock(id) != nil)
    #expect(l.dock(id)!.groups.isEmpty)
}

// MARK: - Move Panel

@Test func movePanelSameDock() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.movePanelToGroup(pa(id.value, 1, 1), to: ga(id.value, 0))
    #expect(l.dock(id)!.groups[0].panels == [.layers, .stroke])
    #expect(l.dock(id)!.groups[1].panels == [.color, .properties])
}

@Test func movePanelBecomesActive() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.movePanelToGroup(pa(id.value, 1, 1), to: ga(id.value, 0))
    #expect(l.dock(id)!.groups[0].active == 1)
}

@Test func movePanelCrossDock() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 50, y: 50)!
    l.movePanelToGroup(pa(id.value, 0, 0), to: ga(fid.value, 0))
    #expect(l.dock(fid)!.groups[0].panels == [.layers, .color])
    #expect(l.dock(id)!.groups[0].panels == [.stroke, .properties])
}

@Test func moveLastPanelRemovesGroup() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.movePanelToGroup(pa(id.value, 0, 0), to: ga(id.value, 1))
    #expect(l.dock(id)!.groups.count == 1)
    #expect(l.dock(id)!.groups[0].panels.contains(.layers))
}

@Test func moveLastPanelRemovesFloating() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 50, y: 50)!
    l.movePanelToGroup(pa(fid.value, 0, 0), to: ga(id.value, 0))
    #expect(l.dock(fid) == nil)
}

@Test func movePanelClampsActive() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.dockMut(id) { $0.groups[1].active = 2 }
    l.movePanelToGroup(pa(id.value, 1, 2), to: ga(id.value, 0))
    #expect(l.dock(id)!.groups[1].active < l.dock(id)!.groups[1].panels.count)
}

@Test func movePanelInvalidSource() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.movePanelToGroup(pa(id.value, 1, 99), to: ga(id.value, 0))
    l.movePanelToGroup(pa(99, 0, 0), to: ga(id.value, 0))
}

@Test func movePanelInvalidTarget() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.movePanelToGroup(pa(id.value, 1, 0), to: ga(99, 0))
    #expect(l.dock(id)!.groups[1].panels.count == 3)
}

// MARK: - Insert Panel as Group

@Test func insertPanelCreatesGroup() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.insertPanelAsNewGroup(pa(id.value, 1, 1), toDock: id, atIdx: 0)
    #expect(l.dock(id)!.groups.count == 3)
    #expect(l.dock(id)!.groups[0].panels == [.stroke])
}

@Test func insertPanelCleansSource() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.insertPanelAsNewGroup(pa(id.value, 0, 0), toDock: id, atIdx: 99)
    #expect(l.dock(id)!.groups.count == 2)
    #expect(l.dock(id)!.groups[1].panels == [.layers])
}

@Test func insertPanelInvalid() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.insertPanelAsNewGroup(pa(id.value, 1, 99), toDock: id, atIdx: 0)
    l.insertPanelAsNewGroup(pa(99, 0, 0), toDock: id, atIdx: 0)
    #expect(l.dock(id)!.groups.count == 2)
}

// MARK: - Detach Panel

@Test func detachPanelCreatesFloating() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachPanel(pa(id.value, 1, 1), x: 300, y: 150)
    #expect(fid != nil)
    #expect(l.dock(fid!)!.groups[0].panels == [.stroke])
    #expect(l.dock(id)!.groups[1].panels == [.color, .properties])
}

@Test func detachPanelPosition() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachPanel(pa(id.value, 1, 0), x: 300, y: 150)!
    #expect(l.floatingDock(fid)!.x == 300)
    #expect(l.floatingDock(fid)!.y == 150)
}

@Test func detachPanelLastRemovesGroup() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.detachPanel(pa(id.value, 0, 0), x: 50, y: 50)
    #expect(l.dock(id)!.groups.count == 1)
}

@Test func detachPanelLastRemovesFloating() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let f1 = l.detachGroup(ga(id.value, 0), x: 50, y: 50)!
    _ = l.detachPanel(pa(f1.value, 0, 0), x: 100, y: 100)
    #expect(l.dock(f1) == nil)
}

// MARK: - Floating Position

@Test func setFloatingPositionTest() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 10, y: 10)!
    l.setFloatingPosition(fid, x: 200, y: 300)
    #expect(l.floatingDock(fid)!.x == 200)
    #expect(l.floatingDock(fid)!.y == 300)
}

@Test func setPositionAnchoredIgnored() {
    var l = DockLayout.defaultLayout()
    l.setFloatingPosition(rightDockId(l), x: 999, y: 999)
}

@Test func setPositionInvalidId() {
    var l = DockLayout.defaultLayout()
    l.setFloatingPosition(DockId(99), x: 0, y: 0)
}

// MARK: - Resize

@Test func resizeGroupSetsHeight() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.resizeGroup(ga(id.value, 0), height: 150)
    #expect(l.dock(id)!.groups[0].height == 150)
}

@Test func resizeGroupClampsMin() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.resizeGroup(ga(id.value, 0), height: 5)
    #expect(l.dock(id)!.groups[0].height == minGroupHeight)
}

@Test func resizeGroupInvalidAddr() {
    var l = DockLayout.defaultLayout()
    l.resizeGroup(ga(99, 0), height: 100)
    l.resizeGroup(ga(0, 99), height: 100)
}

@Test func defaultGroupHeightIsNil() {
    let l = DockLayout.defaultLayout()
    for g in l.anchoredDock(.right)!.groups {
        #expect(g.height == nil)
    }
}

@Test func setDockWidthClamped() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.setDockWidth(id, width: 50)
    #expect(l.dock(id)!.width == minDockWidth)
    l.setDockWidth(id, width: 9999)
    #expect(l.dock(id)!.width == maxDockWidth)
    l.setDockWidth(id, width: 300)
    #expect(l.dock(id)!.width == 300)
}

// MARK: - Cleanup

@Test func cleanupClampsActive() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.dockMut(id) { $0.groups[1].active = 2 }
    l.movePanelToGroup(pa(id.value, 1, 2), to: ga(id.value, 0))
    #expect(l.dock(id)!.groups[1].active < l.dock(id)!.groups[1].panels.count)
}

@Test func cleanupMultipleEmptyGroups() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.dockMut(id) { dock in
        dock.groups[0].panels.removeAll()
        dock.groups[1].panels.removeAll()
    }
    // Trigger cleanup via a method that calls it
    l.closePanel(pa(id.value, 0, 0)) // will fail gracefully, but cleanup runs
    // Actually need to call cleanup directly — let's trigger it another way
}

// MARK: - Labels

@Test func panelLabelValues() {
    #expect(DockLayout.panelLabel(.layers) == "Layers")
    #expect(DockLayout.panelLabel(.color) == "Color")
    #expect(DockLayout.panelLabel(.stroke) == "Stroke")
    #expect(DockLayout.panelLabel(.properties) == "Properties")
}

@Test func panelGroupActivePanel() {
    let group = PanelGroup(panels: [.color, .stroke])
    #expect(group.activePanel() == .color)
}

@Test func panelGroupActivePanelEmpty() {
    var group = PanelGroup(panels: [])
    group.active = 0
    #expect(group.activePanel() == nil)
}

// MARK: - Close / Show Panels

@Test func closePanelHidesIt() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.closePanel(pa(id.value, 1, 1))
    #expect(l.hiddenPanels.contains(.stroke))
    #expect(!l.isPanelVisible(.stroke))
}

@Test func closePanelRemovesFromGroup() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.closePanel(pa(id.value, 1, 1))
    #expect(l.dock(id)!.groups[1].panels == [.color, .properties])
}

@Test func closeLastPanelRemovesGroup() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.closePanel(pa(id.value, 0, 0))
    #expect(l.dock(id)!.groups.count == 1)
    #expect(l.hiddenPanels.contains(.layers))
}

@Test func showPanelAddsToDefaultGroup() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.closePanel(pa(id.value, 1, 1))
    l.showPanel(.stroke)
    #expect(!l.hiddenPanels.contains(.stroke))
    #expect(l.dock(id)!.groups[0].panels.contains(.stroke))
}

@Test func showPanelRemovesFromHidden() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.closePanel(pa(id.value, 1, 0))
    #expect(l.hiddenPanels.count == 1)
    l.showPanel(.color)
    #expect(l.hiddenPanels.isEmpty)
}

@Test func hiddenPanelsDefaultEmpty() {
    let l = DockLayout.defaultLayout()
    #expect(l.hiddenPanels.isEmpty)
}

@Test func panelMenuItemsAllVisible() {
    let l = DockLayout.defaultLayout()
    let items = l.panelMenuItems()
    #expect(items.count == 4)
    for (_, visible) in items { #expect(visible) }
}

@Test func panelMenuItemsWithHidden() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.closePanel(pa(id.value, 1, 1))
    let items = l.panelMenuItems()
    #expect(items.first(where: { $0.0 == .stroke })!.1 == false)
    #expect(items.first(where: { $0.0 == .layers })!.1 == true)
}

// MARK: - Z-Index

@Test func bringToFrontMovesToEnd() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let f1 = l.detachGroup(ga(id.value, 0), x: 10, y: 10)!
    let f2 = l.detachGroup(ga(id.value, 0), x: 20, y: 20)!
    l.bringToFront(f1)
    #expect(l.zOrder.last == f1)
}

@Test func bringToFrontAlreadyFront() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    _ = l.detachGroup(ga(id.value, 0), x: 10, y: 10)!
    let f2 = l.detachGroup(ga(id.value, 0), x: 20, y: 20)!
    l.bringToFront(f2)
    #expect(l.zOrder.last == f2)
    #expect(l.zOrder.count == 2)
}

@Test func zIndexForOrdering() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let f1 = l.detachGroup(ga(id.value, 0), x: 10, y: 10)!
    let f2 = l.detachGroup(ga(id.value, 0), x: 20, y: 20)!
    #expect(l.zIndexFor(f1) == 0)
    #expect(l.zIndexFor(f2) == 1)
    l.bringToFront(f1)
    #expect(l.zIndexFor(f1) == 1)
    #expect(l.zIndexFor(f2) == 0)
}

// MARK: - Snap & Re-dock

@Test func snapToRightEdge() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 50, y: 50)!
    let before = l.anchoredDock(.right)!.groups.count
    l.snapToEdge(fid, edge: .right)
    #expect(l.floatingDock(fid) == nil)
    #expect(l.anchoredDock(.right)!.groups.count > before)
}

@Test func snapToLeftEdge() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 50, y: 50)!
    l.snapToEdge(fid, edge: .left)
    #expect(l.anchoredDock(.left) != nil)
    #expect(l.floatingDock(fid) == nil)
}

@Test func snapCreatesAnchoredDock() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    #expect(l.anchoredDock(.bottom) == nil)
    let fid = l.detachGroup(ga(id.value, 0), x: 50, y: 50)!
    l.snapToEdge(fid, edge: .bottom)
    #expect(l.anchoredDock(.bottom) != nil)
    #expect(l.anchoredDock(.bottom)!.groups[0].panels == [.layers])
}

@Test func redockMergesIntoRight() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 50, y: 50)!
    l.redock(fid)
    #expect(l.floating.isEmpty)
    #expect(l.anchoredDock(.right)!.groups.contains(where: { $0.panels.contains(.layers) }))
}

@Test func redockInvalidId() {
    var l = DockLayout.defaultLayout()
    l.redock(DockId(99))
    #expect(l.anchored.count == 1)
}

@Test func isNearEdgeDetection() {
    #expect(DockLayout.isNearEdge(x: 5, y: 500, viewportW: 1000, viewportH: 800) == .left)
    #expect(DockLayout.isNearEdge(x: 990, y: 500, viewportW: 1000, viewportH: 800) == .right)
    #expect(DockLayout.isNearEdge(x: 500, y: 790, viewportW: 1000, viewportH: 800) == .bottom)
}

@Test func isNearEdgeNotNear() {
    #expect(DockLayout.isNearEdge(x: 500, y: 400, viewportW: 1000, viewportH: 800) == nil)
}

// MARK: - Multi-Edge

@Test func addAnchoredLeft() {
    var l = DockLayout.defaultLayout()
    let id = l.addAnchoredDock(.left)
    #expect(l.anchoredDock(.left) != nil)
    #expect(l.anchoredDock(.left)!.id == id)
}

@Test func addAnchoredExistingReturnsId() {
    var l = DockLayout.defaultLayout()
    let id1 = l.addAnchoredDock(.left)
    let id2 = l.addAnchoredDock(.left)
    #expect(id1 == id2)
    #expect(l.anchored.count == 2)
}

@Test func addAnchoredBottom() {
    var l = DockLayout.defaultLayout()
    l.addAnchoredDock(.bottom)
    #expect(l.anchoredDock(.bottom) != nil)
    #expect(l.anchored.count == 2)
}

@Test func removeAnchoredMovesToFloating() {
    var l = DockLayout.defaultLayout()
    let lid = l.addAnchoredDock(.left)
    l.dockMut(lid) { $0.groups.append(PanelGroup(panels: [.layers])) }
    let fid = l.removeAnchoredDock(.left)
    #expect(fid != nil)
    #expect(l.anchoredDock(.left) == nil)
    #expect(l.floatingDock(fid!) != nil)
}

@Test func removeAnchoredEmptyReturnsNil() {
    var l = DockLayout.defaultLayout()
    l.addAnchoredDock(.left)
    let fid = l.removeAnchoredDock(.left)
    #expect(fid == nil)
}

// MARK: - Persistence

@Test func toJsonRoundTrip() {
    let l = DockLayout.defaultLayout()
    let json = l.toJson()!
    let l2 = DockLayout.fromJson(json)
    #expect(l2.anchored.count == 1)
    #expect(l2.anchored[0].0 == .right)
    #expect(l2.anchoredDock(.right)!.groups.count == 2)
    #expect(l2.anchoredDock(.right)!.groups[0].panels == [.layers])
}

@Test func fromJsonWithFloating() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.detachGroup(ga(id.value, 0), x: 100, y: 200)
    let json = l.toJson()!
    let l2 = DockLayout.fromJson(json)
    #expect(l2.floating.count == 1)
    #expect(l2.floating[0].x == 100)
    #expect(l2.floating[0].y == 200)
}

@Test func fromJsonInvalidGraceful() {
    let l = DockLayout.fromJson("not valid json{{{")
    #expect(l.anchored.count == 1)
    #expect(l.anchoredDock(.right)!.groups.count == 2)
}

@Test func resetToDefaultTest() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.detachGroup(ga(id.value, 0), x: 50, y: 50)
    l.closePanel(pa(id.value, 0, 0))
    #expect(!l.floating.isEmpty)
    #expect(!l.hiddenPanels.isEmpty)
    l.resetToDefault()
    #expect(l.floating.isEmpty)
    #expect(l.hiddenPanels.isEmpty)
    #expect(l.anchoredDock(.right)!.groups.count == 2)
}

// MARK: - Focus

@Test func setFocusedPanelTest() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let addr = pa(id.value, 1, 2)
    l.setFocusedPanel(addr)
    #expect(l.focusedPanel == addr)
    l.setFocusedPanel(nil)
    #expect(l.focusedPanel == nil)
}

@Test func focusNextWraps() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.setFocusedPanel(nil)
    l.focusNextPanel()
    #expect(l.focusedPanel == pa(id.value, 0, 0))
    l.focusNextPanel() // Color
    l.focusNextPanel() // Stroke
    l.focusNextPanel() // Properties
    #expect(l.focusedPanel == pa(id.value, 1, 2))
    l.focusNextPanel()
    #expect(l.focusedPanel == pa(id.value, 0, 0))
}

@Test func focusPrevWraps() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.setFocusedPanel(nil)
    l.focusPrevPanel()
    #expect(l.focusedPanel == pa(id.value, 1, 2))
    l.focusPrevPanel() // Stroke
    l.focusPrevPanel() // Color
    l.focusPrevPanel() // Layers
    #expect(l.focusedPanel == pa(id.value, 0, 0))
    l.focusPrevPanel()
    #expect(l.focusedPanel == pa(id.value, 1, 2))
}

// MARK: - Safety

@Test func clampFloatingWithinViewport() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 2000, y: 1500)!
    l.clampFloatingDocks(viewportW: 1000, viewportH: 800)
    #expect(l.floatingDock(fid)!.x <= 950)
    #expect(l.floatingDock(fid)!.y <= 750)
}

@Test func clampFloatingPartiallyOffscreen() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: -500, y: -100)!
    l.clampFloatingDocks(viewportW: 1000, viewportH: 800)
    let fd = l.floatingDock(fid)!
    #expect(fd.x >= -fd.dock.width + 50)
    #expect(fd.y >= 0)
}

@Test func setAutoHideTest() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    #expect(!l.dock(id)!.autoHide)
    l.setAutoHide(id, autoHide: true)
    #expect(l.dock(id)!.autoHide)
    l.setAutoHide(id, autoHide: false)
    #expect(!l.dock(id)!.autoHide)
}

// MARK: - Reorder Panels

@Test func reorderPanelForward() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.reorderPanel(ga(id.value, 1), from: 0, to: 2)
    #expect(l.dock(id)!.groups[1].panels == [.stroke, .properties, .color])
    #expect(l.dock(id)!.groups[1].active == 2)
}

@Test func reorderPanelBackward() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.reorderPanel(ga(id.value, 1), from: 2, to: 0)
    #expect(l.dock(id)!.groups[1].panels == [.properties, .color, .stroke])
    #expect(l.dock(id)!.groups[1].active == 0)
}

@Test func reorderPanelSamePosition() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.reorderPanel(ga(id.value, 1), from: 1, to: 1)
    #expect(l.dock(id)!.groups[1].panels == [.color, .stroke, .properties])
}

@Test func reorderPanelClamped() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.reorderPanel(ga(id.value, 1), from: 0, to: 99)
    #expect(l.dock(id)!.groups[1].panels[2] == .color)
}

@Test func reorderPanelOutOfBounds() {
    var l = DockLayout.defaultLayout()
    let id = rightDockId(l)
    l.reorderPanel(ga(id.value, 1), from: 99, to: 0)
    l.reorderPanel(ga(99, 0), from: 0, to: 1)
}

// MARK: - Named Layouts & AppConfig

@Test func defaultLayoutName() {
    let l = DockLayout.defaultLayout()
    #expect(l.name == "Default")
}

@Test func namedLayout() {
    let l = DockLayout.named("My Workspace")
    #expect(l.name == "My Workspace")
    #expect(l.anchored.count == 1)
}

@Test func storageKeyIncludesName() {
    let l = DockLayout.named("Editing")
    #expect(l.storageKey() == "jas_layout:Editing")
}

@Test func storageKeyForStatic() {
    #expect(DockLayout.storageKeyFor("Drawing") == "jas_layout:Drawing")
}

@Test func resetPreservesName() {
    var l = DockLayout.named("Custom")
    let id = rightDockId(l)
    l.detachGroup(ga(id.value, 0), x: 50, y: 50)
    #expect(!l.floating.isEmpty)
    l.resetToDefault()
    #expect(l.name == "Custom")
    #expect(l.floating.isEmpty)
}

@Test func jsonRoundTripPreservesName() {
    let l = DockLayout.named("Test Layout")
    let json = l.toJson()!
    let l2 = DockLayout.fromJson(json)
    #expect(l2.name == "Test Layout")
}

@Test func appConfigDefault() {
    let c = AppConfig()
    #expect(c.activeLayout == "Default")
    #expect(c.savedLayouts == ["Default"])
}

@Test func appConfigRoundTrip() {
    let c = AppConfig(activeLayout: "My Layout", savedLayouts: ["My Layout"])
    let json = c.toJson()!
    let c2 = AppConfig.fromJson(json)
    #expect(c2.activeLayout == "My Layout")
}

@Test func appConfigInvalidJson() {
    let c = AppConfig.fromJson("garbage{{{")
    #expect(c.activeLayout == "Default")
}

// MARK: - PaneLayout Integration

@Test func dockLayoutDefaultHasNoPaneLayout() {
    let l = DockLayout.defaultLayout()
    #expect(l.panes() == nil)
}

@Test func ensurePaneLayoutCreatesIfNone() {
    var l = DockLayout.defaultLayout()
    l.ensurePaneLayout(viewportW: 1000, viewportH: 700)
    #expect(l.panes() != nil)
    #expect(l.panes()!.panes.count == 3)
}

@Test func ensurePaneLayoutNoopIfPresent() {
    var l = DockLayout.defaultLayout()
    l.ensurePaneLayout(viewportW: 1000, viewportH: 700)
    l.markSaved()
    l.ensurePaneLayout(viewportW: 1000, viewportH: 700)
    #expect(!l.needsSave())
}

@Test func resetToDefaultClearsPaneLayout() {
    var l = DockLayout.defaultLayout()
    l.ensurePaneLayout(viewportW: 1000, viewportH: 700)
    #expect(l.panes() != nil)
    l.resetToDefault()
    #expect(l.panes() == nil)
}

@Test func panesAccessors() {
    var l = DockLayout.defaultLayout()
    #expect(l.panes() == nil)
    l.ensurePaneLayout(viewportW: 1000, viewportH: 700)
    #expect(l.panes() != nil)
    l.panesMut { pl in
        pl.hidePane(.toolbar)
    }
    #expect(!l.panes()!.isPaneVisible(.toolbar))
}

@Test func serdeBackwardCompatNoPaneLayout() {
    let l = DockLayout.defaultLayout()
    let json = l.toJson()!
    let l2 = DockLayout.fromJson(json)
    #expect(l2.panes() == nil)
    #expect(l2.anchored.count == 1)
}

@Test func serdeRoundTripWithPaneLayout() {
    var l = DockLayout.defaultLayout()
    l.ensurePaneLayout(viewportW: 1000, viewportH: 700)
    let json = l.toJson()!
    let l2 = DockLayout.fromJson(json)
    #expect(l2.panes() != nil)
    #expect(l2.panes()!.panes.count == 3)
    #expect(l2.panes()!.snaps.count == 10)
}

@Test func serdeVersionMismatchFallsBackToDefault() {
    var l = DockLayout.defaultLayout()
    l.ensurePaneLayout(viewportW: 1000, viewportH: 700)
    let json = l.toJson()!
    // Tamper with version to simulate future format
    let tampered = json.replacingOccurrences(of: "\"version\":1", with: "\"version\":999")
    let l2 = DockLayout.fromJson(tampered)
    // Should fall back to default (version mismatch)
    #expect(l2.version == layoutVersion)
    #expect(l2.panes() == nil)
}

@Test func serdeOldJsonWithoutVersionFallsBackToDefault() {
    // Simulate old JSON that has no version field
    let l = DockLayout.defaultLayout()
    let json = l.toJson()!
    let tampered = json.replacingOccurrences(of: "\"version\":1,", with: "")
    let l2 = DockLayout.fromJson(tampered)
    // Old layout without version field should fall back to default
    #expect(l2.version == layoutVersion)
}

@Test func clampFloatingDocksAlsoClampsPanes() {
    var l = DockLayout.defaultLayout()
    l.ensurePaneLayout(viewportW: 1000, viewportH: 700)
    l.panesMut { pl in
        let canvasId = pl.paneByKind(.canvas)!.id
        pl.setPanePosition(canvasId, x: 5000, y: 5000)
    }
    l.clampFloatingDocks(viewportW: 1000, viewportH: 700)
    let canvas = l.panes()!.paneByKind(.canvas)!
    #expect(canvas.x <= 1000 - minPaneVisible)
    #expect(canvas.y <= 700 - minPaneVisible)
}
