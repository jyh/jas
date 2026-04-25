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

// MARK: - doc.path.probe_anchor_hit + commit_anchor_edit

@Test func docPathProbeAnchorHitMissIsIdle() {
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0)]
    let model = modelWithPath(cmds)
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.probe_anchor_hit": ["x": 500, "y": 500]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(store.getTool("anchor_point", "mode") as? String == "idle")
}

@Test func docPathProbeAnchorHitCornerAnchor() {
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0)]
    let model = modelWithPath(cmds)
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.probe_anchor_hit": ["x": 0, "y": 0]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(store.getTool("anchor_point", "mode") as? String == "pressed_corner")
    if let idx = store.getTool("anchor_point", "hit_anchor_idx") as? Int {
        #expect(idx == 0)
    } else { Issue.record("expected hit_anchor_idx") }
}

@Test func docPathCommitAnchorEditCornerToSmoothDrag() {
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0)]
    let model = modelWithPath(cmds)
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    // Probe to latch the corner anchor.
    runEffects(
        [["doc.path.probe_anchor_hit": ["x": 100, "y": 0]]],
        ctx: [:], store: store, platformEffects: effects
    )
    // Commit drag from (100,0) to (100,-20) → pulls a smooth handle.
    runEffects(
        [["doc.path.commit_anchor_edit": [
            "origin_x": 100, "origin_y": 0,
            "target_x": 100, "target_y": -20,
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    // Last command should now be a CurveTo (smooth).
    if case .path(let p) = model.document.layers[0].children[0] {
        if case .curveTo = p.d.last! {} else {
            Issue.record("expected curveTo after corner→smooth")
        }
    } else { Issue.record("expected path") }
}

@Test func docPathCommitAnchorEditCornerTinyMoveIsNoop() {
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0)]
    let model = modelWithPath(cmds)
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.probe_anchor_hit": ["x": 100, "y": 0]]],
        ctx: [:], store: store, platformEffects: effects
    )
    // Move <= 1 px → no commit.
    runEffects(
        [["doc.path.commit_anchor_edit": [
            "origin_x": 100, "origin_y": 0,
            "target_x": 100.5, "target_y": 0,
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    if case .path(let p) = model.document.layers[0].children[0] {
        #expect(p.d == cmds)
    } else { Issue.record("expected path") }
}

@Test func docPathCommitAnchorEditIdleIsNoop() {
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0)]
    let model = modelWithPath(cmds)
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    // Probe misses → mode=idle, commit should be a no-op.
    runEffects(
        [["doc.path.probe_anchor_hit": ["x": 500, "y": 500]]],
        ctx: [:], store: store, platformEffects: effects
    )
    runEffects(
        [["doc.path.commit_anchor_edit": [
            "origin_x": 0, "origin_y": 0,
            "target_x": 50, "target_y": 50,
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    if case .path(let p) = model.document.layers[0].children[0] {
        #expect(p.d == cmds)
    } else { Issue.record("expected path") }
}

// MARK: - doc.path.probe_partial_hit + commit_partial_marquee + move_path_handle

@Test func docPathProbePartialHitMarqueeOnMiss() {
    let model = twoRectModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.probe_partial_hit": ["x": 500, "y": 500, "hit_radius": 8]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(store.getTool("partial_selection", "mode") as? String == "marquee")
}

@Test func docPathProbePartialHitMovingPendingOnCpHit() {
    // Click the (0, 0) corner of the first rect.
    let model = twoRectModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.probe_partial_hit": ["x": 0, "y": 0, "hit_radius": 8]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(store.getTool("partial_selection", "mode") as? String == "moving_pending")
    // The CP should now be in the selection.
    #expect(model.document.selection.contains { $0.path == [0, 0] })
}

@Test func docPathCommitPartialMarqueeRectSelects() {
    let model = twoRectModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.commit_partial_marquee": [
            "x1": -1, "y1": -1, "x2": 11, "y2": 11,
            "additive": false,
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.selection.contains { $0.path == [0, 0] })
}

@Test func docPathCommitPartialMarqueeTinyRectClearsOnNonAdditive() {
    let model = twoRectModel()
    Controller(model: model).selectElement([0, 0])
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.commit_partial_marquee": [
            "x1": 50, "y1": 50, "x2": 50, "y2": 50,
            "additive": false,
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.selection.isEmpty)
}

@Test func docMovePathHandleWithoutLatchIsNoop() {
    let cmds: [PathCommand] = [
        .moveTo(0, 0),
        .curveTo(x1: 0, y1: 50, x2: 50, y2: 50, x: 50, y: 0),
    ]
    let model = modelWithPath(cmds)
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.move_path_handle": ["dx": 10, "dy": 0]]],
        ctx: [:], store: store, platformEffects: effects
    )
    if case .path(let p) = model.document.layers[0].children[0] {
        #expect(p.d == cmds)
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

// MARK: - Blob Brush commit effects

private func seedBlobBrushSweep() {
    pointBuffersClear("blob_brush")
    // Short horizontal sweep; 6 points spanning 50 pt.
    for i in 0...5 {
        pointBuffersPush("blob_brush", Double(i) * 10.0, 0.0)
    }
}

private func blobBrushStateDefaults(_ store: StateStore) {
    store.set("fill_color", "#ff0000")
    store.set("blob_brush_size", 10.0)
    store.set("blob_brush_angle", 0.0)
    store.set("blob_brush_roundness", 100.0)
}

@Test func blobBrushCommitPaintingCreatesTaggedPath() {
    let store = StateStore()
    blobBrushStateDefaults(store)
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        selectedLayer: 0, selection: []))
    seedBlobBrushSweep()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.blob_brush.commit_painting": [
            "buffer": "blob_brush",
            "fidelity_epsilon": "5.0",
            "merge_only_with_selection": "false",
            "keep_selected": "false",
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let children = model.document.layers[0].children
    #expect(children.count == 1)
    if case .path(let pe) = children[0] {
        #expect(pe.toolOrigin == "blob_brush")
        #expect(pe.fill != nil)
        #expect(pe.stroke == nil)
        // At least one MoveTo + multiple LineTos + ClosePath.
        #expect(pe.d.count >= 3)
    } else {
        Issue.record("expected .path")
    }
}

@Test func blobBrushCommitErasingDeletesFullyCoveredElement() {
    let store = StateStore()
    blobBrushStateDefaults(store)
    // Small 4×2 blob-brush square fully inside the sweep's coverage
    // area (sweep = 50pt horizontal, 10pt tip → covers y ∈ [-5, 5]).
    let target: Element = .path(Path(
        d: [
            .moveTo(23, -1),
            .lineTo(27, -1),
            .lineTo(27, 1),
            .lineTo(23, 1),
            .closePath,
        ],
        fill: Fill(color: Color.fromHex("#ff0000")!),
        toolOrigin: "blob_brush"))
    let model = Model(document: Document(
        layers: [Layer(children: [target])],
        selectedLayer: 0, selection: []))
    seedBlobBrushSweep()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.blob_brush.commit_erasing": [
            "buffer": "blob_brush",
            "fidelity_epsilon": "5.0",
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let children = model.document.layers[0].children
    #expect(children.isEmpty,
            "erasing should delete fully-covered element")
}

@Test func blobBrushCommitErasingIgnoresNonBlobBrushElements() {
    let store = StateStore()
    blobBrushStateDefaults(store)
    // Same square but WITHOUT toolOrigin — erase must skip.
    let target: Element = .path(Path(
        d: [
            .moveTo(20, -2),
            .lineTo(30, -2),
            .lineTo(30, 2),
            .lineTo(20, 2),
            .closePath,
        ],
        fill: Fill(color: Color.fromHex("#ff0000")!)))
    let model = Model(document: Document(
        layers: [Layer(children: [target])],
        selectedLayer: 0, selection: []))
    seedBlobBrushSweep()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.blob_brush.commit_erasing": [
            "buffer": "blob_brush",
            "fidelity_epsilon": "5.0",
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let children = model.document.layers[0].children
    #expect(children.count == 1,
            "erasing must not touch non-blob-brush elements")
}

// MARK: - doc.magic_wand.apply

private func threeRectsRedRedBlueModel() -> Model {
    let red = Fill(color: Color(r: 1.0, g: 0, b: 0))
    let blue = Fill(color: Color(r: 0, g: 0, b: 1.0))
    let stroke = Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0)
    func rect(_ fill: Fill, _ x: Double) -> Element {
        .rect(Rect(x: x, y: 0, width: 10, height: 10,
                   rx: 0, ry: 0,
                   fill: fill, stroke: stroke,
                   opacity: 1.0, transform: nil,
                   locked: false, visibility: .preview))
    }
    return Model(document: Document(
        layers: [Layer(children: [
            rect(red, 0),
            rect(red, 20),
            rect(blue, 40),
        ])],
        selectedLayer: 0, selection: []))
}

private func magicWandStateDefaults(_ store: StateStore) {
    store.set("magic_wand_fill_color", true)
    store.set("magic_wand_fill_tolerance", 32.0)
    store.set("magic_wand_stroke_color", true)
    store.set("magic_wand_stroke_tolerance", 32.0)
    store.set("magic_wand_stroke_weight", true)
    store.set("magic_wand_stroke_weight_tolerance", 5.0)
    store.set("magic_wand_opacity", true)
    store.set("magic_wand_opacity_tolerance", 5.0)
    store.set("magic_wand_blending_mode", false)
}

@Test func magicWandReplaceSelectsSeedPlusSimilar() {
    let model = threeRectsRedRedBlueModel()
    let store = StateStore()
    magicWandStateDefaults(store)
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.magic_wand.apply": [
            "seed": [0, 0],
            "mode": "'replace'",
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let paths = Set(model.document.selection.map { $0.path })
    #expect(paths.contains([0, 0]))
    #expect(paths.contains([0, 1]))
    #expect(!paths.contains([0, 2]))
    #expect(paths.count == 2)
}

@Test func magicWandAddUnionsWithExistingSelection() {
    let model = threeRectsRedRedBlueModel()
    let store = StateStore()
    magicWandStateDefaults(store)
    Controller(model: model).setSelection([ElementSelection.all([0, 2])])
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.magic_wand.apply": [
            "seed": [0, 0],
            "mode": "'add'",
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let paths = Set(model.document.selection.map { $0.path })
    #expect(paths.count == 3)
}

@Test func magicWandSubtractRemovesWandResult() {
    let model = threeRectsRedRedBlueModel()
    let store = StateStore()
    magicWandStateDefaults(store)
    Controller(model: model).setSelection([
        ElementSelection.all([0, 0]),
        ElementSelection.all([0, 1]),
        ElementSelection.all([0, 2]),
    ])
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.magic_wand.apply": [
            "seed": [0, 0],
            "mode": "'subtract'",
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let paths = Set(model.document.selection.map { $0.path })
    #expect(paths.count == 1)
    #expect(paths.contains([0, 2]))
}

@Test func magicWandSkipsLockedAndHiddenElements() {
    let red = Fill(color: Color(r: 1.0, g: 0, b: 0))
    let stroke = Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0)
    func rect(_ x: Double, locked: Bool, vis: Visibility) -> Element {
        .rect(Rect(x: x, y: 0, width: 10, height: 10,
                   rx: 0, ry: 0,
                   fill: red, stroke: stroke,
                   opacity: 1.0, transform: nil,
                   locked: locked, visibility: vis))
    }
    let model = Model(document: Document(
        layers: [Layer(children: [
            rect(0,  locked: false, vis: .preview),
            rect(20, locked: true,  vis: .preview),
            rect(40, locked: false, vis: .invisible),
        ])],
        selectedLayer: 0, selection: []))
    let store = StateStore()
    magicWandStateDefaults(store)
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.magic_wand.apply": [
            "seed": [0, 0],
            "mode": "'replace'",
        ]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let paths = Set(model.document.selection.map { $0.path })
    #expect(paths.count == 1)
    #expect(paths.contains([0, 0]))
}

// MARK: - doc.zoom.* and doc.pan.apply

@Test func docZoomSet() {
    let model = Model()
    model.zoomLevel = 2.5
    model.viewOffsetX = 100.0
    model.viewOffsetY = 50.0
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.zoom.set": ["level": "1.0"]]],
               ctx: [:], store: store, platformEffects: effects)
    #expect(model.zoomLevel == 1.0)
    // Pan unchanged.
    #expect(model.viewOffsetX == 100.0)
    #expect(model.viewOffsetY == 50.0)
}

@Test func docZoomSetClampsToMinMax() {
    let model = Model()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.zoom.set": ["level": "1000.0"]]],
               ctx: [:], store: store, platformEffects: effects)
    // Default max_zoom 64.0 from preferences.yaml.
    #expect(model.zoomLevel == 64.0)
}

@Test func docZoomSetFull() {
    let model = Model()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.zoom.set_full": [
        "zoom":     "2.0",
        "offset_x": "150.0",
        "offset_y": "75.0",
    ]]], ctx: [:], store: store, platformEffects: effects)
    #expect(model.zoomLevel == 2.0)
    #expect(model.viewOffsetX == 150.0)
    #expect(model.viewOffsetY == 75.0)
}

@Test func docZoomApplyAnchorsAtCursor() {
    // Anchor invariant: doc point (200, 150) at screen (200, 150)
    // before should be at screen (200, 150) after a 2x zoom from
    // identity. screen = offset + zoom * doc; doc was 200/1 = 200,
    // offset_new = 200 - 200*2 = -200.
    let model = Model()
    model.zoomLevel = 1.0
    model.viewOffsetX = 0.0
    model.viewOffsetY = 0.0
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.zoom.apply": [
        "factor":   "2.0",
        "anchor_x": "200",
        "anchor_y": "150",
    ]]], ctx: [:], store: store, platformEffects: effects)
    #expect(model.zoomLevel == 2.0)
    #expect(model.viewOffsetX == -200.0)
    #expect(model.viewOffsetY == -150.0)
}

@Test func docZoomApplyClampsAtMax() {
    let model = Model()
    model.zoomLevel = 32.0
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.zoom.apply": [
        "factor":   "10.0",
        "anchor_x": "100",
        "anchor_y": "100",
    ]]], ctx: [:], store: store, platformEffects: effects)
    // Clamped to 64.0 (default max_zoom).
    #expect(model.zoomLevel == 64.0)
}

@Test func docPanApplyTranslatesByDragDelta() {
    let model = Model()
    let initialZoom = model.zoomLevel
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.pan.apply": [
        "press_x":      "100",
        "press_y":      "50",
        "cursor_x":     "150",
        "cursor_y":     "120",
        "initial_offx": "0",
        "initial_offy": "0",
    ]]], ctx: [:], store: store, platformEffects: effects)
    // delta = (50, 70); initial = (0, 0); result = (50, 70).
    #expect(model.viewOffsetX == 50.0)
    #expect(model.viewOffsetY == 70.0)
    // Zoom unchanged.
    #expect(model.zoomLevel == initialZoom)
}

@Test func docPanApplyIsIdempotent() {
    // Calling twice with the same press / cursor / initial values
    // gives the same result — the effect uses cumulative delta from
    // press, not per-event delta.
    let model = Model()
    model.viewOffsetX = 0.0
    model.viewOffsetY = 0.0
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    let effectList: [[String: Any]] = [["doc.pan.apply": [
        "press_x":      "100",
        "press_y":      "50",
        "cursor_x":     "150",
        "cursor_y":     "120",
        "initial_offx": "0",
        "initial_offy": "0",
    ]]]
    runEffects(effectList, ctx: [:], store: store, platformEffects: effects)
    let afterFirst = (model.viewOffsetX, model.viewOffsetY)
    runEffects(effectList, ctx: [:], store: store, platformEffects: effects)
    let afterSecond = (model.viewOffsetX, model.viewOffsetY)
    #expect(afterFirst == afterSecond)
}

@Test func docZoomFitRectCentersAndScales() {
    // 200x100 rect at (0, 0) in 800x600 viewport with 20px padding.
    // Zoom = min(760/200, 560/100) = 3.8.
    // Rect center (100, 50) at zoom 3.8 → screen (380, 190).
    // Viewport center (400, 300). offset = (400-380, 300-190) = (20, 110).
    let model = Model()
    model.viewportW = 800
    model.viewportH = 600
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.zoom.fit_rect": [
        "rect_x":  "0", "rect_y":  "0",
        "rect_w":  "200", "rect_h": "100",
        "padding": "20",
    ]]], ctx: [:], store: store, platformEffects: effects)
    #expect(abs(model.zoomLevel - 3.8) < 1e-9)
    #expect(abs(model.viewOffsetX - 20.0) < 1e-9)
    #expect(abs(model.viewOffsetY - 110.0) < 1e-9)
}

@Test func docZoomFitMarqueeBelowThresholdIsNoop() {
    let model = Model()
    let initialZoom = model.zoomLevel
    let initialOffX = model.viewOffsetX
    let initialOffY = model.viewOffsetY
    model.viewportW = 800
    model.viewportH = 600
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.zoom.fit_marquee": [
        "press_x":  "100", "press_y": "100",
        "cursor_x": "105", "cursor_y": "150",  // 5x50, below threshold
    ]]], ctx: [:], store: store, platformEffects: effects)
    #expect(model.zoomLevel == initialZoom)
    #expect(model.viewOffsetX == initialOffX)
    #expect(model.viewOffsetY == initialOffY)
}

@Test func docZoomFitAllArtboardsUnionsRectangles() {
    // Two artboards: A at (0, 0, 100, 100), B at (200, 50, 100, 100).
    // Union: (0, 0, 300, 150). Fit into 600x300 viewport with padding 0.
    // Zoom = min(600/300, 300/150) = 2.0.
    let abA = Artboard(id: "a", name: "A", x: 0, y: 0,
                       width: 100, height: 100,
                       fill: .transparent,
                       showCenterMark: false, showCrossHairs: false,
                       showVideoSafeAreas: false,
                       videoRulerPixelAspectRatio: 1.0)
    let abB = Artboard(id: "b", name: "B", x: 200, y: 50,
                       width: 100, height: 100,
                       fill: .transparent,
                       showCenterMark: false, showCrossHairs: false,
                       showVideoSafeAreas: false,
                       videoRulerPixelAspectRatio: 1.0)
    let doc = Document(layers: [Layer(children: [])],
                       selectedLayer: 0, selection: [],
                       artboards: [abA, abB])
    let model = Model(document: doc)
    model.viewportW = 600
    model.viewportH = 300
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.zoom.fit_all_artboards": ["padding": "0"]]],
               ctx: [:], store: store, platformEffects: effects)
    #expect(abs(model.zoomLevel - 2.0) < 1e-9)
}

// MARK: - doc.artboard.* effects (ARTBOARD_TOOL.md)

private func artboardModel(_ artboards: [Artboard]) -> Model {
    Model(document: Document(
        layers: [Layer(name: "Layer 1", children: [])],
        selectedLayer: 0, selection: [],
        artboards: artboards))
}

@Test func docArtboardCreateCommitAppendsArtboard() {
    let seed = Artboard(id: "seed00001", name: "Artboard 1")
    let model = artboardModel([seed])
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.artboard.create_commit": [
        "x1": "10", "y1": "20", "x2": "110", "y2": "120"
    ]]], ctx: [:], store: store, platformEffects: effects)
    #expect(model.document.artboards.count == 2)
    let new = model.document.artboards[1]
    #expect(new.x == 10.0)
    #expect(new.y == 20.0)
    #expect(new.width == 100.0)
    #expect(new.height == 100.0)
    #expect(new.name == "Artboard 2")
}

@Test func docArtboardCreateCommitClampsAtMin() {
    let seed = Artboard(id: "seed00001", name: "Artboard 1")
    let model = artboardModel([seed])
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.artboard.create_commit": [
        "x1": "50", "y1": "50", "x2": "50.4", "y2": "50.4"
    ]]], ctx: [:], store: store, platformEffects: effects)
    #expect(model.document.artboards[1].width == 1.0)
    #expect(model.document.artboards[1].height == 1.0)
}

@Test func docArtboardProbeHitInteriorSetsToolState() {
    // Probe_hit on an artboard interior sets tool state. The
    // panel-selection write also happens but verifying it requires
    // the renderer's active_document scope plumbing (per-tab); this
    // test covers the tool-state side, which is verified directly
    // via the eval context.
    let ab = Artboard(id: "aaa00001", name: "Artboard 1",
                      x: 0, y: 0, width: 100, height: 100)
    let model = artboardModel([ab])
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.artboard.probe_hit": [
        "x": "50", "y": "50",
        "shift": "false", "cmd": "false", "alt": "false"
    ]]], ctx: [:], store: store, platformEffects: effects)
    let mode = (store.evalContext()["tool"] as? [String: Any])?["artboard"]
        as? [String: Any]
    #expect((mode?["mode"] as? String) == "moving_pending")
    #expect((mode?["hit_artboard_id"] as? String) == "aaa00001")
}

@Test func docArtboardProbeHoverClassifiesPosition() {
    let ab = Artboard(id: "aaa00001", name: "Artboard 1",
                      x: 0, y: 0, width: 100, height: 100)
    let model = artboardModel([ab])
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.artboard.probe_hover":
                 ["x": "50", "y": "50"]]],
               ctx: [:], store: store, platformEffects: effects)
    let ab_state = (store.evalContext()["tool"] as? [String: Any])?["artboard"]
        as? [String: Any]
    #expect((ab_state?["hover_kind"] as? String) == "interior")
    runEffects([["doc.artboard.probe_hover":
                 ["x": "999", "y": "999"]]],
               ctx: [:], store: store, platformEffects: effects)
    let ab_state2 = (store.evalContext()["tool"] as? [String: Any])?["artboard"]
        as? [String: Any]
    #expect((ab_state2?["hover_kind"] as? String) == "empty")
}

@Test func docArtboardMoveApplyTranslatesViaHitFallback() {
    let ab = Artboard(id: "aaa00001", name: "Artboard 1",
                      x: 100, y: 100, width: 200, height: 200)
    let model = artboardModel([ab])
    model.capturePreviewSnapshot()
    let store = StateStore()
    store.setTool("artboard", "hit_artboard_id", "aaa00001")
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.artboard.move_apply": [
        "press_x": "100", "press_y": "100",
        "cursor_x": "150", "cursor_y": "70",
        "shift_held": "false"
    ]]], ctx: [:], store: store, platformEffects: effects)
    let result = model.document.artboards[0]
    #expect(result.x == 150.0)
    #expect(result.y == 70.0)
}

// Note: doc.artboard.delete_panel_selected reads target ids from
// active_document.artboards_panel_selection_ids, which is built by
// the renderer per-tab. Unit-testing the delete path requires the
// active_document scope plumbing — covered indirectly by the
// run-time behavior verified by the manual test suite
// (ARTBOARD_TOOL_TESTS.md §Session G).
