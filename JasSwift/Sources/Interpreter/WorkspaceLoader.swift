/// Workspace loader -- parses compiled JSON and extracts panel specs,
/// actions, state defaults, and theme.

import Foundation

/// Parsed workspace data.
class WorkspaceData {
    let data: [String: Any]

    init(_ data: [String: Any]) {
        self.data = data
    }

    /// Load the workspace from a JSON file or embedded fallback.
    ///
    /// Tries to read from the development file path first
    /// (../../workspace/workspace.json relative to JasSwift),
    /// then falls back to an embedded empty workspace.
    static func load() -> WorkspaceData? {
        // Try file-based loading for development
        let filePaths = [
            // Relative to JasSwift directory
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()  // Interpreter/
                .deletingLastPathComponent()  // Sources/
                .deletingLastPathComponent()  // JasSwift/
                .deletingLastPathComponent()  // jas/
                .appendingPathComponent("workspace/workspace.json")
                .path,
            // Direct relative path
            "../../workspace/workspace.json",
        ]

        for path in filePaths {
            if FileManager.default.fileExists(atPath: path) {
                if let data = FileManager.default.contents(atPath: path),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return WorkspaceData(json)
                }
            }
        }

        // Try from Bundle
        if let url = Bundle.main.url(forResource: "workspace", withExtension: "json") {
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return WorkspaceData(json)
            }
        }

        return nil
    }

    /// Get the panels map.
    func panels() -> [String: Any]? {
        data["panels"] as? [String: Any]
    }

    /// Get a specific panel spec by content id.
    func panel(_ contentId: String) -> [String: Any]? {
        (data["panels"] as? [String: Any])?[contentId] as? [String: Any]
    }

    /// Get a concept pack by id from the concept registry (CONCEPTS.md): the
    /// spec carries `params`, `closed`, and the `generator` expression.
    func concept(_ id: String) -> [String: Any]? {
        (data["concepts"] as? [String: Any])?[id] as? [String: Any]
    }

    /// The whole concept registry (id -> spec), for code that must iterate every
    /// concept — e.g. `promote` trying each concept's `fitter` detector
    /// (CONCEPTS.md §10). Mirrors Rust `Workspace::concepts`.
    func concepts() -> [String: Any]? {
        data["concepts"] as? [String: Any]
    }

    /// The concept registry as a sorted list of `{id, name, description}` for the
    /// Concepts panel's `data.concepts` foreach (CONCEPTS.md §6).
    func conceptsList() -> [[String: Any]] {
        guard let map = data["concepts"] as? [String: Any] else { return [] }
        return map.keys.sorted().map { id in
            let c = map[id] as? [String: Any] ?? [:]
            return [
                "id": id,
                "name": (c["name"] as? String) ?? id,
                "description": (c["description"] as? String) ?? "",
            ]
        }
    }

    /// Get the panel menu items for a content id.
    func panelMenu(_ contentId: String) -> [[String: Any]] {
        guard let panel = panel(contentId),
              let menu = panel["menu"] as? [[String: Any]] else {
            return []
        }
        return menu
    }

    /// Get the panel menu entries for a content id, preserving every
    /// entry type. Unlike ``panelMenu`` (which casts to
    /// `[[String: Any]]` and so silently drops the bare `"separator"`
    /// string entries), this returns the raw heterogeneous array so the
    /// generic menu builder sees separators as well as object entries.
    func panelMenuRaw(_ contentId: String) -> [Any] {
        guard let panel = panel(contentId),
              let menu = panel["menu"] as? [Any] else {
            return []
        }
        return menu
    }

    /// Get the top menu-bar spec: the raw heterogeneous array of top-level
    /// menus (each a `{ id, label, items }` object) from the compiled bundle.
    /// The menu bar projector (``menuBarModel()``) consumes this. Mirrors the
    /// ``panelMenuRaw`` accessor — it returns `[Any]` so nested `"separator"`
    /// string entries survive (an `[[String: Any]]` cast would drop them).
    func menubar() -> [Any] {
        data["menubar"] as? [Any] ?? []
    }

    /// Get the panel content element tree for a content id.
    func panelContent(_ contentId: String) -> [String: Any]? {
        panel(contentId)?["content"] as? [String: Any]
    }

    /// Find a node with the given ``id`` anywhere in the layout tree
    /// (depth-first over ``children``). Used to pull the toolbar's
    /// ``tool_grid`` element out of the compiled layout so the toolbar
    /// pane renders from the bundle, mirroring Rust's
    /// ``YamlToolbarContent`` lookup.
    private func findLayoutNode(_ id: String, in node: [String: Any]) -> [String: Any]? {
        if node["id"] as? String == id { return node }
        if let kids = node["children"] as? [[String: Any]] {
            for kid in kids {
                if let found = findLayoutNode(id, in: kid) { return found }
            }
        }
        // The toolbar pane's content is nested under `content`, not
        // `children`; descend into it too.
        if let content = node["content"] as? [String: Any] {
            if let found = findLayoutNode(id, in: content) { return found }
        }
        return nil
    }

    /// The toolbar's ``tool_grid`` element from the compiled layout
    /// (``layout`` → ``toolbar_pane`` → ``content`` → ``tool_grid``).
    /// Nil if the layout or grid is absent. Step A renders only the
    /// tool grid generically; the fill/stroke widget below it stays
    /// native (see ContentView's toolbar pane).
    func toolGrid() -> [String: Any]? {
        guard let layout = data["layout"] as? [String: Any] else { return nil }
        return findLayoutNode("tool_grid", in: layout)
    }

    /// Extract default values from state definitions.
    func stateDefaults() -> [String: Any] {
        guard let state = data["state"] as? [String: Any] else { return [:] }
        var defaults: [String: Any] = [:]
        for (key, defn) in state {
            if let d = defn as? [String: Any] {
                defaults[key] = d["default"] ?? NSNull()
            } else {
                defaults[key] = defn
            }
        }
        return defaults
    }

    /// Extract default values from a panel's state section.
    func panelStateDefaults(_ contentId: String) -> [String: Any] {
        guard let panel = panel(contentId),
              let state = panel["state"] as? [String: Any] else {
            return [:]
        }
        var defaults: [String: Any] = [:]
        for (key, defn) in state {
            if let d = defn as? [String: Any] {
                defaults[key] = d["default"] ?? NSNull()
            } else {
                defaults[key] = defn
            }
        }
        return defaults
    }

    /// Get the dialogs map.
    func dialogs() -> [String: Any] {
        data["dialogs"] as? [String: Any] ?? [:]
    }

    /// Get a specific dialog spec by id.
    func dialog(_ dialogId: String) -> [String: Any]? {
        (data["dialogs"] as? [String: Any])?[dialogId] as? [String: Any]
    }

    /// Extract default values from a dialog's state section.
    func dialogStateDefaults(_ dialogId: String) -> [String: Any] {
        guard let dlg = dialog(dialogId),
              let state = dlg["state"] as? [String: Any] else {
            return [:]
        }
        var defaults: [String: Any] = [:]
        for (key, defn) in state {
            if let d = defn as? [String: Any] {
                defaults[key] = d["default"] ?? NSNull()
            } else {
                defaults[key] = defn
            }
        }
        return defaults
    }

    /// Get the swatch libraries data map.
    func swatchLibraries() -> [String: Any] {
        data["swatch_libraries"] as? [String: Any] ?? [:]
    }

    /// Get the brush libraries data map. Each entry is a library
    /// keyed by slug; library value carries name / description /
    /// brushes[] per BRUSHES.md §Brush libraries. Mutated at runtime
    /// by the brush.* and data.* effect handlers (when those land in
    /// Swift). Phase 1 ships the seed `default_brushes` library only.
    func brushLibraries() -> [String: Any] {
        data["brush_libraries"] as? [String: Any] ?? [:]
    }

    /// Get the icons map.
    func icons() -> [String: Any] {
        data["icons"] as? [String: Any] ?? [:]
    }

    /// Get the actions map.
    func actions() -> [String: Any] {
        data["actions"] as? [String: Any] ?? [:]
    }

    /// Get the theme data.
    func theme() -> [String: Any]? {
        data["theme"] as? [String: Any]
    }
}

/// Map a tool yaml's `tool_options_panel` string id to the matching
/// PanelKind. Returns nil if the id does not name a known panel.
public func panelIdToKind(_ id: String) -> PanelKind? {
    switch id {
    case "magic_wand": return .magicWand
    default: return nil
    }
}

/// The three ways a tool can surface its options when its toolbar icon
/// is double-clicked, in the priority order the dispatcher resolves them
/// (panel beats action beats dialog). ``.none`` means the active tool
/// declares no options field — the double-click is a no-op.
///
/// Mirrors the prior native ``onOpenToolOptions`` lookup (which handled
/// only ``tool_options_panel`` / ``tool_options_dialog``) plus the
/// previously-aspirational ``tool_options_action`` path documented on the
/// Hand / Zoom toolbar slots (HAND_TOOL.md / ZOOM_TOOL.md).
public enum ToolOptionsDispatch: Equatable {
    /// ``tool_options_panel`` → show this panel id (mapped to a
    /// ``PanelKind`` by ``panelIdToKind``). e.g. magic_wand → magic_wand.
    case panel(String)
    /// ``tool_options_action`` → dispatch this named view action.
    /// e.g. hand → fit_active_artboard, zoom → zoom_to_actual_size.
    case action(String)
    /// ``tool_options_dialog`` → open this dialog id via the dialog path.
    /// e.g. paintbrush → paintbrush_tool_options.
    case dialog(String)
    /// The tool declares none of the three options fields.
    case none
}

/// Resolve the active tool's options dispatch from the compiled bundle's
/// ``tools`` map. The tool list is NOT hardcoded — the entry is looked up
/// by its yaml string id and its three optional fields are read in
/// priority order (panel → action → dialog). A tool typically declares at
/// most one; if it somehow declared several, panel wins, then action.
///
/// Returns ``.none`` when the tool is unknown or declares no options
/// field, so callers treat the double-click as a no-op.
public func resolveToolOptions(
    tools: [String: Any], activeTool: String
) -> ToolOptionsDispatch {
    guard let spec = tools[activeTool] as? [String: Any] else { return .none }
    if let panelId = spec["tool_options_panel"] as? String, !panelId.isEmpty {
        return .panel(panelId)
    }
    if let actionName = spec["tool_options_action"] as? String, !actionName.isEmpty {
        return .action(actionName)
    }
    if let dialogId = spec["tool_options_dialog"] as? String, !dialogId.isEmpty {
        return .dialog(dialogId)
    }
    return .none
}

/// Discriminate a TOOLBAR tool button from every other ``icon_button``
/// (panel radios, dialog glyphs, fill/stroke mode buttons, …). A toolbar
/// tool slot is exactly an ``icon_button`` whose ``behavior`` carries a
/// ``click`` event dispatching the ``select_tool`` action (the same
/// discriminator the icon-sizing path keys on). This is true for both the
/// plain top-level slots (btn_selection, btn_line, …) and the
/// long-press-alternate slots (btn_arrow_slot, …): both commit a tool on
/// click, so both should open the active tool's options on double-click.
/// Panels and other icon_buttons never carry a ``select_tool`` click, so
/// they never match — the double-click stays scoped to tool slots.
public func isToolButtonElement(_ element: [String: Any]) -> Bool {
    guard (element["type"] as? String) == "icon_button" else { return false }
    let behaviors = element["behavior"] as? [[String: Any]] ?? []
    return behaviors.contains { beh in
        (beh["event"] as? String) == "click"
            && (beh["action"] as? String) == "select_tool"
    }
}

/// Map PanelKind to YAML content id.
func panelKindToContentId(_ kind: PanelKind) -> String {
    switch kind {
    case .layers: return "layers_panel_content"
    case .color: return "color_panel_content"
    case .swatches: return "swatches_panel_content"
    case .stroke: return "stroke_panel_content"
    case .properties: return "properties_panel_content"
    case .character: return "character_panel_content"
    case .paragraph: return "paragraph_panel_content"
    case .artboards: return "artboards_panel_content"
    case .align: return "align_panel_content"
    case .boolean: return "boolean_panel_content"
    case .opacity: return "opacity_panel_content"
    case .magicWand: return "magic_wand_panel_content"
    case .symbols: return "symbols_panel_content"
    }
}
