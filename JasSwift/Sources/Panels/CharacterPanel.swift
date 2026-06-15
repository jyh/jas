/// Character panel menu definition.
///
/// Mirrors the item list in `CHARACTER.md` and matches the Rust
/// `character_panel.rs` module. The four toggle commands (All Caps,
/// Small Caps, Superscript, Subscript) are rendered as the native
/// hamburger menu items; the yaml-driven menu declared in
/// `workspace/panels/character.yaml` carries the same actions with
/// `bind: panel.*_caps / super / sub` checked expressions so the
/// two surfaces stay in sync.
///
/// Layer B wiring lives in:
/// - `DockPanelView.buildPanelCtx` — seeds / activates the panel
///   scope in `model.stateStore` and merges `characterPanelLive
///   Overrides(model:)` on top so the widgets reflect the selected
///   Text / TextPath.
/// - `YamlElementView.commitPanelWrite` — widget write-backs fire
///   `notifyPanelStateChanged("character_panel_content", ...)`, which calls
///   `applyCharacterPanelToSelection`.

public enum CharacterPanel {
    /// Source of truth is workspace/panels/character.yaml's `menu:`
    /// block (review #15); the generic reader builds the items from the
    /// bundle. Each `checked:` toggle maps to a panel-state bool the
    /// dispatcher flips (and `isCheckedWithModel` reads back).
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("character_panel_content")
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr,
                                layout: inout WorkspaceLayout,
                                model: Model? = nil) {
        switch cmd {
        case "close_panel":
            layout.closePanel(addr)
        case "toggle_snap_to_glyph_visible":
            flipPanelBool(model: model, key: "snap_to_glyph_visible",
                          applyToSelection: false)
        case "toggle_all_caps":
            flipPanelBool(model: model, key: "all_caps",
                          // Mutually exclusive with Small Caps per
                          // CHARACTER.md: turning All Caps on clears
                          // Small Caps so the two toggles never claim
                          // the same selection at once.
                          clearOnSet: ["small_caps"],
                          applyToSelection: true)
        case "toggle_small_caps":
            flipPanelBool(model: model, key: "small_caps",
                          clearOnSet: ["all_caps"],
                          applyToSelection: true)
        case "toggle_superscript":
            flipPanelBool(model: model, key: "superscript",
                          clearOnSet: ["subscript"],
                          applyToSelection: true)
        case "toggle_subscript":
            flipPanelBool(model: model, key: "subscript",
                          clearOnSet: ["superscript"],
                          applyToSelection: true)
        default: break
        }
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        // Without model context, no way to read panel state.
        // Real menu invocations route through `isCheckedWithModel`.
        false
    }

    /// Read a toggle's checked state from the Character panel store.
    /// Used by the hamburger menu so the menu's checkmark mirrors the
    /// panel-state bool the toggle dispatchers flip.
    public static func isCheckedWithModel(_ cmd: String, model: Model?) -> Bool {
        guard let model = model else { return false }
        let pid = "character_panel_content"
        let key: String
        switch cmd {
        case "toggle_snap_to_glyph_visible": key = "snap_to_glyph_visible"
        case "toggle_all_caps":               key = "all_caps"
        case "toggle_small_caps":             key = "small_caps"
        case "toggle_superscript":            key = "superscript"
        case "toggle_subscript":              key = "subscript"
        default: return false
        }
        return (model.stateStore.getPanel(pid, key) as? Bool) ?? false
    }

    /// Flip a panel-local Bool, optionally clear sibling bools (for
    /// mutual-exclusion pairs), then push the resulting panel state
    /// onto the selected Text / TextPath so the menu and the in-panel
    /// icon toggles stay in sync. ``applyToSelection`` is false for
    /// the snap-to-glyph visibility toggle since that one is purely
    /// panel-local UI state.
    private static func flipPanelBool(model: Model?, key: String,
                                       clearOnSet: [String] = [],
                                       applyToSelection: Bool) {
        guard let model = model else { return }
        let pid = "character_panel_content"
        let store = model.stateStore
        if !store.hasPanel(pid), let ws = WorkspaceData.load() {
            store.initPanel(pid, defaults: ws.panelStateDefaults(pid))
        }
        // Sync from selection so untouched fields keep current values
        // when the apply pipeline reads them back. Mirrors
        // ``commitPanelWrite``.
        if applyToSelection,
           let overrides = characterPanelLiveOverrides(model: model) {
            for (k, v) in overrides { store.setPanel(pid, k, v) }
        }
        let cur = (store.getPanel(pid, key) as? Bool) ?? false
        let newVal = !cur
        store.setPanel(pid, key, newVal)
        if newVal {
            for sib in clearOnSet { store.setPanel(pid, sib, false) }
        }
        model.panelStateVersion &+= 1
        if applyToSelection {
            applyCharacterPanelToSelection(
                store: store, controller: Controller(model: model))
        }
    }
}
