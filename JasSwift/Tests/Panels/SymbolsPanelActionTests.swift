import Testing
@testable import JasLib

/// Integration tests for the Symbols panel's native action arms
/// (SYMBOLS.md §8, P3). Each test drives a full action via
/// `SymbolsPanel.dispatchSymbolAction`, mirroring the Rust lead's
/// dispatch_action symbol-arm tests: the arms mint ids by the
/// value-in-op rule, snapshot, and call the shared Controller ops, plus
/// maintain the panel-selected master state.

// MARK: - Data exposure (active_document.symbols)

@Test func activeDocumentSymbolsEmptyByDefault() {
    let model = Model(document: Document(layers: [Layer(children: [])]))
    let view = buildActiveDocumentView(model: model)
    let symbols = view["symbols"] as? [[String: Any]]
    #expect(symbols?.isEmpty == true)
}

@Test func activeDocumentSymbolsExposesNameFallbackAndUsageCount() {
    // One named master with one instance, one unnamed master with none.
    let named = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                  name: "Star", id: "M1"))
    let unnamed = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, id: "M2"))
    let instance = Element.live(.reference(ReferenceElem(
        target: ElementRef("M1"), name: nil, id: "R1")))
    let doc = Document(
        layers: [Layer(children: [instance])],
        symbols: [named, unnamed]
    )
    let view = buildActiveDocumentView(model: Model(document: doc))
    let symbols = view["symbols"] as? [[String: Any]]
    #expect(symbols?.count == 2)
    // Named master: keeps its name, usage_count = 1 (one instance).
    #expect(symbols?[0]["name"] as? String == "Star")
    #expect(symbols?[0]["usage_count"] as? Int == 1)
    #expect(symbols?[0]["id"] as? String == "M1")
    // Unnamed master: positional "Symbol N" fallback, usage_count = 0.
    #expect(symbols?[1]["name"] as? String == "Symbol 2")
    #expect(symbols?[1]["usage_count"] as? Int == 0)
}

// MARK: - new_symbol

@Test func newSymbolPromotesSingleSelectionToMaster() {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let doc = Document(layers: [Layer(children: [rect])],
                       selection: [ElementSelection.all([0, 0])])
    let model = Model(document: doc)
    // The panel's scope exists on every production route (the dock renders
    // the panel; `panelDispatch` seeds it), and a `set_panel_state` to a
    // missing scope is dropped in every port, the reference included.
    model.stateStore.initPanel("symbols_panel_content", defaults: [:])
    LayersPanel.dispatchYamlAction("new_symbol", model: model)
    // The master now lives off-canvas, an instance sits in its place.
    #expect(model.document.symbols.count == 1)
    if case .live(.reference) = model.document.layers[0].children[0] {
        // ok — the in-place element is now an instance
    } else {
        Issue.record("expected an instance in place of the promoted element")
    }
    // The new master is panel-selected (target of Place / Delete), by the
    // YAML's `as: master` + `set_panel_state`.
    #expect(SymbolsPanel.selectedSymbol(model) == model.document.symbols.first?.id)
    #expect(SymbolsPanel.selectedSymbol(model) != nil)
    // Undo restores the original (single snapshot).
    model.undo()
    #expect(model.document.symbols.isEmpty)
}

@Test func newSymbolNoOpWithoutSingleWholeSelection() {
    // Empty selection: no-op.
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let model = Model(document: Document(layers: [Layer(children: [rect])]))
    LayersPanel.dispatchYamlAction("new_symbol", model: model)
    #expect(model.document.symbols.isEmpty)
    #expect(SymbolsPanel.selectedSymbol(model) == nil)
}

// MARK: - place_instance

@Test func placeInstanceAppendsInstanceOfSelectedMaster() {
    let master = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, id: "M1"))
    let doc = Document(layers: [Layer(children: [])], symbols: [master])
    let model = Model(document: doc)
    model.stateStore.initPanel("symbols_panel_content", defaults: [:])
    model.stateStore.setPanel("symbols_panel_content", "selected_symbol", "M1")
    LayersPanel.dispatchYamlAction("place_instance", model: model)
    // A new instance targeting M1 was appended to the active layer.
    let kids = model.document.layers[model.document.selectedLayer].children
    let instances = kids.filter {
        if case .live(.reference(let r)) = $0 { return r.target.id == "M1" }
        return false
    }
    #expect(instances.count == 1)
}

@Test func placeInstanceNoOpWhenNoMasterSelected() {
    let master = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, id: "M1"))
    let doc = Document(layers: [Layer(children: [])], symbols: [master])
    let model = Model(document: doc)
    LayersPanel.dispatchYamlAction("place_instance", model: model)
    #expect(model.document.layers[0].children.isEmpty)
}

// MARK: - delete_symbol_action (no instances → silent)

@Test func deleteSymbolWithNoInstancesDeletesSilently() {
    let master = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, id: "M1"))
    let doc = Document(layers: [Layer(children: [])], symbols: [master])
    let model = Model(document: doc)
    model.stateStore.initPanel("symbols_panel_content", defaults: [:])
    model.stateStore.setPanel("symbols_panel_content", "selected_symbol", "M1")
    // No instances → usage 0 → no confirm modal, deletes inline.
    SymbolsPanel.dispatchSymbolAction("delete_symbol_action", model: model)
    #expect(model.document.symbols.isEmpty)
    // Panel selection cleared after delete.
    #expect(SymbolsPanel.selectedSymbol(model) == nil)
}

// The Symbols panel menu's New Symbol, through the production route
// (`panelDispatch`, which seeds the panel's scope first): the YAML runs and
// the master is panel-selected, on a bare Model with no scope seeded by hand.
@Test func newSymbolFromThePanelMenuSelectsTheMaster() {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, id: "r1"))
    let model = Model(document: Document(layers: [Layer(children: [rect])],
                                         selection: [ElementSelection.all([0, 0])]))
    var layout = WorkspaceLayout.defaultLayout()
    panelDispatch(.symbols, cmd: "new_symbol",
                  addr: PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0),
                  layout: &layout, model: model)
    #expect(model.document.symbols.first?.id == "r1", "an element keeps its own id as the master's")
    #expect(SymbolsPanel.selectedSymbol(model) == "r1", "and the panel selects it")
}
