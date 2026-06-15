/// Stroke panel menu definition.

public enum StrokePanel {
    /// Source of truth is workspace/panels/stroke.yaml's `menu:` block
    /// (review #15); the generic reader builds the items from the bundle.
    /// The cap/join radio rows share one YAML action each
    /// (`set_stroke_cap` / `set_stroke_join`), so the builder folds each
    /// `params.cap` / `params.join` into the command
    /// (`set_stroke_cap:butt`, …); `dispatch` / `isCheckedWithModel`
    /// split that suffix back off.
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("stroke_panel_content")
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr,
                                layout: inout WorkspaceLayout,
                                model: Model? = nil) {
        if cmd == "close_panel" { layout.closePanel(addr); return }
        // Cap/join radios arrive param-folded from the generic menu
        // builder (`set_stroke_cap:round`); split the value back off and
        // route through the YAML action so both panel state (panel.cap)
        // and global state (stroke_cap, which propagates to the
        // selection) update — matching the in-panel cap/join buttons.
        guard let model = model else { return }
        if let cap = strip(cmd, prefix: "set_stroke_cap:") {
            runYamlActionByName("set_stroke_cap", params: ["cap": cap], model: model)
            return
        }
        if let join = strip(cmd, prefix: "set_stroke_join:") {
            runYamlActionByName("set_stroke_join", params: ["join": join], model: model)
            return
        }
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }

    /// Variant with the model in scope so the cap/join radio buttons can
    /// render their checkmark from the Stroke panel state (`panel.cap` /
    /// `panel.join`), matching the YAML `checked_when` expressions.
    public static func isCheckedWithModel(_ cmd: String, model: Model?) -> Bool {
        guard let model = model else { return false }
        let pid = "stroke_panel_content"
        if let cap = strip(cmd, prefix: "set_stroke_cap:") {
            return (model.stateStore.getPanel(pid, "cap") as? String) == cap
        }
        if let join = strip(cmd, prefix: "set_stroke_join:") {
            return (model.stateStore.getPanel(pid, "join") as? String) == join
        }
        return false
    }

    private static func strip(_ s: String, prefix: String) -> String? {
        s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : nil
    }
}
