import Foundation
import Testing
@testable import JasLib

// STATUS-jas row 283 (1): on the Mac, the Artboards panel's `ap_new` pressed
// by AXPress left ONE artboard (measured live 11-26, slot-1126e). The app
// presses a click-kind button through ``PanelWidgetEvents/click`` (the
// widget route the level-1 scripts drive), while `new_artboard` itself was
// tested only through ``LayersPanel/dispatchYamlAction``. This drives the
// button's own route on the shipped spec.

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

/// The route as the dock builds it: the panel's own render scope
/// (``buildPanelBodyContext``), which carries `active_document`.
private func appRoute(_ model: Model) -> PanelWidgetEvents {
    let ws = WorkspaceData.load()!
    return PanelWidgetEvents(model: model, panelId: "artboards_panel_content", scope: buildPanelBodyContext(
        ws: ws, model: model, contentId: "artboards_panel_content", opacityPanel: OpacityPanelState()))
}

@Test func clickingTheShippedNewArtboardButtonAddsAnArtboard() throws {
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: [Artboard.defaultWithId("aaa00001")]
    ))
    let w = try #require(shippedWidget("ap_new"))
    let result = appRoute(model).click(w)
    #expect(result.outcome == "committed", "\(result)")
    #expect(model.document.artboards.count == 2)
}

@Test func clickingTheShippedDeleteArtboardsButtonDeletesTheSelectedOne() throws {
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: [Artboard.defaultWithId("aaa00001"), Artboard.defaultWithId("bbb00002")]
    ))
    model.stateStore.initPanel("artboards_panel_content", defaults: ["artboards_panel_selection": ["bbb00002"]])
    let w = try #require(shippedWidget("ap_delete"))
    let result = appRoute(model).click(w)
    #expect(result.outcome == "committed", "\(result)")
    #expect(model.document.artboards.map(\.id) == ["aaa00001"])
}

@Test func aDocEffectIsFoundAtAnyDepth() {
    let none: [String: PlatformEffect] = [:]
    let held: [String: PlatformEffect] = ["doc.x": { _, _, _ in nil }]
    #expect(effectsNeedDocRegistry([["doc.x": 1]], table: none))
    #expect(effectsNeedDocRegistry(["snapshot", ["if": ["condition": "c", "then": [["doc.x": 1]]]]], table: none))
    #expect(effectsNeedDocRegistry([["if": ["condition": "c", "then": [], "else": [["doc.x": 1]]]]], table: none))
    #expect(effectsNeedDocRegistry([["foreach": ["source": "s", "do": [["if": ["then": [["doc.x": 1]]]]]]]], table: none))
    #expect(!effectsNeedDocRegistry([["doc.x": 1]], table: held), "a handler the table holds runs there")
    #expect(!effectsNeedDocRegistry(["snapshot", ["set_panel_state": ["key": "k"]]], table: none))
}
