import Testing
@testable import JasLib

// STATUS-jas item 20: Ungroup splices a group's members into the group's OWN
// parent at its index (MENU.md), and the selection's offset is per parent.
// The same cases, in the same text, as Rust's `ungroup_*` arms in
// controller.rs and the reference's test_doc_op.py.

/// `r<x>` for a rect at x, `G[..]` for a group, one `L[..]` per layer.
private func shape(_ doc: Document) -> String {
    func walk(_ e: Element) -> String {
        switch e {
        case .rect(let r): return "r\(Int(r.x))"
        case .group(let g): return "G[" + g.children.map(walk).joined(separator: " ") + "]"
        default: return "?"
        }
    }
    return doc.layers.map { "L[" + $0.children.map(walk).joined(separator: " ") + "]" }
        .joined(separator: " ")
}

private func r(_ x: Double) -> Element { .rect(Rect(x: x, y: 0, width: 1, height: 1)) }
private func g(_ cs: Element...) -> Element { .group(Group(children: cs)) }

private func ungroup(_ layers: [[Element]], _ selected: [ElementPath]) -> (String, [ElementPath]) {
    let doc = Document(layers: layers.enumerated().map { Layer(name: "L\($0.offset)", children: $0.element) })
    let ctrl = Controller(model: Model(document: doc))
    ctrl.setSelection(selected.map { ElementSelection.all($0) })
    ctrl.ungroupSelection()
    let sel = ctrl.document.selection.map(\.path).sorted { $0.lexicographicallyPrecedes($1) }
    return (shape(ctrl.document), sel)
}

@Test func ungroupNestedGroupKeepsMembersInItsParent() {
    let (s, sel) = ungroup([[r(0), g(g(r(1), r(2)), r(3)), r(4)]], [[0, 1, 0]])
    #expect(s == "L[r0 G[r1 r2 r3] r4]")
    #expect(sel == [[0, 1, 0], [0, 1, 1]])
}

@Test func ungroupInTwoLayersSelectsEachLayersMembers() {
    let (s, sel) = ungroup([[r(0), g(r(1), r(2), r(3))], [g(r(5), r(6)), r(7)]], [[0, 1], [1, 0]])
    #expect(s == "L[r0 r1 r2 r3] L[r5 r6 r7]")
    #expect(sel == [[0, 1], [0, 2], [0, 3], [1, 0], [1, 1]])
}

@Test func ungroupTwoGroupsInOneParent() {
    let (s, sel) = ungroup([[g(r(0), r(1)), r(2), g(r(3), r(4))]], [[0, 0], [0, 2]])
    #expect(s == "L[r0 r1 r2 r3 r4]")
    #expect(sel == [[0, 0], [0, 1], [0, 3], [0, 4]])
}

@Test func ungroupGroupAndItsAncestorDissolvesBoth() {
    let (s, sel) = ungroup([[r(0), g(g(r(1), r(2)), r(3)), r(4)]], [[0, 1], [0, 1, 0]])
    #expect(s == "L[r0 r1 r2 r3 r4]")
    #expect(sel == [[0, 1], [0, 2], [0, 3]])
}

@Test func ungroupEmptyGroupBeforeAnother() {
    let (s, sel) = ungroup([[g(), r(1), g(r(2), r(3))]], [[0, 0], [0, 2]])
    #expect(s == "L[r1 r2 r3]")
    #expect(sel == [[0, 1], [0, 2]])
}

@Test func ungroupMixedDepthsInTwoParents() {
    let (s, sel) = ungroup([[r(0), g(g(r(1), r(2)), r(3)), g(r(4), r(5))]], [[0, 1, 0], [0, 2]])
    #expect(s == "L[r0 G[r1 r2 r3] r4 r5]")
    #expect(sel == [[0, 1, 0], [0, 1, 1], [0, 2], [0, 3]])
}
