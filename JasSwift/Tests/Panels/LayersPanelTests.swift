import Testing
import Foundation
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

@Test func newLayerViaYamlNoSelection() {
    let model = Model(document: Document(layers: [
        Layer(name: "Layer 1", children: []),
    ]))
    LayersPanel.dispatchYamlAction("new_layer", model: model)
    #expect(model.document.layers.count == 2)
    #expect(model.document.layers[1].name == "Layer 2")
}

@Test func newLayerViaYamlInsertsAboveSelection() {
    let model = Model(document: Document(layers: [
        Layer(name: "Layer 1", children: []),
        Layer(name: "Layer 2", children: []),
        Layer(name: "Layer 3", children: []),
    ]))
    LayersPanel.dispatchYamlAction("new_layer", model: model,
                                    panelSelection: [[1]])
    #expect(model.document.layers.count == 4)
    // Inserted at index 2, next unused after Layer 1/2/3 is Layer 4
    #expect(model.document.layers[2].name == "Layer 4")
    #expect(model.document.layers[3].name == "Layer 3")
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

@Test func deleteLayerSelectionHandlesNestedPath() {
    // Nested selection: Layer → Group → Element. doc.delete_at's
    // handler now walks the Element tree instead of being restricted
    // to top-level, so deleting a nested path removes it in place.
    let nested = Group(children: [
        Element.rect(Rect(x: 0, y: 0, width: 10, height: 10)),
        Element.rect(Rect(x: 20, y: 0, width: 10, height: 10)),
    ])
    let topLayer = Layer(name: "A", children: [Element.group(nested)])
    let model = Model(document: Document(layers: [topLayer]))
    LayersPanel.dispatchYamlAction("delete_layer_selection",
                                    model: model,
                                    panelSelection: [[0, 0, 1]])
    // After: the group at [0, 0] has one child left
    let layer = model.document.layers[0]
    guard case .group(let g) = layer.children[0] else {
        Issue.record("expected group at [0,0]"); return
    }
    #expect(g.children.count == 1)
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

@Test func newGroupWrapsSelectedChildrenInGroup() {
    // Wrap two of three sibling rects into a new Group at the
    // topmost source position.
    let children: [Element] = [
        .rect(Rect(x: 0, y: 0, width: 10, height: 10)),
        .rect(Rect(x: 20, y: 0, width: 10, height: 10)),
        .rect(Rect(x: 40, y: 0, width: 10, height: 10)),
    ]
    let model = Model(document: Document(layers: [
        Layer(name: "L", children: children),
    ]))
    LayersPanel.dispatchYamlAction("new_group",
                                    model: model,
                                    panelSelection: [[0, 0], [0, 1]])
    let layer = model.document.layers[0]
    #expect(layer.children.count == 2)
    guard case .group(let g) = layer.children[0] else {
        Issue.record("expected group at layer.children[0]"); return
    }
    #expect(g.children.count == 2)
    // The trailing rect at original index 2 should still be at index 1
    // of the rewritten layer.
    guard case .rect = layer.children[1] else {
        Issue.record("expected rect at layer.children[1]"); return
    }
}

@Test func newGroupEmptySelectionIsNoop() {
    let children: [Element] = [
        .rect(Rect(x: 0, y: 0, width: 10, height: 10)),
    ]
    let model = Model(document: Document(layers: [
        Layer(name: "L", children: children),
    ]))
    LayersPanel.dispatchYamlAction("new_group",
                                    model: model,
                                    panelSelection: [])
    // Document unchanged.
    #expect(model.document.layers[0].children.count == 1)
    guard case .rect = model.document.layers[0].children[0] else {
        Issue.record("expected unchanged rect"); return
    }
}

@Test func newGroupMixedParentsIsNoop() {
    // Selection that spans two different layers violates the
    // same-parent invariant; handler must refuse to mutate.
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: [
            .rect(Rect(x: 0, y: 0, width: 10, height: 10)),
        ]),
        Layer(name: "B", children: [
            .rect(Rect(x: 20, y: 0, width: 10, height: 10)),
        ]),
    ]))
    LayersPanel.dispatchYamlAction("new_group",
                                    model: model,
                                    panelSelection: [[0, 0], [1, 0]])
    // Both layers unchanged.
    #expect(model.document.layers.count == 2)
    #expect(model.document.layers[0].children.count == 1)
    #expect(model.document.layers[1].children.count == 1)
}

@Test func flattenArtworkUnpacksSingleGroup() {
    // A group containing two rects gets unpacked; the rects take the
    // group's position in the parent layer.
    let inner: [Element] = [
        .rect(Rect(x: 0, y: 0, width: 10, height: 10)),
        .rect(Rect(x: 20, y: 0, width: 10, height: 10)),
    ]
    let group = Element.group(Group(children: inner))
    let model = Model(document: Document(layers: [
        Layer(name: "L", children: [group]),
    ]))
    LayersPanel.dispatchYamlAction("flatten_artwork",
                                    model: model,
                                    panelSelection: [[0, 0]])
    let layer = model.document.layers[0]
    #expect(layer.children.count == 2)
    for child in layer.children {
        guard case .rect = child else {
            Issue.record("expected rect after unpacking"); return
        }
    }
}

@Test func flattenArtworkPreservesSurroundingSiblings() {
    // Group sandwiched between two rects. After unpacking, the group's
    // children replace the group in place, preserving sibling order.
    let before = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let group = Element.group(Group(children: [
        Element.rect(Rect(x: 20, y: 0, width: 10, height: 10)),
        Element.rect(Rect(x: 40, y: 0, width: 10, height: 10)),
    ]))
    let after = Element.rect(Rect(x: 60, y: 0, width: 10, height: 10))
    let model = Model(document: Document(layers: [
        Layer(name: "L", children: [before, group, after]),
    ]))
    LayersPanel.dispatchYamlAction("flatten_artwork",
                                    model: model,
                                    panelSelection: [[0, 1]])
    let kids = model.document.layers[0].children
    // Expect 4 rects in sequence: [before, inner[0], inner[1], after].
    #expect(kids.count == 4)
    let bounds = kids.map { $0.bounds }
    #expect(bounds[0].x == 0)
    #expect(bounds[1].x == 20)
    #expect(bounds[2].x == 40)
    #expect(bounds[3].x == 60)
}

@Test func collectInNewLayerViaYamlDispatch() {
    let model = Model(document: Document(layers: [
        Layer(name: "Layer 1", children: []),
        Layer(name: "Layer 2", children: []),
        Layer(name: "Layer 3", children: []),
    ]))
    LayersPanel.dispatchYamlAction("collect_in_new_layer",
                                    model: model,
                                    panelSelection: [[0], [2]])
    #expect(model.document.layers.count == 2)
    #expect(model.document.layers[0].name == "Layer 2")
    // Next unused name after Layer 1/2/3 is Layer 4; contains the two
    // wrapped source layers as Element.layer children.
    #expect(model.document.layers[1].name == "Layer 4")
    #expect(model.document.layers[1].children.count == 2)
}

@Test func enterIsolationModePushesPanelSelection() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: []),
        Layer(name: "B", children: []),
    ]))
    #expect(model.layersIsolationStack.isEmpty)
    LayersPanel.dispatchYamlAction("enter_isolation_mode",
                                    model: model,
                                    panelSelection: [[1]])
    #expect(model.layersIsolationStack.count == 1)
    #expect(model.layersIsolationStack[0] == [1])
}

@Test func listPushInsideIfThen() {
    // list_push nested inside if-then. Tests that runOne's if handler
    // propagates threadedCtx into the nested runEffects invocation.
    var calls = 0
    let handler: PlatformEffect = { _, _, _ in calls += 1; return nil }
    let effects: [Any] = [
        ["if": ["condition": "true",
                "then": [
                    ["list_push": ["target": "panel.isolation_stack",
                                    "value": "path(1)"]]
                ]]],
    ]
    runEffects(effects, ctx: [:], store: StateStore(),
               platformEffects: ["list_push": handler])
    #expect(calls == 1)
}

@Test func listPushHandlerInvokedAtTopLevel() {
    // Minimal: list_push at the top of an effect list (no let, no if).
    // Isolates the handler dispatch from every other effect.
    var handlerCalled = false
    var seenTarget = ""
    var seenValue: Value = .null
    let handler: PlatformEffect = { value, callCtx, _ in
        handlerCalled = true
        if let spec = value as? [String: Any] {
            seenTarget = (spec["target"] as? String) ?? ""
            if let vexp = spec["value"] as? String {
                seenValue = evaluate(vexp, context: callCtx)
            }
        }
        return nil
    }
    let effects: [Any] = [
        ["list_push": ["target": "panel.isolation_stack",
                        "value": "path(1)"]],
    ]
    runEffects(effects, ctx: [:], store: StateStore(),
               platformEffects: ["list_push": handler])
    #expect(handlerCalled)
    #expect(seenTarget == "panel.isolation_stack")
    if case .path(let p) = seenValue { #expect(p == [1]) }
    else { Issue.record("expected .path value, got \(seenValue)") }
}

@Test func listPushPlatformHandlerDirect() {
    // Verify the list_push platform handler path fires with a
    // bare-metal effect (no YAML loading). Isolates the
    // let/if/list_push pipeline from yaml parsing.
    var stackCalls: [[Int]] = []
    let listPushHandler: PlatformEffect = { value, callCtx, _ in
        guard let spec = value as? [String: Any] else { return nil }
        let target = (spec["target"] as? String) ?? ""
        guard target == "panel.isolation_stack" else { return nil }
        let valueExpr = (spec["value"] as? String) ?? "null"
        let val = evaluate(valueExpr, context: callCtx)
        if case .path(let idx) = val { stackCalls.append(idx) }
        return nil
    }
    let effects: [Any] = [
        ["let": ["target": "panel.layers_panel_selection[0]"]],
        ["if": ["condition": "target != null",
                "then": [
                    ["list_push": ["target": "panel.isolation_stack",
                                    "value": "target"]]
                ]]],
    ]
    let ctx: [String: Any] = [
        "panel": [
            "layers_panel_selection": [["__path__": [1]]],
        ],
    ]
    runEffects(effects, ctx: ctx, store: StateStore(),
               platformEffects: ["list_push": listPushHandler])
    #expect(stackCalls == [[1]])
}

@Test func layerOptionsConfirmEditModeUpdatesLayer() {
    let model = Model(document: Document(layers: [
        Layer(name: "Old", children: [], visibility: .preview),
    ]))
    var closed = false
    LayersPanel.dispatchYamlAction(
        "layer_options_confirm",
        model: model,
        params: [
            "layer_id": "0",
            "name": "Renamed",
            "lock": true,
            "show": true,
            "preview": false,   // show=true + preview=false → outline
        ],
        onCloseDialog: { closed = true }
    )
    #expect(closed)
    #expect(model.document.layers[0].name == "Renamed")
    #expect(model.document.layers[0].locked == true)
    #expect(model.document.layers[0].visibility == .outline)
}

@Test func layerOptionsConfirmCreateModeAppendsLayer() {
    let model = Model(document: Document(layers: [
        Layer(name: "Existing", children: []),
    ]))
    var closed = false
    LayersPanel.dispatchYamlAction(
        "layer_options_confirm",
        model: model,
        params: [
            "layer_id": NSNull(),
            "name": "Brand New",
            "lock": false,
            "show": true,
            "preview": true,
        ],
        onCloseDialog: { closed = true }
    )
    #expect(closed)
    #expect(model.document.layers.count == 2)
    #expect(model.document.layers[1].name == "Brand New")
    #expect(model.document.layers[1].visibility == .preview)
}

@Test func exitIsolationModePopsStack() {
    let model = Model(document: Document(layers: [
        Layer(name: "A", children: []),
    ]))
    model.layersIsolationStack = [[0]]
    LayersPanel.dispatchYamlAction("exit_isolation_mode", model: model)
    #expect(model.layersIsolationStack.isEmpty)
}

// Shared mutable layout for tests — not exercised by dispatch here.
private var defaultLayout: WorkspaceLayout = WorkspaceLayout.defaultLayout()
