import Testing
import Foundation
@testable import JasLib

// Combined selection-VARIANT gesture-seam tests for the YAML tool
// runtime. Ports the Rust reference seam tests
// (jas_dioxus/src/tools/yaml_tool.rs) for three harder selection
// tools that hit-test the document and (for partial_selection) run the
// alt-drag-copy preview state machine:
//
//   partial_selection — CP click / marquee / at-press-alt-copy /
//                       mid-drag-alt-copy / mid-drag-alt preview /
//                       alt-released-before-mouseup (normal move).
//   lasso            — polygon select / miss / click-clears /
//                       shift-click-preserves / state transitions.
//   interior_selection — click enters group (leaf path) / marquee.
//
// The spec lives in workspace/*.yaml and is byte-identical across the
// five apps, so the expected child counts, selection paths, rect
// positions, and mode strings are exactly the ones the Rust tests
// assert. Setup mirrors YamlSelectionToolTests.swift: the YamlTool
// reads the model's registered document directly (no hit-test
// closures), and the initial selection is seeded via
// Controller.selectElement, just like the base selection test.

// MARK: - Loaders

private func partialSelectionTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["partial_selection"] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

private func lassoTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["lasso"] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

private func interiorSelectionTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["interior_selection"] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

// MARK: - Fixtures

private func makeRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Element {
    .rect(Rect(x: x, y: y, width: w, height: h))
}

/// Rect at (0, 0) 10x10 — control points 0=(0,0), 1=(10,0),
/// 2=(10,10), 3=(0,10). Mirrors Rust `model_with_rect_element`.
private func modelWithRectElement() -> Model {
    let layer = Layer(children: [makeRect(0, 0, 10, 10)])
    return Model(document: Document(
        layers: [layer], selectedLayer: 0, selection: []
    ))
}

/// Single rect at (50, 50, 20, 20). Mirrors Rust
/// `selection_parity_model_for_lasso`.
private func selectionParityModelForLasso() -> Model {
    let layer = Layer(children: [makeRect(50, 50, 20, 20)])
    return Model(document: Document(
        layers: [layer], selectedLayer: 0, selection: []
    ))
}

/// Layer → Group → Rect(50,50,20,20). Mirrors Rust
/// `model_with_rect_inside_group`. The rect lives at path [0, 0, 0].
private func modelWithRectInsideGroup() -> Model {
    let group = Element.group(Group(children: [makeRect(50, 50, 20, 20)]))
    let layer = Layer(name: "L", children: [group])
    return Model(document: Document(
        layers: [layer], selectedLayer: 0, selection: []
    ))
}

// Shared ToolContext: no hit-test closures (the YAML tool reads the
// registered document directly), mirroring YamlSelectionToolTests.
private func makeCtx(model: Model) -> ToolContext {
    ToolContext(
        model: model,
        controller: Controller(model: model),
        hitTestSelection: { _ in false },
        hitTestHandle: { _ in nil },
        hitTestText: { _ in nil },
        hitTestPathCurve: { _, _ in nil },
        requestUpdate: {},
        drawElementOverlay: { _, _, _ in }
    )
}

// Helper: read the rects in the top layer's children at the given index.
private func layerRect(_ model: Model, _ idx: Int) -> Rect? {
    let kids = model.document.layers[0].children
    guard idx < kids.count, case .rect(let r) = kids[idx] else { return nil }
    return r
}

// ── partial_selection ─────────────────────────────────────────────

@Test func partialSelectionClickOnCpSelectsIt() throws {
    let tool = try #require(partialSelectionTool())
    let model = modelWithRectElement()
    let ctx = makeCtx(model: model)
    // Click on CP 0 at (0, 0).
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 0, y: 0, shift: false, alt: false)
    let sel = model.document.selection
    #expect(sel.count == 1)
    #expect(sel.first?.path == [0, 0])
    // The selection kind should include CP 0.
    #expect(sel.first?.kind.contains(0) == true)
    #expect(model.canUndo)
}

@Test func partialSelectionClickEmptyStartsMarquee() throws {
    let tool = try #require(partialSelectionTool())
    let model = modelWithRectElement()
    let ctx = makeCtx(model: model)
    // Click far from any CP.
    tool.onPress(ctx, x: 500, y: 500, shift: false, alt: false)
    #expect(tool.toolState("mode") as? String == "marquee")
    // Release far away → no hits → empty selection.
    tool.onRelease(ctx, x: 600, y: 600, shift: false, alt: false)
    #expect(model.document.selection.isEmpty)
}

@Test func partialSelectionMarqueePicksControlPoints() throws {
    let tool = try #require(partialSelectionTool())
    let model = modelWithRectElement()
    let ctx = makeCtx(model: model)
    // Marquee covering all four CPs (x/y in [0,10]).
    tool.onPress(ctx, x: -5, y: -5, shift: false, alt: false)
    tool.onMove(ctx, x: 15, y: 15, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 15, y: 15, shift: false, alt: false)
    let sel = model.document.selection
    #expect(sel.count == 1)
    #expect(sel.first?.path == [0, 0])
}

@Test func partialSelectionAtPressAltDragCopiesPath() throws {
    // SEL-132 at-press: with the rect selected, press a CP WITH Alt,
    // drag past threshold, release. Exactly one copy inserted.
    let tool = try #require(partialSelectionTool())
    let model = modelWithRectElement()
    Controller(model: model).selectElement([0, 0])
    let ctx = makeCtx(model: model)
    let nBefore = model.document.layers[0].children.count
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: true)
    tool.onMove(ctx, x: 5, y: 0, shift: false, alt: true, dragging: true)
    tool.onMove(ctx, x: 80, y: 0, shift: false, alt: true, dragging: true)
    tool.onRelease(ctx, x: 80, y: 0, shift: false, alt: true)
    let nAfter = model.document.layers[0].children.count
    #expect(nAfter == nBefore + 1)
}

@Test func partialSelectionMidDragAltCopiesPath() throws {
    // SEL-132 mid-drag: press WITHOUT Alt, drag past threshold, press
    // Alt mid-drag, release WITH Alt held. Exactly one copy; original
    // preserved at (0,0) by preview restore, copy at (80,0).
    let tool = try #require(partialSelectionTool())
    let model = modelWithRectElement()
    Controller(model: model).selectElement([0, 0])
    let ctx = makeCtx(model: model)
    let nBefore = model.document.layers[0].children.count
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    // Past 4px threshold, no alt — snapshot, mode=moving, translate (5,0).
    tool.onMove(ctx, x: 5, y: 0, shift: false, alt: false, dragging: true)
    // Alt pressed mid-drag — enter preview, original snaps back to (0,0).
    tool.onMove(ctx, x: 10, y: 0, shift: false, alt: true, dragging: true)
    tool.onMove(ctx, x: 80, y: 0, shift: false, alt: true, dragging: true)
    // Release with Alt still held — commit copy.
    tool.onRelease(ctx, x: 80, y: 0, shift: false, alt: true)
    let kids = model.document.layers[0].children
    #expect(kids.count == nBefore + 1)
    // Original at (0,0) — preview snapped it back.
    if let r = layerRect(model, 0) {
        #expect(r.x == 0)
        #expect(r.y == 0)
    } else {
        Issue.record("expected Rect at index 0 (original)")
    }
    // Copy at (80,0) — translated by (cursor - press).
    if let r = layerRect(model, 1) {
        #expect(r.x == 80)
        #expect(r.y == 0)
    } else {
        Issue.record("expected Rect at index 1 (copy)")
    }
}

@Test func partialSelectionMidDragAltPreviewShowsRealCopy() throws {
    // During the mid-drag alt-preview phase the document holds BOTH the
    // original (snapped to press) AND a real copy at the cursor.
    let tool = try #require(partialSelectionTool())
    let model = modelWithRectElement()
    Controller(model: model).selectElement([0, 0])
    let ctx = makeCtx(model: model)
    let nBefore = model.document.layers[0].children.count
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    tool.onMove(ctx, x: 5, y: 0, shift: false, alt: false, dragging: true)
    // Alt pressed mid-drag — enter preview.
    tool.onMove(ctx, x: 30, y: 0, shift: false, alt: true, dragging: true)
    let kids = model.document.layers[0].children
    #expect(kids.count == nBefore + 1)
    if let r = layerRect(model, 0) {
        #expect(r.x == 0)   // original snapped back to press
    } else {
        Issue.record("expected Rect at index 0 (original)")
    }
    if let r = layerRect(model, 1) {
        #expect(r.x == 30)  // copy at cursor delta from press
    } else {
        Issue.record("expected Rect at index 1 (live copy)")
    }
}

@Test func partialSelectionMidDragAltReleasedBeforeMouseupNoCopy() throws {
    // Press WITHOUT Alt, drag past threshold, press Alt mid-drag,
    // RELEASE Alt before mouseup → normal move, NO copy. Original lands
    // at the cursor (50,0); child count unchanged.
    let tool = try #require(partialSelectionTool())
    let model = modelWithRectElement()
    Controller(model: model).selectElement([0, 0])
    let ctx = makeCtx(model: model)
    let nBefore = model.document.layers[0].children.count
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    tool.onMove(ctx, x: 5, y: 0, shift: false, alt: false, dragging: true)
    tool.onMove(ctx, x: 30, y: 0, shift: false, alt: true, dragging: true)
    // Alt released before mouseup — exit preview, original to cursor.
    tool.onMove(ctx, x: 50, y: 0, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)
    let kids = model.document.layers[0].children
    #expect(kids.count == nBefore)
    if let r = layerRect(model, 0) {
        #expect(r.x == 50)  // original moved to cursor x
        #expect(r.y == 0)   // y unchanged
    } else {
        Issue.record("expected Rect at index 0")
    }
}

// ── lasso ─────────────────────────────────────────────────────────

@Test func lassoSelect() throws {
    let tool = try #require(lassoTool())
    let model = selectionParityModelForLasso()
    let ctx = makeCtx(model: model)
    // Polygon enclosing the rect at (50,50,20,20).
    tool.onPress(ctx, x: 40, y: 40, shift: false, alt: false)
    tool.onMove(ctx, x: 80, y: 40, shift: false, alt: false, dragging: true)
    tool.onMove(ctx, x: 80, y: 80, shift: false, alt: false, dragging: true)
    tool.onMove(ctx, x: 40, y: 80, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 40, y: 80, shift: false, alt: false)
    #expect(!model.document.selection.isEmpty)
}

@Test func lassoMiss() throws {
    let tool = try #require(lassoTool())
    let model = selectionParityModelForLasso()
    let ctx = makeCtx(model: model)
    // Polygon nowhere near the rect.
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    tool.onMove(ctx, x: 10, y: 0, shift: false, alt: false, dragging: true)
    tool.onMove(ctx, x: 10, y: 10, shift: false, alt: false, dragging: true)
    tool.onMove(ctx, x: 0, y: 10, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 0, y: 10, shift: false, alt: false)
    #expect(model.document.selection.isEmpty)
}

@Test func lassoClickWithoutDragClears() throws {
    let tool = try #require(lassoTool())
    let model = selectionParityModelForLasso()
    Controller(model: model).selectElement([0, 0])
    #expect(!model.document.selection.isEmpty)
    let ctx = makeCtx(model: model)
    // Press + release at same point, no shift — buffer < 3 points →
    // clear-selection branch.
    tool.onPress(ctx, x: 5, y: 5, shift: false, alt: false)
    tool.onRelease(ctx, x: 5, y: 5, shift: false, alt: false)
    #expect(model.document.selection.isEmpty)
}

@Test func lassoClickWithoutDragShiftPreserves() throws {
    let tool = try #require(lassoTool())
    let model = selectionParityModelForLasso()
    Controller(model: model).selectElement([0, 0])
    let ctx = makeCtx(model: model)
    // Shift+click without drag — clear branch is guarded by !shift, so
    // the selection is preserved.
    tool.onPress(ctx, x: 5, y: 5, shift: true, alt: false)
    tool.onRelease(ctx, x: 5, y: 5, shift: true, alt: false)
    #expect(!model.document.selection.isEmpty)
}

@Test func lassoStateTransitions() throws {
    let tool = try #require(lassoTool())
    let model = selectionParityModelForLasso()
    let ctx = makeCtx(model: model)
    #expect(tool.toolState("mode") as? String == "idle")
    tool.onPress(ctx, x: 10, y: 10, shift: false, alt: false)
    #expect(tool.toolState("mode") as? String == "drawing")
    tool.onRelease(ctx, x: 10, y: 10, shift: false, alt: false)
    #expect(tool.toolState("mode") as? String == "idle")
}

// ── interior_selection ────────────────────────────────────────────

@Test func interiorSelectionClickEntersGroup() throws {
    let tool = try #require(interiorSelectionTool())
    let model = modelWithRectInsideGroup()
    let ctx = makeCtx(model: model)
    // Click inside the rect (at layer[0]/group[0]/rect[0]).
    tool.onPress(ctx, x: 55, y: 55, shift: false, alt: false)
    tool.onRelease(ctx, x: 55, y: 55, shift: false, alt: false)
    let sel = model.document.selection
    #expect(sel.count == 1)
    // Interior selection picks the leaf INSIDE the group, not the group.
    #expect(sel.first?.path == [0, 0, 0])
}

@Test func interiorSelectionMarqueeSelectsPartial() throws {
    let tool = try #require(interiorSelectionTool())
    let model = modelWithRectInsideGroup()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 40, y: 40, shift: false, alt: false)
    tool.onMove(ctx, x: 80, y: 80, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 80, y: 80, shift: false, alt: false)
    #expect(!model.document.selection.isEmpty)
}
