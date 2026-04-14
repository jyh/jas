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

    /// Get the panel menu items for a content id.
    func panelMenu(_ contentId: String) -> [[String: Any]] {
        guard let panel = panel(contentId),
              let menu = panel["menu"] as? [[String: Any]] else {
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

/// Map PanelKind to YAML content id.
func panelKindToContentId(_ kind: PanelKind) -> String {
    switch kind {
    case .layers: return "layers_panel_content"
    case .color: return "color_panel_content"
    case .swatches: return "swatches_panel_content"
    case .stroke: return "stroke_panel_content"
    case .properties: return "properties_panel_content"
    }
}
