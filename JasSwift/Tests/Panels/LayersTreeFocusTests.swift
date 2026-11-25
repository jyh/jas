import Testing
import AppKit
@testable import JasLib

// STATUS-jas row 208 R4 (read live on the Mac test box 11-24 22:03): a click on
// a Layers row selected it (panel selection [[1,0]]) and Delete then did
// nothing, because the tree's keys run only while the tree holds keyboard
// focus and nothing ever gave it focus: SwiftUI's `.focusable()` takes none
// from a tap. Windows deleted in the same case, and the web's tree takes focus
// from its `tabindex` on the click. `LayersTreeFocus.afterEvent` is the rule
// the tree's event monitor applies to every event it sees.

@Test func aPressOnARowFocusesTheTree() {
    #expect(LayersTreeFocus.afterEvent(.leftMouseDown, onRow: true, focused: false, renaming: false) == true)
}

@Test func aSecondaryPressOnARowFocusesTheTree() {
    #expect(LayersTreeFocus.afterEvent(.rightMouseDown, onRow: true, focused: false, renaming: false) == true)
}

@Test func aPressOffTheRowsTakesFocusAway() {
    // A click on the canvas after a row click must not leave Delete with the
    // tree: it would delete the panel selection instead of the canvas's.
    #expect(LayersTreeFocus.afterEvent(.leftMouseDown, onRow: false, focused: true, renaming: false) == false)
    #expect(LayersTreeFocus.afterEvent(.rightMouseDown, onRow: false, focused: true, renaming: false) == false)
}

@Test func otherEventsLeaveFocusAsItIs() {
    for type in [NSEvent.EventType.keyDown, .flagsChanged] {
        #expect(LayersTreeFocus.afterEvent(type, onRow: true, focused: false, renaming: false) == false)
        #expect(LayersTreeFocus.afterEvent(type, onRow: false, focused: true, renaming: false) == true)
    }
}

@Test func aPressDuringARenameLeavesFocusWithTheField() {
    // The rename field sits on a row: a press in it must not pull focus to
    // the tree, which would end the rename.
    #expect(LayersTreeFocus.afterEvent(.leftMouseDown, onRow: true, focused: false, renaming: true) == false)
    #expect(LayersTreeFocus.afterEvent(.leftMouseDown, onRow: false, focused: true, renaming: true) == true)
}
