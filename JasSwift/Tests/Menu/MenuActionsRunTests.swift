import Foundation
import Testing
@testable import JasLib

// MenuActions.run: the model-pure menu verbs by name, one table, mirroring Rust
// `menu_native::VERBS` / `run`. The live menu and the level-1 script runner
// both go through it.

@Test func theMenuVerbsAreRustsNine() {
    // Rust `menu_native::VERBS`, in its order.
    #expect(MenuActions.verbs == ["select_all", "group", "ungroup", "ungroup_all", "lock",
                                  "unlock_all", "hide_selection", "show_all", "make_instance"])
}

@Test func runRefusesAnythingElseAndRunsNothing() {
    let model = Model()
    let before = model.document
    for action in ["copy", "paste", "delete_selection", "", "Group"] {
        #expect(!MenuActions.run(action, model), "\(action)")
    }
    #expect(model.document == before)
}

@Test func runGroupsTheSelection() {
    let model = Model()
    let r = { (x: Double) in Element.rect(Rect(x: x, y: 0, width: 10, height: 10)) }
    model.setDocumentForTest(Document(layers: [Layer(children: [r(0), r(20)])], selectedLayer: 0,
                                      selection: [ElementSelection.all([0, 0]), ElementSelection.all([0, 1])]))
    #expect(MenuActions.run("group", model))
    #expect(model.document.layers[0].children.count == 1)
}
