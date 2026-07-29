import Testing
@testable import JasLib

/// §16.4's JUSTIFYING DEFECT, pinned in Swift.
///
/// An adversarial review of the §16.4 ruling (2026-07-29) found that the
/// consequence the ruling rests on was pinned in **Rust only**, and that the
/// shared corpus's copy case runs on `two_rects.svg` — a document with **no
/// group at all**. That is precisely why this defect survived so long: the copy
/// family could not express it, and the marquee family never copied.
///
/// This suite is the Swift half. It drives the real gesture — marquee, then
/// copy — over a document that HAS a group.
@Suite("Marquee then copy")
struct MarqueeCopyTests {

    private func rect(_ x: Double) -> Element {
        .rect(Rect(x: x, y: 0, width: 10, height: 10))
    }

    private func groupDoc() -> Controller {
        let doc = Document(layers: [Layer(name: "Stage", children: [
            .group(Group(children: [rect(0), rect(20)])),
        ])])
        return Controller(model: Model(document: doc))
    }

    /// The band selects the group ALONE (§16.4), so copy duplicates the group
    /// once and leaves the source intact.
    ///
    /// Before the ruling the band returned the group AND both members, and
    /// `copySelection` read that as: copy the group whole, then copy each member
    /// INTO the source group. The SOURCE came back holding four children
    /// instead of two. The artist asked for a duplicate and got the original
    /// damaged.
    @Test func marqueeThenCopyLeavesTheSourceGroupIntact() {
        let ctrl = groupDoc()
        ctrl.selectRect(x: -5, y: -5, width: 100, height: 100)

        #expect(ctrl.document.selection.map(\.path) == [[0, 0]],
                "precondition: the band selects the group alone (§16.4)")

        ctrl.copySelection(dx: 100, dy: 0)

        let kids = ctrl.document.layers[0].children
        #expect(kids.count == 2, "exactly one copy beside the source")
        for (i, kid) in kids.enumerated() {
            guard case .group(let g) = kid else {
                Issue.record("expected a Group at [\(i)], got \(kid)"); continue
            }
            #expect(g.children.count == 2,
                    "group [\(i)] holds exactly its two members; before §16.4 the SOURCE came back with four")
        }
    }

    /// The review's sharper consequence: **deselect could SELECT.**
    ///
    /// Select All, then shift-marquee over the group. Under the old shape the
    /// XOR removed the group's entry and ADDED its two members — so a gesture
    /// whose whole purpose is to remove something from the selection put two
    /// new things into it, and produced exactly the ancestor+descendant shape
    /// §16 had already called a defect, inside the marquee's own extend mode.
    @Test func shiftMarqueeOverAGroupDeselectsItWithoutAddingItsMembers() {
        let ctrl = groupDoc()
        ctrl.selectAll()
        #expect(ctrl.document.selection.map(\.path) == [[0, 0]],
                "precondition: Select All takes the group as ONE (§16.3)")

        ctrl.selectRect(x: -5, y: -5, width: 100, height: 100, extend: true)

        #expect(ctrl.document.selection.isEmpty,
                "the XOR removes the group and adds nothing; got \(ctrl.document.selection.map(\.path))")
    }

    /// THE EMPTY INTERIOR — a band falling entirely BETWEEN a group's members
    /// selects nothing.
    ///
    /// The adversarial review flagged this as unwatched: the group branch asks
    /// `anyHit` over the MEMBERS, not over the group's bounding box, so a band
    /// inside the group's bounds but touching no member must come back empty.
    /// Nothing pinned that, in either port. It is the semantic difference
    /// between the group branch and the plain bounding-box arm, and it is the
    /// reason that branch survives §16.4 rather than collapsing into it.
    ///
    /// Members here are at x=0..10 and x=20..30, so the band at x=12..18 sits
    /// in the gap. A bbox test would match the group (bounds 0..30) and be
    /// wrong.
    @Test func aBandInsideTheGroupButTouchingNoMemberSelectsNothing() {
        let ctrl = groupDoc()
        ctrl.selectRect(x: 12, y: 2, width: 6, height: 6)
        #expect(ctrl.document.selection.isEmpty,
                "the band is inside the group's bounds but touches no member; got \(ctrl.document.selection.map(\.path))")
    }
}

/// §16.4 AT THE POINT OF USE — an ancestor in the selection covers its
/// descendants.
///
/// The ruling forbids such a selection, but it is not yet ENFORCED at every
/// producer: the extend/add seams and `doc.set_selection`'s still-live
/// container expansion (§20) can all still build one. An adversarial review of
/// §16.4 found the consequence by probing, 2026-07-29.
///
/// Twin of Rust `an_ancestor_in_the_selection_covers_its_descendants`.
@Suite("Ancestor covers descendants")
struct AncestorCoversDescendantsTests {

    /// Group selected whole PLUS one member's single control point, dragged.
    ///
    /// Before the fix the member was rebuilt by the control-point edit and the
    /// group's translation was lost on it — in Rust it came back as a Polygon
    /// stranded at pristine coordinates with one corner displaced, while its
    /// sibling had moved correctly. The two ports corrupted it *differently*,
    /// because Rust reads each element from the pristine document and Swift
    /// read from the running one.
    @Test func aPartiallySelectedMemberRidesItsGroupsMoveWhole() {
        let doc = Document(layers: [Layer(name: "Stage", children: [
            .group(Group(children: [
                .rect(Rect(x: 0, y: 0, width: 10, height: 10)),
                .rect(Rect(x: 20, y: 0, width: 10, height: 10)),
            ])),
        ])])
        let model = Model(document: doc.replacing(selection: [
            ElementSelection.all([0, 0]),
            ElementSelection(path: [0, 0, 0], kind: .partial(.single(0))),
        ]))
        Controller(model: model).moveSelection(dx: 24, dy: 0)

        guard case .group(let g) = model.document.getElement([0, 0]) else {
            Issue.record("[0,0] should still be a Group"); return
        }
        guard case .rect(let a) = g.children[0] else {
            Issue.record("child 0 must stay a Rect"); return
        }
        guard case .rect(let b) = g.children[1] else {
            Issue.record("child 1 must stay a Rect"); return
        }
        #expect(a.x == 24 && a.y == 0,
                "the partially-selected member rides the group's move whole, got (\(a.x), \(a.y))")
        #expect(b.x == 44 && b.y == 0,
                "the sibling moves with the group, got (\(b.x), \(b.y))")
    }
}
