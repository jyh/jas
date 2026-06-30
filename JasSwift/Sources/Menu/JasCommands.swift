import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - FocusedValue for model access from commands

public struct FocusedModelKey: FocusedValueKey {
    public typealias Value = Model
}

public struct FocusedHasSelectionKey: FocusedValueKey {
    public typealias Value = Bool
}

public struct FocusedCanUndoKey: FocusedValueKey {
    public typealias Value = Bool
}

public struct FocusedCanRedoKey: FocusedValueKey {
    public typealias Value = Bool
}

public struct FocusedAddCanvasKey: FocusedValueKey {
    public typealias Value = (Model) -> Void
}

public struct FocusedWorkspaceKey: FocusedValueKey {
    public typealias Value = WorkspaceState
}

public struct FocusedActiveAppearanceKey: FocusedValueKey {
    public typealias Value = String
}

/// Closure that opens a YAML dialog by id. Published from ContentView
/// so JasCommands menu items can route to dialogs without owning the
/// dialog-state binding directly.
public struct FocusedOpenYamlDialogKey: FocusedValueKey {
    public typealias Value = (String) -> Void
}

public extension FocusedValues {
    var workspace: WorkspaceState? {
        get { self[FocusedWorkspaceKey.self] }
        set { self[FocusedWorkspaceKey.self] = newValue }
    }
    var jasModel: Model? {
        get { self[FocusedModelKey.self] }
        set { self[FocusedModelKey.self] = newValue }
    }
    var hasSelection: Bool? {
        get { self[FocusedHasSelectionKey.self] }
        set { self[FocusedHasSelectionKey.self] = newValue }
    }
    var canUndo: Bool? {
        get { self[FocusedCanUndoKey.self] }
        set { self[FocusedCanUndoKey.self] = newValue }
    }
    var canRedo: Bool? {
        get { self[FocusedCanRedoKey.self] }
        set { self[FocusedCanRedoKey.self] = newValue }
    }
    var addCanvas: ((Model) -> Void)? {
        get { self[FocusedAddCanvasKey.self] }
        set { self[FocusedAddCanvasKey.self] = newValue }
    }
    var activeAppearance: String? {
        get { self[FocusedActiveAppearanceKey.self] }
        set { self[FocusedActiveAppearanceKey.self] = newValue }
    }
    var openYamlDialog: ((String) -> Void)? {
        get { self[FocusedOpenYamlDialogKey.self] }
        set { self[FocusedOpenYamlDialogKey.self] = newValue }
    }
}

/// Custom menu commands for Jas app (File, Edit, View menus).
public struct JasCommands: Commands {
    @FocusedValue(\.jasModel) private var model
    @FocusedValue(\.hasSelection) private var hasSelection
    @FocusedValue(\.canUndo) private var canUndo
    @FocusedValue(\.canRedo) private var canRedo
    @FocusedValue(\.addCanvas) private var addCanvas
    @FocusedValue(\.workspace) private var workspace
    @FocusedValue(\.activeAppearance) private var activeAppearanceName
    @FocusedValue(\.openYamlDialog) private var openYamlDialog

    public init() {}

    /// Top menu-bar entries projected from the compiled bundle `menubar`
    /// (menubar.yaml) — the single source of truth. The five top-level
    /// menus map onto macOS's fixed Commands DSL slots (File → newItem +
    /// saveItem, Edit → undoRedo + pasteboard, Object → CommandMenu, View →
    /// toolbar, Window → windowList): macOS pins these system slots, so the
    /// shells are static while their CONTENTS `ForEach` the projected
    /// entries. Mirrors the Rust reference `menu_bar.rs` (which projects the
    /// same model, then renders it).
    private var model_menus: [MenuModel] { menuBarModel() }

    /// Entries for one top-level menu by its bundle label, or `[]` if absent.
    private func entries(for label: String) -> [MenuEntry] {
        model_menus.first { $0.label == label }?.entries ?? []
    }

    public var body: some Commands {
        // File menu. macOS splits the File menu across two fixed slots:
        // `.newItem` (where New / Open live) and `.saveItem` (Save … Quit).
        // The bundle has one flat File list; we render its leading New/Open
        // pair into `.newItem` and the remainder into `.saveItem`. Splitting
        // by action keeps the projection authoritative without inventing a
        // second bundle menu.
        CommandGroup(replacing: .newItem) {
            renderEntries(entries(for: "&File").filter { isFileNewItem($0) })
        }
        CommandGroup(replacing: .saveItem) {
            renderEntries(entries(for: "&File").filter { !isFileNewItem($0) })
        }

        // Edit menu → undoRedo (Undo/Redo) + pasteboard (Cut … Select All).
        CommandGroup(replacing: .undoRedo) {
            renderEntries(entries(for: "&Edit").filter { isEditUndoRedo($0) })
        }
        CommandGroup(replacing: .pasteboard) {
            renderEntries(entries(for: "&Edit").filter { !isEditUndoRedo($0) })
        }

        // Object menu → its own CommandMenu (no fixed system slot).
        CommandMenu("Object") {
            renderEntries(entries(for: "&Object"))
        }

        // View menu → the `.toolbar` slot (zoom + fit items).
        CommandGroup(replacing: .toolbar) {
            renderEntries(entries(for: "&View"))
        }

        // Window menu → `.windowList`. The dynamic Workspace / Appearance
        // submenus stay bespoke (runtime-populated); the projected entries
        // (Tile, pane toggles, panel toggles) flow through renderEntries.
        CommandGroup(replacing: .windowList) {
            renderWindowEntries(entries(for: "&Window"))
        }
    }

    /// The File entries that belong in the `.newItem` slot (New, Open): the
    /// leading run of actions before the first separator. Everything after
    /// (Save, Save As, Revert, Document Setup, Print, Export, Quit) goes in
    /// `.saveItem`.
    private func isFileNewItem(_ entry: MenuEntry) -> Bool {
        if case .action(_, let action, _, _, _, _) = entry {
            return action == "new_document" || action == "open_file"
        }
        return false
    }

    /// The Edit entries that belong in the `.undoRedo` slot (Undo, Redo).
    private func isEditUndoRedo(_ entry: MenuEntry) -> Bool {
        if case .action(_, let action, _, _, _, _) = entry {
            return action == "undo" || action == "redo"
        }
        return false
    }

    /// Render a flat list of projected entries (separators + actions) into
    /// the SwiftUI Commands DSL. Mixing `Divider` and `Button` from one list
    /// is the main DSL friction; emitting one view per entry (separator →
    /// `Divider`, action → `Button`) keeps it inside a single `ForEach`.
    @ViewBuilder
    private func renderEntries(_ entries: [MenuEntry]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            entryView(entry)
        }
    }

    /// Window menu renderer: like ``renderEntries`` but routes
    /// `.dynamicSubmenu` entries to the bespoke Workspace / Appearance
    /// builders (runtime-populated, with check-mark machinery) and gates the
    /// whole dynamic block + pane toggles behind a live `workspace`.
    @ViewBuilder
    private func renderWindowEntries(_ entries: [MenuEntry]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            windowEntryView(entry)
        }
    }

    /// A single non-Window entry → its SwiftUI view. Mnemonic markers are
    /// stripped for display (macOS has no `&` mnemonics); the shortcut is
    /// parsed from the bundle string; the enabled / checked state is driven by
    /// the bundle `enabled_when` / `checked_when` predicates, evaluated through
    /// the shared expression evaluator against the live menu ctx (the same
    /// evaluation the cross-app `menu_state` gate pins).
    @ViewBuilder
    private func entryView(_ entry: MenuEntry) -> some View {
        switch entry {
        case .separator:
            Divider()
        case .dynamicSubmenu:
            // No dynamic submenus outside Window today; render nothing.
            EmptyView()
        case .action(let label, let action, let params, let shortcut,
                     let enabledWhen, let checkedWhen):
            actionButton(label: label, action: action, params: params,
                         shortcut: shortcut, enabledWhen: enabledWhen,
                         checkedWhen: checkedWhen)
        }
    }

    /// A single Window-menu entry → its SwiftUI view, including the bespoke
    /// dynamic submenus.
    @ViewBuilder
    private func windowEntryView(_ entry: MenuEntry) -> some View {
        switch entry {
        case .separator:
            Divider()
        case .dynamicSubmenu(_, let kind):
            switch kind {
            case .workspace: workspaceSubmenu()
            case .appearance: appearanceSubmenu()
            }
        case .action(let label, let action, let params, let shortcut,
                     let enabledWhen, let checkedWhen):
            actionButton(label: label, action: action, params: params,
                         shortcut: shortcut, enabledWhen: enabledWhen,
                         checkedWhen: checkedWhen)
        }
    }

    /// Build one action Button: stripped label (+ check-mark prefix when a
    /// `checked_when` predicate evaluates true), parsed keyboard shortcut, the
    /// `enabled_when`-driven disabled state, and the dispatch to the bespoke
    /// handler / generic route. `enabled_when` / `checked_when` are evaluated
    /// through the shared expression evaluator against ``menuCtx`` — the SAME
    /// evaluation the cross-app `menu_state` gate pins (so per-item enabled /
    /// checked equals ``MenuState/menuState(_:_:)`` by construction). SwiftUI
    /// re-renders the menu body reactively (focused model / selection / undo
    /// signals), so evaluating inline keeps the grays-out / check-mark state
    /// live. Mirrors the Python jas `_sync_menu`.
    @ViewBuilder
    private func actionButton(label: String, action: String,
                              params: [String: Any], shortcut: String,
                              enabledWhen: String?, checkedWhen: String?) -> some View {
        let ctx = menuCtx
        let display = stripMnemonic(label)
        // checked_when present (non-empty) → drive the check-mark prefix from
        // its evaluated bool (✓ for true, aligned spaces for false, keeping
        // unchecked rows flush with checked ones). Absent → no prefix. This is
        // exactly MenuState's `checked` projection (null when absent).
        let prefix: String? = checkedWhen.flatMap { cw in
            cw.isEmpty ? nil
                : (evaluate(cw, context: ctx).toBool() ? "\u{2713} " : "    ")
        }
        let prefixed = prefix.map { $0 + display } ?? display
        // enabled_when present (non-empty) → evaluate it; absent → enabled
        // (matches MenuState's `enabled` default).
        let enabled: Bool = {
            guard let ew = enabledWhen, !ew.isEmpty else { return true }
            return evaluate(ew, context: ctx).toBool()
        }()
        let btn = Button(prefixed) {
            dispatchMenuAction(action, params: params)
        }
        .disabled(!enabled)
        if let parsed = parseShortcut(shortcut) {
            btn.keyboardShortcut(KeyEquivalent(parsed.key), modifiers: parsed.modifiers)
        } else {
            btn
        }
    }

    /// The menu evaluation context (TESTING_STRATEGY.md chrome seam): the exact
    /// namespaces the bundle `enabled_when` / `checked_when` predicates read,
    /// built from the live focused model + workspace. Delegates to the testable
    /// free function ``buildMenuContext(model:tabCount:hasSelection:canUndo:canRedo:workspace:)``.
    private var menuCtx: [String: Any] {
        buildMenuContext(model: model, tabCount: workspace?.canvases.count ?? 0,
                         hasSelection: hasSelection, canUndo: canUndo,
                         canRedo: canRedo, workspace: workspace)
    }

    /// Dispatch a bundle action to the EXISTING bespoke handler or generic
    /// route. Every historical handler (file dialogs, clipboard, orphan
    /// NSAlert, withTxn bracketing, dynamic-submenu helpers) is preserved
    /// verbatim — only the DATA SOURCE + wiring changed. Mirrors the Rust
    /// reference `menu_bar.rs` dispatch.
    private func dispatchMenuAction(_ action: String, params: [String: Any]) {
        switch action {
        // File
        case "new_document":
            // Document() defaults artboards: []; newEmptyDocument() seeds the
            // at-least-one-artboard invariant so the new canvas isn't a
            // featureless white plane.
            addCanvas?(Model(document: Document.newEmptyDocument()))
        case "open_file":
            openFile()
        case "save":
            save()
        case "save_as":
            saveAs()
        case "revert":
            revert()
        case "open_document_setup":
            openYamlDialog?("document_setup")
        case "open_print_dialog":
            openYamlDialog?("print")
        case "export_to_pdf":
            exportToPdf()
        case "quit":
            // Genuinely-new File action: terminate the app (no bespoke
            // handler existed before — the menu had no Quit item).
            NSApplication.shared.terminate(nil)
        // Edit
        case "undo":
            model?.undo()
        case "redo":
            model?.redo()
        case "cut":
            cutSelection()
        case "copy":
            copySelection()
        case "paste":
            pasteClipboard(offset: pasteOffset)
        case "paste_in_place":
            pasteClipboard(offset: 0.0)
        case "select_all":
            selectAll()
        // Object
        case "group":
            groupSelection()
        case "ungroup":
            ungroupSelection()
        case "ungroup_all":
            ungroupAll()
        case "lock":
            lockSelection()
        case "unlock_all":
            unlockAll()
        case "hide_selection":
            hideSelection()
        case "show_all":
            showAll()
        case "make_instance":
            makeInstance()
        case "promote_to_concept":
            // CONCEPTS.md §10 — the fitter / promote. New menu route to the
            // existing ConceptsPanel intercept (was only reachable from the
            // panel before). No-op unless exactly one element is selected
            // (the native enabled predicate already gates the menu item).
            guard let model = model else { return }
            ConceptsPanel.dispatch("promote_to_concept", model: model)
        // View
        case "zoom_in":
            model?.zoomIn()
        case "zoom_out":
            model?.zoomOut()
        case "zoom_to_actual_size":
            model?.zoomToActualSize()
        case "fit_active_artboard":
            model?.fitActiveArtboard()
        case "fit_all_artboards":
            model?.fitAllArtboards()
        case "fit_in_window":
            model?.fitInWindow()
        // Window
        case "tile_panes":
            guard let ws = workspace else { return }
            // OP_LOG 3d-2: dispatch through the shared layout-op runtime.
            // Swift's menu Tile neither clears canvas maximization nor
            // applies a collapsed-dock override, so both params are omitted —
            // byte-identical to the prior `pl.tilePanes(collapsedOverride:
            // nil)` call and matching the bare corpus `tile_panes` path.
            layoutApply(&ws.workspaceLayout,
                        opTilePanes(setCanvasMaximized: nil, overridePane: nil))
            ws.workspaceLayout.saveIfNeeded()
        case "toggle_pane":
            guard let ws = workspace,
                  let paneId = params["pane"] as? String,
                  let kind = paneKindForId(paneId) else { return }
            // OP_LOG 3d-2: resolve live visibility against the pane layout,
            // then dispatch hide/show through the shared layout-op runtime
            // (only when a pane layout exists, matching the prior `panesMut`
            // guard). Byte-identical to the prior `paneToggle` body.
            if let visibleNow = ws.workspaceLayout.panes()?.isPaneVisible(kind) {
                let op = visibleNow ? opHidePane(kind) : opShowPane(kind)
                layoutApply(&ws.workspaceLayout, op)
            }
            ws.workspaceLayout.saveIfNeeded()
        case "toggle_panel":
            guard let ws = workspace,
                  let panelId = params["panel"] as? String else { return }
            guard let kind = panelKindForMenuId(panelId) else {
                // `concepts` has NO PanelKind case (the Concepts panel is not
                // wired into the dock/PanelKind layout in this app), so the
                // toggle is a graceful no-op here — special-cased like Rust's
                // `toggle_panel_concepts`, but Swift has no panel to show yet.
                return
            }
            // OP_LOG 3d-2: dispatch close/show through the shared layout-op
            // runtime. Byte-identical to the prior `panelToggle` body.
            if ws.workspaceLayout.isPanelVisible(kind) {
                if let addr = findPanel(ws.workspaceLayout, kind) {
                    layoutApply(&ws.workspaceLayout, opClosePanel(addr))
                }
            } else {
                layoutApply(&ws.workspaceLayout, opShowPanel(kind))
            }
            ws.workspaceLayout.saveIfNeeded()
        default:
            break
        }
    }

    /// The bespoke dynamic Workspace submenu (runtime-populated, with the
    /// active-layout check mark + Save As / Reset / Revert). Unchanged from
    /// the prior native version; only its trigger moved to a `.dynamicSubmenu`
    /// projected entry.
    @ViewBuilder
    private func workspaceSubmenu() -> some View {
        SwiftUI.Group {
            if let ws = workspace {
                Menu("Workspace \u{25B6}") {
                    let visibleLayouts = ws.appConfig.savedLayouts.filter { $0 != workspaceLayoutName }
                    ForEach(visibleLayouts, id: \.self) { name in
                        let isActive = name == ws.appConfig.activeLayout
                        let prefix = isActive ? "\u{2713} " : "    "
                        Button(prefix + name) {
                            ws.switchLayout(name)
                        }
                    }

                    Divider()

                    Button("Save As\u{2026}") {
                        let alert = NSAlert()
                        alert.messageText = "Save Workspace As"
                        alert.informativeText = "Enter a name for the workspace:"
                        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
                        let prefill = ws.appConfig.activeLayout != workspaceLayoutName
                            ? ws.appConfig.activeLayout : ""
                        input.stringValue = prefill
                        input.placeholderString = "Workspace name"
                        alert.accessoryView = input
                        alert.addButton(withTitle: "Save")
                        alert.addButton(withTitle: "Cancel")
                        alert.window.initialFirstResponder = input
                        let response = alert.runModal()
                        if response == .alertFirstButtonReturn {
                            let name = input.stringValue.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            // Reject "Workspace" name
                            if name.caseInsensitiveCompare(workspaceLayoutName) == .orderedSame {
                                let info = NSAlert()
                                info.messageText = "\u{201C}Workspace\u{201D} is a system workspace that is saved automatically."
                                info.addButton(withTitle: "OK")
                                info.runModal()
                                return
                            }
                            // Confirm overwrite
                            if ws.appConfig.savedLayouts.contains(name) {
                                let confirm = NSAlert()
                                confirm.messageText = "Layout \u{201C}\(name)\u{201D} already exists. Overwrite?"
                                confirm.addButton(withTitle: "Overwrite")
                                confirm.addButton(withTitle: "Cancel")
                                let confirmResponse = confirm.runModal()
                                guard confirmResponse == .alertFirstButtonReturn else { return }
                            }
                            ws.saveLayoutAs(name)
                        }
                    }

                    Divider()

                    Button("Reset to Default") {
                        ws.resetToDefault()
                    }

                    Button("Revert to Saved") {
                        ws.revertToSaved()
                    }
                    .disabled(ws.appConfig.activeLayout == workspaceLayoutName)
                }
            }
        }
    }

    /// The bespoke dynamic Appearance submenu (runtime-populated, with the
    /// active-appearance check mark). Unchanged from the prior native version;
    /// only its trigger moved to a `.dynamicSubmenu` projected entry.
    @ViewBuilder
    private func appearanceSubmenu() -> some View {
        if let ws = workspace {
            Menu("Appearance \u{25B6}") {
                ForEach(predefinedAppearances, id: \.name) { entry in
                    let isActive = entry.name == (activeAppearanceName ?? "dark_gray")
                    let prefix = isActive ? "\u{2713} " : "    "
                    Button(prefix + entry.label) {
                        ws.switchAppearance(entry.name)
                    }
                }
            }
        }
    }

    private func findPanel(_ layout: WorkspaceLayout, _ kind: PanelKind) -> PanelAddr? {
        for (_, dock) in layout.anchored {
            for (gi, group) in dock.groups.enumerated() {
                if let pi = group.panels.firstIndex(of: kind) {
                    return PanelAddr(group: GroupAddr(dockId: dock.id, groupIdx: gi), panelIdx: pi)
                }
            }
        }
        for fd in layout.floating {
            for (gi, group) in fd.dock.groups.enumerated() {
                if let pi = group.panels.firstIndex(of: kind) {
                    return PanelAddr(group: GroupAddr(dockId: fd.dock.id, groupIdx: gi), panelIdx: pi)
                }
            }
        }
        return nil
    }

    private func save() {
        guard let model = model else { return }
        JasCommands.saveModel(model)
    }

    /// Save a model to disk (named file) or present Save As for untitled.
    /// Shared between JasCommands menu and ContentView close-tab prompt.
    public static func saveModel(_ model: Model) {
        if model.filename.hasPrefix("Untitled-") {
            saveModelAs(model)
            return
        }
        let svg = documentToSvg(model.document)
        do {
            try svg.write(toFile: model.filename, atomically: true, encoding: .utf8)
            model.markSaved()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.title = "Open"
        panel.allowedContentTypes = [.svg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? Int, size > 100 * 1024 * 1024 {
                let alert = NSAlert()
                alert.messageText = "File too large (over 100 MB)."
                alert.alertStyle = .critical
                alert.runModal()
                return
            }
            let svg = try String(contentsOf: url, encoding: .utf8)
            let newModel = Model(document: svgToDocument(svg), filename: url.path)
            addCanvas?(newModel)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private func saveAs() {
        guard let model = model else { return }
        JasCommands.saveModelAs(model)
    }

    /// Present Save As panel and save to chosen location.
    public static func saveModelAs(_ model: Model) {
        let panel = NSSavePanel()
        panel.title = "Save As"
        panel.nameFieldStringValue = (model.filename as NSString).lastPathComponent
        panel.allowedContentTypes = [.svg]
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let svg = documentToSvg(model.document)
        do {
            try svg.write(to: url, atomically: true, encoding: .utf8)
            model.markSaved()
            model.filename = url.path
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private func exportToPdf() {
        guard let model = model else { return }
        let bytes = documentToPdf(model.document)
        let panel = NSSavePanel()
        panel.title = "Export to PDF"
        panel.nameFieldStringValue = pdfFilenameForModel(model)
        panel.allowedContentTypes = [.pdf]
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try bytes.write(to: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private func revert() {
        guard let model = model,
              model.isModified,
              !model.filename.hasPrefix("Untitled-") else { return }
        let alert = NSAlert()
        alert.messageText = "Revert to the saved version of \"\(model.filename)\"?"
        alert.informativeText = "All current modifications will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: model.filename)
            if let size = attrs[.size] as? Int, size > 100 * 1024 * 1024 {
                let alert = NSAlert()
                alert.messageText = "File too large (over 100 MB)."
                alert.alertStyle = .critical
                alert.runModal()
                return
            }
            let svg = try String(contentsOfFile: model.filename, encoding: .utf8)
            let newDoc = svgToDocument(svg)
            // Undoable revert: editDocument self-brackets one undo step.
            model.editDocument(newDoc)
            model.markSaved()
        } catch {
            let errAlert = NSAlert(error: error)
            errAlert.runModal()
        }
    }

    private func translateElement(_ elem: Element, dx: Double, dy: Double) -> Element {
        if dx == 0 && dy == 0 { return elem }
        switch elem {
        case .group(let g):
            return .group(Group(children: g.children.map { translateElement($0, dx: dx, dy: dy) },
                                opacity: g.opacity, transform: g.transform, locked: g.locked))
        case .layer(let l):
            return .layer(Layer(name: l.name,
                                children: l.children.map { translateElement($0, dx: dx, dy: dy) },
                                opacity: l.opacity, transform: l.transform, locked: l.locked))
        default:
            return elem.moveControlPoints(.all, dx: dx, dy: dy)
        }
    }

    private func isSvg(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("<?xml") || s.hasPrefix("<svg")
    }

    private func pasteClipboard(offset: Double) {
        guard let model = model else { return }
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        let doc = model.document
        var newSelection: Selection = []

        if isSvg(text) {
            let pastedDoc = svgToDocument(text)
            var newLayers = doc.layers
            for pastedLayer in pastedDoc.layers {
                let children = pastedLayer.children.map { translateElement($0, dx: offset, dy: offset) }
                guard !children.isEmpty else { continue }
                // Find matching layer by name
                var targetIdx: Int?
                if let pastedName = pastedLayer.name, !pastedName.isEmpty {
                    for i in 0..<newLayers.count {
                        if newLayers[i].name == pastedName {
                            targetIdx = i
                            break
                        }
                    }
                }
                let idx = targetIdx ?? doc.selectedLayer
                // Record paths for pasted elements (appended at end)
                let base = newLayers[idx].children.count
                for (j, _) in children.enumerated() {
                    let path: ElementPath = [idx, base + j]
                    newSelection.insert(ElementSelection.all(path))
                }
                newLayers[idx] = Layer(name: newLayers[idx].name,
                                          children: newLayers[idx].children + children,
                                          opacity: newLayers[idx].opacity,
                                          transform: newLayers[idx].transform)
            }
            // Use `replacing(...)` so artboards / artboardOptions /
            // documentSetup / printPreferences are preserved. The
            // designated `Document(layers:...)` initializer's empty
            // defaults silently drop unset fields — the comment on
            // `Document.replacing` calls this out as the bug that made
            // the artboard frame disappear after a selection mutation.
            // Undoable paste: editDocument self-brackets one undo step.
            model.editDocument(doc.replacing(layers: newLayers, selection: newSelection))
        } else {
            // Plain text: create a Text element
            let elem = Element.text(Text(x: offset, y: offset + 16.0, content: text))
            let idx = doc.selectedLayer
            let path: ElementPath = [idx, doc.layers[idx].children.count]
            newSelection.insert(ElementSelection.all(path))
            var newLayers = doc.layers
            newLayers[idx] = Layer(name: newLayers[idx].name,
                                      children: newLayers[idx].children + [elem],
                                      opacity: newLayers[idx].opacity,
                                      transform: newLayers[idx].transform)
            // Same `replacing(...)` pattern — preserves artboards.
            model.editDocument(doc.replacing(layers: newLayers, selection: newSelection))
        }
    }

    private func groupSelection() {
        guard let model = model else { return }
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        // withTxn opens ONE bracket; the Controller mutator's editDocument joins
        // it (one undo step). Mirrors Rust's with_txn { Controller::... }.
        let controller = Controller(model: model)
        model.withTxn { controller.groupSelection() }
    }

    /// "Make Instance": the first user-facing way to create a live
    /// reference. Native UI glue (NOT a Controller op) that composes two
    /// already-pinned ops under ONE snapshot: `createReference` (the UI
    /// mints `targetId`/`refId`, value-in-op, with a collision-retry loop
    /// over existing ids — never minted in a Controller) then a move of
    /// the now-selected reference by `(pasteOffset, pasteOffset)`. The
    /// offset rides on the new reference's transform via `moveSelection`.
    /// Enabled only when exactly ONE whole element (kind=.all; not a
    /// control-point sub-selection) is selected. Mirrors Rust's
    /// `make_instance` menu_bar dispatch.
    private func makeInstance() {
        guard let model = model else { return }
        let doc = model.document
        // `Selection` is a Set; sort by path lexicographically so the
        // single-selection pick is deterministic.
        let sorted = doc.selection.sorted {
            $0.path.lexicographicallyPrecedes($1.path)
        }
        guard sorted.count == 1, let es = sorted.first else { return }
        guard es.kind == .all else { return }
        let targetPath = es.path
        // Gather every existing element id so the freshly minted
        // targetId / refId can avoid collisions.
        var existing: Set<String> = []
        func gatherIds(_ elem: Element) {
            if let id = elem.id { existing.insert(id) }
            switch elem {
            case .group(let g): for c in g.children { gatherIds(c) }
            case .layer(let l): for c in l.children { gatherIds(c) }
            default: break
            }
        }
        for layer in doc.layers { gatherIds(.layer(layer)) }
        // Mint two distinct, collision-free ids (mirrors the artboard
        // mint loop in LayersPanel).
        func mint() -> String? {
            for _ in 0..<100 {
                let c = generateElementId()
                if !existing.contains(c) { return c }
            }
            return nil
        }
        guard let targetId = mint() else { return }
        existing.insert(targetId)
        guard let refId = mint() else { return }
        // createReference + offset-move under ONE snapshot = a single
        // undo step (offset rides on the new reference's transform via
        // moveSelection).
        // Both ops join ONE withTxn bracket = a single undo step (each
        // Controller mutator's editDocument joins it). Mirrors Rust's
        // with_txn around make_instance's two ops.
        let controller = Controller(model: model)
        model.withTxn {
            controller.createReference(targetPath, targetId: targetId, refId: refId)
            controller.moveSelection(dx: pasteOffset, dy: pasteOffset)
        }
    }

    private func ungroupSelection() {
        guard let model = model else { return }
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        let controller = Controller(model: model)
        model.withTxn { controller.ungroupSelection() }
    }

    private func ungroupAll() {
        guard let model = model else { return }
        let doc = model.document
        var changed = false

        func flatten(_ children: [Element]) -> [Element] {
            var result: [Element] = []
            for child in children {
                switch child {
                case .group(let g) where !g.locked:
                    changed = true
                    result.append(contentsOf: flatten(g.children))
                case .group(let g):
                    // Locked group: recurse into children but keep the group
                    let newChildren = flatten(g.children)
                    result.append(.group(Group(children: newChildren,
                                               opacity: g.opacity, transform: g.transform,
                                               locked: g.locked)))
                default:
                    result.append(child)
                }
            }
            return result
        }

        let newLayers = doc.layers.map { layer in
            let newChildren = flatten(layer.children)
            return Layer(name: layer.name, children: newChildren,
                         opacity: layer.opacity, transform: layer.transform,
                         locked: layer.locked)
        }
        guard changed else { return }
        // Undoable: editDocument self-brackets one undo step.
        model.editDocument(Document(layers: newLayers,
                                  selectedLayer: doc.selectedLayer, selection: []))
    }

    private func lockSelection() {
        guard let model = model else { return }
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        let controller = Controller(model: model)
        model.withTxn { controller.lockSelection() }
    }

    private func unlockAll() {
        guard let model = model else { return }
        let controller = Controller(model: model)
        model.withTxn { controller.unlockAll() }
    }

    private func hideSelection() {
        guard let model = model else { return }
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        let controller = Controller(model: model)
        model.withTxn { controller.hideSelection() }
    }

    private func showAll() {
        guard let model = model else { return }
        let controller = Controller(model: model)
        model.withTxn { controller.showAll() }
    }

    private func deleteSelection() {
        guard let model = model else { return }
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        // Reference-aware delete (warn-then-orphan): if deleting the selection
        // would leave live instances pointing at a now-gone target, confirm
        // first. Empty -> delete as today (no dialog). Cut is intentionally
        // left unguarded for now (it may orphan silently — follow-on work).
        let paths = doc.selection.map(\.path)
        let orphaned = DependencyIndex.orphanedReferences(doc, paths)
        if !orphaned.isEmpty && !JasCommands.confirmOrphaningDelete(orphaned.count) {
            return
        }
        // OP_LOG.md §9 Phase P4 — route the menu Delete through the SHARED
        // `opApply` dispatcher (`apply_delete_selection`, the SAME
        // Document.deleteSelection body) so the gesture JOURNALS a real
        // `delete_selection` op (one named undo step). The synchronous orphan
        // NSAlert above IS Swift's confirm path; only the mutation routes here.
        model.withTxn {
            model.nameTxn("delete_orphan_confirm_ok")
            opApply(model, Controller(model: model), ["op": "delete_selection"])
        }
    }

    /// Present the synchronous warn-then-orphan confirm (mirrors `revert()`'s
    /// `NSAlert` precedent). Returns `true` if the user confirmed the delete.
    /// "Cancel" is the default/escape button (the safe choice); "Delete" is the
    /// destructive confirming button. Verbatim title/body/buttons are
    /// cross-language-pinned. Shared by the three Swift delete entry points.
    static func confirmOrphaningDelete(_ orphanCount: Int) -> Bool {
        confirmOrphaning(orphanCount, action: "Delete", verb: "Deleting")
    }

    /// Present the synchronous warn-then-orphan confirm for Cut. Returns `true`
    /// if the user confirmed. Same dialog shape as the delete confirm; only the
    /// title/confirming-button label and the body verb differ.
    static func confirmOrphaningCut(_ orphanCount: Int) -> Bool {
        confirmOrphaning(orphanCount, action: "Cut", verb: "Cutting")
    }

    /// Generalized warn-then-orphan confirm shared by Delete and Cut. `action`
    /// labels the title and the destructive confirming button ("Delete" /
    /// "Cut"); `verb` is the gerund passed to the cross-language-pinned body
    /// (`"Deleting"` / `"Cutting"`). "Cancel" is the default/escape button (the
    /// safe choice) per the spec.
    private static func confirmOrphaning(_ orphanCount: Int, action: String, verb: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = action
        alert.informativeText = DependencyIndex.orphanWarningBody(orphanCount, verb: verb)
        alert.alertStyle = .warning
        // Order matters: the destructive action first, then the safe default.
        // Making "Cancel" the key-equivalent default keeps the safe choice as
        // the focused button per the spec.
        let confirmButton = alert.addButton(withTitle: action)
        let cancelButton = alert.addButton(withTitle: "Cancel")
        confirmButton.keyEquivalent = ""
        cancelButton.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func selectAll() {
        guard let model = model else { return }
        let controller = Controller(model: model)
        controller.selectAll()
    }

    private func cutSelection() {
        guard let model = model else { return }
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        // Reference-aware cut (warn-then-orphan): cut = copy + delete, so it can
        // orphan live instances exactly like Delete. Same pinned predicate;
        // empty orphan set -> cut as today (no dialog). Confirm before touching
        // the clipboard so Cancel leaves it unchanged.
        let orphaned = DependencyIndex.orphanedReferences(doc, doc.selection.map(\.path))
        if !orphaned.isEmpty && !JasCommands.confirmOrphaningCut(orphaned.count) {
            return
        }
        copySelection()  // clipboard only — no document write
        // OP_LOG.md §9 Phase P4 — route the delete-half of the cut through the
        // SHARED `opApply` dispatcher so it JOURNALS a real `delete_selection`
        // op (one named undo step). The clipboard copy is a non-document side
        // effect (no op). Mirrors Rust's cut_orphan_confirm_ok.
        model.withTxn {
            model.nameTxn("cut_orphan_confirm_ok")
            opApply(model, Controller(model: model), ["op": "delete_selection"])
        }
    }

    private func copySelection() {
        guard let model = model else { return }
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        var elements: [Element] = []
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            elements.append(elem)
        }
        guard !elements.isEmpty else { return }
        let tempDoc = Document(layers: [Layer(children: elements)])
        let svg = documentToSvg(tempDoc)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(svg, forType: .string)
    }
}

// MARK: - Menu evaluation context (chrome seam)

/// The 14 Window-menu panel ids whose visibility populates the `panels.*`
/// namespace of the menu ctx. `concepts` has no ``PanelKind`` case in this app,
/// so it resolves to not-visible (see ``panelKindForMenuId(_:)``).
let menuPanelIds: [String] = [
    "artboards", "layers", "color", "swatches", "stroke", "properties",
    "character", "paragraph", "align", "boolean", "magic_wand", "opacity",
    "symbols", "concepts",
]

/// Map a bundle pane id (`"toolbar"`, `"dock"`) to ``PaneKind``. Free function
/// shared by the menu dispatch and the menu-ctx builder.
func paneKindForId(_ id: String) -> PaneKind? {
    switch id {
    case "toolbar": return .toolbar
    case "dock": return .dock
    case "canvas": return .canvas
    default: return nil
    }
}

/// Map a bundle Window-menu panel id to ``PanelKind``. Returns nil for
/// `concepts` (no PanelKind case — the Concepts panel is not wired into this
/// app's dock/PanelKind layout, see the `toggle_panel` dispatch arm). Free
/// function shared by the menu dispatch and the menu-ctx builder.
func panelKindForMenuId(_ id: String) -> PanelKind? {
    switch id {
    case "layers": return .layers
    case "color": return .color
    case "swatches": return .swatches
    case "stroke": return .stroke
    case "properties": return .properties
    case "character": return .character
    case "paragraph": return .paragraph
    case "artboards": return .artboards
    case "align": return .align
    case "boolean": return .boolean
    case "opacity": return .opacity
    case "magic_wand": return .magicWand
    case "symbols": return .symbols
    default: return nil
    }
}

/// Build the menu evaluation context (TESTING_STRATEGY.md chrome seam): the
/// exact namespaces the bundle's `enabled_when` / `checked_when` predicates
/// read. Its shape matches the seeded contexts in
/// `test_fixtures/algorithms/menu_state.json` so the live menu evaluates exactly
/// what the cross-app `menu_state` gate pins; per-item enabled / checked then
/// equals ``MenuState/menuState(_:_:)``. Mirrors the Python jas `_build_menu_ctx`.
///
/// - `state.tab_count` — the open-document/tab count.
/// - `active_document` — has_selection / selection_count / can_undo / can_redo /
///   is_modified / has_filename (has_filename = filename does NOT start with
///   `Untitled-`); all-false when no document is active.
/// - `workspace.has_saved_layout` — the active layout is not the system
///   "Workspace" layout.
/// - `panels` — `isPanelVisible(kind)` for each of the 14 ids (concepts → false).
/// - `panes` — `isPaneVisible(kind)` for `toolbar` / `dock`.
func buildMenuContext(model: Model?, tabCount: Int, hasSelection: Bool?,
                      canUndo: Bool?, canRedo: Bool?,
                      workspace: WorkspaceState?) -> [String: Any] {
    let activeDocument: [String: Any]
    if let model = model {
        let doc = model.document
        activeDocument = [
            "has_selection": hasSelection ?? !doc.selection.isEmpty,
            "selection_count": doc.selection.count,
            "can_undo": canUndo ?? model.canUndo,
            "can_redo": canRedo ?? model.canRedo,
            "is_modified": model.isModified,
            "has_filename": !model.filename.hasPrefix("Untitled-"),
        ]
    } else {
        activeDocument = [
            "has_selection": false, "selection_count": 0,
            "can_undo": false, "can_redo": false,
            "is_modified": false, "has_filename": false,
        ]
    }
    var hasSavedLayout = false
    var panels: [String: Any] = [:]
    var panes: [String: Any] = [:]
    if let ws = workspace {
        hasSavedLayout = ws.appConfig.activeLayout != workspaceLayoutName
        let layout = ws.workspaceLayout
        for pid in menuPanelIds {
            // concepts → false (no PanelKind case), matching the Python ctx.
            panels[pid] = panelKindForMenuId(pid).map { layout.isPanelVisible($0) } ?? false
        }
        let paneLayout = layout.panes()
        for pnid in ["toolbar", "dock"] {
            if let kind = paneKindForId(pnid), let pl = paneLayout {
                panes[pnid] = pl.isPaneVisible(kind)
            } else {
                panes[pnid] = false
            }
        }
    } else {
        for pid in menuPanelIds { panels[pid] = false }
        for pnid in ["toolbar", "dock"] { panes[pnid] = false }
    }
    return [
        "state": ["tab_count": tabCount],
        "active_document": activeDocument,
        "workspace": ["has_saved_layout": hasSavedLayout],
        "panels": panels,
        "panes": panes,
    ]
}
