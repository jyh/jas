import Testing
import Foundation
@testable import JasLib

// Blob Brush tool gesture-seam tests — Swift port of the Rust blob-brush
// seam tests in jas_dioxus/src/tools/yaml_tool.rs (the
// blob_brush_parity_* family + blob_brush_yaml_tool() loader,
// seed_blob_brush_app_state, blob_brush_sweep, and model_with_square
// helpers).
//
// These drive the PRODUCTION blob_brush tool loaded from the workspace
// bundle through on_press / on_move / on_release / on_key_event and assert
// the committed Path — complementing the effect-level unit tests in
// YamlToolEffectsTests.swift (which call commit_painting / commit_erasing
// directly with a PRE-SEEDED buffer). The seam tests exercise the FULL
// gesture pipeline: mode latching on press (Alt -> erasing), arc-length dab
// accumulation via doc.blob_brush.sweep_sample on each move, and the commit
// on release.
//
// Seam mapping from Rust to Swift:
//   on_press        -> onPress(ctx, x:, y:, shift:, alt:)
//   on_move(drag)   -> onMove(ctx, x:, y:, shift:, alt:, dragging:)
//   on_release      -> onRelease(ctx, x:, y:, shift:, alt:)
//   on_key_event    -> onKeyEvent(ctx, "Escape", KeyMods())  (the same
//                      non-capturing-tool shell entry the pencil Esc test uses)
//   tool.store.set  -> stage app-level state on the MODEL (defaultFill +
//                      model.stateStore) and route it through the PRODUCTION
//                      bridge tool.syncAppState(model) — the same seam the
//                      canvas runs on every dispatch — instead of poking the
//                      tool store directly. (De-seeded to mirror the Rust blob
//                      seam helper, which routes through sync_global_state.)
//
// The committed element is a Path; in Swift the Path-case payload (`pe`) is the
// Path struct, with pe.d : [PathCommand], pe.fill : Fill?, pe.stroke : Stroke?,
// and pe.toolOrigin : String?.

private func blobBrushTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["blob_brush"] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

private func emptyLayerModel() -> Model {
    Model(document: Document(
        layers: [Layer(children: [])],
        selectedLayer: 0, selection: []
    ))
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

/// Stage the app-level `state.blob_brush_*` + `state.fill_color` that the
/// commit reads (tip shape, fill, fidelity, merge filter) onto the MODEL,
/// then route them through the PRODUCTION bridge `tool.syncAppState(model)` —
/// the same path the canvas runs at the top of every dispatch — rather than
/// poking the tool store directly. `fill_color=#ff0000` proves the bridge
/// delivers the live document fill to the commit (the hollow-blob regression
/// guard); the blob_brush_* values pin the tip shape. These app-level values
/// are NOT part of the tool's own state defaults (mode / hover / alt). Mirrors
/// the de-seeded seed_blob_brush_app_state in the Rust reference (which routes
/// through sync_global_state).
private func seedBlobBrushAppState(_ tool: YamlTool, _ model: Model) {
    model.defaultFill = Fill(color: Color.fromHex("#ff0000")!)
    model.stateStore.set("blob_brush_size", 10.0)
    model.stateStore.set("blob_brush_angle", 0.0)
    model.stateStore.set("blob_brush_roundness", 100.0)
    model.stateStore.set("blob_brush_fidelity", 1.0)
    model.stateStore.set("blob_brush_merge_only_with_selection", false)
    model.stateStore.set("blob_brush_keep_selected", false)
    tool.syncAppState(model)
}

/// Drive a left-to-right paint (or erase, when `alt` is true) sweep along
/// y=0 from x0 to x1 with a dab every 10pt — enough arc-length for
/// sweep_sample to push a dab on each move (tip size 10 -> half min-dimension
/// = 5pt threshold). press latches the mode (Alt -> erasing), release commits.
private func blobBrushSweep(
    _ tool: YamlTool, _ ctx: ToolContext,
    _ x0: Double, _ x1: Double, _ alt: Bool
) {
    tool.onPress(ctx, x: x0, y: 0, shift: false, alt: alt)
    var x = x0 + 10.0
    while x < x1 {
        tool.onMove(ctx, x: x, y: 0, shift: false, alt: alt, dragging: true)
        x += 10.0
    }
    tool.onRelease(ctx, x: x1, y: 0, shift: false, alt: alt)
}

/// Single-layer model holding one filled square spanning (x0,y0)-(x1,y1).
/// When `blobOrigin` is true the square carries jas:tool-origin="blob_brush"
/// (an erase target); otherwise it has no tool-origin (an erase bystander).
private func modelWithSquare(
    _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, blobOrigin: Bool
) -> Model {
    let square: Element = .path(Path(
        d: [
            .moveTo(x0, y0),
            .lineTo(x1, y0),
            .lineTo(x1, y1),
            .lineTo(x0, y1),
            .closePath,
        ],
        fill: Fill(color: Color.fromHex("#ff0000")!),
        toolOrigin: blobOrigin ? "blob_brush" : nil))
    return Model(document: Document(
        layers: [Layer(name: "L", children: [square])],
        selectedLayer: 0, selection: []))
}

// MARK: - Loader sanity

@Test func blobBrushToolLoadsFromWorkspace() throws {
    let tool = try #require(blobBrushTool())
    #expect(tool.spec.id == "blob_brush")
}

// MARK: - BB-010/011: paint commits one tagged, fill-only Path

@Test func blobBrushParityPaintCommitsTaggedPath() throws {
    // A paint gesture commits exactly one Path tagged
    // jas:tool-origin="blob_brush", fill-only (no stroke). The tip is swept
    // along the drag and unioned into one closed region.
    let tool = try #require(blobBrushTool())
    let model = emptyLayerModel()
    seedBlobBrushAppState(tool, model)
    let ctx = makeCtx(model: model)
    blobBrushSweep(tool, ctx, 0, 50, false)

    let children = model.document.layers[0].children
    #expect(children.count == 1, "paint commits exactly one Path")
    guard case .path(let pe) = children[0] else {
        Issue.record("expected Path, got \(children[0])")
        return
    }
    #expect(pe.toolOrigin == "blob_brush",
            "committed path carries jas:tool-origin=blob_brush")
    #expect(pe.fill != nil, "blob path is filled")
    #expect(pe.stroke == nil, "blob path has no stroke")
    #expect(pe.d.count >= 3,
            "closed swept region: MoveTo + LineTos + ClosePath")
}

// MARK: - BB-016: undo/redo round-trips the committed blob

@Test func blobBrushParityUndoRedoRoundTrips() throws {
    // on_mousedown's doc.snapshot checkpoints the empty doc; undo restores
    // zero children, redo restores the blob.
    let tool = try #require(blobBrushTool())
    let model = emptyLayerModel()
    seedBlobBrushAppState(tool, model)
    let ctx = makeCtx(model: model)
    blobBrushSweep(tool, ctx, 0, 50, false)
    #expect(model.document.layers[0].children.count == 1)

    model.undo()
    #expect(model.document.layers[0].children.isEmpty,
            "undo removes the blob")

    model.redo()
    #expect(model.document.layers[0].children.count == 1,
            "redo restores the blob")
}

// MARK: - BB-004: Escape mid-drag cancels the paint

@Test func blobBrushParityEscapeDuringDragCancels() throws {
    // Escape mid-drag flips mode to idle (on_keydown), so on_mouseup's
    // painting commit branch (guarded by mode == 'painting') is skipped —
    // nothing lands. Escape arrives via onKeyEvent, the non-capturing-tool
    // shell entry (the same path the pencil Esc test uses).
    let tool = try #require(blobBrushTool())
    let model = emptyLayerModel()
    seedBlobBrushAppState(tool, model)
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    tool.onMove(ctx, x: 20, y: 0, shift: false, alt: false, dragging: true)
    tool.onMove(ctx, x: 40, y: 0, shift: false, alt: false, dragging: true)
    _ = tool.onKeyEvent(ctx, "Escape", KeyMods())
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)

    #expect(model.document.layers[0].children.isEmpty,
            "Esc during drag cancels — no blob committed")
}

// MARK: - BB-100/101: Alt-erase removes a fully-covered blob element

@Test func blobBrushParityAltEraseRemovesCoveredBlob() throws {
    // Alt-at-press latches erasing mode; the swept region boolean-subtracts
    // from overlapping blob-brush elements. A small blob square fully inside
    // the sweep is deleted.
    let tool = try #require(blobBrushTool())
    // Square (23,-1)-(27,1): fully inside a 0..50 sweep, 10pt tip.
    let model = modelWithSquare(23, -1, 27, 1, blobOrigin: true)
    seedBlobBrushAppState(tool, model)
    let ctx = makeCtx(model: model)
    #expect(model.document.layers[0].children.count == 1)

    blobBrushSweep(tool, ctx, 0, 50, true) // alt = erase
    #expect(model.document.layers[0].children.isEmpty,
            "Alt-erase deletes a fully-covered blob-brush element")
}

// MARK: - BB-104: Alt-erase leaves a non-blob bystander untouched

@Test func blobBrushParityAltEraseLeavesNonBlob() throws {
    // Erase only subtracts from elements tagged
    // jas:tool-origin="blob_brush". A bystander square without that tag is
    // left untouched even when fully under the sweep.
    let tool = try #require(blobBrushTool())
    let model = modelWithSquare(23, -1, 27, 1, blobOrigin: false) // no origin
    seedBlobBrushAppState(tool, model)
    let ctx = makeCtx(model: model)

    blobBrushSweep(tool, ctx, 0, 50, true) // alt = erase
    let children = model.document.layers[0].children
    #expect(children.count == 1,
            "erase must not touch non-blob-brush elements")
    guard case .path(let pe) = children[0] else {
        Issue.record("expected the untouched Path, got \(children[0])")
        return
    }
    #expect(pe.toolOrigin == nil)
}

// MARK: - BB-070: overlapping same-fill paints merge into one Path

@Test func blobBrushParityOverlappingSameFillMerges() throws {
    // A second paint overlapping an existing blob-brush element of the same
    // fill is unioned into it — the layer still holds exactly one Path, not
    // two.
    let tool = try #require(blobBrushTool())
    let model = emptyLayerModel()
    seedBlobBrushAppState(tool, model)
    let ctx = makeCtx(model: model)
    blobBrushSweep(tool, ctx, 0, 50, false)
    #expect(model.document.layers[0].children.count == 1)

    // Second stroke (25..75) overlaps the first (0..50).
    blobBrushSweep(tool, ctx, 25, 75, false)
    #expect(model.document.layers[0].children.count == 1,
            "overlapping same-fill paint merges into one Path")
}
