/// Paragraph panel menu definition. Mirrors the yaml-side menu in
/// `workspace/panels/paragraph.yaml`. The Hanging Punctuation toggle
/// flips `panel.hanging_punctuation` and writes
/// `jas:hanging-punctuation` on every paragraph wrapper tspan in the
/// selection (omitted when toggled off, identity rule). Reset Panel
/// restores every Paragraph control to its default and removes the
/// corresponding paragraph attributes from the selection.

public enum ParagraphPanel {
    /// Source of truth is workspace/panels/paragraph.yaml's `menu:`
    /// block (review #15); the generic reader builds the items from the
    /// bundle.
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("paragraph_panel_content")
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr,
                                layout: inout WorkspaceLayout,
                                model: Model? = nil) {
        switch cmd {
        case "close_panel":
            layoutApply(&layout, opClosePanel(addr))
        case "toggle_hanging_punctuation":
            guard let model = model else { return }
            // Sync from selection so untouched fields keep current
            // values, then flip hanging_punctuation in panel state and
            // re-apply (the apply commits the flag onto the wrapper).
            let pid = "paragraph_panel_content"
            let store = model.stateStore
            if !store.hasPanel(pid),
               let ws = WorkspaceData.load() {
                store.initPanel(pid, defaults: ws.panelStateDefaults(pid))
            }
            let overrides = paragraphPanelLiveOverrides(model: model)
            for (k, v) in overrides { store.setPanel(pid, k, v) }
            let cur = (store.getPanel(pid, "hanging_punctuation") as? Bool) ?? false
            store.setPanel(pid, "hanging_punctuation", !cur)
            applyParagraphPanelToSelection(
                store: store, controller: Controller(model: model))
        case "reset_paragraph_panel":
            guard let model = model else { return }
            let pid = "paragraph_panel_content"
            let store = model.stateStore
            if !store.hasPanel(pid),
               let ws = WorkspaceData.load() {
                store.initPanel(pid, defaults: ws.panelStateDefaults(pid))
            }
            resetParagraphPanel(store: store, controller: Controller(model: model))
        case "open_paragraph_justification":
            // Open the Justification dialog. The DockPanelView dispatch
            // wrapper compares store.getDialogId() before/after and
            // bridges the change to the SwiftUI overlay binding.
            guard let model = model, let ws = WorkspaceData.load() else { return }
            let store = model.stateStore
            store.initDialog("paragraph_justification",
                              defaults: ws.dialogStateDefaults("paragraph_justification"))
        case "open_paragraph_hyphenation":
            guard let model = model, let ws = WorkspaceData.load() else { return }
            let store = model.stateStore
            store.initDialog("paragraph_hyphenation",
                              defaults: ws.dialogStateDefaults("paragraph_hyphenation"))
        default:
            break
        }
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }

    /// Variant that consults the model's StateStore so the
    /// Hanging Punctuation toggle can render its menu checkmark
    /// from `panel.hanging_punctuation`. Mirrors the Rust
    /// `paragraph_panel::is_checked` path.
    public static func isCheckedWithModel(_ cmd: String, model: Model?) -> Bool {
        guard let model = model else { return false }
        switch cmd {
        case "toggle_hanging_punctuation":
            let pid = "paragraph_panel_content"
            return (model.stateStore.getPanel(pid, "hanging_punctuation") as? Bool) ?? false
        default:
            return false
        }
    }
}
