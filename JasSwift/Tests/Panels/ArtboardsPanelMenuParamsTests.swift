import Testing
import Foundation
@testable import JasLib

/// Row 280: a non-radio panel-menu item is dispatched by its bare action, so
/// its declared `params` were never evaluated, and Artboards' "Artboard
/// Options..." opened the dialog bound to no artboard (OK then wrote nothing).
/// The app's own route: the menu builder's command through ``panelDispatch``.
private func artboardsModel() throws -> Model {
    let path = ((#filePath as NSString).deletingLastPathComponent as NSString)
        .appendingPathComponent("../../../test_fixtures/svg/paragraph_justified.svg")
    let m = Model(document: svgToDocument(try String(contentsOfFile: (path as NSString).standardizingPath, encoding: .utf8)))
    m.stateStore.initPanel("artboards_panel_content",
                           defaults: WorkspaceData.load()!.panelStateDefaults("artboards_panel_content"))
    m.stateStore.setPanel("artboards_panel_content", "artboards_panel_selection", ["zs8ap4x3"])
    return m
}

private func liveCommand(_ action: String) -> String {
    for item in menuItemsFromYaml("artboards_panel_content") {
        switch item {
        case .action(_, let c, _) where c.hasPrefix(action): return c
        default: continue
        }
    }
    return "<no item \(action)>"
}

@Test func theArtboardsMenuOpensArtboardOptionsOnThePanelSelectedArtboard() throws {
    let m = try artboardsModel()
    var layout = WorkspaceLayout.defaultLayout()
    panelDispatch(.artboards, cmd: liveCommand("open_artboard_options"),
                  addr: PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0), layout: &layout, model: m)
    #expect(m.stateStore.getDialogId() == "artboard_options")
    #expect(m.stateStore.getDialogParams()?["artboard_id"] as? String == "zs8ap4x3",
            "\(m.stateStore.getDialogParams() ?? [:])")
}

/// The control: with nothing panel-selected the item's own `enabled_when`
/// is false, so a person cannot pick it; dispatched anyway it binds nothing.
@Test func withNoPanelSelectionTheItemBindsNoArtboard() throws {
    let m = try artboardsModel()
    m.stateStore.setPanel("artboards_panel_content", "artboards_panel_selection", [String]())
    var layout = WorkspaceLayout.defaultLayout()
    panelDispatch(.artboards, cmd: liveCommand("open_artboard_options"),
                  addr: PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0), layout: &layout, model: m)
    #expect(m.stateStore.getDialogParams()?["artboard_id"] as? String == nil, "\(m.stateStore.getDialogParams() ?? [:])")
}

/// The menu's other dead item: "Rename" begins renaming the panel-selected
/// artboard (`panel.renaming_artboard`), which reads its `artboard_id` param.
@Test func theArtboardsMenuRenameBeginsRenamingThePanelSelectedArtboard() throws {
    let m = try artboardsModel()
    var layout = WorkspaceLayout.defaultLayout()
    panelDispatch(.artboards, cmd: liveCommand("rename_artboard"),
                  addr: PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0), layout: &layout, model: m)
    #expect(m.stateStore.getPanel("artboards_panel_content", "renaming_artboard") as? String == "zs8ap4x3",
            "\(m.stateStore.getPanelState("artboards_panel_content"))")
}
