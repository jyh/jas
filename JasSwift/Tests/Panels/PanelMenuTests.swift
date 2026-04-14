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
    #expect(PanelKind.all.count == 5)
}

@Test func panelKindAllContainsAllVariants() {
    #expect(PanelKind.all.contains(.layers))
    #expect(PanelKind.all.contains(.color))
    #expect(PanelKind.all.contains(.swatches))
    #expect(PanelKind.all.contains(.stroke))
    #expect(PanelKind.all.contains(.properties))
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
