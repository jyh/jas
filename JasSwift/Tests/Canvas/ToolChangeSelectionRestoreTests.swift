import Testing
import AppKit
@testable import JasLib

/// Arc 1 follow-up (FA): a tool switch preserves selection via a NON-undoable
/// `.selection` write (OP_LOG.md §7/§8). The rebuild that write feeds must
/// carry the FULL document forward and change ONLY the selection — the S1
/// census found it reconstructing the document from a subset of fields
/// (`Document(layers:selectedLayer:selection:)`), which silently defaulted
/// artboards / documentSetup / printPreferences / symbols. A document with real
/// artboards or print setup therefore lost that state on any tool switch.
///
/// These pin the extracted seam (`rebuildForToolChangeSelectionRestore`) so the
/// drop is a regression without driving an NSView. Mirrors the Rust Selection
/// teeth (`differs_only_in_selection`, model.rs), which catch the same class.
@Suite struct ToolChangeSelectionRestoreTests {

    /// Build a document whose every non-selection field is DELIBERATELY
    /// non-default, so a rebuild that drops any of them is visible.
    private func nonDefaultDocument() -> Document {
        let artboard = Artboard(
            id: "ab-custom", name: "Custom", x: 100, y: 200,
            width: 300, height: 400, showCenterMark: true)
        let setup = DocumentSetup(
            bleedTop: 12, bleedRight: 12, bleedBottom: 12, bleedLeft: 12,
            showImagesOutline: true)
        let prefs = PrintPreferences(copies: 3, collate: true)
        let master = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, id: "sym-1"))
        return Document(
            layers: [Layer(name: "Layer", children: [])],
            symbols: [master],
            selectedLayer: 0,
            selection: [ElementSelection.all([0])],
            artboards: [artboard],
            artboardOptions: ArtboardOptions(
                fadeRegionOutsideArtboard: false, updateWhileDragging: false),
            documentSetup: setup,
            printPreferences: prefs)
    }

    @Test func rebuildCarriesArtboardsSetupPrefsAndSymbols() {
        let base = nonDefaultDocument()
        // The pre-switch selection differs from the document's current
        // selection — exactly the guard that fires the restore write.
        let savedSelection: Selection = []

        let rebuilt = CanvasNSView.rebuildForToolChangeSelectionRestore(
            base, restoring: savedSelection)

        // The selection is restored to the pre-switch value ...
        #expect(rebuilt.selection == savedSelection)
        // ... and EVERY other field survives (the drop regression).
        #expect(rebuilt.artboards == base.artboards)
        #expect(rebuilt.documentSetup == base.documentSetup)
        #expect(rebuilt.printPreferences == base.printPreferences)
        #expect(rebuilt.artboardOptions == base.artboardOptions)
        #expect(rebuilt.symbols == base.symbols)
        #expect(rebuilt.layers == base.layers)
        #expect(rebuilt.selectedLayer == base.selectedLayer)
    }

    /// The whole-document invariant: the rebuild differs from the base in AT
    /// MOST the selection field. Uses the same alignment the `.selection` teeth
    /// use — align selection, then Document `==` must hold.
    @Test func rebuildDiffersOnlyInSelection() {
        let base = nonDefaultDocument()
        let savedSelection: Selection = []
        let rebuilt = CanvasNSView.rebuildForToolChangeSelectionRestore(
            base, restoring: savedSelection)
        #expect(base.replacing(selection: rebuilt.selection) == rebuilt,
                "the tool-change rebuild changes only the selection field")
    }
}
