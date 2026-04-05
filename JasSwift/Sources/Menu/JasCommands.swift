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

public extension FocusedValues {
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
        }

        CommandMenu("View") {
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
                                opacity: g.opacity, transform: g.transform))
        case .layer(let l):
            return .layer(Layer(name: l.name,
                                children: l.children.map { translateElement($0, dx: dx, dy: dy) },
                                opacity: l.opacity, transform: l.transform))
        default:
            let n = elem.controlPointCount
            return elem.moveControlPoints(Set(0..<n), dx: dx, dy: dy)
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
                for (j, child) in children.enumerated() {
                    let path: ElementPath = [idx, base + j]
                    let n = child.controlPointCount
                    newSelection.insert(ElementSelection(path: path,
                                                          controlPoints: Set(0..<n)))
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
            let n = elem.controlPointCount
            newSelection.insert(ElementSelection(path: path,
                                                  controlPoints: Set(0..<n)))
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
        let paths = doc.selection.map(\.path).sorted { $0.lexicographicallyPrecedes($1) }
        guard paths.count >= 2 else { return }
        // All selected elements must be siblings (same parent prefix)
        let parent = Array(paths[0].dropLast())
        guard paths.allSatisfy({ Array($0.dropLast()) == parent }) else { return }
        // Gather elements in order
        let elements = paths.map { doc.getElement($0) }
        model.snapshot()
        // Delete in reverse order
        var newDoc = doc
        for path in paths.reversed() {
            newDoc = newDoc.deleteElement(path)
        }
        // Create group and insert at position of first element
        let group = Element.group(Group(children: elements))
        let insertPath = paths[0]
        let layerIdx = insertPath[0]
        let childIdx = insertPath.count > 1 ? insertPath[1] : 0
        let layer = newDoc.layers[layerIdx]
        var newChildren = layer.children
        newChildren.insert(group, at: childIdx)
        let newLayer = Layer(name: layer.name, children: newChildren,
                            opacity: layer.opacity, transform: layer.transform)
        var newLayers = newDoc.layers
        newLayers[layerIdx] = newLayer
        let n = group.controlPointCount
        let newSelection: Selection = [ElementSelection(
            path: insertPath, controlPoints: Set(0..<n))]
        model.document = Document(layers: newLayers,
                                  selectedLayer: newDoc.selectedLayer,
                                  selection: newSelection)
    }

    private func ungroupSelection() {
        guard let model = model else { return }
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        // Collect selected paths that are Groups
        var groupPaths: [ElementPath] = []
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            if case .group = elem {
                groupPaths.append(es.path)
            }
        }
        guard !groupPaths.isEmpty else { return }
        groupPaths.sort { $0.lexicographicallyPrecedes($1) }
        model.snapshot()
        // Process in reverse order to preserve indices
        var newDoc = doc
        for gpath in groupPaths.reversed() {
            let groupElem = newDoc.getElement(gpath)
            guard case .group(let g) = groupElem else { continue }
            let children = g.children
            // Delete the group
            newDoc = newDoc.deleteElement(gpath)
            let layerIdx = gpath[0]
            let childIdx = gpath.count > 1 ? gpath[1] : 0
            let layer = newDoc.layers[layerIdx]
            var newChildren = layer.children
            newChildren.insert(contentsOf: children, at: childIdx)
            let newLayer = Layer(name: layer.name, children: newChildren,
                                opacity: layer.opacity, transform: layer.transform)
            var newLayers = newDoc.layers
            newLayers[layerIdx] = newLayer
            newDoc = Document(layers: newLayers, selectedLayer: newDoc.selectedLayer,
                              selection: [])
        }
        // Build selection for all unpacked children
        var newSelection: Selection = []
        var offset = 0
        for gpath in groupPaths {
            let groupElem = doc.getElement(gpath)
            guard case .group(let g) = groupElem else { continue }
            let nChildren = g.children.count
            let layerIdx = gpath[0]
            let childIdx = (gpath.count > 1 ? gpath[1] : 0) + offset
            for j in 0..<nChildren {
                let path: ElementPath = [layerIdx, childIdx + j]
                let elem = newDoc.getElement(path)
                let n = elem.controlPointCount
                newSelection.insert(ElementSelection(path: path,
                                                      controlPoints: Set(0..<n)))
            }
            offset += nChildren - 1
        }
        model.document = Document(layers: newDoc.layers,
                                  selectedLayer: newDoc.selectedLayer,
                                  selection: newSelection)
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
