import Testing
@testable import JasLib

// ── OpacityPanelState defaults ───────────────────────────────

@Test func opacityPanelStateDefaultBlendModeIsNormal() {
    let s = OpacityPanelState()
    #expect(s.blendMode == .normal)
}

@Test func opacityPanelStateDefaultOpacityIs100() {
    let s = OpacityPanelState()
    #expect(s.opacity == 100.0)
}

@Test func opacityPanelStateDefaultTogglesAreFalse() {
    let s = OpacityPanelState()
    #expect(s.thumbnailsHidden == false)
    #expect(s.optionsShown == false)
}

@Test func opacityPanelStateDefaultNewMasksClippingTrue() {
    let s = OpacityPanelState()
    #expect(s.newMasksClipping == true)
}

@Test func opacityPanelStateDefaultNewMasksInvertedFalse() {
    let s = OpacityPanelState()
    #expect(s.newMasksInverted == false)
}

// ── Menu shape ───────────────────────────────────────────────

@Test func opacityPanelMenuHasSpecItemsPlusClose() {
    // Ten spec items (OPACITY.md panel menu) + Close Opacity = 11 non-separator
    // items. Three separators divide the spec groups; a fourth precedes Close.
    let items = OpacityPanel.menuItems()
    let seps = items.filter { if case .separator = $0 { return true }; return false }.count
    let others = items.count - seps
    #expect(seps == 4)
    #expect(others == 11)
}

@Test func opacityPanelMenuHasFourPanelLocalToggles() {
    let items = OpacityPanel.menuItems()
    var toggleCmds: [String] = []
    for item in items {
        if case .toggle(_, let cmd) = item {
            toggleCmds.append(cmd)
        }
    }
    #expect(toggleCmds.contains("toggle_opacity_thumbnails"))
    #expect(toggleCmds.contains("toggle_opacity_options"))
    #expect(toggleCmds.contains("toggle_new_masks_clipping"))
    #expect(toggleCmds.contains("toggle_new_masks_inverted"))
}

@Test func opacityPanelMenuHasFourMaskLifecycleActionsInOrder() {
    // The menu DATA now comes from workspace/panels/opacity.yaml
    // (review #15). A row with a `checked_when` is a toggle, so Page Isolated
    // Blending (checked from the document's flag since row 192) is a toggle,
    // and Page Knockout Group (no check expression; disabled until knockout is
    // built) is still an action between the mask-lifecycle group and
    // `close_panel`.
    let items = OpacityPanel.menuItems()
    var actionCmds: [String] = []
    var toggleCmds: [String] = []
    for item in items {
        if case .action(_, let cmd, _) = item {
            actionCmds.append(cmd)
        }
        if case .toggle(_, let cmd) = item {
            toggleCmds.append(cmd)
        }
    }
    #expect(actionCmds == [
        "make_opacity_mask",
        "release_opacity_mask",
        "disable_opacity_mask",
        "unlink_opacity_mask",
        "toggle_page_knockout_group",
        "close_panel",
    ])
    #expect(toggleCmds.contains("toggle_page_isolated_blending"), "\(toggleCmds)")
}

// ── Dispatch toggles panel-local state ───────────────────────

private func makeLayoutAndAddr() -> (WorkspaceLayout, PanelAddr) {
    var layout = WorkspaceLayout.defaultLayout()
    // First panel of the first group in the first anchored dock. Opacity
    // tests only need a valid addr; close_panel isn't called in these.
    let addr = PanelAddr(
        group: GroupAddr(dockId: layout.anchored[0].1.id, groupIdx: 0),
        panelIdx: 0
    )
    return (layout, addr)
}

@Test func opacityPanelDispatchToggleThumbnailsFlipsField() {
    var (layout, addr) = makeLayoutAndAddr()
    let m = Model()
    #expect(layout.opacityPanel.thumbnailsHidden == false)
    OpacityPanel.dispatch("toggle_opacity_thumbnails", addr: addr, layout: &layout, model: m)
    #expect(layout.opacityPanel.thumbnailsHidden == true)
    OpacityPanel.dispatch("toggle_opacity_thumbnails", addr: addr, layout: &layout, model: m)
    #expect(layout.opacityPanel.thumbnailsHidden == false)
}

@Test func opacityPanelPreferencesToggleWithNoDocumentOpen() {
    // With no document open the dock passes no model; the four panel-local
    // toggles are the layout's and still flip (the native route did).
    var (layout, addr) = makeLayoutAndAddr()
    OpacityPanel.dispatch("toggle_opacity_thumbnails", addr: addr, layout: &layout)
    OpacityPanel.dispatch("toggle_new_masks_clipping", addr: addr, layout: &layout)
    #expect(layout.opacityPanel.thumbnailsHidden == true)
    #expect(layout.opacityPanel.newMasksClipping == false)
}

@Test func opacityPanelDispatchToggleOptionsFlipsField() {
    var (layout, addr) = makeLayoutAndAddr()
    let m = Model()
    #expect(layout.opacityPanel.optionsShown == false)
    OpacityPanel.dispatch("toggle_opacity_options", addr: addr, layout: &layout, model: m)
    #expect(layout.opacityPanel.optionsShown == true)
}

@Test func opacityPanelDispatchToggleNewMasksClippingFlipsFromDefaultTrue() {
    var (layout, addr) = makeLayoutAndAddr()
    let m = Model()
    #expect(layout.opacityPanel.newMasksClipping == true)
    OpacityPanel.dispatch("toggle_new_masks_clipping", addr: addr, layout: &layout, model: m)
    #expect(layout.opacityPanel.newMasksClipping == false)
}

@Test func opacityPanelDispatchToggleNewMasksInvertedFlipsFromDefaultFalse() {
    var (layout, addr) = makeLayoutAndAddr()
    let m = Model()
    #expect(layout.opacityPanel.newMasksInverted == false)
    OpacityPanel.dispatch("toggle_new_masks_inverted", addr: addr, layout: &layout, model: m)
    #expect(layout.opacityPanel.newMasksInverted == true)
}

@Test func opacityPanelDispatchMaskLifecycleDoesNotTouchPanelState() {
    // Mask-lifecycle commands route to the Controller and operate on
    // the document; they must not mutate panel-local state (which
    // governs UI chrome).
    var (layout, addr) = makeLayoutAndAddr()
    let m = Model()
    let before = layout.opacityPanel
    OpacityPanel.dispatch("make_opacity_mask", addr: addr, layout: &layout, model: m)
    OpacityPanel.dispatch("release_opacity_mask", addr: addr, layout: &layout, model: m)
    OpacityPanel.dispatch("disable_opacity_mask", addr: addr, layout: &layout, model: m)
    OpacityPanel.dispatch("unlink_opacity_mask", addr: addr, layout: &layout, model: m)
    #expect(before == layout.opacityPanel)
}

// ── Integration: dispatch routes to Controller when model is passed ──

private func setupOneRectSelectionModel() -> Model {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [rect])
    let doc = Document(layers: [layer], selection: [
        ElementSelection.all([0, 0]),
    ])
    return Model(document: doc)
}

@Test func dispatchMakeOpacityMaskCreatesMaskOnSelection() {
    var (layout, addr) = makeLayoutAndAddr()
    let model = setupOneRectSelectionModel()
    OpacityPanel.dispatch("make_opacity_mask", addr: addr, layout: &layout, model: model)
    #expect(selectionHasMask(model.document) == true)
}

@Test func dispatchMakeUsesDocumentDefaultsForClipInvert() {
    var (layout, addr) = makeLayoutAndAddr()
    layout.opacityPanel.newMasksClipping = false
    layout.opacityPanel.newMasksInverted = true
    let model = setupOneRectSelectionModel()
    OpacityPanel.dispatch("make_opacity_mask", addr: addr, layout: &layout, model: model)
    let m = model.document.getElement([0, 0]).mask
    #expect(m?.clip == false)
    #expect(m?.invert == true)
}

@Test func dispatchReleaseClearsMaskOnSelection() {
    var (layout, addr) = makeLayoutAndAddr()
    let model = setupOneRectSelectionModel()
    OpacityPanel.dispatch("make_opacity_mask", addr: addr, layout: &layout, model: model)
    OpacityPanel.dispatch("release_opacity_mask", addr: addr, layout: &layout, model: model)
    #expect(selectionHasMask(model.document) == false)
}

@Test func dispatchDisableAndUnlinkToggleMaskFields() {
    var (layout, addr) = makeLayoutAndAddr()
    let model = setupOneRectSelectionModel()
    OpacityPanel.dispatch("make_opacity_mask", addr: addr, layout: &layout, model: model)
    OpacityPanel.dispatch("disable_opacity_mask", addr: addr, layout: &layout, model: model)
    #expect(model.document.getElement([0, 0]).mask?.disabled == true)
    OpacityPanel.dispatch("unlink_opacity_mask", addr: addr, layout: &layout, model: model)
    #expect(model.document.getElement([0, 0]).mask?.linked == false)
}

// ── isChecked ────────────────────────────────────────────────

@Test func opacityPanelIsCheckedReflectsPanelState() {
    var layout = WorkspaceLayout.defaultLayout()
    #expect(panelIsChecked(.opacity, cmd: "toggle_opacity_thumbnails", layout: layout) == false)
    #expect(panelIsChecked(.opacity, cmd: "toggle_new_masks_clipping", layout: layout) == true)
    layout.opacityPanel.thumbnailsHidden = true
    layout.opacityPanel.newMasksClipping = false
    #expect(panelIsChecked(.opacity, cmd: "toggle_opacity_thumbnails", layout: layout) == true)
    #expect(panelIsChecked(.opacity, cmd: "toggle_new_masks_clipping", layout: layout) == false)
}

@Test func opacityPanelIsCheckedReturnsFalseForUnknownCommand() {
    let layout = WorkspaceLayout.defaultLayout()
    #expect(panelIsChecked(.opacity, cmd: "nonexistent", layout: layout) == false)
    #expect(panelIsChecked(.opacity, cmd: "make_opacity_mask", layout: layout) == false)
}
