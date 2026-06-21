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
import unittest

from document.model import Model
from document.document import Document
from document.op_apply import op_apply
from geometry.element import Layer, Rect, Fill, Color, GeneratedElem
from geometry.test_json import document_to_test_json


def _rect():
    return Rect(x=0.0, y=0.0, width=10.0, height=10.0,
                fill=Fill(color=Color.rgb(1.0, 0.0, 0.0)))


def _base_doc():
    # One layer seeded with a single rect; the Generated instance lands at [0,1].
    return Document(layers=(Layer(name="L0", children=(_rect(),)),))


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


if __name__ == "__main__":
    unittest.main()
