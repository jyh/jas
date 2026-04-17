import Testing
@testable import JasLib

@Test func panelLabelMatchesAllKinds() {
    #expect(panelLabel(.layers) == "Layers")
    #expect(panelLabel(.color) == "Color")
    #expect(panelLabel(.swatches) == "Swatches")
    #expect(panelLabel(.stroke) == "Stroke")
    #expect(panelLabel(.properties) == "Properties")
}

@Test func panelKindAllCount() {
    #expect(PanelKind.all.count == 8)
}

@Test func panelKindAllContainsAllVariants() {
    #expect(PanelKind.all.contains(.layers))
    #expect(PanelKind.all.contains(.color))
    #expect(PanelKind.all.contains(.swatches))
    #expect(PanelKind.all.contains(.stroke))
    #expect(PanelKind.all.contains(.properties))
    #expect(PanelKind.all.contains(.character))
    #expect(PanelKind.all.contains(.paragraph))
    #expect(PanelKind.all.contains(.artboards))
}

@Test func panelMenuNonEmptyForAllKinds() {
    for kind in PanelKind.all {
        let items = panelMenu(kind)
        #expect(!items.isEmpty, "Menu for \(kind) is empty")
    }
}

@Test func everyPanelHasCloseAction() {
    for kind in PanelKind.all {
        let items = panelMenu(kind)
        let hasClose = items.contains { item in
            if case .action(_, let cmd, _) = item { return cmd == "close_panel" }
            return false
        }
        #expect(hasClose, "Menu for \(kind) missing close_panel action")
    }
}

@Test func closeLabelMatchesPanelName() {
    for kind in PanelKind.all {
        let items = panelMenu(kind)
        let closeItem = items.first { item in
            if case .action(_, let cmd, _) = item { return cmd == "close_panel" }
            return false
        }
        if case .action(let label, _, _) = closeItem {
            #expect(label == "Close \(panelLabel(kind))",
                    "Close label mismatch for \(kind)")
        }
    }
}

@Test func panelDispatchCloseRemovesPanel() {
    var layout = WorkspaceLayout.defaultLayout()
    let dockId = layout.anchoredDock(.right)!.id
    // Color is at group 0, panel index 0
    let addr = PanelAddr(group: GroupAddr(dockId: dockId, groupIdx: 0), panelIdx: 0)
    #expect(layout.isPanelVisible(.color))
    panelDispatch(.color, cmd: "close_panel", addr: addr, layout: &layout)
    #expect(!layout.isPanelVisible(.color))
}

@Test func panelIsCheckedDefaultsFalse() {
    let layout = WorkspaceLayout.defaultLayout()
    for kind in PanelKind.all {
        #expect(!panelIsChecked(kind, cmd: "anything", layout: layout))
    }
}

@Test func layersMenuHasNewLayer() {
    let items = panelMenu(.layers)
    let has = items.contains { if case .action(_, "new_layer", _) = $0 { return true }; return false }
    #expect(has, "Layers menu missing new_layer")
}

@Test func layersMenuHasNewGroup() {
    let items = panelMenu(.layers)
    let has = items.contains { if case .action(_, "new_group", _) = $0 { return true }; return false }
    #expect(has, "Layers menu missing new_group")
}

@Test func layersMenuHasVisibilityToggles() {
    let items = panelMenu(.layers)
    for cmd in ["toggle_all_layers_visibility", "toggle_all_layers_outline", "toggle_all_layers_lock"] {
        let has = items.contains { if case .action(_, let c, _) = $0 { return c == cmd }; return false }
        #expect(has, "Layers menu missing \(cmd)")
    }
}

@Test func layersMenuHasIsolationMode() {
    let items = panelMenu(.layers)
    for cmd in ["enter_isolation_mode", "exit_isolation_mode"] {
        let has = items.contains { if case .action(_, let c, _) = $0 { return c == cmd }; return false }
        #expect(has, "Layers menu missing \(cmd)")
    }
}

@Test func layersMenuHasFlattenAndCollect() {
    let items = panelMenu(.layers)
    for cmd in ["flatten_artwork", "collect_in_new_layer"] {
        let has = items.contains { if case .action(_, let c, _) = $0 { return c == cmd }; return false }
        #expect(has, "Layers menu missing \(cmd)")
    }
}

@Test func layersDispatchTier3NoError() {
    var layout = WorkspaceLayout.defaultLayout()
    let dockId = layout.anchoredDock(.right)!.id
    let addr = PanelAddr(group: GroupAddr(dockId: dockId, groupIdx: 2), panelIdx: 0)
    for cmd in ["new_layer", "new_group", "toggle_all_layers_visibility",
                "toggle_all_layers_outline", "toggle_all_layers_lock",
                "enter_isolation_mode", "exit_isolation_mode",
                "flatten_artwork", "collect_in_new_layer"] {
        panelDispatch(.layers, cmd: cmd, addr: addr, layout: &layout)
    }
}
