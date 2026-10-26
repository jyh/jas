import Testing
@testable import JasLib

// STATUS-jas item 8, delete_selection's Swift half: every Swift delete route
// runs actions.yaml `delete_selection`, which asks through
// `active_document.selection_orphan_count`. The Mac presents the
// `delete_orphan_confirm` the YAML opens AS its NSAlert (`confirm` here), and
// a Delete there runs `delete_orphan_confirm_ok`'s YAML.

/// A rect, an unrelated rect, and a live reference to the first (made by the
/// real make_instance action), with `select` as the canvas selection.
private func referencedModel(select: [ElementPath]) -> Model {
    let model = Model(document: Document(
        layers: [Layer(name: "L", children: [
            .rect(Rect(x: 0, y: 0, width: 10, height: 10)),
            .rect(Rect(x: 20, y: 0, width: 10, height: 10)),
        ])],
        selectedLayer: 0,
        selection: [ElementSelection.all([0, 0])]))
    LayersPanel.dispatchYamlAction("make_instance", model: model)
    #expect(model.document.layers[0].children.count == 3, "the reference is made")
    Controller(model: model).setSelection(select.map { ElementSelection.all($0) })
    return model
}

@Test func activeDocumentViewPublishesTheSelectionOrphanCount() {
    let read = { (m: Model?) in buildActiveDocumentView(model: m)["selection_orphan_count"] as? Int }
    #expect(read(referencedModel(select: [])) == 0, "nothing selected")
    #expect(read(referencedModel(select: [[0, 1]])) == 0, "an unreferenced rect")
    #expect(read(referencedModel(select: [[0, 0]])) == 1, "the referenced rect")
    #expect(read(referencedModel(select: [[0, 0], [0, 2]])) == 0, "the target and its reference")
    #expect(read(nil) == 0, "no document")
}

@Test func deleteSelectionAsksBeforeStrandingAReferenceAndCancelChangesNothing() {
    let model = referencedModel(select: [[0, 0]])
    let before = model.document
    var asked: [Int] = []
    JasCommands.runDeleteSelection(model, confirm: { asked.append($0); return false })
    #expect(asked == [1], "the confirm names the count")
    #expect(model.document == before, "Cancel deletes nothing")
    #expect(model.stateStore.getDialogId() == nil, "no dialog is left open in the store")
}

@Test func deleteSelectionConfirmedDeletesAsOneUndoStep() {
    let model = referencedModel(select: [[0, 0]])
    let before = model.document
    JasCommands.runDeleteSelection(model, confirm: { _ in true })
    #expect(model.document.layers[0].children.count == 2, "the rect is deleted")
    #expect(model.stateStore.getDialogId() == nil)
    model.undo()
    #expect(model.document.layers[0].children == before.layers[0].children, "one undo brings it back")
}

@Test func deleteSelectionWithNothingToStrandDeletesWithoutAsking() {
    let model = referencedModel(select: [[0, 1]])
    var asked = false
    JasCommands.runDeleteSelection(model, confirm: { _ in asked = true; return false })
    #expect(!asked)
    #expect(model.document.layers[0].children.count == 2)
    #expect(model.document.selection.isEmpty)
}

@Test func deleteSelectionWithNothingSelectedChangesNothing() {
    let model = referencedModel(select: [])
    let before = model.document
    let undoable = model.canUndo
    JasCommands.runDeleteSelection(model, confirm: { _ in Issue.record("asked"); return true })
    #expect(model.document == before)
    #expect(model.canUndo == undoable, "no undo step")
}

@Test func theFifoDeleteRunsTheYamlAndStrandsNothing() {
    let model = referencedModel(select: [[0, 0]])
    let before = model.document
    FifoActionRouting.dispatch("delete_selection", model: model)
    #expect(model.document == before, "headless: the delete waits on delete_orphan_confirm")
}
