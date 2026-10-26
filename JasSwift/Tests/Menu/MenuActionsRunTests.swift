import Foundation
import Testing
@testable import JasLib

// MenuActions.run: the model-pure menu verbs by name, one table, mirroring Rust
// `menu_native::VERBS` / `run`. The live menu and the level-1 script runner
// both go through it.

@Test func theMenuVerbsAreRustsFour() {
    // Rust `menu_native::VERBS`, in its order. Those whose YAML is `doc.op`
    // are not in it: the menu runs their declared action.
    #expect(MenuActions.verbs == ["group", "ungroup", "ungroup_all", "make_instance"])
    #expect(MenuActions.yamlVerbs == ["unlock_all", "hide_selection", "show_all", "lock", "select_all"])
}

@Test func runRefusesAnythingElseAndRunsNothing() {
    let model = Model()
    let before = model.document
    for action in ["copy", "paste", "delete_selection", "", "Group",
                   "unlock_all", "hide_selection", "show_all", "lock", "select_all"] {
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

// Select All runs its YAML (`doc.op: {op: select_all}`, no `snapshot`) from the
// menu, the canvas context menu and the FIFO channel: every visible, unlocked
// direct child of a layer, a group as one object, and NOT an undo step, as the
// native table it left made it.
@Test func selectAllRunsItsYamlAndIsNotAnUndoStep() {
    let model = Model()
    let r = { (x: Double, locked: Bool) in
        Element.rect(Rect(x: x, y: 0, width: 10, height: 10, locked: locked)) }
    let group = Element.group(Group(children: [r(40, true), r(60, false)]))
    model.setDocumentForTest(Document(layers: [
        Layer(name: "Locked", children: [r(0, false)], locked: true),
        Layer(name: "Open", children: [r(20, true), r(30, false), group]),
    ], selectedLayer: 1, selection: []))
    LayersPanel.dispatchYamlAction("select_all", model: model)
    #expect(Set(model.document.selection.map(\.path)) == Set([[1, 1], [1, 2]]),
            "the unlocked rect and the group as one; nothing locked")
    #expect(!model.canUndo, "selecting is not an edit")
}
