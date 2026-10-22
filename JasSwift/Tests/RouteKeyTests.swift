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
    // (`Tab` was this arm's long token until it became a caret key.)
    #expect(routeKey("PageUp", m(), toolTakes: free) == .badKey)
    #expect(routeKey("", m(), toolTakes: free) == .badKey)
}

/// The caret keys (the Type tool's named gaps): a tool editing text takes them;
/// with none, a key `shortcuts.yaml` binds runs its action (the arrows nudge)
/// and the rest are unhandled, never a bad key name.
@Test func routeKeyCaretKeysGoToAToolThatTakesThemAndAreUnhandledOtherwise() {
    for k in ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "Tab"] {
        #expect(routeKey(k, m(), toolTakes: takes) == .toolKey(k), "\(k) to the tool")
        #expect(routeKey(k, m(ctrl: true, shift: true), toolTakes: takes) == .toolKey(k), "\(k): modifiers too")
    }
    for k in ["Home", "End", "Tab"] {
        #expect(routeKey(k, m(), toolTakes: free) == .unhandled, "\(k) with no tool")
    }
    #expect(routeKey("F13", m(), toolTakes: free) == .badKey, "CONTROL: still a bad name")
}

/// An arrow no tool takes is `nudge_selection`: 1 pt, 10 with Shift, and up
/// is toward smaller y. Every (key, shift) pair is a DIFFERENT move.
@Test func routeKeyAnUnclaimedArrowNudgesOnePointOrTenWithShift() {
    var seen = Set<[Double]>()
    for (k, dx, dy) in [("ArrowLeft", -1.0, 0.0), ("ArrowRight", 1, 0), ("ArrowUp", 0, -1), ("ArrowDown", 0, 1)] {
        for (shift, n) in [(false, 1.0), (true, 10.0)] {
            guard case .action(let cmd) = routeKey(k, m(shift: shift), toolTakes: free) else {
                Issue.record("\(k) shift=\(shift): not an action")
                continue
            }
            #expect(cmd.action == "nudge_selection", "\(k) shift=\(shift)")
            let got = [cmd.params["dx"]?.number ?? .nan, cmd.params["dy"]?.number ?? .nan]
            #expect(got == [dx * n, dy * n], "\(k) shift=\(shift)")
            seen.insert(got)
        }
    }
    #expect(seen.count == 8, "eight distinct moves")
}

/// Only a bare or Shift arrow is bound: Ctrl and Alt name no binding.
@Test func routeKeyACtrlOrAltArrowIsUnhandled() {
    #expect(routeKey("ArrowLeft", KeyMods(alt: true), toolTakes: free) == .unhandled)
    #expect(routeKey("ArrowRight", m(ctrl: true), toolTakes: free) == .unhandled)
    if case .action = routeKey("ArrowRight", m(), toolTakes: free) {} else {
        Issue.record("CONTROL: a bare arrow is an action")
    }
}

/// THE NUDGE THROUGH THE CANVAS'S DOOR (`LayersPanel.dispatchYamlAction`, the
/// call the canvas's arrow arm makes): it moves the selection, a run of nudges
/// of one selection is ONE undo step (the journal's drag coalescing), and with
/// nothing selected it records no undo step. Mirrors Rust
/// `an_arrow_key_nudges_the_selection_and_a_run_of_nudges_is_one_undo_step`.
@Test func aRunOfNudgesIsOneUndoStepAndNothingSelectedRecordsNone() {
    let model = Model(document: Document(layers: [Layer(children: [
        .rect(Rect(x: 10, y: 20, width: 30, height: 40)),
    ])]))
    LayersPanel.dispatchYamlAction("nudge_selection", model: model, params: ["dx": 1, "dy": 0])
    #expect(!model.canUndo, "nothing selected: no undo step")
    let x = { () -> [Double] in
        guard case .rect(let r) = model.document.layers[0].children[0] else { return [] }
        return [r.x, r.y]
    }
    #expect(x() == [10, 20], "and nothing moved")
    Controller(model: model).selectAll()
    LayersPanel.dispatchYamlAction("nudge_selection", model: model, params: ["dx": 1, "dy": 0])
    #expect(x() == [11, 20], "one point right")
    LayersPanel.dispatchYamlAction("nudge_selection", model: model, params: ["dx": 0, "dy": -10])
    #expect(x() == [11, 10], "ten up")
    model.undo()
    #expect(x() == [10, 20], "one undo takes back the run")
}
