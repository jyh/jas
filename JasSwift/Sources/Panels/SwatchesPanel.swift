import Foundation

/// Swatches panel menu definition.
///
/// Mirrors `workspace/panels/swatches.yaml`'s `menu:` section. Each
/// entry maps to a YAML action (in `actions.yaml`) which is dispatched
/// through `runYamlActionByName` — the shared effects pipeline opens
/// dialogs, writes panel state, etc. The Swift menu hardcodes the
/// labels and the params (e.g. {size: small}) because PanelMenuItem
/// can't carry arbitrary param maps yet; per-variant commands keep
/// the wiring contained until that refactor lands.

public enum SwatchesPanel {
    public static func menuItems() -> [PanelMenuItem] {
        [
            .action(label: "New Swatch", command: "new_swatch"),
            .action(label: "Duplicate Swatch", command: "duplicate_swatch"),
            .action(label: "Delete Swatch", command: "delete_swatch"),
            .separator,
            .action(label: "Select All Unused", command: "select_all_unused_swatches"),
            .action(label: "Add Used Colors", command: "add_used_colors"),
            .separator,
            .action(label: "Sort by Name", command: "sort_swatches_by_name"),
            .separator,
            .radio(label: "Small Thumbnail View", command: "thumb_size_small", group: "thumbnail_size"),
            .radio(label: "Medium Thumbnail View", command: "thumb_size_medium", group: "thumbnail_size"),
            .radio(label: "Large Thumbnail View", command: "thumb_size_large", group: "thumbnail_size"),
            .separator,
            .action(label: "Swatch Options...", command: "open_swatch_options_menu"),
            .separator,
            .action(label: "Save Swatch Library", command: "save_swatch_library"),
            .separator,
            .action(label: "Close Swatches", command: "close_panel"),
        ]
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout, model: Model? = nil) {
        if cmd == "close_panel" { layout.closePanel(addr); return }
        guard let model = model else { return }
        switch cmd {
        case "thumb_size_small":
            runYamlActionByName("set_swatch_thumbnail_size", params: ["size": "small"], model: model)
        case "thumb_size_medium":
            runYamlActionByName("set_swatch_thumbnail_size", params: ["size": "medium"], model: model)
        case "thumb_size_large":
            runYamlActionByName("set_swatch_thumbnail_size", params: ["size": "large"], model: model)
        case "open_swatch_options_menu":
            // The menu variant edits the first selected swatch.
            // Without a selection it would be a no-op in the YAML
            // (`enabled_when: panel.selected_swatches.length > 0`),
            // so we just pass mode=edit and let the dialog read the
            // selection from panel state.
            runYamlActionByName("open_swatch_options", params: ["mode": "edit"], model: model)
        default:
            runYamlActionByName(cmd, params: [:], model: model)
        }
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }

    /// Same as ``isChecked`` but with the model in scope so radio
    /// buttons that mirror panel state (thumbnail_size) can read it.
    /// Used by the hamburger menu's checkmark logic; the
    /// model-less ``isChecked`` is kept for legacy call sites.
    public static func isCheckedWithModel(_ cmd: String, model: Model?) -> Bool {
        guard let model = model else { return false }
        let store = model.stateStore
        let size = (store.getPanel("swatches_panel_content", "thumbnail_size") as? String) ?? "small"
        switch cmd {
        case "thumb_size_small": return size == "small"
        case "thumb_size_medium": return size == "medium"
        case "thumb_size_large": return size == "large"
        default: return false
        }
    }
}

/// Run a YAML-defined action by name, looking up its effects in the
/// workspace actions catalog and dispatching them through the shared
/// pipeline. Sets the active panel id so panel-scoped writes (and
/// dialog opens) target the right state container. Uses the same
/// platform-effects registry as canvas-button clicks
/// (`alignPlatformEffects`, which despite the name covers Align,
/// Boolean, snapshot, etc.) so menu-driven actions take the same
/// `- snapshot` and platform-op steps a button click would — without
/// this, hamburger-menu "Make Compound Shape" mutated the doc but
/// never pushed an undo entry.
public func runYamlActionByName(_ name: String, params: [String: Any], model: Model) {
    guard let ws = WorkspaceData.load() else { return }
    let actions = ws.data["actions"] as? [String: Any]
    guard let actionDef = actions?[name] as? [String: Any],
          let effects = actionDef["effects"] as? [Any] else { return }
    let store = model.stateStore
    var ctx: [String: Any] = ws.stateDefaults()
    ctx["param"] = params
    let dialogs = ws.data["dialogs"] as? [String: Any]
    let platformEffects = alignPlatformEffects(model: model)
    runEffects(effects, ctx: ctx, store: store,
               actions: actions, dialogs: dialogs,
               platformEffects: platformEffects)
    model.panelStateVersion &+= 1
}
