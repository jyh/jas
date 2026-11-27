import Foundation
import Testing
@testable import JasLib

// STATUS-jas row 282: an `open_menu` widget (the Brushes panel's
// `bp_libraries_menu_btn`, the only one shipped) popped NO menu on the Mac,
// by an accessibility press or by a real click (measured live 11-26 on a
// release build of main 0b48fba1). The popup was placed only at
// `NSApp.currentEvent`, in the KEY window's content view, and either can be
// missing. The fix is #1135's rule for the hamburger menu: drop the menu below
// the requesting widget's own view, so the widget must carry an anchor. These
// pin which widgets carry one, and the link from the click to the request.

private func shippedPanels() -> [String: Any] {
    WorkspaceData.load()?.panels() ?? [:]
}

private func walk(_ node: Any, _ visit: ([String: Any]) -> Void) {
    if let d = node as? [String: Any] {
        visit(d)
        for v in d.values { walk(v, visit) }
    } else if let a = node as? [Any] {
        for v in a { walk(v, visit) }
    }
}

private func shippedWidget(_ id: String) -> [String: Any]? {
    var hit: [String: Any]?
    walk(shippedPanels()) { if $0["id"] as? String == id, hit == nil { hit = $0 } }
    return hit
}

@Test func theBrushLibrariesButtonRequestsAMenu() throws {
    let actions = try #require(WorkspaceData.load()).actions()
    let w = try #require(shippedWidget("bp_libraries_menu_btn"))
    #expect(WidgetEvent.clickRequestsMenu(w, actions: actions))
}

@Test func aButtonWhoseClickRequestsNoMenuCarriesNoAnchor() throws {
    let actions = try #require(WorkspaceData.load()).actions()
    let w = try #require(shippedWidget("bp_remove_brush_stroke_btn"))
    #expect(!WidgetEvent.clickRequestsMenu(w, actions: actions))
}

@Test func theRequestIsFoundInlineInABranchAndThroughANodeAction() {
    let actions: [String: Any] = [
        "pop": ["effects": [["open_menu": ["id": "m"]]]],
        "branchy": ["effects": [["if": ["condition": "true", "then": [["open_menu": "m"]]]]]],
        "quiet": ["effects": [["set": ["x": 1]]]],
    ]
    func btn(_ extra: [String: Any]) -> [String: Any] {
        ["id": "b", "type": "icon_button"].merging(extra) { $1 }
    }
    #expect(WidgetEvent.clickRequestsMenu(btn(["behavior": [["event": "click", "action": "pop"]]]), actions: actions))
    #expect(WidgetEvent.clickRequestsMenu(btn(["behavior": [["event": "click", "action": "branchy"]]]), actions: actions))
    #expect(WidgetEvent.clickRequestsMenu(btn(["behavior": [["event": "click", "effects": [["open_menu": "m"]]]]]), actions: actions))
    #expect(WidgetEvent.clickRequestsMenu(btn(["action": "pop"]), actions: actions))
    #expect(!WidgetEvent.clickRequestsMenu(btn(["behavior": [["event": "click", "action": "quiet"]]]), actions: actions))
    // A declared click behavior IS the click: the node action does not run.
    #expect(!WidgetEvent.clickRequestsMenu(btn(["action": "pop", "behavior": [["event": "click", "action": "quiet"]]]),
                                           actions: actions))
    // Not a click kind: a menu its other events request is not this rule's.
    #expect(!WidgetEvent.clickRequestsMenu(["id": "t", "type": "text", "behavior": [["event": "click", "action": "pop"]]],
                                           actions: actions))
    // An unknown action requests nothing, rather than crashing.
    #expect(!WidgetEvent.clickRequestsMenu(btn(["behavior": [["event": "click", "action": "nope"]]]), actions: actions))
}

/// The census, on a second axis: the actions whose serialised effects carry
/// the text `"open_menu"`, and the click-kind widgets that name one. Every
/// such widget must carry an anchor, and the population must not be empty.
@Test func everyShippedWidgetWhoseClickNamesAnOpenMenuActionCarriesAnAnchor() throws {
    let actions = try #require(WorkspaceData.load()).actions()
    let menuActions = Set(actions.compactMap { name, spec -> String? in
        guard let data = try? JSONSerialization.data(withJSONObject: spec),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.contains("\"open_menu\"") ? name : nil
    })
    #expect(menuActions.contains("open_brush_libraries_menu"), "\(menuActions.sorted())")
    var named: [String] = []
    var missed: [String] = []
    walk(shippedPanels()) { node in
        guard let kind = node["type"] as? String, WidgetEvent.clickKinds.contains(kind) else { return }
        let behaviors = (node["behavior"] as? [[String: Any]]) ?? []
        let clickActions = behaviors.filter { ($0["event"] as? String) == "click" }.compactMap { $0["action"] as? String }
        guard clickActions.contains(where: menuActions.contains) else { return }
        let id = node["id"] as? String ?? "?"
        named.append(id)
        if !WidgetEvent.clickRequestsMenu(node, actions: actions) { missed.append(id) }
    }
    #expect(named.contains("bp_libraries_menu_btn"), "\(named)")
    #expect(missed.isEmpty, "click-kind widgets naming an open_menu action with no anchor: \(missed)")
}

/// The link row 282 left UNMEASURED: the app's click route, on the shipped
/// button, records the request in the store the view reads.
@Test func clickingTheShippedButtonRecordsTheMenuRequest() throws {
    let model = Model()
    let w = try #require(shippedWidget("bp_libraries_menu_btn"))
    let route = PanelWidgetEvents(model: model, panelId: "brushes_panel_content")
    let result = route.click(w)
    #expect(result.outcome == "committed", "\(result)")
    #expect(model.stateStore.pendingMenu == "bp_menu_open_library")
    #expect(panelMenuRequest("bp_menu_open_library") != nil)
}
