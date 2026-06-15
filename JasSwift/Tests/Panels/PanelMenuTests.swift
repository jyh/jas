import Foundation
import Testing
@testable import JasLib

// ── Generic YAML menu builder ────────────────────────────────────
//
// These probe `menuItemsFromYaml` directly: the builder reads each
// panel's `menu:` block from the compiled bundle and maps it to
// PanelMenuItem (separator / checked->toggle / recurring-action->radio
// with folded params / else action). They mirror the Rust reference's
// panel_menu unit tests.

private func commands(_ items: [PanelMenuItem]) -> [String] {
    items.compactMap { item in
        switch item {
        case .action(_, let c, _), .toggle(_, let c), .radio(_, let c, _): return c
        case .separator: return nil
        }
    }
}

@Test func builderReadsBooleanPanel() {
    let items = menuItemsFromYaml("boolean_panel_content")
    let cmds = commands(items)
    #expect(cmds.contains("make_compound_shape"))
    #expect(cmds.contains("close_panel"))
    let seps = items.filter { if case .separator = $0 { return true }; return false }.count
    #expect(seps == 3)
    #expect(items.count == 10)
}

@Test func builderFoldsColorRadioParamsIntoCommand() {
    // The Color panel's five mode rows share `action: set_color_panel_mode`,
    // so the builder treats them as a radio group and folds each
    // `params.mode` value into the command.
    let items = menuItemsFromYaml("color_panel_content")
    var radios: [(String, String)] = []
    for item in items {
        if case .radio(_, let cmd, let group) = item { radios.append((cmd, group)) }
    }
    #expect(radios.contains { $0 == ("set_color_panel_mode:grayscale", "set_color_panel_mode") })
    #expect(radios.contains { $0 == ("set_color_panel_mode:rgb", "set_color_panel_mode") })
    #expect(radios.contains { $0 == ("set_color_panel_mode:web_safe_rgb", "set_color_panel_mode") })
    // Plain actions keep their action verbatim (no param folding).
    #expect(commands(items).contains("invert_active_color"))
    // close_panel keeps its action even though the YAML carries
    // `params: { panel: color }`.
    #expect(commands(items).contains("close_panel"))
}

@Test func builderSwatchesSubmenuBecomesOpenLibraryAction() {
    // The dynamic "Open Swatch Library" submenu entry has an explicit
    // `action: open_swatch_library` in the YAML so the menu view's
    // submenu host fires.
    let items = menuItemsFromYaml("swatches_panel_content")
    let hasHost = items.contains { if case .action(_, "open_swatch_library", _) = $0 { return true }; return false }
    #expect(hasHost, "swatches menu should expose open_swatch_library host")
    // Thumbnail-size rows are a radio group with folded params.
    var radios: [String] = []
    for item in items { if case .radio(_, let cmd, _) = item { radios.append(cmd) } }
    #expect(radios.contains("set_swatch_thumbnail_size:small"))
    #expect(radios.contains("set_swatch_thumbnail_size:large"))
}

@Test func builderStandaloneCheckboxIsToggleNotRadio() {
    // The Align panel has a single `toggle_use_preview_bounds` checkbox;
    // its action does not recur, so it is a toggle, not a radio.
    let items = menuItemsFromYaml("align_panel_content")
    let isToggle = items.contains { if case .toggle(_, "toggle_use_preview_bounds") = $0 { return true }; return false }
    #expect(isToggle)
}

@Test func builderStrokeCapJoinAreRadioGroups() {
    let items = menuItemsFromYaml("stroke_panel_content")
    var radios: [String] = []
    for item in items { if case .radio(_, let cmd, _) = item { radios.append(cmd) } }
    #expect(radios.contains("set_stroke_cap:butt"))
    #expect(radios.contains("set_stroke_cap:round"))
    #expect(radios.contains("set_stroke_join:miter"))
    #expect(radios.contains("set_stroke_join:bevel"))
    #expect(commands(items).contains("close_panel"))
}

@Test func panelLabelMatchesAllKinds() {
    #expect(panelLabel(.layers) == "Layers")
    #expect(panelLabel(.color) == "Color")
    #expect(panelLabel(.swatches) == "Swatches")
    #expect(panelLabel(.stroke) == "Stroke")
    #expect(panelLabel(.properties) == "Object properties")
}

@Test func panelKindAllCount() {
    #expect(PanelKind.all.count == 12)
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
    #expect(PanelKind.all.contains(.align))
    #expect(PanelKind.all.contains(.boolean))
    #expect(PanelKind.all.contains(.opacity))
    #expect(PanelKind.all.contains(.magicWand))
}

@Test func alignPanelMenuHasExpectedEntries() {
    let items = panelMenu(.align)
    // Three entries plus two separators per ALIGN.md Panel menu.
    #expect(items.count == 5)
    guard case .toggle(_, let togCmd) = items[0] else {
        Issue.record("first item should be a toggle")
        return
    }
    #expect(togCmd == "toggle_use_preview_bounds")
    if case .separator = items[1] {} else {
        Issue.record("second item should be a separator")
    }
    guard case .action(_, let resetCmd, _) = items[2] else {
        Issue.record("third item should be an action")
        return
    }
    #expect(resetCmd == "reset_align_panel")
    if case .separator = items[3] {} else {
        Issue.record("fourth item should be a separator")
    }
    guard case .action(let closeLabel, let closeCmd, _) = items[4] else {
        Issue.record("fifth item should be an action")
        return
    }
    #expect(closeCmd == "close_panel")
    #expect(closeLabel == "Close Align")
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

@Test func pushRecentColorMoveToFront() {
    let m = Model()
    m.recentColors = []
    ColorPanel.pushRecentColor("#ff0000", model: m)
    #expect(m.recentColors == ["#ff0000"])
    ColorPanel.pushRecentColor("#00ff00", model: m)
    #expect(m.recentColors == ["#00ff00", "#ff0000"])
    ColorPanel.pushRecentColor("#ff0000", model: m)  // dedup, move to front
    #expect(m.recentColors == ["#ff0000", "#00ff00"])
}

@Test func pushRecentColorCapsAtTen() {
    let m = Model()
    m.recentColors = []
    for i in 0..<15 {
        ColorPanel.pushRecentColor(String(format: "#0000%02x", i), model: m)
    }
    #expect(m.recentColors.count == 10)
    #expect(m.recentColors[0] == "#00000e")
}

@Test func pushRecentColorListenerFires() {
    // Use a sentinel hex unlikely to collide with other parallel tests.
    let sentinel = "#abcdef"
    let m = Model()
    m.recentColors = []
    let box = NSMutableArray()  // reference type so the closure mutates a shared array
    ColorPanel.addRecentColorsListener { _, hex in
        if hex == sentinel { box.add(hex) }
    }
    ColorPanel.pushRecentColor(sentinel, model: m)
    #expect(box.count >= 1)
}
