import Foundation
import Testing
@testable import JasLib

// MenuActions.run: the model-pure menu verbs by name, one table, mirroring Rust
// `menu_native::VERBS` / `run`. The live menu and the level-1 script runner
// both go through it.

@Test func theMenuVerbsAreRustsSix() {
    // Rust `menu_native::VERBS`, in its order. The three whose YAML is `doc.op`
    // are not in it: the menu runs their declared action.
    #expect(MenuActions.verbs == ["select_all", "group", "ungroup", "ungroup_all", "lock",
                                  "make_instance"])
    #expect(MenuActions.yamlVerbs == ["unlock_all", "hide_selection", "show_all"])
}

@Test func runRefusesAnythingElseAndRunsNothing() {
    let model = Model()
    let before = model.document
    for action in ["copy", "paste", "delete_selection", "", "Group",
                   "unlock_all", "hide_selection", "show_all"] {
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

// The three verbs whose YAML is `doc.op` keep the native table's ONE undo step
// (it ran each under `withTxn`) on the route the menu now takes
// (`LayersPanel.dispatchYamlAction`). That dispatcher owns one transaction per
// action: a mutant deleting the YAML's `snapshot` SURVIVES here (driven
// 2026-10-25), while one deleting the `doc.op` reds the unlock below.
@Test func theDocOpVerbsAreEachOneUndoStep() {
    let model = Model()
    let r = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    model.setDocumentForTest(Document(layers: [Layer(name: "L", children: [r], locked: true)],
                                      selectedLayer: 0, selection: []))
    LayersPanel.dispatchYamlAction("unlock_all", model: model)
    #expect(Element.layer(model.document.layers[0]).isLocked == false, "unlocked")
    model.undo()
    #expect(Element.layer(model.document.layers[0]).isLocked == true, "one undo restores the lock")
}
