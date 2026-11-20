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
    /// bundle. Each `checked_when:` toggle maps to a panel-state bool the
    /// dispatcher flips (and the generic `panelIsChecked` reads back through
    /// character.yaml's own `checked_when:` predicates).
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("character_panel_content")
    }

    // No native dispatch: every menu row runs its actions.yaml entry through
    // ``panelDispatchRow`` (row 174), as the engine and the web do.
}
