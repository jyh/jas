import Foundation
import Testing
@testable import JasLib

// STATUS-jas row 286: with NO document open, every panel button in the Mac
// dock was inert. The dock was handed `workspace.activeModel`, nil with no
// canvas, so a click returned at `guard let model` (logged live 11-27). On
// Windows both panel buttons act with no document (flask STATUS-flask 1030),
// as with one. The dock now acts on the workspace's APP model when no
// document is open: a Model adopted into the same app tiers every canvas
// shares, so an app-level effect lands where the next document reads it.

private func shippedWidget(_ id: String) -> [String: Any]? {
    func walk(_ node: Any) -> [String: Any]? {
        if let d = node as? [String: Any] {
            if d["id"] as? String == id { return d }
            for v in d.values { if let hit = walk(v) { return hit } }
        } else if let a = node as? [Any] {
            for v in a { if let hit = walk(v) { return hit } }
        }
        return nil
    }
    return walk(WorkspaceData.load()?.panels() ?? [:])
}

@Test func withNoDocumentTheDockActsOnTheAppModel() {
    let ws = WorkspaceState()
    #expect(ws.activeModel == nil, "the precondition: no canvas is open")
    let m = ws.dockModel
    #expect(m === ws.appModel)
    #expect(m.appDefaults === ws.appDefaults, "it shares the app default-paint tier")
    #expect(m.swatchLibraries === ws.swatchLibraries)
    #expect(m.gradientLibraries === ws.gradientLibraries)
    #expect(m.stateStore.sharedBrushLibraries === ws.brushLibraries)
}

@Test func withADocumentTheDockActsOnIt() {
    let ws = WorkspaceState()
    let doc = Model(document: Document.newEmptyDocument())
    ws.addCanvas(doc)
    #expect(ws.dockModel === doc)
}

@Test func colorNoneWithNoDocumentIsReadByTheNextDocument() throws {
    let ws = WorkspaceState()
    let w = try #require(shippedWidget("cp_none_swatch"))
    #expect(ws.dockModel.appDefaultFill != nil, "the precondition: the app fill is not already none")
    let r = PanelWidgetEvents(model: ws.dockModel, panelId: "color_panel_content").click(w)
    #expect(r.outcome == "committed", "\(r)")
    #expect(ws.dockModel.appDefaultFill == nil, "the click acted with no document")
    let next = Model(document: Document.newEmptyDocument())
    ws.addCanvas(next)
    #expect(next.appDefaultFill == nil, "File > New inherits it")
}
