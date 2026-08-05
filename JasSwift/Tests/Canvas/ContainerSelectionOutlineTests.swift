import Testing
import CoreGraphics
@testable import JasLib

/// A SELECTED GROUP MUST SHOW A HIGHLIGHT.
///
/// Found by JYH at council, 2026-07-29, clicking the thing the GROUPMOVE fix
/// had just made draggable: *"in swift, the group drags, but there is no select
/// highlight"*.
///
/// `drawElementOverlay` returned early for `.group` and `.layer` and said why:
///
/// > *"Groups and Layers emit no overlay themselves — their descendants are
/// > individually in the selection and draw their own highlights."*
///
/// That premise is the Rust-only container expansion in `doc.set_selection`
/// (`interpreter/effects.rs`), which JasSwift does not do — so in Swift the
/// descendants were never in the selection and nothing drew at all. It is the
/// THIRD consumer found resting on that premise, after `move_control_points`
/// (a group would not move) and `copy_selection` (a copy damaged its source).
///
/// Rust already carries the answer and states the convention at
/// `canvas/render.rs`:
///
/// > *"Per the vector-illustration convention, a selected Group is shown as a
/// > single bbox around its contents — not as individual descendant outlines"*
///
/// So this is not a design choice to make; it is a port catching up. The
/// handle-square half already agreed — `selectionHandleRects` returns `[]` for
/// containers in both ports, so a group gets an outline and no grab handles.
@Suite("Container selection outline")
struct ContainerSelectionOutlineTests {

    private func rect(_ x: Double, _ w: Double = 10) -> Element {
        .rect(Rect(x: x, y: 0, width: w, height: 10))
    }

    /// The outline is the container's own bounds — the union of its contents.
    @Test func aGroupOutlinesItsChildrenUnionBounds() {
        let g = Element.group(Group(children: [rect(0), rect(20)]))
        guard let r = containerSelectionOutlineRect(g) else {
            Issue.record("a group must produce an outline rect; got none")
            return
        }
        let desc = "x=\(r.minX) y=\(r.minY) w=\(r.width) h=\(r.height)"
        #expect(r.minX == 0 && r.width == 30, "spans both children, 0..30; got \(desc)")
        #expect(r.minY == 0 && r.height == 10, "and their common height; got \(desc)")
    }

    /// A Layer is a container too — the Layers panel can select one.
    @Test func aLayerAlsoOutlines() {
        let l = Element.layer(Layer(name: "L", children: [rect(5)]))
        #expect(containerSelectionOutlineRect(l) != nil,
                "a selected layer outlines like a group")
    }

    /// A non-container draws its own geometry, not a bbox — it must NOT take
    /// this path, or every shape would be outlined as a plain rectangle and a
    /// circle would gain square corners.
    @Test func aLeafDoesNotUseTheContainerOutline() {
        #expect(containerSelectionOutlineRect(rect(0)) == nil,
                "a rect strokes its own geometry")
        #expect(containerSelectionOutlineRect(.ellipse(Ellipse(cx: 5, cy: 5, rx: 5, ry: 5))) == nil,
                "a circle strokes its own geometry")
    }

    /// An EMPTY container has no extent, and stroking a zero-sized rect draws a
    /// dot at the origin. Rust guards this with `bw > 0.0 && bh > 0.0`; the
    /// guard is mirrored rather than reinvented.
    @Test func anEmptyContainerOutlinesNothing() {
        #expect(containerSelectionOutlineRect(.group(Group(children: []))) == nil,
                "an empty group has no extent and must not stroke a dot")
    }
}

/// GROUPPHANTOM: a container's box is the UNION of its children, so a symbol
/// instance child's zero box is not absent — it is a phantom point AT THE
/// ORIGIN that the union swallows, and the outline stretches back across empty
/// canvas. Twin of Rust's
/// `a_selected_group_holding_an_instance_does_not_stretch_to_the_origin`.
@Test func aSelectedGroupHoldingAnInstanceDoesNotStretchToTheOrigin() {
    let master = Element.rect(Rect(x: 5, y: 7, width: 10, height: 20, id: "m1"))
    let instance = Element.live(.reference(ReferenceElem(
        target: ElementRef("m1"), name: nil, id: "i1")))
    let sibling = Element.rect(Rect(x: 100, y: 100, width: 10, height: 10))
    let group = Element.group(Group(children: [instance, sibling]))
    let doc = Document(layers: [Layer(name: "L0", children: [group])], symbols: [master])
    let resolver = IdIndexResolver(index: rebuildIdIndex(doc))

    guard let r = containerSelectionOutlineRect(group, resolvedBy: resolver) else {
        Issue.record("a group with drawn members must have an outline")
        return
    }
    #expect(r.origin.x == 5 && r.origin.y == 7
            && r.width == 105 && r.height == 103,
            "the outline bounds what is DRAWN, and reaches the origin only if something is drawn there")

    // The narrow form still answers from the origin — that is why the overlay
    // must ask the resolved one.
    let narrow = containerSelectionOutlineRect(group)
    #expect(narrow?.origin.x == 0 && narrow?.origin.y == 0)
}
