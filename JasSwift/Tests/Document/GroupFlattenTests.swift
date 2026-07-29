import Testing
@testable import JasLib

/// R1 — GROUP ALWAYS FLATTENS (transcripts/LAYER_STRUCTURE.md §3 R1,
/// ratified 2026-07-28). Twin of the Rust probes `r1_*` in
/// `jas_dioxus/src/document/controller.rs`, case for case.
///
/// Before R1 both ports carried a SIBLING GUARD that returned when the
/// selected paths did not share one parent prefix (and did not share one path
/// LENGTH). Cmd+G across two layers was a silent no-op with no feedback. R1:
/// no refusal — every selected element becomes a child of the new Group,
/// which lands at the FRONTMOST selected element's parent, at the z-slot that
/// element vacates.
///
/// "Frontmost" is fixed by the rule BOOLEAN.md already uses and
/// `makeCompoundShape` already implements: paths sorted ascending, frontmost
/// is `.last` — the GREATEST path. The canvas paints layers forward, so a
/// higher index paints later and therefore on top.
@Suite("R1 group flattens")
struct GroupFlattenTests {

    private func doc(_ layers: [Layer], _ sel: [[Int]]) -> Model {
        var d = Document(layers: layers)
        d = d.replacing(selection: sel.map { ElementSelection(path: $0) })
        return Model(document: d)
    }

    private func rect(_ x: Double, _ w: Double = 10) -> Element {
        .rect(Rect(x: x, y: 0, width: w, height: 10))
    }

    /// R1 case 1 — TWO LAYERS. The old guard refused outright. The new Group
    /// lands in the FRONTMOST element's layer (layer 1); layer 0 — emptied by
    /// the move — stays, per the T4 bystander clause.
    @Test func groupAcrossTwoLayersLandsInTheFrontmostLayer() {
        let r = rect(0)
        let l = Element.line(Line(x1: 1, y1: 1, x2: 6, y2: 6))
        let model = doc([Layer(name: "Background", children: [r]),
                         Layer(name: "Foreground", children: [l])],
                        [[0, 0], [1, 0]])
        Controller(model: model).groupSelection()
        let after = model.document

        #expect(after.layers.count == 2, "both layers must survive the move")
        #expect(after.layers[0].children.isEmpty,
                "layer 0 gave up its only child and must be left EMPTY, not deleted")
        #expect(after.layers[0].name == "Background",
                "the emptied bystander layer keeps its name")

        guard case .group(let g) = after.getElement([1, 0]) else {
            Issue.record("expected the new group at [1,0]"); return
        }
        #expect(g.children.count == 2, "both selected elements became children")
        // Whole-element equality: this is a RELOCATION, not a rebuild. Paired
        // with explicit VALUE assertions below, because whole-struct equality
        // is structurally blind to which field carries the geometry.
        #expect(g.children[0] == r, "the rect moved across whole and unchanged")
        #expect(g.children[1] == l, "the line moved across whole and unchanged")
        guard case .rect(let rr) = g.children[0] else {
            Issue.record("child 0 should still be a Rect"); return
        }
        #expect(rr.x == 0 && rr.y == 0 && rr.width == 10 && rr.height == 10,
                "the rect's geometry survived the move")
        guard case .line(let ll) = g.children[1] else {
            Issue.record("child 1 should still be a Line"); return
        }
        #expect(ll.x1 == 1 && ll.y1 == 1 && ll.x2 == 6 && ll.y2 == 6,
                "the line's geometry survived the move")
        #expect(after.selection == [ElementSelection(path: [1, 0])],
                "selection becomes the new group")
    }

    /// R1 case 2 — TWO DIFFERENT GROUPS, one layer. The old guard rejected
    /// this for exactly the reason it rejected two layers: the parents
    /// differ. Nothing about the fix may be phrased in terms of layers.
    @Test func groupAcrossTwoGroupsLandsInTheFrontmostGroup() {
        let a = rect(0), b = rect(20), c = rect(40), d = rect(60)
        let model = doc([Layer(name: "Stage", children: [
            .group(Group(children: [a, b])),
            .group(Group(children: [c, d])),
        ])], [[0, 0, 1], [0, 1, 0]])
        Controller(model: model).groupSelection()
        let after = model.document

        guard case .group(let back) = after.getElement([0, 0]) else {
            Issue.record("the back group must survive"); return
        }
        #expect(back.children.count == 1, "the back group keeps its remaining child")
        #expect(back.children[0] == a, "and that child is untouched")

        guard case .group(let ng) = after.getElement([0, 1, 0]) else {
            Issue.record("expected the new group at [0,1,0]"); return
        }
        #expect(ng.children.count == 2, "b and c became the new group's children")
        #expect(ng.children[0] == b, "b relocated whole")
        #expect(ng.children[1] == c, "c relocated whole")
        guard case .rect(let cc) = ng.children[1] else {
            Issue.record("expected Rect"); return
        }
        #expect(cc.x == 40 && cc.width == 10,
                "c's geometry survived the cross-parent move")

        guard case .group(let front) = after.getElement([0, 1]) else {
            Issue.record("the front group must survive"); return
        }
        #expect(front.children.count == 2 && front.children[1] == d,
                "d is still in the front group")
    }

    /// R1 case 3 — a source GROUP emptied by the move. DECISION (see
    /// `groupSelection`'s comment): an emptied Group is kept, exactly as an
    /// emptied Layer is. It is a bystander the edit never spoke to, and it
    /// carries a name, an id and blend flags that deleting would destroy.
    /// This is NOT D3's orphan: there the container was emptied by a WRONG
    /// insert; here the emptying is the correct consequence of the move.
    @Test func aGroupEmptiedByTheMoveSurvivesAsAnEmptyGroup() {
        let a = rect(0), b = rect(20), c = rect(40)
        let model = doc([
            Layer(name: "Lower", children: [.group(Group(children: [a, b]))]),
            Layer(name: "Upper", children: [c]),
        ], [[0, 0, 0], [0, 0, 1], [1, 0]])
        Controller(model: model).groupSelection()
        let after = model.document

        guard case .group(let src) = after.getElement([0, 0]) else {
            Issue.record("the emptied source group must still be at [0,0] — not pruned, not orphaned")
            return
        }
        #expect(src.children.isEmpty, "with no children left")
        #expect(after.layers[0].children.count == 1,
                "the lower layer still holds exactly the emptied group")

        guard case .group(let g) = after.getElement([1, 0]) else {
            Issue.record("expected the new group in the upper layer"); return
        }
        #expect(g.children.count == 3, "all three selected elements moved in")
        #expect(g.children == [a, b, c], "all three relocated whole, in document order")
    }

    /// R1 case 4 — SAME PARENT, NON-CONTIGUOUS. This case never hit the
    /// guard, so it is not about flattening: it pins the PLACEMENT half of
    /// R1. `actions.yaml` §group has always said the group "inherits the
    /// z-order position of the frontmost selected object"; both ports
    /// inserted at `paths[0]`, the BACKMOST.
    @Test func sameParentGroupTakesTheFrontmostZSlotNotTheBackmost() {
        let a = rect(0), b = rect(20), c = rect(40)
        let model = doc([Layer(name: "Stage", children: [a, b, c])],
                        [[0, 0], [0, 2]])
        Controller(model: model).groupSelection()
        let after = model.document

        let kids = after.layers[0].children
        #expect(kids.count == 2, "b plus the new group")
        #expect(kids[0] == b,
                "b, unselected, keeps the BACK slot — the group must not be inserted under it")
        guard case .group(let g) = kids[1] else {
            Issue.record("the new group must take the frontmost slot"); return
        }
        #expect(g.children == [a, c], "a and c relocated whole")
        #expect(after.selection == [ElementSelection(path: [0, 1])],
                "selection follows the group to its real path")
    }

    /// R1 case 5 — the CONTIGUOUS same-parent case, which is what the corpus
    /// golden `menu_group_two_rects` pins. Frontmost-minus-removed-siblings
    /// and old-backmost agree here (1 - 1 == 0), so this case must be
    /// byte-identical before and after R1. It is the regression guard on the
    /// placement change above.
    @Test func contiguousSameParentPlacementIsUnchanged() {
        let a = rect(0), b = rect(20)
        let model = doc([Layer(name: "Stage", children: [a, b])], [[0, 0], [0, 1]])
        Controller(model: model).groupSelection()
        let after = model.document
        #expect(after.layers[0].children.count == 1, "one group replaces the two rects")
        if case .group = after.layers[0].children[0] {} else {
            Issue.record("expected a group at index 0")
        }
        #expect(after.selection == [ElementSelection(path: [0, 0])],
                "group at index 0, as before R1")
    }

    /// R1 case 6 — MIXED DEPTHS. **OPEN QUESTION 3 in the brief; NOT ruled.**
    /// What this pins is the CONSERVATIVE consequence of applying R1
    /// literally — the frontmost path is the deep one, so its parent (the
    /// group) is the destination and the shallow element is pulled INTO that
    /// group. Recorded so the behaviour is watched and so a future ruling
    /// changes a RED test rather than discovering silence.
    @Test func mixedDepthSelectionFollowsTheFrontmostParentUnruled() {
        let solo = rect(0), alpha = rect(20), beta = rect(40)
        let model = doc([Layer(name: "Stage", children: [
            solo, .group(Group(children: [alpha, beta])),
        ])], [[0, 0], [0, 1, 1]])
        Controller(model: model).groupSelection()
        let after = model.document

        let kids = after.layers[0].children
        #expect(kids.count == 1, "solo left the layer; only the cluster remains")
        guard case .group(let cluster) = kids[0] else {
            Issue.record("expected the cluster"); return
        }
        #expect(cluster.children.count == 2, "cluster holds alpha and the new group")
        #expect(cluster.children[0] == alpha, "alpha untouched")
        guard case .group(let g) = cluster.children[1] else {
            Issue.record("the new group must land INSIDE the cluster"); return
        }
        #expect(g.children == [solo, beta],
                "solo and beta relocated whole, in document order")
    }

    /// R1 case 7 — ANCESTOR AND DESCENDANT both selected. Also unruled, and
    /// the one shape where the naive reading is actively UNSAFE: cloning both
    /// the container and its child into the new group would put the same
    /// element in the document twice, duplicating a live id. The conservative
    /// position: the ancestor carries its children, so a selected path with a
    /// selected ancestor is dropped from the move.
    @Test func selectingAGroupAndItsOwnChildDoesNotDuplicateTheChild() {
        let solo = rect(0), alpha = rect(20), beta = rect(40)
        let model = doc([Layer(name: "Stage", children: [
            solo, .group(Group(children: [alpha, beta])),
        ])], [[0, 0], [0, 1], [0, 1, 1]])
        Controller(model: model).groupSelection()
        let after = model.document

        let kids = after.layers[0].children
        #expect(kids.count == 1, "solo and the cluster both moved into one new group")
        guard case .group(let g) = kids[0] else {
            Issue.record("expected the new group"); return
        }
        #expect(g.children.count == 2,
                "exactly solo + the cluster: beta must NOT appear a second time")
        #expect(g.children[0] == solo, "solo relocated whole")
        guard case .group(let cl) = g.children[1] else {
            Issue.record("the cluster must relocate as a whole subtree"); return
        }
        #expect(cl.children == [alpha, beta],
                "and it still carries BOTH its own children, intact")
    }

    /// R1 case 8 — a STALE selection path. Rust's `get_element` returns None
    /// and the operation no-ops; Swift's `getElement` INDEXES and would trap,
    /// so without `pathResolves` the same stale selection is quiet in one port
    /// and a CRASH here. That is the saturate-vs-trap divergence class, and R1
    /// widened its reach by accepting selections the old guard used to reject
    /// before ever resolving them.
    @Test func aStaleSelectionPathIsANoOpNotATrap() {
        let a = rect(0)
        let model = doc([Layer(name: "Stage", children: [a])], [[0, 0], [0, 7]])
        Controller(model: model).groupSelection()
        let after = model.document
        #expect(after.layers[0].children.count == 1, "the document is untouched")
        #expect(after.layers[0].children[0] == a,
                "and the one real element is still itself")
    }
}
