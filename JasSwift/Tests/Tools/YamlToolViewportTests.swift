import Testing
import Foundation
@testable import JasLib

// Combined Zoom + Hand VIEWPORT gesture-seam tests for the YAML tool
// runtime. Ports the Rust REFERENCE seam tests
// (jas_dioxus/src/tools/yaml_tool.rs, zoom_parity_* / hand_parity_*).
// They exercise the shared viewport-tool gesture contract through the
// live YamlTool event seam (onPress / onMove / onRelease / onKeyEvent),
// never poking handlers directly.
//
// These are VIEWPORT tools — unlike the drawing / transform tools they
// change VIEW STATE (Model.zoomLevel, viewOffsetX, viewOffsetY), NOT the
// document. So the load-bearing assertions are the exact post-gesture
// zoom_level / view_offset numbers, and the invariant the no-op / Escape
// cases prove is that the document stays byte-identical and nothing is
// journaled (canUndo == false).
//
// Key mechanics (mirrored 1:1 from Rust):
//   * The tools read SCREEN coords (event.x / event.y, not doc coords).
//     We drive onPress / onMove / onRelease with screen x/y. At the
//     default identity view (zoom 1, offset 0) screen == doc.
//   * zoom_step (1.2) is READ from the bundle
//     (preferences.viewport.zoom_step) at dispatch time, so driving the
//     production tool gives the real factor — asserted, never guessed.
//   * HAND: a drag press(s1)->cursor(s2) sets
//     view_offset = initial_offset + (cursor - press) (same sign);
//     Escape mid-pan restores the initial offset; mode idle->panning->idle.
//   * ZOOM: a plain CLICK (no drag) zooms IN to initial*1.2 and recenters
//     so the clicked screen point stays glued (off = sx*(1 - z_new) at
//     identity view); an ALT-click zooms OUT to initial*(1/1.2) == 0.8333;
//     a sub-4px drag is treated as a click; Escape mid-scrubby-drag
//     restores the pre-drag view.
//
// View changes are NOT journaled, so every case asserts document
// byte-identity (documentToTestJson) and canUndo == false on the
// no-op / Escape paths. These tools read no app-level state.* (no bridge
// seeding needed).

// MARK: - Loaders

private func zoomTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["zoom"] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

private func handTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["hand"] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

/// Read `preferences.viewport.zoom_step` out of the embedded bundle so
/// the tests assert against the REAL production factor rather than a
/// hardcoded guess. Returns nil if the bundle is missing the key (the
/// tests are meaningless without it). Mirrors Rust `bundle_zoom_step`.
private func bundleZoomStep() -> Double? {
    guard let ws = WorkspaceData.load(),
          let prefs = ws.data["preferences"] as? [String: Any],
          let viewport = prefs["viewport"] as? [String: Any],
          let step = viewport["zoom_step"] as? NSNumber else {
        return nil
    }
    return step.doubleValue
}

// MARK: - Fixtures

/// Minimal one-layer document for the VIEWPORT tools. They ignore
/// document content entirely (they touch only view state), so an empty
/// layer is enough; the fresh model starts at the identity view (zoom
/// 1.0, offset 0,0). Mirrors Rust `viewport_model`.
private func viewportModel() -> Model {
    let layer = Layer(name: "L", children: [])
    return Model(document: Document(layers: [layer], selectedLayer: 0))
}

// Shared ToolContext: no hit-test closures (the YAML tool reads the
// registered document directly), mirroring YamlToolTransformTests.
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

// MARK: - Helpers

/// Canonical document JSON for the "unchanged?" comparison — the same
/// canonicalization the cross-language byte-gate uses. Mirrors Rust
/// `doc_json`.
private func docJson(_ model: Model) -> String {
    documentToTestJson(model.document)
}

/// Read `tool.<id>.mode` out of the tool's own store via the public
/// `toolState` accessor (reads `store.getTool(spec.id, key)`). Mirrors
/// Rust's inline `read_mode` closure in hand_parity_mode_idle_panning_idle.
private func readToolMode(_ tool: YamlTool) -> String {
    tool.toolState("mode") as? String ?? ""
}

// ── Hand ─────────────────────────────────────────────────────────────

@Test func handParityDragPansViewOffsetByScreenDelta() throws {
    let tool = try #require(handTool())
    let model = viewportModel()
    let ctx = makeCtx(model: model)
    // Start from a NON-zero baseline offset so the test proves the pan is
    // `initial + delta`, not just `delta`.
    model.viewOffsetX = 30.0
    model.viewOffsetY = -10.0
    let beforeDoc = docJson(model)
    let zBefore = model.zoomLevel

    // Press at screen (100,100); drag to (160,135).
    //   delta = (160-100, 135-100) = (+60, +35)
    // doc.pan.apply: off = initial + delta (SAME sign), so
    //   off_x = 30 + 60 = 90
    //   off_y = -10 + 35 = 25
    tool.onPress(ctx, x: 100, y: 100, shift: false, alt: false)
    tool.onMove(ctx, x: 160, y: 135, shift: false, alt: false, dragging: true)

    #expect(abs(model.viewOffsetX - 90.0) < 1e-9)
    #expect(abs(model.viewOffsetY - 25.0) < 1e-9)
    // The pan must touch ONLY the offset — zoom and document stay put.
    #expect(abs(model.zoomLevel - zBefore) < 1e-9)
    #expect(docJson(model) == beforeDoc)
    #expect(!model.canUndo)

    // Idempotency: a SECOND move to the same cursor recomputes from
    // press+initial, so the offset is identical (not doubled).
    tool.onMove(ctx, x: 160, y: 135, shift: false, alt: false, dragging: true)
    #expect(abs(model.viewOffsetX - 90.0) < 1e-9)
    #expect(abs(model.viewOffsetY - 25.0) < 1e-9)
}

@Test func handParityEscapeMidPanRestoresInitialOffset() throws {
    let tool = try #require(handTool())
    let model = viewportModel()
    let ctx = makeCtx(model: model)
    model.viewOffsetX = 30.0
    model.viewOffsetY = -10.0
    let offX0 = model.viewOffsetX
    let offY0 = model.viewOffsetY
    let beforeDoc = docJson(model)

    // Begin the SAME pan proven to move the view in the drag case, but
    // press Escape BEFORE the next event. Escape's on_keydown restores
    // the pre-drag offset (initial_offx/offy) via doc.zoom.set_full and
    // sets mode back to idle.
    tool.onPress(ctx, x: 100, y: 100, shift: false, alt: false)
    tool.onMove(ctx, x: 160, y: 135, shift: false, alt: false, dragging: true)
    // Mid-pan the view IS shifted (90, 25) — same as the drag case.
    #expect(abs(model.viewOffsetX - 90.0) < 1e-9)
    #expect(abs(model.viewOffsetY - 25.0) < 1e-9)

    _ = tool.onKeyEvent(ctx, "Escape", KeyMods())

    #expect(abs(model.viewOffsetX - offX0) < 1e-9)
    #expect(abs(model.viewOffsetY - offY0) < 1e-9)

    // A subsequent mousemove must NOT re-pan: Escape set mode=idle, so
    // the on_mousemove `mode == 'panning'` guard now fails.
    tool.onMove(ctx, x: 300, y: 300, shift: false, alt: false, dragging: true)
    #expect(abs(model.viewOffsetX - offX0) < 1e-9)
    #expect(abs(model.viewOffsetY - offY0) < 1e-9)
    #expect(docJson(model) == beforeDoc)
    #expect(!model.canUndo)
}

@Test func handParityModeIdlePanningIdleLifecycle() throws {
    let tool = try #require(handTool())
    let model = viewportModel()
    let ctx = makeCtx(model: model)

    // on_enter resets to idle.
    tool.activate(ctx)
    #expect(readToolMode(tool) == "idle")

    // mousedown => panning.
    tool.onPress(ctx, x: 100, y: 100, shift: false, alt: false)
    #expect(readToolMode(tool) == "panning")

    // mouseup => idle.
    tool.onRelease(ctx, x: 160, y: 135, shift: false, alt: false)
    #expect(readToolMode(tool) == "idle")
}

// ── Zoom ─────────────────────────────────────────────────────────────

@Test func zoomParityPlainClickZoomsInByZoomStep() throws {
    let tool = try #require(zoomTool())
    let model = viewportModel()
    let ctx = makeCtx(model: model)
    let beforeDoc = docJson(model)
    let step = try #require(bundleZoomStep())
    // Sanity: the bundle ships the documented 1.2 step.
    #expect(abs(step - 1.2) < 1e-9)

    // Plain CLICK: press + release at the SAME screen point, no
    // intervening move => moved stays false => the not-moved branch
    // dispatches zoom_in anchored at the click.
    //   z_new   = 1.0 * 1.2 = 1.2
    //   anchor  = (200, 150) (screen)
    //   doc_a   = (200-0)/1, (150-0)/1 = (200, 150)
    //   off_new = anchor - doc_a*z_new = 200 - 200*1.2 = -40
    //                                    150 - 150*1.2 = -30
    tool.onPress(ctx, x: 200, y: 150, shift: false, alt: false)
    tool.onRelease(ctx, x: 200, y: 150, shift: false, alt: false)

    let expectedZoom = 1.0 * step  // 1.2
    #expect(abs(model.zoomLevel - expectedZoom) < 1e-9)
    #expect(abs(model.viewOffsetX - (-40.0)) < 1e-9)
    #expect(abs(model.viewOffsetY - (-30.0)) < 1e-9)
    // The clicked SCREEN point maps to the SAME doc point before and
    // after the zoom — the invariant the recenter exists to keep.
    let docBefore = (200.0 - 0.0) / 1.0  // = 200
    let docAfter = (200.0 - model.viewOffsetX) / model.zoomLevel
    #expect(abs(docAfter - docBefore) < 1e-9)
    #expect(docJson(model) == beforeDoc)
    #expect(!model.canUndo)
}

@Test func zoomParityAltClickZoomsOut() throws {
    let tool = try #require(zoomTool())
    let model = viewportModel()
    let ctx = makeCtx(model: model)
    let beforeDoc = docJson(model)
    let step = try #require(bundleZoomStep())

    // ALT-click (alt = the LAST bool arg of the seam). alt_at_press
    // latches true on mousedown, so the not-moved branch dispatches
    // zoom_OUT with factor 1/step.
    //   z_new   = 1.0 * (1/1.2) = 0.833333…
    //   anchor  = (200, 150)
    //   off_new = 200 - 200*z_new ; 150 - 150*z_new
    tool.onPress(ctx, x: 200, y: 150, shift: false, alt: true)
    tool.onRelease(ctx, x: 200, y: 150, shift: false, alt: true)

    let expectedZoom = 1.0 / step  // 0.83333…
    #expect(abs(model.zoomLevel - expectedZoom) < 1e-9)
    #expect(model.zoomLevel < 1.0)
    let expectedOffX = 200.0 - 200.0 * expectedZoom
    let expectedOffY = 150.0 - 150.0 * expectedZoom
    #expect(abs(model.viewOffsetX - expectedOffX) < 1e-9)
    #expect(abs(model.viewOffsetY - expectedOffY) < 1e-9)
    // Same screen->doc invariant under zoom-out.
    let docAfter = (200.0 - model.viewOffsetX) / model.zoomLevel
    #expect(abs(docAfter - 200.0) < 1e-9)
    #expect(docJson(model) == beforeDoc)
    #expect(!model.canUndo)
}

@Test func zoomParityEscapeMidScrubbyDragRestoresInitialView() throws {
    let tool = try #require(zoomTool())
    let model = viewportModel()
    let ctx = makeCtx(model: model)
    // Non-identity starting view so the restore target is distinctive.
    model.zoomLevel = 2.0
    model.viewOffsetX = 15.0
    model.viewOffsetY = 25.0
    let z0 = model.zoomLevel
    let offX0 = model.viewOffsetX
    let offY0 = model.viewOffsetY
    let beforeDoc = docJson(model)

    // Scrubby is on by default in the bundle, so a horizontal drag past
    // the 4px threshold applies a continuous scrubby zoom on each move.
    // Press captures the initial snapshot; the move (>4px in x) flips
    // moved=true and writes a NEW zoom/offset.
    tool.onPress(ctx, x: 100, y: 100, shift: false, alt: false)
    tool.onMove(ctx, x: 180, y: 100, shift: false, alt: false, dragging: true)

    // Precondition: the scrubby move actually CHANGED the view (so the
    // Escape restore is non-vacuous).
    #expect(abs(model.zoomLevel - z0) > 1e-6)

    // Escape mid-drag: zoom.yaml restores the pre-drag snapshot
    // (initial_zoom/offx/offy) via doc.zoom.set_full and idles.
    _ = tool.onKeyEvent(ctx, "Escape", KeyMods())

    #expect(abs(model.zoomLevel - z0) < 1e-9)
    #expect(abs(model.viewOffsetX - offX0) < 1e-9)
    #expect(abs(model.viewOffsetY - offY0) < 1e-9)

    // After Escape (mode idle) a further move must NOT re-zoom.
    tool.onMove(ctx, x: 300, y: 100, shift: false, alt: false, dragging: true)
    #expect(abs(model.zoomLevel - z0) < 1e-9)
    #expect(docJson(model) == beforeDoc)
    #expect(!model.canUndo)
}

@Test func zoomParitySubthresholdDragIsAClick() throws {
    // A press + tiny move (<=4px) + release is NOT a drag: moved stays
    // false, so mouseup takes the click branch and zooms IN by zoom_step.
    // Proves the 4px click-vs-drag threshold and that scrubby did NOT
    // fire on the sub-threshold move.
    let tool = try #require(zoomTool())
    let model = viewportModel()
    let ctx = makeCtx(model: model)
    let step = try #require(bundleZoomStep())

    tool.onPress(ctx, x: 200, y: 150, shift: false, alt: false)
    // 3px in x, 0 in y — both within the >4px gate, so moved stays false
    // and no scrubby zoom is written on the move.
    tool.onMove(ctx, x: 203, y: 150, shift: false, alt: false, dragging: true)
    #expect(abs(model.zoomLevel - 1.0) < 1e-9)

    tool.onRelease(ctx, x: 203, y: 150, shift: false, alt: false)
    // Release takes the click branch => zoom IN by step. Anchor is the
    // RELEASE point (203,150): off_x = 203 - 203*1.2.
    #expect(abs(model.zoomLevel - step) < 1e-9)
    let expectedOffX = 203.0 - 203.0 * step
    #expect(abs(model.viewOffsetX - expectedOffX) < 1e-9)
    #expect(!model.canUndo)
}
