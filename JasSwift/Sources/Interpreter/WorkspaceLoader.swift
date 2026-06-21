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

    /// Get the panel content element tree for a content id.
    func panelContent(_ contentId: String) -> [String: Any]? {
        panel(contentId)?["content"] as? [String: Any]
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
