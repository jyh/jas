import Testing
@testable import JasLib

// Mirrors Rust `workspace::resolve_key::route_key_tests`, arm for arm.

private func m(ctrl: Bool = false, shift: Bool = false) -> KeyMods { KeyMods(shift: shift, ctrl: ctrl) }
private let free: (String) -> Bool = { _ in false }
private let takes: (String) -> Bool = { _ in true }

@Test func routeKeyAnUnclaimedDeleteOrBackspaceDeletesTheSelection() {
    #expect(routeKey("Delete", m(), toolTakes: free) == .deleteSelection)
    #expect(routeKey("Backspace", m(), toolTakes: free) == .deleteSelection)
}

@Test func routeKeyAClaimedDeleteGoesToTheTool() {
    #expect(routeKey("Delete", m(), toolTakes: takes) == .toolKey("Delete"))
    #expect(routeKey("Backspace", m(), toolTakes: takes) == .toolKey("Backspace"))
}

@Test func routeKeyEscapeAndEnterGoToTheToolWhetherOrNotItCaptures() {
    #expect(routeKey("Escape", m(), toolTakes: free) == .toolKey("Escape"))
    #expect(routeKey("Enter", m(), toolTakes: free) == .toolKey("Enter"))
}

@Test func routeKeyACommandChordActsOnlyForUndoAndRedo() {
    #expect(routeKey("Z", m(ctrl: true), toolTakes: free) == .undo)
    #expect(routeKey("z", m(ctrl: true), toolTakes: free) == .undo)
    #expect(routeKey("Z", m(ctrl: true, shift: true), toolTakes: free) == .redo)
    // Ctrl+G is `group` in shortcuts.yaml: the menu's, not the key route's.
    #expect(routeKey("G", m(ctrl: true), toolTakes: free) == .unhandled)
}

@Test func routeKeyAnUnmodifiedToolLetterSelectsThatTool() {
    #expect(routeKey("V", m(), toolTakes: free) == .selectTool("selection"))
    #expect(routeKey("M", m(), toolTakes: free) == .selectTool("rect"))
}

@Test func routeKeyAnUnboundCharacterIsUnhandledAndALongTokenIsRefused() {
    #expect(routeKey("J", m(), toolTakes: free) == .unhandled)
    #expect(routeKey("Tab", m(), toolTakes: free) == .badKey)
    #expect(routeKey("", m(), toolTakes: free) == .badKey)
}
