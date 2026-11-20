/// Opacity panel menu definition.
///
/// Phase-1 scope: handle the four panel-local toggle commands
/// (`toggle_opacity_thumbnails`, `toggle_opacity_options`,
/// `toggle_new_masks_clipping`, `toggle_new_masks_inverted`). The
/// mask-lifecycle and page-level menu items are declared in the YAML
/// (`workspace/panels/opacity.yaml`) with `enabled_when: "false"`, so they
/// remain inert until later phases add document-model fields and renderer
/// support. `blend_mode` and `opacity` working values are driven by the
/// panel controls (MODE_DROPDOWN, OPACITY_INPUT) via the interpreter's
/// widget-onchange path, not through this dispatch.
///
/// Mirrors `jas_dioxus/src/panels/opacity_panel.rs`.

/// Panel-local state for the Opacity panel. Mirrors the state block in
/// `workspace/panels/opacity.yaml`. `blendMode` and `opacity` are working
/// values shown in the panel controls; later phases synchronize them with
/// the selection's `element.blendMode` / `element.opacity`. The
/// `newMasks*` fields are document preferences used when creating new
/// masks (Phase 1 stores them on the panel state).
///
/// Named `blendMode` rather than `mode` to avoid a collision with the
/// Color panel's `mode` key in the shared live-overrides map.
public struct OpacityPanelState: Equatable {
    public var blendMode: BlendMode
    public var opacity: Double
    public var thumbnailsHidden: Bool
    public var optionsShown: Bool
    public var newMasksClipping: Bool
    public var newMasksInverted: Bool

    public init(
        blendMode: BlendMode = .normal,
        opacity: Double = 100.0,
        thumbnailsHidden: Bool = false,
        optionsShown: Bool = false,
        newMasksClipping: Bool = true,
        newMasksInverted: Bool = false
    ) {
        self.blendMode = blendMode
        self.opacity = opacity
        self.thumbnailsHidden = thumbnailsHidden
        self.optionsShown = optionsShown
        self.newMasksClipping = newMasksClipping
        self.newMasksInverted = newMasksInverted
    }
}

public enum OpacityPanel {

    /// Menu items for the Opacity panel.
    ///
    /// Source of truth is workspace/panels/opacity.yaml's `menu:` block
    /// (review #15); the generic reader builds the items from the bundle.
    /// The four panel-local toggles carry `checked_when` and so surface
    /// as toggles; the page-level rows
    /// (`toggle_page_isolated_blending` / `toggle_page_knockout_group`)
    /// carry no `checked` and so surface as actions (they are inert in
    /// Phase 1 — the dispatcher's default branch).
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("opacity_panel_content")
    }

    /// Dispatch a menu command: Close is the layout's, and every other row
    /// runs its actions.yaml entry in the panel's scope, as the engine and the
    /// web do (row 174). This app keeps the four panel-local keys on the
    /// LAYOUT (``opacityHeldPanelState``) while the action reads and writes
    /// the store, so the layout's values are laid over the store before the
    /// row runs and the store's are copied back after. Without a model there
    /// is no store to run in, and nothing happens.
    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout, model: Model? = nil) {
        if cmd == "close_panel" {
            layoutApply(&layout, opClosePanel(addr))
            return
        }
        guard let model = model else { return }
        let pid = "opacity_panel_content"
        let store = model.stateStore
        if !store.hasPanel(pid) {
            store.initPanel(pid, defaults: WorkspaceData.load()?.panelStateDefaults(pid) ?? [:])
        }
        for (k, v) in opacityHeldPanelState(layout.opacityPanel) { store.setPanel(pid, k, v) }
        panelDispatchRow(.opacity, action: cmd, params: [:], model: model)
        let flag = { (k: String, old: Bool) in (store.getPanel(pid, k) as? Bool) ?? old }
        layout.opacityPanel.thumbnailsHidden = flag("thumbnails_hidden", layout.opacityPanel.thumbnailsHidden)
        layout.opacityPanel.optionsShown = flag("options_shown", layout.opacityPanel.optionsShown)
        layout.opacityPanel.newMasksClipping = flag("new_masks_clipping", layout.opacityPanel.newMasksClipping)
        layout.opacityPanel.newMasksInverted = flag("new_masks_inverted", layout.opacityPanel.newMasksInverted)
    }
}
