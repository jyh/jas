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

// Row 208 follow-up (read live 11-24 23:11 at #1107's build): after a click on a
// row, ArrowDown and ArrowUp left the panel selection at [1]. The tree's
// layers.yaml keys ran only through SwiftUI's `onKeyPress`, which needs SwiftUI
// focus that a click does not give; the monitor now sends them too, through
// the same table. `layersTreeKeyChord(characters:flags:)` reads an NSEvent's
// `charactersIgnoringModifiers` and modifier flags.

@Test func theMonitorsChordsAreTheTreeTable() {
    let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
    let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
    let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
    let f2 = String(Character(UnicodeScalar(NSF2FunctionKey)!))
    let cases: [(String, NSEvent.ModifierFlags, String)] = [
        (up, [], "ArrowUp"), (down, [], "ArrowDown"), (left, [], "ArrowLeft"),
        (right, [], "ArrowRight"), ("\r", [], "Enter"), ("\u{1B}", [], "Escape"),
        (f2, [], "F2"), ("a", [.command], "A"),
    ]
    for (chars, flags, name) in cases {
        #expect(layersTreeKeyChord(characters: chars, flags: flags)?.key == name, "\(name)")
    }
}

@Test func theMonitorsChordsCarryTheModifiers() {
    let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
    let c = layersTreeKeyChord(characters: down, flags: [.shift, .option])
    #expect(c?.shift == true && c?.alt == true && c?.ctrl == false)
    #expect(layersTreeKeyChord(characters: "a", flags: [.command])?.ctrl == true)
}

@Test func keysTheTreeDoesNotBindPassOn() {
    // A plain letter, Delete (the monitor's own arm), and an empty string.
    #expect(layersTreeKeyChord(characters: "a", flags: []) == nil)
    #expect(layersTreeKeyChord(characters: "\u{7F}", flags: []) == nil)
    #expect(layersTreeKeyChord(characters: "", flags: []) == nil)
}
