import Testing
@testable import JasLib

// MARK: - Phase 3: Group A toggle actions via YAML dispatch

private func makeLayersPanelAddr() -> PanelAddr {
    // Any PanelAddr works for these tests — dispatch doesn't modify the
    // layout for toggle_all_layers_* commands.
    return PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0)
}

@Test func toggleAllLayersVisibilityViaYaml() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: [], visibility: .preview),
    ]))
    LayersPanel.dispatch("toggle_all_layers_visibility",
                         addr: makeLayersPanelAddr(),
                         layout: &defaultLayout, model: model)
    // Preview → any_visible=true → target=invisible
    #expect(model.document.layers[0].visibility == .invisible)
}

@Test func toggleAllLayersVisibilityAllInvisibleToPreview() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: [], visibility: .invisible),
        Layer(name: "B", children: [], visibility: .invisible),
    ]))
    LayersPanel.dispatch("toggle_all_layers_visibility",
                         addr: makeLayersPanelAddr(),
                         layout: &defaultLayout, model: model)
    #expect(model.document.layers[0].visibility == .preview)
    #expect(model.document.layers[1].visibility == .preview)
}

@Test func toggleAllLayersLockViaYaml() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: [], locked: false),
    ]))
    LayersPanel.dispatch("toggle_all_layers_lock",
                         addr: makeLayersPanelAddr(),
                         layout: &defaultLayout, model: model)
    #expect(model.document.layers[0].locked == true)
}

@Test func toggleAllLayersOutlineViaYaml() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: [], visibility: .preview),
    ]))
    LayersPanel.dispatch("toggle_all_layers_outline",
                         addr: makeLayersPanelAddr(),
                         layout: &defaultLayout, model: model)
    // Preview → any_preview=true → target=outline
    #expect(model.document.layers[0].visibility == .outline)
}

// MARK: - Phase 3 Group B: doc.delete_at / doc.clone_at / doc.insert_after

private func runLayersEffects(_ effects: [Any], model: Model) {
    // Minimal wrapper: mimic LayersPanel.dispatchYamlAction's platform
    // handler registration. Used to test Group B primitives in isolation
    // without requiring a full workspace/actions.yaml round-trip.
    let snapshotHandler: PlatformEffect = { _, _, _ in model.snapshot(); return nil }
    let docDeleteAtHandler: PlatformEffect = { value, callCtx, _ in
        guard let pathExpr = value as? String else { return nil }
        let pathVal = evaluate(pathExpr, context: callCtx)
        guard case .path(let indices) = pathVal,
              indices.count == 1,
              indices[0] >= 0 && indices[0] < model.document.layers.count
        else { return nil }
        let idx = indices[0]
        let removed = model.document.layers[idx]
        var newLayers = model.document.layers
        newLayers.remove(at: idx)
        model.document = Document(layers: newLayers,
                                   selectedLayer: model.document.selectedLayer,
                                   selection: model.document.selection)
        return removed
    }
    let docCloneAtHandler: PlatformEffect = { value, callCtx, _ in
        guard let pathExpr = value as? String else { return nil }
        let pathVal = evaluate(pathExpr, context: callCtx)
        guard case .path(let indices) = pathVal,
              indices.count == 1,
              indices[0] >= 0 && indices[0] < model.document.layers.count
        else { return nil }
        return model.document.layers[indices[0]]
    }
    let docInsertAfterHandler: PlatformEffect = { value, callCtx, _ in
        guard let spec = value as? [String: Any] else { return nil }
        let pathExpr = (spec["path"] as? String) ?? ""
        let pathVal = evaluate(pathExpr, context: callCtx)
        guard case .path(let indices) = pathVal,
              indices.count == 1
        else { return nil }
        let newElement: Layer?
        if let layer = spec["element"] as? Layer { newElement = layer }
        else if let name = spec["element"] as? String,
                let layer = callCtx[name] as? Layer { newElement = layer }
        else { newElement = nil }
        guard let elem = newElement else { return nil }
        let insertIdx = min(indices[0] + 1, model.document.layers.count)
        var newLayers = model.document.layers
        newLayers.insert(elem, at: insertIdx)
        model.document = Document(layers: newLayers,
                                   selectedLayer: model.document.selectedLayer,
                                   selection: model.document.selection)
        return nil
    }
    let platformEffects: [String: PlatformEffect] = [
        "snapshot": snapshotHandler,
        "doc.delete_at": docDeleteAtHandler,
        "doc.clone_at": docCloneAtHandler,
        "doc.insert_after": docInsertAfterHandler,
    ]
    runEffects(effects, ctx: [:], store: StateStore(),
               platformEffects: platformEffects)
}

@Test func docDeleteAtTopLevel() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: []),
        Layer(name: "B", children: []),
        Layer(name: "C", children: []),
    ]))
    runLayersEffects([
        ["doc.delete_at": "path(1)"],
    ], model: model)
    #expect(model.document.layers.count == 2)
    #expect(model.document.layers[0].name == "A")
    #expect(model.document.layers[1].name == "C")
}

@Test func docCloneAtThenInsertAfterDuplicates() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: []),
        Layer(name: "B", children: []),
    ]))
    runLayersEffects([
        ["doc.clone_at": "path(0)", "as": "clone"],
        ["doc.insert_after": ["path": "path(0)", "element": "clone"]],
    ], model: model)
    #expect(model.document.layers.count == 3)
    #expect(model.document.layers[0].name == "A")
    #expect(model.document.layers[1].name == "A")
    #expect(model.document.layers[2].name == "B")
}

@Test func docDeleteAtReverseOrderViaForeach() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: []),
        Layer(name: "B", children: []),
        Layer(name: "C", children: []),
        Layer(name: "D", children: []),
    ]))
    runLayersEffects([
        ["foreach": ["source": "[path(2), path(0)]", "as": "p"],
         "do": [["doc.delete_at": "p"]]],
    ], model: model)
    #expect(model.document.layers.count == 2)
    #expect(model.document.layers[0].name == "B")
    #expect(model.document.layers[1].name == "D")
}

@Test func deleteLayerSelectionViaYamlDispatch() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: []),
        Layer(name: "B", children: []),
        Layer(name: "C", children: []),
    ]))
    LayersPanel.dispatchYamlAction("delete_layer_selection",
                                    model: model,
                                    panelSelection: [[0], [2]])
    #expect(model.document.layers.count == 1)
    #expect(model.document.layers[0].name == "B")
}

@Test func duplicateLayerSelectionViaYamlDispatch() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: []),
        Layer(name: "B", children: []),
    ]))
    LayersPanel.dispatchYamlAction("duplicate_layer_selection",
                                    model: model,
                                    panelSelection: [[1]])
    #expect(model.document.layers.count == 3)
    #expect(model.document.layers[0].name == "A")
    #expect(model.document.layers[1].name == "B")
    #expect(model.document.layers[2].name == "B")
}

// Shared mutable layout for tests — not exercised by dispatch here.
private var defaultLayout: WorkspaceLayout = WorkspaceLayout.defaultLayout()
