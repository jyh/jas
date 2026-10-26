"""`doc.op`: apply one journaled op by name to the store's document.

The model verbs (`unlock_all`, `show_all`, ...) were `log` stubs whose meaning
lived in one native table per port. `doc.op` routes an action to the op layer
every port already has; in the reference that is `document/op_apply.py`, run
on the store's dict document through the test-JSON bridge, so the reference's
meaning of `unlock_all` IS `Controller.unlock_all`.
"""

from __future__ import annotations

import json
import os
import sys

# The op layer lives beside the frozen Python app (``document.op_apply``), the
# same import root as `test_character_apply.py`'s bridge-level arms.
_JAS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "jas"))
if _JAS_DIR not in sys.path:
    sys.path.insert(0, _JAS_DIR)

from dataclasses import replace

from document.document import Document, ElementSelection
from geometry.element import Layer, Rect, Visibility
from geometry.test_json import document_to_test_json, test_json_to_document

from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore


def _store(doc: Document) -> StateStore:
    d = json.loads(document_to_test_json(doc))
    # A store-only key the bridge does not produce: it must survive the op.
    d["artboard_options"] = {"fade_region_outside_artboard": True}
    return StateStore(document=d)


def _doc_of(store: StateStore) -> Document:
    return test_json_to_document(json.dumps(
        {k: v for k, v in store._document.items() if k != "artboard_options"}))


def _two_rects(first: Rect, second: Rect, *, layer_locked=False) -> Document:
    layer = Layer(name="L", children=(first, second), locked=layer_locked)
    return Document(layers=(layer,))


def _rect(**kw) -> Rect:
    return Rect(x=0, y=0, width=10, height=10, **kw)


def test_unlock_all_clears_every_lock_and_keeps_the_selection():
    doc = _two_rects(_rect(locked=True), _rect(), layer_locked=True)
    doc = replace(doc, selection=frozenset({ElementSelection.all((0, 1))}))
    store = _store(doc)
    options = dict(store._document["artboard_options"])  # as the store normalised it
    run_effects([{"doc.op": {"op": "unlock_all"}}], {}, store)
    after = _doc_of(store)
    assert after.layers[0].locked is False
    assert [c.locked for c in after.layers[0].children] == [False, False]
    assert {es.path for es in after.selection} == {(0, 1)}, "UNLOCKSEL: the selection is kept"
    assert store._document["artboard_options"] == options, "a store-only key survives the bridge"
    assert options["fade_region_outside_artboard"] is True


def test_show_all_reveals_the_hidden_and_selects_exactly_them():
    doc = _two_rects(_rect(visibility=Visibility.INVISIBLE), _rect())
    doc = replace(doc, selection=frozenset({ElementSelection.all((0, 1))}))
    store = _store(doc)
    run_effects([{"doc.op": {"op": "show_all"}}], {}, store)
    after = _doc_of(store)
    assert [c.visibility for c in after.layers[0].children] == [Visibility.PREVIEW, Visibility.PREVIEW]
    assert {es.path for es in after.selection} == {(0, 0)}, "the selection is what was shown"


def test_an_op_the_layer_does_not_know_changes_nothing():
    doc = _two_rects(_rect(locked=True), _rect())
    store = _store(doc)
    before = json.dumps(store._document, sort_keys=True)
    run_effects([{"doc.op": {"op": "zz_no_such_op"}}], {}, store)
    assert json.dumps(store._document, sort_keys=True) == before
