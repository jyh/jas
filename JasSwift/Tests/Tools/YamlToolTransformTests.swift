import Testing
import Foundation
@testable import JasLib

// Combined Rotate + Shear transform-tool gesture-seam tests for the
// YAML tool runtime. Ports the Rust REFERENCE seam tests
// (jas_dioxus/src/tools/yaml_tool.rs, rotate_parity_* / shear_parity_*).
// They exercise the shared transform-tool gesture contract through the
// live YamlTool event seam (onPress / onMove / onRelease / onKeyEvent),
// never poking handlers directly:
//
//   1. click-only (press+release, no move) WRITES the pivot
//      (state.transform_reference_point) and mutates NOTHING in the
//      document — moved stays false so the apply branch never runs.
//   2. a real drag (move past the >2px threshold) APPLIES the
//      transform. Proven by the post-transform SELECTION BBOX dims:
//      a 100x40 rect rotated 90deg about its centre swaps to ~40x100;
//      sheared 45deg horizontally widens to ~140 and pushes min_x to
//      ~-20. canUndo is true after the journaled commit.
//   3. a SUB-THRESHOLD drag (<2px) leaves moved=false → the apply
//      branch never runs → document UNCHANGED, canUndo false.
//   4. Escape MID-DRAG (mode back to idle) makes the following
//      mouseup's `mode == 'rotating'/'shearing'` guard fail, so the
//      transform that case 2 proves WOULD fire is suppressed →
//      document UNCHANGED. Non-vacuous precisely because case 2 shows
//      the identical press+move+release path DOES mutate.
//
// The load-bearing geometry check is the transformed bbox (computed by
// `selectionTransformedBbox`, which DOES apply common.transform —
// Element.geometricBounds reports only LOCAL geometry and would be
// blind to the baked matrix). The transform tools write their matrix
// into common.transform (via compose_matrix_over_paths), leaving the
// rect's local x/y/w/h untouched. The spec lives in workspace/*.yaml
// and is byte-identical across the five apps, so the expected bbox
// dims and tolerances are exactly the ones the Rust tests assert.

// MARK: - Loaders

private func rotateTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["rotate"] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

private func shearTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["shear"] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

// MARK: - Fixtures

/// One-layer document with a single stroked NON-SQUARE 100x40 rect at
/// doc (0,0), selected via element path [0,0]. Mirrors Rust
/// `transform_nonsquare_model`. The aspect ratio is the whole point: a
/// 90deg rotation about the centre SWAPS the bbox dims (100x40 →
/// 40x100), a swap a square could never show.
private func transformNonsquareModel() -> Model {
    let rect = Element.rect(Rect(
        x: 0, y: 0, width: 100, height: 40,
        fill: Fill(color: .black),
        stroke: Stroke(color: .black, width: 1.0)
    ))
    let layer = Layer(name: "L", children: [rect])
    return Model(document: Document(
        layers: [layer],
        selectedLayer: 0,
        selection: [ElementSelection.all([0, 0])]
    ))
}

// Shared ToolContext: no hit-test closures (the YAML tool reads the
// registered document directly), mirroring YamlToolSelectionVariantsTests.
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

// MARK: - Helpers (ported 1:1 from the Rust reference)

/// Axis-aligned bounding box of the element at `path`, in DOCUMENT
/// space, WITH its `common.transform` applied. Returns
/// `(minX, minY, width, height)`.
///
/// This is the load-bearing helper: the transform tools bake their
/// matrix into `common.transform`, leaving the rect's LOCAL x/y/w/h
/// untouched — so the element's local bounds alone are blind to a
/// rotate/shear. We take the element's LOCAL geometric bounds, map its
/// four corners through the transform, and re-derive the axis-aligned
/// box. With identity transform this is a no-op, so it also validates
/// the click-only / sub-threshold / escape cases honestly (their bbox
/// stays 100x40).
///
/// `geometricBounds` (not `bounds`) so the 1px stroke inflation does
/// not bleed into the dims — the fixture's stroke is there only to
/// match the scale fixture, not to be measured.
private func selectionTransformedBbox(
    _ model: Model, _ path: [Int]
) -> (minX: Double, minY: Double, width: Double, height: Double) {
    let elem = model.document.getElement(path)
    let (lx, ly, lw, lh) = elem.geometricBounds  // LOCAL geometry, no stroke
    let t = elem.transform ?? .identity
    let corners = [
        (lx, ly), (lx + lw, ly), (lx + lw, ly + lh), (lx, ly + lh),
    ]
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    for (cx, cy) in corners {
        let (tx, ty) = t.applyPoint(cx, cy)
        minX = min(minX, tx); minY = min(minY, ty)
        maxX = max(maxX, tx); maxY = max(maxY, ty)
    }
    return (minX, minY, maxX - minX, maxY - minY)
}

/// Canonical document JSON for the "unchanged?" comparison — the same
/// canonicalization the cross-language byte-gate uses. Mirrors Rust
/// `doc_json`.
private func docJson(_ model: Model) -> String {
    documentToTestJson(model.document)
}

/// Read `state.transform_reference_point` back out of the tool's own
/// store as `(rx, ry)`, or `nil` if unset / malformed. The stored list
/// elements may be Double- or Int-typed depending on the evaluator's
/// whole-number folding, so we coerce numerically. Mirrors Rust
/// `read_ref_point`.
private func readRefPoint(_ tool: YamlTool) -> (Double, Double)? {
    guard let arr = tool.globalState("transform_reference_point") as? [Any],
          arr.count >= 2,
          let rx = asDouble(arr[0]),
          let ry = asDouble(arr[1]) else {
        return nil
    }
    return (rx, ry)
}

private func asDouble(_ v: Any) -> Double? {
    switch v {
    case let d as Double: return d
    case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue
    default: return nil
    }
}

// ── Rotate ─────────────────────────────────────────────────────────

@Test func rotateParityClickOnlySetsRefAndDoesNotTransform() throws {
    let tool = try #require(rotateTool())
    let model = transformNonsquareModel()
    let ctx = makeCtx(model: model)
    let before = docJson(model)

    // Plain click at doc (10, 20): press+release at the SAME point, no
    // move → moved stays false → the apply branch never runs, the else
    // branch writes transform_reference_point.
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)

    // Pivot stored in the tool's global state (handler-written),
    // readable as state.transform_reference_point. Compare numerically.
    let rp = readRefPoint(tool)
    #expect(rp != nil)
    if let (rx, ry) = rp {
        #expect(abs(rx - 10.0) < 1e-9)
        #expect(abs(ry - 20.0) < 1e-9)
    }

    // Document byte-identical and nothing undoable.
    #expect(docJson(model) == before)
    #expect(!model.canUndo)
    let bbox = selectionTransformedBbox(model, [0, 0])
    #expect(abs(bbox.width - 100.0) < 0.5)
    #expect(abs(bbox.height - 40.0) < 0.5)
}

@Test func rotateParityDragApplies90degAndSwapsBbox() throws {
    let tool = try #require(rotateTool())
    let model = transformNonsquareModel()
    let ctx = makeCtx(model: model)

    // Seed the pivot at the selection CENTRE (50, 20) via a click-only
    // gesture (the production path that writes it).
    tool.onPress(ctx, x: 50, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 20, shift: false, alt: false)
    #expect(!model.canUndo)

    // Rotate drag for theta = +90deg about (50, 20):
    //   press  doc (150, 20) → atan2(0, 100)  = 0deg
    //   cursor doc (50, 120) → atan2(100, 0)  = 90deg
    //   theta = 90 - 0 = 90deg. Move is >2px → moved = true.
    tool.onPress(ctx, x: 150, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 50, y: 120, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 50, y: 120, shift: false, alt: false)

    // A 90deg rotation about the centre SWAPS the bbox dims.
    let bbox = selectionTransformedBbox(model, [0, 0])
    #expect(abs(bbox.width - 40.0) < 0.5)
    #expect(abs(bbox.height - 100.0) < 0.5)
    #expect(model.canUndo)
}

@Test func rotateParitySubthresholdDragDoesNotTransform() throws {
    let tool = try #require(rotateTool())
    let model = transformNonsquareModel()
    let ctx = makeCtx(model: model)
    // Pre-seed a pivot so the only variable is the drag distance.
    tool.onPress(ctx, x: 50, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 20, shift: false, alt: false)
    let before = docJson(model)

    // Press, then a 1px move (<2px on both axes → moved stays false),
    // then release. The apply branch must not run.
    tool.onPress(ctx, x: 150, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 151, y: 21, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 151, y: 21, shift: false, alt: false)

    #expect(docJson(model) == before)
    #expect(!model.canUndo)
    let bbox = selectionTransformedBbox(model, [0, 0])
    #expect(abs(bbox.width - 100.0) < 0.5)
    #expect(abs(bbox.height - 40.0) < 0.5)
}

@Test func rotateParityEscapeMidDragSuppressesApply() throws {
    let tool = try #require(rotateTool())
    let model = transformNonsquareModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 50, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 20, shift: false, alt: false)
    let before = docJson(model)

    // Begin the SAME 90deg drag proven to mutate in the apply case, but
    // press Escape BEFORE releasing. Escape sets mode back to idle, so
    // the subsequent mouseup's `mode == 'rotating'` guard fails and the
    // apply is suppressed.
    tool.onPress(ctx, x: 150, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 50, y: 120, shift: false, alt: false, dragging: true)
    _ = tool.onKeyEvent(ctx, "Escape", KeyMods())
    tool.onRelease(ctx, x: 50, y: 120, shift: false, alt: false)

    #expect(docJson(model) == before)
    #expect(!model.canUndo)
    let bbox = selectionTransformedBbox(model, [0, 0])
    #expect(abs(bbox.width - 100.0) < 0.5)
    #expect(abs(bbox.height - 40.0) < 0.5)
}

// ── Shear ──────────────────────────────────────────────────────────

@Test func shearParityClickOnlySetsRefAndDoesNotTransform() throws {
    let tool = try #require(shearTool())
    let model = transformNonsquareModel()
    let ctx = makeCtx(model: model)
    let before = docJson(model)

    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)

    let rp = readRefPoint(tool)
    #expect(rp != nil)
    if let (rx, ry) = rp {
        #expect(abs(rx - 10.0) < 1e-9)
        #expect(abs(ry - 20.0) < 1e-9)
    }

    #expect(docJson(model) == before)
    #expect(!model.canUndo)
    let bbox = selectionTransformedBbox(model, [0, 0])
    #expect(abs(bbox.width - 100.0) < 0.5)
    #expect(abs(bbox.height - 40.0) < 0.5)
}

@Test func shearParityDragAppliesHorizontalShearAndWidensBbox() throws {
    let tool = try #require(shearTool())
    let model = transformNonsquareModel()
    let ctx = makeCtx(model: model)

    // Seed the pivot at the selection CENTRE (50, 20).
    tool.onPress(ctx, x: 50, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 20, shift: false, alt: false)
    #expect(!model.canUndo)

    // Shift-constrained HORIZONTAL shear, k = 1 (angle = 45deg):
    //   press  doc (50, 60) → |press_y - ref_y| = 40
    //   cursor doc (90, 60) → dx = 40 (dominant-x), dy = 0
    //   k = dx / 40 = 1.0  →  angle = atan(1) = 45deg.
    // Shift is the FIRST bool arg to the seam methods.
    tool.onPress(ctx, x: 50, y: 60, shift: true, alt: false)
    tool.onMove(ctx, x: 90, y: 60, shift: true, alt: false, dragging: true)
    tool.onRelease(ctx, x: 90, y: 60, shift: true, alt: false)

    // Horizontal shear widens the bbox (100 + k*height = 140), keeps
    // the height (40), and shifts the box LEFT (min_x = -20: the top
    // edge slides left, the bottom edge slides right).
    let bbox = selectionTransformedBbox(model, [0, 0])
    #expect(abs(bbox.width - 140.0) < 0.5)
    #expect(abs(bbox.height - 40.0) < 0.5)
    #expect(abs(bbox.minX - (-20.0)) < 0.5)
    #expect(model.canUndo)
}

@Test func shearParitySubthresholdDragDoesNotTransform() throws {
    let tool = try #require(shearTool())
    let model = transformNonsquareModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 50, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 20, shift: false, alt: false)
    let before = docJson(model)

    // 1px move on both axes (<2px → moved stays false).
    tool.onPress(ctx, x: 50, y: 60, shift: true, alt: false)
    tool.onMove(ctx, x: 51, y: 61, shift: true, alt: false, dragging: true)
    tool.onRelease(ctx, x: 51, y: 61, shift: true, alt: false)

    #expect(docJson(model) == before)
    #expect(!model.canUndo)
    let bbox = selectionTransformedBbox(model, [0, 0])
    #expect(abs(bbox.width - 100.0) < 0.5)
    #expect(abs(bbox.height - 40.0) < 0.5)
}

@Test func shearParityEscapeMidDragSuppressesApply() throws {
    let tool = try #require(shearTool())
    let model = transformNonsquareModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 50, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 20, shift: false, alt: false)
    let before = docJson(model)

    // The SAME k=1 shear drag that case 2 proves mutates, but Escape
    // before release suppresses the apply.
    tool.onPress(ctx, x: 50, y: 60, shift: true, alt: false)
    tool.onMove(ctx, x: 90, y: 60, shift: true, alt: false, dragging: true)
    _ = tool.onKeyEvent(ctx, "Escape", KeyMods())
    tool.onRelease(ctx, x: 90, y: 60, shift: true, alt: false)

    #expect(docJson(model) == before)
    #expect(!model.canUndo)
    let bbox = selectionTransformedBbox(model, [0, 0])
    #expect(abs(bbox.width - 100.0) < 0.5)
    #expect(abs(bbox.height - 40.0) < 0.5)
}
