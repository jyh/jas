import Testing
import Foundation
@testable import JasLib

// Combined hit-test gesture-seam tests for the YAML tool runtime,
// covering the two single-click hit-testing tools that resolve
// hit_test(event.x, event.y) headlessly in the seam (no hit-test
// closures, just like YamlToolSelectionVariantsTests):
//
//   magic_wand — click a red rect selects both reds (not blue) /
//                click blue selects only blue / shift-click unions /
//                alt-click subtracts / click empty clears / a
//                non-default (Fill Color OFF) config seeded through the
//                production bridge changes the result.
//   eyedropper — click a coloured source with a selected empty target
//                copies the EXACT source fill into the target /
//                plain-click loads the cache then alt-click applies it /
//                click empty is a true document no-op.
//
// Ports the Rust reference seam tests (jas_dioxus/src/tools/yaml_tool.rs:
// magic_wand_parity_* + eyedropper_parity_*) 1:1: the same three-rect
// red/red/blue wand fixture, the same green (0,0.6,0.2) eyedropper
// source + empty target, the same screen coordinates, and the same exact
// selection-path and sampled-rgb assertions.
//
// The Magic Wand config reaches the tool ONLY through the production
// bridge: the nine state.magic_wand_* keys are seeded onto
// model.stateStore and copied into the tool store by syncAppState (which
// runs at the top of every dispatch) — and only because magic_wand_* is
// in bridgedStateKeys (YamlTool.swift). Flip the keys back out of that
// allowlist and the non-default-config gate below fails: that is the
// live-bug regression proof. The Eyedropper toggles all default true and
// EyedropperConfig() agrees, so its fill-copy path needs no seeding.

// MARK: - Loaders

private func magicWandTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["magic_wand"] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

private func eyedropperTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["eyedropper"] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

// MARK: - Fixtures

// Shared ToolContext: no hit-test closures (the YAML tool reads the
// registered document directly and hit-tests it headlessly), mirroring
// YamlSelectionToolTests / YamlToolSelectionVariantsTests.
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

/// Three rects in one layer — red @[0,0], red @[0,1], blue @[0,2] — each
/// 10x10 with an identical 1pt black stroke. Mirrors the Rust
/// `magic_wand_seam_model` (and the effect-level red/red/blue fixture):
/// screen (5,5) hits the first red, screen (45,5) hits the blue.
private func magicWandSeamModel() -> Model {
    let red = Fill(color: Color(r: 1, g: 0, b: 0))
    let blue = Fill(color: Color(r: 0, g: 0, b: 1))
    let stroke = Stroke(color: .black, width: 1.0)
    func make(_ fill: Fill, _ x: Double) -> Element {
        .rect(Rect(x: x, y: 0, width: 10, height: 10,
                   fill: fill, stroke: stroke))
    }
    let layer = Layer(name: "L", children: [
        make(red, 0), make(red, 20), make(blue, 40),
    ])
    return Model(document: Document(
        layers: [layer], selectedLayer: 0, selection: []
    ))
}

/// The exact green the eyedropper fixture source carries. A distinctive
/// non-primary colour so the apply assertion can't accidentally pass
/// against a stray black/red default.
private let eyedropperSourceColor = Color(r: 0, g: 0.6, b: 0.2)

/// Two rects in one layer: source [0,0] green-filled, target [0,1]
/// fill-less. Both 10x10 at the identity view, side by side — screen
/// (5,5) hits the source, screen (25,5) hits the target. Mirrors the Rust
/// `eyedropper_seam_model`.
private func eyedropperSeamModel() -> Model {
    let green = Fill(color: eyedropperSourceColor)
    let stroke = Stroke(color: .black, width: 1.0)
    let source = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                   fill: green, stroke: stroke))
    let target = Element.rect(Rect(x: 20, y: 0, width: 10, height: 10,
                                   fill: nil, stroke: stroke))
    let layer = Layer(name: "L", children: [source, target])
    return Model(document: Document(
        layers: [layer], selectedLayer: 0, selection: []
    ))
}

/// Seed the full default Magic Wand config onto the shared model state
/// store, routed into the tool by syncAppState through the production
/// bridge — the same path the live canvas exercises. Mirrors the Rust
/// `seed_magic_wand_defaults` (which routes through sync_global_state).
private func seedMagicWandDefaults(_ model: Model) {
    model.stateStore.set("magic_wand_fill_color", true)
    model.stateStore.set("magic_wand_fill_tolerance", 32.0)
    model.stateStore.set("magic_wand_stroke_color", true)
    model.stateStore.set("magic_wand_stroke_tolerance", 32.0)
    model.stateStore.set("magic_wand_stroke_weight", true)
    model.stateStore.set("magic_wand_stroke_weight_tolerance", 5.0)
    model.stateStore.set("magic_wand_opacity", true)
    model.stateStore.set("magic_wand_opacity_tolerance", 5.0)
    model.stateStore.set("magic_wand_blending_mode", false)
}

/// Selected element paths as a set, for order-independent assertions.
private func selectionPaths(_ model: Model) -> Set<[Int]> {
    Set(model.document.selection.map { $0.path })
}

// ── magic_wand ─────────────────────────────────────────────────────

@Test func magicWandClickRedSelectsBothRedsNotBlue() throws {
    let tool = try #require(magicWandTool())
    let model = magicWandSeamModel()
    seedMagicWandDefaults(model)
    let ctx = makeCtx(model: model)

    // Plain click on the first red rect at screen (5,5) → replace.
    tool.onPress(ctx, x: 5, y: 5, shift: false, alt: false)
    tool.onRelease(ctx, x: 5, y: 5, shift: false, alt: false)

    let paths = selectionPaths(model)
    #expect(paths.contains([0, 0]))   // seed red
    #expect(paths.contains([0, 1]))   // matching red
    #expect(!paths.contains([0, 2]))  // blue must NOT match
    #expect(paths.count == 2)
}

@Test func magicWandClickBlueSelectsOnlyBlue() throws {
    let tool = try #require(magicWandTool())
    let model = magicWandSeamModel()
    seedMagicWandDefaults(model)
    let ctx = makeCtx(model: model)

    // Plain click on the blue rect at screen (45,5) → replace.
    tool.onPress(ctx, x: 45, y: 5, shift: false, alt: false)
    tool.onRelease(ctx, x: 45, y: 5, shift: false, alt: false)

    #expect(selectionPaths(model) == Set([[0, 2]]))
}

@Test func magicWandShiftClickUnionsAltClickSubtracts() throws {
    let tool = try #require(magicWandTool())
    let model = magicWandSeamModel()
    seedMagicWandDefaults(model)
    let ctx = makeCtx(model: model)

    // Pre-select the blue rect [0,2].
    Controller(model: model).setSelection(Set([ElementSelection.all([0, 2])]))

    // Shift+click red [0,0] → ADD: {2} ∪ {0,1} = {0,1,2}.
    tool.onPress(ctx, x: 5, y: 5, shift: true, alt: false)
    tool.onRelease(ctx, x: 5, y: 5, shift: true, alt: false)
    #expect(selectionPaths(model) == Set([[0, 0], [0, 1], [0, 2]]))

    // Alt+click red [0,0] → SUBTRACT the wand result {0,1}: leaves {2}.
    tool.onPress(ctx, x: 5, y: 5, shift: false, alt: true)
    tool.onRelease(ctx, x: 5, y: 5, shift: false, alt: true)
    #expect(selectionPaths(model) == Set([[0, 2]]))
}

@Test func magicWandClickEmptyClearsSelection() throws {
    let tool = try #require(magicWandTool())
    let model = magicWandSeamModel()
    seedMagicWandDefaults(model)
    let ctx = makeCtx(model: model)

    // Start with a non-empty selection.
    Controller(model: model).setSelection(Set([ElementSelection.all([0, 1])]))
    #expect(!model.document.selection.isEmpty)

    // Plain click on empty canvas (100,100) → selection cleared.
    tool.onPress(ctx, x: 100, y: 100, shift: false, alt: false)
    tool.onRelease(ctx, x: 100, y: 100, shift: false, alt: false)
    #expect(model.document.selection.isEmpty)
}

@Test func magicWandRespectsBridgedNonDefaultConfig() throws {
    // REGRESSION GATE for the live state-bridge fix. With Fill Color
    // turned OFF and only stroke/weight/opacity matching the seed, the
    // blue rect — which has the SAME 1pt black stroke and opacity as the
    // reds — now also matches, so a click on a red selects ALL THREE
    // rects. This non-default config only reaches the tool via
    // syncAppState, and only because magic_wand_* is now in
    // bridgedStateKeys. Remove the keys from the allowlist and the config
    // falls back to the default MagicWandConfig (Fill ON) → the blue
    // stops matching → this assertion fails. That is the bridge proof.
    let tool = try #require(magicWandTool())
    let model = magicWandSeamModel()
    let ctx = makeCtx(model: model)

    model.stateStore.set("magic_wand_fill_color", false)
    model.stateStore.set("magic_wand_fill_tolerance", 32.0)
    model.stateStore.set("magic_wand_stroke_color", true)
    model.stateStore.set("magic_wand_stroke_tolerance", 32.0)
    model.stateStore.set("magic_wand_stroke_weight", true)
    model.stateStore.set("magic_wand_stroke_weight_tolerance", 5.0)
    model.stateStore.set("magic_wand_opacity", true)
    model.stateStore.set("magic_wand_opacity_tolerance", 5.0)
    model.stateStore.set("magic_wand_blending_mode", false)

    // Click red [0,0]. Fill is ignored, stroke+weight+opacity are
    // identical across all three rects → all three match.
    tool.onPress(ctx, x: 5, y: 5, shift: false, alt: false)
    tool.onRelease(ctx, x: 5, y: 5, shift: false, alt: false)

    #expect(selectionPaths(model) == Set([[0, 0], [0, 1], [0, 2]]))
}

// ── eyedropper ─────────────────────────────────────────────────────

@Test func eyedropperClickSourceWithSelectionCopiesFillToTarget() throws {
    let tool = try #require(eyedropperTool())
    let model = eyedropperSeamModel()
    let ctx = makeCtx(model: model)

    // Pre-select the empty target [0,1]; the source [0,0] is clicked.
    Controller(model: model).setSelection(Set([ElementSelection.all([0, 1])]))
    #expect(model.document.getElement([0, 1]).fill == nil)

    // Plain click on the green source at screen (5,5) → sample, which
    // (selection non-empty) also writes the appearance to [0,1].
    tool.onPress(ctx, x: 5, y: 5, shift: false, alt: false)
    tool.onRelease(ctx, x: 5, y: 5, shift: false, alt: false)

    let fill = try #require(model.document.getElement([0, 1]).fill)
    #expect(fill.color == eyedropperSourceColor)
}

@Test func eyedropperAltClickAppliesCachedColorToTarget() throws {
    let tool = try #require(eyedropperTool())
    let model = eyedropperSeamModel()
    let ctx = makeCtx(model: model)

    // First, plain-click the source with NO selection → loads the cache
    // (and mutates nothing, since the selection is empty).
    tool.onPress(ctx, x: 5, y: 5, shift: false, alt: false)
    tool.onRelease(ctx, x: 5, y: 5, shift: false, alt: false)
    #expect(model.document.getElement([0, 1]).fill == nil)

    // Now Alt+click the empty target [0,1] at screen (25,5) →
    // apply_loaded writes the cached green into the target.
    tool.onPress(ctx, x: 25, y: 5, shift: false, alt: true)
    tool.onRelease(ctx, x: 25, y: 5, shift: false, alt: true)

    let fill = try #require(model.document.getElement([0, 1]).fill)
    #expect(fill.color == eyedropperSourceColor)
}

@Test func eyedropperClickEmptyIsANoop() throws {
    let tool = try #require(eyedropperTool())
    let model = eyedropperSeamModel()
    let ctx = makeCtx(model: model)

    // Snapshot the document before the gesture for an exact-equality
    // no-op proof.
    let before = model.document.layers

    // Plain click on empty canvas (100,100) → no hit → no-op.
    tool.onPress(ctx, x: 100, y: 100, shift: false, alt: false)
    tool.onRelease(ctx, x: 100, y: 100, shift: false, alt: false)

    #expect(model.document.layers == before)
    // The source fill is untouched; the target is still fill-less.
    #expect(model.document.getElement([0, 0]).fill?.color == eyedropperSourceColor)
    #expect(model.document.getElement([0, 1]).fill == nil)
}
