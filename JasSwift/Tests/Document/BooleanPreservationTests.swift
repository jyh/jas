import Testing
@testable import JasLib

/// EDIT_SEMANTICS_FREEZE.md §3.3 / §3.6 applied to
/// `Controller.applyDestructiveBoolean` — the Swift twin of Rust's
/// `preservation_law_tests` module in `jas_dioxus/src/document/controller.rs`.
///
/// What the Swift rebuild did before this battery, per the freeze's §3.5 row
/// ("Swift boolean rebuild, non-paint fields"): it wrote `locked` as a literal
/// `false` and dropped `name`, `id`, `toolOrigin` and `mask` at every arm. Two
/// distinct violations sat inside that one sentence:
///
///   * the N→1 arms (union / intersection / exclude) minted NOTHING, so a merge
///     of two identified operands produced an identity-less product — the same
///     clause Rust used to fail by the OPPOSITE route (it carried the frontmost
///     operand's id, "the frontmost source keeps the id", the rule JYH rejected
///     twice);
///   * the 1→1 survivor arms (subtract_front / subtract_back / crop / trim)
///     destroyed an identity the cardinality law says survives.
///
/// Plus a THIRD, structural one that no per-copy-API battery could ever reach
/// (§4.1): the insert site rebuilt the containing layer with an inline
/// `Layer(name:children:opacity:transform:)`, silently erasing that layer's
/// `id`, `mask`, `blendMode`, `visibility`, `isolatedBlending` and
/// `knockoutGroup` on every boolean op. That is the T4 bystander clause, and
/// `bystanderLayerSurvivesABooleanOp` below is its per-port inner loop; the
/// cross-port gate is the `boolean_union_merges_two_rects` vector of
/// test_fixtures/preservation/preservation_invariants.json.
///
/// METHOD, per §3.1's three mandatory requirements:
///   * the ANTI-VACUITY guard — `assertFixtureIsRich` asserts every fixture
///     differs from a fresh element's default in every legislated field, so a
///     fixture that decayed to defaults could not pass on nothing;
///   * the MANDATORY GEOMETRY PAIRING — at least one assertion per arm on where
///     the result's geometry actually landed, because a field-only battery
///     cannot tell a working op from one that returned its input;
///   * id FRESHNESS, not a literal id: the product's id must be absent from the
///     pre-edit id set.

// MARK: - Fixtures

private func aMask() -> Mask {
    Mask(subtreeElement: .rect(Rect(x: 0, y: 0, width: 4, height: 4)),
         clip: false, invert: false, disabled: false, linked: true,
         unlinkTransform: nil)
}

/// A rect whose non-paint fields differ from the default in every field the
/// preservation law legislates AND that Swift's `Rect` can express.
///
/// NOT expressible here: `toolOrigin`. Rust carries it on `CommonProps` for all
/// eleven kinds; in Swift it is a stored property of `Path` alone (§3.5's
/// cross-port field-vocabulary note). `unanimousToolOriginCarriesOnAPathResult`
/// below probes it on the one Swift output kind that can hold it.
private func richRect(x: Double, w: Double, id: String,
                      name: String?, opacity: Double) -> Element {
    .rect(Rect(x: x, y: 0, width: w, height: 10,
               fill: Fill(color: Color(r: 0, g: 0, b: 0)),
               stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 2),
               opacity: opacity,
               transform: nil,
               locked: true,
               visibility: .outline,
               blendMode: .multiply,
               mask: aMask(),
               name: name, id: id))
}

/// §3.1(i), mandatory: a fixture sitting at its default is a field whose loss
/// the batteries cannot see.
private func assertFixtureIsRich(_ e: Element) {
    let d = Rect(x: 0, y: 0, width: 1, height: 1)
    #expect(e.opacity != d.opacity, "fixture opacity decayed to default")
    #expect(e.blendMode != d.blendMode, "fixture blend mode decayed to default")
    #expect(e.visibility != d.visibility, "fixture visibility decayed to default")
    #expect(e.isLocked != d.locked, "fixture locked decayed to default")
    #expect(e.mask != nil, "fixture mask decayed to default")
    #expect(e.id != nil, "fixture must carry an id")
}

/// Two overlapping rich rects, back-to-front, both selected, inside a layer
/// that is itself attribute-rich — the T4 bystander the op must rebuild to
/// reach its target.
private func richPair(backName: String?, frontName: String?,
                      backOpacity: Double, frontOpacity: Double) -> Model {
    let back = richRect(x: 0, w: 10, id: "id-back", name: backName,
                        opacity: backOpacity)
    let front = richRect(x: 5, w: 10, id: "id-front", name: frontName,
                         opacity: frontOpacity)
    assertFixtureIsRich(back)
    assertFixtureIsRich(front)
    let layer = Layer(name: "L0", children: [back, front],
                      opacity: 0.7, transform: nil,
                      locked: true, visibility: .outline, blendMode: .multiply,
                      isolatedBlending: true, knockoutGroup: true,
                      mask: aMask(), id: "lyr-0")
    let doc = Document(layers: [layer], selectedLayer: 0,
                       selection: [ElementSelection.all([0, 0]),
                                   ElementSelection.all([0, 1])])
    return Model(document: doc)
}

private func onlyChild(_ model: Model) -> Element {
    let children = model.document.layers[0].children
    #expect(children.count == 1, "expected exactly one output element")
    return children[0]
}

/// The bbox of a Polygon's POINTS — the geometry the op produced, unaffected by
/// the stroke width `Element.bounds` inflates by.
private func polygonPointBBox(_ e: Element) -> (Double, Double, Double, Double) {
    guard case .polygon(let p) = e else {
        Issue.record("expected a Polygon, got \(e)")
        return (0, 0, 0, 0)
    }
    let xs = p.points.map(\.0), ys = p.points.map(\.1)
    return (xs.min()!, ys.min()!, xs.max()! - xs.min()!, ys.max()! - ys.min()!)
}

// MARK: - §3.3 / the cardinality law: the N→1 boolean arm

/// Identity is preservable exactly when the edit is 1→1. A union is N→1, so the
/// product wears an id that belonged to NEITHER operand — and it does wear one,
/// because an identity WAS at stake.
@Test func booleanUnionMintsAnIdThatWasNoOperands() {
    let m = richPair(backName: nil, frontName: nil,
                     backOpacity: 0.5, frontOpacity: 0.5)
    let before = m.document.elementIds
    Controller(model: m).applyDestructiveBoolean("union")
    let out = onlyChild(m)
    // MANDATORY GEOMETRY PAIRING: the union really is the [0..15] bar.
    let (bx, by, bw, bh) = polygonPointBBox(out)
    #expect(abs(bx) < 1e-9 && abs(by) < 1e-9
            && abs(bw - 15) < 1e-9 && abs(bh - 10) < 1e-9,
            "union bbox should be [0..15]x[0..10], got \(bx),\(by),\(bw),\(bh)")
    #expect(out.id != nil,
            "an N→1 merge mints a fresh id; it does not leave the product identity-less")
    #expect(out.id != "id-front",
            "the frontmost operand's id survived an N→1 merge — the rule JYH rejected twice")
    #expect(out.id != "id-back", "the backmost operand's id survived an N→1 merge")
    // FRESHNESS is the pinned property, not a literal id.
    #expect(!before.contains(out.id ?? ""),
            "the merge product's id must be absent from the pre-edit id set")
}

/// Uniqueness (REFERENCE_GRAPH.md §2.5): whatever the merge mints must not
/// collide with an id still live in the document.
@Test func booleanUnionMintedIdAvoidsLiveIds() {
    let m = richPair(backName: nil, frontName: nil,
                     backOpacity: 0.5, frontOpacity: 0.5)
    Controller(model: m).applyDestructiveBoolean("union")
    let ids = m.document.elementIds
    let out = onlyChild(m)
    #expect(ids.contains(out.id ?? ""))
    // The layer keeps its own id, so exactly two live: the layer and the product.
    #expect(ids.count == 2, "no stale operand id may linger")
}

/// Identity in this app is LAZY: an element is born id-less. A merge of id-less
/// operands kills nothing, so nothing is minted and the product takes the fresh
/// element's documented default. Rust's arm is guarded identically.
@Test func booleanUnionOfIdlessOperandsMintsNothing() {
    let back = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let front = Element.rect(Rect(x: 5, y: 0, width: 10, height: 10))
    let doc = Document(layers: [Layer(children: [back, front])],
                       selectedLayer: 0,
                       selection: [ElementSelection.all([0, 0]),
                                   ElementSelection.all([0, 1])])
    let m = Model(document: doc)
    Controller(model: m).applyDestructiveBoolean("union")
    let out = onlyChild(m)
    let (_, _, bw, _) = polygonPointBBox(out)
    #expect(abs(bw - 15) < 1e-9, "union width should be 15, got \(bw)")
    #expect(out.id == nil,
            "no identity was at stake, so none dies and none is minted")
}

/// §3.3: a field the op does not speak to follows UNANIMITY. `mask`,
/// `visibility` and `locked` agree across both operands here, so they carry —
/// no winner is elected, the value is simply well-defined.
@Test func booleanUnionCarriesUnanimousNonPaintFields() {
    let m = richPair(backName: nil, frontName: nil,
                     backOpacity: 0.5, frontOpacity: 0.5)
    Controller(model: m).applyDestructiveBoolean("union")
    let out = onlyChild(m)
    #expect(out.mask == aMask(), "a unanimous mask is preservation, not a guess")
    #expect(out.visibility == .outline, "a unanimous visibility carries")
    #expect(out.isLocked == true, "a unanimous locked flag carries")
}

/// §3.3: sources DISAGREE, so the fresh element's documented default stands.
/// Nothing geometric elects a winner.
@Test func booleanUnionDisagreeingFieldFallsToTheDefault() {
    let m = richPair(backName: nil, frontName: nil,
                     backOpacity: 0.5, frontOpacity: 0.5)
    // Make the back operand disagree on visibility only.
    let back = m.document.getElement([0, 0]).withVisibility(.invisible)
    m.editDocument(m.document.replaceElement([0, 0], with: back))
    Controller(model: m).applyDestructiveBoolean("union")
    let out = onlyChild(m)
    #expect(out.visibility == Rect(x: 0, y: 0, width: 1, height: 1).visibility,
            "disagreeing sources must fall to the default, never elect the frontmost")
}

/// RATIFIED ANSWER (1), ASSERTING-SOURCES: a source that asserts a name carries
/// it; a silent source does not veto. "hull" + unnamed → "hull".
@Test func booleanUnionNameCarriesFromTheOnlyAssertingSource() {
    let m = richPair(backName: "hull", frontName: nil,
                     backOpacity: 0.5, frontOpacity: 0.5)
    Controller(model: m).applyDestructiveBoolean("union")
    #expect(onlyChild(m).name == "hull",
            "the only name asserted must survive the merge")
}

/// ASSERTING-SOURCES, the other direction: two sources both assert and they
/// disagree, so the name dies. No winner by z-order.
@Test func booleanUnionNameDiesWhenAssertingSourcesDisagree() {
    let m = richPair(backName: "hull", frontName: "keel",
                     backOpacity: 0.5, frontOpacity: 0.5)
    Controller(model: m).applyDestructiveBoolean("union")
    #expect(onlyChild(m).name == nil,
            "two asserted names disagree → the default, not the frontmost's word")
}

/// The ratified BOOLEAN.md paint rule is FOUR properties — fill, stroke,
/// opacity, blend mode — from the frontmost operand. That rule is what the op
/// SPEAKS TO (T1), so it survives the identity repair. Disagreeing opacities
/// prove it is the frontmost's value and not a unanimity accident.
@Test func booleanUnionStillTakesTheFrontmostsFourPaintProperties() {
    let m = richPair(backName: nil, frontName: nil,
                     backOpacity: 0.25, frontOpacity: 0.75)
    Controller(model: m).applyDestructiveBoolean("union")
    let out = onlyChild(m)
    #expect(out.opacity == 0.75,
            "opacity is paint: the frontmost operand's, per BOOLEAN.md")
    #expect(out.blendMode == .multiply)
    #expect(out.fill != nil)
    #expect(out.stroke != nil)
}

/// T6 CAPABILITY MARKERS on the one Swift output kind that can hold one. A
/// multi-ring result emits a Path, and Path is the only Swift struct with a
/// `toolOrigin` stored property, so a unanimous marker carries there. The
/// single-ring (Polygon) arm CANNOT hold it in this port — §3.5's cross-port
/// field-vocabulary divergence, named there as a scheduled defect, not fixable
/// from inside `applyDestructiveBoolean`.
@Test func unanimousToolOriginCarriesOnAPathResult() {
    func blobPath(_ x: Double) -> Element {
        .path(Path(d: [.moveTo(x, 0), .lineTo(x + 10, 0),
                       .lineTo(x + 10, 10), .lineTo(x, 10), .closePath],
                   fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                   toolOrigin: "blob_brush", fillRule: .nonzero))
    }
    let doc = Document(layers: [Layer(children: [blobPath(0), blobPath(5)])],
                       selectedLayer: 0,
                       selection: [ElementSelection.all([0, 0]),
                                   ElementSelection.all([0, 1])])
    let m = Model(document: doc)
    // EXCLUDE of two overlapping rects is one outer ring plus an inner ring, so
    // the result is a Path — the multi-ring arm.
    Controller(model: m).applyDestructiveBoolean("exclude")
    guard case .path(let p) = onlyChild(m) else {
        Issue.record("expected a multi-ring Path result")
        return
    }
    // GEOMETRY PAIRING: two subpaths, i.e. the hole survived.
    #expect(p.d.filter { if case .moveTo = $0 { return true }; return false }.count == 2,
            "expected two rings (outer + hole)")
    #expect(p.toolOrigin == "blob_brush",
            "a unanimous capability marker carries (T6)")
}

// MARK: - §3.6: the 1→1 survivor arms

/// A SUBTRACT_FRONT survivor is 1→1, so its identity LIVES. The N→1 repair must
/// not leak into the survivor arms — and the pre-existing drop must not survive
/// there either.
@Test func booleanSubtractFrontSurvivorKeepsItsOwnIdentity() {
    let m = richPair(backName: "hull", frontName: "keel",
                     backOpacity: 0.25, frontOpacity: 0.75)
    Controller(model: m).applyDestructiveBoolean("subtract_front")
    let out = onlyChild(m)
    let (bx, _, bw, _) = polygonPointBBox(out)
    #expect(abs(bx) < 1e-9 && abs(bw - 5) < 1e-9,
            "subtract_front leaves [0..5], got x=\(bx) w=\(bw)")
    #expect(out.id == "id-back", "a 1→1 survivor keeps its id")
    #expect(out.name == "hull", "a 1→1 survivor keeps its name")
    #expect(out.opacity == 0.25, "and its own paint")
    #expect(out.isLocked == true, "and its own lock state — not a literal false")
    #expect(out.mask == aMask(), "and its own mask")
}

// MARK: - T4: the bystander clause at the insert site

/// The op rebuilds the containing layer to insert its result. The layer names
/// no part of this edit, so every one of ITS fields comes back unchanged. The
/// inline `Layer(name:children:opacity:transform:)` this replaced kept four of
/// eleven — an inline container rebuild is not a copy API, which is exactly why
/// §4.1 makes the document-level invariant the primary gate.
@Test func bystanderLayerSurvivesABooleanOp() {
    let m = richPair(backName: nil, frontName: nil,
                     backOpacity: 0.5, frontOpacity: 0.5)
    let before = m.document.layers[0]
    Controller(model: m).applyDestructiveBoolean("union")
    let after = m.document.layers[0]
    // GEOMETRY PAIRING: the op really ran.
    #expect(after.children.count == 1, "expected the union product")
    #expect(after.id == before.id, "the layer's id must survive")
    #expect(after.name == before.name, "the layer's name must survive")
    #expect(after.opacity == before.opacity)
    #expect(after.locked == before.locked)
    #expect(after.visibility == before.visibility)
    #expect(after.blendMode == before.blendMode)
    #expect(after.isolatedBlending == before.isolatedBlending)
    #expect(after.knockoutGroup == before.knockoutGroup)
    #expect(after.mask == before.mask)
    // The whole container, one predicate: only `children` may differ.
    #expect(before.withChildren(after.children) == after,
            "the boolean's layer rebuild changed a field other than children")
}

// MARK: - Multi-member container operands (BOOLEAN.md:63, the MEMBERS vote)

/// A container holding TWO members that disagree, wrapped around the front
/// operand. The single-member wrapper the cross-language relation seeds with
/// (`wrap_at`) cannot express this, which is why the divergences below survived
/// a gate that was otherwise watching this exact seam.
private func twoMemberFrontOperand(aName: String?, bName: String?,
                                   aLocked: Bool, bLocked: Bool) -> Element {
    let a = Element.rect(Rect(x: 5, y: 0, width: 10, height: 10,
                              fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                              locked: aLocked, name: aName, id: nil))
    let b = Element.rect(Rect(x: 7, y: 0, width: 10, height: 10,
                              fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                              locked: bLocked, name: bName, id: nil))
    return .group(Group(children: [a, b]))
}

private func twoMemberModel(aName: String?, bName: String?,
                            aLocked: Bool, bLocked: Bool) -> Model {
    let back = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                 fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                                 locked: true, name: nil, id: nil))
    let front = twoMemberFrontOperand(aName: aName, bName: bName,
                                      aLocked: aLocked, bLocked: bLocked)
    let layer = Layer(name: "L0", children: [back, front])
    return Model(document: Document(layers: [layer], selectedLayer: 0,
                                    selection: [ElementSelection.all([0, 0]),
                                                ElementSelection.all([0, 1])]))
}

/// BOOLEAN.md:63 — "the operands' MEMBERS vote". MEMBERS, plural.
///
/// This port took ONE voter per operand (`booleanPaintSource`, the FIRST
/// paintable leaf), which is the right answer to a DIFFERENT question: fill and
/// stroke resolve to the frontmost operand's first paintable leaf, because a
/// container has no paint of its own. The electorate is not the paint source,
/// and collapsing the two disenfranchises every member after the first.
///
/// Measured before the repair: a two-member group whose members disagree on
/// `locked` reported a UNANIMOUS `locked = true`, because the dissenting member
/// never got a vote. Rust, which flat-maps `operand_leaves` over every operand,
/// reported the disagreement and fell to the default.
@Test func aMultiMemberContainersMembersAllVoteOnUnanimity() {
    let m = twoMemberModel(aName: nil, bName: nil, aLocked: true, bLocked: false)
    Controller(model: m).applyDestructiveBoolean("union")
    let out = onlyChild(m)
    #expect(out.isLocked == false,
            "member b is unlocked, so the sources disagree and the default stands")
}

/// The same electorate, on `name`. Two members that both ASSERT a name and
/// disagree must kill the name (§3.3); this port saw only the first, read it as
/// the sole asserting source, and carried it onto the product.
@Test func twoMembersAssertingDifferentNamesKillTheName() {
    let m = twoMemberModel(aName: "a", bName: "b", aLocked: true, bLocked: true)
    Controller(model: m).applyDestructiveBoolean("union")
    let out = onlyChild(m)
    #expect(out.name == nil,
            "two asserting members disagree, so the name dies")
}

/// The mint guard asks what the edit DESTROYS, and a container is destroyed
/// along with everything it holds. An id-less container whose LEAF carries an
/// id therefore has an identity at stake.
///
/// This port read `elements` only — the operands, not their members — so a
/// group with an identified leaf minted nothing and the identity died silently.
/// Rust reads `elements.chain(sources)`. The comment beside this port's guard
/// claimed "Rust's arm is guarded identically"; it was not.
@Test func anIdentifiedLeafInsideAnIdlessContainerIsAnIdentityAtStake() {
    let a = Element.rect(Rect(x: 5, y: 0, width: 10, height: 10,
                              fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                              name: nil, id: "leaf-identity"))
    let front = Element.group(Group(children: [a]))
    let back = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                 fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                                 name: nil, id: nil))
    let layer = Layer(name: "L0", children: [back, front])
    let m = Model(document: Document(layers: [layer], selectedLayer: 0,
                                     selection: [ElementSelection.all([0, 0]),
                                                 ElementSelection.all([0, 1])]))
    Controller(model: m).applyDestructiveBoolean("union")
    let out = onlyChild(m)
    #expect(out.id != nil,
            "the leaf's identity is destroyed, so one is at stake and a fresh id is minted")
    #expect(out.id != "leaf-identity",
            "the dead id is never re-worn; a fresh one is minted")
}

/// The 1 -> 1 SURVIVOR arms, where the divergence hid behind the same
/// single-member assumption. Twin of Rust's `source_common`.
///
/// subtract-front keeps the back operand. When that survivor is a container
/// holding TWO members with different names and ids, no one member is entitled
/// to speak for the rest: Rust merges over all leaves and kills both, this port
/// took the first leaf's and carried them onto the product. With a one-member
/// wrapper the two agree exactly, which is why the corpus never saw it.
@Test func aMultiMemberSurvivorElectsNoSingleMembersIdentity() {
    let a = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                              fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                              name: "member-a", id: "id-a"))
    let b = Element.rect(Rect(x: 2, y: 0, width: 10, height: 10,
                              fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                              name: "member-b", id: "id-b"))
    let survivor = Element.group(Group(children: [a, b]))
    let cutter = Element.rect(Rect(x: 20, y: 0, width: 4, height: 4,
                                   fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                                   name: nil, id: nil))
    let layer = Layer(name: "L0", children: [survivor, cutter])
    let m = Model(document: Document(layers: [layer], selectedLayer: 0,
                                     selection: [ElementSelection.all([0, 0]),
                                                 ElementSelection.all([0, 1])]))
    Controller(model: m).applyDestructiveBoolean("subtract_front")
    let out = m.document.layers[0].children[0]
    #expect(out.name == nil,
            "two members assert different names, so no name survives")
    #expect(out.id != "id-a" && out.id != "id-b",
            "no single member's identity is elected to speak for the container")
}

/// THE RELATION THE CORPUS CANNOT STATE, and the one that would have caught
/// every divergence above at the moment it was written.
///
/// `wrap_at` in the cross-language relation wraps exactly ONE leaf, because the
/// property it serves — an operation on a group equals the same operation on
/// its member — is only true for one. There is no single-member document in
/// which a two-member electorate can disagree, so the entire multi-member class
/// is invisible to that gate by construction. It is not a gap in the corpus; it
/// is outside what that relation can express.
///
/// The multi-member generalisation is: GROUPING A CONTIGUOUS RUN OF OPERANDS
/// DOES NOT CHANGE THE RESULT. That follows from the container ruling — a
/// selected group is shorthand for its members — and it is checkable without
/// the action corpus, because it needs only the controller called twice.
///
/// SCOPED DELIBERATELY TO THE BACK RUN. Fill, stroke, opacity and blend mode all
/// resolve through the FRONTMOST operand's first paintable leaf. Wrapping the
/// frontmost operand changes which leaf that is — `group{b, c}` answers with
/// `b` where bare `c` answers with `c` — so the relation is false there and
/// saying so is not a cop-out. Wrapping the back run leaves the frontmost
/// operand untouched and the relation exact.
@Test func groupingTheBackOperandsDoesNotChangeTheBooleanResult() {
    func rect(_ x: Double, _ name: String?, _ id: String?, locked: Bool) -> Element {
        .rect(Rect(x: x, y: 0, width: 10, height: 10,
                   fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                   locked: locked, name: name, id: id))
    }
    // Two back operands that DISAGREE, so a lost vote is visible, plus a
    // frontmost operand left bare in both arms.
    func build(grouped: Bool) -> Model {
        let a = rect(0, "aye", "id-a", locked: true)
        let b = rect(2, "bee", nil, locked: false)
        let c = rect(4, nil, nil, locked: true)
        let children: [Element] = grouped
            ? [.group(Group(children: [a, b])), c]
            : [a, b, c]
        let sel = (0..<children.count).map { ElementSelection.all([0, $0]) }
        return Model(document: Document(layers: [Layer(name: "L0", children: children)],
                                        selectedLayer: 0, selection: sel))
    }
    for op in ["union", "intersection", "exclude"] {
        let g = build(grouped: true), u = build(grouped: false)
        Controller(model: g).applyDestructiveBoolean(op)
        Controller(model: u).applyDestructiveBoolean(op)
        let go = onlyChild(g), uo = onlyChild(u)
        #expect(go.name == uo.name, "\(op): grouping the back run moved `name`")
        #expect(go.isLocked == uo.isLocked, "\(op): grouping moved `locked`")
        #expect(go.visibility == uo.visibility, "\(op): grouping moved `visibility`")
        #expect(go.blendMode == uo.blendMode, "\(op): grouping moved `blendMode`")
        #expect((go.id == nil) == (uo.id == nil),
                "\(op): grouping moved whether an identity was at stake")
    }
}
