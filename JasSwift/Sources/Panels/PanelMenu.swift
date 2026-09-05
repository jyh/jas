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
    // Gradient / Concepts are rendered generically from the YAML bundle and
    // have no native panel-menu module, so their hamburger menu is empty (the
    // bundle supplies any panel-menu rows). They exist as PanelKind cases
    // purely so the dock can show/hide them via the generic toggle_panel path.
    case .gradient, .concepts: return []
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
    // No native panel-menu module (YAML-rendered): no bespoke menu commands.
    case .gradient, .concepts: break
    }
}

/// Query whether a toggle/radio command is checked for a panel kind.
///
/// ONE path for every panel: the panel's bundle menu entry is looked up by
/// its runtime command, its `checked_when:` / `checked:` predicate is
/// evaluated against the panel's context, and that is the answer. The
/// fourteen per-panel native hooks this replaced are gone — with them went
/// `BrushesPanel`'s hand-written `arr.contains { ($0 as? String) == v }`,
/// which was the ONLY place five of the Brushes panel's check marks worked
/// (jas_dioxus answered `false` for all of them): the same YAML predicate,
/// two different answers, which is precisely what the prime directive
/// forbids.
///
/// `model` stays optional so legacy call sites without one still work; a
/// panel whose live state is in the shared store then falls back to the
/// bundle's declared defaults.
///
/// Mirrors the Rust `panels::panel_is_checked`.
public func panelIsChecked(_ kind: PanelKind, cmd: String,
                           layout: WorkspaceLayout, model: Model? = nil) -> Bool {
    let contentId = panelKindToContentId(kind)
    let ctx = panelMenuContext(contentId, layout: layout, model: model)
    return panelMenuIsChecked(contentId, cmd, ctx: ctx)
}

/// The `checked_when:` (or `checked:`) predicate of the panel-menu entry
/// whose runtime command is `cmd`, or nil when there is no such entry or it
/// declares no predicate.
///
/// The command is matched with the SAME fold `menuItemsFromYaml` applies
/// (`commandWithParams` for radio members, the bare action otherwise), so a
/// caller holding a `PanelMenuItem`'s command can always find its own entry.
///
/// Both spellings are read because the panel-menu vocabulary uses both:
/// `workspace/panels/{brushes,color,opacity,stroke,swatches}.yaml` write
/// `checked_when:`, while `{align,character,paragraph}.yaml` write
/// `checked:`. `menuItemsFromYaml` already reads both to decide toggle vs
/// radio, so reading only one here would leave three panels' check marks
/// dead. No expression feature is added: the two keys carry the same grammar
/// and are evaluated the same way.
///
/// Mirrors the Rust `panel_menu::checked_expr`.
public func panelMenuCheckedExpr(_ contentId: String, _ cmd: String) -> String? {
    guard !cmd.isEmpty, let ws = WorkspaceData.load() else { return nil }
    let menu = ws.panelMenuRaw(contentId)
    var actionCounts: [String: Int] = [:]
    for entry in menu {
        if let obj = entry as? [String: Any],
           let action = obj["action"] as? String {
            actionCounts[action, default: 0] += 1
        }
    }
    for entry in menu {
        guard let obj = entry as? [String: Any] else { continue }
        let action = obj["action"] as? String
        let isRadioMember = action.map { (actionCounts[$0] ?? 0) > 1 } ?? false
        let entryCmd = isRadioMember ? commandWithParams(obj) : (action ?? "")
        guard entryCmd == cmd else { continue }
        let expr = (obj["checked_when"] as? String) ?? (obj["checked"] as? String)
        guard let expr = expr, !expr.isEmpty else { return nil }
        return expr
    }
    return nil
}

/// Whether the panel-menu entry for `cmd` is checked, evaluating its bundle
/// predicate against `ctx` through the SHARED menu-state evaluator.
///
/// An entry with no predicate — and a command that names no entry — is not
/// checked, matching `MenuState`'s `checked: NSNull()` for an item with no
/// `checked_when`.
public func panelMenuIsChecked(_ contentId: String, _ cmd: String,
                               ctx: [String: Any]) -> Bool {
    guard let expr = panelMenuCheckedExpr(contentId, cmd) else { return false }
    return MenuState.evalBool(expr, ctx)
}

/// Build the expression context a panel's menu predicates are evaluated
/// against: the panel's own state table as `panel`, the `preferences` tier the
/// bundle ships, the live `state` scope, the `active_document` view and the
/// OPACITY.md selection predicates at top level — the namespaces the bundle's
/// panel-menu `enabled_when` / `checked_when` rows read, censused by
/// `everyPanelMenuPredicateReadIsPublishedToTheMenuContext`.
///
/// `panel` starts from the bundle's declared state defaults, is overlaid with
/// the shared panel store (where most of this app's panel state actually
/// lives), then with the handful of values this app keeps on
/// `WorkspaceLayout` and on the `Model` instead. Those overlays are the whole
/// of what the deleted native hooks encoded — a statement about STORAGE, not
/// about menus.
///
/// The other three namespaces come from the SAME builders the panel BODY
/// renders against (`DockPanelView.buildPanelCtx`), so a predicate reads one
/// fact one way whether it sits in the hamburger menu or in a widget's
/// `bind:`. Until they were added the menu context published `panel` and
/// `preferences` alone, and every `enabled_when` naming `state.`,
/// `active_document.` or `selection_has_mask` read null — invisible while
/// `panelIsEnabled` never consulted the YAML.
///
/// Mirrors the Rust `panel_menu::panel_menu_ctx`.
public func panelMenuContext(_ contentId: String, layout: WorkspaceLayout,
                             model: Model?) -> [String: Any] {
    let ws = WorkspaceData.load()
    var panel: [String: Any] = ws?.panelStateDefaults(contentId) ?? [:]
    if let store = model?.stateStore, store.hasPanel(contentId) {
        for (k, v) in store.getPanelState(contentId) { panel[k] = v }
    }
    for (k, v) in layoutHeldPanelState(contentId, layout: layout) { panel[k] = v }
    for (k, v) in modelHeldPanelState(contentId, model: model) { panel[k] = v }
    var ctx: [String: Any] = ["panel": panel]
    ctx["preferences"] = ws?.data["preferences"] ?? [:]
    if let ws = ws {
        ctx["state"] = buildLiveStateMap(ws: ws, model: model)
    } else {
        ctx["state"] = [:] as [String: Any]
    }
    ctx["active_document"] = buildActiveDocumentView(
        model: model,
        layersPanelSelection: layersPanelSelection(model: model),
        artboardsPanelSelection: artboardsPanelSelection(model: model)
    )
    // `selection_has_mask` and its siblings sit at TOP level, as the body's
    // context places them, so `enabled_when: "!selection_has_mask"` reads the
    // same key from both surfaces.
    for (k, v) in buildSelectionPredicates(model: model) { ctx[k] = v }
    return ctx
}

/// The layers-panel TREE selection, as paths, read from the shared store
/// under the key layers.yaml declares (`panel.panel_selection`, content
/// `layers_panel_content`).
///
/// `TreeViewContent` keeps the selection in view-lived `@State` and mirrors
/// it here on every change; before the mirror existed nothing outside that
/// view could read it, so `active_document.layers_panel_selection_count` was
/// 0 in every context this app built — the dock's body context read a store
/// key nothing had ever written. One reader for both surfaces now.
func layersPanelSelection(model: Model?) -> [[Int]] {
    guard let store = model?.stateStore,
          let raw = store.getPanel("layers_panel_content", "panel_selection") as? [Any]
    else { return [] }
    return raw.compactMap { entry -> [Int]? in
        if let ints = entry as? [Int] { return ints }
        if let nums = entry as? [NSNumber] { return nums.map { $0.intValue } }
        return nil
    }
}

/// The artboards-panel selection ids, read from the store scope the
/// artboards effects write (`"artboards"` / `artboards_panel_selection`, the
/// reader `Effects.swift`'s artboard verbs already use).
func artboardsPanelSelection(model: Model?) -> [String] {
    (model?.stateStore.getPanel("artboards", "artboards_panel_selection") as? [String]) ?? []
}

/// The `panel.*` values this app keeps on the ``Model`` rather than in the
/// shared panel store, keyed exactly as the panel's YAML state table
/// declares them. One panel: the layers isolation stack, which the YAML
/// `list_push` / `list_pop` effects route to `model.layersIsolationStack`.
private func modelHeldPanelState(_ contentId: String,
                                 model: Model?) -> [String: Any] {
    switch contentId {
    case "layers_panel_content":
        guard let m = model else { return [:] }
        return ["isolation_stack": m.layersIsolationStack]
    default:
        return [:]
    }
}

/// The `panel.*` values this app keeps on ``WorkspaceLayout`` rather than in
/// the shared panel store, keyed exactly as the panel's YAML state table
/// declares them.
///
/// Two panels only. Everything else reads back out of the store the YAML
/// actions write to, which is why the other twelve native hooks reduced to
/// nothing at all.
private func layoutHeldPanelState(_ contentId: String,
                                  layout: WorkspaceLayout) -> [String: Any] {
    switch contentId {
    case "color_panel_content":
        let mode: String
        switch layout.colorPanelMode {
        case .grayscale: mode = "grayscale"
        case .hsb: mode = "hsb"
        case .rgb: mode = "rgb"
        case .cmyk: mode = "cmyk"
        case .webSafeRgb: mode = "web_safe_rgb"
        }
        return ["mode": mode]
    case "opacity_panel_content":
        return [
            "thumbnails_hidden": layout.opacityPanel.thumbnailsHidden,
            "options_shown": layout.opacityPanel.optionsShown,
            "new_masks_clipping": layout.opacityPanel.newMasksClipping,
            "new_masks_inverted": layout.opacityPanel.newMasksInverted,
        ]
    default:
        return [:]
    }
}

/// Query whether a menu command is enabled for a panel kind.
///
/// ONE path for every panel, the twin of `panelIsChecked`: the panel's bundle
/// menu entry is looked up by its runtime command, its `enabled_when:`
/// predicate is evaluated against the panel's context, and that is the answer
/// (`true` with no predicate, as `MenuState` defaults). The native hook this
/// replaced — `ColorPanel.isEnabled`'s `activeDefaultPaintColor != nil` —
/// restated a rule color.yaml already states; every other panel answered
/// `true` without reading the YAML at all, so "New Brush" never greyed out
/// and the gradient rows declared `enabled_when: "false"` stayed live in both
/// active ports.
///
/// Mirrors the Rust `panels::panel_is_enabled`.
public func panelIsEnabled(_ kind: PanelKind, cmd: String,
                           layout: WorkspaceLayout, model: Model? = nil) -> Bool {
    let contentId = panelKindToContentId(kind)
    let ctx = panelMenuContext(contentId, layout: layout, model: model)
    return panelMenuIsEnabled(contentId, cmd, ctx: ctx)
}

/// The `enabled_when:` predicate of the panel-menu entry whose runtime
/// command is `cmd`, or nil when there is no such entry or it declares none.
/// Matched with the SAME fold `menuItemsFromYaml` applies, exactly as
/// `panelMenuCheckedExpr` is. One spelling only: the panel-menu vocabulary
/// writes `enabled_when:` everywhere (the menubar's word too).
///
/// Mirrors the Rust `panel_menu::enabled_expr`.
public func panelMenuEnabledExpr(_ contentId: String, _ cmd: String) -> String? {
    guard !cmd.isEmpty, let ws = WorkspaceData.load() else { return nil }
    let menu = ws.panelMenuRaw(contentId)
    var actionCounts: [String: Int] = [:]
    for entry in menu {
        if let obj = entry as? [String: Any],
           let action = obj["action"] as? String {
            actionCounts[action, default: 0] += 1
        }
    }
    for entry in menu {
        guard let obj = entry as? [String: Any] else { continue }
        let action = obj["action"] as? String
        let isRadioMember = action.map { (actionCounts[$0] ?? 0) > 1 } ?? false
        let entryCmd = isRadioMember ? commandWithParams(obj) : (action ?? "")
        guard entryCmd == cmd else { continue }
        guard let expr = obj["enabled_when"] as? String, !expr.isEmpty else { return nil }
        return expr
    }
    return nil
}

/// Whether the panel-menu entry for `cmd` is enabled, evaluating its bundle
/// predicate against `ctx` through the SHARED menu-state evaluator. An entry
/// with no predicate — and a command that names no entry — is enabled,
/// matching `MenuState`'s `enabled: true` default.
///
/// Mirrors the Rust `panel_menu::is_enabled_from_yaml`.
public func panelMenuIsEnabled(_ contentId: String, _ cmd: String,
                               ctx: [String: Any]) -> Bool {
    guard let expr = panelMenuEnabledExpr(contentId, cmd) else { return true }
    return MenuState.evalBool(expr, ctx)
}
