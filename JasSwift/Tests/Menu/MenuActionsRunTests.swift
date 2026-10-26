import Foundation
import Testing
@testable import JasLib

// The Edit / Object model verbs: since 2026-10-25 none has a native table; the
// menu runs each one's declared action (`MenuActions.yamlVerbs`), as the
// engine's door and the web menu do (Rust `menu_native` keeps only the
// clipboard and Delete laws).

@Test func everyMenuModelVerbRunsItsYaml() {
    #expect(MenuActions.yamlVerbs == ["unlock_all", "hide_selection", "show_all", "lock", "select_all",
                                      "group", "ungroup", "ungroup_all", "make_instance", "promote_to_concept"])
}

// Make Instance runs its YAML (`snapshot` + `doc.make_instance`): an offset
// reference to the ONE selected element, selected, as ONE undo step; with two
// selected it changes nothing.
@Test func makeInstanceRunsItsYamlAsOneUndoStep() {
    let model = Model()
    let r = { (x: Double) in Element.rect(Rect(x: x, y: 0, width: 10, height: 10)) }
    model.setDocumentForTest(Document(layers: [Layer(children: [r(0), r(20)])], selectedLayer: 0,
                                      selection: [ElementSelection.all([0, 0]), ElementSelection.all([0, 1])]))
    LayersPanel.dispatchYamlAction("make_instance", model: model)
    #expect(model.document.layers[0].children.count == 2, "two selected: nothing")
    #expect(!model.canUndo, "and no undo step")
    model.setDocumentForTest(Document(layers: [Layer(children: [r(0), r(20)])], selectedLayer: 0,
                                      selection: [ElementSelection.all([0, 0])]))
    LayersPanel.dispatchYamlAction("make_instance", model: model)
    #expect(model.document.layers[0].children.count == 3, "the reference is added")
    #expect(Set(model.document.selection.map(\.path)) == Set([[0, 2]]), "and selected")
    model.undo()
    #expect(model.document.layers[0].children.count == 2, "ONE undo removes it")
    #expect(!model.canUndo, "it was one step")
}

// Group, Ungroup and Ungroup All run their YAML (`snapshot` + `doc.op`) from
// the menu: each ONE undo step, as the native table made them with `withTxn`.
@Test func theGroupVerbsRunTheirYamlAndAreEachOneUndoStep() {
    let model = Model()
    let r = { (x: Double) in Element.rect(Rect(x: x, y: 0, width: 10, height: 10)) }
    model.setDocumentForTest(Document(layers: [Layer(children: [r(0), r(20)])], selectedLayer: 0,
                                      selection: [ElementSelection.all([0, 0]), ElementSelection.all([0, 1])]))
    let isGroup = { (m: Model) in m.document.layers[0].children.map { if case .group = $0 { true } else { false } } }
    LayersPanel.dispatchYamlAction("group", model: model)
    #expect(isGroup(model) == [true], "group")
    #expect(Set(model.document.selection.map(\.path)) == Set([[0, 0]]), "the group is selected")
    LayersPanel.dispatchYamlAction("ungroup", model: model)
    #expect(isGroup(model) == [false, false], "ungroup")
    #expect(Set(model.document.selection.map(\.path)) == Set([[0, 0], [0, 1]]), "its members are selected")
    model.undo()
    #expect(isGroup(model) == [true], "one undo restores ungroup")
    model.undo()
    #expect(isGroup(model) == [false, false], "one more restores group")
    model.setDocumentForTest(Document(layers: [Layer(children: [.group(Group(children: [r(0), r(20)]))])],
                                      selectedLayer: 0, selection: []))
    LayersPanel.dispatchYamlAction("ungroup_all", model: model)
    #expect(isGroup(model) == [false, false], "ungroup_all")
    model.undo()
    #expect(isGroup(model) == [true], "one undo restores ungroup_all")
    #expect(!model.canUndo, "ungroup_all was ONE step")
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
