import Foundation
import Testing
@testable import JasLib

// Row 174: the Character panel menu runs its actions.yaml entries on the Mac
// through the generic row route (`panelDispatchRow`), as the engine runs them
// (`ffi` arm `every_live_character_menu_item_runs_in_the_engine`, the same
// sequence) and as the web does (`character_panel::tests`). Read off the
// ELEMENT, never through the panel.

private func modelWithSelectedText() -> Model {
    let model = Model()
    let text = Element.text(Text(x: 0, y: 20, content: "Hello", fontSize: 16, width: 0, height: 0))
    model.setDocumentForTest(Document(layers: [Layer(children: [text])],
                                      selectedLayer: 0,
                                      selection: [ElementSelection(path: [0, 0])]))
    return model
}

private func caseOf(_ model: Model) -> [String] {
    guard case .text(let t) = model.document.getElement([0, 0]) else { return ["not text"] }
    return [t.textTransform, t.fontVariant, t.baselineShift]
}

@Test func theCharacterMenuRunsItsYamlOnTheMac() {
    let model = modelWithSelectedText()
    var layout = WorkspaceLayout.defaultLayout()
    let addr = PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0)
    #expect(caseOf(model) == ["", "", ""], "the control")
    let steps: [(String, [String], String)] = [
        ("toggle_all_caps", ["uppercase", "", ""], "All Caps"),
        ("toggle_small_caps", ["", "small-caps", ""], "Small Caps clears All Caps"),
        ("toggle_superscript", ["", "small-caps", "super"], "Superscript"),
        ("toggle_subscript", ["", "small-caps", "sub"], "Subscript clears Superscript"),
        ("toggle_subscript", ["", "small-caps", ""], "Subscript again turns it off"),
        ("toggle_small_caps", ["", "", ""], "Small Caps again turns it off"),
    ]
    for (cmd, want, why) in steps {
        panelDispatch(.character, cmd: cmd, addr: addr, layout: &layout, model: model)
        #expect(caseOf(model) == want, "\(why)")
    }
}

// STATUS-flask §944 on the Mac: an exclusive toggle unchecks its sibling in
// the MENU, and the next click on the sibling acts. A toggle writes one store
// key and never clears its sibling, so the menu reads the selection as the
// panel body does (`characterPanelLiveOverrides`), and the row runs on a store
// that holds it (the engine's `panel_scope::sync_character_state`).
@Test func anExclusiveCharacterToggleUnchecksItsSiblingInTheMacMenu() {
    let model = modelWithSelectedText()
    var layout = WorkspaceLayout.defaultLayout()
    let addr = PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0)
    let checks: () -> [Bool] = {
        ["toggle_all_caps", "toggle_small_caps", "toggle_superscript", "toggle_subscript"]
            .map { panelIsChecked(.character, cmd: $0, layout: layout, model: model) }
    }
    let run: (String) -> Void = { cmd in
        panelDispatch(.character, cmd: cmd, addr: addr, layout: &layout, model: model)
    }
    #expect(checks() == [false, false, false, false], "the control: nothing checked")
    run("toggle_all_caps")
    run("toggle_small_caps")
    #expect(caseOf(model) == ["", "small-caps", ""], "the document was already right")
    #expect(checks() == [false, true, false, false], "after All Caps then Small Caps")
    run("toggle_all_caps")
    #expect(caseOf(model) == ["uppercase", "", ""], "All Caps again acts")
    #expect(checks() == [true, false, false, false], "after Small Caps then All Caps")
    run("toggle_superscript")
    run("toggle_subscript")
    #expect(checks() == [true, false, false, true], "after Superscript then Subscript")
    run("toggle_superscript")
    #expect(caseOf(model) == ["uppercase", "", "super"], "Superscript again acts")
    #expect(checks() == [true, false, true, false], "after Subscript then Superscript")
}
