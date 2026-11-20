import Foundation
import Testing
@testable import JasLib

// Row 179: the Artboards rename field's declared `keydown` behaviors (Enter
// confirms with the field's text, Escape cancels) run through the text-entry
// door the panel view now calls for a field that declares them. Until then the
// view sent only a commit, which this field declares nothing for. The node is
// artboards.yaml's own; the row's `ab` rides in the route's scope.
// ⚠️ The view's wiring itself (onSubmit / onExitCommand / focus loss) is
// SwiftUI and is not driven here.

private func renameRoute() -> (Model, PanelWidgetEvents, [String: Any], String) {
    let model = Model()
    model.setDocumentForTest(model.document.replacing(artboards: [Artboard.defaultWithId("ab-rename")]))
    guard let ab = model.document.artboards.first else { fatalError("the fixture's artboard") }
    model.stateStore.initPanel("artboards_panel_content",
                               defaults: WorkspaceData.load()?.panelStateDefaults("artboards_panel_content") ?? [:])
    model.stateStore.setPanel("artboards_panel_content", "renaming_artboard", ab.id)
    let node = WidgetEvent.findWidget(in: WorkspaceData.load()?.panel("artboards_panel_content"),
                                      id: "ap_name_edit") ?? [:]
    let route = PanelWidgetEvents(model: model, panelId: "artboards_panel_content",
                                  scope: ["ab": ["id": ab.id, "name": ab.name]])
    return (model, route, node, ab.id)
}

private func nameOf(_ model: Model, _ id: String) -> String {
    model.document.artboards.first(where: { $0.id == id })?.name ?? "missing"
}

@Test func theArtboardRenameFieldConfirmsOnEnterWithItsText() {
    let (model, route, node, id) = renameRoute()
    #expect(node["type"] as? String == "text_input", "the control: artboards.yaml's ap_name_edit")
    #expect(nameOf(model, id) != "Cover", "the control: not already the new name")
    let r = route.textEntry(node, event: "keydown", text: "Cover", key: "Enter")
    #expect(r.outcome == "committed", "the door ran the Enter behavior: \(r.outcome) \(String(describing: r.reason)) ran=\(r.behaviorsRun)")
    let after = model.stateStore.getPanel("artboards_panel_content", "renaming_artboard")
    #expect(after == nil || after is NSNull, "the action's last effect closed the field: \(String(describing: after))")
    #expect(nameOf(model, id) == "Cover", "names: \(model.document.artboards.map { $0.id + "=" + $0.name })")
}

@Test func theArtboardRenameFieldCancelsOnEscapeAndIgnoresALetter() {
    let (model, route, node, id) = renameRoute()
    let before = nameOf(model, id)
    route.textEntry(node, event: "keydown", text: "Cov", key: "v")
    #expect(nameOf(model, id) == before, "a letter is not Enter")
    route.textEntry(node, event: "keydown", text: "Cov", key: "Escape")
    #expect(nameOf(model, id) == before, "Escape writes no name")
    #expect(model.stateStore.getPanel("artboards_panel_content", "renaming_artboard") is NSNull
            || model.stateStore.getPanel("artboards_panel_content", "renaming_artboard") == nil,
            "and closes the field")
}

// The same routing law for the panel's Move Up button: `doc.move_artboards_up`
// is not in Align's table either, so the action ran and moved nothing.
@Test func thePanelBodyRouteRunsTheArtboardsMoveUp() {
    let model = Model()
    model.setDocumentForTest(model.document.replacing(
        artboards: [Artboard.defaultWithId("ab-one"), Artboard.defaultWithId("ab-two")]))
    #expect(model.document.artboards.map { $0.id } == ["ab-one", "ab-two"], "the control")
    dispatchPanelAction("move_artboard_up", params: [:],
                        actions: WorkspaceData.load()?.actions(),
                        ctx: ["active_document": ["artboards_panel_selection_ids": ["ab-two"]]],
                        store: model.stateStore, model: model, onDialogOpened: nil)
    #expect(model.document.artboards.map { $0.id } == ["ab-two", "ab-one"])
}
