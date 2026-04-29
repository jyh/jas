import Testing
@testable import JasLib

// Tests for the recent-colors bridge installed by WorkspaceState that
// mirrors model.recentColors into the YAML panel.recent_colors state
// of every panel that has seeded a recent_colors slot. Mirrors the
// Python jas _setup_recent_colors_bridge.

@Test func bridgeMirrorsPushIntoBothPanelsWhenSeeded() {
    WorkspaceState.installRecentColorsBridge()

    let model = Model()
    model.recentColors = []
    model.stateStore.initPanel("color_panel_content",
                               defaults: ["recent_colors": [String]()])
    model.stateStore.initPanel("swatches_panel_content",
                               defaults: ["recent_colors": [String]()])

    let sentinel = "#a1b2c3"
    ColorPanel.pushRecentColor(sentinel, model: model)

    let cp = model.stateStore.getPanel("color_panel_content", "recent_colors") as? [String]
    let sp = model.stateStore.getPanel("swatches_panel_content", "recent_colors") as? [String]
    #expect(cp?.first == sentinel)
    #expect(sp?.first == sentinel)
}

@Test func bridgeSkipsPanelsWithoutSeededRecentColors() {
    WorkspaceState.installRecentColorsBridge()

    let model = Model()
    model.recentColors = []
    // Only seed Color panel; Swatches panel is intentionally not init'd.
    model.stateStore.initPanel("color_panel_content",
                               defaults: ["recent_colors": [String]()])

    let sentinel = "#d4e5f6"
    ColorPanel.pushRecentColor(sentinel, model: model)

    let cp = model.stateStore.getPanel("color_panel_content", "recent_colors") as? [String]
    let sp = model.stateStore.getPanel("swatches_panel_content", "recent_colors")
    #expect(cp?.first == sentinel)
    // Swatches panel was not seeded, so the bridge skips it — no
    // creation of a recent_colors slot happens implicitly.
    #expect(sp == nil)
}

@Test func bridgeInstallIsIdempotent() {
    // Calling install multiple times should not register multiple
    // listeners (which would cause the mirror to fire N times per
    // push). Installs are guarded by a private flag.
    WorkspaceState.installRecentColorsBridge()
    WorkspaceState.installRecentColorsBridge()
    WorkspaceState.installRecentColorsBridge()

    let model = Model()
    model.recentColors = []
    model.stateStore.initPanel("color_panel_content",
                               defaults: ["recent_colors": [String]()])

    let sentinel = "#0f1e2d"
    ColorPanel.pushRecentColor(sentinel, model: model)

    // The mirrored state should be the same as a single push, not
    // duplicated entries from extra listener fires.
    let cp = model.stateStore.getPanel("color_panel_content", "recent_colors") as? [String]
    #expect(cp == model.recentColors)
}

@Test func bridgeMirrorReflectsMoveToFrontDedup() {
    // Push the same color twice. recentColors keeps a single entry
    // moved to the front; the mirrored panel state should match.
    WorkspaceState.installRecentColorsBridge()

    let model = Model()
    model.recentColors = []
    model.stateStore.initPanel("color_panel_content",
                               defaults: ["recent_colors": [String]()])

    ColorPanel.pushRecentColor("#aa0000", model: model)
    ColorPanel.pushRecentColor("#00aa00", model: model)
    ColorPanel.pushRecentColor("#aa0000", model: model)

    let cp = model.stateStore.getPanel("color_panel_content", "recent_colors") as? [String]
    #expect(cp == ["#aa0000", "#00aa00"])
    #expect(cp == model.recentColors)
}
