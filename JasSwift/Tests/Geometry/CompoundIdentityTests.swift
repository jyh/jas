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
