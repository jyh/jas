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
    public static let label = "Opacity"

    /// Menu items for the Opacity panel. Ten spec items (from OPACITY.md)
    /// plus a trailing "Close Opacity" action. Three separators divide
    /// the spec groups; a fourth precedes Close.
    public static func menuItems() -> [PanelMenuItem] {
        [
            .toggle(label: "Hide Thumbnails", command: "toggle_opacity_thumbnails"),
            .toggle(label: "Show Options", command: "toggle_opacity_options"),
            .separator,
            .action(label: "Make Opacity Mask", command: "make_opacity_mask"),
            .action(label: "Release Opacity Mask", command: "release_opacity_mask"),
            .action(label: "Disable Opacity Mask", command: "disable_opacity_mask"),
            .action(label: "Unlink Opacity Mask", command: "unlink_opacity_mask"),
            .separator,
            .toggle(label: "New Opacity Masks Are Clipping", command: "toggle_new_masks_clipping"),
            .toggle(label: "New Opacity Masks Are Inverted", command: "toggle_new_masks_inverted"),
            .separator,
            .toggle(label: "Page Isolated Blending", command: "toggle_page_isolated_blending"),
            .toggle(label: "Page Knockout Group", command: "toggle_page_knockout_group"),
            .separator,
            .action(label: "Close Opacity", command: "close_panel"),
        ]
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
        default:
            // Mask-lifecycle and page-level commands are Phase-1 inert.
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
