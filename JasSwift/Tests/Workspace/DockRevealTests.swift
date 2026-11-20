/// Row 111 (Mac): Window ▸ <panel> raises a tab in a dock group, and the dock
/// must then SHOW that group. The Captain's Mac reading on 11-20 (B): Window ▸
/// Layers raised the Layers tab in the bottom group, but the window's bottom
/// edge cut the group off at the default size, and the side dock had no
/// scroller to bring it back. The fix puts the side dock's groups in a
/// ScrollView and scrolls to the group this function names; these arms pin
/// which group that is. (The scroll itself is SwiftUI's `scrollTo` with no
/// anchor, the smallest scroll, which is the web's `nearest_scroll_delta`
/// rule; it is read on the Mac, not here.)

import Testing
@testable import JasLib

@Suite("Dock reveal target (row 111)")
struct DockRevealTests {
    private func g(_ panels: [PanelKind], active: Int = 0, collapsed: Bool = false) -> PanelGroup {
        PanelGroup(panels: panels, active: active, collapsed: collapsed, height: nil)
    }

    private var defaults: [PanelGroup] {
        [g([.color, .swatches]), g([.stroke, .properties]), g([.character]),
         g([.paragraph]), g([.artboards, .layers])]
    }

    @Test("Raising a background tab names its group (Window ▸ Layers)")
    func raisingABackgroundTabNamesItsGroup() {
        var after = defaults
        after[4].active = 1
        #expect(DockPanelView.revealTarget(before: defaults, after: after) == 4)
    }

    @Test("Expanding a collapsed group names it")
    func expandingACollapsedGroupNamesIt() {
        var before = defaults
        before[2].collapsed = true
        #expect(DockPanelView.revealTarget(before: before, after: defaults) == 2)
    }

    @Test("A new group names itself (a panel shown into a new group)")
    func aNewGroupIsNamed() {
        let before = Array(defaults.prefix(4))
        #expect(DockPanelView.revealTarget(before: before, after: defaults) == 4)
    }

    @Test("Removing a group raises nothing, though the later groups shift")
    func removingAGroupRaisesNothing() {
        var after = defaults
        after.remove(at: 2)  // groups 3 and 4 shift to 2 and 3: their active panels "change"
        #expect(DockPanelView.revealTarget(before: defaults, after: after) == nil)
    }

    @Test("No change names no group (control)")
    func noChangeNamesNoGroup() {
        #expect(DockPanelView.revealTarget(before: defaults, after: defaults) == nil)
    }

    @Test("Collapsing a group is not a raise (control)")
    func collapsingIsNotARaise() {
        var after = defaults
        after[1].collapsed = true
        #expect(DockPanelView.revealTarget(before: defaults, after: after) == nil)
    }
}
