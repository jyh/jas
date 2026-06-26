import Testing
import Foundation
@testable import JasLib

// Anchor-edit tool gesture-seam tests — Swift port of the Rust anchor-EDIT
// seam tests in jas_dioxus/src/tools/yaml_tool.rs. ONE combined file covering
// all three anchor-edit tools: anchor_point, add_anchor_point, and
// delete_anchor_point.
//
// Each case loads the PRODUCTION tool from the workspace bundle and drives it
// through on_press / on_release. With an identity view, doc coords equal the
// screen coords passed to the verbs. These tools read NO app-level state
// (anchor edits resolve purely from the path geometry under the cursor), so —
// unlike the blob/selection seam tests — there is no app-state seed/bridge
// call. The ToolContext hit-test closures are stubbed because the anchor
// effects hit-test directly against the document geometry by coordinate.
//
// Seam mapping from Rust to Swift:
//   on_press        -> onPress(ctx, x:, y:, shift:, alt:)
//   on_release      -> onRelease(ctx, x:, y:, shift:, alt:)
//
// The numbers below mirror the Rust fixtures and assertions EXACTLY:
//   model_with_smooth_three_anchor_path  (anchor_point)
//   model_with_horizontal_line_path      (add_anchor_point)
//   model_with_four_anchor_path          (delete_anchor_point)

private func anchorTool(_ id: String) -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools[id] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

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

private func pathModel(_ d: [PathCommand]) -> Model {
    let path = Path(d: d, fill: nil, stroke: nil)
    let layer = Layer(name: "L", children: [.path(path)])
    return Model(document: Document(
        layers: [layer], selectedLayer: 0, selection: []
    ))
}

private func firstPath(_ model: Model) -> Path? {
    let children = model.document.layers[0].children
    guard let first = children.first, case .path(let p) = first else { return nil }
    return p
}

// MARK: - add_anchor_point tool

// model_with_horizontal_line_path: MoveTo(0,0) + LineTo(100,0).
private func modelWithHorizontalLinePath() -> Model {
    pathModel([
        .moveTo(0, 0),
        .lineTo(100, 0),
    ])
}

@Test func addAnchorParityClickOnLineInsertsMidpoint() throws {
    // Click at (50, 0) — exactly on the line at t=0.5. Expect 3 commands:
    // MoveTo, LineTo(mid=50,0), LineTo(end=100,0). Undo available.
    let tool = try #require(anchorTool("add_anchor_point"))
    let model = modelWithHorizontalLinePath()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)

    let pe = try #require(firstPath(model))
    #expect(pe.d.count == 3)
    guard case .lineTo(let x, let y) = pe.d[1] else {
        Issue.record("expected inserted LineTo at midpoint, got \(pe.d[1])")
        return
    }
    #expect(abs(x - 50) < 0.01)
    #expect(abs(y) < 0.01)
    #expect(model.canUndo)
}

@Test func addAnchorParityClickFarFromPathIsNoop() throws {
    // Click in empty space -> path unchanged (still 2 commands), no undo.
    let tool = try #require(anchorTool("add_anchor_point"))
    let model = modelWithHorizontalLinePath()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 500, y: 500, shift: false, alt: false)
    tool.onRelease(ctx, x: 500, y: 500, shift: false, alt: false)

    let pe = try #require(firstPath(model))
    #expect(pe.d.count == 2)
    #expect(!model.canUndo)
}

@Test func addAnchorParityClickOnCurveSplitsIt() throws {
    // Single cubic from (0,0) to (100,0) with symmetric handles (25,50)/(75,50).
    // Click near the curve's midpoint at t=0.5 -> MoveTo + 2 CurveTos. First
    // CurveTo endpoint is the mid-point.
    let tool = try #require(anchorTool("add_anchor_point"))
    let model = pathModel([
        .moveTo(0, 0),
        .curveTo(x1: 25, y1: 50, x2: 75, y2: 50, x: 100, y: 0),
    ])
    let ctx = makeCtx(model: model)
    let (midX, midY) = evalCubic(0, 0, 25, 50, 75, 50, 100, 0, 0.5)
    tool.onPress(ctx, x: midX, y: midY, shift: false, alt: false)
    tool.onRelease(ctx, x: midX, y: midY, shift: false, alt: false)

    let pe = try #require(firstPath(model))
    #expect(pe.d.count == 3)
    guard case .curveTo = pe.d[1] else {
        Issue.record("expected CurveTo at d[1], got \(pe.d[1])")
        return
    }
    guard case .curveTo(_, _, _, _, let x, let y) = pe.d[1] else { return }
    #expect(abs(x - midX) < 0.1)
    #expect(abs(y - midY) < 0.1)
    guard case .curveTo = pe.d[2] else {
        Issue.record("expected CurveTo at d[2], got \(pe.d[2])")
        return
    }
}

// MARK: - anchor_point tool

// model_with_smooth_three_anchor_path: MoveTo(0,0),
//   CurveTo(x1=10,y1=20, x2=40,y2=20, x=50,y=0),
//   CurveTo(x1=60,y1=-20, x2=90,y2=-20, x=100,y=0).
private func modelWithSmoothThreeAnchorPath() -> Model {
    pathModel([
        .moveTo(0, 0),
        .curveTo(x1: 10, y1: 20, x2: 40, y2: 20, x: 50, y: 0),
        .curveTo(x1: 60, y1: -20, x2: 90, y2: -20, x: 100, y: 0),
    ])
}

@Test func anchorPointParityClickSmoothMakesCorner() throws {
    // Smooth anchor lives at (50, 0) — click without drag. Anchor index 1
    // should convert from smooth to corner. Undo available.
    let tool = try #require(anchorTool("anchor_point"))
    let model = modelWithSmoothThreeAnchorPath()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)

    let pe = try #require(firstPath(model))
    #expect(!isSmoothPoint(pe.d, anchorIdx: 1),
            "click on smooth anchor should convert it to corner")
    #expect(model.canUndo)
}

@Test func anchorPointParityDragHandleMovesIt() throws {
    // Outgoing handle of anchor 1 at (60, -20) — drag it by (+10, +5).
    // x1 of cmd[2] (outgoing handle of anchor 1) should now be (70, -15);
    // x2/y2 of cmd[1] (incoming handle of anchor 1) should be UNCHANGED at
    // (40, 20) — an independent move.
    let tool = try #require(anchorTool("anchor_point"))
    let model = modelWithSmoothThreeAnchorPath()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 60, y: -20, shift: false, alt: false)
    tool.onRelease(ctx, x: 70, y: -15, shift: false, alt: false)

    let pe = try #require(firstPath(model))
    guard case .curveTo(let x1, let y1, _, _, _, _) = pe.d[2] else {
        Issue.record("expected CurveTo at d[2], got \(pe.d[2])")
        return
    }
    #expect(abs(x1 - 70) < 0.01)
    #expect(abs(y1 - (-15)) < 0.01)
    guard case .curveTo(_, _, let x2, let y2, _, _) = pe.d[1] else {
        Issue.record("expected CurveTo at d[1], got \(pe.d[1])")
        return
    }
    #expect(abs(x2 - 40) < 0.01)
    #expect(abs(y2 - 20) < 0.01)
}

@Test func anchorPointParityDragCornerPullsOutSmoothHandles() throws {
    // Corner-only path (all LineTos). Corner anchor at (50, 0). Press there,
    // drag to (50, 30) -> anchor 1 becomes smooth (symmetric handles pulled).
    let tool = try #require(anchorTool("anchor_point"))
    let model = pathModel([
        .moveTo(0, 0),
        .lineTo(50, 0),
        .lineTo(100, 0),
    ])
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 30, shift: false, alt: false)

    let pe = try #require(firstPath(model))
    #expect(isSmoothPoint(pe.d, anchorIdx: 1),
            "dragging a corner anchor should pull out smooth handles")
}

@Test func anchorPointParityClickWithoutHitIsNoop() throws {
    // Click empty space -> nothing changes, no undo snapshot.
    let tool = try #require(anchorTool("anchor_point"))
    let model = modelWithSmoothThreeAnchorPath()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 500, y: 500, shift: false, alt: false)
    tool.onRelease(ctx, x: 500, y: 500, shift: false, alt: false)

    #expect(!model.canUndo)
}

// MARK: - delete_anchor_point tool

// model_with_four_anchor_path: MoveTo(0,0) + three CurveTos ending at
//   (30,0), (60,0), (90,0), all with flat (y=0) handles.
private func modelWithFourAnchorPath() -> Model {
    pathModel([
        .moveTo(0, 0),
        .curveTo(x1: 10, y1: 0, x2: 20, y2: 0, x: 30, y: 0),
        .curveTo(x1: 40, y1: 0, x2: 50, y2: 0, x: 60, y: 0),
        .curveTo(x1: 70, y1: 0, x2: 80, y2: 0, x: 90, y: 0),
    ])
}

@Test func deleteAnchorParityClickOnInteriorRemovesAnchor() throws {
    // Click on the anchor at (60, 0) — command index 2. The path should drop
    // from 4 anchors to 3 (and re-fit the neighbours). Path still exists.
    // Undoable.
    let tool = try #require(anchorTool("delete_anchor_point"))
    let model = modelWithFourAnchorPath()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 60, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 60, y: 0, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1, "path should still exist")
    let pe = try #require(firstPath(model))
    #expect(pe.d.count == 3)
    #expect(model.canUndo, "delete should be undoable")
}

@Test func deleteAnchorParityClickEmptyIsNoop() throws {
    // Click empty space -> path unchanged (still 4 commands), no undo.
    let tool = try #require(anchorTool("delete_anchor_point"))
    let model = modelWithFourAnchorPath()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 500, y: 500, shift: false, alt: false)
    tool.onRelease(ctx, x: 500, y: 500, shift: false, alt: false)

    let pe = try #require(firstPath(model))
    #expect(pe.d.count == 4)
    #expect(!model.canUndo)
}
