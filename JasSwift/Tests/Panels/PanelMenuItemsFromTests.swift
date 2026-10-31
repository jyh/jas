import Foundation
import Testing
@testable import JasLib

// A panel-menu entry that declares `items_from` (the 2026-10-28 jas
// brush-library design, A.2) is a SUBMENU whose rows are evaluated when the
// menu opens, in the panel menu's own context, and whose selected row runs its
// action with its evaluated params. The row evaluation itself is
// `MenuState.itemsFromEntries` (MenuItemsFromTests); these pin the menu's use
// of it.

private let libsSpec: [String: Any] = [
    "source": "keys(data.brush_libraries)",
    "as": "lib",
    "item": [
        "label": "{{data.brush_libraries[lib].name}}",
        "action": "set_brush_view_mode",
        "params": ["view_mode": "lib"],
    ] as [String: Any],
]

@Test func anItemsFromEntryBuildsASubmenuCarryingItsSpec() {
    let raw: [Any] = [
        ["label": "Open Brush Library", "type": "submenu", "dynamic": true, "items_from": libsSpec],
        "separator",
        ["label": "Close", "action": "close_panel"],
    ]
    let items = menuItems(fromRaw: raw)
    #expect(items.count == 3)
    guard case .submenu(let label, let spec) = items[0] else {
        Issue.record("an items_from entry must be a .submenu, got \(items[0])"); return
    }
    #expect(label == "Open Brush Library")
    #expect(spec["source"] as? String == "keys(data.brush_libraries)")
    #expect(spec["as"] as? String == "lib")
}

@Test func aSubmenuEntryWithoutItemsFromStaysADisabledAction() {
    // Today's brushes.yaml row: `type: submenu`, `dynamic: true`, no action.
    let items = menuItems(fromRaw: [["label": "Open Brush Library", "type": "submenu", "dynamic": true]])
    guard case .action(let label, let command, _) = items[0] else {
        Issue.record("got \(items[0])"); return
    }
    #expect(label == "Open Brush Library")
    #expect(command == "")
}

@Test func thePanelMenuContextCarriesTheDataNamespaceFromTheStore() {
    let model = Model()
    let ctx = panelMenuContext("brushes_panel_content", layout: WorkspaceLayout.defaultLayout(), model: model)
    let stored = (model.stateStore.getDataPath("brush_libraries") as? [String: Any]) ?? [:]
    #expect(!stored.isEmpty, "precondition: the store is seeded with the bundle's libraries")
    let data = ctx["data"] as? [String: Any]
    let libs = data?["brush_libraries"] as? [String: Any]
    #expect(libs.map { Set($0.keys) } == Set(stored.keys))
}

@Test func theContextReadsTheStoreNotTheBundle() {
    let model = Model()
    model.stateStore.setDataPath("brush_libraries.zz_user_lib", ["name": "ZZ User", "brushes": [Any]()])
    let ctx = panelMenuContext("brushes_panel_content", layout: WorkspaceLayout.defaultLayout(), model: model)
    let libs = (ctx["data"] as? [String: Any])?["brush_libraries"] as? [String: Any]
    #expect(libs?["zz_user_lib"] != nil, "a library added to the store at run time is listed")
}

@Test func submenuRowsAreEvaluatedInThePanelContextInKeyOrder() {
    let model = Model()
    // A second library, named to sort FIRST, so the order is a claim: the
    // bundle seeds only one.
    model.stateStore.setDataPath("brush_libraries.aa_user_lib", ["name": "AA User", "brushes": [Any]()])
    let stored = (model.stateStore.getDataPath("brush_libraries") as? [String: Any]) ?? [:]
    #expect(stored.count >= 2, "precondition: two libraries, or the order is not tested")
    let rows = panelSubmenuRows(.brushes, spec: libsSpec, layout: WorkspaceLayout.defaultLayout(), model: model)
    #expect(rows.map { $0.params["view_mode"] as? String } == stored.keys.sorted().map { Optional($0) })
    #expect(rows.first?.label == "AA User")
}

@Test func aSubmenuRowDispatchesItsActionWithItsParams() {
    let model = Model()
    var layout = WorkspaceLayout.defaultLayout()
    let addr = PanelAddr(group: GroupAddr(dockId: layout.anchoredDock(.right)!.id, groupIdx: 0), panelIdx: 0)
    panelDispatchRow(.brushes, action: "set_brush_view_mode", params: ["view_mode": "list"],
                     addr: addr, layout: &layout, model: model)
    #expect(model.stateStore.getPanel("brushes_panel_content", "view_mode") as? String == "list")
    panelDispatchRow(.brushes, action: "set_brush_view_mode", params: ["view_mode": "thumbnail"],
                     addr: addr, layout: &layout, model: model)
    #expect(model.stateStore.getPanel("brushes_panel_content", "view_mode") as? String == "thumbnail",
            "both directions: a radio driven one way only can pass by accident")
}

@Test func aSubmenuRowWithNoActionDispatchesNothing() {
    let model = Model()
    var layout = WorkspaceLayout.defaultLayout()
    let addr = PanelAddr(group: GroupAddr(dockId: layout.anchoredDock(.right)!.id, groupIdx: 0), panelIdx: 0)
    let before = model.stateStore.getPanel("brushes_panel_content", "view_mode") as? String
    panelDispatchRow(.brushes, action: "", params: ["view_mode": "list"], addr: addr, layout: &layout, model: model)
    #expect(model.stateStore.getPanel("brushes_panel_content", "view_mode") as? String == before)
}
