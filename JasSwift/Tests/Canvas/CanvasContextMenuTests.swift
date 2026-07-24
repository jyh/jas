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

// MARK: - SWCTX-001: built NSMenu is exactly the five house verbs + dividers,
// with the macOS-injected extras suppressed (Writing Tools / AutoFill /
// Start Dictation / Emoji & Symbols). The BUILDER's output is testable without
// presenting the menu; the visual confirmation that the OS adds nothing at
// display time lives in the manual suite (SWCTX-001 note).

/// The verb rows (skipping separators), in display order, that the builder
/// must emit from the CanvasContextMenu data model.
private let expectedContextTitles = ["Cut", "Copy", "Paste", "Delete", "Select All"]

@Test func builtContextMenuIsExactlyTheDataModelItems() {
    // 5 verbs + 2 separators (before Delete, before Select All) = 7 items, in
    // order, titles verbatim — nothing extra from the builder itself.
    let menu = CanvasNSView.buildContextMenu(
        hasSelection: true, hasTab: true, target: nil, selectors: [:])
    #expect(menu.items.count == 7)
    let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    #expect(titles == expectedContextTitles)
    // Separator positions: index 3 (before Delete) and index 5 (before Select All).
    #expect(menu.items[3].isSeparatorItem)
    #expect(menu.items[5].isSeparatorItem)
    #expect(menu.items.filter(\.isSeparatorItem).count == 2)
}

@Test func builtContextMenuSuppressesInjectedSystemItems() {
    // The supported opt-outs are set on the menu: no third-party contextual
    // plug-ins and (15.2+) no auto-inserted Writing Tools items.
    let menu = CanvasNSView.buildContextMenu(
        hasSelection: false, hasTab: true, target: nil, selectors: [:])
    #expect(menu.allowsContextMenuPlugIns == false)
    if #available(macOS 15.2, *) {
        #expect(menu.automaticallyInsertsWritingToolsItems == false)
    }
}

@Test func builtContextMenuStampsEveryItemWithOurIdentifier() {
    // Every item the builder emits (verbs AND separators) carries the canvas
    // identifier, so the willOpenMenu sweep can tell ours from OS-appended ones
    // WITHOUT matching localized titles.
    let menu = CanvasNSView.buildContextMenu(
        hasSelection: true, hasTab: true, target: nil, selectors: [:])
    for item in menu.items {
        #expect(item.identifier == CanvasNSView.contextMenuItemIdentifier)
    }
}

@Test func builtContextMenuEnabledStatesFollowThePredicates() {
    // No selection: cut/copy/delete disabled; paste/selectAll enabled.
    let noSel = CanvasNSView.buildContextMenu(
        hasSelection: false, hasTab: true, target: nil, selectors: [:])
    func item(_ m: NSMenu, _ title: String) -> NSMenuItem? {
        m.items.first { $0.title == title }
    }
    #expect(item(noSel, "Cut")?.isEnabled == false)
    #expect(item(noSel, "Copy")?.isEnabled == false)
    #expect(item(noSel, "Delete")?.isEnabled == false)
    #expect(item(noSel, "Paste")?.isEnabled == true)
    #expect(item(noSel, "Select All")?.isEnabled == true)
    // With a selection: cut/copy/delete now enabled.
    let sel = CanvasNSView.buildContextMenu(
        hasSelection: true, hasTab: true, target: nil, selectors: [:])
    #expect(item(sel, "Cut")?.isEnabled == true)
    #expect(item(sel, "Copy")?.isEnabled == true)
    #expect(item(sel, "Delete")?.isEnabled == true)
    // No tab (closed document): paste/selectAll disabled.
    let noTab = CanvasNSView.buildContextMenu(
        hasSelection: false, hasTab: false, target: nil, selectors: [:])
    #expect(item(noTab, "Paste")?.isEnabled == false)
    #expect(item(noTab, "Select All")?.isEnabled == false)
}

@Test func stripInjectedItemsRemovesUntaggedKeepsOurs() {
    // Simulate the OS appending its extras after the builder ran: append items
    // WITHOUT our identifier (a separator + a "Writing Tools"-style row), then
    // run the sweep. Only our seven tagged items survive — title-independent.
    let menu = CanvasNSView.buildContextMenu(
        hasSelection: true, hasTab: true, target: nil, selectors: [:])
    #expect(menu.items.count == 7)
    let injectedSep = NSMenuItem.separator()   // untagged
    menu.addItem(injectedSep)
    let injected = NSMenuItem(title: "Writing Tools", action: nil, keyEquivalent: "")
    menu.addItem(injected)                      // untagged
    let injected2 = NSMenuItem(title: "Emoji & Symbols", action: nil, keyEquivalent: "")
    menu.addItem(injected2)                     // untagged
    #expect(menu.items.count == 10)

    CanvasNSView.stripInjectedContextMenuItems(from: menu)

    #expect(menu.items.count == 7)
    let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    #expect(titles == expectedContextTitles)
    for item in menu.items {
        #expect(item.identifier == CanvasNSView.contextMenuItemIdentifier)
    }
}

@Test func stripInjectedItemsIsIdempotentOnACleanMenu() {
    // A menu with only our items is untouched by the sweep (no over-removal).
    let menu = CanvasNSView.buildContextMenu(
        hasSelection: false, hasTab: true, target: nil, selectors: [:])
    CanvasNSView.stripInjectedContextMenuItems(from: menu)
    #expect(menu.items.count == 7)
    #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == expectedContextTitles)
}
