import Foundation
import SwiftUI
import Testing
@testable import JasLib

// ── Top menu-bar projector ───────────────────────────────────────
//
// These probe `menuBarModel()` directly: the projector reads the
// compiled bundle `menubar` and maps each top-level menu + entry to a
// MenuModel / MenuEntry (separator / dynamicSubmenu / action). They
// mirror the Rust reference's `menu.rs` projector tests, pinning the
// model so the Swift menu bar can never drift from menubar.yaml.

private func actionNames(_ menu: MenuModel) -> [String] {
    menu.entries.compactMap { entry in
        if case .action(_, let action, _, _, _) = entry { return action }
        return nil
    }
}

private func menu(_ model: [MenuModel], _ label: String) -> MenuModel? {
    model.first { $0.label == label }
}

@Test func modelHasFiveMenusIncludingView() {
    let model = menuBarModel()
    let labels = model.map(\.label)
    #expect(labels == ["&File", "&Edit", "&Object", "&View", "&Window"])
}

@Test func modelFileMenuHasPrintAndExport() {
    let model = menuBarModel()
    let actions = actionNames(model[0])
    #expect(actions.contains("open_print_dialog"))
    #expect(actions.contains("export_to_pdf"))
    // Quit is the genuinely-new File action.
    #expect(actions.contains("quit"))
}

@Test func modelViewMenuHasZoomAndFit() {
    let model = menuBarModel()
    guard let view = menu(model, "&View") else {
        Issue.record("View menu present")
        return
    }
    let actions = actionNames(view)
    #expect(actions.contains("zoom_in"))
    #expect(actions.contains("fit_active_artboard"))
    #expect(actions.contains("fit_in_window"))
}

@Test func modelObjectMenuHasPromoteToConcept() {
    let model = menuBarModel()
    guard let object = menu(model, "&Object") else {
        Issue.record("Object menu present")
        return
    }
    let actions = actionNames(object)
    #expect(actions.contains("make_instance"))
    #expect(actions.contains("promote_to_concept"))
}

@Test func modelWindowMenuHasDynamicSubmenus() {
    let model = menuBarModel()
    guard let window = menu(model, "&Window") else {
        Issue.record("Window menu present")
        return
    }
    let kinds: [SubmenuKind] = window.entries.compactMap { entry in
        if case .dynamicSubmenu(_, let kind) = entry { return kind }
        return nil
    }
    #expect(kinds.contains(.workspace))
    #expect(kinds.contains(.appearance))
}

@Test func modelTogglePanelCarriesPanelParam() {
    let model = menuBarModel()
    guard let window = menu(model, "&Window") else {
        Issue.record("Window menu present")
        return
    }
    let hasColor = window.entries.contains { entry in
        if case .action(_, let action, let params, _, _) = entry,
           action == "toggle_panel",
           (params["panel"] as? String) == "color" {
            return true
        }
        return false
    }
    #expect(hasColor)
    // Concepts toggle is present (Co&ncepts).
    let hasConcepts = window.entries.contains { entry in
        if case .action(_, let action, let params, _, _) = entry,
           action == "toggle_panel",
           (params["panel"] as? String) == "concepts" {
            return true
        }
        return false
    }
    #expect(hasConcepts)
}

@Test func modelSeparatorsPresent() {
    let model = menuBarModel()
    let fileSeps = model[0].entries.filter { entry in
        if case .separator = entry { return true }
        return false
    }.count
    #expect(fileSeps >= 1)
}

// ── stripMnemonic ────────────────────────────────────────────────

@Test func stripMnemonicRemovesMarkers() {
    #expect(stripMnemonic("&File") == "File")
    #expect(stripMnemonic("Zoom &In") == "Zoom In")
    #expect(stripMnemonic("Save &As...") == "Save As...")
    #expect(stripMnemonic("Fit A&ll in Window") == "Fit All in Window")
    #expect(stripMnemonic("Tile") == "Tile")
    #expect(stripMnemonic("A && B") == "A & B")
    #expect(stripMnemonic("Co&ncepts") == "Concepts")
}

// ── parseShortcut ────────────────────────────────────────────────

@Test func parseShortcutHandlesModifiersAndKeys() {
    #expect(parseShortcut("") == nil)

    let n = parseShortcut("Ctrl+N")
    #expect(n?.key == "n")
    #expect(n?.modifiers == .command)

    let saveAs = parseShortcut("Ctrl+Shift+S")
    #expect(saveAs?.key == "s")
    #expect(saveAs?.modifiers == [.command, .shift])

    let zoomIn = parseShortcut("Ctrl+=")
    #expect(zoomIn?.key == "=")
    #expect(zoomIn?.modifiers == .command)

    let zoomOut = parseShortcut("Ctrl+-")
    #expect(zoomOut?.key == "-")
    #expect(zoomOut?.modifiers == .command)

    let actual = parseShortcut("Ctrl+1")
    #expect(actual?.key == "1")
    #expect(actual?.modifiers == .command)

    let unlock = parseShortcut("Ctrl+Alt+2")
    #expect(unlock?.key == "2")
    #expect(unlock?.modifiers == [.command, .option])
}

@Test func parseShortcutLowercasesLetters() {
    // Bundle uppercases the accelerator letter; macOS keyEquivalents are
    // lowercase (Shift carries the case intent).
    let s = parseShortcut("Ctrl+G")
    #expect(s?.key == "g")
}
