import Testing
import AppKit
@testable import JasLib

// SH-3: canvas right-click context menu. The item set / titles / enabled
// predicates are pure (CanvasContextMenu) and tested without an NSMenu; the
// clipboard verbs it dispatches (EditClipboard) are exercised on a private
// pasteboard so the round trip never clobbers the system clipboard (mirrors
// RichClipboardTests).

// MARK: - Enabled predicates mirror the menubar.yaml Edit menu

@Test func contextMenuEnabledMirrorsSelectionPredicate() {
    // cut/copy/delete follow active_document.has_selection.
    for item in [CanvasContextMenu.Item.cut, .copy, .delete] {
        #expect(CanvasContextMenu.isEnabled(item, hasSelection: true, hasTab: true))
        #expect(!CanvasContextMenu.isEnabled(item, hasSelection: false, hasTab: true))
    }
}

@Test func contextMenuEnabledMirrorsTabPredicate() {
    // paste/selectAll follow state.tab_count > 0 — NOT gated on selection or
    // clipboard content, exactly as the Edit menu.
    for item in [CanvasContextMenu.Item.paste, .selectAll] {
        #expect(CanvasContextMenu.isEnabled(item, hasSelection: false, hasTab: true))
        #expect(!CanvasContextMenu.isEnabled(item, hasSelection: false, hasTab: false))
    }
}

@Test func contextMenuTitlesMatchMainMenu() {
    #expect(CanvasContextMenu.title(.cut) == "Cut")
    #expect(CanvasContextMenu.title(.copy) == "Copy")
    #expect(CanvasContextMenu.title(.paste) == "Paste")
    #expect(CanvasContextMenu.title(.delete) == "Delete")
    #expect(CanvasContextMenu.title(.selectAll) == "Select All")
}

@Test func contextMenuSeparatorGrouping() {
    // clipboard group | delete | select-all.
    #expect(!CanvasContextMenu.separatorBefore(.cut))
    #expect(!CanvasContextMenu.separatorBefore(.copy))
    #expect(!CanvasContextMenu.separatorBefore(.paste))
    #expect(CanvasContextMenu.separatorBefore(.delete))
    #expect(CanvasContextMenu.separatorBefore(.selectAll))
}

// MARK: - EditClipboard shared verbs (private pasteboard)

private func privatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name(rawValue: "jas.tests.ctxmenu.\(UUID().uuidString)"))
}

private func modelWithSelectedRect() -> Model {
    let rect = Element.rect(Rect(x: 10, y: 10, width: 20, height: 20))
    let doc = Document(layers: [Layer(children: [rect])],
                       selectedLayer: 0,
                       selection: [ElementSelection.all([0, 0])])
    return Model(document: doc)
}

@Test func editClipboardCopyPasteRoundTripsThroughPasteboard() {
    let pb = privatePasteboard()
    let model = modelWithSelectedRect()
    EditClipboard.copySelection(model, pasteboard: pb)
    // Copy is clipboard-only: the document is untouched.
    #expect(model.document.layers[0].children.count == 1)
    #expect(pb.string(forType: .string) != nil)

    EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)
    // Paste appended the pasted element and selected it.
    #expect(model.document.layers[0].children.count == 2)
    #expect(!model.document.selection.isEmpty)
}

@Test func editClipboardCutRemovesSelectionAndPopulatesClipboard() {
    let pb = privatePasteboard()
    let model = modelWithSelectedRect()
    EditClipboard.cutSelection(model, pasteboard: pb, confirmOrphaning: { _ in true })
    // The selected element is gone from the document...
    #expect(model.document.layers[0].children.isEmpty)
    // ...and its serialization is on the clipboard, so a paste can restore it.
    #expect(pb.string(forType: .string) != nil)
    EditClipboard.pasteClipboard(model, offset: 0.0, pasteboard: pb)
    #expect(model.document.layers[0].children.count == 1)
}

@Test func editClipboardPasteNoOpsOnEmptyClipboard() {
    let pb = privatePasteboard()
    pb.clearContents()
    let model = modelWithSelectedRect()
    EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)
    // Nothing on the clipboard → no document change.
    #expect(model.document.layers[0].children.count == 1)
}

@Test func editClipboardCopyNoOpsOnEmptySelection() {
    let pb = privatePasteboard()
    pb.clearContents()
    let doc = Document(layers: [Layer(children: [.rect(Rect(x: 0, y: 0, width: 5, height: 5))])],
                       selectedLayer: 0, selection: [])
    let model = Model(document: doc)
    EditClipboard.copySelection(model, pasteboard: pb)
    #expect(pb.string(forType: .string) == nil)  // empty selection wrote nothing
}
