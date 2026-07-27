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

/// The law at a RING-REGENERATING 1 -> 1 site (EDIT_SEMANTICS_FREEZE.md §1.1
/// T1, third closure): `d` AND `fillRule` are both spoken to, everything else
/// is preserved. The exemption is not a loosening — the rule is asserted
/// positively against `boolResultFillRule`, so a site that silently kept the
/// source's rule still goes red.
///
/// Kept separate from `expectOnlyDChanged` on purpose: the ordinary path edits
/// (anchor move, insert, eraser split) preserve ring structure and therefore
/// preserve the rule, and must keep failing if they ever stamp it. Mirrors
/// Rust `assert_only_d_and_ring_rule_changed`.
private func expectOnlyDAndRingRuleChanged(
    _ src: Path, _ out: Path, _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(out.fillRule == FillRule(boolResultFillRule),
            "\(label): rings regenerated through the polygon-set layer wear the generated-geometry rule",
            sourceLocation: sourceLocation)
    expectOnlyDChanged(src, out, label, alsoExempt: ["fillRule"],
                       sourceLocation: sourceLocation)
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

/// Run `body` with the per-char id counter both corpus runners install
/// (0,1,2,… so each 8-char draw walks the base-36 alphabet in order:
/// "01234567", "89abcdef", "ghijklmn", "opqrstuv"), then clear it. Rust's twin
/// `with_corpus_id_counter` installs the identical source, which is what lets
/// the two ports pin the SAME literal ids.
private func withCorpusIdCounter<T>(_ body: () -> T) -> T {
    var ctr = 0
    setTestIdRng({ defer { ctr += 1 }; return ctr })
    defer { setTestIdRng(nil) }
    return body()
}

private func eraseAtRect(_ model: Model, lastX: Double, lastY: Double,
                         x: Double, y: Double, eraserSize: Double) {
    runEffects([["doc.path.erase_at_rect":
                    ["last_x": lastX, "last_y": lastY, "x": x, "y": y,
                     "eraser_size": eraserSize]]],
               ctx: [:], store: StateStore(),
               platformEffects: buildYamlToolEffects(model: model))
}

/// A SEVERING erase yields several fragments. They keep their appearance,
/// transform and `name`, but must NOT propagate `id`: copying it would leave N
/// live elements sharing an id and break the unique-id invariant of
/// REFERENCE_GRAPH.md §2.5. Each fragment gets a FRESH id, minted inside the
/// effect.
///
/// `fillGradient` / `strokeGradient` join `id` on the exempt list: S-2 makes
/// the severing arm re-express a LINEAR gradient on each fragment's own
/// extent, so they are now fields the erase DOES speak to. This assertion is
/// about the ones it must not; `gradientSplitRemapsLinearStopsOntoEachFragment`
/// pins their new values, and the #expect below refuses a fragment that still
/// carries the parent's ramp verbatim.
@Test func theseusEraseSplitKeepsAppearanceAndNameWithFreshIds() throws {
    let (model, src) = modelWithTheseus([.moveTo(0, 0), .lineTo(100, 0)])
    withCorpusIdCounter {
        eraseAtRect(model, lastX: 50, lastY: 0, x: 50, y: 0, eraserSize: 2)
    }
    let n = model.document.layers[0].children.count
    #expect(n == 2, "a severing erase of an open path yields two fragments")
    var seen: [String] = []
    for i in 0..<n {
        let frag = try #require(pathAt(model, [0, i]))
        expectOnlyDChanged(src, frag, "erase fragment \(i)",
                           alsoExempt: ["id", "fillGradient", "strokeGradient"])
        #expect(frag.fillGradient != src.fillGradient,
                "erase fragment \(i): the linear fill gradient must be remapped")
        let id = try #require(frag.id,
                              "erase fragment \(i): a split fragment must carry a fresh id")
        #expect(id != src.id,
                "erase fragment \(i): no fragment may wear the severed source's id")
        #expect(!seen.contains(id),
                "erase fragment \(i): fragments must not share an id")
        seen.append(id)
        #expect(frag.name == "theseus",
                "erase fragment \(i): the name must survive the split")
    }
}


/// S-2 AT THE SEAM: a severing erase re-expresses each fragment's LINEAR
/// gradient on that fragment's own extent. Twin of Rust's
/// `gradient_split_remaps_linear_stops_onto_each_fragment`.
///
/// Geometry chosen so every number is hand-derivable, exactly as the
/// `gradient_remap` corpus family's vectors are. A horizontal segment from
/// (0,0) to (120,0) carries a red-to-blue linear gradient at angle 0. The
/// painter resolves it against `Element.bounds`, which for this stroke-less
/// path is (0,0,120,0): centre.u = 60, half = 60, so the ramp runs 0..120.
/// Erasing a 2-wide bite at x = 60 severs it into (0,0)-(59,0) and
/// (61,0)-(120,0).
///
/// Fragment 0's box is (0,0,59,0): centre.u = 29.5, half = 29.5. The red stop
/// sits at absolute 0 -> L' = 0. The blue stop sits at 120 -> L' ~ 203.39,
/// clipped; the endpoint sample at 100 is t = 100/203.39 of the way from red to
/// blue. What the UNFIXED code produced instead: the parent's stops verbatim,
/// ff0000 and 0000ff -- a fragment covering the left half of the ramp painting
/// the WHOLE red-to-blue.
@Test func gradientSplitRemapsLinearStopsOntoEachFragment() throws {
    let ramp = Gradient(type: .linear, angle: 0, stops: [
        GradientStop(color: "ff0000", opacity: 100, location: 0),
        GradientStop(color: "0000ff", opacity: 100, location: 100),
    ])
    let model = Model(document: Document(
        layers: [Layer(children: [
            .path(Path(d: [.moveTo(0, 0), .lineTo(120, 0)],
                       fillGradient: ramp, fillRule: .nonzero)),
        ])],
        selectedLayer: 0, selection: []))
    withCorpusIdCounter {
        eraseAtRect(model, lastX: 60, lastY: 0, x: 60, y: 0, eraserSize: 1)
    }
    #expect(model.document.layers[0].children.count == 2,
            "the bite at x = 60 severs the segment in two")
    let frag0 = try #require(pathAt(model, [0, 0]))
    let g0 = try #require(frag0.fillGradient)
    #expect(g0.stops.count == 2)
    #expect(g0.stops[0].location == 0.0)
    #expect(g0.stops[1].location == 100.0)
    let fb = Element.path(frag0).bounds
    #expect(abs(fb.x - 0.0) < 1e-9 && abs(fb.width - 59.0) < 1e-9,
            "fragment 0 is the 0..59 piece, got x=\(fb.x) w=\(fb.width)")
    let half = fb.width / 2.0
    let t = 100.0 / (50.0 * ((120.0 - half) / half + 1.0))
    let c0 = try #require(Color.fromHex(g0.stops[0].color)).toRgba()
    let c1 = try #require(Color.fromHex(g0.stops[1].color)).toRgba()
    #expect(abs(c0.0 - 1.0) < 1e-9 && abs(c0.2) < 1e-9,
            "the fragment's near end is still full red")
    // Both stop colours are 8-bit hex here, so the far end is compared at
    // quantisation width rather than 1e-9: 1/255 is 0.0039, and the value this
    // separates from is 0 (an un-remapped fragment reports 0000ff).
    #expect(abs(c1.0 - (1.0 - t)) < 1.0 / 255.0 && abs(c1.2 - t) < 1.0 / 255.0,
            "the fragment's far end is the ramp colour at t=\(t), got \(g0.stops[1].color) \u{2014} an un-remapped fragment would report 0000ff")
}

/// A RADIAL gradient is NOT remapped, and its stops come through a severing
/// erase unchanged. Twin of Rust's
/// `gradient_split_leaves_a_radial_gradient_alone`.
///
/// This is the ruled behaviour, not an oversight: a radial gradient's centre is
/// forced to the element's bbox centre and the model has nowhere to record an
/// anchor, so a fragment necessarily re-centres. JYH accepted the recentre
/// (2026-07-26); "gradient anchor" is a separate stone. What this vector
/// forbids is running the LINEAR remap on it anyway.
///
/// Same geometry as the linear vector above, so the ONLY difference is `type`:
/// drop the linear-only guard and this fragment's 80 moves to 100.
@Test func gradientSplitLeavesARadialGradientAlone() throws {
    let stops = [
        GradientStop(color: "ff0000", opacity: 100, location: 0),
        GradientStop(color: "0000ff", opacity: 100, location: 80),
    ]
    let model = Model(document: Document(
        layers: [Layer(children: [
            .path(Path(d: [.moveTo(0, 0), .lineTo(120, 0)],
                       fillGradient: Gradient(type: .radial, angle: 0, stops: stops),
                       fillRule: .nonzero)),
        ])],
        selectedLayer: 0, selection: []))
    withCorpusIdCounter {
        eraseAtRect(model, lastX: 60, lastY: 0, x: 60, y: 0, eraserSize: 1)
    }
    #expect(model.document.layers[0].children.count == 2,
            "the bite at x = 60 severs the segment in two")
    for i in 0..<2 {
        let frag = try #require(pathAt(model, [0, i]))
        let g = try #require(frag.fillGradient)
        #expect(g.type == .radial)
        #expect(g.stops == stops,
                "fragment \(i): a radial gradient's stops are untouched \u{2014} the 80 would become 100 under the linear remap")
    }
}

/// The minted ids themselves, pinned as literals under the SAME per-char
/// counter Rust's twin installs, so the two ports cannot drift on how many ids
/// a severing erase draws or in what order it hands them out. Document order
/// is mint order: fragment [0,0] takes the first id.
///
/// Separation from the pre-fix behaviour: the old code left BOTH fragments at
/// `id: nil`, which is neither literal here.
@Test func eraseSplitMintsIdsInDocumentOrder() throws {
    let (model, _) = modelWithTheseus([.moveTo(0, 0), .lineTo(100, 0)])
    withCorpusIdCounter {
        eraseAtRect(model, lastX: 50, lastY: 0, x: 50, y: 0, eraserSize: 2)
    }
    #expect(try #require(pathAt(model, [0, 0])).id == "01234567")
    #expect(try #require(pathAt(model, [0, 1])).id == "89abcdef")
}

/// TWO paths severed by ONE erase call. The mint order is DOCUMENT order (the
/// earlier child's fragments draw first), which is the only order both ports
/// can agree on — Rust rebuilds the child list front-to-back for exactly this
/// reason. Four fragments, four ids, in sequence.
@Test func eraseSplitOfTwoPathsMintsInDocumentOrder() throws {
    func bar(_ y: Double, _ id: String) -> Element {
        .path(Path(d: [.moveTo(0, y), .lineTo(100, y)],
                   stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1),
                   id: id, fillRule: .nonzero))
    }
    let model = Model(document: Document(
        layers: [Layer(children: [bar(0, "top"), bar(10, "bottom")])],
        selectedLayer: 0, selection: []))
    // A tall eraser rect at x = 50 crosses BOTH bars in one call.
    withCorpusIdCounter {
        eraseAtRect(model, lastX: 50, lastY: 5, x: 50, y: 5, eraserSize: 8)
    }
    let ids = model.document.layers[0].children.map { $0.id }
    #expect(ids == ["01234567", "89abcdef", "ghijklmn", "opqrstuv"])
}

// MARK: - The cardinality law at the blob-brush merge
//
// JYH, ratified 2026-07-26: "Identity survives a one-to-one edit. It does not
// survive a change in cardinality." So `doc.blob_brush.commit_painting` picks
// its arm by the MATCH COUNT:
//   0 matches -> a brand-new blob with the tool's own attributes;
//   1 match   -> the 1 -> 1 case, so the Theseus law applies in full;
//   N >= 2    -> a merge, so identity dies and the result carries no id.
// "The largest source keeps the id" was explicitly REJECTED in both
// directions, so no arm tie-breaks among sources. Rust's
// `blob_brush_commit_painting` branches on the same predicate.

/// The state `doc.blob_brush.commit_painting` reads. `fill_color` comes FROM
/// the source so `blobBrushFillMatches` accepts it — that helper compares
/// lowercased hex plus opacity, and `Color.toHex` round-trips.
private func seedBlobBrushMergeState(_ store: StateStore, _ src: Path) {
    store.set("fill_color", src.fill!.color.toHex())
    store.set("blob_brush_size", 10.0)
    store.set("blob_brush_angle", 0.0)
    store.set("blob_brush_roundness", 100.0)
}

/// A 6-point horizontal sweep along `y` from `x0` to `x1`, in a test-private
/// buffer (the point buffers are process-global and tests run in parallel).
///
/// The coordinates are DOCUMENT space, as the point buffer's are on the live
/// canvas. For a source carrying a `transform` that is not the element's own
/// `d` space, so a sweep meant to land ON such a source must be given the
/// coordinates where the source is DRAWN.
private func seedBlobBrushSweepIn(_ buffer: String, _ x0: Double,
                                  _ x1: Double, _ y: Double) {
    pointBuffersClear(buffer)
    for i in 0...5 {
        let t = Double(i) / 5.0
        pointBuffersPush(buffer, x0 + (x1 - x0) * t, y)
    }
}

private func runBlobBrushCommitPainting(_ model: Model, _ store: StateStore,
                                        buffer: String) {
    runEffects([["doc.blob_brush.commit_painting": [
                    "buffer": buffer,
                    "fidelity_epsilon": "5.0",
                    "merge_only_with_selection": "false",
                    "keep_selected": "false",
                ]]],
               ctx: [:], store: store,
               platformEffects: buildYamlToolEffects(model: model))
    pointBuffersClear(buffer)
}

private let theseusSquare: [PathCommand] = [
    .moveTo(0, 0), .lineTo(100, 0), .lineTo(100, 100), .lineTo(0, 100),
    .closePath,
]

/// EXACTLY ONE match is the 1 -> 1 case: one Path in, one out with a rewritten
/// `d`. The law applies in full, `id` included. `fill` is not re-derived from
/// `state.fill_color` — the match loop already gated on fill equality, so the
/// source's fill matches the stroke's.
@Test func theseusBlobBrushMergeOneMatchPreservesEverythingButD() throws {
    let (model, src) = modelWithTheseus(theseusSquare)
    let store = StateStore()
    seedBlobBrushMergeState(store, src)
    let buffer = "theseus_blob_merge_one_swift"
    // The theseus fixture carries transform translate(40,70), so its local
    // square 0..100 is DRAWN at doc x 40..140, y 70..170. The sweep is aimed
    // there. (It used to run at doc y=50, which is where the square is STORED
    // and 20 units above where it appears; the merge matched anyway, which was
    // the transform-blind bug.)
    seedBlobBrushSweepIn(buffer, 90, 190, 120)
    runBlobBrushCommitPainting(model, store, buffer: buffer)
    #expect(model.document.layers[0].children.count == 1,
            "the sweep overlapped the one existing blob, so it merged")
    // Ring-regenerating: the union rewrote `d` AND re-derived the ring
    // structure, so `fillRule` is spoken to as well (T1's third closure). The
    // theseus fixture happens to declare `.evenodd`, which is also the
    // generated-rings constant, so this vector cannot separate carrying from
    // stamping — `blobMergeOneMatchStampsTheGeneratedRingsFillRule` is the
    // vector that does, on a `.nonzero` source.
    expectOnlyDAndRingRuleChanged(
        src, try #require(pathAt(model, [0, 0])),
        "doc.blob_brush.commit_painting (exactly one match)")
}

/// TWO matches change cardinality, so identity DIES: the merged element
/// carries NEITHER source's id, and wears a FRESH one minted inside the effect
/// (carrying a source's id would leave the merge wearing a dead ship's name).
/// Pinned as a literal under the per-char counter Rust's twin also installs.
///
/// Separation from the pre-fix behaviour: the old code left the merged element
/// at `id: nil`, which is neither "01234567" nor either source's.
@Test func blobBrushMergeOfTwoSourcesMintsAFreshId() throws {
    let red = Fill(color: Color.fromHex("#ff0000")!)
    func blob(_ id: String, _ x0: Double, _ x1: Double) -> Element {
        .path(Path(d: [.moveTo(x0, 40), .lineTo(x1, 40),
                       .lineTo(x1, 60), .lineTo(x0, 60), .closePath],
                   fill: red, toolOrigin: "blob_brush", id: id,
                   fillRule: .nonzero))
    }
    let model = Model(document: Document(
        layers: [Layer(children: [blob("left", 0, 40), blob("right", 60, 100)])],
        selectedLayer: 0, selection: []))
    let store = StateStore()
    store.set("fill_color", red.color.toHex())
    store.set("blob_brush_size", 10.0)
    store.set("blob_brush_angle", 0.0)
    store.set("blob_brush_roundness", 100.0)
    let buffer = "theseus_blob_merge_two_swift"
    seedBlobBrushSweepIn(buffer, 10, 90, 50)
    withCorpusIdCounter {
        runBlobBrushCommitPainting(model, store, buffer: buffer)
    }
    // Both sources plus the sweep collapsed into ONE child: had only one
    // matched, the other would still be sitting there.
    #expect(model.document.layers[0].children.count == 1,
            "the sweep bridged both blobs, so both were merged away")
    let out = try #require(pathAt(model, [0, 0]))
    #expect(out.id == "01234567",
            "a merge of two sources wears a FRESH id, not either source's")
    #expect(out.toolOrigin == "blob_brush",
            "the merged blob stays a blob-brush element")
}

/// A SINGULAR `transform` disqualifies a source from the merge.
///
/// `scale(1, 0)` flattens the element onto a horizontal line: it has no area
/// on screen, so there is nothing to paint into, and it has no inverse, so the
/// unified document-space region could not be written back into its space even
/// if it did match. The sweep must therefore commit a SECOND element and leave
/// the degenerate one untouched.
///
/// HONEST SCOPE, matching Rust's twin: this vector does NOT separate the
/// singular-matrix guard in the match loop. `transformPolygonSet` collapses the
/// source to a zero-area figure and `booleanIntersect` reports empty for that,
/// so deleting the guard leaves this assertion green. What it pins is the
/// OUTCOME — a degenerate source is left alone and the sweep commits beside it,
/// with no crash — which is the corner case a user can actually reach by
/// scaling a blob to zero height.
@Test func blobMergeSkipsASourceWhoseTransformIsSingular() throws {
    let red = Fill(color: Color.fromHex("#ff0000")!)
    let model = Model(document: Document(
        layers: [Layer(children: [
            .path(Path(d: [.moveTo(0, 40), .lineTo(100, 40),
                           .lineTo(100, 60), .lineTo(0, 60), .closePath],
                       fill: red,
                       // det == 0: everything lands on the line y = 50.
                       transform: Transform(a: 1, b: 0, c: 0, d: 0, e: 0, f: 50),
                       toolOrigin: "blob_brush",
                       fillRule: .nonzero)),
        ])],
        selectedLayer: 0, selection: []))
    let store = StateStore()
    store.set("fill_color", red.color.toHex())
    store.set("blob_brush_size", 10.0)
    store.set("blob_brush_angle", 0.0)
    store.set("blob_brush_roundness", 100.0)
    let buffer = "blob_singular_transform_swift"
    // Straight along the collapsed line, so the degenerate source is as
    // reachable as it can be.
    seedBlobBrushSweepIn(buffer, 10, 90, 50)
    runBlobBrushCommitPainting(model, store, buffer: buffer)
    #expect(model.document.layers[0].children.count == 2,
            "the degenerate source is skipped, so the sweep commits beside it")
    let untouched = try #require(pathAt(model, [0, 0]))
    #expect(untouched.d.count == 5, "the degenerate source keeps its `d`")
    let fresh = try #require(pathAt(model, [0, 1]))
    #expect(fresh.transform == nil, "the new blob is the transform-less one")
}

/// The erase arm PRESERVES `toolOrigin` where the initializer defaults used to
/// clear it, so an erased fragment is now a blob-merge candidate it previously
/// was not. A closed path erased once yields ONE fragment (the 1 -> 1 arm),
/// and a sweep over that fragment is again 1 -> 1, so the whole chain must
/// preserve everything but `d`. If erase dropped `toolOrigin`, the sweep would
/// append a SECOND element instead.
@Test func theseusEraseThenBlobMergePreservesEverythingButD() throws {
    let (model, src) = modelWithTheseus(theseusSquare)
    runEffects([["doc.path.erase_at_rect":
                    ["last_x": 50, "last_y": 0, "x": 50, "y": 0,
                     "eraser_size": 2]]],
               ctx: [:], store: StateStore(),
               platformEffects: buildYamlToolEffects(model: model))
    let fragment = try #require(pathAt(model, [0, 0]))
    #expect(fragment.toolOrigin == "blob_brush",
            "the erased fragment keeps toolOrigin — that is what makes it a merge candidate")
    let store = StateStore()
    seedBlobBrushMergeState(store, src)
    let buffer = "theseus_blob_merge_after_erase_swift"
    // The theseus fixture carries transform translate(40,70), so its local
    // square 0..100 is DRAWN at doc x 40..140, y 70..170. The sweep is aimed
    // there. (It used to run at doc y=50, which is where the square is STORED
    // and 20 units above where it appears; the merge matched anyway, which was
    // the transform-blind bug.)
    seedBlobBrushSweepIn(buffer, 90, 190, 120)
    runBlobBrushCommitPainting(model, store, buffer: buffer)
    #expect(model.document.layers[0].children.count == 1,
            "the erased fragment was merged into, not left beside a new blob")
    // The final step is the blob merge's 1 -> 1 arm, which regenerates rings —
    // see the note on the vector above for why the fixture's own `.evenodd`
    // cannot separate the two behaviours here.
    expectOnlyDAndRingRuleChanged(src, try #require(pathAt(model, [0, 0])),
                                  "erase then blob_brush merge")
}

// MARK: - Unanimous attributes on an N -> 1 merge
//
// JYH, ratified 2026-07-26: if EVERY source agrees on a non-paint attribute
// the result carries it; if they disagree, the tool's default is taken. No
// winner is ever picked — "the largest source keeps it" was rejected in both
// directions. The rationale is the Theseus principle: an edit preserves what
// it does not speak to, and painting a stroke says nothing about opacity.
// `transform` is EXCLUDED regardless (see the site).

/// A test-only mask, so `mask` can be given a non-default value.
private func unanimityMask() -> Mask {
    Mask(subtreeElement: .rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                    fill: Fill(color: Color(r: 1, g: 1, b: 1)))),
         clip: true, invert: true, disabled: false, linked: false,
         unlinkTransform: Transform())
}

/// The non-paint attributes one blob-brush source carries into a merge.
private struct BlobAttrs {
    var opacity: Double = 1.0
    var transform: Transform? = nil
    var locked: Bool = false
    var visibility: Visibility = .preview
    var blendMode: BlendMode = .normal
    var mask: Mask? = nil
    var name: String? = nil
}

/// Two overlapping blob-brush sources (left + right, same red fill) bridged by
/// ONE sweep, so the commit takes the N = 2 merge arm. Returns the merged
/// element. `buffer` must be unique per test — the point buffers are
/// process-global and tests run in parallel. Mirrors Rust `merge_two_blobs`.
/// The sources' local `d` spans x 0..40 and 60..100 at y 40..60; `sweep` is
/// `(x0, x1, y)` in DOCUMENT space, so a caller that gives its sources a
/// `transform` must offset the sweep by it to land on them.
private func mergeTwoBlobs(_ left: BlobAttrs, _ right: BlobAttrs,
                           buffer: String,
                           sweep: (Double, Double, Double)) -> Path? {
    let red = Fill(color: Color.fromHex("#ff0000")!)
    func blob(_ x0: Double, _ x1: Double, _ a: BlobAttrs) -> Element {
        .path(Path(d: [.moveTo(x0, 40), .lineTo(x1, 40),
                       .lineTo(x1, 60), .lineTo(x0, 60), .closePath],
                   fill: red,
                   opacity: a.opacity, transform: a.transform,
                   locked: a.locked, visibility: a.visibility,
                   blendMode: a.blendMode, mask: a.mask,
                   toolOrigin: "blob_brush",
                   name: a.name,
                   fillRule: .nonzero))
    }
    let model = Model(document: Document(
        layers: [Layer(children: [blob(0, 40, left), blob(60, 100, right)])],
        selectedLayer: 0, selection: []))
    let store = StateStore()
    store.set("fill_color", red.color.toHex())
    store.set("blob_brush_size", 10.0)
    store.set("blob_brush_angle", 0.0)
    store.set("blob_brush_roundness", 100.0)
    seedBlobBrushSweepIn(buffer, sweep.0, sweep.1, sweep.2)
    runBlobBrushCommitPainting(model, store, buffer: buffer)
    #expect(model.document.layers[0].children.count == 1,
            "the sweep bridged both blobs, so both were merged away")
    return pathAt(model, [0, 0])
}

/// UNANIMOUS: both sources carry the same five non-paint attributes, so all
/// five ride onto the merged element.
///
/// Separation from the pre-fix behaviour: the old code built the result from
/// the initializer defaults, so it returned opacity 1.0, .normal, .preview,
/// locked false and mask nil — the opposite of every value asserted here.
@Test func blobMergeCarriesUnanimousAttributes() throws {
    let agreed = BlobAttrs(opacity: 0.5, locked: true, visibility: .outline,
                           blendMode: .multiply, mask: unanimityMask())
    let out = try #require(mergeTwoBlobs(agreed, agreed, buffer: "unanimity_agree_swift",
                                        sweep: (10, 90, 50)))
    #expect(out.opacity == 0.5)
    #expect(out.blendMode == .multiply)
    #expect(out.visibility == .outline)
    #expect(out.locked)
    #expect(out.mask == unanimityMask())
}

/// DISAGREEMENT: the sources differ on every one of the five, so the merged
/// element takes the tool's defaults. No source is ever the winner.
///
/// This vector does NOT separate the pre-fix behaviour (which also produced
/// the defaults) — it is the anti-arbitrariness pin, and it goes red the
/// moment anyone implements "the first/largest source wins".
@Test func blobMergeOfDisagreeingSourcesTakesTheDefaults() throws {
    let left = BlobAttrs(opacity: 0.5, locked: true, visibility: .outline,
                         blendMode: .multiply, mask: unanimityMask())
    let right = BlobAttrs(opacity: 0.25, locked: false, visibility: .preview,
                          blendMode: .screen, mask: nil)
    let out = try #require(mergeTwoBlobs(left, right, buffer: "unanimity_disagree_swift",
                                        sweep: (10, 90, 50)))
    #expect(out.opacity == 1.0)
    #expect(out.blendMode == .normal)
    #expect(out.visibility == .preview)
    #expect(!out.locked)
    #expect(out.mask == nil)
}

/// `transform` is EXCLUDED even when the sources agree. The merge matches raw
/// geometry against a document-space sweep, so it is already transform-blind
/// (transcripts/BLOB_BRUSH_TOOL.md); carrying a unanimous transform would
/// COMPOUND that bug by relocating the merged artwork.
///
/// This vector does not separate the pre-fix behaviour either — it is the pin
/// that stops `transform` being swept into the unanimity list later.
@Test func blobMergeNeverCarriesTransformEvenWhenUnanimous() throws {
    let withTransform = BlobAttrs(
        transform: Transform(a: 1, b: 0, c: 0, d: 1, e: 40, f: 70))
    // Both sources carry translate(40,70), so their local x 0..40 / 60..100 at
    // y 40..60 are DRAWN at doc x 40..80 / 100..140, y 110..130. The sweep is
    // aimed there — at the old doc y=50 the fixture no longer merges at all,
    // and the assertion below would be vacuous.
    let out = try #require(mergeTwoBlobs(withTransform, withTransform,
                                         buffer: "unanimity_transform_swift",
                                         sweep: (50, 130, 120)))
    #expect(out.transform == nil,
            "a unanimous transform must NOT ride onto the merge")
}

// MARK: - `name` at an N -> 1 merge: ASSERTING-SOURCES
//
// JYH, ratified 2026-07-27 (EDIT_SEMANTICS_FREEZE.md §3.3, the `name` bullet):
// for `name` ONLY, unanimity ranges over the sources that ASSERT a name —
// silence is not a competing claim. "hull" + unnamed -> "hull"; "hull" +
// "keel" -> the documented default (no name), per T3. Nothing geometric elects
// the survivor. Mirrors Rust's twin vectors exactly.

/// ONE source asserts a name; the other is silent. The assertion carries.
///
/// Separation from the pre-fix behaviour: `name` was not carried at all (the
/// merge arm's `Path(...)` passed no `name:`), so this returned nil.
@Test func blobMergeCarriesANameOnlyOneSourceAsserts() throws {
    let out = try #require(mergeTwoBlobs(BlobAttrs(name: "hull"), BlobAttrs(),
                                         buffer: "name_one_asserts_swift",
                                         sweep: (10, 90, 50)))
    #expect(out.name == "hull",
            "a silent source does not veto the only name asserted")
}

/// The silent source may be either operand — the carry must not depend on
/// document order, which is geometry (z-order) wearing a different hat.
@Test func blobMergeCarriesANameAssertedByTheSecondSourceOnly() throws {
    let out = try #require(mergeTwoBlobs(BlobAttrs(), BlobAttrs(name: "keel"),
                                         buffer: "name_second_asserts_swift",
                                         sweep: (10, 90, 50)))
    #expect(out.name == "keel",
            "which operand asserts the name cannot change the answer")
}

/// ALL-SILENT: nothing is asserted, so the documented default (no name)
/// stands. The anti-invention pin.
@Test func blobMergeOfSilentSourcesHasNoName() throws {
    let out = try #require(mergeTwoBlobs(BlobAttrs(), BlobAttrs(),
                                         buffer: "name_all_silent_swift",
                                         sweep: (10, 90, 50)))
    #expect(out.name == nil,
            "no source asserted a name, so the default (none) stands")
}

/// DISAGREEMENT: two sources assert DIFFERENT names — T2 shape 2 — so T3 takes
/// the documented default. No winner by z-order, area or document position.
@Test func blobMergeOfDisagreeingNamesTakesTheDefault() throws {
    let out = try #require(mergeTwoBlobs(BlobAttrs(name: "hull"),
                                         BlobAttrs(name: "keel"),
                                         buffer: "name_disagree_swift",
                                         sweep: (10, 90, 50)))
    #expect(out.name == nil,
            "two asserted names disagree, so neither is elected")
}

/// AGREEMENT: both sources assert the SAME name, so asserting-sources reduces
/// to plain unanimity and the agreed name carries.
@Test func blobMergeCarriesANameBothSourcesAgreeOn() throws {
    let out = try #require(mergeTwoBlobs(BlobAttrs(name: "hull"),
                                         BlobAttrs(name: "hull"),
                                         buffer: "name_agree_swift",
                                         sweep: (10, 90, 50)))
    #expect(out.name == "hull",
            "agreeing sources carry their name, as any unanimous field does")
}

// MARK: - T1's RING TERM: the fill rule belongs to whoever made the rings
//
// EDIT_SEMANTICS_FREEZE.md §1.1 T1, third closure: an edit that re-derives an
// element's ring structure through the polygon-set layer stamps the
// generated-geometry constant (`boolResultFillRule`). Every blob-brush commit
// arm builds its `d` from a polygon set — `booleanUnion` on the paint arms,
// `booleanSubtract` on the erase arm — so its rings are MACHINE-WOUND, and a
// non-zero declaration over machine-wound rings silently fills holes.
//
// The subtlety at the 1-match arm: it is a 1 -> 1 edit, so Theseus preserves
// everything else — but the rings were REGENERATED, so `fillRule` is precisely
// a field the edit speaks to. Carrying the source's rule there is
// OVER-preservation, which the law forbids just as firmly.

/// `spans` are local `x0..x1` boxes at y 40..60, each a blob-brush source
/// declaring `rule`; the store is seeded for a commit whose fill matches. An
/// empty `spans` gives the 0 -> 1 (brand-new blob) arm. Mirrors Rust
/// `blob_doc_with_rule`.
private func blobDocWithRule(_ spans: [(Double, Double)],
                             _ rule: FillRule) -> (Model, StateStore) {
    let red = Fill(color: Color.fromHex("#ff0000")!)
    let children: [Element] = spans.map { (x0, x1) in
        .path(Path(d: [.moveTo(x0, 40), .lineTo(x1, 40),
                       .lineTo(x1, 60), .lineTo(x0, 60), .closePath],
                   fill: red, toolOrigin: "blob_brush",
                   id: "src\(x0)", fillRule: rule))
    }
    let model = Model(document: Document(
        layers: [Layer(children: children)], selectedLayer: 0, selection: []))
    let store = StateStore()
    store.set("fill_color", red.color.toHex())
    store.set("blob_brush_size", 10.0)
    store.set("blob_brush_angle", 0.0)
    store.set("blob_brush_roundness", 100.0)
    return (model, store)
}

/// The 1 -> 1 arm regenerates its rings by union, so it stamps
/// `boolResultFillRule` instead of carrying the source's `.nonzero`.
///
/// Separation from the pre-fix behaviour: the source declares `.nonzero` and
/// the arm forwarded `pe.fillRule`, so this returned `.nonzero`. The declared
/// value is deliberately the OPPOSITE of the constant — a source already at
/// `.evenodd` (as `theseusPath` is) could not tell carrying from stamping.
@Test func blobMergeOneMatchStampsTheGeneratedRingsFillRule() throws {
    let (model, store) = blobDocWithRule([(0, 100)], .nonzero)
    let buffer = "ring_rule_one_match_swift"
    seedBlobBrushSweepIn(buffer, 10, 90, 50)
    runBlobBrushCommitPainting(model, store, buffer: buffer)
    #expect(model.document.layers[0].children.count == 1,
            "the sweep overlapped the one source, so it took the 1 -> 1 arm")
    let out = try #require(pathAt(model, [0, 0]))
    #expect(out.id == "src0.0",
            "the 1 -> 1 arm is still a survivor — its identity must not die")
    #expect(out.fillRule == FillRule(boolResultFillRule),
            "union-generated rings wear the generated-geometry rule, not the source's")
}

/// The N -> 1 merge arm stamps the constant too — it must not hardcode
/// `.nonzero` ("parity, not preference", as the arm's own comment conceded).
@Test func blobMergeOfTwoSourcesStampsTheGeneratedRingsFillRule() throws {
    let out = try #require(mergeTwoBlobs(BlobAttrs(), BlobAttrs(),
                                         buffer: "ring_rule_merge_swift",
                                         sweep: (10, 90, 50)))
    #expect(out.fillRule == FillRule(boolResultFillRule),
            "a merge's rings come out of booleanUnion, so they wear the generated-geometry rule")
}

/// The 0 -> 1 arm — a brand-new blob — also builds its `d` from a unioned
/// polygon set (the swept dabs), so it stamps the constant as well.
@Test func blobNewBlobStampsTheGeneratedRingsFillRule() throws {
    let (model, store) = blobDocWithRule([], .nonzero)
    let buffer = "ring_rule_new_blob_swift"
    seedBlobBrushSweepIn(buffer, 10, 90, 50)
    runBlobBrushCommitPainting(model, store, buffer: buffer)
    #expect(model.document.layers[0].children.count == 1,
            "an empty document plus a sweep commits exactly one new blob")
    let out = try #require(pathAt(model, [0, 0]))
    #expect(out.fillRule == FillRule(boolResultFillRule),
            "the swept region is a machine-wound polygon set like any other")
}

/// The ERASE arm is the third ring-regenerating blob site, and the one where
/// the corruption is easiest to reach: `booleanSubtract` can punch a HOLE ring
/// into a source, and a carried `.nonzero` declaration over machine-wound
/// rings fills exactly that hole back in.
@Test func blobEraseStampsTheGeneratedRingsFillRule() throws {
    let (model, store) = blobDocWithRule([(0, 100)], .nonzero)
    let buffer = "ring_rule_erase_swift"
    // A short sweep well inside the source's y 40..60 band, so the subtract
    // bites a notch rather than clearing the element away.
    seedBlobBrushSweepIn(buffer, 40, 60, 50)
    runEffects([["doc.blob_brush.commit_erasing": [
                    "buffer": buffer, "fidelity_epsilon": "5.0",
                ]]],
               ctx: [:], store: store,
               platformEffects: buildYamlToolEffects(model: model))
    pointBuffersClear(buffer)
    #expect(model.document.layers[0].children.count == 1,
            "the notch leaves a non-empty remainder, so the element survives")
    let out = try #require(pathAt(model, [0, 0]))
    #expect(out.d.count != 5,
            "the erase actually bit into `d` — otherwise the rule assertion below would be watching an unedited element")
    #expect(out.id == "src0.0",
            "erase is 1 -> 1 for a surviving element — its identity lives")
    #expect(out.fillRule == FillRule(boolResultFillRule),
            "subtract-generated rings wear the generated-geometry rule")
}
