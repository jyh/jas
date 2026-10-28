import Testing
import Foundation
import SwiftUI
import AppKit
@testable import JasLib

// The Layers tree's three pieces of view state -- the collapsed containers,
// the panel selection and the row being renamed -- live in the panel store
// under the keys layers.yaml declares (`collapsed_paths`,
// `layers_panel_selection`, `renaming_element`), so a YAML action and the
// native tree read and write ONE value (STATUS-jas item 8 class L, step 2b).
// Until 2026-10-28 they were view `@State`, mirrored one way (the selection
// only), so a key routed through `LayersPanel.treeKey` changed state the tree
// never drew.

/// multi_layer.svg with every panel initialised from the workspace defaults;
/// rows, top first: [1] [1,0] [0] [0,0].
private func twoLayers() -> Model {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../test_fixtures/svg/multi_layer.svg").standardizedFileURL
    let svg = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let model = Model(document: svgToDocument(svg))
    if let ws = WorkspaceData.load(), let panels = ws.panels() {
        for pid in panels.keys.sorted() {
            model.stateStore.initPanel(pid, defaults: ws.panelStateDefaults(pid))
        }
    }
    model.stateStore.setActivePanel("layers_panel_content")
    return model
}

// MARK: - collapsed_paths
// The twirl's `path` param is a path (`node.path` in the row template), which
// the action route carries as a `__path__` marker; a bare list would toggle a
// LIST into collapsed_paths, which no path ever equals.

@Test func aCollapseTheTreeWritesIsOneTheTwirlActionRemoves() {
    let model = twoLayers()
    setLayersCollapsedPaths(model: model, [[1]])
    #expect(layersCollapsedPaths(model: model) == [[1]], "positive control: the write reads back")
    LayersPanel.dispatchYamlAction("toggle_element_twirl", model: model, params: ["path": ["__path__": [1]]])
    #expect(layersCollapsedPaths(model: model) == [], "the YAML toggle found the tree's entry")
}

@Test func aCollapseTheTwirlActionWritesIsOneTheTreeReads() {
    let model = twoLayers()
    #expect(layersCollapsedPaths(model: model) == [])
    LayersPanel.dispatchYamlAction("toggle_element_twirl", model: model, params: ["path": ["__path__": [1, 0]]])
    #expect(layersCollapsedPaths(model: model) == [[1, 0]])
}

@Test func arrowLeftOnAnExpandedContainerCollapsesItForTheTree() {
    let model = twoLayers()
    setLayersPanelSelection(model: model, [[1]])
    #expect(LayersPanel.treeKey(KeyChord(key: "ArrowLeft"), model: model))
    #expect(layersCollapsedPaths(model: model) == [[1]])
    #expect(LayersPanel.treeKey(KeyChord(key: "ArrowRight"), model: model))
    #expect(layersCollapsedPaths(model: model) == [], "Right expands what Left collapsed")
}

@Test func aCollapsedContainerTheTreeWroteHidesItsRowsFromTheKeys() {
    // [1] collapsed: the visible rows are [1] [0] [0,0], so Down from [1] lands
    // on [0], not on the hidden [1,0].
    let model = twoLayers()
    setLayersCollapsedPaths(model: model, [[1]])
    setLayersPanelSelection(model: model, [[1]])
    #expect(LayersPanel.treeKey(KeyChord(key: "ArrowDown"), model: model))
    #expect(layersPanelSelection(model: model) == [[0]])
}

// MARK: - layers_panel_selection

@Test func theTreeSelectionIsStoredSortedAsPathMarkers() {
    let model = twoLayers()
    setLayersPanelSelection(model: model, [[1], [0, 0], [0]])
    #expect(layersPanelSelection(model: model) == [[0], [0, 0], [1]])
    let raw = model.stateStore.getPanel("layers_panel_content", "layers_panel_selection") as? [Any]
    #expect((raw?.first as? [String: Any])?["__path__"] as? [Int] == [0])
}

@Test func aKeyMovesTheSelectionTheTreeWrote() {
    let model = twoLayers()
    setLayersPanelSelection(model: model, [[1]])
    #expect(LayersPanel.treeKey(KeyChord(key: "ArrowDown"), model: model))
    #expect(layersPanelSelection(model: model) == [[1, 0]])
}

// MARK: - renaming_element

@Test func f2StartsARenameTheTreeReads() {
    let model = twoLayers()
    setLayersPanelSelection(model: model, [[1, 0]])
    #expect(layersRenamingPath(model: model) == nil)
    #expect(LayersPanel.treeKey(KeyChord(key: "F2"), model: model))
    #expect(layersRenamingPath(model: model) == [1, 0])
}

@Test func escapeCancelsARenameTheTreeStarted() {
    let model = twoLayers()
    setLayersRenamingPath(model: model, [0])
    #expect(layersRenamingPath(model: model) == [0], "positive control: the write reads back")
    #expect(LayersPanel.treeKey(KeyChord(key: "Escape"), model: model))
    #expect(layersRenamingPath(model: model) == nil)
}

@Test func clearingTheRenameStoresNull() {
    let model = twoLayers()
    setLayersRenamingPath(model: model, [0])
    setLayersRenamingPath(model: model, nil)
    #expect(layersRenamingPath(model: model) == nil)
    #expect(model.stateStore.getPanel("layers_panel_content", "renaming_element") is NSNull)
}

// MARK: - an uninitialised store

@Test func theTreeWritersInitialiseTheLayersPanel() {
    // The tree can draw before anything has initialised the panel's state; the
    // writers seed it from the workspace defaults rather than dropping the write.
    let model = Model(document: Document(layers: [Layer(children: [])]))
    #expect(!model.stateStore.hasPanel("layers_panel_content"))
    setLayersCollapsedPaths(model: model, [[0]])
    #expect(layersCollapsedPaths(model: model) == [[0]])
    #expect(model.stateStore.getPanel("layers_panel_content", "type_filter") != nil,
            "seeded from the defaults, not created empty")
}

// MARK: - the tree's key hook

// `layersTreeKeyChord` is the hook's translation of a SwiftUI key press into the
// chord `LayersPanel.treeKey` resolves. Delete/Backspace stay with the view's
// native monitor (its orphan-confirm Delete), so the hook does not name them.

@Test func theTreeHookNamesTheKeysLayersYamlBindsAndNoOthers() {
    #expect(layersTreeKeyChord(.upArrow, []) == KeyChord(key: "ArrowUp"))
    #expect(layersTreeKeyChord(.downArrow, []) == KeyChord(key: "ArrowDown"))
    #expect(layersTreeKeyChord(.leftArrow, []) == KeyChord(key: "ArrowLeft"))
    #expect(layersTreeKeyChord(.rightArrow, []) == KeyChord(key: "ArrowRight"))
    #expect(layersTreeKeyChord(.return, []) == KeyChord(key: "Enter"))
    #expect(layersTreeKeyChord(.escape, []) == KeyChord(key: "Escape"))
    #expect(layersTreeKeyChord(KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), [])
            == KeyChord(key: "F2"))
    #expect(layersTreeKeyChord(.delete, []) == nil, "native: the orphan-confirm Delete")
    #expect(layersTreeKeyChord(.deleteForward, []) == nil)
    #expect(layersTreeKeyChord("a", .command) == KeyChord(key: "A", ctrl: true),
            "⌘A is the Ctrl+A row (`layers_select_all`)")
    #expect(layersTreeKeyChord("a", []) == nil, "a plain letter is not the tree's")
    #expect(layersTreeKeyChord("x", []) == nil)
}

@Test func theTreeHookCarriesModifiersWithCommandAsCtrl() {
    #expect(layersTreeKeyChord(.downArrow, .shift) == KeyChord(key: "ArrowDown", shift: true))
    #expect(layersTreeKeyChord(.downArrow, .command) == KeyChord(key: "ArrowDown", ctrl: true))
    #expect(layersTreeKeyChord(.downArrow, .option) == KeyChord(key: "ArrowDown", alt: true))
}

@Test func everyKeyTheHookNamesResolvesToALayersRow() {
    // The other direction: a name the hook produces that no row binds would be
    // a key the hook swallows for nothing (it returns .handled only on a
    // dispatch, but a typo here would read as "no row" forever).
    let model = twoLayers()
    setLayersPanelSelection(model: model, [[1]])
    guard let ws = WorkspaceData.load(),
          let panel = (ws.data["panels"] as? [String: Any])?["layers_panel_content"] else {
        Issue.record("no layers panel"); return
    }
    let ctx = LayersPanel.actionContext(model: model, ws: ws, panelSelection: [],
                                        artboardsPanelSelection: [], params: [:])
    let keys: [(KeyEquivalent, EventModifiers)] = [
        (.upArrow, []), (.downArrow, []), (.leftArrow, []), (.rightArrow, []), (.return, []), (.escape, []),
        (KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), []), ("a", .command)]
    for (k, mods) in keys {
        let chord = layersTreeKeyChord(k, mods)!
        #expect(resolvePanelKey(panel, chord: chord, context: ctx) != nil, "\(chord.key)")
    }
}

@Test func aKeyTheTreeTakesRedrawsTheViewsReadingTheStore() {
    // Left's `list_toggle` writes the store and publishes nothing, so without a
    // bump the tree reads the new collapsed_paths only at its next unrelated
    // redraw.
    let model = twoLayers()
    setLayersPanelSelection(model: model, [[1]])
    let before = model.panelStateVersion
    #expect(LayersPanel.treeKey(KeyChord(key: "ArrowLeft"), model: model))
    #expect(model.panelStateVersion != before)
    let unbound = model.panelStateVersion
    #expect(!LayersPanel.treeKey(KeyChord(key: "X"), model: model))
    #expect(model.panelStateVersion == unbound, "an unbound key changes nothing")
}

@Test func commandASelectsEveryVisibleRowThroughTheYaml() {
    // `layers_select_all` runs its YAML (the visible rows, scoped to an
    // isolation); the tree's native select-all, which took every element path,
    // is gone.
    let model = twoLayers()
    setLayersPanelSelection(model: model, [[1]])
    #expect(LayersPanel.treeKey(KeyChord(key: "A", ctrl: true), model: model))
    #expect(layersPanelSelection(model: model) == [[1], [1, 0], [0], [0, 0]], "rows, top first")
}

@Test func commandAInIsolationSelectsOnlyTheIsolatedSubtree() {
    let model = twoLayers()
    setLayersPanelSelection(model: model, [[1]])
    model.layersIsolationStack = [[1]]
    #expect(LayersPanel.treeKey(KeyChord(key: "A", ctrl: true), model: model))
    #expect(layersPanelSelection(model: model) == [[1, 0]])
}
