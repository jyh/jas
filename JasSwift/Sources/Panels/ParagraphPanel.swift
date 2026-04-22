/// Paragraph panel menu definition. Mirrors the yaml-side menu in
/// `workspace/panels/paragraph.yaml`. The Hanging Punctuation toggle
/// flips `panel.hanging_punctuation` and writes
/// `jas:hanging-punctuation` on every paragraph wrapper tspan in the
/// selection (omitted when toggled off, identity rule). Reset Panel
/// restores every Paragraph control to its default and removes the
/// corresponding paragraph attributes from the selection.

public enum ParagraphPanel {
    public static func menuItems() -> [PanelMenuItem] {
        [
            .toggle(label: "Hanging Punctuation", command: "toggle_hanging_punctuation"),
            .separator,
            .action(label: "Justification…", command: "open_paragraph_justification"),
            .action(label: "Hyphenation…", command: "open_paragraph_hyphenation"),
            .separator,
            .action(label: "Reset Panel", command: "reset_paragraph_panel"),
            .separator,
            .action(label: "Close Paragraph", command: "close_panel"),
        ]
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr,
                                layout: inout WorkspaceLayout,
                                model: Model? = nil) {
        switch cmd {
        case "close_panel":
            layout.closePanel(addr)
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
        default:
            // Justification / Hyphenation dialog launchers land with
            // their respective dialog wirings in Phase 8 / 9.
            break
        }
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        // Mirror toggles read from the StateStore not from
        // WorkspaceLayout — the yaml-bind-style `checked: panel.*` is
        // handled by the menu-item closure that calls
        // `panelIsChecked` with model context. Until that read path
        // is threaded through, the menu checkmark is rendered by the
        // dock view's per-frame StateStore lookup elsewhere.
        false
    }
}
