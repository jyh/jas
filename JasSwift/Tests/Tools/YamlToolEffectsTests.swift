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
        layers: [Layer(children: [.path(Path(d: cmds, fillRule: .nonzero))])],
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
        layers: [Layer(children: [.path(Path(d: cmds, fillRule: .nonzero))])],
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
        layers: [Layer(children: [.path(Path(d: cmds, fillRule: .nonzero))])],
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

/// The control-point probe hits a corner WHERE IT IS DRAWN: through the
/// group's transform and the element's own, which is where the handle square
/// is drawn (`selectionHandleRects`). A Group translated (100, 0) holds a rect
/// (0, 0, 10 x 10) scaled 2x by its own transform, so corner 2 (local 10, 10)
/// is drawn at (120, 20), and (10, 10) draws nothing. Twin of Rust
/// `the_control_point_probe_hits_a_corner_where_it_is_drawn`.
@Test func theControlPointProbeHitsACornerWhereItIsDrawn() {
    func probe(_ x: Double, _ y: Double) -> (String?, [ElementSelection]) {
        let rect: Element = .rect(Rect(x: 0, y: 0, width: 10, height: 10, transform: .scale(2, 2)))
        let group: Element = .group(Group(children: [rect], transform: .translate(100, 0)))
        let model = Model(document: Document(layers: [Layer(name: "L", children: [group])],
                                             selectedLayer: 0, selection: []))
        let store = StateStore()
        runEffects([["doc.path.probe_partial_hit": ["x": x, "y": y, "hit_radius": 4]]],
                   ctx: [:], store: store, platformEffects: buildYamlToolEffects(model: model))
        return (store.getTool("partial_selection", "mode") as? String, model.document.selection)
    }
    let (hitMode, hitSel) = probe(120, 20)
    #expect(hitMode == "moving_pending", "the drawn corner is a hit")
    #expect(hitSel == [ElementSelection.partial([0, 0, 0], [2])])
    let (missMode, missSel) = probe(10, 10)
    #expect(missMode == "marquee", "the untransformed position draws nothing")
    #expect(missSel.isEmpty)
}

/// ROUTE 4 SLICE 3b: the probe reaches a Transformed wrapper's CHILD only while
/// that wrapper is the innermost isolation entry, and hits the child's points
/// where they are drawn (frame `W·M`). The wrapper scales a rect (2, 2, 10 x 10)
/// by (2, 3), so corner 2 (local 12, 12) is drawn at (24, 36). Twin of Rust
/// `the_probe_reaches_a_wrapped_childs_corner_only_while_isolated`.
@Test func theProbeReachesAWrappedChildsCornerOnlyWhileIsolated() {
    func probe(_ stack: [[Int]], _ x: Double, _ y: Double) -> (String?, [ElementSelection]) {
        let w = TransformedElem(child: .rect(Rect(x: 2, y: 2, width: 10, height: 10)),
                                matrix: .scale(2, 3), scaleStrokes: false)
        let model = Model(document: Document(layers: [Layer(name: "L", children: [.live(.transformed(w))])],
                                             selectedLayer: 0, selection: []))
        model.layersIsolationStack = stack
        let store = StateStore()
        runEffects([["doc.path.probe_partial_hit": ["x": x, "y": y, "hit_radius": 4]]],
                   ctx: [:], store: store, platformEffects: buildYamlToolEffects(model: model))
        return (store.getTool("partial_selection", "mode") as? String, model.document.selection)
    }
    #expect(probe([], 24, 36).1.allSatisfy { $0.path != [0, 0, 0] }, "not isolated: the child is unreachable")
    let (mode, sel) = probe([[0, 0]], 24, 36)
    #expect(mode == "moving_pending")
    #expect(sel == [ElementSelection.partial([0, 0, 0], [2])], "isolated: the drawn corner")
    #expect(probe([[0, 0]], 12, 12).0 == "marquee", "isolated: the untransformed corner draws nothing")
    #expect(probe([[0]], 24, 36).1.allSatisfy { $0.path != [0, 0, 0] }, "isolated into the LAYER only")
}

/// A Bezier HANDLE is grabbed where it is DRAWN and dragged in DOCUMENT space,
/// as a pair. A curve whose middle anchor (30, 0) has its in-handle at (20, 10),
/// inside a group at matrix(2,0,0,2,100,0): drawn at (140, 20); a (10, 10) drag
/// moves it (5, 5) locally. Twin of Rust
/// `a_bezier_handle_is_grabbed_where_drawn_and_dragged_in_document_space`.
@Test func aBezierHandleIsGrabbedWhereDrawnAndDraggedInDocumentSpace() {
    let curve: [PathCommand] = [
        .moveTo(0, 0),
        .curveTo(x1: 10, y1: 10, x2: 20, y2: 10, x: 30, y: 0),
        .curveTo(x1: 40, y1: -10, x2: 50, y2: -10, x: 60, y: 0),
    ]
    let group: Element = .group(Group(children: [.path(Path(d: curve, fillRule: .nonzero))],
                                      transform: Transform(a: 2, b: 0, c: 0, d: 2, e: 100, f: 0)))
    let model = Model(document: Document(layers: [Layer(name: "L", children: [group])],
                                         selectedLayer: 0, selection: [ElementSelection.all([0, 0, 0])]))
    let store = StateStore()
    let fx = buildYamlToolEffects(model: model)
    runEffects([["doc.path.probe_partial_hit": ["x": 140, "y": 20, "hit_radius": 4]]], ctx: [:], store: store, platformEffects: fx)
    #expect(store.getTool("partial_selection", "mode") as? String == "handle", "the drawn handle is a hit")
    #expect(store.getTool("partial_selection", "handle_type") as? String == "in")
    runEffects([["doc.move_path_handle": ["dx": 10, "dy": 10]]], ctx: [:], store: store, platformEffects: fx)
    guard case .path(let p) = model.document.getElement([0, 0, 0]),
          case .curveTo(_, _, let x2, let y2, _, _) = p.d[1] else { Issue.record("a curve"); return }
    #expect(x2 == 25 && y2 == 15, "moved (5,5) locally: \(p.d[1])")
}

// MARK: - the Anchor Point tool hits and edits a path WHERE IT IS DRAWN
//
// Transform-correct path verbs, S1: both anchor probes walk every depth on
// `findInEditablePaths` and compare through the path's frame, and
// `commit_anchor_edit` maps its release point (corner) and its drag (handle)
// back into local space. Twins of the Rust `the_anchor_point_tool_*` tests.

/// The open path (0,0) -> (30,30) -> (60,0): a CORNER at (30,30).
private let s1CornerPath: Element = .path(Path(d: [.moveTo(0, 0), .lineTo(30, 30), .lineTo(60, 0)], fillRule: .nonzero))

/// `elem` inside an identity Group inside a Group rotated 90 degrees and moved
/// to (100, 50): local (x, y) is drawn at (100 - y, 50 + x).
private func s1RotatedModel(_ elem: Element) -> Model {
    let inner: Element = .group(Group(children: [elem]))
    let outer: Element = .group(Group(children: [inner], transform: Transform(a: 0, b: 1, c: -1, d: 0, e: 100, f: 50)))
    return Model(document: Document(layers: [Layer(name: "L", children: [outer])], selectedLayer: 0, selection: []))
}

/// Press at `from`, release at `to`: the probe then the commit. Returns the
/// mode the probe chose.
@discardableResult
private func s1AnchorDrag(_ model: Model, _ from: (Double, Double), _ to: (Double, Double)) -> String? {
    let store = StateStore()
    let fx = buildYamlToolEffects(model: model)
    runEffects([["doc.path.probe_anchor_hit": ["x": from.0, "y": from.1, "hit_radius": 5]]],
               ctx: [:], store: store, platformEffects: fx)
    let mode = store.getTool("anchor_point", "mode") as? String
    runEffects([["doc.path.commit_anchor_edit": ["origin_x": from.0, "origin_y": from.1,
                                                 "target_x": to.0, "target_y": to.1]]],
               ctx: [:], store: store, platformEffects: fx)
    return mode
}

private func s1Commands(_ model: Model, _ path: ElementPath) -> [PathCommand] {
    guard case .path(let p) = model.document.getElement(path) else { return [] }
    return p.d
}

/// The corner (30,30) is drawn at (70,80); a release at (70,90) is local
/// (40,30), so the out-handle lands there and the in-handle mirrors to (20,30).
@Test func theAnchorPointToolConvertsACornerWhereItIsDrawnUnderRotation() {
    #expect(s1AnchorDrag(s1RotatedModel(s1CornerPath), (30, 30), (40, 30)) == "idle", "the local position draws nothing")
    let model = s1RotatedModel(s1CornerPath)
    #expect(s1AnchorDrag(model, (70, 80), (70, 90)) == "pressed_corner")
    let d = s1Commands(model, [0, 0, 0, 0])
    guard d.count == 3, case .curveTo(_, _, let x2, let y2, let x, let y) = d[1],
          case .curveTo(let x1, let y1, _, _, _, _) = d[2] else { Issue.record("two curves: \(d)"); return }
    #expect((x2, y2, x, y) == (20, 30, 30, 30), "in-handle mirrored to local (20,30): \(d[1])")
    #expect((x1, y1) == (40, 30), "out-handle at the release point's local image (40,30): \(d[2])")
}

/// Anchor 1 (30,0) has its in-handle at local (20,10), drawn at (90,70). A
/// (0,10) document drag is the local delta (10,0), so the handle moves to
/// (30,10); an unmapped drag gives (20,20) and a transposed one (10,10).
@Test func theAnchorPointToolDragsAHandleInDocumentSpaceUnderRotation() {
    let curve: [PathCommand] = [
        .moveTo(0, 0),
        .curveTo(x1: 10, y1: 10, x2: 20, y2: 10, x: 30, y: 0),
        .curveTo(x1: 40, y1: -10, x2: 50, y2: -10, x: 60, y: 0),
    ]
    let model = s1RotatedModel(.path(Path(d: curve, fillRule: .nonzero)))
    #expect(s1AnchorDrag(model, (90, 70), (90, 80)) == "pressed_handle")
    let d = s1Commands(model, [0, 0, 0, 0])
    guard d.count == 3, case .curveTo(_, _, let x2, let y2, _, _) = d[1] else { Issue.record("a curve: \(d)"); return }
    #expect((x2, y2) == (30, 10), "the in-handle moved (10,0) locally: \(d[1])")
}

/// The tool reaches a Transformed wrapper's child only while the wrapper is
/// the innermost isolation entry, under W·M. The wrapper scales the corner
/// path by (2,3), so the corner (30,30) is drawn at (60,90).
@Test func theAnchorPointToolReachesAWrappedPathOnlyWhileIsolated() {
    func probe(_ stack: [[Int]], _ x: Double, _ y: Double) -> String? {
        let w = TransformedElem(child: s1CornerPath, matrix: .scale(2, 3), scaleStrokes: false)
        let model = Model(document: Document(layers: [Layer(name: "L", children: [.live(.transformed(w))])],
                                             selectedLayer: 0, selection: []))
        model.layersIsolationStack = stack
        let store = StateStore()
        runEffects([["doc.path.probe_anchor_hit": ["x": x, "y": y, "hit_radius": 5]]],
                   ctx: [:], store: store, platformEffects: buildYamlToolEffects(model: model))
        return store.getTool("anchor_point", "mode") as? String
    }
    #expect(probe([], 60, 90) == "idle", "not isolated: a wrapper is one element")
    #expect(probe([[0, 0]], 60, 90) == "pressed_corner", "isolated: the drawn corner")
    #expect(probe([[0, 0]], 30, 30) == "idle", "isolated: the local corner draws nothing")
}

/// A path whose frame is SINGULAR (a group scaled to zero width) is skipped:
/// its corner collapses onto (0,30) and cannot be mapped back.
@Test func theAnchorPointToolSkipsAPathWithASingularFrame() {
    let group: Element = .group(Group(children: [s1CornerPath], transform: .scale(0, 1)))
    let model = Model(document: Document(layers: [Layer(name: "L", children: [group])], selectedLayer: 0, selection: []))
    let store = StateStore()
    runEffects([["doc.path.probe_anchor_hit": ["x": 0, "y": 30, "hit_radius": 5]]],
               ctx: [:], store: store, platformEffects: buildYamlToolEffects(model: model))
    #expect(store.getTool("anchor_point", "mode") as? String == "idle")
}

// MARK: - S2: Delete and Add Anchor Point hit a path WHERE IT IS DRAWN
// Twins of the Rust `the_delete_anchor_point_tool_*` / `the_add_anchor_point_tool_*` tests.

private func s2Click(_ model: Model, _ effect: String, _ x: Double, _ y: Double) {
    runEffects([[effect: ["x": x, "y": y, "hit_radius": 5]]],
               ctx: [:], store: StateStore(), platformEffects: buildYamlToolEffects(model: model))
}

/// The corner (30,30) is drawn at (70,80) under the rotated frame; a click
/// there deletes it, a click at the local position deletes nothing.
@Test func theDeleteAnchorPointToolDeletesACornerWhereItIsDrawnUnderRotation() {
    let model = s1RotatedModel(s1CornerPath)
    s2Click(model, "doc.path.delete_anchor_near", 30, 30)
    #expect(s1Commands(model, [0, 0, 0, 0]).count == 3, "the local position draws nothing")
    s2Click(model, "doc.path.delete_anchor_near", 70, 80)
    #expect(s1Commands(model, [0, 0, 0, 0]) == [.moveTo(0, 0), .lineTo(60, 0)])
}

/// Delete reaches a Transformed wrapper's child only while isolated into it.
/// The wrapper scales the corner path by (2,3): corner drawn at (60,90).
@Test func theDeleteAnchorPointToolReachesAWrappedPathOnlyWhileIsolated() {
    let w = TransformedElem(child: s1CornerPath, matrix: .scale(2, 3), scaleStrokes: false)
    let model = Model(document: Document(layers: [Layer(name: "L", children: [.live(.transformed(w))])],
                                         selectedLayer: 0, selection: []))
    s2Click(model, "doc.path.delete_anchor_near", 60, 90)
    #expect(s1Commands(model, [0, 0, 0]).count == 3, "not isolated: a wrapper is one element")
    model.layersIsolationStack = [[0, 0]]
    s2Click(model, "doc.path.delete_anchor_near", 60, 90)
    #expect(s1Commands(model, [0, 0, 0]).count == 2, "isolated: the drawn corner is deleted")
}

/// Add measures in DOCUMENT space. The segment (0,0)-(10,10) in a group scaled
/// (1,4) is drawn to (10,40); a click at (4,4) is closest at t = 2/17, so the
/// new anchor is local (20/17, 20/17). Mapping the click to local first, (4,1),
/// would pick t = 0.25 and put it at (2.5, 2.5).
@Test func theAddAnchorPointToolMeasuresTheDrawnSegmentUnderNonUniformScale() {
    let group: Element = .group(Group(children: [.path(Path(d: [.moveTo(0, 0), .lineTo(10, 10)], fillRule: .nonzero))],
                                      transform: .scale(1, 4)))
    let model = Model(document: Document(layers: [Layer(name: "L", children: [group])], selectedLayer: 0, selection: []))
    s2Click(model, "doc.path.insert_anchor_on_segment_near", 4, 4)
    let d = s1Commands(model, [0, 0, 0])
    guard d.count == 3, case .lineTo(let x, let y) = d[1] else { Issue.record("one anchor inserted: \(d)"); return }
    let want = 20.0 / 17.0
    #expect(abs(x - want) < 1e-12 && abs(y - want) < 1e-12, "inserted at local (\(x), \(y)), want (\(want), \(want))")
}

// MARK: - S3: the Partial Selection marquee selects where a thing is DRAWN
// Twins of the Rust `the_marquee_*` tests.

private func s3Marquee(_ model: Model, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> [ElementSelection] {
    runEffects([["doc.partial_select_in_rect": ["x1": x1, "y1": y1, "x2": x2, "y2": y2, "additive": false]]],
               ctx: [:], store: StateStore(), platformEffects: buildYamlToolEffects(model: model))
    return model.document.selection
}

/// Under the rotated frame the corner anchor 1, local (30,30), is drawn at
/// (70,80); the other two anchors are drawn at (100,50) and (100,110).
@Test func theMarqueeSelectsAControlPointWhereItIsDrawnUnderRotation() {
    let model = s1RotatedModel(s1CornerPath)
    #expect(s3Marquee(model, 65, 75, 75, 85) == [ElementSelection.partial([0, 0, 0, 0], [1])])
    #expect(s3Marquee(model, 25, 25, 35, 35).isEmpty, "the local position draws nothing")
}

/// A filled rect (0,0,30,30) in a group scaled 2 and moved (60,30) is drawn
/// over (60..120, 30..90). A marquee inside it holds no corner and still
/// touches the body: the element is selected with no control points.
@Test func theMarqueeHitsABodyWhereItIsDrawnInAScaledGroup() {
    let rect: Element = .rect(Rect(x: 0, y: 0, width: 30, height: 30, fill: Fill(color: Color(r: 1, g: 0, b: 0))))
    let group: Element = .group(Group(children: [rect], transform: Transform(a: 2, b: 0, c: 0, d: 2, e: 60, f: 30)))
    let model = Model(document: Document(layers: [Layer(name: "L", children: [group])], selectedLayer: 0, selection: []))
    #expect(s3Marquee(model, 80, 50, 90, 60) == [ElementSelection.partial([0, 0, 0], [])])
    #expect(s3Marquee(model, 130, 100, 140, 110).isEmpty, "outside the drawn body")
    #expect(s3Marquee(model, 10, 10, 20, 20).isEmpty, "the local body draws nothing")
}

/// The marquee reaches a Transformed wrapper's child only while isolated into
/// it. The wrapper scales a rect (2,2,10x10) by (2,3): corner 2 drawn at (24,36).
@Test func theMarqueeReachesAWrappedChildsCornerOnlyWhileIsolated() {
    let w = TransformedElem(child: .rect(Rect(x: 2, y: 2, width: 10, height: 10)), matrix: .scale(2, 3), scaleStrokes: false)
    let model = Model(document: Document(layers: [Layer(name: "L", children: [.live(.transformed(w))])],
                                         selectedLayer: 0, selection: []))
    #expect(s3Marquee(model, 22, 34, 26, 38).allSatisfy { $0.path != [0, 0, 0] }, "not isolated: the child is unreachable")
    model.layersIsolationStack = [[0, 0]]
    #expect(s3Marquee(model, 22, 34, 26, 38) == [ElementSelection.partial([0, 0, 0], [2])], "isolated: the drawn corner")
}

/// Under a SINGULAR frame (a group scaled to zero width) the marquee selects
/// nothing: the path's corner collapses onto (0,30).
@Test func theMarqueeSkipsAnElementWithASingularFrame() {
    let group: Element = .group(Group(children: [s1CornerPath], transform: .scale(0, 1)))
    let model = Model(document: Document(layers: [Layer(name: "L", children: [group])], selectedLayer: 0, selection: []))
    #expect(s3Marquee(model, -5, 25, 5, 35).isEmpty)
}

// MARK: - S4a: Smooth hits and fits where a path is DRAWN
// The ORACLE: smoothing P inside a frame F, then mapping through F, equals
// smoothing F(P) at the top level. Twin of Rust `the_smooth_tool_fits_in_document_space`.

private func s4Zigzag() -> [PathCommand] {
    [.moveTo(0, 0)] + (1...12).map { i in .lineTo(5 * Double(i), i % 2 == 1 ? 3 : 0) }
}

private func s4Smooth(_ d: [PathCommand], frame: Transform?, _ x: Double, _ y: Double) -> [PathCommand] {
    let pathElem: Element = .path(Path(d: d, fillRule: .nonzero))
    let child: Element = frame.map { .group(Group(children: [pathElem], transform: $0)) } ?? pathElem
    let path: ElementPath = frame == nil ? [0, 0] : [0, 0, 0]
    let model = Model(document: Document(layers: [Layer(name: "L", children: [child])], selectedLayer: 0,
                                         selection: [ElementSelection.all(path)]))
    runEffects([["doc.path.smooth_at_cursor": ["x": x, "y": y, "radius": 40, "fit_error": 2]]],
               ctx: [:], store: StateStore(), platformEffects: buildYamlToolEffects(model: model))
    return s1Commands(model, path)
}

private func s4Points(_ c: PathCommand) -> [Double] {
    switch c {
    case .moveTo(let x, let y), .lineTo(let x, let y): return [x, y]
    case .curveTo(let x1, let y1, let x2, let y2, let x, let y): return [x1, y1, x2, y2, x, y]
    default: return [.nan]
    }
}

@Test func theSmoothToolFitsInDocumentSpace() {
    let f = Transform(a: 2, b: 0, c: 0, d: 3, e: 100, f: 50)
    // The cursor is local (30, 1.5), drawn at (160, 54.5).
    let top = s4Smooth(mapPathCommands(s4Zigzag(), f), frame: nil, 160, 54.5)
    let grouped = s4Smooth(s4Zigzag(), frame: f, 160, 54.5)
    #expect(top.count < 13, "the oracle must smooth something: \(top.count) commands")
    let mapped = mapPathCommands(grouped, f)
    #expect(mapped.count == top.count)
    for (a, b) in zip(mapped, top) {
        let (pa, pb) = (s4Points(a), s4Points(b))
        #expect(pa.count == pb.count && zip(pa, pb).allSatisfy { abs($0 - $1) < 1e-9 }, "\(a) vs \(b)")
    }
    #expect(s4Smooth(s4Zigzag(), frame: f, 30, 1.5) == s4Zigzag(), "the local position draws nothing")
}

/// Under a SINGULAR frame Smooth leaves the path alone. Twin of Rust
/// `the_smooth_tool_skips_a_path_with_a_singular_frame`.
@Test func theSmoothToolSkipsAPathWithASingularFrame() {
    #expect(s4Smooth(s4Zigzag(), frame: .scale(1, 0), 30, 0) == s4Zigzag())
}

// MARK: - S4b: the Paintbrush edit hits and fits where a path is DRAWN
// Twins of the Rust `the_paintbrush_*` tests.

private func s4bEdit(_ d: [PathCommand], frame: Transform?, press: (Double, Double),
                     drag: [(Double, Double)]) -> (String?, [PathCommand]) {
    let pathElem: Element = .path(Path(d: d, fillRule: .nonzero))
    let child: Element = frame.map { .group(Group(children: [pathElem], transform: $0)) } ?? pathElem
    let path: ElementPath = frame == nil ? [0, 0] : [0, 0, 0]
    let model = Model(document: Document(layers: [Layer(name: "L", children: [child])], selectedLayer: 0,
                                         selection: [ElementSelection.all(path)]))
    let store = StateStore()
    let fx = buildYamlToolEffects(model: model)
    runEffects([["doc.paintbrush.edit_start": ["x": press.0, "y": press.1, "within": 12]]],
               ctx: [:], store: store, platformEffects: fx)
    let mode = store.getTool("paintbrush", "mode") as? String
    let buffer = frame == nil ? "s4b_top_swift" : "s4b_grouped_swift"
    pointBuffersClear(buffer)
    for p in drag { pointBuffersPush(buffer, p.0, p.1) }
    runEffects([["doc.paintbrush.edit_commit": ["buffer": buffer, "fit_error": 2, "within": 12]]],
               ctx: [:], store: store, platformEffects: fx)
    pointBuffersClear(buffer)
    return (mode, s1Commands(model, path))
}

@Test func thePaintbrushEditFitsInDocumentSpace() {
    let f = Transform(a: 2, b: 0, c: 0, d: 3, e: 100, f: 50)
    let d: [PathCommand] = [.moveTo(0, 0), .lineTo(20, 0), .lineTo(40, 0), .lineTo(60, 0)]
    let drag: [(Double, Double)] = [(140, 52), (150, 60), (160, 64), (170, 60), (180, 51)]
    let (topMode, top) = s4bEdit(mapPathCommands(d, f), frame: nil, press: (140, 50), drag: drag)
    let (mode, grouped) = s4bEdit(d, frame: f, press: (140, 50), drag: drag)
    #expect(topMode == "edit", "the oracle must enter edit mode")
    #expect(mode == "edit", "the drawn point is a hit")
    #expect(top != mapPathCommands(d, f), "the oracle must edit something")
    let mapped = mapPathCommands(grouped, f)
    #expect(mapped.count == top.count)
    for (a, b) in zip(mapped, top) {
        let (pa, pb) = (s4Points(a), s4Points(b))
        #expect(pa.count == pb.count && zip(pa, pb).allSatisfy { abs($0 - $1) < 1e-9 }, "\(a) vs \(b)")
    }
    #expect(s4bEdit(d, frame: f, press: (20, 0), drag: drag).0 != "edit", "the local position draws nothing")
}

@Test func thePaintbrushEditSkipsAPathWithASingularFrame() {
    let d: [PathCommand] = [.moveTo(0, 0), .lineTo(20, 0), .lineTo(40, 0)]
    let (mode, out) = s4bEdit(d, frame: .scale(0, 1), press: (0, 0), drag: [(0, 0), (0, 5), (0, 0)])
    #expect(mode != "edit")
    #expect(out == d)
}

/// The COMMIT refuses a singular frame on its own: the edit state is primed by
/// hand, at entry 2, because the collapsed points all tie and the exit search
/// returns index 0 (an entry of 0 would end as a degenerate range first).
@Test func thePaintbrushCommitSkipsAPathWithASingularFrame() {
    let d: [PathCommand] = [.moveTo(0, 0), .lineTo(20, 0), .lineTo(40, 0)]
    let group: Element = .group(Group(children: [.path(Path(d: d, fillRule: .nonzero))], transform: .scale(0, 1)))
    let model = Model(document: Document(layers: [Layer(name: "L", children: [group])], selectedLayer: 0, selection: []))
    let store = StateStore()
    store.setTool("paintbrush", "edit_target_path", ["__path__": [0, 0, 0]])
    store.setTool("paintbrush", "edit_entry_idx", 2)
    let buffer = "s4b_singular_swift"
    pointBuffersClear(buffer)
    for p in [(0.0, 0.0), (0.0, 5.0), (0.0, 10.0), (0.0, 0.0)] { pointBuffersPush(buffer, p.0, p.1) }
    runEffects([["doc.paintbrush.edit_commit": ["buffer": buffer, "fit_error": 2, "within": 12]]],
               ctx: [:], store: store, platformEffects: buildYamlToolEffects(model: model))
    pointBuffersClear(buffer)
    #expect(s1Commands(model, [0, 0, 0]) == d)
}

// MARK: - S6: the Selection marquee and lasso select where a thing is DRAWN
// Twins of the Rust `the_selection_*` tests.

private func s6Model(layer layerT: Transform?, group groupT: Transform?) -> Model {
    let rect: Element = .rect(Rect(x: 0, y: 0, width: 30, height: 30, fill: Fill(color: Color(r: 1, g: 0, b: 0))))
    let child: Element = groupT.map { .group(Group(children: [rect], transform: $0)) } ?? rect
    return Model(document: Document(layers: [Layer(name: "L", children: [child], transform: layerT)],
                                    selectedLayer: 0, selection: []))
}

@Test func theSelectionLassoSelectsAMemberWhereItIsDrawn() {
    let model = s6Model(layer: nil, group: Transform(a: 2, b: 0, c: 0, d: 2, e: 60, f: 30))
    Controller(model: model).selectPolygon(polygon: [(80, 50), (100, 50), (90, 70)])
    #expect(model.document.selection == [ElementSelection.all([0, 0])])
    Controller(model: model).selectPolygon(polygon: [(5, 5), (25, 5), (15, 25)])
    #expect(model.document.selection.isEmpty, "the local body draws nothing")
}

@Test func theSelectionMarqueeHonoursTheLayersTransform() {
    let model = s6Model(layer: .translate(200, 0), group: nil)
    Controller(model: model).selectRect(x: 210, y: 10, width: 5, height: 5)
    #expect(model.document.selection == [ElementSelection.all([0, 0])])
    Controller(model: model).selectRect(x: 10, y: 10, width: 5, height: 5)
    #expect(model.document.selection.isEmpty, "the untranslated position draws nothing")
}

@Test func theSelectionMarqueeSkipsAMemberWithASingularFrame() {
    let model = s6Model(layer: nil, group: .scale(0, 1))
    Controller(model: model).selectRect(x: -5, y: -5, width: 10, height: 40)
    #expect(model.document.selection.isEmpty)
    Controller(model: model).selectPolygon(polygon: [(-5, -5), (5, -5), (0, 40)])
    #expect(model.document.selection.isEmpty)
}

// MARK: - S5: the Path Eraser cuts where a path is DRAWN
// Twins of the Rust `the_eraser_*` tests.

private func s5Erase(_ len: Double, _ t: Transform, _ x: Double, _ y: Double) -> Model {
    let path: Element = .path(Path(d: [.moveTo(0, 0), .lineTo(len, 0)], transform: t, fillRule: .nonzero))
    let model = Model(document: Document(layers: [Layer(name: "L", children: [path])], selectedLayer: 0, selection: []))
    runEffects([["doc.path.erase_at_rect": ["last_x": x, "last_y": y, "x": x, "y": y, "eraser_size": 2]]],
               ctx: [:], store: StateStore(), platformEffects: buildYamlToolEffects(model: model))
    return model
}

/// The line is 3 long locally and drawn 30 long (scaled 10), so an erase at
/// its drawn middle splits it in two; judged by its local bounds it would be
/// deleted. Twin of Rust `the_eraser_judges_fit_by_the_drawn_bounds`.
@Test func theEraserJudgesFitByTheDrawnBounds() {
    #expect(s5Erase(3, .scale(10, 10), 15, 0).document.layers[0].children.count == 2)
}

/// Under a SINGULAR transform the eraser leaves the path alone.
@Test func theEraserSkipsAPathWithASingularFrame() {
    let model = s5Erase(30, .scale(0, 1), 0, 0)
    #expect(model.document.layers[0].children.count == 1)
    #expect(s1Commands(model, [0, 0]).count == 2)
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
        toolOrigin: "blob_brush", fillRule: .nonzero))
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

/// blobBrushCommitErasing rebuilds the surviving Path field by field
/// where Rust writes `PathElem { d: new_d, ..pe.clone() }`
/// (effects.rs §blob_brush_commit_erasing), so every field Swift does not
/// restate is silently reset to its initializer default. The remainder is
/// `booleanSubtract` output — the very producer this wave taught to emit
/// EvenOdd — so a dropped rule refills the hole the subtraction cut.
@Test func blobBrushCommitErasingPreservesEveryPathField() {
    let store = StateStore()
    blobBrushStateDefaults(store)
    // The sweep is 50pt horizontal along y=0 with a 10pt tip, so it
    // covers y in [-5, 5]. A tall square straddling that band is partly
    // erased, leaving a remainder rather than deleting the element.
    let target: Element = .path(Path(
        d: [
            .moveTo(10, -20),
            .lineTo(40, -20),
            .lineTo(40, 20),
            .lineTo(10, 20),
            .closePath,
        ],
        fill: Fill(color: Color.fromHex("#ff0000")!),
        toolOrigin: "blob_brush",
        name: "blob-1", id: "blob-id-1",
        fillRule: .evenodd))
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
    #expect(children.count == 1, "a remainder should survive the erase")
    guard case .path(let out) = children[0] else {
        Issue.record("expected .path"); return
    }
    #expect(out.fillRule == .evenodd, "erase reset the fill rule")
    #expect(out.name == "blob-1", "erase wiped the element name")
    #expect(out.id == "blob-id-1", "erase wiped the element id")
    #expect(out.toolOrigin == "blob_brush",
            "erase wiped the tool origin, orphaning the element from later sweeps")
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
        fill: Fill(color: Color.fromHex("#ff0000")!), fillRule: .nonzero))
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

/// doc.zoom.set anchors at the VIEWPORT CENTRE (RULED 2026-07-27,
/// transcripts/ZOOM_TOOL.md "zoom_to_actual_size RECENTRES"; mirrors Rust's
/// `test_doc_zoom_set_anchors_at_viewport_center`).
///
/// This test used to assert "pan unchanged" and passed, because that is what the
/// spec said in four places and what the effect did. The requirement underneath
/// that wording is that the artist keeps looking at the same thing, and holding
/// view_offset — the DOC ORIGIN's screen position — fixed while the zoom factor
/// changes by 4x does the opposite: the visible region quadruples around that
/// point and the artwork walks off the canvas. So the assertion is now the
/// invariant itself rather than a field's stillness.
@Test func docZoomSetAnchorsAtViewportCentre() {
    let model = Model()
    model.viewportW = 800.0
    model.viewportH = 600.0
    model.zoomLevel = 4.0
    // Off-centre pan, so a port that left it alone would be caught.
    model.viewOffsetX = 94.0
    model.viewOffsetY = -96.0
    let docUnderCentreBefore = ((400.0 - 94.0) / 4.0,      // 76.5
                                (300.0 - (-96.0)) / 4.0)   // 99.0
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.zoom.set": ["level": "1.0"]]],
               ctx: [:], store: store, platformEffects: effects)
    #expect(model.zoomLevel == 1.0)
    let docUnderCentreAfter = ((400.0 - model.viewOffsetX) / model.zoomLevel,
                               (300.0 - model.viewOffsetY) / model.zoomLevel)
    #expect(abs(docUnderCentreBefore.0 - docUnderCentreAfter.0) < 0.01)
    #expect(abs(docUnderCentreBefore.1 - docUnderCentreAfter.1) < 0.01)
    // The concrete triple that invariant implies, so a regression reads as a
    // number and not only as a broken relation.
    #expect(model.viewOffsetX == 400.0 - 76.5)
    #expect(model.viewOffsetY == 300.0 - 99.0)
}

/// The fallback: with the viewport unmeasured there is no centre to anchor on,
/// so doc.zoom.set writes the level and leaves the pan literally unchanged.
@Test func docZoomSetLeavesPanAloneWhenViewportUnmeasured() {
    let model = Model()
    model.viewportW = 0.0
    model.viewportH = 0.0
    model.zoomLevel = 2.5
    model.viewOffsetX = 100.0
    model.viewOffsetY = 50.0
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.zoom.set": ["level": "1.0"]]],
               ctx: [:], store: store, platformEffects: effects)
    #expect(model.zoomLevel == 1.0)
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

/// The -1 sentinel means the VIEWPORT CENTRE (RULED 2026-07-27,
/// transcripts/ZOOM_TOOL.md "the DEFAULT ZOOM ANCHOR is the viewport centre").
/// This effect used to have no viewport-centre branch at all: `anchorXRaw < 0`
/// fell through to the doc origin's screen position, and the `viewportW` the
/// Model carries was never read. Mirrors Rust's doc.zoom.apply arm.
@Test func docZoomApplyDefaultAnchorIsViewportCentre() {
    let model = Model()
    model.viewportW = 800.0
    model.viewportH = 600.0
    model.zoomLevel = 2.0
    model.viewOffsetX = -100.0
    model.viewOffsetY = -50.0
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.zoom.apply": [
        "factor":   "1.2",
        "anchor_x": "-1",
        "anchor_y": "-1",
    ]]], ctx: [:], store: store, platformEffects: effects)
    // ax=400 ay=300 ; doc_ax=250 doc_ay=175 ; z=2.4
    // px = 400 - 250*2.4 = -200 ; py = 300 - 175*2.4 = -120
    #expect(model.zoomLevel == 2.4)
    #expect(model.viewOffsetX == -200.0)
    #expect(model.viewOffsetY == -120.0)
    // Anchoring at the doc origin's screen position instead would land at
    // (-120, -60) — the value this port produced before the ruling.
    #expect(model.viewOffsetX != -120.0)
}

/// The fallback for the -1 sentinel: with the viewport unmeasured, the anchor is
/// the doc origin's screen position and the pan does not move.
@Test func docZoomApplyDefaultAnchorFallsBackWhenViewportUnmeasured() {
    let model = Model()
    model.viewportW = 0.0
    model.viewportH = 0.0
    model.zoomLevel = 2.0
    model.viewOffsetX = -100.0
    model.viewOffsetY = -50.0
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects([["doc.zoom.apply": [
        "factor":   "1.2",
        "anchor_x": "-1",
        "anchor_y": "-1",
    ]]], ctx: [:], store: store, platformEffects: effects)
    #expect(model.zoomLevel == 2.4)
    #expect(model.viewOffsetX == -100.0)
    #expect(model.viewOffsetY == -50.0)
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

// MARK: - Partial Selection control-point selection (SEL-100/103/105/106)
//
// CP-LEVEL selection through the Partial Selection effects. twoRectModel's
// first rect (0,0,10,10) exposes four control points at its corners:
// cp0=(0,0), cp1=(10,0), cp2=(10,10), cp3=(0,10) (Element.controlPointPositions).
// `doc.path.probe_partial_hit` selects the CP under the cursor (or shift-toggles
// it into the per-element partial set); `doc.path.commit_partial_marquee`
// selects every CP inside the rubber-band rect. These assert the CP-level
// SelectionKind (.partial carrying the enclosed indices), not just which
// element is touched — the granularity the Rust GUI run could only judge
// visually. The second rect lives at path [0, 1] and must stay untouched.

/// SEL-100: clicking a single control point selects exactly that CP (a
/// `.partial` selection of one), not the whole element.
@Test func partialSelectionCpClickSelectsSingleControlPoint() {
    let model = twoRectModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    runEffects(
        [["doc.path.probe_partial_hit": ["x": 0, "y": 0, "hit_radius": 8]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let entry = model.document.selection.first { $0.path == [0, 0] }
    #expect(entry != nil)
    #expect(entry?.kind.contains(0) == true)        // cp0 = (0,0) is selected
    #expect(entry?.kind.count(total: 4) == 1)       // exactly one CP …
    #expect(entry?.kind.isAll(total: 4) == false)   // … so NOT the whole element
    #expect(store.getTool("partial_selection", "mode") as? String == "moving_pending")
    #expect(!model.document.selection.contains { $0.path == [0, 1] })
}

/// SEL-103/104 (designate): shift-clicking control points adds them to the
/// per-element partial set, and shift-clicking a selected CP toggles it off.
@Test func partialSelectionShiftClickAddsAndTogglesControlPoints() {
    let model = twoRectModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    // Plain click cp0.
    runEffects(
        [["doc.path.probe_partial_hit": ["x": 0, "y": 0, "hit_radius": 8]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.selection.first { $0.path == [0, 0] }?
        .kind.count(total: 4) == 1)
    // Shift-click cp1 = (10,0): ADDS it → two CPs selected on the same element.
    runEffects(
        [["doc.path.probe_partial_hit":
            ["x": 10, "y": 0, "hit_radius": 8, "shift": true]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let two = model.document.selection.first { $0.path == [0, 0] }
    #expect(two?.kind.count(total: 4) == 2)
    #expect(two?.kind.contains(0) == true)
    #expect(two?.kind.contains(1) == true)
    // Shift-click cp1 AGAIN: toggles it OFF → back to just cp0.
    runEffects(
        [["doc.path.probe_partial_hit":
            ["x": 10, "y": 0, "hit_radius": 8, "shift": true]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let one = model.document.selection.first { $0.path == [0, 0] }
    #expect(one?.kind.count(total: 4) == 1)
    #expect(one?.kind.contains(0) == true)
    #expect(one?.kind.contains(1) == false)
}

/// SEL-105: a marquee enclosing only one corner selects exactly that one CP
/// (proving CP-level, not whole-element, marquee granularity).
@Test func partialSelectionMarqueeSelectsOnlyEnclosedControlPoint() {
    let model = twoRectModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    // Rect (-5,-5)..(5,5) encloses cp0=(0,0) only; cp1/cp2/cp3 are at x or y = 10.
    runEffects(
        [["doc.path.commit_partial_marquee":
            ["x1": -5, "y1": -5, "x2": 5, "y2": 5]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let entry = model.document.selection.first { $0.path == [0, 0] }
    #expect(entry != nil)
    #expect(entry?.kind.contains(0) == true)
    #expect(entry?.kind.count(total: 4) == 1)
    #expect(entry?.kind.isAll(total: 4) == false)
    #expect(!model.document.selection.contains { $0.path == [0, 1] })
}

/// SEL-105: a marquee enclosing all four corners selects every CP of the
/// element, and leaves the out-of-rect element untouched.
@Test func partialSelectionMarqueeSelectsAllEnclosedControlPoints() {
    let model = twoRectModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    // Rect (-5,-5)..(15,15) encloses all four corners of rect[0,0]; rect[0,1]
    // lives at (50,50) and is fully outside.
    runEffects(
        [["doc.path.commit_partial_marquee":
            ["x1": -5, "y1": -5, "x2": 15, "y2": 15]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let entry = model.document.selection.first { $0.path == [0, 0] }
    #expect(entry != nil)
    #expect(entry?.kind.count(total: 4) == 4)
    #expect(entry?.kind.isAll(total: 4) == true)
    #expect(!model.document.selection.contains { $0.path == [0, 1] })
}

/// SEL-106: an empty (zero-size) marquee with no shift clears the CP selection.
@Test func partialSelectionEmptyMarqueeClearsSelection() {
    let model = twoRectModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    // Select a CP first.
    runEffects(
        [["doc.path.probe_partial_hit": ["x": 0, "y": 0, "hit_radius": 8]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(!model.document.selection.isEmpty)
    // A zero-size marquee (rw,rh <= 1), non-additive, clears the selection.
    runEffects(
        [["doc.path.commit_partial_marquee":
            ["x1": 100, "y1": 100, "x2": 100, "y2": 100]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.selection.isEmpty)
}

// MARK: - Partial Selection control-point DRAG (SEL-130 CP translate)
//
// Dragging a selected control point is `doc.translate_selection` over a
// PARTIAL selection: `Controller.moveSelection` calls
// `elem.moveControlPoints(es.kind, …)`, so ONLY the selected CPs move. A rect's
// corners are not independently movable, so these use a triangle Path whose
// anchors are cp0=(0,0), cp1=(100,0), cp2=(50,100)
// (Element.controlPointPositions == pathAnchorPoints(d)).

private func trianglePathModel() -> Model {
    let tri: Element = .path(Path(
        d: [.moveTo(0, 0), .lineTo(100, 0), .lineTo(50, 100), .closePath],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1), fillRule: .nonzero))
    return Model(document: Document(
        layers: [Layer(children: [tri])], selectedLayer: 0, selection: []))
}

private func cpsEqual(_ a: (Double, Double), _ x: Double, _ y: Double) -> Bool {
    abs(a.0 - x) < 1e-9 && abs(a.1 - y) < 1e-9
}

/// SEL-130: dragging a single selected control point translates ONLY that
/// anchor; the other anchors of the same path stay put.
@Test func partialSelectionCpDragTranslatesOnlySelectedControlPoint() {
    let model = trianglePathModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    // Select anchor 0 = (0,0).
    runEffects(
        [["doc.path.probe_partial_hit": ["x": 0, "y": 0, "hit_radius": 8]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.selection.first { $0.path == [0, 0] }?.kind.contains(0) == true)
    // Drag that CP by (+20, +30).
    runEffects(
        [["doc.translate_selection": ["dx": 20, "dy": 30]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let cps = model.document.layers[0].children[0].controlPointPositions
    #expect(cps.count == 3)
    #expect(cpsEqual(cps[0], 20, 30))     // anchor 0 moved …
    #expect(cpsEqual(cps[1], 100, 0))     // … anchors 1 and 2 unchanged
    #expect(cpsEqual(cps[2], 50, 100))
    // Selection preserved (still the same single CP).
    #expect(model.document.selection.first { $0.path == [0, 0] }?.kind.count(total: 3) == 1)
}

/// SEL-130: dragging a multi-CP selection translates EVERY selected anchor by
/// the same delta and leaves the unselected anchor put.
@Test func partialSelectionCpDragTranslatesAllSelectedControlPoints() {
    let model = trianglePathModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)
    // Select anchor 0 = (0,0), then shift-add anchor 2 = (50,100).
    runEffects(
        [["doc.path.probe_partial_hit": ["x": 0, "y": 0, "hit_radius": 8]]],
        ctx: [:], store: store, platformEffects: effects
    )
    runEffects(
        [["doc.path.probe_partial_hit":
            ["x": 50, "y": 100, "hit_radius": 8, "shift": true]]],
        ctx: [:], store: store, platformEffects: effects
    )
    #expect(model.document.selection.first { $0.path == [0, 0] }?.kind.count(total: 3) == 2)
    // Drag the pair by (+10, -10).
    runEffects(
        [["doc.translate_selection": ["dx": 10, "dy": -10]]],
        ctx: [:], store: store, platformEffects: effects
    )
    let cps = model.document.layers[0].children[0].controlPointPositions
    #expect(cpsEqual(cps[0], 10, -10))    // anchor 0 moved
    #expect(cpsEqual(cps[1], 100, 0))     // anchor 1 NOT selected → unchanged
    #expect(cpsEqual(cps[2], 60, 90))     // anchor 2 moved
}

// MARK: - Partial Selection Bezier HANDLE drag (SEL-131 / SEL-306)
//
// Dragging a Bezier HANDLE (not the anchor) of a SMOOTH path anchor is
// `doc.move_path_handle`. The effect reads the latched handle target from
// partial_selection tool state — `handle_path` (encoded ElementPath),
// `handle_anchor_idx`, `handle_type` ("in"|"out") — and applies (dx,dy) to
// the named handle. The opposite handle is then rotated to stay COLLINEAR
// through the anchor while keeping its OWN distance (smooth-point semantics,
// `reflectHandleKeepDistance` in Element.swift), and the anchor stays put.
//
// The CP/marquee tests above use a POLYLINE triangle, which has no handles.
// Handle drags need a CURVED Path: a smooth middle anchor whose in- and
// out-handles are collinear-through-the-anchor and equidistant, so the
// reflection is an exact point-reflection (clean integer assertions).
//
// Fixture — a two-segment cubic path:
//   moveTo(0,100)                                          anchor 0 = (0,100)
//   curveTo(20,100, 80,100, 100,100)   anchor 1 = (100,100), in-handle (80,100)
//   curveTo(120,100, 180,100, 200,100) anchor 2 = (200,100), out-handle of
//                                       anchor 1 = (120,100)
// Anchor 1 is the SMOOTH anchor under test: in-handle (80,100) and out-handle
// (120,100) sit on opposite sides of the anchor, both 20 units away — a true
// smooth point. (pathHandlePositions returns (in, out) for an anchor index.)

// Anchor (end-point) position of a path command, for asserting the anchor
// stays put. Mirrors the anchor read in pathHandlePositions / movePathHandle.
private func anchorPos(_ d: [PathCommand], _ anchorIdx: Int) -> (Double, Double) {
    var cmdIndices: [Int] = []
    for (ci, cmd) in d.enumerated() {
        if case .closePath = cmd { continue }
        cmdIndices.append(ci)
    }
    switch d[cmdIndices[anchorIdx]] {
    case .moveTo(let x, let y), .lineTo(let x, let y): return (x, y)
    case .curveTo(_, _, _, _, let x, let y): return (x, y)
    default: fatalError("anchor command has no end point")
    }
}

// decodePath in YamlToolEffects reads handle_path as ["__path__": [Int]]; mirror
// its encoding here (encodePath itself is file-private to that module).
private func latchedPath(_ p: ElementPath) -> [String: Any] {
    ["__path__": p as [Any]]
}

private func smoothCurvePathModel() -> Model {
    let curve: Element = .path(Path(
        d: [
            .moveTo(0, 100),
            .curveTo(x1: 20, y1: 100, x2: 80, y2: 100, x: 100, y: 100),
            .curveTo(x1: 120, y1: 100, x2: 180, y2: 100, x: 200, y: 100),
        ],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1), fillRule: .nonzero))
    return Model(document: Document(
        layers: [Layer(children: [curve])], selectedLayer: 0, selection: []))
}

/// SEL-131/306: dragging the OUT handle of a smooth anchor moves that handle
/// by (dx,dy); the opposite IN handle is reflected through the anchor (mirror /
/// smooth-point behavior), and the anchor itself does not move.
///
/// Empirically observed (this is the ACTUAL impl behavior, not an assumption):
///   anchor 1 = (100,100) before and after — stays put.
///   out-handle (120,100) --[drag (-20,+20)]--> (100,120)   moved by (dx,dy)
///   in-handle  (80,100)  --[MIRRORED]--------> (100, 80)   reflected through
///       the anchor: 2*anchor - newOut = (200,200)-(100,120) = (100,80).
/// The drag was chosen so the new out-handle keeps the in-handle's distance
/// (both 20 from the anchor), making the collinear reflection an exact
/// point-reflection. A broken/independent mirror would leave the in-handle at
/// (80,100) and fail the (100,80) assertion below.
@Test func partialSelectionHandleDragOutMirrorsOppositeInHandle() {
    let model = smoothCurvePathModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)

    // BEFORE: confirm the smooth-point fixture.
    let d0 = { () -> [PathCommand] in
        guard case .path(let p) = model.document.layers[0].children[0] else {
            fatalError("expected path element")
        }
        return p.d
    }()
    let (in0, out0) = pathHandlePositions(d0, anchorIdx: 1)
    #expect(in0 != nil && cpsEqual(in0!, 80, 100))     // in-handle  (80,100)
    #expect(out0 != nil && cpsEqual(out0!, 120, 100))  // out-handle (120,100)
    #expect(cpsEqual(anchorPos(d0, 1), 100, 100))      // anchor (100,100)

    // Latch the handle target the way probe_partial_hit would: anchor 1's
    // OUT handle on element [0,0].
    store.setTool("partial_selection", "handle_path", latchedPath([0, 0]))
    store.setTool("partial_selection", "handle_anchor_idx", 1)
    store.setTool("partial_selection", "handle_type", "out")

    // Drag the OUT handle by (dx=-20, dy=+20): (120,100) -> (100,120).
    runEffects(
        [["doc.move_path_handle": ["dx": -20, "dy": 20]]],
        ctx: [:], store: store, platformEffects: effects
    )

    // AFTER.
    guard case .path(let p1) = model.document.layers[0].children[0] else {
        fatalError("expected path element")
    }
    let (in1, out1) = pathHandlePositions(p1.d, anchorIdx: 1)
    // Dragged handle moved by exactly (dx,dy).
    #expect(out1 != nil && cpsEqual(out1!, 100, 120))
    // Opposite handle MIRRORED through the anchor (non-vacuous: a no-op /
    // independent impl would leave this at (80,100)).
    #expect(in1 != nil && cpsEqual(in1!, 100, 80))
    // Anchor unmoved.
    #expect(cpsEqual(anchorPos(p1.d, 1), 100, 100))
    // The other anchors' positions are untouched too.
    #expect(cpsEqual(anchorPos(p1.d, 0), 0, 100))
    #expect(cpsEqual(anchorPos(p1.d, 2), 200, 100))
}

/// SEL-131/306 (symmetric case): dragging the IN handle mirrors the OUT handle.
/// Drag the in-handle (80,100) by (dx=+20, dy=+20) -> (100,120); the out-handle
/// reflects through the anchor to (100,80) = 2*(100,100)-(100,120). Same
/// smooth-point semantics, exercised from the opposite handle so neither
/// branch of movePathHandle is left unpinned.
@Test func partialSelectionHandleDragInMirrorsOppositeOutHandle() {
    let model = smoothCurvePathModel()
    let store = StateStore()
    let effects = buildYamlToolEffects(model: model)

    store.setTool("partial_selection", "handle_path", latchedPath([0, 0]))
    store.setTool("partial_selection", "handle_anchor_idx", 1)
    store.setTool("partial_selection", "handle_type", "in")

    // Drag the IN handle by (dx=+20, dy=+20): (80,100) -> (100,120).
    runEffects(
        [["doc.move_path_handle": ["dx": 20, "dy": 20]]],
        ctx: [:], store: store, platformEffects: effects
    )

    guard case .path(let p1) = model.document.layers[0].children[0] else {
        fatalError("expected path element")
    }
    let (in1, out1) = pathHandlePositions(p1.d, anchorIdx: 1)
    #expect(in1 != nil && cpsEqual(in1!, 100, 120))    // dragged in-handle
    #expect(out1 != nil && cpsEqual(out1!, 100, 80))   // MIRRORED out-handle
    #expect(cpsEqual(anchorPos(p1.d, 1), 100, 100))    // anchor put
}

// MARK: - S7: the anchor probes must skip a LOCKED Path

// Mirror of jas_dioxus `effects.rs`
// `anchor_probes_hit_when_nothing_is_locked` /
// `anchor_probe_skips_a_locked_path` /
// `delete_anchor_near_skips_a_locked_path` /
// `insert_anchor_on_segment_skips_a_locked_path`, same geometry and the
// same probe points.
//
// SCOPE-effective-locked.md §4, S7: this port already guarded all three
// positions (direct Path, Group, Path-inside-Group) in all four
// `findPath*` / `tryPath` walkers; jas_dioxus guarded only the Group. So
// these are REGRESSION PINS on the correct side of a divergence whose
// red was in Rust -- they exist so the pair cannot drift apart again in
// either direction.
//
// PER-PORT, because no shared fixture can seed a locked document: every
// cross-language document case starts from a `setup_svg` and the SVG
// codec does not persist `locked` at all.

/// A three-anchor curve: anchors at (0,dy), (30,dy), (60,dy); handles
/// around the middle anchor at (20,10+dy) and (40,-10+dy).
private func s7Curve(_ dy: Double) -> [PathCommand] {
    [
        .moveTo(0, dy),
        .curveTo(x1: 10, y1: 10 + dy, x2: 20, y2: 10 + dy, x: 30, y: dy),
        .curveTo(x1: 40, y1: -10 + dy, x2: 50, y2: -10 + dy, x: 60, y: dy),
    ]
}

/// [0,0] a Path locked per the argument (the DIRECT arm); [0,1] an
/// UNLOCKED Group holding [0,1,0], a Path locked per the argument (the
/// NESTED arm), 100 units lower. The group is never locked: the group
/// guard is not the arm under test.
private func s7Model(locked: Bool) -> Model {
    func mk(_ dy: Double) -> Element {
        .path(Path(d: s7Curve(dy), locked: locked, fillRule: .nonzero))
    }
    let group = Element.group(Group(children: [mk(100)]))
    let layer = Layer(name: "L", children: [mk(0), group])
    return Model(document: Document(layers: [layer], selectedLayer: 0, selection: []))
}

private func s7ProbeMode(_ locked: Bool, _ x: Double, _ y: Double) -> String {
    let model = s7Model(locked: locked)
    let store = StateStore()
    store.setTool("anchor_point", "mode", "idle")
    runEffects(
        [["doc.path.probe_anchor_hit": ["x": x, "y": y, "hit_radius": 5]]],
        ctx: [:], store: store, platformEffects: buildYamlToolEffects(model: model)
    )
    return (store.getTool("anchor_point", "mode") as? String) ?? ""
}

/// Positive control for the family: with NOTHING locked all four probe
/// points land, so the "locked => idle" assertions below cannot pass by
/// missing the geometry.
@Test func anchorProbesHitWhenNothingIsLocked() {
    #expect(s7ProbeMode(false, 20, 10) == "pressed_handle")
    #expect(s7ProbeMode(false, 30, 0) == "pressed_smooth")
    #expect(s7ProbeMode(false, 20, 110) == "pressed_handle")
    #expect(s7ProbeMode(false, 30, 100) == "pressed_smooth")
}

@Test func anchorProbeSkipsALockedPath() {
    #expect(s7ProbeMode(true, 20, 10) == "idle")     // handle, DIRECT
    #expect(s7ProbeMode(true, 30, 0) == "idle")      // anchor, DIRECT
    #expect(s7ProbeMode(true, 20, 110) == "idle")    // handle, NESTED
    #expect(s7ProbeMode(true, 30, 100) == "idle")    // anchor, NESTED
}

/// Command count of the Path at `path` after running one effect.
private func s7CommandCount(
    _ locked: Bool, _ verb: String, _ x: Double, _ y: Double, at path: ElementPath
) -> Int {
    let model = s7Model(locked: locked)
    let store = StateStore()
    runEffects(
        [[verb: ["x": x, "y": y, "hit_radius": 5]]],
        ctx: [:], store: store, platformEffects: buildYamlToolEffects(model: model)
    )
    guard case .path(let p) = model.document.getElement(path) else { return -1 }
    return p.d.count
}

@Test func deleteAnchorNearSkipsALockedPath() {
    let del = "doc.path.delete_anchor_near"
    #expect(s7CommandCount(false, del, 30, 0, at: [0, 0]) == 2)
    #expect(s7CommandCount(false, del, 30, 100, at: [0, 1, 0]) == 2)
    #expect(s7CommandCount(true, del, 30, 0, at: [0, 0]) == 3)
    #expect(s7CommandCount(true, del, 30, 100, at: [0, 1, 0]) == 3)
}

/// (15, 7.5) is the t = 0.5 point of the first cubic; the nested copy's
/// is (15, 107.5).
@Test func insertAnchorOnSegmentSkipsALockedPath() {
    let ins = "doc.path.insert_anchor_on_segment_near"
    #expect(s7CommandCount(false, ins, 15, 7.5, at: [0, 0]) == 4)
    #expect(s7CommandCount(false, ins, 15, 107.5, at: [0, 1, 0]) == 4)
    #expect(s7CommandCount(true, ins, 15, 7.5, at: [0, 0]) == 3)
    #expect(s7CommandCount(true, ins, 15, 107.5, at: [0, 1, 0]) == 3)
}

// MARK: - brush.options_confirm reads whole numbers (bank 10-16 §1 item 1)
//
// A dialog commit stores an integral number as a Swift `Int`
// (`valueToAnyDlg` -> `intIfIntegral`), and `as? Double` does not read a Swift
// `Int` out of `Any`: the shape that collapsed the artboard resize (#470). The
// defaults (0, 100, 5) are themselves whole, so only a value that DIFFERS from
// its default can show the read failing.

private func brushConfirm(_ dialog: [String: Any], mode: String = "create",
                          slug: String = "") -> [String: Any]? {
    let store = StateStore()
    store.setDataPath("brush_libraries", ["lib": ["brushes": [
        ["name": "Old", "slug": "old", "type": "calligraphic",
         "angle": 1.0, "roundness": 2.0, "size": 3.0],
    ]]])
    store.initDialog("brush_options", defaults: dialog,
                     params: ["mode": mode, "library": "lib", "brush_slug": slug])
    let effects = buildYamlToolEffects(model: Model())
    _ = effects["brush.options_confirm"]!(NSNull(), [:], store)
    let brushes = store.getDataPath("brush_libraries.lib.brushes") as? [[String: Any]] ?? []
    return brushes.first { ($0["slug"] as? String) == (mode == "create" ? "new" : slug) }
}

private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? Double) }

@Test func brushOptionsConfirmCreateReadsWholeNumbers() {
    let b = brushConfirm(["brush_name": "New", "brush_type": "calligraphic",
                          "angle": 45, "roundness": 50, "size": 12])
    #expect(num(b?["angle"]) == 45)
    #expect(num(b?["roundness"]) == 50)
    #expect(num(b?["size"]) == 12)
}

@Test func brushOptionsConfirmLibraryEditReadsWholeNumbers() {
    let b = brushConfirm(["brush_name": "Old", "brush_type": "calligraphic",
                          "angle": 45, "roundness": 50, "size": 12],
                         mode: "library_edit", slug: "old")
    #expect(num(b?["angle"]) == 45)
    #expect(num(b?["roundness"]) == 50)
    #expect(num(b?["size"]) == 12)
}

@Test func brushOptionsConfirmStillReadsFractions() {
    // The control: a Double reads today, and must keep reading.
    let b = brushConfirm(["brush_name": "New", "brush_type": "calligraphic",
                          "angle": 45.5, "roundness": 50.5, "size": 12.5])
    #expect(num(b?["angle"]) == 45.5)
    #expect(num(b?["roundness"]) == 50.5)
    #expect(num(b?["size"]) == 12.5)
}

// MARK: - strokeCompensation (Scale Strokes under a stored transform)

@Test func strokeCompensationOnLeavesOffDividesAndAZeroScaleCompensatesNothing() {
    #expect(strokeCompensation(sx: 1.5, sy: 1.5, scaleStrokes: true) == nil)
    #expect(abs(strokeCompensation(sx: 1.5, sy: 1.5, scaleStrokes: false)! - 1.0 / 1.5) < 1e-12)
    // A 0 % scale collapses the shape; 1/0 would write an infinite width.
    #expect(strokeCompensation(sx: 0, sy: 2, scaleStrokes: false) == nil)
    #expect(strokeCompensation(sx: 2, sy: 0, scaleStrokes: false) == nil)
}
