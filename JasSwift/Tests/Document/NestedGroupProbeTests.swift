import Testing
@testable import JasLib

/// PROBE: grouping a sub-selection that already lives inside a Group.
///
/// `Controller.groupSelection` deletes the selected elements at their true
/// depth (`Document.deleteElement` recurses via `removeFromGroup`), but
/// re-inserts the new Group by reading only `insertPath[1]` and pushing into
/// `layers[layerIdx].children`. Any path component past the second is
/// discarded, so the new Group should land BESIDE the outer group rather than
/// inside it. Rust's `insert_element_at` recurses on `&path[1..]`.
@Suite("Nested group probe")
struct NestedGroupProbeTests {

    /// Layer 0 holds [rect, Group(line, line)]. Select the two lines INSIDE
    /// the group -- paths [0,1,0] and [0,1,1] -- and group them. Correct
    /// behaviour: the outer group ends up holding exactly one child (the new
    /// nested group), and the layer still holds exactly 2 children.
    @Test func groupingInsideAGroupStaysInsideThatGroup() {
        let l1 = Element.line(Line(x1: 0, y1: 0, x2: 5, y2: 5))
        let l2 = Element.line(Line(x1: 1, y1: 1, x2: 6, y2: 6))
        let inner = Element.group(Group(children: [l1, l2]))
        let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
        let layer = Layer(name: "L", children: [rect, inner])
        var doc = Document(layers: [layer])
        doc = doc.replacing(selection: Set([
            ElementSelection(path: [0, 1, 0]),
            ElementSelection(path: [0, 1, 1]),
        ]))
        let model = Model(document: doc)
        Controller(model: model).groupSelection()

        let after = model.document
        let layerCount = after.layers[0].children.count
        #expect(layerCount == 2,
                "layer holds \(layerCount) children; a third means the new group escaped one level")

        let outer = after.getElement([0, 1])
        guard case .group(let g) = outer else {
            Issue.record("element at [0,1] is no longer a group")
            return
        }
        #expect(g.children.count == 1,
                "outer group should hold exactly the new nested group, holds \(g.children.count)")
    }
}
