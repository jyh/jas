import Testing
import Foundation
@testable import JasLib

/// Unit tests for the derived DEPENDENCY INDEX (REFERENCE_GRAPH.md §3).
/// Mirror jas_dioxus `document/dependency_index.rs` tests exactly.

// MARK: - Builders

private func rectWithId(_ id: String?) -> Element {
    .rect(Rect(x: 0, y: 0, width: 10, height: 10, id: id))
}

private func reference(_ id: String, _ target: String) -> Element {
    .live(.reference(ReferenceElem(target: ElementRef(target), id: id)))
}

/// Wrap `children` in a single layer named "Layer".
private func docWithLayer(_ children: [Element]) -> Document {
    Document(layers: [Layer(name: "Layer", children: children)],
             selectedLayer: 0, selection: [], artboards: [])
}

// MARK: - Tests

@Test func emptyDocumentHasEmptyIndex() {
    let idx = DependencyIndex.build(docWithLayer([]))
    #expect(idx.deps.isEmpty)
    #expect(idx.rdeps.isEmpty)
    #expect(idx.dangling.isEmpty)
    #expect(idx.cycles.isEmpty)
}

@Test func depsAndRdepsForTwoReferencesToOneTarget() {
    // a <- r1, a <- r2.
    let idx = DependencyIndex.build(docWithLayer([
        rectWithId("a"),
        reference("r1", "a"),
        reference("r2", "a"),
    ]))
    #expect(idx.deps["r1"] == ["a"])
    #expect(idx.deps["r2"] == ["a"])
    // rdeps of `a` lists r1, r2 sorted; `a` is targetable (a plain rect node).
    #expect(idx.rdeps["a"] == ["r1", "r2"])
    #expect(idx.dangling.isEmpty)
    #expect(idx.cycles.isEmpty)
}

@Test func idLessElementIsNotANode() {
    // The rect has no id; only the reference is a node, and its target is
    // absent -> dangling. The id-less rect appears nowhere in the index.
    let idx = DependencyIndex.build(docWithLayer([
        rectWithId(nil),
        reference("r", "ghost"),
    ]))
    #expect(idx.deps.count == 1)
    #expect(idx.deps["r"] == ["ghost"])
    #expect(idx.rdeps.isEmpty)  // ghost is not targetable -> no rdeps
    #expect(idx.dangling == ["r"])
}

@Test func danglingWhenTargetAbsent() {
    let idx = DependencyIndex.build(docWithLayer([reference("r3", "ghost")]))
    #expect(idx.dangling == ["r3"])
    #expect(idx.rdeps.isEmpty)
    #expect(idx.cycles.isEmpty)
}

@Test func twoCycleIsDetected() {
    // c1 -> c2 -> c1.
    let idx = DependencyIndex.build(docWithLayer([
        reference("c1", "c2"),
        reference("c2", "c1"),
    ]))
    #expect(idx.cycles == ["c1", "c2"])
    // Both are targetable references, so each appears in the other's rdeps.
    #expect(idx.rdeps["c1"] == ["c2"])
    #expect(idx.rdeps["c2"] == ["c1"])
    // Neither is dangling: each target exists as a node.
    #expect(idx.dangling.isEmpty)
}

@Test func selfTargetIsACycle() {
    // R -> R counts as a cycle.
    let idx = DependencyIndex.build(docWithLayer([reference("self", "self")]))
    #expect(idx.cycles == ["self"])
    #expect(idx.rdeps["self"] == ["self"])
    #expect(idx.dangling.isEmpty)
}

@Test func threeCycleCollectsAllMembers() {
    // x -> y -> z -> x.
    let idx = DependencyIndex.build(docWithLayer([
        reference("x", "y"),
        reference("y", "z"),
        reference("z", "x"),
    ]))
    #expect(idx.cycles == ["x", "y", "z"])
}

@Test func nodeOffACycleIsNotReported() {
    // tail -> c1, and c1 <-> c2 is a 2-cycle. `tail` reaches the cycle but
    // is not itself on it, so it must NOT be in `cycles`.
    let idx = DependencyIndex.build(docWithLayer([
        reference("tail", "c1"),
        reference("c1", "c2"),
        reference("c2", "c1"),
    ]))
    #expect(idx.cycles == ["c1", "c2"])
    #expect(!idx.cycles.contains("tail"))
}

@Test func compoundOperandIdIsOpaque() {
    // A CompoundShape with one operand carrying id="op1". The walk does NOT
    // recurse into operands, so op1 is NOT targetable. A reference r4->op1
    // must therefore come out DANGLING, and op1 gets NO rdeps entry. This
    // pins the operands-opaque decision.
    let op1 = rectWithId("op1")
    let op2 = rectWithId(nil)
    let compound = Element.live(.compoundShape(CompoundShape(
        operation: .subtractFront,
        operands: [op1, op2],
        id: "cs"
    )))
    let idx = DependencyIndex.build(docWithLayer([compound, reference("r4", "op1")]))

    // The compound contributes no out-edge (dependencies == []), so it is
    // not in `deps`; op1 is invisible to the index entirely.
    #expect(idx.deps["cs"] == nil)
    #expect(idx.deps["op1"] == nil)
    // r4's edge to op1 is dangling because op1 is operand-nested/opaque.
    #expect(idx.deps["r4"] == ["op1"])
    #expect(idx.dangling == ["r4"])
    #expect(idx.rdeps["op1"] == nil)  // op1 is not targetable -> no rdeps entry
    // The compound IS targetable (top-level layer child) but unreferenced,
    // so it has no rdeps entry either.
    #expect(idx.rdeps["cs"] == nil)
}

@Test func groupChildrenAreWalkedButOperandsAreNot() {
    // A group nesting a reference proves the walk recurses into Group/Layer.
    let innerRef = reference("g_ref", "a")
    let group = Element.group(Group(children: [innerRef]))
    let idx = DependencyIndex.build(docWithLayer([rectWithId("a"), group]))
    // The reference nested inside the group is discovered.
    #expect(idx.deps["g_ref"] == ["a"])
    #expect(idx.rdeps["a"] == ["g_ref"])
}

@Test func canonicalJsonHasSortedKeysAndArrays() {
    // c1<->c2 cycle plus two refs to `a` and a dangling ref.
    let idx = DependencyIndex.build(docWithLayer([
        rectWithId("a"),
        reference("r2", "a"),
        reference("r1", "a"),
        reference("r3", "ghost"),
        reference("c1", "c2"),
        reference("c2", "c1"),
    ]))
    let json = dependencyIndexToTestJson(idx)
    // Top-level keys are alphabetical: cycles, dangling, deps, rdeps.
    #expect(json.hasPrefix("{\"cycles\":[\"c1\",\"c2\"],\"dangling\":[\"r3\"],"))
    // deps object keys sorted; rdeps value list sorted (r1 before r2).
    #expect(json.contains("\"a\":[\"r1\",\"r2\"]"))
    #expect(json.contains("\"r1\":[\"a\"]"))
    // Parse back as generic JSON to confirm well-formedness.
    let data = json.data(using: .utf8)!
    #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
}
