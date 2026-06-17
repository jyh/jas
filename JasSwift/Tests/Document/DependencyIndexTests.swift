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

@Test func symbolsMasterIsTargetableAndInstanceResolves() {
    // SYMBOLS.md §6: an instance (a reference) in `layers` targeting a master
    // in `doc.symbols`. The targetable-set walk includes symbols, so the
    // instance is NOT dangling and rdeps[master] lists the instance. Mirrors
    // Rust `symbols_master_is_targetable_and_instance_resolves`.
    let master = Element.rect(Rect(x: 0, y: 0, width: 30, height: 40, id: "m1"))
    let doc = Document(
        layers: [Layer(name: "Layer", children: [reference("i1", "m1")])],
        symbols: [master])

    let idx = DependencyIndex.build(doc)
    // The instance's edge resolves to a targetable master -> not dangling.
    #expect(idx.dangling.isEmpty, "instance -> master must not be dangling")
    // rdeps[m1] is exactly the instance i1.
    #expect(idx.rdeps["m1"] == ["i1"])
    // The instance's out-edge is recorded; no cycles.
    #expect(idx.deps["i1"] == ["m1"])
    #expect(idx.cycles.isEmpty)
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

// MARK: - orphaned_references predicate (reference-aware delete core)

@Test func orphanedTargetWithTwoRefsReturnsBoth() {
    // a <- r1, r2. Deleting `a` (at [0,0]) orphans both r1 and r2.
    let doc = docWithLayer([
        rectWithId("a"),
        reference("r1", "a"),
        reference("r2", "a"),
    ])
    #expect(DependencyIndex.orphanedReferences(doc, [[0, 0]]) == ["r1", "r2"])
}

@Test func orphanedTargetPlusOneRefReturnsTheOther() {
    // Deleting `a` AND r1 ([0,0]+[0,1]) leaves only r2 orphaned; r1 is itself
    // deleted, so it is not orphaned.
    let doc = docWithLayer([
        rectWithId("a"),
        reference("r1", "a"),
        reference("r2", "a"),
    ])
    #expect(DependencyIndex.orphanedReferences(doc, [[0, 0], [0, 1]]) == ["r2"])
}

@Test func orphanedDeletingAnInstanceReturnsEmpty() {
    // Deleting a reference (an instance) orphans nothing: an instance has no
    // rdeps (nothing points AT it).
    let doc = docWithLayer([rectWithId("a"), reference("r1", "a")])
    #expect(DependencyIndex.orphanedReferences(doc, [[0, 1]]).isEmpty)
}

@Test func orphanedGroupContainingReferencedElement() {
    // A group at [0,1] contains the referenced rect `a`; an external reference
    // r1 -> a sits outside the group. Deleting the group orphans r1 (its target
    // `a` vanishes with the group).
    let group = Element.group(Group(children: [rectWithId("a")]))
    let doc = docWithLayer([reference("r1", "a"), group])
    #expect(DependencyIndex.orphanedReferences(doc, [[0, 1]]) == ["r1"])
}

// MARK: - warn-then-orphan confirm message (reference-aware delete UI)

@Test func orphanWarningBodySingularVsPlural() {
    // Verbatim, cross-language-pinned wording. Singular at n == 1.
    #expect(DependencyIndex.orphanWarningBody(1, verb: "Deleting")
        == "Deleting will leave 1 live instance empty.")
    #expect(DependencyIndex.orphanWarningBody(2, verb: "Deleting")
        == "Deleting will leave 2 live instances empty.")
    #expect(DependencyIndex.orphanWarningBody(0, verb: "Deleting")
        == "Deleting will leave 0 live instances empty.")
}

@Test func orphanWarningBodyVerbParameterizesAction() {
    // Cut reuses the same body helper, only the gerund verb differs.
    #expect(DependencyIndex.orphanWarningBody(1, verb: "Cutting")
        == "Cutting will leave 1 live instance empty.")
    #expect(DependencyIndex.orphanWarningBody(2, verb: "Cutting")
        == "Cutting will leave 2 live instances empty.")
}

@Test func orphanWarningPathTriggersOnlyWhenNonEmpty() {
    // Two refs to `a`: deleting `a` orphans both -> warn (n == 2).
    let doc = docWithLayer([
        rectWithId("a"),
        reference("r1", "a"),
        reference("r2", "a"),
    ])
    let orphaned = DependencyIndex.orphanedReferences(doc, [[0, 0]])
    #expect(orphaned.count == 2)
    #expect(DependencyIndex.orphanWarningBody(orphaned.count, verb: "Deleting")
        == "Deleting will leave 2 live instances empty.")

    // Deleting a plain rect with no referrers -> no warn (empty).
    let plain = docWithLayer([rectWithId("a")])
    #expect(DependencyIndex.orphanedReferences(plain, [[0, 0]]).isEmpty)
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
    // Top-level keys are alphabetical: cycles, dangling, deps, rdeps, topo_order.
    #expect(json.hasPrefix("{\"cycles\":[\"c1\",\"c2\"],\"dangling\":[\"r3\"],"))
    // deps object keys sorted; rdeps value list sorted (r1 before r2).
    #expect(json.contains("\"a\":[\"r1\",\"r2\"]"))
    #expect(json.contains("\"r1\":[\"a\"]"))
    // topo_order is the LAST key (alphabetical) and its VALUE is the topo
    // sequence: level 0 {a, r3} (r3 dangling -> count 0) emitted sorted,
    // freeing r1, r2 for level 1; c1/c2 cycle remnants trail in sorted order.
    #expect(json.contains("\"topo_order\":[\"a\",\"r3\",\"r1\",\"r2\",\"c1\",\"c2\"]"))
    // Parse back as generic JSON to confirm well-formedness.
    let data = json.data(using: .utf8)!
    #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
}

// MARK: - topoOrder (Phase 4a — LOCKED algorithm)
//
// Kahn with sorted-id tie-break; dependencies-first; cycle remnants appended in
// sorted order. These tests pin the deterministic sequence the algorithm must
// produce; the SAME cases are mirrored across all four apps.

@Test func topoOrderWorkedExampleMatchesLockedSpec() {
    // The cross-language fixture graph (REFERENCE_GRAPH.md §8 worked example):
    // deps c1<->c2, r1->a, r2->a, r3->ghost, r4->op1; nodes are
    // {a,c1,c2,r1,r2,r3,r4} (ghost/op1 are non-nodes). Expected sequence:
    // ready {a,r3,r4} sorted -> a,r3,r4 frees r1,r2 -> r1,r2; cycle c1,c2 trail.
    let op1 = rectWithId("op1")
    let op2 = rectWithId(nil)
    let compound = Element.live(.compoundShape(CompoundShape(
        operation: .subtractFront,
        operands: [op1, op2],
        id: "cs"
    )))
    let idx = DependencyIndex.build(docWithLayer([
        rectWithId("a"),
        reference("r1", "a"),
        reference("r2", "a"),
        reference("r3", "ghost"),
        reference("c1", "c2"),
        reference("c2", "c1"),
        compound,
        reference("r4", "op1"),
    ]))
    #expect(idx.topoOrder == ["a", "r3", "r4", "r1", "r2", "c1", "c2"])
}

@Test func topoOrderChainIsDependenciesFirst() {
    // The chain/diamond fixture graph: b; s1->b; s2->s1; t1->b; t2->b; d1->s1.
    // Level-by-level Kahn:
    //   level 0: {b}                  emit b      -> frees s1, t1, t2
    //   level 1: {s1, t1, t2} sorted  emit s1,t1,t2 -> emitting s1 frees d1, s2
    //   level 2: {d1, s2} sorted      emit d1, s2
    // Expected: b, s1, t1, t2, d1, s2.
    let idx = DependencyIndex.build(docWithLayer([
        rectWithId("b"),
        reference("s1", "b"),
        reference("s2", "s1"),
        reference("t1", "b"),
        reference("t2", "b"),
        reference("d1", "s1"),
    ]))
    #expect(idx.topoOrder == ["b", "s1", "t1", "t2", "d1", "s2"])
    // Dependencies-first invariant: every target precedes its referrer.
    func pos(_ id: String) -> Int { idx.topoOrder.firstIndex(of: id)! }
    #expect(pos("b") < pos("s1"))
    #expect(pos("b") < pos("t1"))
    #expect(pos("b") < pos("t2"))
    #expect(pos("s1") < pos("s2"))
    #expect(pos("s1") < pos("d1"))
    #expect(idx.cycles.isEmpty)
}

@Test func topoOrderPureDagNoCycleFullOrdering() {
    // A pure DAG with no cycle: a -> b -> c (a depends on b depends on c).
    // Dependencies-first means c, b, a — the reverse of the reference chain.
    let idx = DependencyIndex.build(docWithLayer([
        rectWithId("c"),
        reference("b", "c"),
        reference("a", "b"),
    ]))
    #expect(idx.cycles.isEmpty)
    #expect(idx.topoOrder == ["c", "b", "a"])
}

@Test func topoOrderAllDanglingIsEmpty() {
    // Every reference points at an absent target -> the targets are NOT nodes,
    // so the only nodes are the referencing ids, all with dependency count 0.
    // They emit in sorted order and none is cyclic/dangling-as-node.
    let idx = DependencyIndex.build(docWithLayer([
        reference("z", "ghost1"),
        reference("a", "ghost2"),
        reference("m", "ghost3"),
    ]))
    // All three referrers are dangling (their targets are absent).
    #expect(idx.dangling == ["a", "m", "z"])
    // No present targets -> no rdeps; nodes are just the 3 sources, all ready
    // immediately -> emitted in sorted id order.
    #expect(idx.rdeps.isEmpty)
    #expect(idx.cycles.isEmpty)
    #expect(idx.topoOrder == ["a", "m", "z"])
}

@Test func topoOrderTrulyEmptyGraphIsEmpty() {
    // No id-bearing elements -> no nodes -> empty topo order.
    let idx = DependencyIndex.build(docWithLayer([rectWithId(nil)]))
    #expect(idx.topoOrder.isEmpty)
}

@Test func topoOrderCycleRemnantsTrailInSortedOrder() {
    // A DAG prefix feeding a cycle, plus an unrelated cyclic pair, to pin that
    // ALL cycle members trail at the end in sorted-id order while the acyclic
    // part is emitted dependencies-first.
    // Graph: head -> root (root is a plain rect, count 0);
    //        a cycle z<->y; a cycle q<->p.
    // Acyclic nodes: root (0), head (1, dep root). Emit root, head.
    // Cyclic nodes never reach 0: p,q,y,z -> trail sorted: p,q,y,z.
    let idx = DependencyIndex.build(docWithLayer([
        rectWithId("root"),
        reference("head", "root"),
        reference("z", "y"),
        reference("y", "z"),
        reference("q", "p"),
        reference("p", "q"),
    ]))
    #expect(idx.cycles == ["p", "q", "y", "z"])
    #expect(idx.topoOrder == ["root", "head", "p", "q", "y", "z"])
}

@Test func topoOrderNodeBlockedByCycleTrailsWithRemnants() {
    // A node that DEPENDS on a cycle but is not ON it (tail -> c1, c1<->c2)
    // never reaches dependency-count 0, so it is a remnant too. The remnants
    // are ALL un-emitted nodes appended in sorted order — here the superset
    // {c1, c2, tail}, NOT just the cycle set {c1, c2}. There is no acyclic
    // prefix (every node is blocked), so topoOrder is exactly the sorted
    // remnants. This pins that `cycles` is a SUBSET of the remnants.
    let idx = DependencyIndex.build(docWithLayer([
        reference("tail", "c1"),
        reference("c1", "c2"),
        reference("c2", "c1"),
    ]))
    #expect(idx.cycles == ["c1", "c2"])
    #expect(idx.topoOrder == ["c1", "c2", "tail"],
        "tail is blocked by the cycle -> a remnant, appended sorted after the cycle")
}

@Test func topoOrderSelfCycleNodeTrails() {
    // A self-targeting reference is a cycle of one; it must trail after the
    // acyclic nodes in sorted order. tail -> leaf (leaf count 0); self -> self.
    let idx = DependencyIndex.build(docWithLayer([
        rectWithId("leaf"),
        reference("tail", "leaf"),
        reference("self", "self"),
    ]))
    #expect(idx.cycles == ["self"])
    #expect(idx.topoOrder == ["leaf", "tail", "self"])
}
