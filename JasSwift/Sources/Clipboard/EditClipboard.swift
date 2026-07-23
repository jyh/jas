import AppKit

/// Clipboard-backed Edit verbs (Cut / Copy / Paste), shared by the main-menu
/// commands (``JasCommands``) and the canvas right-click context menu so both
/// dispatch ONE implementation — the same single-source-of-truth pattern as
/// ``MenuActions``. Unlike ``MenuActions`` (model-pure, driven by the headless
/// cross-language ACTION corpus), these touch ``NSPasteboard``, so they live in
/// the AppKit / clipboard layer rather than the model-pure menu layer.
///
/// The pasteboard is injectable so round-trip tests use a private pasteboard
/// instead of clobbering the system one (mirrors ``RichClipboardTests``). The
/// bodies moved verbatim out of ``JasCommands`` — no behavior change.
enum EditClipboard {
    /// Serialize the current selection to SVG on the pasteboard. Clipboard-only:
    /// no document write, no undo step. No-op on an empty selection.
    static func copySelection(_ model: Model, pasteboard: NSPasteboard = .general) {
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
        pasteboard.clearContents()
        pasteboard.setString(svg, forType: .string)
    }

    /// Paste pasteboard contents into the document, translated by `offset` in
    /// both axes, selecting the pasted elements. SVG payloads merge by layer
    /// name (falling back to the active layer); plain text becomes a Text
    /// element. Undoable — `editDocument` self-brackets one undo step. No-op on
    /// empty pasteboard text.
    static func pasteClipboard(_ model: Model, offset: Double,
                               pasteboard: NSPasteboard = .general) {
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

    /// Cut = reference-aware confirm, then copy to the clipboard, then delete
    /// the selection as ONE named undo step via the shared `opApply` dispatcher.
    /// `confirmOrphaning` is injected so the caller supplies its own UI (the
    /// menu / canvas pass ``JasCommands.confirmOrphaningCut``'s NSAlert; headless
    /// tests pass a stub). Returns WITHOUT touching the clipboard if the user
    /// cancels an orphaning cut. No-op on an empty selection.
    static func cutSelection(_ model: Model, pasteboard: NSPasteboard = .general,
                             confirmOrphaning: (Int) -> Bool) {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        // Reference-aware cut (warn-then-orphan): cut = copy + delete, so it can
        // orphan live instances exactly like Delete. Same pinned predicate;
        // empty orphan set -> cut as today (no dialog). Confirm before touching
        // the clipboard so Cancel leaves it unchanged.
        let orphaned = DependencyIndex.orphanedReferences(doc, doc.selection.map(\.path))
        if !orphaned.isEmpty && !confirmOrphaning(orphaned.count) {
            return
        }
        copySelection(model, pasteboard: pasteboard)  // clipboard only — no document write
        // OP_LOG.md §9 Phase P4 — route the delete-half of the cut through the
        // SHARED `opApply` dispatcher so it JOURNALS a real `delete_selection`
        // op (one named undo step). The clipboard copy is a non-document side
        // effect (no op). Mirrors Rust's cut_orphan_confirm_ok.
        model.withTxn {
            model.nameTxn("cut_orphan_confirm_ok")
            opApply(model, Controller(model: model), ["op": "delete_selection"])
        }
    }

    // MARK: - Helpers (moved verbatim from JasCommands)

    static func translateElement(_ elem: Element, dx: Double, dy: Double) -> Element {
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

    static func isSvg(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("<?xml") || s.hasPrefix("<svg")
    }
}
