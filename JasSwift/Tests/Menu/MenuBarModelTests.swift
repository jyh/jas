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
        if case .action(_, let action, _, _, _, _) = entry { return action }
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
        if case .action(_, let action, let params, _, _, _) = entry,
           action == "toggle_panel",
           (params["panel"] as? String) == "color" {
            return true
        }
        return false
    }
    #expect(hasColor)
    // Concepts toggle is present (Co&ncepts).
    let hasConcepts = window.entries.contains { entry in
        if case .action(_, let action, let params, _, _, _) = entry,
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

// ── Live menu enabled / checked wiring ───────────────────────────
//
// The live menu (`JasCommands.actionButton`) builds the menu ctx via
// `buildMenuContext` and evaluates each item's `enabled_when` / `checked_when`
// through the shared expression evaluator. This pins that the SAME ctx, run
// through the SAME `MenuState.menuState` the cross-app gate uses, grays out /
// checks the right items for a seeded document — i.e. the live wiring agrees
// with the corpus gate by construction.

@Test func liveMenuCtxDrivesEnabledAndChecked() throws {
    guard let ws = WorkspaceData.load() else {
        Issue.record("workspace bundle present")
        return
    }
    let menubar = ws.menubar()

    // Seed a document: two selected rects, a named file, and one undoable edit
    // (so is_modified + can_undo are true). can_redo stays false.
    let r1 = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let r2 = Element.rect(Rect(x: 20, y: 20, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [r1, r2])
    let model = Model(document: Document(layers: [layer]),
                      filename: "/tmp/wiring.svg")
    model.editDocument(Document(
        layers: [layer],
        selection: [ElementSelection.all([0, 0]), ElementSelection.all([0, 1])]))

    // workspace = nil so panels / panes are all not-visible (checked == false
    // for toggles); the focused signals are passed explicitly as the live menu
    // does. Per-item enabled / checked then equals MenuState.menuState(ctx).
    let ctx = buildMenuContext(model: model, tabCount: 1,
                               hasSelection: true, canUndo: true, canRedo: false,
                               workspace: nil)
    let items = MenuState.menuState(menubar, ctx)

    func enabled(_ action: String) -> Bool? {
        items.first { ($0["action"] as? String) == action }?["enabled"] as? Bool
    }
    #expect(enabled("save") == true)            // state.tab_count > 0
    #expect(enabled("revert") == true)          // is_modified and has_filename
    #expect(enabled("cut") == true)             // has_selection
    #expect(enabled("group") == true)           // selection_count >= 2
    #expect(enabled("make_instance") == false)  // selection_count == 1 (it is 2)
    #expect(enabled("undo") == true)            // can_undo
    #expect(enabled("redo") == false)           // can_redo
    // §15's visible half, from an OPEN active layer: paste is available.
    #expect(enabled("paste") == true)
    #expect(enabled("paste_in_place") == true)

    // THE REFUSAL, MADE VISIBLE (LAYER_STRUCTURE.md §15.4). Lock the ACTIVE
    // layer and nothing else, and `paste` / `paste_in_place` must grey out —
    // while `paste_preserving_layers`, which DIVERTS rather than refusing,
    // must stay available. That asymmetry is the ruling, so it is asserted
    // rather than assumed.
    //
    // WHY THIS TEST HAS TO EXIST AND CANNOT BE THE SHARED GATE: the cross-app
    // `menu_state` corpus SEEDS its context, so it pins how the predicate is
    // EVALUATED and is structurally blind to a port that forgets to BUILD the
    // key. A missing key evaluates to null → false → `!false` → paste stays
    // enabled, which is silently the pre-ruling behaviour. Only a live-ctx test
    // can catch that, and it is a per-port claim in both ports.
    let lockedModel = Model(document: Document(layers: [
        Layer(name: "L0", children: [r1, r2], locked: true),
    ]), filename: "/tmp/wiring.svg")
    let lockedCtx = buildMenuContext(model: lockedModel, tabCount: 1,
                                     hasSelection: false, canUndo: false,
                                     canRedo: false, workspace: nil)
    let lockedItems = MenuState.menuState(menubar, lockedCtx)
    func enabledLocked(_ action: String) -> Bool? {
        lockedItems.first { ($0["action"] as? String) == action }?["enabled"] as? Bool
    }
    #expect(enabledLocked("paste") == false, "paste must grey out on a locked active layer")
    #expect(enabledLocked("paste_in_place") == false,
            "paste_in_place shares plain Paste's target, so it greys out too")
    #expect(enabledLocked("paste_preserving_layers") == true,
            "preserving paste DIVERTS rather than refusing, so it stays available")
    #expect(enabledLocked("save") == true, "the lock must not disable unrelated items")

    // checked: the pane / panel toggles carry `checked_when` → a Bool (false
    // here, workspace nil); non-toggle items carry no `checked_when` → JSON null.
    let toggles = items.filter {
        let a = $0["action"] as? String
        return a == "toggle_pane" || a == "toggle_panel"
    }
    #expect(toggles.count == 18)  // 2 panes + 16 panels (incl. Brushes, Gradient)
    #expect(toggles.allSatisfy { ($0["checked"] as? Bool) == false })
    let newDoc = items.first { ($0["action"] as? String) == "new_document" }
    #expect(newDoc?["checked"] is NSNull)

    // No-document ctx: tab_count 0 disables save; new_document has no
    // `enabled_when` so it stays enabled.
    let emptyCtx = buildMenuContext(model: nil, tabCount: 0, hasSelection: nil,
                                    canUndo: nil, canRedo: nil, workspace: nil)
    let emptyItems = MenuState.menuState(menubar, emptyCtx)
    func enabledEmpty(_ action: String) -> Bool? {
        emptyItems.first { ($0["action"] as? String) == action }?["enabled"] as? Bool
    }
    #expect(enabledEmpty("save") == false)
    #expect(enabledEmpty("new_document") == true)
    #expect(enabledEmpty("undo") == false)
}
