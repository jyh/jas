import Testing
import Foundation
@testable import JasLib

// Phase 3 of the Swift YAML tool-runtime migration. Tests for
// DocPrimitives, PointBuffers, AnchorBuffers, and the new evaluator
// primitives (math + doc-aware + buffer_length etc.).

// MARK: - DocPrimitives

private func docWithRect() -> Document {
    let rect = Element.rect(Rect(x: 10, y: 10, width: 20, height: 20))
    return Document(
        layers: [Layer(children: [rect])],
        selectedLayer: 0, selection: []
    )
}

@Test func hitTestWithoutRegisteredDocIsNull() {
    let v = evaluate("hit_test(15, 15)", context: [:])
    #expect(v == .null)
}

@Test func hitTestHitsElementInsideBounds() {
    let handle = registerDocument(docWithRect())
    let v = evaluate("hit_test(15, 15)", context: [:])
    #expect(v == .path([0, 0]))
    _ = handle  // keep registration alive through the evaluate call
}

@Test func hitTestMissesOutsideBounds() {
    let handle = registerDocument(docWithRect())
    let v = evaluate("hit_test(100, 100)", context: [:])
    #expect(v == .null)
    _ = handle
}

@Test func docGuardRestoresPriorOnDeinit() {
    do {
        let outer = registerDocument(docWithRect())
        #expect(evaluate("hit_test(15, 15)", context: [:]) == .path([0, 0]))
        do {
            let inner = registerDocument(
                Document(layers: [Layer(children: [])],
                         selectedLayer: 0, selection: [])
            )
            #expect(evaluate("hit_test(15, 15)", context: [:]) == .null)
            _ = inner
        }
        // Outer restored after inner deinit.
        #expect(evaluate("hit_test(15, 15)", context: [:]) == .path([0, 0]))
        _ = outer
    }
    // After the outer guard drops, no doc registered.
    #expect(evaluate("hit_test(15, 15)", context: [:]) == .null)
}

@Test func selectionContainsFindsPath() {
    var doc = docWithRect()
    doc = Document(layers: doc.layers, selectedLayer: 0,
                   selection: [ElementSelection.all([0, 0])])
    let handle = registerDocument(doc)
    let v = evaluate("selection_contains(path(0, 0))", context: [:])
    #expect(v == .bool(true))
    let no = evaluate("selection_contains(path(0, 1))", context: [:])
    #expect(no == .bool(false))
    _ = handle
}

@Test func selectionEmptyReflectsDocument() {
    let emptyDoc = Document(layers: [Layer(children: [])],
                            selectedLayer: 0, selection: [])
    let h = registerDocument(emptyDoc)
    #expect(evaluate("selection_empty()", context: [:]) == .bool(true))
    _ = h
}

// MARK: - Math primitives

@Test func minMaxAbs() {
    #expect(evaluate("min(3, 1, 2)", context: [:]) == .number(1))
    #expect(evaluate("max(3, 1, 2)", context: [:]) == .number(3))
    #expect(evaluate("abs(-5)", context: [:]) == .number(5))
}

@Test func sqrtAndHypot() {
    #expect(evaluate("sqrt(9)", context: [:]) == .number(3))
    #expect(evaluate("hypot(3, 4)", context: [:]) == .number(5))
}

@Test func sqrtRejectsNegative() {
    #expect(evaluate("sqrt(-1)", context: [:]) == .null)
}

// MARK: - PointBuffers

@Test func pointBufferPushAndLength() {
    pointBuffersClear("test_buf_a")
    #expect(pointBuffersLength("test_buf_a") == 0)
    pointBuffersPush("test_buf_a", 1, 2)
    pointBuffersPush("test_buf_a", 3, 4)
    #expect(pointBuffersLength("test_buf_a") == 2)
    let pts = pointBuffersPoints("test_buf_a")
    #expect(pts.count == 2 && pts[0] == (1, 2) && pts[1] == (3, 4))
    pointBuffersClear("test_buf_a")
    #expect(pointBuffersLength("test_buf_a") == 0)
}

@Test func bufferLengthPrimitive() {
    pointBuffersClear("test_buf_b")
    pointBuffersPush("test_buf_b", 1, 2)
    pointBuffersPush("test_buf_b", 3, 4)
    pointBuffersPush("test_buf_b", 5, 6)
    let v = evaluate("buffer_length(\"test_buf_b\")", context: [:])
    #expect(v == .number(3))
    pointBuffersClear("test_buf_b")
}

// MARK: - AnchorBuffers

@Test func anchorBufferPushCreatesCorner() {
    anchorBuffersClear("test_anc_a")
    anchorBuffersPush("test_anc_a", 10, 20)
    let a = anchorBuffersFirst("test_anc_a")!
    #expect(a.x == 10 && a.y == 20)
    #expect(a.hxIn == 10 && a.hyIn == 20)
    #expect(a.hxOut == 10 && a.hyOut == 20)
    #expect(!a.smooth)
    anchorBuffersClear("test_anc_a")
}

@Test func anchorBufferSetLastOutMirrorsIn() {
    anchorBuffersClear("test_anc_b")
    anchorBuffersPush("test_anc_b", 50, 50)
    anchorBuffersSetLastOutHandle("test_anc_b", 60, 50)
    let a = anchorBuffersFirst("test_anc_b")!
    #expect(a.hxOut == 60 && a.hyOut == 50)
    // Mirrored: (2*50 - 60, 2*50 - 50) = (40, 50)
    #expect(a.hxIn == 40 && a.hyIn == 50)
    #expect(a.smooth)
    anchorBuffersClear("test_anc_b")
}

@Test func anchorBufferPop() {
    anchorBuffersClear("test_anc_c")
    anchorBuffersPush("test_anc_c", 1, 2)
    anchorBuffersPush("test_anc_c", 3, 4)
    #expect(anchorBuffersLength("test_anc_c") == 2)
    anchorBuffersPop("test_anc_c")
    #expect(anchorBuffersLength("test_anc_c") == 1)
    #expect(anchorBuffersFirst("test_anc_c")?.x == 1)
    anchorBuffersClear("test_anc_c")
}

@Test func anchorBufferCloseHitPrimitive() {
    anchorBuffersClear("test_anc_d")
    anchorBuffersPush("test_anc_d", 0, 0)
    anchorBuffersPush("test_anc_d", 100, 0)
    // Cursor at (3, 4) — hypot = 5, within r=8.
    let hit = evaluate("anchor_buffer_close_hit(\"test_anc_d\", 3, 4, 8)",
                       context: [:])
    #expect(hit == .bool(true))
    // Cursor at (20, 0) — too far.
    let miss = evaluate("anchor_buffer_close_hit(\"test_anc_d\", 20, 0, 8)",
                        context: [:])
    #expect(miss == .bool(false))
    anchorBuffersClear("test_anc_d")
}

@Test func anchorBufferCloseHitRejectsShortBuffer() {
    anchorBuffersClear("test_anc_e")
    anchorBuffersPush("test_anc_e", 0, 0)
    // Only 1 anchor — close-hit requires >= 2.
    let v = evaluate("anchor_buffer_close_hit(\"test_anc_e\", 1, 1, 10)",
                     context: [:])
    #expect(v == .bool(false))
    anchorBuffersClear("test_anc_e")
}

// MARK: - Buffer effects + path-from-buffer effects

@Test func bufferPushEffect() {
    pointBuffersClear("test_eff_a")
    let model = Model()
    let effects = buildYamlToolEffects(model: model)
    let store = StateStore()
    runEffects(
        [["buffer.push": ["buffer": "test_eff_a", "x": 10, "y": 20]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(pointBuffersLength("test_eff_a") == 1)
    pointBuffersClear("test_eff_a")
}

@Test func anchorPushSetLastOutPopEffects() {
    anchorBuffersClear("test_eff_b")
    let model = Model()
    let effects = buildYamlToolEffects(model: model)
    let store = StateStore()
    runEffects(
        [
            ["anchor.push": ["buffer": "test_eff_b", "x": 50, "y": 50]],
            ["anchor.set_last_out": ["buffer": "test_eff_b", "hx": 60, "hy": 50]],
        ],
        ctx: [:], store: store, platformEffects: effects
    )
    let a = anchorBuffersFirst("test_eff_b")!
    #expect(a.smooth)
    #expect(a.hxOut == 60)
    runEffects(
        [["anchor.pop": ["buffer": "test_eff_b"]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(anchorBuffersLength("test_eff_b") == 0)
    anchorBuffersClear("test_eff_b")
}

@Test func addPathFromAnchorBufferProducesPath() {
    anchorBuffersClear("test_pen")
    anchorBuffersPush("test_pen", 0, 0)
    anchorBuffersPush("test_pen", 50, 50)
    anchorBuffersPush("test_pen", 100, 0)
    let model = Model(document: Document(
        layers: [Layer(children: [])], selectedLayer: 0, selection: []
    ))
    let effects = buildYamlToolEffects(model: model)
    let store = StateStore()
    runEffects(
        [["doc.add_path_from_anchor_buffer": [
            "buffer": "test_pen", "closed": false,
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.layers[0].children.count == 1)
    if case .path(let p) = model.document.layers[0].children[0] {
        // Expect MoveTo + 2 CurveTos (3 anchors → 2 segments).
        #expect(p.d.count == 3)
    }
    anchorBuffersClear("test_pen")
}
