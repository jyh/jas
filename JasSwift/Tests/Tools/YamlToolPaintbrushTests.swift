import Testing
import Foundation
@testable import JasLib

// Paintbrush tool gesture-seam tests — Swift port of the Rust paintbrush
// seam tests in jas_dioxus/src/tools/yaml_tool.rs (the
// paintbrush_parity_* family + paintbrush_yaml_tool() loader,
// seed_paintbrush_app_state, and paintbrush_stroke helpers).
//
// These drive the PRODUCTION paintbrush tool loaded from the workspace
// bundle through onPress / onMove / onRelease / onKeyEvent and assert the
// committed Path — complementing the effect-level unit tests (which seed a
// PRE-BUILT buffer and call the commit effect directly). The seam tests
// exercise the FULL gesture pipeline AND the app-state bridge: fidelity ->
// fit_error (smoothing) and fill_new_strokes -> fill both arrive ONLY via
// the bridge (paintbrush_*). Before those keys were in the bridge allowlist
// the live paintbrush committed with fit_error=0 (no smoothing) and dropped
// the fill — the same residual disconnect Fix A addressed for the blob
// brush. See PAINTBRUSH_TOOL.md and PAINTBRUSH_TOOL_TESTS.md.
//
// Seam mapping from Rust to Swift:
//   on_press        -> onPress(ctx, x:, y:, shift:, alt:)
//   on_move(drag)   -> onMove(ctx, x:, y:, shift:, alt:, dragging:)
//   on_release      -> onRelease(ctx, x:, y:, shift:, alt:)
//   on_key_event    -> onKeyEvent(ctx, "Escape", KeyMods())  (the same
//                      non-capturing-tool shell entry the pencil/blob Esc
//                      test uses)
//   tool.sync_global_state -> stage app-level state on the MODEL
//                      (defaultFill + model.stateStore) and route it through
//                      the PRODUCTION bridge tool.syncAppState(model) — the
//                      same seam the canvas runs on every dispatch — instead
//                      of poking the tool store directly.
//
// The committed element is a Path; the Path-case payload (`pe`) is the Path
// struct, with pe.d : [PathCommand], pe.fill : Fill?, pe.stroke : Stroke?.

private func paintbrushTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["paintbrush"] as? [String: Any] else {
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

/// Stage the app-level state the paintbrush commit reads, through the
/// PRODUCTION bridge. `fill_color=#ff0000` proves the bridge delivers the
/// live document fill to the commit (gated by fill_new_strokes);
/// `paintbrush_fidelity=3` -> fit_error 5.0 (a SMOOTHED fit), not the
/// degenerate fit_error=0 over-fit a null fidelity would produce. The values
/// are set on the MODEL (defaultFill where the Color panel writes it, and
/// model.stateStore where the paintbrush options dialog writes the
/// paintbrush_*), then routed through `tool.syncAppState(model)` — the same
/// path the canvas runs at the top of every dispatch — rather than poking
/// the tool store directly. Mirrors the Rust seed_paintbrush_app_state
/// (which routes through sync_global_state).
private func seedPaintbrushAppState(_ tool: YamlTool, _ model: Model, fillNew: Bool) {
    model.defaultFill = Fill(color: Color.fromHex("#ff0000")!)
    model.stateStore.set("paintbrush_fidelity", 3.0)
    model.stateStore.set("paintbrush_fill_new_strokes", fillNew)
    model.stateStore.set("paintbrush_edit_within", 12.0)
    model.stateStore.set("paintbrush_edit_selected_paths", true)
    model.stateStore.set("paintbrush_keep_selected", true)
    tool.syncAppState(model)
}

/// Drive a multi-point paintbrush zigzag: press -> 3 drag moves -> release.
/// Mirrors the Rust paintbrush_stroke helper.
private func paintbrushStroke(_ tool: YamlTool, _ ctx: ToolContext) {
    tool.onPress(ctx, x: 40, y: 60, shift: false, alt: false)
    tool.onMove(ctx, x: 60, y: 40, shift: false, alt: false, dragging: true)
    tool.onMove(ctx, x: 80, y: 60, shift: false, alt: false, dragging: true)
    tool.onMove(ctx, x: 100, y: 40, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 120, y: 60, shift: false, alt: false)
}

// MARK: - Loader sanity

@Test func paintbrushToolLoadsFromWorkspace() throws {
    let tool = try #require(paintbrushTool())
    #expect(tool.spec.id == "paintbrush")
}

// MARK: - paint_commits_smoothed_stroke

@Test func paintbrushParityPaintCommitsSmoothedStroke() throws {
    // A paint gesture commits exactly one Path with a stroke set. fidelity=3
    // -> fit_error 5.0 (via the bridge): a SMOOTHED fit (MoveTo + CurveTos),
    // not the degenerate fit_error=0 over-fit a null fidelity would produce.
    let tool = try #require(paintbrushTool())
    let model = emptyLayerModel()
    seedPaintbrushAppState(tool, model, fillNew: false)
    let ctx = makeCtx(model: model)
    paintbrushStroke(tool, ctx)

    let children = model.document.layers[0].children
    #expect(children.count == 1, "paint commits one Path")
    guard case .path(let pe) = children[0] else {
        Issue.record("expected Path, got \(children[0])")
        return
    }
    #expect(pe.stroke != nil, "paintbrush path has a stroke")
    // Smoothed: first command is MoveTo, the rest are CurveTo.
    guard case .moveTo = pe.d[0] else {
        Issue.record("expected first command MoveTo, got \(pe.d[0])")
        return
    }
    #expect(pe.d.count >= 2, "smoothed: MoveTo + at least one CurveTo")
    #expect(pe.d[1...].allSatisfy {
        if case .curveTo = $0 { return true } else { return false }
    }, "smoothed: MoveTo + CurveTo(s)")
}

// MARK: - fill_new_strokes_fills_via_bridge

@Test func paintbrushParityFillNewStrokesFillsViaBridge() throws {
    // The fill (red) reaches the commit ONLY through the app-state bridge
    // (fill_color), gated by fill_new_strokes=true. Before the bridge the
    // live tool dropped it (fill_new_strokes -> null -> false). This is the
    // paintbrush analogue of the blob fill bug.
    let tool = try #require(paintbrushTool())
    let model = emptyLayerModel()
    seedPaintbrushAppState(tool, model, fillNew: true)
    let ctx = makeCtx(model: model)
    paintbrushStroke(tool, ctx)

    guard case .path(let pe) = model.document.layers[0].children[0] else {
        Issue.record("expected Path")
        return
    }
    #expect(pe.fill != nil, "fill_new_strokes=true fills the path")
}

// MARK: - no_fill_when_option_off

@Test func paintbrushParityNoFillWhenOptionOff() throws {
    // fill_new_strokes=false (default) -> open freehand stroke, no fill.
    let tool = try #require(paintbrushTool())
    let model = emptyLayerModel()
    seedPaintbrushAppState(tool, model, fillNew: false)
    let ctx = makeCtx(model: model)
    paintbrushStroke(tool, ctx)

    guard case .path(let pe) = model.document.layers[0].children[0] else {
        Issue.record("expected Path")
        return
    }
    #expect(pe.fill == nil, "no fill when fill_new_strokes is off")
}

// MARK: - undo_redo_round_trips

@Test func paintbrushParityUndoRedoRoundTrips() throws {
    // on_mousedown's doc.snapshot checkpoints the empty doc; undo restores
    // zero children, redo restores the stroke.
    let tool = try #require(paintbrushTool())
    let model = emptyLayerModel()
    seedPaintbrushAppState(tool, model, fillNew: false)
    let ctx = makeCtx(model: model)
    paintbrushStroke(tool, ctx)
    #expect(model.document.layers[0].children.count == 1)

    model.undo()
    #expect(model.document.layers[0].children.isEmpty,
            "undo removes the stroke")

    model.redo()
    #expect(model.document.layers[0].children.count == 1,
            "redo restores it")
}

// MARK: - escape_during_drag_cancels

@Test func paintbrushParityEscapeDuringDragCancels() throws {
    // Esc mid-drag flips mode to idle (on_keydown), so the on_mouseup
    // drawing-commit branch (guarded by mode == 'drawing') is skipped.
    // Escape arrives via onKeyEvent, the non-capturing-tool shell entry
    // (the same path the pencil/blob Esc test uses).
    let tool = try #require(paintbrushTool())
    let model = emptyLayerModel()
    seedPaintbrushAppState(tool, model, fillNew: false)
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 40, y: 60, shift: false, alt: false)
    tool.onMove(ctx, x: 60, y: 40, shift: false, alt: false, dragging: true)
    _ = tool.onKeyEvent(ctx, "Escape", KeyMods())
    tool.onRelease(ctx, x: 80, y: 60, shift: false, alt: false)

    #expect(model.document.layers[0].children.isEmpty,
            "Esc during drag cancels — no stroke committed")
}
