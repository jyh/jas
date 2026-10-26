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


def test_select_all_from_actions_yaml_selects_each_unlocked_top_level_object_once():
    """`actions.yaml` select_all is `doc.op: {op: select_all}`: every visible,
    unlocked direct child of a layer, a group counting as one, and nothing in a
    locked layer. Driven from the real YAML entry, so a `log` stub reds here."""
    import yaml
    from geometry.element import Group
    path = os.path.join(os.path.dirname(__file__), "..", "..", "workspace", "actions.yaml")
    with open(path, encoding="utf-8") as f:
        effects = yaml.safe_load(f)["actions"]["select_all"]["effects"]
    locked_layer = Layer(name="Locked", children=(_rect(),), locked=True)
    open_layer = Layer(name="Open", children=(
        _rect(locked=True), _rect(), _rect(visibility=Visibility.INVISIBLE),
        Group(children=(_rect(locked=True), _rect()))))
    store = _store(Document(layers=(locked_layer, open_layer)))
    run_effects(effects, {}, store)
    assert {es.path for es in _doc_of(store).selection} == {(1, 1), (1, 3)}


def _run_yaml_action(store: StateStore, name: str) -> None:
    import yaml
    path = os.path.join(os.path.dirname(__file__), "..", "..", "workspace", "actions.yaml")
    with open(path, encoding="utf-8") as f:
        effects = yaml.safe_load(f)["actions"][name]["effects"]
    run_effects(effects, {}, store)


def test_group_from_actions_yaml_wraps_the_selection_in_one_selected_group():
    from geometry.element import Group
    doc = _two_rects(_rect(), Rect(x=20, y=0, width=10, height=10))
    doc = replace(doc, selection=frozenset({ElementSelection.all((0, 0)), ElementSelection.all((0, 1))}))
    store = _store(doc)
    _run_yaml_action(store, "group")
    after = _doc_of(store)
    assert len(after.layers[0].children) == 1 and isinstance(after.layers[0].children[0], Group)
    assert len(after.layers[0].children[0].children) == 2
    assert {es.path for es in after.selection} == {(0, 0)}


def test_ungroup_from_actions_yaml_replaces_the_group_with_its_members_selected():
    from geometry.element import Group
    doc = Document(layers=(Layer(name="L", children=(Group(children=(_rect(), _rect())),)),))
    doc = replace(doc, selection=frozenset({ElementSelection.all((0, 0))}))
    store = _store(doc)
    _run_yaml_action(store, "ungroup")
    after = _doc_of(store)
    assert [type(c).__name__ for c in after.layers[0].children] == ["Rect", "Rect"]
    assert {es.path for es in after.selection} == {(0, 0), (0, 1)}


def test_ungroup_all_from_actions_yaml_keeps_every_locked_group():
    from geometry.element import Group
    doc = Document(layers=(
        Layer(name="Locked", children=(Group(children=(_rect(),)),), locked=True),
        Layer(name="Open", children=(
            Group(children=(_rect(),), locked=True), Group(children=(_rect(), _rect()))))))
    store = _store(doc)
    _run_yaml_action(store, "ungroup_all")
    after = _doc_of(store)
    assert [type(c).__name__ for c in after.layers[0].children] == ["Group"], "inside a locked layer"
    assert [type(c).__name__ for c in after.layers[1].children] == ["Group", "Rect", "Rect"]


def test_make_instance_from_actions_yaml_leaves_an_offset_reference_selected():
    """`actions.yaml` make_instance: a by-id reference to the ONE selected
    element (SYMBOLS.md: an offset reference, not Make Symbol), offset by the
    YAML's own `offset` and selected; the target gains an id. Two selected,
    or none, is a no-op."""
    import yaml
    path = os.path.join(os.path.dirname(__file__), "..", "..", "workspace", "actions.yaml")
    with open(path, encoding="utf-8") as f:
        spec = yaml.safe_load(f)["actions"]["make_instance"]
    offset = next(e["doc.make_instance"]["offset"] for e in spec["effects"]
                  if isinstance(e, dict) and "doc.make_instance" in e)
    doc = _two_rects(_rect(), Rect(x=20, y=0, width=10, height=10))
    doc = replace(doc, selection=frozenset({ElementSelection.all((0, 0))}))
    store = _store(doc)
    _run_yaml_action(store, "make_instance")
    after = _doc_of(store)
    kids = after.layers[0].children
    assert len(kids) == 3, "the reference is added"
    ref = kids[2]
    assert type(ref).__name__ == "ReferenceElem", type(ref).__name__
    assert kids[0].id is not None and ref.target == kids[0].id, "it references the target by id"
    assert ref.id is not None and ref.id != kids[0].id
    assert ref.transform is not None and (ref.transform.e, ref.transform.f) == (offset, offset)
    assert {es.path for es in after.selection} == {(0, 2)}, "the reference is selected"

    two = replace(_two_rects(_rect(), _rect()),
                  selection=frozenset({ElementSelection.all((0, 0)), ElementSelection.all((0, 1))}))
    store = _store(two)
    before = json.dumps(store._document, sort_keys=True)
    _run_yaml_action(store, "make_instance")
    assert json.dumps(store._document, sort_keys=True) == before, "two selected: nothing"
