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

@Test func aSameGroupDropReordersToTheSlot() {
    // As the web: the slot goes to `reorder_panel` unchanged.
    let op = dockPanelDropOp(from: PanelAddr(group: g1, panelIdx: 2), onto: g1, slot: 0)
    #expect(op["op"] as? String == "reorder_panel")
    #expect(op["from"] as? Int == 2)
    #expect(op["to"] as? Int == 0)
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
