import Testing
import AppKit
@testable import JasLib

// SH-5: the render-signature gate that stops updateNSView from repainting the
// whole canvas on every SwiftUI update. Canvas-relevant changes must change the
// signature (so they still repaint); canvas-irrelevant @Published churn must
// NOT (so the redundant repaint is dropped).

private func modelWithRect() -> Model {
    let doc = Document(layers: [Layer(children: [.rect(Rect(x: 0, y: 0, width: 10, height: 10))])],
                       selectedLayer: 0, selection: [])
    return Model(document: doc)
}

private func sig(_ m: Model, tool: Tool = .selection, sel: [String] = []) -> CanvasRenderSignature {
    CanvasRenderSignature(model: m, tool: tool, artboardsPanelSelection: sel)
}

@Test func signatureStableWhenNothingChanges() {
    let m = modelWithRect()
    #expect(sig(m) == sig(m))
}

// MARK: - canvas-relevant changes DO change the signature

@Test func signatureChangesOnDocumentEdit() {
    let m = modelWithRect()
    let before = sig(m)
    m.editDocument(m.document.replacing(
        layers: [Layer(children: [.rect(Rect(x: 5, y: 5, width: 10, height: 10))])]))
    #expect(sig(m) != before)
}

@Test func signatureChangesOnSelection() {
    let m = modelWithRect()
    let before = sig(m)
    m.setDocumentUnbracketed(m.document.replacing(selection: [ElementSelection.all([0, 0])]),
                             intent: .selection)
    #expect(sig(m) != before)
}

@Test func signatureChangesOnViewTransform() {
    let m = modelWithRect()
    let before = sig(m)
    m.zoomLevel = 2.0
    #expect(sig(m) != before)
    let z = sig(m)
    m.viewOffsetX = 40
    #expect(sig(m) != z)
}

@Test func signatureChangesOnTool() {
    let m = modelWithRect()
    #expect(sig(m, tool: .selection) != sig(m, tool: .pen))
}

@Test func signatureChangesOnMaskIsolation() {
    let m = modelWithRect()
    let before = sig(m)
    m.maskIsolationPath = [0]
    #expect(sig(m) != before)
}

@Test func signatureChangesOnEditingTarget() {
    let m = modelWithRect()
    let before = sig(m)
    m.editingTarget = .mask([0, 0])
    #expect(sig(m) != before)
}

@Test func signatureChangesOnArtboardsPanelSelection() {
    let m = modelWithRect()
    #expect(sig(m, sel: []) != sig(m, sel: ["ab1"]))
}

@Test func signatureChangesOnAlignKeyObject() {
    let m = modelWithRect()
    let before = sig(m)
    m.stateStore.set("align_key_object_path", ["__path__": [0, 0]])
    #expect(sig(m) != before)
}

@Test func signatureDistinguishesModelsAtSameGeneration() {
    // Two fresh models both have generation 0; the model identity must still
    // distinguish them so a tab switch repaints.
    let a = modelWithRect()
    let b = modelWithRect()
    #expect(a.generation == b.generation)
    #expect(sig(a) != sig(b))
}

// MARK: - canvas-IRRELEVANT churn does NOT change the signature

@Test func signatureIgnoresRecentColors() {
    let m = modelWithRect()
    let before = sig(m)
    m.recentColors = ["#ff0000", "#00ff00"]
    #expect(sig(m) == before)
}

@Test func signatureIgnoresPanelStateVersion() {
    let m = modelWithRect()
    let before = sig(m)
    m.panelStateVersion += 1
    #expect(sig(m) == before)
}

@Test func signatureIgnoresDefaultFillAndFilename() {
    let m = modelWithRect()
    let before = sig(m)
    m.defaultFill = Fill(color: .rgb(r: 1, g: 0, b: 0, a: 1))
    m.filename = "renamed"
    #expect(sig(m) == before)
}

// MARK: - the view-level gate

@Test func repaintGateFiresOnlyOnChange() {
    let m = modelWithRect()
    let view = CanvasNSView()
    view.document = m.document
    view.controller = Controller(model: m)
    // First call: no prior signature → repaint.
    #expect(view.repaintIfRenderStateChanged())
    // No change → no repaint.
    #expect(!view.repaintIfRenderStateChanged())
    // A canvas-relevant change → repaint again.
    m.zoomLevel = 3.0
    #expect(view.repaintIfRenderStateChanged())
    #expect(!view.repaintIfRenderStateChanged())
    // Irrelevant churn → still no repaint.
    m.panelStateVersion += 1
    #expect(!view.repaintIfRenderStateChanged())
}

@Test func repaintGateForcesRepaintWithoutModel() {
    let view = CanvasNSView()  // no controller/model attached
    #expect(view.repaintIfRenderStateChanged())
}
