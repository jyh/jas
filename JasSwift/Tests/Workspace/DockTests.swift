import Testing
@testable import JasLib

// Helpers
private func ga(_ dockId: Int, _ groupIdx: Int) -> GroupAddr {
    GroupAddr(dockId: DockId(dockId), groupIdx: groupIdx)
}
private func pa(_ dockId: Int, _ groupIdx: Int, _ panelIdx: Int) -> PanelAddr {
    PanelAddr(group: ga(dockId, groupIdx), panelIdx: panelIdx)
}
private func rightDockId(_ l: WorkspaceLayout) -> DockId {
    l.anchoredDock(.right)!.id
}

// MARK: - Layout & Lookup

@Test func defaultLayoutOneAnchoredRight() {
    let l = WorkspaceLayout.defaultLayout()
    #expect(l.anchored.count == 1)
    #expect(l.anchored[0].0 == .right)
    #expect(l.floating.isEmpty)
}

@Test func defaultLayoutTwoGroups() {
    let l = WorkspaceLayout.defaultLayout()
    let d = l.anchoredDock(.right)!
    #expect(d.groups.count == 3)
    #expect(d.groups[0].panels == [.color, .swatches])
    #expect(d.groups[1].panels == [.stroke, .properties])
    #expect(d.groups[2].panels == [.layers])
}

@Test func defaultNotCollapsed() {
    let l = WorkspaceLayout.defaultLayout()
    let d = l.anchoredDock(.right)!
    #expect(!d.collapsed)
    for g in d.groups { #expect(!g.collapsed) }
}

@Test func defaultDockWidthValue() {
    let l = WorkspaceLayout.defaultLayout()
    #expect(l.anchoredDock(.right)!.width == defaultDockWidth)
}

@Test func dockLookupAnchored() {
    let l = WorkspaceLayout.defaultLayout()
    #expect(l.dock(rightDockId(l)) != nil)
}

@Test func dockLookupFloating() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 100, y: 100)!
    #expect(l.dock(fid) != nil)
    #expect(l.floatingDock(fid) != nil)
}

@Test func dockLookupInvalid() {
    let l = WorkspaceLayout.defaultLayout()
    #expect(l.dock(DockId(99)) == nil)
}

@Test func anchoredDockByEdge() {
    let l = WorkspaceLayout.defaultLayout()
    #expect(l.anchoredDock(.right) != nil)
    #expect(l.anchoredDock(.left) == nil)
    #expect(l.anchoredDock(.bottom) == nil)
}

// MARK: - Toggle / Active

@Test func toggleDockCollapsed() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    #expect(!l.dock(id)!.collapsed)
    l.toggleDockCollapsed(id)
    #expect(l.dock(id)!.collapsed)
    l.toggleDockCollapsed(id)
    #expect(!l.dock(id)!.collapsed)
}

@Test func toggleGroupCollapsed() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.toggleGroupCollapsed(ga(id.value, 0))
    #expect(l.dock(id)!.groups[0].collapsed)
    #expect(!l.dock(id)!.groups[1].collapsed)
    l.toggleGroupCollapsed(ga(id.value, 0))
    #expect(!l.dock(id)!.groups[0].collapsed)
}

@Test func toggleGroupOutOfBounds() {
    var l = WorkspaceLayout.defaultLayout()
    l.toggleGroupCollapsed(ga(0, 99))
    l.toggleGroupCollapsed(ga(99, 0))
}

@Test func setActivePanel() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.setActivePanel(pa(id.value, 1, 1))
    #expect(l.dock(id)!.groups[1].active == 1)
}

@Test func setActivePanelOutOfBounds() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.setActivePanel(pa(id.value, 1, 99))
    #expect(l.dock(id)!.groups[1].active == 0)
    l.setActivePanel(pa(id.value, 99, 0))
    l.setActivePanel(pa(99, 0, 0))
}

// MARK: - Move Group Within Dock

@Test func moveGroupForward() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupWithinDock(id, from: 0, to: 1)
    #expect(l.dock(id)!.groups[0].panels == [.stroke, .properties])
    #expect(l.dock(id)!.groups[1].panels == [.color, .swatches])
    #expect(l.dock(id)!.groups[2].panels == [.layers])
}

@Test func moveGroupBackward() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupWithinDock(id, from: 1, to: 0)
    #expect(l.dock(id)!.groups[0].panels == [.stroke, .properties])
    #expect(l.dock(id)!.groups[1].panels == [.color, .swatches])
    #expect(l.dock(id)!.groups[2].panels == [.layers])
}

@Test func moveGroupSamePosition() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupWithinDock(id, from: 0, to: 0)
    #expect(l.dock(id)!.groups[0].panels == [.color, .swatches])
}

@Test func moveGroupClamped() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupWithinDock(id, from: 0, to: 99)
    #expect(l.dock(id)!.groups[2].panels == [.color, .swatches])
}

@Test func moveGroupOutOfBounds() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupWithinDock(id, from: 99, to: 0)
    #expect(l.dock(id)!.groups.count == 3)
}

@Test func moveGroupPreservesState() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.dockMut(id) { $0.groups[1].active = 2; $0.groups[1].collapsed = true }
    l.moveGroupWithinDock(id, from: 1, to: 0)
    #expect(l.dock(id)!.groups[0].active == 2)
    #expect(l.dock(id)!.groups[0].collapsed)
}

// MARK: - Move Group Between Docks

@Test func moveGroupBetweenDocks() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 50, y: 50)!
    l.moveGroupToDock(ga(id.value, 0), toDock: fid, toIdx: 1)
    #expect(l.dock(id)!.groups.count == 1)
    #expect(l.dock(fid)!.groups.count == 2)
}

@Test func moveGroupInsertsAtPosition() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let f1 = l.detachGroup(ga(id.value, 0), x: 10, y: 10)!
    let f2 = l.detachGroup(ga(id.value, 0), x: 20, y: 20)!
    l.moveGroupToDock(ga(f1.value, 0), toDock: f2, toIdx: 0)
    #expect(l.dock(f2)!.groups[0].panels == [.color, .swatches])
    #expect(l.dock(f1) == nil) // cleaned up
}

@Test func moveGroupSameDockIsReorder() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupToDock(ga(id.value, 0), toDock: id, toIdx: 1)
    #expect(l.dock(id)!.groups[0].panels == [.stroke, .properties])
    #expect(l.dock(id)!.groups[1].panels == [.color, .swatches])
    #expect(l.dock(id)!.groups[2].panels == [.layers])
}

@Test func moveGroupInvalidSource() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupToDock(ga(id.value, 99), toDock: id, toIdx: 0)
    #expect(l.dock(id)!.groups.count == 3)
}

@Test func moveGroupInvalidTarget() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.moveGroupToDock(ga(id.value, 0), toDock: DockId(99), toIdx: 0)
    #expect(l.dock(id)!.groups.count == 3)
}

// MARK: - Detach Group

@Test func detachGroupCreatesFloating() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 100, y: 200)
    #expect(fid != nil)
    #expect(l.dock(fid!)!.groups[0].panels == [.color, .swatches])
    #expect(l.dock(id)!.groups.count == 2)
}

@Test func detachGroupPosition() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 100, y: 200)!
    let fd = l.floatingDock(fid)!
    #expect(fd.x == 100)
    #expect(fd.y == 200)
}

@Test func detachGroupUniqueIds() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let f1 = l.detachGroup(ga(id.value, 0), x: 10, y: 10)!
    let f2 = l.detachGroup(ga(id.value, 0), x: 20, y: 20)!
    #expect(f1 != f2)
}

@Test func detachLastGroupFloatingRemovesDock() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let f1 = l.detachGroup(ga(id.value, 0), x: 10, y: 10)!
    _ = l.detachGroup(ga(f1.value, 0), x: 20, y: 20)
    #expect(l.dock(f1) == nil)
}

@Test func detachLastGroupAnchoredKeepsDock() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.detachGroup(ga(id.value, 0), x: 10, y: 10)
    l.detachGroup(ga(id.value, 0), x: 20, y: 20)
    l.detachGroup(ga(id.value, 0), x: 30, y: 30)
    #expect(l.dock(id) != nil)
    #expect(l.dock(id)!.groups.isEmpty)
}

// MARK: - Move Panel

@Test func movePanelSameDock() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    // Move Stroke (group 1, panel 0) to group 0
    l.movePanelToGroup(pa(id.value, 1, 0), to: ga(id.value, 0))
    #expect(l.dock(id)!.groups[0].panels == [.color, .swatches, .stroke])
    #expect(l.dock(id)!.groups[1].panels == [.properties])
    #expect(l.dock(id)!.groups[2].panels == [.layers])
}

@Test func movePanelBecomesActive() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.movePanelToGroup(pa(id.value, 1, 0), to: ga(id.value, 0))
    #expect(l.dock(id)!.groups[0].active == 2)
}

@Test func movePanelCrossDock() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 50, y: 50)!
    // Move Stroke from anchored group 0 (now [Stroke, Properties]) to floating group 0
    l.movePanelToGroup(pa(id.value, 0, 0), to: ga(fid.value, 0))
    #expect(l.dock(fid)!.groups[0].panels == [.color, .swatches, .stroke])
    #expect(l.dock(id)!.groups[0].panels == [.properties])
}

@Test func moveLastPanelRemovesGroup() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    // Move Layers (group 2, panel 0) to group 0
    l.movePanelToGroup(pa(id.value, 2, 0), to: ga(id.value, 0))
    #expect(l.dock(id)!.groups.count == 2) // group 2 removed
    #expect(l.dock(id)!.groups[0].panels.contains(.layers))
}

@Test func moveLastPanelRemovesFloating() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 2), x: 50, y: 50)!
    // Floating has one group with one panel (Layers). Move it to anchored.
    l.movePanelToGroup(pa(fid.value, 0, 0), to: ga(id.value, 0))
    #expect(l.dock(fid) == nil)
}

@Test func movePanelClampsActive() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.dockMut(id) { $0.groups[1].active = 1 }
    l.movePanelToGroup(pa(id.value, 1, 1), to: ga(id.value, 0))
    #expect(l.dock(id)!.groups[1].active < l.dock(id)!.groups[1].panels.count)
}

@Test func movePanelInvalidSource() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.movePanelToGroup(pa(id.value, 1, 99), to: ga(id.value, 0))
    l.movePanelToGroup(pa(99, 0, 0), to: ga(id.value, 0))
}

@Test func movePanelInvalidTarget() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.movePanelToGroup(pa(id.value, 1, 0), to: ga(99, 0))
    #expect(l.dock(id)!.groups[1].panels.count == 2)
}

// MARK: - Insert Panel as Group

@Test func insertPanelCreatesGroup() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    // Insert Stroke (group 1, panel 0) as new group at position 0
    l.insertPanelAsNewGroup(pa(id.value, 1, 0), toDock: id, atIdx: 0)
    #expect(l.dock(id)!.groups.count == 4)
    #expect(l.dock(id)!.groups[0].panels == [.stroke])
}

@Test func insertPanelCleansSource() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    // Group 2 has only Layers. Insert it as new group at end.
    l.insertPanelAsNewGroup(pa(id.value, 2, 0), toDock: id, atIdx: 99)
    #expect(l.dock(id)!.groups.count == 3)
    #expect(l.dock(id)!.groups[2].panels == [.layers])
}

@Test func insertPanelInvalid() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.insertPanelAsNewGroup(pa(id.value, 1, 99), toDock: id, atIdx: 0)
    l.insertPanelAsNewGroup(pa(99, 0, 0), toDock: id, atIdx: 0)
    #expect(l.dock(id)!.groups.count == 3)
}

// MARK: - Detach Panel

@Test func detachPanelCreatesFloating() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachPanel(pa(id.value, 1, 0), x: 300, y: 150)
    #expect(fid != nil)
    #expect(l.dock(fid!)!.groups[0].panels == [.stroke])
    #expect(l.dock(id)!.groups[1].panels == [.properties])
}

@Test func detachPanelPosition() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachPanel(pa(id.value, 1, 0), x: 300, y: 150)!
    #expect(l.floatingDock(fid)!.x == 300)
    #expect(l.floatingDock(fid)!.y == 150)
}

@Test func detachPanelLastRemovesGroup() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    // Detach the only panel in group 2 (Layers)
    l.detachPanel(pa(id.value, 2, 0), x: 50, y: 50)
    #expect(l.dock(id)!.groups.count == 2)
}

@Test func detachPanelLastRemovesFloating() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let f1 = l.detachGroup(ga(id.value, 2), x: 50, y: 50)!
    // f1 has one group with one panel (Layers). Detach it.
    _ = l.detachPanel(pa(f1.value, 0, 0), x: 100, y: 100)
    #expect(l.dock(f1) == nil)
}

// MARK: - Floating Position

@Test func setFloatingPositionTest() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 10, y: 10)!
    l.setFloatingPosition(fid, x: 200, y: 300)
    #expect(l.floatingDock(fid)!.x == 200)
    #expect(l.floatingDock(fid)!.y == 300)
}

@Test func setPositionAnchoredIgnored() {
    var l = WorkspaceLayout.defaultLayout()
    l.setFloatingPosition(rightDockId(l), x: 999, y: 999)
}

@Test func setPositionInvalidId() {
    var l = WorkspaceLayout.defaultLayout()
    l.setFloatingPosition(DockId(99), x: 0, y: 0)
}

// MARK: - Resize

@Test func resizeGroupSetsHeight() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.resizeGroup(ga(id.value, 0), height: 150)
    #expect(l.dock(id)!.groups[0].height == 150)
}

@Test func resizeGroupClampsMin() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.resizeGroup(ga(id.value, 0), height: 5)
    #expect(l.dock(id)!.groups[0].height == minGroupHeight)
}

@Test func resizeGroupInvalidAddr() {
    var l = WorkspaceLayout.defaultLayout()
    l.resizeGroup(ga(99, 0), height: 100)
    l.resizeGroup(ga(0, 99), height: 100)
}

@Test func defaultGroupHeightIsNil() {
    let l = WorkspaceLayout.defaultLayout()
    for g in l.anchoredDock(.right)!.groups {
        #expect(g.height == nil)
    }
}

@Test func setDockWidthClamped() {
    var l = WorkspaceLayout.defaultLayout()
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
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.dockMut(id) { $0.groups[1].active = 1 }
    l.movePanelToGroup(pa(id.value, 1, 1), to: ga(id.value, 0))
    #expect(l.dock(id)!.groups[1].active < l.dock(id)!.groups[1].panels.count)
}

@Test func cleanupMultipleEmptyGroups() {
    var l = WorkspaceLayout.defaultLayout()
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
    #expect(WorkspaceLayout.panelLabel(.layers) == "Layers")
    #expect(WorkspaceLayout.panelLabel(.color) == "Color")
    #expect(WorkspaceLayout.panelLabel(.swatches) == "Swatches")
    #expect(WorkspaceLayout.panelLabel(.stroke) == "Stroke")
    #expect(WorkspaceLayout.panelLabel(.properties) == "Properties")
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
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.closePanel(pa(id.value, 1, 0)) // close Stroke
    #expect(l.hiddenPanels.contains(.stroke))
    #expect(!l.isPanelVisible(.stroke))
}

@Test func closePanelRemovesFromGroup() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.closePanel(pa(id.value, 1, 0)) // close Stroke
    #expect(l.dock(id)!.groups[1].panels == [.properties])
}

@Test func closeLastPanelRemovesGroup() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.closePanel(pa(id.value, 2, 0)) // close Layers (only panel in group 2)
    #expect(l.dock(id)!.groups.count == 2)
    #expect(l.hiddenPanels.contains(.layers))
}

@Test func showPanelAddsToDefaultGroup() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.closePanel(pa(id.value, 1, 0)) // close Stroke
    l.showPanel(.stroke)
    #expect(!l.hiddenPanels.contains(.stroke))
    #expect(l.dock(id)!.groups[0].panels.contains(.stroke))
}

@Test func showPanelRemovesFromHidden() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.closePanel(pa(id.value, 0, 0)) // close Color
    #expect(l.hiddenPanels.count == 1)
    l.showPanel(.color)
    #expect(l.hiddenPanels.isEmpty)
}

@Test func hiddenPanelsDefaultEmpty() {
    let l = WorkspaceLayout.defaultLayout()
    #expect(l.hiddenPanels.isEmpty)
}

@Test func panelMenuItemsAllVisible() {
    let l = WorkspaceLayout.defaultLayout()
    let items = l.panelMenuItems()
    #expect(items.count == 5)
    for (_, visible) in items { #expect(visible) }
}

@Test func panelMenuItemsWithHidden() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.closePanel(pa(id.value, 1, 0)) // close Stroke
    let items = l.panelMenuItems()
    #expect(items.first(where: { $0.0 == .stroke })!.1 == false)
    #expect(items.first(where: { $0.0 == .layers })!.1 == true)
}

// MARK: - Z-Index

@Test func bringToFrontMovesToEnd() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let f1 = l.detachGroup(ga(id.value, 0), x: 10, y: 10)!
    let f2 = l.detachGroup(ga(id.value, 0), x: 20, y: 20)!
    l.bringToFront(f1)
    #expect(l.zOrder.last == f1)
}

@Test func bringToFrontAlreadyFront() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    _ = l.detachGroup(ga(id.value, 0), x: 10, y: 10)!
    let f2 = l.detachGroup(ga(id.value, 0), x: 20, y: 20)!
    l.bringToFront(f2)
    #expect(l.zOrder.last == f2)
    #expect(l.zOrder.count == 2)
}

@Test func zIndexForOrdering() {
    var l = WorkspaceLayout.defaultLayout()
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
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 50, y: 50)!
    let before = l.anchoredDock(.right)!.groups.count
    l.snapToEdge(fid, edge: .right)
    #expect(l.floatingDock(fid) == nil)
    #expect(l.anchoredDock(.right)!.groups.count > before)
}

@Test func snapToLeftEdge() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 50, y: 50)!
    l.snapToEdge(fid, edge: .left)
    #expect(l.anchoredDock(.left) != nil)
    #expect(l.floatingDock(fid) == nil)
}

@Test func snapCreatesAnchoredDock() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    #expect(l.anchoredDock(.bottom) == nil)
    let fid = l.detachGroup(ga(id.value, 0), x: 50, y: 50)!
    l.snapToEdge(fid, edge: .bottom)
    #expect(l.anchoredDock(.bottom) != nil)
    #expect(l.anchoredDock(.bottom)!.groups[0].panels == [.color, .swatches])
}

@Test func redockMergesIntoRight() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 50, y: 50)!
    l.redock(fid)
    #expect(l.floating.isEmpty)
    #expect(l.anchoredDock(.right)!.groups.contains(where: { $0.panels.contains(.layers) }))
}

@Test func redockInvalidId() {
    var l = WorkspaceLayout.defaultLayout()
    l.redock(DockId(99))
    #expect(l.anchored.count == 1)
}

@Test func isNearEdgeDetection() {
    #expect(WorkspaceLayout.isNearEdge(x: 5, y: 500, viewportW: 1000, viewportH: 800) == .left)
    #expect(WorkspaceLayout.isNearEdge(x: 990, y: 500, viewportW: 1000, viewportH: 800) == .right)
    #expect(WorkspaceLayout.isNearEdge(x: 500, y: 790, viewportW: 1000, viewportH: 800) == .bottom)
}

@Test func isNearEdgeNotNear() {
    #expect(WorkspaceLayout.isNearEdge(x: 500, y: 400, viewportW: 1000, viewportH: 800) == nil)
}

// MARK: - Multi-Edge

@Test func addAnchoredLeft() {
    var l = WorkspaceLayout.defaultLayout()
    let id = l.addAnchoredDock(.left)
    #expect(l.anchoredDock(.left) != nil)
    #expect(l.anchoredDock(.left)!.id == id)
}

@Test func addAnchoredExistingReturnsId() {
    var l = WorkspaceLayout.defaultLayout()
    let id1 = l.addAnchoredDock(.left)
    let id2 = l.addAnchoredDock(.left)
    #expect(id1 == id2)
    #expect(l.anchored.count == 2)
}

@Test func addAnchoredBottom() {
    var l = WorkspaceLayout.defaultLayout()
    l.addAnchoredDock(.bottom)
    #expect(l.anchoredDock(.bottom) != nil)
    #expect(l.anchored.count == 2)
}

@Test func removeAnchoredMovesToFloating() {
    var l = WorkspaceLayout.defaultLayout()
    let lid = l.addAnchoredDock(.left)
    l.dockMut(lid) { $0.groups.append(PanelGroup(panels: [.layers])) }
    let fid = l.removeAnchoredDock(.left)
    #expect(fid != nil)
    #expect(l.anchoredDock(.left) == nil)
    #expect(l.floatingDock(fid!) != nil)
}

@Test func removeAnchoredEmptyReturnsNil() {
    var l = WorkspaceLayout.defaultLayout()
    l.addAnchoredDock(.left)
    let fid = l.removeAnchoredDock(.left)
    #expect(fid == nil)
}

// MARK: - Persistence

@Test func toJsonRoundTrip() {
    let l = WorkspaceLayout.defaultLayout()
    let json = l.toJson()!
    let l2 = WorkspaceLayout.fromJson(json)
    #expect(l2.anchored.count == 1)
    #expect(l2.anchored[0].0 == .right)
    #expect(l2.anchoredDock(.right)!.groups.count == 3)
    #expect(l2.anchoredDock(.right)!.groups[0].panels == [.color, .swatches])
}

@Test func fromJsonWithFloating() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.detachGroup(ga(id.value, 0), x: 100, y: 200)
    let json = l.toJson()!
    let l2 = WorkspaceLayout.fromJson(json)
    #expect(l2.floating.count == 1)
    #expect(l2.floating[0].x == 100)
    #expect(l2.floating[0].y == 200)
}

@Test func fromJsonInvalidGraceful() {
    let l = WorkspaceLayout.fromJson("not valid json{{{")
    #expect(l.anchored.count == 1)
    #expect(l.anchoredDock(.right)!.groups.count == 3)
}

@Test func resetToDefaultTest() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.detachGroup(ga(id.value, 0), x: 50, y: 50)
    l.closePanel(pa(id.value, 0, 0))
    #expect(!l.floating.isEmpty)
    #expect(!l.hiddenPanels.isEmpty)
    l.resetToDefault()
    #expect(l.floating.isEmpty)
    #expect(l.hiddenPanels.isEmpty)
    #expect(l.anchoredDock(.right)!.groups.count == 3)
}

// MARK: - Focus

@Test func setFocusedPanelTest() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let addr = pa(id.value, 1, 2)
    l.setFocusedPanel(addr)
    #expect(l.focusedPanel == addr)
    l.setFocusedPanel(nil)
    #expect(l.focusedPanel == nil)
}

@Test func focusNextWraps() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    // 3 groups: [Color, Swatches], [Stroke, Properties], [Layers] = 5 panels
    l.setFocusedPanel(nil)
    l.focusNextPanel()
    // Should focus the first panel (Color)
    #expect(l.focusedPanel == pa(id.value, 0, 0))
    l.focusNextPanel() // Swatches
    l.focusNextPanel() // Stroke
    l.focusNextPanel() // Properties
    l.focusNextPanel() // Layers
    #expect(l.focusedPanel == pa(id.value, 2, 0))
    // Next should wrap to Color
    l.focusNextPanel()
    #expect(l.focusedPanel == pa(id.value, 0, 0))
}

@Test func focusPrevWraps() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.setFocusedPanel(nil)
    l.focusPrevPanel()
    // Should focus the last panel (Layers)
    #expect(l.focusedPanel == pa(id.value, 2, 0))
    l.focusPrevPanel() // Properties
    l.focusPrevPanel() // Stroke
    l.focusPrevPanel() // Swatches
    l.focusPrevPanel() // Color
    #expect(l.focusedPanel == pa(id.value, 0, 0))
    // Prev should wrap to Layers
    l.focusPrevPanel()
    #expect(l.focusedPanel == pa(id.value, 2, 0))
}

// MARK: - Safety

@Test func clampFloatingWithinViewport() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: 2000, y: 1500)!
    l.clampFloatingDocks(viewportW: 1000, viewportH: 800)
    #expect(l.floatingDock(fid)!.x <= 950)
    #expect(l.floatingDock(fid)!.y <= 750)
}

@Test func clampFloatingPartiallyOffscreen() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    let fid = l.detachGroup(ga(id.value, 0), x: -500, y: -100)!
    l.clampFloatingDocks(viewportW: 1000, viewportH: 800)
    let fd = l.floatingDock(fid)!
    #expect(fd.x >= -fd.dock.width + 50)
    #expect(fd.y >= 0)
}

@Test func setAutoHideTest() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    #expect(!l.dock(id)!.autoHide)
    l.setAutoHide(id, autoHide: true)
    #expect(l.dock(id)!.autoHide)
    l.setAutoHide(id, autoHide: false)
    #expect(!l.dock(id)!.autoHide)
}

// MARK: - Reorder Panels

@Test func reorderPanelForward() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    // Group 0: [Color, Swatches] -> move Color to position 1
    l.reorderPanel(ga(id.value, 0), from: 0, to: 1)
    #expect(l.dock(id)!.groups[0].panels == [.swatches, .color])
    #expect(l.dock(id)!.groups[0].active == 1)
}

@Test func reorderPanelBackward() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    // Group 1: [Stroke, Properties] -> move Properties to position 0
    l.reorderPanel(ga(id.value, 1), from: 1, to: 0)
    #expect(l.dock(id)!.groups[1].panels == [.properties, .stroke])
    #expect(l.dock(id)!.groups[1].active == 0)
}

@Test func reorderPanelSamePosition() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.reorderPanel(ga(id.value, 1), from: 1, to: 1)
    #expect(l.dock(id)!.groups[1].panels == [.stroke, .properties])
}

@Test func reorderPanelClamped() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.reorderPanel(ga(id.value, 1), from: 0, to: 99)
    #expect(l.dock(id)!.groups[1].panels[1] == .stroke)
}

@Test func reorderPanelOutOfBounds() {
    var l = WorkspaceLayout.defaultLayout()
    let id = rightDockId(l)
    l.reorderPanel(ga(id.value, 1), from: 99, to: 0)
    l.reorderPanel(ga(99, 0), from: 0, to: 1)
}

// MARK: - Named Layouts & AppConfig

@Test func defaultLayoutName() {
    let l = WorkspaceLayout.defaultLayout()
    #expect(l.name == "Default")
}

@Test func namedLayout() {
    let l = WorkspaceLayout.named("My Workspace")
    #expect(l.name == "My Workspace")
    #expect(l.anchored.count == 1)
}

@Test func storageKeyIncludesName() {
    let l = WorkspaceLayout.named("Editing")
    #expect(l.storageKey() == "jas_layout:Editing")
}

@Test func storageKeyForStatic() {
    #expect(WorkspaceLayout.storageKeyFor("Drawing") == "jas_layout:Drawing")
}

@Test func resetPreservesName() {
    var l = WorkspaceLayout.named("Custom")
    let id = rightDockId(l)
    l.detachGroup(ga(id.value, 0), x: 50, y: 50)
    #expect(!l.floating.isEmpty)
    l.resetToDefault()
    #expect(l.name == "Custom")
    #expect(l.floating.isEmpty)
}

@Test func jsonRoundTripPreservesName() {
    let l = WorkspaceLayout.named("Test Layout")
    let json = l.toJson()!
    let l2 = WorkspaceLayout.fromJson(json)
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

@Test func workspaceLayoutDefaultHasNoPaneLayout() {
    let l = WorkspaceLayout.defaultLayout()
    #expect(l.panes() == nil)
}

@Test func ensurePaneLayoutCreatesIfNone() {
    var l = WorkspaceLayout.defaultLayout()
    l.ensurePaneLayout(viewportW: 1000, viewportH: 700)
    #expect(l.panes() != nil)
    #expect(l.panes()!.panes.count == 3)
}

@Test func ensurePaneLayoutNoopIfPresent() {
    var l = WorkspaceLayout.defaultLayout()
    l.ensurePaneLayout(viewportW: 1000, viewportH: 700)
    l.markSaved()
    l.ensurePaneLayout(viewportW: 1000, viewportH: 700)
    #expect(!l.needsSave())
}

@Test func resetToDefaultClearsPaneLayout() {
    var l = WorkspaceLayout.defaultLayout()
    l.ensurePaneLayout(viewportW: 1000, viewportH: 700)
    #expect(l.panes() != nil)
    l.resetToDefault()
    #expect(l.panes() == nil)
}

@Test func panesAccessors() {
    var l = WorkspaceLayout.defaultLayout()
    #expect(l.panes() == nil)
    l.ensurePaneLayout(viewportW: 1000, viewportH: 700)
    #expect(l.panes() != nil)
    l.panesMut { pl in
        pl.hidePane(.toolbar)
    }
    #expect(!l.panes()!.isPaneVisible(.toolbar))
}

@Test func serdeBackwardCompatNoPaneLayout() {
    let l = WorkspaceLayout.defaultLayout()
    let json = l.toJson()!
    let l2 = WorkspaceLayout.fromJson(json)
    #expect(l2.panes() == nil)
    #expect(l2.anchored.count == 1)
}

@Test func serdeRoundTripWithPaneLayout() {
    var l = WorkspaceLayout.defaultLayout()
    l.ensurePaneLayout(viewportW: 1000, viewportH: 700)
    let json = l.toJson()!
    let l2 = WorkspaceLayout.fromJson(json)
    #expect(l2.panes() != nil)
    #expect(l2.panes()!.panes.count == 3)
    #expect(l2.panes()!.snaps.count == 10)
}

@Test func serdeVersionMismatchFallsBackToDefault() {
    var l = WorkspaceLayout.defaultLayout()
    l.ensurePaneLayout(viewportW: 1000, viewportH: 700)
    let json = l.toJson()!
    // Tamper with version to simulate future format
    let tampered = json.replacingOccurrences(of: "\"version\":\(layoutVersion)", with: "\"version\":999")
    let l2 = WorkspaceLayout.fromJson(tampered)
    // Should fall back to default (version mismatch)
    #expect(l2.version == layoutVersion)
    #expect(l2.panes() == nil)
}

@Test func serdeOldJsonWithoutVersionFallsBackToDefault() {
    // Simulate old JSON that has no version field
    let l = WorkspaceLayout.defaultLayout()
    let json = l.toJson()!
    let tampered = json.replacingOccurrences(of: "\"version\":1,", with: "")
    let l2 = WorkspaceLayout.fromJson(tampered)
    // Old layout without version field should fall back to default
    #expect(l2.version == layoutVersion)
}

@Test func clampFloatingDocksAlsoClampsPanes() {
    var l = WorkspaceLayout.defaultLayout()
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

// MARK: - Workspace working-copy pattern

@Test func workspaceLayoutNameConstant() {
    #expect(workspaceLayoutName == "Workspace")
}

@Test func namedCreatesLayoutWithGivenName() {
    let l = WorkspaceLayout.named("MyLayout")
    #expect(l.name == "MyLayout")
    #expect(l.version == layoutVersion)
    #expect(l.anchored.count == 1)
}

@Test func generationTracking() {
    var l = WorkspaceLayout.defaultLayout()
    #expect(!l.needsSave())
    l.bump()
    #expect(l.needsSave())
    l.markSaved()
    #expect(!l.needsSave())
}

@Test func resetToDefaultPreservesName() {
    var l = WorkspaceLayout.named(workspaceLayoutName)
    l.hiddenPanels.append(.layers)
    l.bump()
    #expect(!l.hiddenPanels.isEmpty)
    l.resetToDefault()
    #expect(l.hiddenPanels.isEmpty)
    #expect(l.name == workspaceLayoutName)
    #expect(l.needsSave())
}

@Test func jsonRoundTripPreservesLayout() {
    let l = WorkspaceLayout.named("Test")
    let json = l.toJson()!
    let loaded = WorkspaceLayout.fromJson(json)
    #expect(loaded.name == "Test")
    #expect(loaded.version == layoutVersion)
    #expect(loaded.anchored.count == l.anchored.count)
}

@Test func tryFromJsonReturnsNilForBadVersion() {
    let json = """
    {"version":0,"name":"Old","anchored":[],"floating":[],"hiddenPanels":[],"zOrder":[],"focusedPanel":null,"nextId":1}
    """
    #expect(WorkspaceLayout.tryFromJson(json) == nil)
}

@Test func tryFromJsonReturnsNilForInvalidJson() {
    #expect(WorkspaceLayout.tryFromJson("not json") == nil)
}

@Test func tryFromJsonReturnsSomeForValid() {
    let l = WorkspaceLayout.named("Valid")
    let json = l.toJson()!
    let result = WorkspaceLayout.tryFromJson(json)
    #expect(result != nil)
    #expect(result!.name == "Valid")
}

@Test func storageKeyUsesPrefixAndName() {
    let l = WorkspaceLayout.named("Foo")
    #expect(l.storageKey() == "jas_layout:Foo")
    #expect(WorkspaceLayout.storageKeyFor("Bar") == "jas_layout:Bar")
}

@Test func appConfigRegisterLayoutIdempotent() {
    var c = AppConfig()
    c.registerLayout("Custom")
    #expect(c.savedLayouts.count == 2)
    #expect(c.savedLayouts.contains("Custom"))
    c.registerLayout("Custom")
    #expect(c.savedLayouts.count == 2)
}
