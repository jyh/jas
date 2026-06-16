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
        # Top-level keys are alphabetical: cycles, dangling, deps, rdeps.
        self.assertTrue(
            json_str.startswith('{"cycles":["c1","c2"],"dangling":["r3"],'))
        # deps object keys sorted; rdeps value list sorted (r1 before r2).
        self.assertIn('"a":["r1","r2"]', json_str)
        self.assertIn('"r1":["a"]', json_str)


if __name__ == "__main__":
    absltest.main()
