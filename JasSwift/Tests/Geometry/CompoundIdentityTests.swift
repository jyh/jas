import Testing
@testable import JasLib

/// THE PRESERVATION LAW over a COMPOUND SHAPE's identity
/// (transcripts/EDIT_SEMANTICS_FREEZE.md §3.2, §3.4, §3.6, and the cardinality
/// law's identity projection).
///
/// A compound shape's `operands` are NOT `children()`: they live on
/// `CompoundShape.operands`, which is exactly why `Document.elementIds` carries
/// a separate arm for them. Every id walk that forgets that arm is blind one
/// level below the id it is reasoning about, and this file pins the two walks
/// in `Geometry/` that forgot it.

// MARK: - Fixtures

/// A rect that differs from a default `Rect` in every field these batteries
/// reason about, so a battery cannot pass on nothing (§3.1 ANTI-VACUITY).
private func richRect(_ x: Double, _ id: String, _ name: String) -> Element {
    .rect(Rect(x: x, y: 0, width: 10, height: 10,
               fill: mvFill, stroke: mvStroke,
               opacity: 0.5, transform: Transform.translate(3, 4),
               locked: true, visibility: .outline, blendMode: .multiply,
               mask: mvProbe(9), fillGradient: mvGrad(30),
               strokeGradient: mvGrad(60),
               name: name, id: id))
}

/// The compound under test: two overlapping rich rects, each with an id of its
/// own, and a `common` that is rich in every field `CompoundShape` carries.
/// The operands' ids are what make the operand assertions bite — a walk that
/// clears only the compound's own id leaves TWO live elements per operand id.
private func richCompound(_ op: CompoundOperation) -> CompoundShape {
    CompoundShape(
        operation: op,
        operands: [richRect(0, "op-back", "port"),
                   richRect(5, "op-front", "starboard")],
        id: "cs-1",
        fill: mvFill,
        stroke: mvStroke,
        opacity: 0.25,
        transform: Transform.translate(7, 11),
        locked: true,
        visibility: .outline,
        blendMode: .multiply,
        mask: mvProbe(12))
}

/// §3.1's mandatory anti-vacuity guard, spelled out over every field the
/// batteries below read: a fixture that silently decayed to defaults would
/// pass on nothing.
private func assertCompoundFixtureIsRich(_ cs: CompoundShape) {
    let d = CompoundShape(operation: cs.operation, operands: [])
    #expect(cs.id != nil, "fixture must carry an id")
    #expect(cs.opacity != d.opacity, "fixture opacity decayed to the default")
    #expect(cs.transform != d.transform, "fixture transform decayed")
    #expect(cs.locked != d.locked, "fixture locked decayed")
    #expect(cs.visibility != d.visibility, "fixture visibility decayed")
    #expect(cs.blendMode != d.blendMode, "fixture blend mode decayed")
    #expect(cs.mask != d.mask, "fixture mask decayed")
    #expect(cs.fill != d.fill, "fixture fill decayed")
    #expect(cs.stroke != d.stroke, "fixture stroke decayed")
    for (i, operand) in cs.operands.enumerated() {
        #expect(operand.id != nil, "operand \(i) must carry an id")
        #expect(operand.name != nil, "operand \(i) must carry a name")
        #expect(operand.mask != nil, "operand \(i) must carry a mask")
        #expect(operand.visibility == .outline, "operand \(i) visibility decayed")
    }
}

private func bbox(_ points: [(Double, Double)]) -> (Double, Double, Double, Double) {
    let xs = points.map(\.0), ys = points.map(\.1)
    return (xs.min()!, ys.min()!, xs.max()!, ys.max()!)
}

// MARK: - `Element.clearingIds()` over a compound's operands

/// THE VIOLATION. `clearingIds()`' `.live` arm returned `.live(v.withId(nil))`
/// — the compound's OWN id cleared and every operand's id left in place. So a
/// copy was born id-less at the top and id-DUPLICATING underneath: a
/// reference to an operand id silently REBINDS to whichever element the index
/// walk reaches first (§3.7), which is strictly worse than a loud break.
/// Rust's `clear_ids` recurses into `operands`; this is the Swift twin.
@Test func clearingIdsOfACompoundClearsItsOperandsIdsToo() {
    let cs = richCompound(.union)
    assertCompoundFixtureIsRich(cs)
    let cleared = Element.live(.compoundShape(cs)).clearingIds()
    guard case .live(.compoundShape(let out)) = cleared else {
        Issue.record("expected a compound shape back"); return
    }
    #expect(out.id == nil, "the compound's own id is cleared")
    #expect(out.operands.count == 2)
    for (i, operand) in out.operands.enumerated() {
        #expect(operand.id == nil,
                "operand \(i) still wears \(String(describing: operand.id)) — an identity that is still live on the source's operand")
    }
}

/// The other half: identity is the ONLY thing the clear takes. Every other
/// field of every operand — and of the compound — survives untouched, and the
/// MANDATORY GEOMETRY PAIRING says where the operands actually are.
@Test func clearingIdsOfACompoundLeavesEveryOtherFieldOfEveryOperandAlone() {
    let cs = richCompound(.union)
    assertCompoundFixtureIsRich(cs)
    let cleared = Element.live(.compoundShape(cs)).clearingIds()
    guard case .live(.compoundShape(let out)) = cleared else {
        Issue.record("expected a compound shape back"); return
    }
    // The compound's own non-id fields.
    #expect(out.operation == cs.operation)
    #expect(out.fill == cs.fill)
    #expect(out.stroke == cs.stroke)
    #expect(out.opacity == cs.opacity)
    #expect(out.transform == cs.transform)
    #expect(out.locked == cs.locked)
    #expect(out.visibility == cs.visibility)
    #expect(out.blendMode == cs.blendMode)
    #expect(out.mask == cs.mask)
    // Every operand's non-id fields, and its geometry VALUE.
    let wantX: [Double] = [0, 5]
    for (i, operand) in out.operands.enumerated() {
        guard case .rect(let r) = operand else {
            Issue.record("operand \(i) should still be a rect"); return
        }
        // MANDATORY GEOMETRY PAIRING: the operands are where they were.
        #expect(abs(r.x - wantX[i]) < 1e-9 && abs(r.width - 10) < 1e-9,
                "operand \(i) geometry moved: x=\(r.x) w=\(r.width)")
        #expect(r.name == (i == 0 ? "port" : "starboard"),
                "clearing ids must not touch `name`")
        #expect(r.opacity == 0.5)
        #expect(r.transform == Transform.translate(3, 4))
        #expect(r.locked == true)
        #expect(r.visibility == .outline)
        #expect(r.blendMode == .multiply)
        #expect(r.mask == mvProbe(9))
        #expect(r.fillGradient == mvGrad(30))
        #expect(r.strokeGradient == mvGrad(60))
    }
    // T4 BYSTANDER: the SOURCE compound is not a copy site's collateral.
    #expect(cs.id == "cs-1")
    #expect(cs.operands[0].id == "op-back")
    #expect(cs.operands[1].id == "op-front")
}

/// The same violation as a DOCUMENT invariant, through the call site the house
/// already documents as the copy rule ("A copy must not inherit the source's
/// stable id (no two elements may share an identity); it is born id-less").
/// The unit battery above cannot see this: uniqueness is a property of the
/// document, not of the returned value.
@Test func copySelectionOfACompoundShapeClearsItsOperandsIdsToo() {
    let cs = Element.live(.compoundShape(richCompound(.union)))
    let layer = Layer(name: "L0", children: [cs])
    let doc = Document(layers: [layer], selection: [ElementSelection.all([0, 0])])
    let ctrl = Controller(model: Model(document: doc))
    let before = doc.elementIds
    #expect(before.contains("op-back") && before.contains("op-front")
            && before.contains("cs-1"),
            "the pre-edit id set must hold the operand ids for this to bite")

    ctrl.copySelection(dx: 20, dy: 0)
    let kids = ctrl.document.layers[0].children
    #expect(kids.count == 2, "the copy landed beside the source")
    guard kids.count == 2,
          case .live(.compoundShape(let copy)) = kids[1],
          case .live(.compoundShape(let src)) = kids[0] else {
        Issue.record("expected two compound shapes"); return
    }
    // MANDATORY GEOMETRY PAIRING: the copy carries the source's operand
    // geometry. It is NOT offset by (dx, dy) — `moveControlPoints` falls
    // through to a bare return for a compound shape, so Edit > Copy of a live
    // compound lands the copy exactly on top of its source. A pre-existing
    // behaviour gap, RECORDED here because a geometry assertion must state
    // what actually happened; it is not this wave's subject and is not
    // repaired here. (Rust's twin battery records the identical gap.)
    guard case .rect(let r) = copy.operands[0] else {
        Issue.record("expected a rect operand"); return
    }
    #expect(abs(r.x - 0) < 1e-9 && abs(r.width - 10) < 1e-9,
            "the copy carries the back operand's geometry, got x=\(r.x) w=\(r.width)")

    #expect(copy.id == nil, "the copy itself is born id-less")
    for (i, operand) in copy.operands.enumerated() {
        #expect(operand.id == nil,
                "operand \(i) of the COPY still wears \(String(describing: operand.id))")
    }
    // The document-level invariant the operand ids actually breach.
    var seen: Set<String> = []
    var dupes: [String] = []
    func walk(_ e: Element) {
        if let id = e.id, !seen.insert(id).inserted { dupes.append(id) }
        switch e {
        case .group(let g): for c in g.children { walk(c) }
        case .layer(let l): for c in l.children { walk(c) }
        case .live(.compoundShape(let c)): for o in c.operands { walk(o) }
        default: break
        }
    }
    for l in ctrl.document.layers { walk(.layer(l)) }
    #expect(dupes.isEmpty, "copy left duplicate id(s) in the document: \(dupes)")

    // And the source is a bystander (T4): untouched, ids included.
    #expect(src.id == "cs-1")
    #expect(src.operands[0].id == "op-back")
    #expect(src.operands[1].id == "op-front")
}

/// THE WALK ITSELF, pinned against the document's OWN id walk instead of
/// against a hand-written id list — the Swift twin of Rust's
/// `clear_ids_leaves_document_element_ids_empty_over_a_nested_compound`.
///
/// `clearingIds()` exists precisely so that ``Document/elementIds`` comes back
/// EMPTY over a cleared subtree, and the operand blind spot survived every
/// by-name assertion written at the time because nobody enumerated the owners:
/// the ratified audit asked "does the helper drop a field?" (no) instead of
/// "does the helper's walk reach what the id walk reaches?" (it did not). See
/// transcripts/EDIT_SEMANTICS_FREEZE.md §7.3's clipboard/duplicate entry.
///
/// The compound sits inside a GROUP inside the layer, so one pass must cross
/// `children` -> `children` -> `operands`.
///
/// STATED BLIND SPOT, so this is not over-read: it proves agreement over the
/// owners THIS FIXTURE contains. A future non-`children` owner added to
/// `elementIds` and not to `clearingIds()` is caught by the document-level
/// invariant gate (freeze §4 tier 1), not by this test.
@Test func clearingIdsLeavesDocumentElementIdsEmptyOverANestedCompound() {
    let cs = richCompound(.union)
    assertCompoundFixtureIsRich(cs)
    let group = Element.group(Group(children: [.live(.compoundShape(cs))],
                                    name: "G", id: "g-outer"))
    let layer = Layer(name: "L0", children: [group], id: "layer-id")
    let before = Document(layers: [layer]).elementIds
    #expect(before.count == 5,
            """
            the fixture must carry an id at all five depths (layer, group, \
            compound, two operands) or the walk proves nothing, got \(before)
            """)

    guard case .layer(let cleared) = Element.layer(layer).clearingIds() else {
        Issue.record("expected a layer back"); return
    }
    // MANDATORY GEOMETRY PAIRING: clearing identity must not disturb the
    // shape. The back operand keeps x=0 w=10 exactly where richCompound put
    // it, two containers below the element this call was made on.
    guard case .group(let g) = cleared.children.first,
          case .live(.compoundShape(let out)) = g.children.first,
          case .rect(let r) = out.operands.first else {
        Issue.record("expected layer > group > compound > rect"); return
    }
    #expect(abs(r.x - 0) < 1e-9 && abs(r.width - 10) < 1e-9,
            "geometry moved: x=\(r.x) w=\(r.width)")

    let after = Document(layers: [cleared]).elementIds
    #expect(after.isEmpty,
            """
            clearingIds() left \(after) live in the document — its walk no \
            longer agrees with Document.elementIds
            """)
}

// MARK: - `Element.withCommon` over a live element

/// A LIVE DIVERGENCE found by this wave's own enumeration of Element.swift,
/// not by the brief. `withCommon`'s `.live` arm read
///
///   _ = (opacity, blendMode)          // "no LiveElement setter"
///   if let t = transform { ... }
///
/// so a Properties-panel Opacity or Blend Mode edit over a selected compound
/// shape (or reference / recorded / generated element) was a SILENT NO-OP in
/// JasSwift, while `apply_properties_panel_field` in jas_dioxus writes
/// `ne.common_mut().opacity = op` — which reaches a Live element like any
/// other. Both fields exist on all four Swift conformers; only the setters
/// were missing. This is not a preservation violation — nothing was dropped —
/// it is the same generative cause one step over: a hand-written per-kind
/// switch whose live arm was left a stub.
///
/// The reference interpreter has no apply half of this panel at all
/// (`workspace_interpreter/effects.py` carries only the display sync), so this
/// is a Rust-vs-Swift divergence with no third opinion, resolved Rust-ward per
/// the house rule that Rust implements first.
@Test func withCommonAppliesOpacityAndBlendModeToALiveCompound() {
    let cs = richCompound(.union)
    assertCompoundFixtureIsRich(cs)
    let edited = Element.live(.compoundShape(cs))
        .withCommon(opacity: 0.75, blendMode: .screen)
    guard case .live(.compoundShape(let out)) = edited else {
        Issue.record("expected a compound shape back"); return
    }
    #expect(out.opacity == 0.75, "the edit's own subject did not land")
    #expect(out.blendMode == .screen, "the edit's own subject did not land")
    // §3.1: it speaks to those two and preserves the rest.
    #expect(out.id == "cs-1", "an opacity edit must not touch identity")
    #expect(out.transform == cs.transform)
    #expect(out.mask == cs.mask)
    #expect(out.fill == cs.fill)
    #expect(out.stroke == cs.stroke)
    #expect(out.locked == cs.locked)
    #expect(out.visibility == cs.visibility)
    #expect(out.operation == cs.operation)
    // MANDATORY GEOMETRY PAIRING: the operands are untouched bystanders (T4).
    #expect(out.operands.count == 2)
    guard out.operands.count == 2,
          case .rect(let r0) = out.operands[0],
          case .rect(let r1) = out.operands[1] else {
        Issue.record("expected two rect operands"); return
    }
    #expect(abs(r0.x - 0) < 1e-9 && abs(r0.width - 10) < 1e-9,
            "operand 0 moved: x=\(r0.x) w=\(r0.width)")
    #expect(abs(r1.x - 5) < 1e-9 && abs(r1.width - 10) < 1e-9,
            "operand 1 moved: x=\(r1.x) w=\(r1.width)")
    #expect(r0.id == "op-back" && r1.id == "op-front",
            "the operands keep their own ids")
}

/// The nil-means-keep contract, at the live arm too: an edit that names only
/// `blendMode` must not reset `opacity` to a default on its way through.
@Test func withCommonOverALiveCompoundLeavesUnnamedFieldsAlone() {
    let cs = richCompound(.union)
    let onlyBlend = Element.live(.compoundShape(cs)).withCommon(blendMode: .screen)
    guard case .live(.compoundShape(let a)) = onlyBlend else {
        Issue.record("expected a compound shape back"); return
    }
    #expect(a.blendMode == .screen)
    #expect(a.opacity == cs.opacity, "an unnamed field must be kept, not defaulted")
    let onlyOpacity = Element.live(.compoundShape(cs)).withCommon(opacity: 0.75)
    guard case .live(.compoundShape(let b)) = onlyOpacity else {
        Issue.record("expected a compound shape back"); return
    }
    #expect(b.opacity == 0.75)
    #expect(b.blendMode == cs.blendMode, "an unnamed field must be kept, not defaulted")
    #expect(b.transform == cs.transform, "transform stays nil-means-keep as before")
}

// MARK: - `CompoundShape.expand` — §3.6's "Compound Shape EXPAND" row

/// THE FIELD VIOLATION (§3.1 / §3.2). `expand` hand-forwarded SIX of the nine
/// fields `CompoundShape` carries and dropped three: `id`, `blendMode` and
/// `mask`. A masked, multiplied compound expanded to rings that were neither
/// masked nor multiplied — the artwork changes on a verb whose whole job is to
/// freeze the artwork as it stands. Rust's twin passes the compound's entire
/// `common` through.
@Test func expandForwardsEveryFieldTheCompoundCarriesToEveryRing() {
    let cs = richCompound(.exclude)
    assertCompoundFixtureIsRich(cs)
    let expanded = cs.expand(precision: DEFAULT_PRECISION)
    #expect(expanded.count == 2, "XOR of two overlapping rects -> 2 rings")
    guard expanded.count == 2 else { return }
    // MANDATORY GEOMETRY PAIRING: XOR really is the two outer bars.
    var bars: [(Double, Double)] = []
    for (i, e) in expanded.enumerated() {
        guard case .polygon(let p) = e else {
            Issue.record("ring \(i) should be a polygon"); return
        }
        let (minX, _, maxX, _) = bbox(p.points)
        bars.append((minX, maxX))
        // Every non-identity field of the compound reaches every ring.
        #expect(p.fill == cs.fill, "ring \(i) lost the compound's fill")
        #expect(p.stroke == cs.stroke, "ring \(i) lost the compound's stroke")
        #expect(p.opacity == cs.opacity, "ring \(i) lost the compound's opacity")
        #expect(p.transform == cs.transform, "ring \(i) lost the compound's transform")
        #expect(p.locked == cs.locked, "ring \(i) lost the compound's locked")
        #expect(p.visibility == cs.visibility, "ring \(i) lost the compound's visibility")
        #expect(p.blendMode == cs.blendMode, "ring \(i) lost the compound's blend mode")
        #expect(p.mask == cs.mask, "ring \(i) lost the compound's mask")
    }
    bars.sort { $0.0 < $1.0 }
    #expect(abs(bars[0].0 - 0) < 1e-9 && abs(bars[0].1 - 5) < 1e-9,
            "left bar should span x 0..5, got \(bars[0])")
    #expect(abs(bars[1].0 - 10) < 1e-9 && abs(bars[1].1 - 15) < 1e-9,
            "right bar should span x 10..15, got \(bars[1])")
}

/// THE IDENTITY VIOLATION, the 1 -> 1 half. A compound that evaluates to ONE
/// ring is a 1 -> 1 edit: its identity is PRESERVABLE, so §3.1 preserves it —
/// killing a preservable identity is as much a guess as carrying one that is
/// not (the branch `pathEraseAtRect` and the DIVIDE arm already take, and the
/// branch Rust's `expand` now takes). `expand` dropped it unconditionally.
@Test func expandOfASingleRingCompoundKeepsItsIdentity() {
    let cs = richCompound(.union)
    assertCompoundFixtureIsRich(cs)
    let expanded = cs.expand(precision: DEFAULT_PRECISION)
    #expect(expanded.count == 1, "union of two overlapping rects -> 1 ring")
    guard case .polygon(let p) = expanded.first else {
        Issue.record("expected one polygon"); return
    }
    // MANDATORY GEOMETRY PAIRING: the ring is the merged bar [0..15].
    let (minX, _, maxX, _) = bbox(p.points)
    #expect(abs(minX - 0) < 1e-9 && abs(maxX - 15) < 1e-9,
            "union should span x 0..15, got \(minX)..\(maxX)")
    #expect(p.id == "cs-1",
            "a 1 -> 1 expansion preserves the identity it could keep, got \(String(describing: p.id))")
}

/// The OVER-REACH guard and the cardinality law's other side: two or more
/// rings is 1 -> N, identity DIES, and no ring may wear the compound's id.
///
/// STATED PLAINLY: this battery was GREEN BEFORE the repair as well, because
/// the pre-repair `expand` dropped `id` on every arm unconditionally. Its
/// expected value therefore coincided with the old output, so it is NOT
/// evidence of the repair — it is the guard that stops the 1 -> 1 branch from
/// over-reaching into the split arm. Its mutation proof runs in that direction
/// (see the commit message): widening the preserve to `>= 1` reds it.
@Test func expandOfASplitCompoundDoesNotReplicateItsId() {
    let cs = richCompound(.exclude)
    assertCompoundFixtureIsRich(cs)
    let expanded = cs.expand(precision: DEFAULT_PRECISION)
    #expect(expanded.count == 2, "XOR of two overlapping rects -> 2 rings")
    for (i, e) in expanded.enumerated() {
        guard case .polygon(let p) = e else {
            Issue.record("ring \(i) should be a polygon"); return
        }
        #expect(p.id == nil,
                "a 1 -> N expansion may not hand its identity to ring \(i); got \(String(describing: p.id))")
    }
}

/// The same two arms as DOCUMENT invariants, through the controller — the only
/// layer at which id UNIQUENESS is even expressible.
@Test func expandCompoundShapeAtTheDocumentPreservesOrKillsIdentityByArrow() {
    for (op, wantRings) in [(CompoundOperation.union, 1),
                            (CompoundOperation.exclude, 2)] {
        let cs = Element.live(.compoundShape(richCompound(op)))
        let layer = Layer(name: "L0", children: [cs])
        let doc = Document(layers: [layer], selection: [ElementSelection.all([0, 0])])
        let ctrl = Controller(model: Model(document: doc))
        ctrl.expandCompoundShape()
        let kids = ctrl.document.layers[0].children
        #expect(kids.count == wantRings, "\(op) -> \(wantRings) ring(s)")
        guard kids.count == wantRings else { continue }
        // MANDATORY GEOMETRY PAIRING at the document, not only at the value.
        var bars: [(Double, Double)] = []
        for (i, k) in kids.enumerated() {
            guard case .polygon(let p) = k else {
                Issue.record("child \(i) should be a polygon"); return
            }
            let (minX, _, maxX, _) = bbox(p.points)
            bars.append((minX, maxX))
        }
        bars.sort { $0.0 < $1.0 }
        if wantRings == 1 {
            #expect(abs(bars[0].0 - 0) < 1e-9 && abs(bars[0].1 - 15) < 1e-9,
                    "the union ring should span x 0..15, got \(bars[0])")
        } else {
            #expect(abs(bars[0].0 - 0) < 1e-9 && abs(bars[0].1 - 5) < 1e-9,
                    "left bar should span x 0..5, got \(bars[0])")
            #expect(abs(bars[1].0 - 10) < 1e-9 && abs(bars[1].1 - 15) < 1e-9,
                    "right bar should span x 10..15, got \(bars[1])")
        }
        // Identity, by the arrow.
        let ids = kids.map(\.id)
        if wantRings == 1 {
            #expect(ids == ["cs-1"],
                    "a 1 -> 1 expansion carries the compound's id, got \(ids)")
        } else {
            #expect(ids.allSatisfy { $0 == nil },
                    "a 1 -> N expansion leaves no ring wearing cs-1, got \(ids)")
        }
        // Uniqueness holds either way.
        var seen: Set<String> = []
        var dupes: [String] = []
        for id in ids.compactMap({ $0 }) where !seen.insert(id).inserted {
            dupes.append(id)
        }
        #expect(dupes.isEmpty, "expand left duplicate id(s): \(dupes)")
    }
}
