import CoreGraphics
import Testing
@testable import JasLib

// Row 129: the Mac's tab drop sends the hovered position, as the web has
// since row 128 (WORKSPACE.md "Moving a Panel to Another Group": the left
// half of a tab inserts before it, the right half after). Each arm drives
// the pure helpers the dock's drop delegate calls, so the SwiftUI view
// only supplies the point and the measured tab frames.

/// Three tabs, 60 pt wide, side by side after a 20 pt grip, in a 24 pt bar.
private let frames: [CGRect] = [
    CGRect(x: 20, y: 0, width: 60, height: 24),
    CGRect(x: 80, y: 0, width: 60, height: 24),
    CGRect(x: 140, y: 0, width: 60, height: 24),
]

@Test func aDropOnATabsLeftHalfInsertsBeforeIt() {
    #expect(dockTabDropSlot(at: CGPoint(x: 85, y: 12), tabFrames: frames) == 1)
    #expect(dockTabDropSlot(at: CGPoint(x: 21, y: 12), tabFrames: frames) == 0)
}

@Test func aDropOnATabsRightHalfInsertsAfterIt() {
    #expect(dockTabDropSlot(at: CGPoint(x: 135, y: 12), tabFrames: frames) == 2)
    #expect(dockTabDropSlot(at: CGPoint(x: 199, y: 12), tabFrames: frames) == 3)
}

@Test func theMidpointBelongsToTheRightHalf() {
    // The web's rule is `x < mid` before, else after.
    #expect(dockTabDropSlot(at: CGPoint(x: 110, y: 12), tabFrames: frames) == 2)
    #expect(dockTabDropSlot(at: CGPoint(x: 109.9, y: 12), tabFrames: frames) == 1)
}

@Test func aDropOffEveryTabAppends() {
    // The bar's empty space past the tabs, the grip, and the panel body.
    #expect(dockTabDropSlot(at: CGPoint(x: 230, y: 12), tabFrames: frames) == 3)
    #expect(dockTabDropSlot(at: CGPoint(x: 5, y: 12), tabFrames: frames) == 3)
    #expect(dockTabDropSlot(at: CGPoint(x: 85, y: 200), tabFrames: frames) == 3)
    #expect(dockTabDropSlot(at: CGPoint(x: 85, y: 12), tabFrames: []) == 0)
}

private let g0 = GroupAddr(dockId: DockId(0), groupIdx: 0)
private let g1 = GroupAddr(dockId: DockId(0), groupIdx: 1)

@Test func aCrossGroupDropPassesTheSlotAsToIndex() {
    let op = dockPanelDropOp(from: PanelAddr(group: g0, panelIdx: 2), onto: g1, slot: 1)
    #expect(op["op"] as? String == "move_panel_to_group")
    #expect(op["to_index"] as? Int == 1)
    #expect(op["to_group_idx"] as? Int == 1)
}

@Test func aSameGroupDropReordersToThePostRemovalIndex() {
    // Row 130: a slot counts gaps with the panel still in place; `reorder_panel`'s
    // `to` is an index after it is removed. Backward slots are unchanged.
    let back = dockPanelDropOp(from: PanelAddr(group: g1, panelIdx: 2), onto: g1, slot: 0)
    #expect(back["op"] as? String == "reorder_panel")
    #expect(back["from"] as? Int == 2)
    #expect(back["to"] as? Int == 0)
    let fwd = dockPanelDropOp(from: PanelAddr(group: g1, panelIdx: 0), onto: g1, slot: 2)
    #expect(fwd["to"] as? Int == 1)
}

@Test func aDropSlotMapsToTheReorderIndex() {
    // The twin of Rust's `a_drop_slot_maps_to_the_reorder_index`, case for case.
    #expect(reorderToForDropSlot(from: 0, slot: 2) == 1)
    #expect(reorderToForDropSlot(from: 0, slot: 3) == 2)
    #expect(reorderToForDropSlot(from: 2, slot: 0) == 0)
    #expect(reorderToForDropSlot(from: 2, slot: 1) == 1)
    #expect(reorderToForDropSlot(from: 1, slot: 1) == 1)
    #expect(reorderToForDropSlot(from: 1, slot: 2) == 1)
}

/// Three tabs, as the web probe built them: the default group 0 is two tabs,
/// so group 1's first panel is moved to its end.
private func threeTabLayout() -> (WorkspaceLayout, GroupAddr) {
    var layout = WorkspaceLayout.defaultLayout()
    let did = layout.anchored[0].1.id
    layoutApply(&layout, opMovePanelToGroup(PanelAddr(group: GroupAddr(dockId: did, groupIdx: 1), panelIdx: 0),
                                            to: GroupAddr(dockId: did, groupIdx: 0)))
    return (layout, GroupAddr(dockId: did, groupIdx: 0))
}

@Test func aSameGroupDropLandsAtTheCaret() {
    var (layout, g) = threeTabLayout()
    let before = layout.anchored[0].1.groups[0].panels
    #expect(before.count == 3)
    layoutApply(&layout, dockPanelDropOp(from: PanelAddr(group: g, panelIdx: 0), onto: g, slot: 2))
    #expect(layout.anchored[0].1.groups[0].panels == [before[1], before[0], before[2]])
    var (own, _) = threeTabLayout()
    layoutApply(&own, dockPanelDropOp(from: PanelAddr(group: g, panelIdx: 0), onto: g, slot: 1))
    #expect(own.anchored[0].1.groups[0].panels == before, "its own right half is a no-op")
}

@Test func aCrossGroupDropLandsAtTheHoveredTab() {
    // End to end through layoutApply: the panel lands at the slot, not the end.
    var layout = WorkspaceLayout.defaultLayout()
    guard let dock = layout.anchored.first?.1, dock.groups.count >= 2 else {
        Issue.record("default layout has fewer than two groups"); return
    }
    let src = GroupAddr(dockId: dock.id, groupIdx: 0)
    let dst = GroupAddr(dockId: dock.id, groupIdx: 1)
    let moved = dock.groups[0].panels[0]
    let before = dock.groups[1].panels
    #expect(before.count >= 2)
    layoutApply(&layout, dockPanelDropOp(from: PanelAddr(group: src, panelIdx: 0), onto: dst, slot: 1))
    let after = layout.dock(dock.id)?.groups[1].panels ?? []
    #expect(after == [before[0], moved] + before.dropFirst())
}
