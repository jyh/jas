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
}

/// Custom menu commands for Jas app (File, Edit, View menus).
public struct JasCommands: Commands {
    @FocusedValue(\.jasModel) private var model
    @FocusedValue(\.hasSelection) private var hasSelection
    @FocusedValue(\.canUndo) private var canUndo
    @FocusedValue(\.canRedo) private var canRedo
    @FocusedValue(\.addCanvas) private var addCanvas
    @FocusedValue(\.workspace) private var workspace

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") {
                addCanvas?(Model())
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Open...") {
                openFile()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                save()
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Save As...") {
                saveAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Revert") {
                revert()
            }
            .disabled(model == nil
                      || !(model?.isModified ?? false)
                      || (model?.filename.hasPrefix("Untitled-") ?? true))
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                model?.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!(canUndo ?? false))

            Button("Redo") {
                model?.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!(canRedo ?? false))
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                cutSelection()
            }
            .keyboardShortcut("x", modifiers: .command)
            .disabled(!(hasSelection ?? false))

            Button("Copy") {
                copySelection()
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(!(hasSelection ?? false))

            Button("Paste") {
                pasteClipboard(offset: pasteOffset)
            }
            .keyboardShortcut("v", modifiers: .command)

            Button("Paste in Place") {
                pasteClipboard(offset: 0.0)
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Divider()

            Button("Delete") {
                deleteSelection()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!(hasSelection ?? false))

            Button("Select All") {
                selectAll()
            }
            .keyboardShortcut("a", modifiers: .command)
        }

        CommandMenu("Object") {
            Button("Group") {
                groupSelection()
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(!(hasSelection ?? false))

            Button("Ungroup") {
                ungroupSelection()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!(hasSelection ?? false))

            Button("Ungroup All") {
                ungroupAll()
            }

            Divider()

            Button("Lock") {
                lockSelection()
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(!(hasSelection ?? false))

            Button("Unlock All") {
                unlockAll()
            }
            .keyboardShortcut("2", modifiers: [.command, .option])

            Divider()

            Button("Hide") {
                hideSelection()
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(!(hasSelection ?? false))

            Button("Show All") {
                showAll()
            }
            .keyboardShortcut("3", modifiers: [.command, .option])
        }

        // Replace default toolbar section in View menu with our zoom items
        CommandGroup(replacing: .toolbar) {
            Button("Zoom In") {
                print("Zoom in")
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("Zoom Out") {
                print("Zoom out")
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Fit in Window") {
                print("Fit in window")
            }
            .keyboardShortcut("0", modifiers: .command)
        }

        // Replace default window list with our workspace/pane items
        CommandGroup(replacing: .windowList) {
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

                Divider()
            }

            if let ws = workspace {
                Button("Tile") {
                    ws.workspaceLayout.panesMut { pl in
                        pl.tilePanes(collapsedOverride: nil)
                    }
                    ws.workspaceLayout.saveIfNeeded()
                }

                Divider()

                paneToggle(ws, .toolbar, "Toolbar")
                paneToggle(ws, .dock, "Panels")

                Divider()
            }

            panelToggle(.layers, "Layers")
            panelToggle(.color, "Color")
            panelToggle(.stroke, "Stroke")
            panelToggle(.properties, "Properties")
        }
    }

    @ViewBuilder
    private func paneToggle(_ ws: WorkspaceState, _ kind: PaneKind, _ label: String) -> some View {
        let visible = ws.workspaceLayout.panes()?.isPaneVisible(kind) ?? true
        let prefix = visible ? "\u{2713} " : "    "
        Button(prefix + label) {
            ws.workspaceLayout.panesMut { pl in
                if pl.isPaneVisible(kind) {
                    pl.hidePane(kind)
                } else {
                    pl.showPane(kind)
                }
            }
            ws.workspaceLayout.saveIfNeeded()
        }
    }

    @ViewBuilder
    private func panelToggle(_ kind: PanelKind, _ label: String) -> some View {
        let visible = workspace?.workspaceLayout.isPanelVisible(kind) ?? true
        let prefix = visible ? "\u{2713} " : "    "
        Button(prefix + label) {
            guard let ws = workspace else { return }
            if ws.workspaceLayout.isPanelVisible(kind) {
                if let addr = findPanel(ws.workspaceLayout, kind) {
                    ws.workspaceLayout.closePanel(addr)
                }
            } else {
                ws.workspaceLayout.showPanel(kind)
            }
            ws.workspaceLayout.saveIfNeeded()
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
            model.snapshot()
            model.document = newDoc
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
        model.snapshot()
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
                if !pastedLayer.name.isEmpty {
                    for i in 0..<newLayers.count {
                        if newLayers[i].name == pastedLayer.name {
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
            model.document = Document(layers: newLayers,
                                          selectedLayer: doc.selectedLayer, selection: newSelection)
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
            model.document = Document(layers: newLayers,
                                          selectedLayer: doc.selectedLayer, selection: newSelection)
        }
    }

    private func groupSelection() {
        guard let model = model else { return }
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        model.snapshot()
        let controller = Controller(model: model)
        controller.groupSelection()
    }

    private func ungroupSelection() {
        guard let model = model else { return }
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        model.snapshot()
        let controller = Controller(model: model)
        controller.ungroupSelection()
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
        model.snapshot()
        model.document = Document(layers: newLayers,
                                  selectedLayer: doc.selectedLayer, selection: [])
    }

    private func lockSelection() {
        guard let model = model else { return }
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        model.snapshot()
        let controller = Controller(model: model)
        controller.lockSelection()
    }

    private func unlockAll() {
        guard let model = model else { return }
        model.snapshot()
        let controller = Controller(model: model)
        controller.unlockAll()
    }

    private func hideSelection() {
        guard let model = model else { return }
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        model.snapshot()
        let controller = Controller(model: model)
        controller.hideSelection()
    }

    private func showAll() {
        guard let model = model else { return }
        model.snapshot()
        let controller = Controller(model: model)
        controller.showAll()
    }

    private func deleteSelection() {
        guard let model = model else { return }
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        model.snapshot()
        model.document = doc.deleteSelection()
    }

    private func selectAll() {
        guard let model = model else { return }
        let controller = Controller(model: model)
        controller.selectAll()
    }

    private func cutSelection() {
        guard let model = model else { return }
        model.snapshot()
        copySelection()
        model.document = model.document.deleteSelection()
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
