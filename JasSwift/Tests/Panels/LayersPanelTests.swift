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

// Shared mutable layout for tests — not exercised by dispatch here.
private var defaultLayout: WorkspaceLayout = WorkspaceLayout.defaultLayout()
