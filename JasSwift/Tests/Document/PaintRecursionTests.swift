import Testing
@testable import JasLib

/// FILL AND STROKE RECURSE INTO A SELECTED CONTAINER. RULED 2026-07-29.
///
/// Selecting a group and clicking a swatch did NOTHING to its members. Driven
/// at council: both children came back with `fill == nil`. Both ports handled
/// containers EXPLICITLY (`case .group, .layer:` here, `Group(_) | Layer(_) =>`
/// in Rust), so nobody forgot — someone decided a container has no fill of its
/// own. True of the data model, false of the artist's intent.
///
/// Rust hid it behind `doc.set_selection`'s container expansion, which put the
/// MEMBERS in the selection so they got filled. JasSwift does not expand, so
/// there it was live; and §20 would have carried it into Rust.
///
/// Twin: Rust `fill_and_stroke_recurse_into_a_selected_container`.
@Suite("Paint recurses into containers")
struct PaintRecursionTests {

    private func rect(_ x: Double) -> Element {
        .rect(Rect(x: x, y: 0, width: 10, height: 10))
    }

    private func nestedModel() -> Model {
        // A group holding a leaf AND a nested group, so recursion is exercised
        // at two depths. Both containers carry ids, so the T4 bystander clause
        // is checked on the rebuild.
        let inner = Element.group(Group(children: [rect(40)], id: "inner"))
        let outer = Element.group(Group(children: [rect(0), inner], id: "outer"))
        let doc = Document(layers: [Layer(name: "L", children: [outer])])
        return Model(document: doc.replacing(selection: [ElementSelection.all([0, 0])]))
    }

    private func fills(_ model: Model) -> [Fill?] {
        guard case .group(let g) = model.document.getElement([0, 0]) else { return [] }
        var out: [Fill?] = []
        func walk(_ e: Element) {
            switch e {
            case .group(let gg): gg.children.forEach(walk)
            case .rect(let r): out.append(r.fill)
            default: break
            }
        }
        g.children.forEach(walk)
        return out
    }

    @Test func fillReachesEveryMemberAtEveryDepth() {
        let model = nestedModel()
        Controller(model: model).setSelectionFill(Fill(color: Color(r: 1, g: 0, b: 0, a: 1)))
        let f = fills(model)
        #expect(f.count == 2, "two leaves under the selected group; found \(f.count)")
        #expect(f.allSatisfy { $0 != nil },
                "every leaf is filled, including the one two levels down")
    }

    @Test func strokeReachesEveryMemberAtEveryDepth() {
        let model = nestedModel()
        Controller(model: model).setSelectionStroke(Stroke(color: Color(r: 0, g: 0, b: 1, a: 1), width: 3))
        guard case .group(let g) = model.document.getElement([0, 0]) else {
            Issue.record("not a group"); return
        }
        guard case .rect(let direct) = g.children[0] else {
            Issue.record("child 0 not a rect"); return
        }
        #expect(direct.stroke != nil, "the direct member is stroked")
        guard case .group(let ig) = g.children[1], case .rect(let deep) = ig.children[0] else {
            Issue.record("nested member missing"); return
        }
        #expect(deep.stroke != nil, "the member two levels down is stroked")
    }

    /// A BRUSH is stroke styling, so it recurses too. Found by the
    /// element-dispatch enumeration rather than by a report:
    /// `setSelectionStrokeBrush` looped the selection and `withStrokeBrush`
    /// returned a container unchanged, so applying a brush to a selected group
    /// did nothing — the same shape as fill and stroke, one ruling behind.
    @Test func aBrushReachesEveryMemberAtEveryDepth() {
        // A brush applies to Path/Line/Polyline only — a Rect carries no
        // stroke brush by design (`with_stroke_brush`), so the fixture uses
        // LINES. The first draft used the shared rect model and failed for
        // that reason: the fixture was wrong, not the code.
        let inner = Element.group(Group(children: [
            .line(Line(x1: 40, y1: 0, x2: 50, y2: 10))], id: "inner"))
        let outer = Element.group(Group(children: [
            .line(Line(x1: 0, y1: 0, x2: 10, y2: 10)), inner], id: "outer"))
        let doc = Document(layers: [Layer(name: "L", children: [outer])])
        let model = Model(document: doc.replacing(
            selection: [ElementSelection.all([0, 0])]))
        Controller(model: model).setSelectionStrokeBrush("charcoal")
        guard case .group(let g) = model.document.getElement([0, 0]) else {
            Issue.record("not a group"); return
        }
        // A brush PROMOTES a stroke-carrying leaf to a Path, so assert on the
        // brush slug rather than on the kind that carries it.
        var slugs: [String?] = []
        func walk(_ e: Element) {
            switch e {
            case .group(let gg): gg.children.forEach(walk)
            case .path(let p): slugs.append(p.strokeBrush)
            case .rect, .line, .polyline: slugs.append(nil)  // unpromoted = no brush
            default: break
            }
        }
        g.children.forEach(walk)
        #expect(slugs.count == 2, "two leaves under the selected group; found \(slugs.count)")
        #expect(slugs.allSatisfy { $0 == "charcoal" },
                "every leaf carries the brush, including the one two levels down; got \(slugs)")
    }

    /// THE RECOLOUR PATH — the one the COLOR PANEL actually uses.
    ///
    /// Found by JYH clicking a swatch with a group selected, 2026-07-29:
    /// nothing happened. `setSelectionFill` STAMPS one identical fill and was
    /// routed through mapPaintable; `mapSelectionFill` RECOLOURS each element's
    /// own fill so per-element opacity survives, and was not. The Color panel's
    /// `applyActiveColorWrite` calls the second one.
    ///
    /// The whole suite above passed with this broken, which is the lesson: the
    /// tests exercised the path that was fixed, not the path the app uses.
    ///
    /// The closure must read the LEAF's own paint — a container's is nil, so
    /// even the input was wrong before.
    @Test func theRecolourPathReachesEveryMemberAndKeepsTheirOpacity() {
        // Members with DIFFERENT fill opacities, so "recolour, preserve
        // opacity" is distinguishable from "stamp one value".
        let a = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                  fill: Fill(color: Color(r: 1, g: 0, b: 0, a: 1), opacity: 0.25)))
        let b = Element.rect(Rect(x: 20, y: 0, width: 10, height: 10,
                                  fill: Fill(color: Color(r: 0, g: 0, b: 1, a: 1), opacity: 0.75)))
        let doc = Document(layers: [Layer(name: "L", children: [
            .group(Group(children: [a, b])),
        ])])
        let model = Model(document: doc.replacing(
            selection: [ElementSelection.all([0, 0])]))
        let green = Color(r: 0, g: 1, b: 0, a: 1)
        Controller(model: model).mapSelectionFill { old in
            old.map { Fill(color: green, opacity: $0.opacity) }
        }

        guard case .group(let g) = model.document.getElement([0, 0]),
              case .rect(let ra) = g.children[0], case .rect(let rb) = g.children[1] else {
            Issue.record("expected a Group of two Rects"); return
        }
        #expect(ra.fill?.color == green && rb.fill?.color == green,
                "both members are recoloured")
        #expect(ra.fill?.opacity == 0.25 && rb.fill?.opacity == 0.75,
                "and each KEEPS ITS OWN opacity — got \(ra.fill?.opacity ?? -1) and \(rb.fill?.opacity ?? -1)")
    }

    /// T4 BYSTANDER: the walk REBUILDS every container it passes through, so a
    /// container's own fields must survive. Rebuilding by re-listing fields is
    /// the Swift copy-site omission class — it would drop `id` and `mask` on
    /// every swatch click. `withChildren` is what prevents that.
    @Test func containersKeepTheirOwnFieldsThroughTheWalk() {
        let model = nestedModel()
        Controller(model: model).setSelectionFill(Fill(color: Color(r: 1, g: 0, b: 0, a: 1)))
        guard case .group(let g) = model.document.getElement([0, 0]) else {
            Issue.record("not a group"); return
        }
        #expect(g.id == "outer", "the rebuilt container keeps its id; got \(g.id ?? "nil")")
        guard case .group(let ig) = g.children[1] else {
            Issue.record("nested group missing"); return
        }
        #expect(ig.id == "inner", "the nested container keeps ITS id; got \(ig.id ?? "nil")")
    }
}

/// A BOOLEAN OVER A CONTAINER OPERAND PAINTS ITS RESULT.
///
/// BOTH HALVES OF THE SPEC ARE SETTLED, so the implementation had no room to
/// decline: BOOLEAN.md §Operand rules — *"operands can be paths, GROUPS, text,
/// or nested LiveElements"* — makes a group a legitimate operand, and
/// BOOLEAN.md §Operand and paint rules — *"all operands are consumed. The
/// result is a single path, painted with the FRONTMOST OPERAND'S fill, stroke,
/// opacity, and blend mode"* — says what it wears. Select a group and a shape,
/// click Union, and the result came out UNPAINTED, UNSTROKED, and wearing the
/// container's name: `Element.fill` / `Element.stroke` answer `nil` for a
/// container (rightly — a group carries no paint of its own), and the boolean
/// seam read them raw.
///
/// The repair is the one this repo already built for exactly this shape:
/// `forEachPaintable`'s ruling that *a selected CONTAINER speaks for its
/// members, at any depth*, so "the frontmost operand's fill" resolves to THE
/// FRONTMOST OPERAND'S FIRST PAINTABLE LEAF — the same resolution
/// `selectionStrokeForPanel` makes for the Weight field. `fill`/`stroke`
/// themselves are NOT widened; they are read at render, hit-test and panel
/// seams where a container answering with a member's paint would be wrong.
///
/// FILL AND STROKE TOGETHER. They are the same defect written twice, one line
/// apart, at every one of the six container-reading sites; repairing only
/// `fill` leaves an operation that looks fixed in a screenshot.
///
/// This is the corpus-wide container-seeding relation
/// (`anOperationOnAGroupEqualsTheSameOperationOnItsMember`) stated directly:
/// `op(group[leaf], …) == op(leaf, …)`. That harness carried the four
/// `boolean.json` rows as KNOWN disagreements; they are deleted with this fix.
@Suite("Boolean paint over a container operand")
struct BooleanContainerPaintTests {

    private static let red = Color(r: 1, g: 0, b: 0, a: 1)
    private static let blue = Color(r: 0, g: 0, b: 1, a: 1)

    private func leaf(_ x: Double, _ color: Color, _ width: Double) -> Element {
        .rect(Rect(x: x, y: 0, width: 100, height: 100,
                   fill: Fill(color: color),
                   stroke: Stroke(color: color, width: width)))
    }

    /// The same two operands in both spellings: bare leaves, and each leaf
    /// alone inside a group. The two wrappers share ONE name deliberately —
    /// asserting-sources unanimity read over the CONTAINERS carries that name
    /// onto the product, which is the "wearing the container's name" half of
    /// the defect and is invisible if the wrappers disagree.
    private func model(wrapped: Bool) -> Model {
        let a = leaf(0, Self.red, 2)
        let b = leaf(50, Self.blue, 7)
        let kids: [Element] = wrapped
            ? [.group(Group(children: [a], name: "wrap")),
               .group(Group(children: [b], name: "wrap"))]
            : [a, b]
        let doc = Document(layers: [Layer(name: "L", children: kids)])
        return Model(document: doc.replacing(selection: [
            ElementSelection.all([0, 0]), ElementSelection.all([0, 1]),
        ]))
    }

    private func destructive(_ op: String, wrapped: Bool) -> Element {
        let m = model(wrapped: wrapped)
        Controller(model: m).applyDestructiveBoolean(op)
        return m.document.getElement([0, 0])
    }

    /// One paint triple per result, so a mismatch names the field.
    private func paint(_ e: Element) -> String {
        "fill=\(e.fill.map { "\($0.color)" } ?? "nil") "
            + "stroke=\(e.stroke.map { "\($0.color)@\($0.width)" } ?? "nil") "
            + "name=\(e.name ?? "nil")"
    }

    /// THE RELATION, over every op whose KNOWN row this fix retires. Written as
    /// an equality against the bare-leaf spelling rather than against literals:
    /// a fix that painted the container case with something *else* would pass a
    /// literal assertion for `fill` alone.
    @Test func aBooleanOverAGroupWrappedOperandMatchesTheBareLeaf() {
        for op in ["union", "subtract_front", "intersection", "exclude"] {
            let bare = destructive(op, wrapped: false)
            let viaGroup = destructive(op, wrapped: true)
            #expect(paint(bare) == paint(viaGroup),
                    "\(op): bare [\(paint(bare))] vs grouped [\(paint(viaGroup))]")
        }
    }

    /// MANDATORY GEOMETRY PAIRING (§3.1): a paint-only battery cannot tell a
    /// working op from one that returned its input, and the container arm is
    /// exactly where a rewrite could quietly swap the operand for its leaf and
    /// lose the other members' area. The union of x∈[0,100] and x∈[50,150] must
    /// still span the full 150.
    @Test func theContainerArmStillUnionsTheWholeOperand() {
        guard case .polygon(let p) = destructive("union", wrapped: true) else {
            Issue.record("union of two overlapping rects is a single-ring polygon")
            return
        }
        #expect(p.points.map(\.0).max() == 150,
                "the grouped union spans both operands; got \(p.points)")
    }

    /// The frontmost operand is the LAST in path order — [0,1], the blue one —
    /// so a fix that resolved the BACKMOST container would pass the equality
    /// above only by breaking the bare case too.
    @Test func theResolvedPaintIsTheFrontmostOperandsAndNotTheBackmosts() {
        let e = destructive("union", wrapped: true)
        #expect(e.fill?.color == Self.blue, "got \(e.fill?.color as Any)")
        #expect(e.stroke?.width == 7, "got \(e.stroke?.width as Any)")
        #expect(e.name == nil,
                "the product does not wear the container's name; got \(e.name ?? "nil")")
    }

    /// SUBTRACT_FRONT's survivor keeps ITS OWN paint (BOOLEAN.md), so the
    /// resolution has to happen per-survivor, not once for the frontmost.
    @Test func aSurvivorResolvesItsOwnPaint() {
        let e = destructive("subtract_front", wrapped: true)
        #expect(e.fill?.color == Self.red, "the survivor is the red one; got \(e.fill?.color as Any)")
        #expect(e.stroke?.width == 2, "and its own weight; got \(e.stroke?.width as Any)")
    }

    /// The LIVE sibling: `makeCompoundShape` copies the frontmost operand's
    /// paint onto the wrapper by the same rule and had the same hole, so an
    /// Alt-click Shape Mode over a group produced an invisible compound.
    /// (Its container-seeding row stays KNOWN: a compound RETAINS its operands,
    /// so the wrapper is still visible in the result by construction.)
    @Test func aCompoundShapeOverAGroupWrappedOperandIsPainted() {
        let m = model(wrapped: true)
        Controller(model: m).makeCompoundShape(operation: .union)
        let e = m.document.getElement([0, 0])
        #expect(e.fill?.color == Self.blue, "got \(e.fill?.color as Any)")
        #expect(e.stroke?.width == 7, "got \(e.stroke?.width as Any)")
    }

    /// ANTI-VACUITY for the whole suite: the bare-leaf spelling must be painted
    /// in the first place. If the fixture ever decayed to unpainted rects the
    /// equality test would pass on `nil == nil`.
    @Test func theBareSpellingIsPaintedToBeginWith() {
        let e = destructive("union", wrapped: false)
        #expect(e.fill != nil && e.stroke != nil, "fixture is painted: \(paint(e))")
    }
}

/// A DESTRUCTIVE BOOLEAN OVER A CONTAINER TAKES **COMPOSED** OPACITY.
/// RULED 2026-07-31 (`seat/fleet/RULING-boolean-container-paint-2026-07-31.md`).
///
/// The suite above settled `fill` and `stroke`: a container has NO paint of its
/// own, so resolving to its first paintable leaf was the ONLY available answer.
/// `opacity` is a different question, and the CONTAINERPAINT fix did not answer
/// it — a container carries a real opacity, so TWO true values exist and the
/// implementation silently picked one (this port took the LEAF's, Rust took the
/// CONTAINER's, which is a second, quieter divergence hiding under the first).
///
/// THE PRINCIPLE: a DESTRUCTIVE operation's result should LOOK LIKE WHAT IT
/// CONSUMED. A group drawn at `0.5 × 0.8 = 0.4` came back at 0.8 here and 0.5 in
/// Rust — either way the artwork visibly changes density at the instant of
/// clicking, which no reading of BOOLEAN.md §paint justifies. So the two true
/// values are COMBINED rather than elected between:
///
///     result.opacity = container.opacity × frontmost-leaf.opacity
///
/// and at any depth, the whole chain multiplies.
///
/// THE HONEST LIMIT, recorded here and in `booleanComposedOpacity` so nobody
/// rediscovers it as a bug: where a group holds SEVERAL members at DIFFERENT
/// opacities, NO rule preserves appearance — flattening N differently
/// transparent shapes into one path is lossy by nature. Composition is EXACT
/// for the single-visible-member case and an approximation otherwise. The
/// ruling is not "correct vs incorrect"; it is which approximation is least
/// surprising, chosen to be exact exactly where an artist will notice.
///
/// BLEND MODE IS **OPEN** and deliberately untested here: opacities multiply,
/// blend modes do not compose at all. See `booleanMergedCommon`.
@Suite("Boolean opacity composes down the container chain")
struct BooleanContainerOpacityTests {

    private static let red = Color(r: 1, g: 0, b: 0, a: 1)
    private static let blue = Color(r: 0, g: 0, b: 1, a: 1)

    private func leaf(_ x: Double, _ color: Color, _ opacity: Double) -> Element {
        .rect(Rect(x: x, y: 0, width: 100, height: 100,
                   fill: Fill(color: color),
                   stroke: Stroke(color: color, width: 2),
                   opacity: opacity))
    }

    /// Two overlapping operands. [front] is the FRONTMOST (last in path order),
    /// the one every N→1 arm takes its paint from; the back operand is a plain
    /// fully-opaque leaf so any number other than 1.0 in the result came from
    /// [front].
    private func model(front: Element) -> Model {
        let doc = Document(layers: [Layer(name: "L", children: [
            leaf(0, Self.red, 1.0), front,
        ])])
        return Model(document: doc.replacing(selection: [
            ElementSelection.all([0, 0]), ElementSelection.all([0, 1]),
        ]))
    }

    private func opacityAfter(_ op: String, front: Element) -> Double {
        let m = model(front: front)
        Controller(model: m).applyDestructiveBoolean(op)
        return m.document.getElement([0, 0]).opacity
    }

    /// A group at 0.5 holding a member at 0.8 is DRAWN at 0.4, so the path that
    /// replaces it must be too. This is the ruling in one line.
    @Test func aGroupAndItsMemberComposeIntoOneOpacity() {
        let front = Element.group(Group(children: [leaf(50, Self.blue, 0.8)],
                                        opacity: 0.5))
        for op in ["union", "intersection", "exclude"] {
            let got = opacityAfter(op, front: front)
            #expect(abs(got - 0.4) < 1e-9,
                    "\(op): 0.5 × 0.8 = 0.4, got \(got)")
        }
    }

    /// DEGENERATE — the container is 1.0. Composition must then be the IDENTITY
    /// on the member, i.e. exactly the bare-leaf spelling. Written as an
    /// equality against that spelling, not against a literal: this is the arm a
    /// wrong fix (take the container, always) breaks.
    @Test func anOpaqueContainerAnswersExactlyAsItsBareMember() {
        let bare = leaf(50, Self.blue, 0.8)
        let wrapped = Element.group(Group(children: [bare], opacity: 1.0))
        let viaLeaf = opacityAfter("union", front: bare)
        let viaGroup = opacityAfter("union", front: wrapped)
        #expect(viaLeaf == viaGroup,
                "bare \(viaLeaf) vs grouped \(viaGroup)")
        #expect(abs(viaLeaf - 0.8) < 1e-9,
                "and the fixture is transparent to begin with; got \(viaLeaf)")
    }

    /// DEGENERATE — the member is 1.0, so the container's own value is the
    /// whole answer. This is the arm the OTHER wrong fix (take the leaf,
    /// always — what this port shipped) breaks.
    @Test func anOpaqueMemberLeavesTheContainersOwnOpacityStanding() {
        let front = Element.group(Group(children: [leaf(50, Self.blue, 1.0)],
                                        opacity: 0.5))
        let got = opacityAfter("union", front: front)
        #expect(abs(got - 0.5) < 1e-9, "0.5 × 1.0 = 0.5, got \(got)")
    }

    /// NESTED — the product must run the WHOLE chain, not just one level.
    /// 0.5 × 0.8 × 0.5 = 0.2. A one-level fix passes every test above.
    @Test func aNestedGroupMultipliesTheWholeChain() {
        let inner = Element.group(Group(children: [leaf(50, Self.blue, 0.5)],
                                        opacity: 0.8))
        let front = Element.group(Group(children: [inner], opacity: 0.5))
        let got = opacityAfter("union", front: front)
        #expect(abs(got - 0.2) < 1e-9, "0.5 × 0.8 × 0.5 = 0.2, got \(got)")
    }

    /// DEGENERATE — an EMPTY container reaches no leaf, so there is nothing to
    /// compose with and its own opacity is the whole story. Pinned directly
    /// rather than through an op because an empty operand contributes no
    /// geometry, so the arm would have nothing to assert on. The second
    /// expectation pins that the two resolvers AGREE about "no leaf reached" —
    /// `booleanPaintSource` answers with the container itself, and a walk that
    /// disagreed would compose an opacity onto paint from somewhere else.
    @Test func anEmptyContainerComposesWithNothing() {
        let empty = Element.group(Group(children: [], opacity: 0.5))
        #expect(booleanComposedOpacity(empty) == 0.5,
                "nothing to inherit is the honest answer; got \(booleanComposedOpacity(empty))")
        #expect(booleanPaintSource(empty) == empty,
                "and the paint resolver answers with the container too")
    }

    /// ANTI-REGRESSION: composition is the IDENTITY on a leaf operand, so no
    /// existing non-container behaviour moves. A bare 0.8 rect still unions to
    /// 0.8 — and that it is not 1.0 is what makes the whole suite non-vacuous.
    @Test func aLeafOperandIsUntouchedByComposition() {
        let got = opacityAfter("union", front: leaf(50, Self.blue, 0.8))
        #expect(abs(got - 0.8) < 1e-9, "a leaf keeps its own opacity; got \(got)")
        #expect(booleanComposedOpacity(leaf(50, Self.blue, 0.8)) == 0.8)
    }

    /// The 1→1 SURVIVOR arms resolve per-operand, so a grouped SURVIVOR
    /// composes too. Here the container is the BACK operand — subtract_front
    /// consumes the frontmost as the cutter and the survivor keeps its own
    /// paint, which for a container is its members'.
    @Test func aGroupedSurvivorComposesItsOwnOpacity() {
        let survivor = Element.group(Group(children: [leaf(0, Self.red, 0.8)],
                                           opacity: 0.5))
        let doc = Document(layers: [Layer(name: "L", children: [
            survivor, leaf(50, Self.blue, 1.0),
        ])])
        let m = Model(document: doc.replacing(selection: [
            ElementSelection.all([0, 0]), ElementSelection.all([0, 1]),
        ]))
        Controller(model: m).applyDestructiveBoolean("subtract_front")
        let got = m.document.getElement([0, 0]).opacity
        #expect(abs(got - 0.4) < 1e-9, "0.5 × 0.8 = 0.4, got \(got)")
    }

    /// The LIVE sibling takes the same rule — and had a THIRD answer again:
    /// this port wrote a literal `1.0` while Rust copied the frontmost
    /// operand's own opacity, so an Alt-click Shape Mode over ANY
    /// half-transparent operand, container or leaf, came out opaque here.
    @Test func aCompoundShapeComposesTheSameWay() {
        let front = Element.group(Group(children: [leaf(50, Self.blue, 0.8)],
                                        opacity: 0.5))
        let m = model(front: front)
        Controller(model: m).makeCompoundShape(operation: .union)
        let got = m.document.getElement([0, 0]).opacity
        #expect(abs(got - 0.4) < 1e-9, "0.5 × 0.8 = 0.4, got \(got)")

        // And the leaf spelling, which is where the literal 1.0 was visible
        // without any container in sight.
        let m2 = model(front: leaf(50, Self.blue, 0.8))
        Controller(model: m2).makeCompoundShape(operation: .union)
        let got2 = m2.document.getElement([0, 0]).opacity
        #expect(abs(got2 - 0.8) < 1e-9,
                "a leaf operand's own opacity rides onto the compound; got \(got2)")
    }

    /// MANDATORY GEOMETRY PAIRING (§3.1): an opacity-only battery cannot tell a
    /// working union from one that returned its input. x∈[0,100] ∪ x∈[50,150]
    /// still spans the full 150 with the container operand in play.
    @Test func theComposingArmStillUnionsTheWholeOperand() {
        let front = Element.group(Group(children: [leaf(50, Self.blue, 0.8)],
                                        opacity: 0.5))
        let m = model(front: front)
        Controller(model: m).applyDestructiveBoolean("union")
        guard case .polygon(let p) = m.document.getElement([0, 0]) else {
            Issue.record("union of two overlapping rects is a single-ring polygon")
            return
        }
        #expect(p.points.map(\.0).max() == 150,
                "the grouped union spans both operands; got \(p.points)")
    }

    /// THE GUARD THE RULING ORDERS LEFT STANDING: `Element.fill` / `.stroke`
    /// are NOT widened. Composing opacity is a tempting occasion to "finish the
    /// job" by teaching a container to answer with its member's paint at every
    /// seam — render, hit-test and the panels read these, and three semantics
    /// would move at once. The resolution stays at the point of USE.
    @Test func aContainerStillHasNoPaintOfItsOwn() {
        let g = Element.group(Group(children: [leaf(0, Self.red, 1.0)],
                                    opacity: 0.5))
        #expect(g.fill == nil, "a container answers None for fill")
        #expect(g.stroke == nil, "and None for stroke")
        #expect(g.opacity == 0.5, "but it DOES carry a real opacity — the asymmetry")
    }
}

/// A SELECTED CONTAINER SUMMARISES ITS MEMBERS' PAINT.
///
/// Twin of Rust `a_selected_container_summarises_its_members_paint`. The two
/// ports were wrong in DIFFERENT directions: Swift skipped containers so a
/// selected group summarised to `.noSelection` ("nothing is selected"), while
/// Rust read the container's own `stroke()` and said `Uniform(None)` ("this has
/// no stroke"). Both are wrong answers rather than unavailable ones, and since
/// the paint ruling an artist meets it directly — set a group's stroke and the
/// panel says it has none.
@Suite("Container paint summary")
struct ContainerPaintSummaryTests {

    private func rect(_ w: Double) -> Element {
        .rect(Rect(x: 0, y: 0, width: 10, height: 10,
                   stroke: Stroke(color: Color(r: 0, g: 0, b: 0, a: 1), width: w)))
    }

    private func doc(_ sel: [[Int]]) -> Document {
        let uniform = Element.group(Group(children: [rect(5), rect(5)]))
        let mixed = Element.group(Group(children: [rect(5), rect(1)]))
        let d = Document(layers: [Layer(name: "L", children: [uniform, mixed])])
        return d.replacing(selection: sel.map { ElementSelection.all($0) })
    }

    @Test func aUniformGroupReadsBackItsMembersCommonValue() {
        guard case .uniform(let s?) = selectionStrokeSummary(doc([[0, 0]])) else {
            Issue.record("a uniform group must summarise its members, got \(selectionStrokeSummary(doc([[0, 0]])))")
            return
        }
        #expect(s.width == 5, "got width \(s.width)")
    }

    /// JYH's own example, one level in: a 5pt and a 1pt member have no honest
    /// common weight.
    @Test func aGroupWithDifferingMembersIsMixed() {
        guard case .mixed = selectionStrokeSummary(doc([[0, 1]])) else {
            Issue.record("a 5pt + 1pt group is Mixed, not \(selectionStrokeSummary(doc([[0, 1]])))")
            return
        }
    }

    /// The point of the whole exercise: a group IS a mixed selection of one, so
    /// the container and non-container spellings must agree.
    @Test func theContainerAndNonContainerSpellingsAgree() {
        let viaGroup = selectionStrokeSummary(doc([[0, 1]]))
        let viaMembers = selectionStrokeSummary(doc([[0, 1, 0], [0, 1, 1]]))
        guard case .mixed = viaGroup, case .mixed = viaMembers else {
            Issue.record("spellings disagree: group=\(viaGroup) members=\(viaMembers)")
            return
        }
    }
}

/// THE STROKE PANEL'S WEIGHT FIELD RESOLVES A CONTAINER.
///
/// Twin of Rust `the_weight_override_resolves_a_uniform_container`. Found by
/// JYH at council 2026-07-29, clicking a group: the Weight field read 1 pt
/// while both members carried 5. `strokePanelLiveOverrides` read
/// `doc.selection.first` and then that element's OWN stroke — nil for a
/// container — and fell through to a hard-coded 1.0, in BOTH ports.
@Suite("Stroke panel weight override")
struct StrokePanelWeightTests {

    private func rect(_ w: Double) -> Element {
        .rect(Rect(x: 0, y: 0, width: 10, height: 10,
                   stroke: Stroke(color: Color(r: 0, g: 0, b: 0, a: 1), width: w)))
    }

    private func doc(_ sel: [[Int]]) -> Document {
        let g = Element.group(Group(children: [rect(5), rect(5)]))
        let d = Document(layers: [Layer(name: "L", children: [g, rect(3)])])
        return d.replacing(selection: sel.map { ElementSelection.all($0) })
    }

    @Test func aUniformGroupResolvesToItsMembersWeight() {
        #expect(selectionStrokeForPanel(doc([[0, 0]]))?.width == 5,
                "a uniform group resolves to 5, not a hard-coded 1")
    }

    /// Unchanged behaviour — this is what already worked, and must keep working.
    @Test func aLeafStillResolvesToItsOwnWeight() {
        #expect(selectionStrokeForPanel(doc([[0, 1]]))?.width == 3,
                "a leaf resolves to its own weight")
    }

    /// A MIXED container and its members selected DIRECTLY must answer alike —
    /// a group is a mixed selection of one. Reading the selection ENTRY instead
    /// of the first leaf gave 1.0 for the group and the first member's weight
    /// for the members: two numbers, one fact.
    @Test func aMixedGroupAndItsMembersAnswerAlike() {
        let mixed = Element.group(Group(children: [rect(5), rect(1)]))
        let base = Document(layers: [Layer(name: "L", children: [mixed])])
        let viaGroup = selectionStrokeForPanel(
            base.replacing(selection: [ElementSelection.all([0, 0])]))
        let viaMembers = selectionStrokeForPanel(
            base.replacing(selection: [ElementSelection.all([0, 0, 0]),
                                       ElementSelection.all([0, 0, 1])]))
        #expect(viaGroup?.width == viaMembers?.width,
                "group says \(viaGroup?.width ?? -1), members say \(viaMembers?.width ?? -1)")
        #expect(viaGroup?.width == 5, "and that answer is the first leaf's")
    }
}

/// THE LAYERS-PANEL MARKER IS ANCESTOR-AWARE. RULED 2026-07-29.
///
/// JYH at council: *"when we select a group on the canvas, it should be as if
/// the children are selected too… almost as if the container were shorthand for
/// 'select all these at once'."*
///
/// AS IF is the design. The shorthand is expanded at the point of USE — here for
/// the panel marker, `mapPaintable`/`forEachPaintable` for operations — rather
/// than by writing descendants into `doc.selection`, which is where all eight
/// container defects came from. Twin: Rust `the_panel_marker_is_ancestor_aware`.
@Suite("Ancestor-aware panel marker")
struct PanelMarkerTests {
    @Test func aSelectedGroupMarksItsMembersRows() {
        let sel: [ElementPath] = [[0, 1]]
        #expect(pathIsSelectedOrUnder(sel, [0, 1]), "the group's own row")
        #expect(pathIsSelectedOrUnder(sel, [0, 1, 0]), "a member's row")
        #expect(pathIsSelectedOrUnder(sel, [0, 1, 2, 5]), "a member two levels down")
    }

    @Test func itDoesNotMarkAncestorsOrSiblings() {
        let sel: [ElementPath] = [[0, 1]]
        #expect(!pathIsSelectedOrUnder(sel, [0]), "the containing layer is NOT marked")
        #expect(!pathIsSelectedOrUnder(sel, [0, 0]), "a sibling is not marked")
    }

    /// Element-wise, never a string prefix: [0,1] must not match [0,10].
    @Test func itComparesPathElementsNotPrefixes() {
        let sel: [ElementPath] = [[0, 1]]
        #expect(!pathIsSelectedOrUnder(sel, [0, 10]), "[0,10] is not under [0,1]")
        #expect(!pathIsSelectedOrUnder(sel, [0, 11, 3]), "nor is [0,11,3]")
        #expect(!pathIsSelectedOrUnder([ElementPath](), [0, 1]),
                "an empty selection marks nothing")
    }
}

/// THE EXTEND SEAMS CANNOT BUILD AN ANCESTOR+DESCENDANT SELECTION.
///
/// Twin of Rust `the_extend_seams_cannot_build_an_ancestor_descendant_selection`.
/// §20 removed the two producers that WROTE the shape, and the corpus census then
/// read zero — but the extend seams still just appended, so shift-clicking a
/// group and then a member inside it rebuilt it. Measured in Rust:
/// `[[0,0], [0,0,1]]`, via the verb shift-click actually runs.
@Suite("Extend seams preserve the selection invariant")
struct ExtendSeamInvariantTests {

    private func rect(_ x: Double) -> Element {
        .rect(Rect(x: x, y: 0, width: 10, height: 10))
    }

    private func model() -> Model {
        let g = Element.group(Group(children: [rect(0), rect(20)]))
        return Model(document: Document(layers: [Layer(name: "L", children: [g, rect(40)])]))
    }

    /// A member of an already-selected group adds nothing — it is already in
    /// play under the Captain's "as if". Subtracting one member from a selected
    /// group is partial group selection, which §16.3 does not permit.
    @Test func aMemberOfASelectedGroupAddsNothing() {
        let m = model()
        let ctrl = Controller(model: m)
        ctrl.addToSelection([0, 0])
        ctrl.addToSelection([0, 0, 1])
        #expect(m.document.selection.map(\.path) == [[0, 0]],
                "got \(m.document.selection.map(\.path))")
    }

    /// The mirror: selecting the group SUBSUMES members already selected —
    /// "the outermost wins", as `moveSelection` already applies.
    @Test func selectingTheGroupSubsumesItsMembers() {
        let m = model()
        let ctrl = Controller(model: m)
        ctrl.addToSelection([0, 0, 0])
        ctrl.addToSelection([0, 0, 1])
        ctrl.addToSelection([0, 0])
        #expect(m.document.selection.map(\.path) == [[0, 0]],
                "got \(m.document.selection.map(\.path))")
    }

    /// And nothing else changes — a fix that made the seam inert would pass the
    /// two tests above.
    @Test func disjointPathsStillAccumulate() {
        let m = model()
        let ctrl = Controller(model: m)
        ctrl.addToSelection([0, 0])
        ctrl.addToSelection([0, 1])
        #expect(m.document.selection.map(\.path) == [[0, 0], [0, 1]],
                "got \(m.document.selection.map(\.path))")
    }
}
