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

    /// Dispatch a menu command. Phase-1 toggles flip panel-local state;
    /// mask-lifecycle and page-level commands are inert (YAML gates them
    /// via `enabled_when: "false"`).
    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout, model: Model? = nil) {
        switch cmd {
        case "close_panel":
            layout.closePanel(addr)
        case "toggle_opacity_thumbnails":
            layout.opacityPanel.thumbnailsHidden.toggle()
        case "toggle_opacity_options":
            layout.opacityPanel.optionsShown.toggle()
        case "toggle_new_masks_clipping":
            layout.opacityPanel.newMasksClipping.toggle()
        case "toggle_new_masks_inverted":
            layout.opacityPanel.newMasksInverted.toggle()
        // Mask-lifecycle commands route to the document controller.
        case "make_opacity_mask":
            guard let model = model else { break }
            let ctrl = Controller(model: model)
            ctrl.makeMaskOnSelection(
                clip: layout.opacityPanel.newMasksClipping,
                invert: layout.opacityPanel.newMasksInverted)
        case "release_opacity_mask":
            guard let model = model else { break }
            Controller(model: model).releaseMaskOnSelection()
        case "disable_opacity_mask":
            guard let model = model else { break }
            Controller(model: model).toggleMaskDisabledOnSelection()
        case "unlink_opacity_mask":
            guard let model = model else { break }
            Controller(model: model).toggleMaskLinkedOnSelection()
        default:
            // Page-level blending commands remain deferred.
            break
        }
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        switch cmd {
        case "toggle_opacity_thumbnails": return layout.opacityPanel.thumbnailsHidden
        case "toggle_opacity_options":    return layout.opacityPanel.optionsShown
        case "toggle_new_masks_clipping": return layout.opacityPanel.newMasksClipping
        case "toggle_new_masks_inverted": return layout.opacityPanel.newMasksInverted
        default: return false
        }
    }
}
