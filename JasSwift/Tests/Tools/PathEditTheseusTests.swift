import Testing
import Foundation
@testable import JasLib

/// The Ship of Theseus law (JYH, ratified 2026-07-26):
///
///   "The ship is the same ship even when planks are removed, replaced, the
///    anchor is heaved — that's what an artist will expect."
///
/// **A PATH EDIT PRESERVES EVERYTHING EXCEPT `d`.** Stated as a law, NOT an
/// enumeration: an earlier list of the fields to carry omitted `transform`,
/// and dropping `transform` RELOCATES the artwork. So the law is phrased as
/// "everything except the geometry" precisely so it cannot rot as fields are
/// added to `Path`.
///
/// Rust satisfies the law by construction — `PathElem { d: new, ..pe.clone() }`
/// cannot drop a field. Swift has no struct-update syntax, so
/// `pathWithCommands` in YamlToolEffects.swift must forward every property by
/// hand, and this file is the pin that catches an omission. The check is
/// deliberately **Mirror-based**, not a field list: it walks the reflected
/// stored properties of `Path` and compares all of them except `d`, so a
/// property added tomorrow is compared without editing this file. That is the
/// Swift analogue of Rust's struct update.
///
/// Phase 1 is the ONE-ELEMENT case. The severing-erase arm keeps appearance,
/// transform and `name` but must NOT propagate `id` — see
/// `theseusEraseSplitKeepsAppearanceAndNameButNotId`.

// MARK: - Fixture

/// A `Path` with every non-`d` property set to a NON-default,
/// distinguishable value, so a dropped one is observable. `locked` stays
/// false (every edit site skips a locked path) and `visibility` stays
/// renderable.
private func theseusPath(_ d: [PathCommand]) -> Path {
    let ramp = Gradient(
        type: .linear, angle: 30,
        stops: [
            GradientStop(color: "#ff0000", location: 0),
            GradientStop(color: "#0000ff", location: 100),
        ])
    return Path(
        d: d,
        fill: Fill(color: Color(r: 0.2, g: 0.4, b: 0.6)),
        stroke: Stroke(color: Color(r: 0.1, g: 0.1, b: 0.1), width: 3),
        widthPoints: [
            StrokeWidthPoint(t: 0, widthLeft: 1, widthRight: 1),
            StrokeWidthPoint(t: 1, widthLeft: 4, widthRight: 4),
        ],
        opacity: 0.5,
        transform: Transform(a: 1, b: 0, c: 0, d: 1, e: 40, f: 70),
        locked: false,
        visibility: .outline,
        blendMode: .multiply,
        mask: Mask(
            subtreeElement: .rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                       fill: Fill(color: Color(r: 1, g: 1, b: 1)))),
            clip: true, invert: true, disabled: false, linked: false,
            unlinkTransform: Transform()),
        fillGradient: ramp,
        strokeGradient: ramp,
        strokeBrush: "default_brushes/flat_10",
        strokeBrushOverrides: "{\"size\":2}",
        toolOrigin: "blob_brush",
        name: "theseus",
        id: "keep-me",
        fillRule: .evenodd)
}

/// The reflected stored properties of `p`, as label -> description.
/// Mirror rather than a hand list so a new property is picked up for free.
private func fields(_ p: Path) -> [String: String] {
    var out: [String: String] = [:]
    for child in Mirror(reflecting: p).children {
        guard let label = child.label else { continue }
        out[label] = String(describing: child.value)
    }
    return out
}

/// Guard the fixture: if any non-`d` property matched the all-defaults `Path`,
/// the batteries below could pass while dropping it.
@Test func theseusFixtureDiffersFromDefaultInEveryNonDField() {
    let d: [PathCommand] = [.moveTo(0, 0), .lineTo(1, 1)]
    let rich = fields(theseusPath(d))
    let bare = fields(Path(d: d, fillRule: .nonzero))
    #expect(rich.count == bare.count)
    // `locked` is deliberately left at the default: every edit site skips a
    // locked path, so a locked fixture would make the batteries vacuous.
    let allowedSame: Set<String> = ["d", "locked"]
    for (label, value) in rich where !allowedSame.contains(label) {
        #expect(value != bare[label],
                "fixture leaves \(label) at its default, so the battery would pass even if \(label) were dropped")
    }
    // Sanity: the Mirror sees the properties at all.
    #expect(rich.count > 10, "Mirror reflected \(rich.count) properties")
}

// MARK: - The law, as an assertion

/// Every reflected property of `out` except `d` (and anything named in
/// `alsoExempt`) must equal `src`'s. No field list — Mirror-driven, so a
/// property added to `Path` later is covered without touching this helper.
private func expectOnlyDChanged(
    _ src: Path, _ out: Path, _ label: String,
    alsoExempt: Set<String> = [],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let a = fields(src), b = fields(out)
    #expect(a["d"] != b["d"],
            "\(label): `d` is unchanged — the fixture did not exercise an edit",
            sourceLocation: sourceLocation)
    for (name, want) in a where name != "d" && !alsoExempt.contains(name) {
        #expect(b[name] == want,
                "\(label): \(name) changed (Ship of Theseus law) — want \(want), got \(b[name] ?? "<missing>")",
                sourceLocation: sourceLocation)
    }
}

private func modelWithTheseus(_ d: [PathCommand]) -> (Model, Path) {
    let src = theseusPath(d)
    return (Model(document: Document(
        layers: [Layer(children: [.path(src)])],
        selectedLayer: 0, selection: [])), src)
}

private func pathAt(_ model: Model, _ p: ElementPath) -> Path? {
    guard case .path(let out) = model.document.getElement(p) else { return nil }
    return out
}

// MARK: - The one-element sites

@Test func theseusDeleteAnchorPreservesEverythingButD() throws {
    let (model, src) = modelWithTheseus([
        .moveTo(0, 0), .lineTo(50, 0), .lineTo(100, 0),
    ])
    runEffects([["doc.path.delete_anchor_near": ["x": 50, "y": 0, "hit_radius": 8]]],
               ctx: [:], store: StateStore(),
               platformEffects: buildYamlToolEffects(model: model))
    expectOnlyDChanged(src, try #require(pathAt(model, [0, 0])),
                       "doc.path.delete_anchor_near")
}

@Test func theseusInsertAnchorPreservesEverythingButD() throws {
    let (model, src) = modelWithTheseus([.moveTo(0, 0), .lineTo(100, 0)])
    runEffects([["doc.path.insert_anchor_on_segment_near":
                    ["x": 50, "y": 0, "hit_radius": 8]]],
               ctx: [:], store: StateStore(),
               platformEffects: buildYamlToolEffects(model: model))
    expectOnlyDChanged(src, try #require(pathAt(model, [0, 0])),
                       "doc.path.insert_anchor_on_segment_near")
}

@Test func theseusSmoothAtCursorPreservesEverythingButD() throws {
    let src = theseusPath([
        .moveTo(0, 0), .lineTo(10, 5), .lineTo(20, -5), .lineTo(30, 0),
    ])
    let model = Model(document: Document(
        layers: [Layer(children: [.path(src)])], selectedLayer: 0,
        selection: [ElementSelection.all([0, 0])]))
    runEffects([["doc.path.smooth_at_cursor":
                    ["x": 15, "y": 0, "radius": 50, "fit_error": 3]]],
               ctx: [:], store: StateStore(),
               platformEffects: buildYamlToolEffects(model: model))
    expectOnlyDChanged(src, try #require(pathAt(model, [0, 0])),
                       "doc.path.smooth_at_cursor")
}

/// `doc.path.commit_anchor_edit` has three arms, all rebuilding through
/// `pathWithCommands`. Each is driven through the effect with the tool state
/// `doc.path.probe_anchor_hit` would have stashed.
@Test func theseusCommitAnchorEditPreservesEverythingButDInEveryArm() throws {
    // pressed_smooth: collapse a smooth anchor's handles to a corner.
    do {
        let (model, src) = modelWithTheseus([
            .moveTo(0, 0),
            .curveTo(x1: 10, y1: 20, x2: 40, y2: 20, x: 50, y: 0),
            .curveTo(x1: 60, y1: -20, x2: 90, y2: -20, x: 100, y: 0),
        ])
        let store = StateStore()
        store.setTool("anchor_point", "mode", "pressed_smooth")
        store.setTool("anchor_point", "hit_path", ["__path__": [0, 0]])
        store.setTool("anchor_point", "hit_anchor_idx", 1)
        runEffects([["doc.path.commit_anchor_edit":
                        ["origin_x": 50, "origin_y": 0,
                         "target_x": 50, "target_y": 0]]],
                   ctx: [:], store: store,
                   platformEffects: buildYamlToolEffects(model: model))
        expectOnlyDChanged(src, try #require(pathAt(model, [0, 0])),
                           "commit_anchor_edit/pressed_smooth")
    }
    // pressed_corner: drag a corner anchor's handle out.
    do {
        let (model, src) = modelWithTheseus([
            .moveTo(0, 0), .lineTo(50, 0), .lineTo(100, 0),
        ])
        let store = StateStore()
        store.setTool("anchor_point", "mode", "pressed_corner")
        store.setTool("anchor_point", "hit_path", ["__path__": [0, 0]])
        store.setTool("anchor_point", "hit_anchor_idx", 1)
        runEffects([["doc.path.commit_anchor_edit":
                        ["origin_x": 50, "origin_y": 0,
                         "target_x": 70, "target_y": 30]]],
                   ctx: [:], store: store,
                   platformEffects: buildYamlToolEffects(model: model))
        expectOnlyDChanged(src, try #require(pathAt(model, [0, 0])),
                           "commit_anchor_edit/pressed_corner")
    }
    // pressed_handle: drag one bezier handle independently.
    do {
        let (model, src) = modelWithTheseus([
            .moveTo(0, 0),
            .curveTo(x1: 10, y1: 20, x2: 40, y2: 20, x: 50, y: 0),
        ])
        let store = StateStore()
        store.setTool("anchor_point", "mode", "pressed_handle")
        store.setTool("anchor_point", "handle_type", "in")
        store.setTool("anchor_point", "hit_path", ["__path__": [0, 0]])
        store.setTool("anchor_point", "hit_anchor_idx", 1)
        runEffects([["doc.path.commit_anchor_edit":
                        ["origin_x": 40, "origin_y": 20,
                         "target_x": 45, "target_y": 30]]],
                   ctx: [:], store: store,
                   platformEffects: buildYamlToolEffects(model: model))
        expectOnlyDChanged(src, try #require(pathAt(model, [0, 0])),
                           "commit_anchor_edit/pressed_handle")
    }
}

@Test func theseusPaintbrushEditCommitPreservesEverythingButD() throws {
    let (model, src) = modelWithTheseus([
        .moveTo(0, 0), .lineTo(50, 0), .lineTo(100, 0), .lineTo(150, 0),
    ])
    let buffer = "theseus_paintbrush_edit_swift"
    pointBuffersClear(buffer)
    pointBuffersPush(buffer, 50, 10)
    pointBuffersPush(buffer, 75, 20)
    pointBuffersPush(buffer, 100, 0)
    let store = StateStore()
    store.setTool("paintbrush", "edit_target_path", ["__path__": [0, 0]])
    store.setTool("paintbrush", "edit_entry_idx", 1)
    runEffects([["doc.paintbrush.edit_commit":
                    ["buffer": buffer, "fit_error": 4, "within": 12]]],
               ctx: [:], store: store,
               platformEffects: buildYamlToolEffects(model: model))
    pointBuffersClear(buffer)
    expectOnlyDChanged(src, try #require(pathAt(model, [0, 0])),
                       "doc.paintbrush.edit_commit")
}

// MARK: - Erase: the two arms

/// A CLOSED path erased at one spot becomes exactly ONE open fragment
/// (`splitPathAtEraser`'s closed branch returns a single fragment). That is
/// the one-element case, so the law applies in full — `id` included. ERASE
/// DOES NOT REMOVE IDENTITY: "it is still the same object."
@Test func theseusEraseSingleFragmentPreservesEverythingButD() throws {
    let (model, src) = modelWithTheseus([
        .moveTo(0, 0), .lineTo(100, 0), .lineTo(100, 100), .lineTo(0, 100),
        .closePath,
    ])
    runEffects([["doc.path.erase_at_rect":
                    ["last_x": 50, "last_y": 0, "x": 50, "y": 0,
                     "eraser_size": 2]]],
               ctx: [:], store: StateStore(),
               platformEffects: buildYamlToolEffects(model: model))
    #expect(model.document.layers[0].children.count == 1,
            "a closed path erased once yields one fragment")
    expectOnlyDChanged(src, try #require(pathAt(model, [0, 0])),
                       "doc.path.erase_at_rect (one fragment)")
}

/// A SEVERING erase yields several fragments. Phase 1 keeps their appearance,
/// transform and `name` but must NOT propagate `id`: nothing on this path can
/// mint one (`Controller.assignId` never mints — the initiator carries the id
/// in the operation payload — and `dedupeElementIds` only CLEARS duplicates,
/// and only in document readers), so copying it would leave N live elements
/// sharing an id and break the unique-id invariant of REFERENCE_GRAPH.md §2.5.
/// Fresh per-fragment ids are phase 2, along with the linear-gradient stop
/// remap. The severing case is NOT finished.
@Test func theseusEraseSplitKeepsAppearanceAndNameButNotId() throws {
    let (model, src) = modelWithTheseus([.moveTo(0, 0), .lineTo(100, 0)])
    runEffects([["doc.path.erase_at_rect":
                    ["last_x": 50, "last_y": 0, "x": 50, "y": 0,
                     "eraser_size": 2]]],
               ctx: [:], store: StateStore(),
               platformEffects: buildYamlToolEffects(model: model))
    let n = model.document.layers[0].children.count
    #expect(n == 2, "a severing erase of an open path yields two fragments")
    for i in 0..<n {
        let frag = try #require(pathAt(model, [0, i]))
        expectOnlyDChanged(src, frag, "erase fragment \(i)", alsoExempt: ["id"])
        #expect(frag.id == nil,
                "erase fragment \(i): split fragments must not share an id")
        #expect(frag.name == "theseus",
                "erase fragment \(i): the name must survive the split")
    }
}
