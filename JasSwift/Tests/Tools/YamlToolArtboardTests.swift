import Testing
import Foundation
@testable import JasLib

// Artboard gesture-seam tests for the YAML tool runtime. Ports the
// Rust reference seam tests (jas_dioxus/src/tools/yaml_tool.rs,
// artboard_parity_*) 1:1.
//
// The Artboard tool is a self-contained state machine: it reads NO
// app-level state.* (no bridge seeding required, unlike the Magic
// Wand). It operates in SCREEN coords (event.x / event.y). With the
// default identity view (zoom 1, offset 0) screen == doc, so a press
// at screen (100,100) lands at doc (100,100). probe_hit hit-tests
// against the document's artboards, which the YamlTool seam registers
// headlessly on every dispatch (registerDocument). on_mousedown
// latches the hit (empty → create; interior → move-pending;
// alt+interior → duplicate-pending); on_mousemove past the 4 px
// threshold promotes the *_pending mode, snapshots, captures the
// preview baseline, and applies the in-flight effect; on_mouseup
// commits.
//
// These tests DRIVE the tool through the CanvasTool press/move/
// release seam (NOT the effects directly) and assert against the
// document ARTBOARD LIST: model.document.artboards (each Artboard has
// id, name, x, y, width, height — the fields asserted here are
// x / y / width / height and the list length). Expected rects and
// counts are byte-identical to the Rust reference numbers.
//
// RESIZE COVERAGE NOTE: the resize gesture is NOT covered through the
// press-on-handle seam. probe_hit's resize-handle branch only fires
// when active_document.artboards_panel_selection_ids holds exactly
// one id, and the headless CanvasTool dispatch path never carries an
// active_document panel-selection namespace. So a real press on a
// corner cannot transition the machine to resizing here. The resize
// MATH is pinned directly by a separate effect test. Reported, not
// faked — same skip Rust takes.

// MARK: - Loader

/// Load the real Artboard tool from the embedded workspace bundle,
/// the same path the running app uses. Mirrors Rust
/// `artboard_yaml_tool`.
private func artboardTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["artboard"] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

// MARK: - Fixture

/// A document with exactly ONE artboard "A" at (0,0) 200x200 and no
/// document elements. The Document init seeds a default artboard when
/// passed an empty list, so we pass our own explicit single artboard
/// to keep the geometry crisp and the count assertions unambiguous.
/// Identity view → screen coords == doc coords. Mirrors Rust
/// `model_with_one_artboard`.
private func modelWithOneArtboard() -> Model {
    let a = Artboard(
        id: "A", name: "Artboard A",
        x: 0, y: 0, width: 200, height: 200
    )
    let layer = Layer(name: "Layer", children: [])
    // `Model.init` builds an IDENTITY-view model (screen == doc), matching the
    // cross-app convention and Rust's `model_with_one_artboard` — view
    // centering on document-open happens at the canvas/app layer, not in the
    // Model. So no view reset is needed here; the Artboard tool's gesture math
    // is driven in identity-view doc space, exactly like the Rust reference.
    return Model(document: Document(
        layers: [layer], selectedLayer: 0, selection: [],
        artboards: [a]
    ))
}

/// The single artboard's (x, y, w, h) — id "A". Returns nil if absent
/// so a vanished artboard fails an assertion loudly instead of
/// silently skipping. Mirrors Rust `artboard_a_rect`.
private func artboardARect(_ model: Model) -> (Double, Double, Double, Double)? {
    guard let a = model.document.artboards.first(where: { $0.id == "A" }) else {
        return nil
    }
    return (a.x, a.y, a.width, a.height)
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

// MARK: - CREATE

@Test func artboardParityDragEmptySpaceCreatesArtboard() throws {
    let tool = try #require(artboardTool())
    let model = modelWithOneArtboard()
    let ctx = makeCtx(model: model)
    tool.activate(ctx)
    #expect(model.document.artboards.count == 1) // precondition: one artboard

    // Press in EMPTY space at screen (300,300) — well clear of the
    // 0..200 artboard — then drag to (450,420) (past the 4 px
    // threshold) and release. create_commit builds the rect from
    // press → release: x = min(300,450)=300, y = min(300,420)=300,
    // w = |300-450| = 150, h = |300-420| = 120.
    tool.onPress(ctx, x: 300, y: 300, shift: false, alt: false)
    tool.onMove(ctx, x: 450, y: 420, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 450, y: 420, shift: false, alt: false)

    let abs = model.document.artboards
    #expect(abs.count == 2) // drag-to-create in empty space adds exactly one
    // The original "A" is untouched; the new one carries the drag
    // bounds. Find the non-A artboard.
    let created = try #require(abs.first(where: { $0.id != "A" }))
    #expect(created.x == 300)
    #expect(created.y == 300)
    #expect(created.width == 150)
    #expect(created.height == 120)
    // Original "A" is unchanged at (0,0,200,200).
    if let rect = artboardARect(model) {
        #expect(rect.0 == 0)
        #expect(rect.1 == 0)
        #expect(rect.2 == 200)
        #expect(rect.3 == 200)
    } else {
        Issue.record("artboard A must still be present")
    }
}

// MARK: - MOVE

@Test func artboardParityDragInteriorMovesArtboard() throws {
    let tool = try #require(artboardTool())
    let model = modelWithOneArtboard()
    let ctx = makeCtx(model: model)
    tool.activate(ctx)

    // Press INSIDE artboard A at screen (100,100) → moving_pending
    // (probe_hit latches hit_artboard_id = "A"). Drag by (+50,+30) to
    // (150,130) past threshold → moving + move_apply. Release →
    // move_commit (integer rounding). move_apply / move_commit fall
    // back to hit_artboard_id when panel-selection is empty, so the
    // single-artboard move works end-to-end through the seam.
    tool.onPress(ctx, x: 100, y: 100, shift: false, alt: false)
    tool.onMove(ctx, x: 150, y: 130, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 150, y: 130, shift: false, alt: false)

    #expect(model.document.artboards.count == 1) // a move must not change the count
    // Artboard A shifts by exactly the drag delta (+50,+30); size unchanged.
    if let rect = artboardARect(model) {
        #expect(rect.0 == 50)
        #expect(rect.1 == 30)
        #expect(rect.2 == 200)
        #expect(rect.3 == 200)
    } else {
        Issue.record("artboard A must still be present")
    }
}

// MARK: - DUPLICATE

@Test func artboardParityAltDragInteriorDuplicatesArtboard() throws {
    let tool = try #require(artboardTool())
    let model = modelWithOneArtboard()
    let ctx = makeCtx(model: model)
    tool.activate(ctx)
    #expect(model.document.artboards.count == 1) // precondition: one artboard

    // ALT-press inside A at (100,100) → duplicating_pending. Drag by
    // (+60,+40) past threshold → duplicate_init mints the copy at A's
    // position and retargets translate ops at it, then duplicate_apply
    // / duplicate_commit translate the COPY. The source A stays put;
    // the copy lands at A + delta.
    tool.onPress(ctx, x: 100, y: 100, shift: false, alt: true)
    tool.onMove(ctx, x: 160, y: 140, shift: false, alt: true, dragging: true)
    tool.onRelease(ctx, x: 160, y: 140, shift: false, alt: true)

    let abs = model.document.artboards
    #expect(abs.count == 2) // alt-drag duplicates: count grows by exactly one
    // Source "A" is unmoved at its origin (0,0,200,200).
    if let rect = artboardARect(model) {
        #expect(rect.0 == 0)
        #expect(rect.1 == 0)
        #expect(rect.2 == 200)
        #expect(rect.3 == 200)
    } else {
        Issue.record("source artboard A must still be present")
    }
    // The copy carries A's size, shifted by the drag delta (+60,+40).
    let copy = try #require(abs.first(where: { $0.id != "A" }))
    #expect(copy.x == 60)
    #expect(copy.y == 40)
    #expect(copy.width == 200)
    #expect(copy.height == 200)
}

// MARK: - NO-OP

@Test func artboardParityPressReleaseNoDragIsANoop() throws {
    let tool = try #require(artboardTool())
    let model = modelWithOneArtboard()
    let ctx = makeCtx(model: model)
    tool.activate(ctx)

    // Snapshot the artboard list before the gesture for an exact
    // no-op proof.
    let before = model.document.artboards

    // Press inside A then release with NO intervening move — a
    // sub-threshold click. `moved` stays false, so on_mouseup's
    // mode-guarded commit arms never fire: no move, no create, no
    // duplicate, no new artboard.
    tool.onPress(ctx, x: 100, y: 100, shift: false, alt: false)
    tool.onRelease(ctx, x: 100, y: 100, shift: false, alt: false)

    #expect(model.document.artboards.count == 1) // a sub-threshold click adds/removes nothing
    // A press+release with no drag leaves the artboard list byte-identical.
    #expect(model.document.artboards == before)

    // Same for a press on EMPTY canvas with no drag — creating mode is
    // latched but the sub-threshold mouseup commits nothing.
    let beforeEmpty = model.document.artboards
    tool.onPress(ctx, x: 400, y: 400, shift: false, alt: false)
    tool.onRelease(ctx, x: 400, y: 400, shift: false, alt: false)
    #expect(model.document.artboards == beforeEmpty) // empty-canvas click creates nothing
}
