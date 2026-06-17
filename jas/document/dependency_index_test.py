"""Unit tests for the derived DEPENDENCY INDEX (REFERENCE_GRAPH.md §3).

Mirrors the 11 Rust unit tests in
``jas_dioxus/src/document/dependency_index.rs``. The index is a pure function
of the Document over the by-id reference graph; operands are OPAQUE (the walk
recurses Group/Layer children only).
"""

from absl.testing import absltest

from document.dependency_index import (
    dependency_index,
    dependency_index_to_test_json,
    orphaned_references,
)
from document.document import Document
from geometry.element import (
    CompoundOperation,
    CompoundShape,
    Group,
    Layer,
    Rect,
    ReferenceElem,
)


def _rect_with_id(eid):
    """A plain rect at the origin, optionally carrying a stable id."""
    return Rect(x=0.0, y=0.0, width=10.0, height=10.0, id=eid)


def _reference(eid, target):
    """A live reference with id ``eid`` targeting ``target``."""
    return ReferenceElem(target=target, id=eid)


def _doc_with_layer(children):
    """A document with a single layer named "Layer" wrapping ``children``."""
    return Document(layers=(Layer(name="Layer", children=tuple(children)),))


class DependencyIndexTest(absltest.TestCase):

    def test_empty_document_has_empty_index(self):
        idx = dependency_index(_doc_with_layer([]))
        self.assertEqual(idx.deps, {})
        self.assertEqual(idx.rdeps, {})
        self.assertEqual(idx.dangling, [])
        self.assertEqual(idx.cycles, [])

    def test_deps_and_rdeps_for_two_references_to_one_target(self):
        # a <- r1, a <- r2.
        idx = dependency_index(_doc_with_layer([
            _rect_with_id("a"),
            _reference("r1", "a"),
            _reference("r2", "a"),
        ]))
        self.assertEqual(idx.deps.get("r1"), ["a"])
        self.assertEqual(idx.deps.get("r2"), ["a"])
        # rdeps of `a` lists r1, r2 sorted; `a` is targetable (a plain rect).
        self.assertEqual(idx.rdeps.get("a"), ["r1", "r2"])
        self.assertEqual(idx.dangling, [])
        self.assertEqual(idx.cycles, [])

    def test_id_less_element_is_not_a_node(self):
        # The rect has no id; only the reference is a node, and its target is
        # absent -> dangling. The id-less rect appears nowhere in the index.
        idx = dependency_index(_doc_with_layer([
            _rect_with_id(None),
            _reference("r", "ghost"),
        ]))
        self.assertEqual(len(idx.deps), 1)
        self.assertEqual(idx.deps.get("r"), ["ghost"])
        self.assertEqual(idx.rdeps, {}, "ghost is not targetable -> no rdeps")
        self.assertEqual(idx.dangling, ["r"])

    def test_dangling_when_target_absent(self):
        idx = dependency_index(_doc_with_layer([_reference("r3", "ghost")]))
        self.assertEqual(idx.dangling, ["r3"])
        self.assertEqual(idx.rdeps, {})
        self.assertEqual(idx.cycles, [])

    def test_two_cycle_is_detected(self):
        # c1 -> c2 -> c1.
        idx = dependency_index(_doc_with_layer([
            _reference("c1", "c2"),
            _reference("c2", "c1"),
        ]))
        self.assertEqual(idx.cycles, ["c1", "c2"])
        # Both are targetable references, so each appears in the other's rdeps.
        self.assertEqual(idx.rdeps.get("c1"), ["c2"])
        self.assertEqual(idx.rdeps.get("c2"), ["c1"])
        # Neither is dangling: each target exists as a node.
        self.assertEqual(idx.dangling, [])

    def test_self_target_is_a_cycle(self):
        # R -> R counts as a cycle.
        idx = dependency_index(_doc_with_layer([_reference("self", "self")]))
        self.assertEqual(idx.cycles, ["self"])
        self.assertEqual(idx.rdeps.get("self"), ["self"])
        self.assertEqual(idx.dangling, [])

    def test_three_cycle_collects_all_members(self):
        # x -> y -> z -> x.
        idx = dependency_index(_doc_with_layer([
            _reference("x", "y"),
            _reference("y", "z"),
            _reference("z", "x"),
        ]))
        self.assertEqual(idx.cycles, ["x", "y", "z"])

    def test_node_off_a_cycle_is_not_reported(self):
        # tail -> c1, and c1 <-> c2 is a 2-cycle. `tail` reaches the cycle but
        # is not itself on it, so it must NOT be in `cycles`.
        idx = dependency_index(_doc_with_layer([
            _reference("tail", "c1"),
            _reference("c1", "c2"),
            _reference("c2", "c1"),
        ]))
        self.assertEqual(idx.cycles, ["c1", "c2"])
        self.assertNotIn("tail", idx.cycles)

    def test_compound_operand_id_is_opaque(self):
        # A CompoundShape with one operand carrying id="op1". The walk does NOT
        # recurse into operands, so op1 is NOT targetable. A reference r4->op1
        # must therefore come out DANGLING, and op1 gets NO rdeps entry. This
        # pins the operands-opaque decision.
        op1 = _rect_with_id("op1")
        op2 = _rect_with_id(None)
        compound = CompoundShape(
            operation=CompoundOperation.SUBTRACT_FRONT,
            operands=(op1, op2),
            id="cs",
        )
        idx = dependency_index(_doc_with_layer([
            compound,
            _reference("r4", "op1"),
        ]))
        # The compound contributes no out-edge (dependencies() == []), so it is
        # not in `deps`; op1 is invisible to the index entirely.
        self.assertNotIn("cs", idx.deps)
        self.assertNotIn("op1", idx.deps)
        # r4's edge to op1 is dangling because op1 is operand-nested/opaque.
        self.assertEqual(idx.deps.get("r4"), ["op1"])
        self.assertEqual(idx.dangling, ["r4"])
        self.assertNotIn("op1", idx.rdeps)
        # The compound IS targetable (top-level layer child) but unreferenced,
        # so it has no rdeps entry either.
        self.assertNotIn("cs", idx.rdeps)

    def test_group_children_are_walked_but_operands_are_not(self):
        # A group nesting a reference proves the walk recurses into Group/Layer.
        inner_ref = _reference("g_ref", "a")
        group = Group(children=(inner_ref,))
        idx = dependency_index(_doc_with_layer([
            _rect_with_id("a"),
            group,
        ]))
        # The reference nested inside the group is discovered.
        self.assertEqual(idx.deps.get("g_ref"), ["a"])
        self.assertEqual(idx.rdeps.get("a"), ["g_ref"])

    def test_symbols_master_is_targetable_and_instance_resolves(self):
        # SYMBOLS.md §6: an instance (a reference) in `layers` targeting a
        # master in `doc.symbols`. The targetable-set walk includes symbols,
        # so the instance is NOT dangling and rdeps[master] lists the instance.
        from dataclasses import replace
        master = replace(_rect_with_id("m1"), width=30.0, height=40.0)
        doc = replace(
            _doc_with_layer([_reference("i1", "m1")]),
            symbols=(master,))

        idx = dependency_index(doc)
        # The instance's edge resolves to a targetable master -> not dangling.
        self.assertEqual(idx.dangling, [],
                         "instance -> master must not be dangling")
        # rdeps[m1] is exactly the instance i1.
        self.assertEqual(idx.rdeps.get("m1"), ["i1"])
        # The instance's out-edge is recorded; no cycles.
        self.assertEqual(idx.deps.get("i1"), ["m1"])
        self.assertEqual(idx.cycles, [])

    # -----------------------------------------------------------------------
    # orphaned_references predicate (reference-aware delete core)
    # -----------------------------------------------------------------------

    def test_orphaned_target_with_two_refs_returns_both(self):
        # a <- r1, r2. Deleting `a` (at [0,0]) orphans both r1 and r2.
        doc = _doc_with_layer([
            _rect_with_id("a"),
            _reference("r1", "a"),
            _reference("r2", "a"),
        ])
        self.assertEqual(
            orphaned_references(doc, [[0, 0]]), ["r1", "r2"])

    def test_orphaned_target_plus_one_ref_returns_the_other(self):
        # Deleting `a` AND r1 ([0,0]+[0,1]) leaves only r2 orphaned; r1 is
        # itself deleted, so it is not orphaned.
        doc = _doc_with_layer([
            _rect_with_id("a"),
            _reference("r1", "a"),
            _reference("r2", "a"),
        ])
        self.assertEqual(
            orphaned_references(doc, [[0, 0], [0, 1]]), ["r2"])

    def test_orphaned_deleting_an_instance_returns_empty(self):
        # Deleting a reference (an instance) orphans nothing: an instance has
        # no rdeps (nothing points AT it).
        doc = _doc_with_layer([_rect_with_id("a"), _reference("r1", "a")])
        self.assertEqual(orphaned_references(doc, [[0, 1]]), [])

    def test_orphaned_group_containing_referenced_element(self):
        # A group at [0,1] contains the referenced rect `a`; an external
        # reference r1 -> a sits outside the group. Deleting the group orphans
        # r1 (its target `a` vanishes with the group).
        group = Group(children=(_rect_with_id("a"),))
        doc = _doc_with_layer([_reference("r1", "a"), group])
        self.assertEqual(orphaned_references(doc, [[0, 1]]), ["r1"])

    def test_canonical_json_has_sorted_keys_and_arrays(self):
        # c1<->c2 cycle plus two refs to `a` and a dangling ref.
        idx = dependency_index(_doc_with_layer([
            _rect_with_id("a"),
            _reference("r2", "a"),
            _reference("r1", "a"),
            _reference("r3", "ghost"),
            _reference("c1", "c2"),
            _reference("c2", "c1"),
        ]))
        json_str = dependency_index_to_test_json(idx)
        # Top-level keys are alphabetical: cycles, dangling, deps, rdeps, topo_order.
        self.assertTrue(
            json_str.startswith('{"cycles":["c1","c2"],"dangling":["r3"],'))
        # deps object keys sorted; rdeps value list sorted (r1 before r2).
        self.assertIn('"a":["r1","r2"]', json_str)
        self.assertIn('"r1":["a"]', json_str)
        # topo_order is the LAST key (alphabetical) and its VALUE is the topo
        # sequence: level 0 {a, r3} (r3 dangling -> count 0) emitted sorted,
        # freeing r1, r2 for level 1; c1/c2 cycle remnants trail in sorted order.
        self.assertIn(
            '"topo_order":["a","r3","r1","r2","c1","c2"]', json_str)

    # -----------------------------------------------------------------------
    # topo_order (Phase 4a -- LOCKED algorithm). Kahn with sorted-id tie-break;
    # dependencies-first; cycle remnants appended in sorted order. These tests
    # pin the deterministic sequence the algorithm must produce; the SAME cases
    # are mirrored across all four apps.
    # -----------------------------------------------------------------------

    def test_topo_order_worked_example_matches_locked_spec(self):
        # The cross-language fixture graph (REFERENCE_GRAPH.md §8 worked
        # example): deps c1<->c2, r1->a, r2->a, r3->ghost, r4->op1; nodes are
        # {a,c1,c2,r1,r2,r3,r4} (ghost/op1 are non-nodes). Expected sequence:
        # ready {a,r3,r4} sorted -> a,r3,r4 frees r1,r2 -> r1,r2; cycle c1,c2 trail.
        op1 = _rect_with_id("op1")
        op2 = _rect_with_id(None)
        compound = CompoundShape(
            operation=CompoundOperation.SUBTRACT_FRONT,
            operands=(op1, op2),
            id="cs",
        )
        idx = dependency_index(_doc_with_layer([
            _rect_with_id("a"),
            _reference("r1", "a"),
            _reference("r2", "a"),
            _reference("r3", "ghost"),
            _reference("c1", "c2"),
            _reference("c2", "c1"),
            compound,
            _reference("r4", "op1"),
        ]))
        self.assertEqual(
            idx.topo_order, ["a", "r3", "r4", "r1", "r2", "c1", "c2"])

    def test_topo_order_chain_is_dependencies_first(self):
        # The chain/diamond fixture graph: b; s1->b; s2->s1; t1->b; t2->b; d1->s1.
        # Level-by-level Kahn:
        #   level 0: {b}                  emit b      -> frees s1, t1, t2
        #   level 1: {s1, t1, t2} sorted  emit s1,t1,t2 -> emitting s1 frees d1, s2
        #   level 2: {d1, s2} sorted      emit d1, s2
        # Expected: b, s1, t1, t2, d1, s2.
        idx = dependency_index(_doc_with_layer([
            _rect_with_id("b"),
            _reference("s1", "b"),
            _reference("s2", "s1"),
            _reference("t1", "b"),
            _reference("t2", "b"),
            _reference("d1", "s1"),
        ]))
        self.assertEqual(
            idx.topo_order, ["b", "s1", "t1", "t2", "d1", "s2"])
        # Dependencies-first invariant: every target precedes its referrer.
        pos = idx.topo_order.index
        self.assertLess(pos("b"), pos("s1"))
        self.assertLess(pos("b"), pos("t1"))
        self.assertLess(pos("b"), pos("t2"))
        self.assertLess(pos("s1"), pos("s2"))
        self.assertLess(pos("s1"), pos("d1"))
        self.assertEqual(idx.cycles, [])

    def test_topo_order_pure_dag_no_cycle_full_ordering(self):
        # A pure DAG with no cycle: a -> b -> c (a depends on b depends on c).
        # Dependencies-first means c, b, a -- the reverse of the reference chain.
        idx = dependency_index(_doc_with_layer([
            _rect_with_id("c"),
            _reference("b", "c"),
            _reference("a", "b"),
        ]))
        self.assertEqual(idx.cycles, [])
        self.assertEqual(idx.topo_order, ["c", "b", "a"])

    def test_topo_order_all_dangling_is_empty(self):
        # Every reference points at an absent target -> the targets are NOT
        # nodes, so the only nodes are the referencing ids, all with dependency
        # count 0. They emit in sorted order and none is cyclic/dangling-as-node.
        idx = dependency_index(_doc_with_layer([
            _reference("z", "ghost1"),
            _reference("a", "ghost2"),
            _reference("m", "ghost3"),
        ]))
        # All three referrers are dangling (their targets are absent).
        self.assertEqual(idx.dangling, ["a", "m", "z"])
        # No present targets -> no rdeps; nodes are just the 3 sources, all
        # ready immediately -> emitted in sorted id order.
        self.assertEqual(idx.rdeps, {})
        self.assertEqual(idx.cycles, [])
        self.assertEqual(idx.topo_order, ["a", "m", "z"])

    def test_topo_order_truly_empty_graph_is_empty(self):
        # No id-bearing elements -> no nodes -> empty topo order.
        idx = dependency_index(_doc_with_layer([_rect_with_id(None)]))
        self.assertEqual(idx.topo_order, [])

    def test_topo_order_cycle_remnants_trail_in_sorted_order(self):
        # A DAG prefix feeding a cycle, plus an unrelated cyclic pair, to pin
        # that ALL cycle members trail at the end in sorted-id order while the
        # acyclic part is emitted dependencies-first.
        # Graph: head -> root (root is a plain rect, count 0);
        #        a cycle z<->y; a cycle q<->p.
        # Acyclic nodes: root (0), head (1, dep root). Emit root, head.
        # Cyclic nodes never reach 0: p,q,y,z -> trail sorted: p,q,y,z.
        idx = dependency_index(_doc_with_layer([
            _rect_with_id("root"),
            _reference("head", "root"),
            _reference("z", "y"),
            _reference("y", "z"),
            _reference("q", "p"),
            _reference("p", "q"),
        ]))
        self.assertEqual(idx.cycles, ["p", "q", "y", "z"])
        self.assertEqual(
            idx.topo_order, ["root", "head", "p", "q", "y", "z"])

    def test_topo_order_node_blocked_by_cycle_trails_with_remnants(self):
        # A node that DEPENDS on a cycle but is not ON it (tail -> c1, c1<->c2)
        # never reaches dependency-count 0, so it is a remnant too. The remnants
        # are ALL un-emitted nodes appended in sorted order -- here the superset
        # {c1, c2, tail}, NOT just the cycle set {c1, c2}. There is no acyclic
        # prefix (every node is blocked), so topo_order is exactly the sorted
        # remnants. This pins that `cycles` is a SUBSET of the remnants.
        idx = dependency_index(_doc_with_layer([
            _reference("tail", "c1"),
            _reference("c1", "c2"),
            _reference("c2", "c1"),
        ]))
        self.assertEqual(idx.cycles, ["c1", "c2"])
        self.assertEqual(
            idx.topo_order, ["c1", "c2", "tail"],
            "tail is blocked by the cycle -> a remnant, appended sorted "
            "after the cycle")

    def test_topo_order_self_cycle_node_trails(self):
        # A self-targeting reference is a cycle of one; it must trail after the
        # acyclic nodes in sorted order. tail -> leaf (leaf count 0); self -> self.
        idx = dependency_index(_doc_with_layer([
            _rect_with_id("leaf"),
            _reference("tail", "leaf"),
            _reference("self", "self"),
        ]))
        self.assertEqual(idx.cycles, ["self"])
        self.assertEqual(idx.topo_order, ["leaf", "tail", "self"])


if __name__ == "__main__":
    absltest.main()
