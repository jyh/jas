import Testing
import Foundation
@testable import JasLib

// Phase 2 of the Swift YAML tool-runtime migration. Tests for the
// doc.* effects wired by buildYamlToolEffects(model:) — the selection
// family (no dependencies on later-phase infra like point_buffers,
// anchor_buffers, or path_ops).

private func makeRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Element {
    .rect(Rect(x: x, y: y, width: w, height: h))
}

private func twoRectModel() -> Model {
    // Layer with two 10×10 rects, one at (0,0) and one at (50,50) —
    // mirrors the Rust port's `make_model_two_rects`.
    let layer = Layer(children: [
        makeRect(0, 0, 10, 10),
        makeRect(50, 50, 10, 10),
    ])
    return Model(document: Document(
        layers: [layer], selectedLayer: 0, selection: []
    ))
}

// MARK: - doc.snapshot

@Test func docSnapshotPushesUndo() {
    let model = Model()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    #expect(!model.canUndo)
    runEffects([["doc.snapshot": NSNull()]], ctx: [:], store: store,
               platformEffects: effects)
    #expect(model.canUndo)
}

// MARK: - doc.clear_selection

@Test func docClearSelectionEmptiesSelection() {
    let model = twoRectModel()
    Controller(model: model).selectElement([0, 0])
    #expect(!model.document.selection.isEmpty)

    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.clear_selection": NSNull()]],
               ctx: [:], store: store, platformEffects: effects)
    #expect(model.document.selection.isEmpty)
}

// MARK: - doc.set_selection

@Test func docSetSelectionFromPathsList() {
    let model = twoRectModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.set_selection": ["paths": [[0, 0], [0, 1]]]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let paths = model.document.selection.map(\.path).sorted { $0.lexicographicallyPrecedes($1) }
    #expect(paths == [[0, 0], [0, 1]])
}

@Test func docSetSelectionDropsInvalidPaths() {
    let model = twoRectModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.set_selection": ["paths": [[0, 0], [99, 99]]]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.selection.count == 1)
    #expect(model.document.selection.first?.path == [0, 0])
}

// MARK: - doc.add_to_selection

@Test func docAddToSelectionRawArray() {
    let model = twoRectModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.add_to_selection": [0, 0]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.selection.count == 1)
    #expect(model.document.selection.first?.path == [0, 0])
}

@Test func docAddToSelectionIsIdempotent() {
    let model = twoRectModel()
    Controller(model: model).selectElement([0, 0])
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.add_to_selection": [0, 0]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.selection.count == 1)
}

// MARK: - doc.toggle_selection

@Test func docToggleSelectionAddsWhenAbsent() {
    let model = twoRectModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.toggle_selection": [0, 0]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.selection.count == 1)
}

@Test func docToggleSelectionRemovesWhenPresent() {
    let model = twoRectModel()
    Controller(model: model).setSelection([ElementSelection.all([0, 0])])
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.toggle_selection": [0, 0]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.selection.isEmpty)
}

// MARK: - doc.translate_selection

@Test func docTranslateSelectionMovesRect() {
    let model = twoRectModel()
    Controller(model: model).selectElement([0, 0])
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.translate_selection": ["dx": 5, "dy": 7]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let elem = model.document.getElement([0, 0])
    if case .rect(let r) = elem {
        // Movement is via transform, not coordinate rewrite.
        #expect(r.transform?.e == 5.0 || r.transform == nil && r.x == 5.0)
    }
}

@Test func docTranslateSelectionZeroDeltaIsNoop() {
    let model = twoRectModel()
    Controller(model: model).selectElement([0, 0])
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.translate_selection": ["dx": 0, "dy": 0]]],
        ctx: [:], store: store, platformEffects: effects
    )
    // No crash; document unchanged in any observable way.
    let elem = model.document.getElement([0, 0])
    if case .rect(let r) = elem {
        #expect(r.x == 0.0)
        #expect(r.y == 0.0)
    }
}

@Test func docTranslateSelectionExpressionArgs() {
    let model = twoRectModel()
    Controller(model: model).selectElement([0, 0])
    let store = StateStore(defaults: ["offset_x": 3, "offset_y": 4])
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.translate_selection": [
            "dx": "state.offset_x",
            "dy": "state.offset_y",
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let elem = model.document.getElement([0, 0])
    if case .rect(let r) = elem {
        #expect(r.transform?.e == 3.0 || r.transform == nil && r.x == 3.0)
    }
}

// MARK: - doc.copy_selection

@Test func docCopySelectionDuplicatesElement() {
    let model = twoRectModel()
    Controller(model: model).selectElement([0, 0])
    let layerBefore = model.document.layers[0]
    let countBefore = layerBefore.children.count

    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.copy_selection": ["dx": 100, "dy": 0]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.layers[0].children.count == countBefore + 1)
}

// MARK: - doc.select_in_rect

@Test func docSelectInRectCoversBoth() {
    // Rect (0..60, 0..60) covers both 10×10 rects.
    let model = twoRectModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.select_in_rect": [
            "x1": 0, "y1": 0, "x2": 60, "y2": 60, "additive": false,
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.selection.count == 2)
}

@Test func docSelectInRectAdditiveExtendsSelection() {
    let model = twoRectModel()
    Controller(model: model).selectElement([0, 0])
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    // Additive rect covers only rect 1; existing selection on rect 0
    // should survive.
    runEffects(
        [["doc.select_in_rect": [
            "x1": 45, "y1": 45, "x2": 65, "y2": 65, "additive": true,
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.selection.count == 2)
}

// MARK: - doc.partial_select_in_rect

@Test func docPartialSelectInRectSelectsControlPoints() {
    // partial_select_in_rect routes through directSelectRect; result
    // entries should be .partial, not .all.
    let model = twoRectModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.partial_select_in_rect": [
            "x1": -5, "y1": -5, "x2": 15, "y2": 15, "additive": false,
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    // At least the first rect's CPs should be in.
    let hasFirstRect = model.document.selection.contains {
        $0.path == [0, 0]
    }
    #expect(hasFirstRect)
}

// MARK: - doc.add_element

private func emptyLayerModel() -> Model {
    Model(document: Document(
        layers: [Layer(children: [])],
        selectedLayer: 0, selection: []
    ))
}

@Test func docAddElementRectAppendsRect() {
    let model = emptyLayerModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.add_element": ["element": [
            "type": "rect",
            "x": 5, "y": 10, "width": 30, "height": 40,
            "rx": 4, "ry": 4,
        ]]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.layers[0].children.count == 1)
    if case .rect(let r) = model.document.layers[0].children[0] {
        #expect(r.x == 5 && r.y == 10 && r.width == 30 && r.height == 40)
        #expect(r.rx == 4 && r.ry == 4)
    } else {
        Issue.record("expected rect element")
    }
}

@Test func docAddElementLineAppendsLine() {
    let model = emptyLayerModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.add_element": ["element": [
            "type": "line",
            "x1": 0, "y1": 0, "x2": 100, "y2": 50,
        ]]]],
        ctx: [:], store: store, platformEffects: effects
    )
    if case .line(let l) = model.document.layers[0].children[0] {
        #expect(l.x1 == 0 && l.y1 == 0 && l.x2 == 100 && l.y2 == 50)
    } else { Issue.record("expected line element") }
}

@Test func docAddElementPolygonDefaultsToFiveSides() {
    let model = emptyLayerModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.add_element": ["element": [
            "type": "polygon",
            "x1": 0, "y1": 0, "x2": 10, "y2": 0,
        ]]]],
        ctx: [:], store: store, platformEffects: effects
    )
    if case .polygon(let p) = model.document.layers[0].children[0] {
        #expect(p.points.count == 5)
    } else { Issue.record("expected polygon element") }
}

@Test func docAddElementStarBuildsTenVertexPolygon() {
    let model = emptyLayerModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.add_element": ["element": [
            "type": "star",
            "x1": 0, "y1": 0, "x2": 100, "y2": 100,
            "points": 5,
        ]]]],
        ctx: [:], store: store, platformEffects: effects
    )
    if case .polygon(let p) = model.document.layers[0].children[0] {
        #expect(p.points.count == 10)
    } else { Issue.record("expected polygon element") }
}

@Test func docAddElementUnknownTypeIsNoop() {
    let model = emptyLayerModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.add_element": ["element": ["type": "mystery"]]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.layers[0].children.isEmpty)
}

@Test func docAddElementExplicitNullFillStripsDefault() {
    let model = emptyLayerModel()
    model.defaultFill = Fill(color: Color(r: 1, g: 0, b: 0))
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.add_element": ["element": [
            "type": "rect",
            "x": 0, "y": 0, "width": 10, "height": 10,
            "fill": NSNull(),
        ]]]],
        ctx: [:], store: store, platformEffects: effects
    )
    if case .rect(let r) = model.document.layers[0].children[0] {
        #expect(r.fill == nil)
    } else { Issue.record("expected rect") }
}

// MARK: - doc.path.delete_anchor_near + insert_anchor_on_segment_near

private func modelWithPath(_ cmds: [PathCommand]) -> Model {
    Model(document: Document(
        layers: [Layer(children: [.path(Path(d: cmds))])],
        selectedLayer: 0, selection: []
    ))
}

@Test func docPathDeleteAnchorNearMidAnchor() {
    let cmds: [PathCommand] = [
        .moveTo(0, 0), .lineTo(50, 0), .lineTo(100, 0),
    ]
    let model = modelWithPath(cmds)
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.delete_anchor_near": ["x": 50, "y": 0, "hit_radius": 8]]],
        ctx: [:], store: store, platformEffects: effects
    )
    if case .path(let p) = model.document.layers[0].children[0] {
        #expect(p.d.count == 2)
    } else { Issue.record("expected path") }
}

@Test func docPathDeleteAnchorNearMissIsNoop() {
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(50, 0), .lineTo(100, 0)]
    let model = modelWithPath(cmds)
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.delete_anchor_near": ["x": 200, "y": 200, "hit_radius": 8]]],
        ctx: [:], store: store, platformEffects: effects
    )
    if case .path(let p) = model.document.layers[0].children[0] {
        #expect(p.d.count == 3)
    } else { Issue.record("expected path") }
}

@Test func docPathDeleteAnchorNearDeletesElementWhenTooSmall() {
    // Two-anchor path — deleting either should remove the element.
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0)]
    let model = modelWithPath(cmds)
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.delete_anchor_near": ["x": 0, "y": 0, "hit_radius": 8]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.layers[0].children.isEmpty)
}

@Test func docPathInsertAnchorOnSegmentMid() {
    // Single line — insert halfway.
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0)]
    let model = modelWithPath(cmds)
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.insert_anchor_on_segment_near":
            ["x": 50, "y": 0, "hit_radius": 8]]],
        ctx: [:], store: store, platformEffects: effects
    )
    if case .path(let p) = model.document.layers[0].children[0] {
        #expect(p.d.count == 3)
        if case .lineTo(let x, _) = p.d[1] {
            #expect(abs(x - 50) < 1e-9)
        } else { Issue.record("expected lineTo at inserted mid") }
    } else { Issue.record("expected path") }
}

@Test func docPathInsertAnchorNotWithinRadiusIsNoop() {
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0)]
    let model = modelWithPath(cmds)
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.insert_anchor_on_segment_near":
            ["x": 50, "y": 500, "hit_radius": 8]]],
        ctx: [:], store: store, platformEffects: effects
    )
    if case .path(let p) = model.document.layers[0].children[0] {
        #expect(p.d.count == 2)
    } else { Issue.record("expected path") }
}

// MARK: - doc.path.erase_at_rect

@Test func docPathEraseAtRectSplitsOpenPath() {
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0)]
    let model = modelWithPath(cmds)
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    // Eraser centred at (50, 0) with default size 2 — should split into
    // two sub-paths at the middle.
    runEffects(
        [["doc.path.erase_at_rect": [
            "last_x": 50, "last_y": 0, "x": 50, "y": 0,
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    // Original is gone; replaced with 2 sub-paths.
    #expect(model.document.layers[0].children.count == 2)
}

@Test func docPathEraseAtRectMissIsNoop() {
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0)]
    let model = modelWithPath(cmds)
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.erase_at_rect": [
            "last_x": 500, "last_y": 500, "x": 500, "y": 500,
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.layers[0].children.count == 1)
}

@Test func docPathEraseAtRectClearsSelection() {
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0)]
    var doc = Document(
        layers: [Layer(children: [.path(Path(d: cmds))])],
        selectedLayer: 0, selection: []
    )
    doc = Document(layers: doc.layers, selectedLayer: 0,
                   selection: [ElementSelection.all([0, 0])])
    let model = Model(document: doc)
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.erase_at_rect": [
            "last_x": 50, "last_y": 0, "x": 50, "y": 0,
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.selection.isEmpty)
}

// MARK: - doc.path.smooth_at_cursor

@Test func docPathSmoothAtCursorCollapsesRange() {
    // A 4-anchor zig-zag that smooth should compress.
    let cmds: [PathCommand] = [
        .moveTo(0, 0),
        .lineTo(10, 5),
        .lineTo(20, -5),
        .lineTo(30, 0),
    ]
    var doc = Document(
        layers: [Layer(children: [.path(Path(d: cmds))])],
        selectedLayer: 0,
        selection: [ElementSelection.all([0, 0])]
    )
    let model = Model(document: doc)
    _ = doc  // silence unused
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.smooth_at_cursor": [
            "x": 15, "y": 0, "radius": 50, "fit_error": 3,
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    // Smoothing re-fits the lines into 1+ CurveTos — result has
    // strictly fewer commands than the 4-line original.
    if case .path(let p) = model.document.layers[0].children[0] {
        #expect(p.d.count < 4)
    } else { Issue.record("expected path") }
}

@Test func docPathSmoothAtCursorWithoutSelectionIsNoop() {
    // Path is present but unselected → no smoothing happens.
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(10, 5), .lineTo(20, 0)]
    let model = modelWithPath(cmds)
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.smooth_at_cursor": ["x": 10, "y": 5, "radius": 20]]],
        ctx: [:], store: store, platformEffects: effects
    )
    if case .path(let p) = model.document.layers[0].children[0] {
        #expect(p.d.count == 3)
    } else { Issue.record("expected path") }
}

// MARK: - Path-spec extraction

@Test func docAddToSelectionAcceptsPathValueFromContext() {
    // Expression that evaluates to a Value.path (via a let-binding in
    // ctx) should work the same as a raw [Int] literal.
    let model = twoRectModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    let ctx: [String: Any] = ["hit": ["__path__": [0, 0]]]
    runEffects(
        [["doc.add_to_selection": "hit"]],
        ctx: ctx, store: store, platformEffects: effects
    )
    #expect(model.document.selection.count == 1)
    #expect(model.document.selection.first?.path == [0, 0])
}
