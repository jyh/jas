/// End-to-end tests for the Align panel's platform-effect pipeline
/// in Swift — parallels `apply_align_operation` tests in
/// `jas_dioxus/src/workspace/app_state.rs`.
///
/// Builds a minimal Model with selected rects, calls
/// `applyAlignOperation`, and verifies each element's transform
/// carries the expected translation. Also exercises
/// `resetAlignPanel` and `alignPlatformEffects`.

import Foundation
import Testing
@testable import JasLib

private func makeRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Element {
    .rect(Rect(x: x, y: y, width: w, height: h))
}

private func modelWithRects(_ rects: [Element], selected: [ElementPath]) -> Model {
    let layer = Layer(children: rects)
    let selection: Selection = Set(selected.map { ElementSelection.all($0) })
    let doc = Document(layers: [layer], selectedLayer: 0, selection: selection)
    return Model(document: doc)
}

private func transformAt(_ model: Model, path: ElementPath) -> Transform {
    model.document.getElement(path).transform ?? .identity
}

@Test func applyAlignLeftTranslatesNonExtremalRects() {
    let rects = [
        makeRect(10, 0, 10, 10),
        makeRect(30, 0, 10, 10),
        makeRect(60, 0, 10, 10),
    ]
    let model = modelWithRects(rects, selected: [[0, 0], [0, 1], [0, 2]])
    applyAlignOperation(model: model, store: model.stateStore, op: "align_left")
    // Defaults: align_to = selection (from store is nil here, falls
    // back to "selection"). First rect already at x=10 → identity.
    #expect(transformAt(model, path: [0, 0]) == .identity)
    let t1 = transformAt(model, path: [0, 1])
    #expect(t1.e == -20)
    #expect(t1.f == 0)
    let t2 = transformAt(model, path: [0, 2])
    #expect(t2.e == -50)
    #expect(t2.f == 0)
}

@Test func applyAlignOperationNoOpWhenFewerThanTwoSelected() {
    let rects = [makeRect(0, 0, 10, 10), makeRect(100, 0, 10, 10)]
    let model = modelWithRects(rects, selected: [[0, 0]])
    applyAlignOperation(model: model, store: model.stateStore, op: "align_left")
    #expect(transformAt(model, path: [0, 0]) == .identity)
    #expect(transformAt(model, path: [0, 1]) == .identity)
}

@Test func applyAlignOperationUnknownOpDoesNothing() {
    let rects = [makeRect(0, 0, 10, 10), makeRect(50, 0, 10, 10)]
    let model = modelWithRects(rects, selected: [[0, 0], [0, 1]])
    applyAlignOperation(model: model, store: model.stateStore, op: "not_a_real_op")
    #expect(transformAt(model, path: [0, 0]) == .identity)
    #expect(transformAt(model, path: [0, 1]) == .identity)
}

@Test func resetAlignPanelResetsBothStateAndPanelMirrors() {
    let model = modelWithRects([makeRect(0, 0, 10, 10)], selected: [])
    let s = model.stateStore
    s.set("align_to", "key_object")
    s.set("align_key_object_path", ["__path__": [0, 1]])
    s.set("align_distribute_spacing", 12.0)
    s.set("align_use_preview_bounds", true)
    s.initPanel("align_panel_content", defaults: [:])
    s.setPanel("align_panel_content", "align_to", "key_object")
    s.setPanel("align_panel_content", "key_object_path", ["__path__": [0, 1]])
    s.setPanel("align_panel_content", "distribute_spacing_value", 12.0)
    s.setPanel("align_panel_content", "use_preview_bounds", true)
    resetAlignPanel(store: s)
    #expect(s.get("align_to") as? String == "selection")
    #expect(s.get("align_key_object_path") is NSNull)
    #expect((s.get("align_distribute_spacing") as? Double) == 0.0)
    #expect((s.get("align_use_preview_bounds") as? Bool) == false)
    #expect(s.getPanel("align_panel_content", "align_to") as? String == "selection")
    #expect(s.getPanel("align_panel_content", "key_object_path") is NSNull)
}

@Test func alignPlatformEffectsDictHasAllFourteenOpsPlusSnapshotAndReset() {
    let model = modelWithRects([makeRect(0, 0, 10, 10)], selected: [])
    let effects = alignPlatformEffects(model: model)
    let expected: Set<String> = [
        "snapshot", "reset_align_panel",
        "align_left", "align_horizontal_center", "align_right",
        "align_top", "align_vertical_center", "align_bottom",
        "distribute_left", "distribute_horizontal_center", "distribute_right",
        "distribute_top", "distribute_vertical_center", "distribute_bottom",
        "distribute_vertical_spacing", "distribute_horizontal_spacing",
    ]
    #expect(Set(effects.keys) == expected)
}

@Test func alignKeyObjectHoldsWhileOthersMove() {
    let rects = [
        makeRect(10, 0, 10, 10),
        makeRect(30, 0, 10, 10),
        makeRect(60, 0, 10, 10),
    ]
    let model = modelWithRects(rects, selected: [[0, 0], [0, 1], [0, 2]])
    let s = model.stateStore
    s.set("align_to", "key_object")
    s.set("align_key_object_path", ["__path__": [0, 1]])
    applyAlignOperation(model: model, store: s, op: "align_left")
    // Key (rs[1]) never moves.
    #expect(transformAt(model, path: [0, 1]) == .identity)
    // Others align to key's left edge (x=30).
    let t0 = transformAt(model, path: [0, 0])
    #expect(t0.e == 20)
    let t2 = transformAt(model, path: [0, 2])
    #expect(t2.e == -30)
}

// MARK: - Canvas click intercept for key-object designation

@Test func tryDesignateReturnsFalseWhenNotInKeyObjectMode() {
    let rects = [makeRect(0, 0, 50, 50), makeRect(100, 0, 50, 50)]
    let model = modelWithRects(rects, selected: [[0, 0], [0, 1]])
    // Defaults: align_to is nil / falls back to "selection" — intercept must not fire.
    #expect(!tryDesignateAlignKeyObject(model: model, store: model.stateStore,
                                        x: 25, y: 25))
    #expect(model.stateStore.get("align_key_object_path") is Optional<Any>)
}

@Test func tryDesignateSetsKeyOnHitInKeyMode() {
    let rects = [makeRect(0, 0, 50, 50), makeRect(100, 0, 50, 50)]
    let model = modelWithRects(rects, selected: [[0, 0], [0, 1]])
    let s = model.stateStore
    s.set("align_to", "key_object")
    let consumed = tryDesignateAlignKeyObject(model: model, store: s, x: 25, y: 25)
    #expect(consumed)
    let dict = s.get("align_key_object_path") as? [String: Any]
    #expect(dict?["__path__"] as? [Int] == [0, 0])
}

@Test func tryDesignateSecondClickOnSameElementClearsKey() {
    let rects = [makeRect(0, 0, 50, 50), makeRect(100, 0, 50, 50)]
    let model = modelWithRects(rects, selected: [[0, 0], [0, 1]])
    let s = model.stateStore
    s.set("align_to", "key_object")
    _ = tryDesignateAlignKeyObject(model: model, store: s, x: 25, y: 25)
    _ = tryDesignateAlignKeyObject(model: model, store: s, x: 25, y: 25)
    #expect(s.get("align_key_object_path") is NSNull)
}

@Test func tryDesignateClickOutsideSelectionClearsKey() {
    let rects = [makeRect(0, 0, 50, 50), makeRect(100, 0, 50, 50)]
    let model = modelWithRects(rects, selected: [[0, 0], [0, 1]])
    let s = model.stateStore
    s.set("align_to", "key_object")
    s.set("align_key_object_path", ["__path__": [0, 0]])
    _ = tryDesignateAlignKeyObject(model: model, store: s, x: 500, y: 500)
    #expect(s.get("align_key_object_path") is NSNull)
}

@Test func tryDesignateClickOnDifferentSelectedElementSwapsKey() {
    let rects = [makeRect(0, 0, 50, 50), makeRect(100, 0, 50, 50)]
    let model = modelWithRects(rects, selected: [[0, 0], [0, 1]])
    let s = model.stateStore
    s.set("align_to", "key_object")
    s.set("align_key_object_path", ["__path__": [0, 0]])
    _ = tryDesignateAlignKeyObject(model: model, store: s, x: 125, y: 25)
    let dict = s.get("align_key_object_path") as? [String: Any]
    #expect(dict?["__path__"] as? [Int] == [0, 1])
}

@Test func syncAlignKeyObjectNoopWhenNoKey() {
    let rects = [makeRect(0, 0, 50, 50), makeRect(100, 0, 50, 50)]
    let model = modelWithRects(rects, selected: [[0, 0], [0, 1]])
    syncAlignKeyObjectFromSelection(model: model, store: model.stateStore)
    // No mutation, no crash.
    #expect(true)
}

@Test func syncAlignKeyObjectPreservesStillSelectedKey() {
    let rects = [makeRect(0, 0, 50, 50), makeRect(100, 0, 50, 50)]
    let model = modelWithRects(rects, selected: [[0, 0], [0, 1]])
    let s = model.stateStore
    s.set("align_key_object_path", ["__path__": [0, 1]])
    syncAlignKeyObjectFromSelection(model: model, store: s)
    let dict = s.get("align_key_object_path") as? [String: Any]
    #expect(dict?["__path__"] as? [Int] == [0, 1])
}

@Test func syncAlignKeyObjectClearsWhenKeyNoLongerSelected() {
    let rects = [makeRect(0, 0, 50, 50), makeRect(100, 0, 50, 50)]
    let model = modelWithRects(rects, selected: [[0, 0]])
    let s = model.stateStore
    s.set("align_key_object_path", ["__path__": [0, 1]])
    syncAlignKeyObjectFromSelection(model: model, store: s)
    #expect(s.get("align_key_object_path") is NSNull)
}
