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
    /// Source of truth is workspace/panels/swatches.yaml's `menu:` block
    /// (review #15); the generic reader builds the items from the bundle.
    ///
    /// The three thumbnail-size rows share `action:
    /// set_swatch_thumbnail_size`, so the builder folds each `params.size`
    /// into the command (`set_swatch_thumbnail_size:small`, …) — `dispatch`
    /// / `isCheckedWithModel` split that suffix back off. The "Open Swatch
    /// Library" dynamic submenu carries an explicit `action:
    /// open_swatch_library` in the YAML; the menu view renders it as a
    /// plain item whose dispatch is the placeholder below until the
    /// library-load plumbing lands.
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("swatches_panel_content")
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout, model: Model? = nil) {
        if cmd == "close_panel" { layoutApply(&layout, opClosePanel(addr)); return }
        guard let model = model else { return }
        // Thumbnail-size radio arrives param-folded from the generic menu
        // builder (`set_swatch_thumbnail_size:small`); split the value
        // back off and run the underlying YAML action.
        if let size = strip(cmd, prefix: "set_swatch_thumbnail_size:") {
            runYamlActionByName("set_swatch_thumbnail_size", params: ["size": size], model: model)
            return
        }
        switch cmd {
        case "open_swatch_options":
            // The menu variant edits the first selected swatch. Without a
            // selection it is a no-op in the YAML
            // (`enabled_when: panel.selected_swatches.length > 0`), so we
            // pass mode=edit and let the dialog read the selection from
            // panel state.
            runYamlActionByName("open_swatch_options", params: ["mode": "edit"], model: model)
        case "open_swatch_library":
            // Dynamic library submenu host — placeholder until the
            // library-load plumbing lands (mirrors the Rust reference's
            // open_swatch_library no-op).
            break
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
        guard let size = strip(cmd, prefix: "set_swatch_thumbnail_size:") else {
            return false
        }
        let store = model.stateStore
        let current = (store.getPanel("swatches_panel_content", "thumbnail_size") as? String) ?? "small"
        return current == size
    }

    private static func strip(_ s: String, prefix: String) -> String? {
        s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : nil
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
