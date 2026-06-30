import Foundation

/// Brushes panel menu definition.
///
/// Source of truth is workspace/panels/brushes.yaml's `menu:` block; the
/// generic reader (`menuItemsFromYaml`) builds the items from the compiled
/// bundle. Several rows share one YAML action and so arrive param-folded
/// from the generic menu builder (`set_brush_view_mode:thumbnail`,
/// `set_brush_thumbnail_size:small`, `toggle_brush_category:calligraphic`,
/// `open_brush_options:create`); `dispatch` / `isCheckedWithModel` split the
/// value suffix back off and route through the shared YAML action pipeline,
/// matching the sibling Stroke / Swatches panels.
public enum BrushesPanel {
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("brushes_panel_content")
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr,
                                layout: inout WorkspaceLayout,
                                model: Model? = nil) {
        if cmd == "close_panel" { layoutApply(&layout, opClosePanel(addr)); return }
        guard let model = model else { return }
        // Param-folded radio rows: split "<action>:<value>" and run the
        // underlying YAML action with the declared param key, so both panel
        // state and any downstream effects update — matching the in-panel
        // controls and the sibling Stroke / Swatches dispatch.
        if let v = strip(cmd, prefix: "set_brush_view_mode:") {
            runYamlActionByName("set_brush_view_mode", params: ["view_mode": v], model: model)
            return
        }
        if let v = strip(cmd, prefix: "set_brush_thumbnail_size:") {
            runYamlActionByName("set_brush_thumbnail_size", params: ["size": v], model: model)
            return
        }
        if let v = strip(cmd, prefix: "toggle_brush_category:") {
            runYamlActionByName("toggle_brush_category", params: ["type": v], model: model)
            return
        }
        if let v = strip(cmd, prefix: "open_brush_options:") {
            runYamlActionByName("open_brush_options", params: ["mode": v], model: model)
            return
        }
        // "Open Brush Library" is a disabled placeholder (no YAML action),
        // so its command is empty — nothing to dispatch.
        guard !cmd.isEmpty else { return }
        runYamlActionByName(cmd, params: [:], model: model)
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }

    /// Variant with the model in scope so the view-mode / thumbnail-size /
    /// category radios render their checkmark from the Brushes panel state,
    /// matching the YAML `checked_when` expressions.
    public static func isCheckedWithModel(_ cmd: String, model: Model?) -> Bool {
        guard let model = model else { return false }
        let pid = "brushes_panel_content"
        if let v = strip(cmd, prefix: "set_brush_view_mode:") {
            return (model.stateStore.getPanel(pid, "view_mode") as? String) == v
        }
        if let v = strip(cmd, prefix: "set_brush_thumbnail_size:") {
            return (model.stateStore.getPanel(pid, "thumbnail_size") as? String) == v
        }
        if let v = strip(cmd, prefix: "toggle_brush_category:") {
            if let arr = model.stateStore.getPanel(pid, "category_filter") as? [Any] {
                return arr.contains { ($0 as? String) == v }
            }
            return false
        }
        return false
    }

    private static func strip(_ s: String, prefix: String) -> String? {
        s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : nil
    }
}
