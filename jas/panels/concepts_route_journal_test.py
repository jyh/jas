"""CONCEPTS.md §7 / OP_LOG.md §6 — concept-pack op replay determinism (Python jas).

Mirrors Rust's ``operation_concept_ops_replay_is_deterministic`` in
``jas_dioxus/src/cross_language_test.rs``: the two verbs the Concepts panel emits
(``place_concept_instance`` / ``set_concept_param``) now have op_apply replay arms
and journal as real ops, so a placed + tuned concept instance replays from the
journal byte-identically to the live document (the checkpoint_equivalence gate),
even though the registry the defaults came from is never consulted on replay (every
operand is VALUE-IN-OP).
"""

import copy
import math
import unittest

from document.model import Model
from document.document import Document
from document.op_apply import op_apply
from geometry.element import (
    Layer, Rect, Fill, Color, GeneratedElem, Polygon)
from geometry.test_json import document_to_test_json


def _rect():
    return Rect(x=0.0, y=0.0, width=10.0, height=10.0,
                fill=Fill(color=Color.rgb(1.0, 0.0, 0.0)))


def _base_doc():
    # One layer seeded with a single rect; the Generated instance lands at [0,1].
    return Document(layers=(Layer(name="L0", children=(_rect(),)),))


def _hexagon_points(radius=50.0):
    # A canonical regular hexagon (first vertex on +x, centred at origin) —
    # exactly what regular_polygon{sides:6, radius:50} generates / the fitter
    # recovers as [6, 50, 0, 0, 0].
    return tuple(
        (radius * math.cos(math.radians(60.0 * i)),
         radius * math.sin(math.radians(60.0 * i)))
        for i in range(6)
    )


def _polygon_doc():
    # One layer seeded with a single raw hexagon Polygon at [0,0] — the
    # promote target.
    return Document(layers=(
        Layer(name="L0", children=(Polygon(points=_hexagon_points()),)),))


class ConceptOpsReplayTests(unittest.TestCase):

    def test_concept_ops_replay_is_deterministic(self):
        model = Model(document=_base_doc())
        pre = copy.deepcopy(model.document)

        # Place a hexagon instance with a literal id + resolved default params,
        # then tune one param (sides 6 -> 8). Each op is bracketed as one named
        # undo step, exactly as the panel handler routes it.
        model.begin_txn()
        model.name_txn("place_concept_instance")
        op_apply(model, {
            "op": "place_concept_instance",
            "concept_id": "regular_polygon",
            "params": {"sides": 6.0, "radius": 50.0},
            "elem_id": "concept-1",
        })
        model.commit_txn()

        model.begin_txn()
        model.name_txn("set_concept_param")
        op_apply(model, {
            "op": "set_concept_param",
            "path": [0, 1],
            "name": "sides",
            "value": 8.0,
        })
        model.commit_txn()

        # (a) the doc mutated: a Generated element with the right concept + id,
        #     sides tuned to 8.
        el = model.document.get_element((0, 1))
        self.assertIsInstance(el, GeneratedElem)
        self.assertEqual(el.concept_id, "regular_polygon")
        self.assertEqual(el.id, "concept-1")
        self.assertEqual(el.params["sides"], 8.0)
        self.assertEqual(el.params["radius"], 50.0)

        # (b) the journal recorded both verbs (the replayable entries).
        self.assertEqual(model.journal[0].name, "place_concept_instance")
        self.assertEqual(model.journal[1].name, "set_concept_param")
        self.assertIn(
            "place_concept_instance",
            [o.op for txn in model.journal[:model.journal_head] for o in txn.ops],
        )
        self.assertIn(
            "set_concept_param",
            [o.op for txn in model.journal[:model.journal_head] for o in txn.ops],
        )

        # checkpoint_equivalence: the journal replays to the SAME document, and
        # two independent replays agree (VALUE-IN-OP operands reproduce the
        # Generated instance + tuned param byte-identically; the registry is
        # never consulted on replay).
        live = document_to_test_json(model.document)

        def _replay():
            m = Model(document=copy.deepcopy(pre))
            for txn in model.journal[:model.journal_head]:
                for o in txn.ops:
                    op_apply(m, o.params)
            return document_to_test_json(m.document)

        replay1 = _replay()
        replay2 = _replay()
        self.assertEqual(replay1, replay2,
                         "concept-op replay is non-deterministic")
        self.assertEqual(replay1, live,
                         "concept-op journal replay != snapshot path")

        # One undo round-trips the LAST op (one gesture = one undo step).
        model.undo()
        el = model.document.get_element((0, 1))
        self.assertEqual(el.params["sides"], 6.0)

    def test_apply_concept_operation_replay_is_deterministic(self):
        # CONCEPTS.md §9 — apply_concept_operation journals + replays byte-
        # identically. The op carries the production-RESOLVED changes map
        # value-in-op (here {sides: 7}, the add_side result), so replay merges it
        # without re-evaluating the operation's expression nor consulting the
        # registry — the checkpoint_equivalence gate for the operations verb.
        # Mirrors Rust operation_apply_concept_operation_replay_is_deterministic.
        model = Model(document=_base_doc())
        pre = copy.deepcopy(model.document)

        # Place a hexagon instance (lands at [0,1] beside the seed rect).
        model.begin_txn()
        model.name_txn("place_concept_instance")
        op_apply(model, {
            "op": "place_concept_instance",
            "concept_id": "regular_polygon",
            "params": {"sides": 6.0, "radius": 50.0},
            "elem_id": "concept-1",
        })
        model.commit_txn()

        # add_side, resolved at production time to { sides: 7 }, journaled with
        # its op_id as metadata and the changes as the authoritative operand.
        model.begin_txn()
        model.name_txn("apply_concept_operation")
        op_apply(model, {
            "op": "apply_concept_operation",
            "path": [0, 1],
            "op_id": "add_side",
            "changes": {"sides": 7.0},
        })
        model.commit_txn()

        # (a) the operation merged sides=7 (radius untouched).
        el = model.document.get_element((0, 1))
        self.assertIsInstance(el, GeneratedElem)
        self.assertEqual(el.params["sides"], 7.0)
        self.assertEqual(el.params["radius"], 50.0)

        # (b) the journal recorded the verb (the replayable entry).
        self.assertEqual(model.journal[1].name, "apply_concept_operation")
        self.assertIn(
            "apply_concept_operation",
            [o.op for txn in model.journal[:model.journal_head] for o in txn.ops],
        )

        # checkpoint_equivalence: the journal replays to the SAME document, and
        # two independent replays agree (replay merges the value-in-op changes;
        # the registry / expressions are never consulted on replay).
        live = document_to_test_json(model.document)

        def _replay():
            m = Model(document=copy.deepcopy(pre))
            for txn in model.journal[:model.journal_head]:
                for o in txn.ops:
                    op_apply(m, o.params)
            return document_to_test_json(m.document)

        replay1 = _replay()
        replay2 = _replay()
        self.assertEqual(replay1, replay2,
                         "apply_concept_operation replay is non-deterministic")
        self.assertEqual(replay1, live,
                         "apply_concept_operation journal replay != snapshot path")

        # One undo round-trips the operation (one gesture = one undo step).
        model.undo()
        el = model.document.get_element((0, 1))
        self.assertEqual(el.params["sides"], 6.0)

    def test_promote_to_concept_replay_is_deterministic(self):
        # CONCEPTS.md §10 — promote_to_concept journals + replays byte-
        # identically. Every operand is value-in-op (the detection ran at
        # production time): the concept id, recovered params, and placement
        # transform are baked into the op, so replay rebuilds the SAME Generated
        # element that replaced the raw polygon — the checkpoint_equivalence gate
        # for the promote verb. Mirrors Rust
        # operation_promote_to_concept_replay_is_deterministic.
        model = Model(document=_polygon_doc())
        pre = copy.deepcopy(model.document)

        model.begin_txn()
        model.name_txn("promote_to_concept")
        op_apply(model, {
            "op": "promote_to_concept",
            "path": [0, 0],
            "concept_id": "regular_polygon",
            "params": {"sides": 6.0, "radius": 50.0},
            "transform": [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
        })
        model.commit_txn()

        # (a) the raw polygon was promoted to a Generated instance.
        el = model.document.get_element((0, 0))
        self.assertIsInstance(el, GeneratedElem)
        self.assertEqual(el.concept_id, "regular_polygon")
        self.assertEqual(el.params["sides"], 6.0)

        # (b) the journal recorded the verb (the replayable entry).
        self.assertEqual(model.journal[0].name, "promote_to_concept")
        self.assertIn(
            "promote_to_concept",
            [o.op for txn in model.journal[:model.journal_head] for o in txn.ops],
        )

        # checkpoint_equivalence: the journal replays to the SAME document, and
        # two independent replays agree (the fitter is NEVER re-run on replay; the
        # value-in-op concept id + params + transform rebuild the Generated).
        live = document_to_test_json(model.document)

        def _replay():
            m = Model(document=copy.deepcopy(pre))
            for txn in model.journal[:model.journal_head]:
                for o in txn.ops:
                    op_apply(m, o.params)
            return document_to_test_json(m.document)

        replay1 = _replay()
        replay2 = _replay()
        self.assertEqual(replay1, replay2,
                         "promote_to_concept replay is non-deterministic")
        self.assertEqual(replay1, live,
                         "promote_to_concept journal replay != snapshot path")

        # One undo round-trips the promotion (one gesture = one undo step).
        model.undo()
        el = model.document.get_element((0, 0))
        self.assertIsInstance(el, Polygon)


class GeneratorFitterRoundTripTests(unittest.TestCase):
    """CONCEPTS.md §10 — the generator and fitter are inverses (the round-trip
    property). Generate a regular_polygon's vertices, feed them back through the
    SAME concept's fitter, and assert it recovers [sides, radius, 0, 0, 0]
    (canonical placement: origin-centred, first vertex on +x => rotation 0). Both
    expressions are read from the compiled registry, so this pins that a concept's
    two halves agree. Mirrors Rust generator_fitter_round_trip."""

    def _unwrap(self, v):
        return v.value if hasattr(v, "value") else v

    def test_generator_fitter_round_trip(self):
        from panels.yaml_menu import get_workspace_data
        from workspace_interpreter.expr import evaluate
        from workspace_interpreter.expr_types import ValueType

        ws = get_workspace_data()
        concept = (ws or {}).get("concepts", {}).get("regular_polygon")
        self.assertIsInstance(concept, dict)
        generator = concept["generator"]
        fitter = concept["fitter"]

        for sides, radius in [(6.0, 50.0), (4.0, 10.0), (5.0, 25.0)]:
            # Generate the canonical points.
            g = evaluate(generator, {"param": {"sides": sides, "radius": radius}})
            self.assertEqual(g.type, ValueType.LIST,
                             f"generator returned non-list for sides={sides}")
            pts = [[self._unwrap(c) for c in self._unwrap(p)] for p in g.value]
            # Fit them back.
            f = evaluate(fitter, {"shape": {"points": pts}})
            self.assertEqual(f.type, ValueType.LIST,
                             f"fitter returned non-list for sides={sides}")
            nums = [float(self._unwrap(x)) for x in f.value]
            expected = [sides, radius, 0.0, 0.0, 0.0]
            self.assertEqual(len(nums), len(expected),
                             f"fitter arity for sides={sides}")
            for i, (gv, ev) in enumerate(zip(nums, expected)):
                self.assertAlmostEqual(
                    gv, ev, places=9,
                    msg=f"round-trip sides={sides} radius={radius} output[{i}]")


if __name__ == "__main__":
    unittest.main()
