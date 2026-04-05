import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - FocusedValue for model access from commands

public struct FocusedModelKey: FocusedValueKey {
    public typealias Value = JasModel
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

public extension FocusedValues {
    var jasModel: JasModel? {
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
}

/// Custom menu commands for Jas app (File, Edit, View menus).
public struct JasCommands: Commands {
    @FocusedValue(\.jasModel) private var model
    @FocusedValue(\.hasSelection) private var hasSelection
    @FocusedValue(\.canUndo) private var canUndo
    @FocusedValue(\.canRedo) private var canRedo

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") {
                print("New document")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Open...") {
                openFile()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                print("Save document")
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Save As...") {
                saveAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
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
                pasteClipboard(offset: 24.0)
            }
            .keyboardShortcut("v", modifiers: .command)

            Button("Paste in Place") {
                pasteClipboard(offset: 0.0)
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
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

    private func openFile() {
        guard let model = model else { return }
        let panel = NSOpenPanel()
        panel.title = "Open"
        panel.allowedContentTypes = [.svg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let svg = try String(contentsOf: url, encoding: .utf8)
            model.document = svgToDocument(svg)
            model.markSaved()
            model.filename = url.path
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private func saveAs() {
        guard let model = model else { return }
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

    private func translateElement(_ elem: Element, dx: Double, dy: Double) -> Element {
        if dx == 0 && dy == 0 { return elem }
        let n = elem.controlPointCount
        return elem.moveControlPoints(Set(0..<n), dx: dx, dy: dy)
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
                newLayers[idx] = JasLayer(name: newLayers[idx].name,
                                          children: newLayers[idx].children + children,
                                          opacity: newLayers[idx].opacity,
                                          transform: newLayers[idx].transform)
            }
            model.document = JasDocument(layers: newLayers,
                                          selectedLayer: doc.selectedLayer, selection: newSelection)
        } else {
            // Plain text: create a Text element
            let elem = Element.text(JasText(x: offset, y: offset + 16.0, content: text))
            let idx = doc.selectedLayer
            let path: ElementPath = [idx, doc.layers[idx].children.count]
            let n = elem.controlPointCount
            newSelection.insert(ElementSelection(path: path,
                                                  controlPoints: Set(0..<n)))
            var newLayers = doc.layers
            newLayers[idx] = JasLayer(name: newLayers[idx].name,
                                      children: newLayers[idx].children + [elem],
                                      opacity: newLayers[idx].opacity,
                                      transform: newLayers[idx].transform)
            model.document = JasDocument(layers: newLayers,
                                          selectedLayer: doc.selectedLayer, selection: newSelection)
        }
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
        let tempDoc = JasDocument(layers: [JasLayer(children: elements)])
        let svg = documentToSvg(tempDoc)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(svg, forType: .string)
    }
}
