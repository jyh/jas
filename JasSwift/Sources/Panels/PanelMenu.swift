/// Unified panel menu lookup functions.
///
/// Each panel kind delegates to its own module for menu items, dispatch,
/// and checked-state queries. Labels are read from the workspace YAML
/// `summary:` field of the panel's content spec.

import Foundation

/// Build a panel's hamburger menu from the compiled workspace bundle
/// (the panel YAML `menu:` array) rather than a hand-written native
/// list. The YAML is the single source of truth (review #15); each
/// panel's `menuItems()` now delegates here.
///
/// Mirrors the Rust reference `panel_menu::menu_items_from_yaml`:
/// a bare `separator` string becomes ``PanelMenuItem/separator``; an
/// entry with a `checked` / `checked_when` expression becomes a
/// ``PanelMenuItem/toggle`` (or a ``PanelMenuItem/radio`` when its
/// action recurs across the menu); everything else — plain actions,
/// dynamic library submenus (which carry an explicit `action:`), and
/// disabled placeholders (no `action:`) — becomes a
/// ``PanelMenuItem/action``.
///
/// A radio group is a set of entries that share one YAML `action`
/// (e.g. every `set_color_panel_mode` row). The YAML carries no
/// explicit `group:` key — sameness of the action *is* the grouping —
/// so we count action occurrences to tell a one-off checkbox apart
/// from a mutually-exclusive radio member, and fold each member's
/// `params` values into its command (`set_color_panel_mode:rgb`) so
/// the no-params menu dispatch stays able to distinguish them.
public func menuItemsFromYaml(_ contentId: String) -> [PanelMenuItem] {
    guard let ws = WorkspaceData.load() else { return [] }
    let menu = ws.panelMenuRaw(contentId)

    // Count action occurrences: an action that recurs marks a radio
    // group; a one-off action with a `checked` expr is a plain toggle.
    var actionCounts: [String: Int] = [:]
    for entry in menu {
        if let obj = entry as? [String: Any],
           let action = obj["action"] as? String {
            actionCounts[action, default: 0] += 1
        }
    }

    var items: [PanelMenuItem] = []
    for entry in menu {
        // A bare `separator` YAML item compiles to the string "separator".
        if let s = entry as? String, s == "separator" {
            items.append(.separator)
            continue
        }
        guard let obj = entry as? [String: Any],
              let label = obj["label"] as? String else { continue }
        let action = obj["action"] as? String
        // A radio-group member is one whose `action` recurs across the
        // menu (grouping is by action sameness, not an explicit key).
        let isRadioMember = action.map { (actionCounts[$0] ?? 0) > 1 } ?? false

        // Radio members share one action, so fold their `params` values
        // into the command to keep them distinguishable when the menu
        // view dispatches the bare command with no params. Every other
        // entry keeps its action verbatim — folding params there would
        // corrupt single-action commands like `close_panel`
        // (params: { panel: color }).
        let command: String = isRadioMember
            ? commandWithParams(obj)
            : (action ?? "")

        // A `checked:` / `checked_when:` expression marks a stateful
        // item: a radio member, or a standalone checkbox (toggle).
        let hasChecked = obj["checked"] != nil || obj["checked_when"] != nil
        if hasChecked && isRadioMember {
            items.append(.radio(label: label, command: command, group: action ?? ""))
        } else if hasChecked {
            items.append(.toggle(label: label, command: command))
        } else {
            // Plain actions, dynamic submenus (`type: submenu`, which
            // carry an explicit `action:` so the menu view's special
            // case fires), and disabled placeholders (no `action:`,
            // gated off by the panel's enabled state) all surface as
            // actions.
            items.append(.action(label: label, command: command))
        }
    }
    return items
}

/// Build the runtime command for a menu entry: the `action` string
/// with any `params` values appended as `:value` segments (in the
/// compiled JSON's param order). Entries with no action produce an
/// empty command (disabled placeholders). Lets several radio members
/// share one YAML `action` yet dispatch to distinct native commands
/// without threading params through the menu view.
///
/// Mirrors the Rust reference `panel_menu::command_with_params`.
func commandWithParams(_ obj: [String: Any]) -> String {
    var cmd = (obj["action"] as? String) ?? ""
    if let params = obj["params"] as? [String: Any] {
        // Preserve insertion order from the compiled JSON. JSONSerialization
        // hands back an unordered dictionary, so recover the declared key
        // order from the canonical `params` ordering when there is more
        // than one — single-param entries (the common radio case:
        // `mode`, `size`, `cap`, `join`) are order-insensitive.
        for v in params.values {
            let seg: String
            if let s = v as? String { seg = s }
            else if let n = v as? NSNumber { seg = n.stringValue }
            else { seg = "\(v)" }
            cmd += ":" + seg
        }
    }
    return cmd
}

/// Human-readable label for a panel kind, read from the workspace YAML
/// `summary:` field of the panel's content spec.
public func panelLabel(_ kind: PanelKind) -> String {
    let contentId = panelKindToContentId(kind)
    if let summary = WorkspaceData.load()?.panel(contentId)?["summary"] as? String {
        return summary
    }
    return contentId.replacingOccurrences(of: "_panel_content", with: "")
}

/// Menu items for a panel kind.
public func panelMenu(_ kind: PanelKind) -> [PanelMenuItem] {
    switch kind {
    case .layers: return LayersPanel.menuItems()
    case .color: return ColorPanel.menuItems()
    case .swatches: return SwatchesPanel.menuItems()
    case .stroke: return StrokePanel.menuItems()
    case .properties: return PropertiesPanel.menuItems()
    case .character: return CharacterPanel.menuItems()
    case .paragraph: return ParagraphPanel.menuItems()
    case .artboards: return ArtboardsPanel.menuItems()
    case .align: return AlignPanel.menuItems()
    case .boolean: return BooleanPanel.menuItems()
    case .opacity: return OpacityPanel.menuItems()
    case .magicWand: return MagicWandPanel.menuItems()
    case .symbols: return SymbolsPanel.menuItems()
    case .brushes: return BrushesPanel.menuItems()
    }
}

/// Resolve a dynamic (`{{if …}}`) menu-item label for a panel kind, or
/// nil when the command has no dynamic label (the menu view then shows
/// the YAML label verbatim). Currently only the Layers panel's
/// all-layers toggle rows carry dynamic labels. Mirrors the Rust
/// `panel_dynamic_label` bridge.
public func panelDynamicLabel(_ kind: PanelKind, cmd: String,
                              model: Model?) -> String? {
    switch kind {
    case .layers: return LayersPanel.dynamicLabel(cmd, model: model)
    default: return nil
    }
}

/// Dispatch a menu command for a panel kind.
public func panelDispatch(_ kind: PanelKind, cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout, model: Model? = nil) {
    switch kind {
    case .layers: LayersPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .color: ColorPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .swatches: SwatchesPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .stroke: StrokePanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .properties: PropertiesPanel.dispatch(cmd, addr: addr, layout: &layout)
    case .character: CharacterPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .paragraph: ParagraphPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .artboards: ArtboardsPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .align: AlignPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .boolean: BooleanPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .opacity: OpacityPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .magicWand: MagicWandPanel.dispatch(cmd, addr: addr, layout: &layout)
    case .symbols: SymbolsPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .brushes: BrushesPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    }
}

/// Query whether a toggle/radio command is checked for a panel kind.
/// `model` is optional so legacy call sites without one still work; panels
/// whose checked state mirrors panel-state (e.g. Swatches' thumbnail_size
/// radio) need it to read the StateStore.
public func panelIsChecked(_ kind: PanelKind, cmd: String,
                           layout: WorkspaceLayout, model: Model? = nil) -> Bool {
    switch kind {
    case .layers: return LayersPanel.isChecked(cmd, layout: layout)
    case .color: return ColorPanel.isChecked(cmd, layout: layout)
    case .swatches:
        return SwatchesPanel.isCheckedWithModel(cmd, model: model)
    case .stroke: return StrokePanel.isCheckedWithModel(cmd, model: model)
    case .properties: return PropertiesPanel.isChecked(cmd, layout: layout)
    case .character: return CharacterPanel.isCheckedWithModel(cmd, model: model)
    case .paragraph: return ParagraphPanel.isCheckedWithModel(cmd, model: model)
    case .artboards: return ArtboardsPanel.isChecked(cmd, layout: layout)
    case .align: return AlignPanel.isCheckedWithModel(cmd, model: model)
    case .boolean: return BooleanPanel.isChecked(cmd, layout: layout)
    case .opacity: return OpacityPanel.isChecked(cmd, layout: layout)
    case .magicWand: return MagicWandPanel.isChecked(cmd, layout: layout)
    case .symbols: return SymbolsPanel.isChecked(cmd, layout: layout)
    case .brushes: return BrushesPanel.isCheckedWithModel(cmd, model: model)
    }
}

/// Query whether a menu command is enabled for a panel kind. Defaults
/// to `true` for panels / commands without a state-conditional rule.
/// Mirrors Rust's `panel_is_enabled`.
public func panelIsEnabled(_ kind: PanelKind, cmd: String,
                           model: Model? = nil) -> Bool {
    switch kind {
    case .color: return ColorPanel.isEnabled(cmd, model: model)
    default: return true
    }
}
