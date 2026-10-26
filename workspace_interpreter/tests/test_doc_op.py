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

import pytest

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


def _ungroup_shape(doc: Document) -> str:
    """Item 20's arms: ``r<x>`` for a rect at x, ``G[..]`` for a group, one
    ``L[..]`` per layer, the same text as the Rust and Swift arms."""
    from geometry.element import Group

    def walk(e) -> str:
        if isinstance(e, Group):
            return "G[" + " ".join(walk(c) for c in e.children) + "]"
        return f"r{e.x:g}"
    return " ".join("L[" + " ".join(walk(c) for c in l.children) + "]" for l in doc.layers)


def _ungroup_case(layers, selected):
    doc = Document(layers=tuple(Layer(name=f"L{i}", children=tuple(cs)) for i, cs in enumerate(layers)))
    doc = replace(doc, selection=frozenset(ElementSelection.all(tuple(p)) for p in selected))
    store = _store(doc)
    _run_yaml_action(store, "ungroup")
    after = _doc_of(store)
    return _ungroup_shape(after), sorted(es.path for es in after.selection)


def _r(x):
    return Rect(x=x, y=0, width=1, height=1)


def _g(*cs):
    from geometry.element import Group
    return Group(children=tuple(cs))



@pytest.mark.parametrize("layers, selected, shape, selection", [
    # C1: a nested group's members stay in its parent (MENU.md "parent container").
    ([[_r(0), _g(_g(_r(1), _r(2)), _r(3)), _r(4)]], [(0, 1, 0)],
     "L[r0 G[r1 r2 r3] r4]", [(0, 1, 0), (0, 1, 1)]),
    # C2: two layers; the selection offset is per parent.
    ([[_r(0), _g(_r(1), _r(2), _r(3))], [_g(_r(5), _r(6)), _r(7)]], [(0, 1), (1, 0)],
     "L[r0 r1 r2 r3] L[r5 r6 r7]", [(0, 1), (0, 2), (0, 3), (1, 0), (1, 1)]),
    # C3: two groups in one parent.
    ([[_g(_r(0), _r(1)), _r(2), _g(_r(3), _r(4))]], [(0, 0), (0, 2)],
     "L[r0 r1 r2 r3 r4]", [(0, 0), (0, 1), (0, 3), (0, 4)]),
    # C4: a group and its own ancestor: both dissolve.
    ([[_r(0), _g(_g(_r(1), _r(2)), _r(3)), _r(4)]], [(0, 1), (0, 1, 0)],
     "L[r0 r1 r2 r3 r4]", [(0, 1), (0, 2), (0, 3)]),
    # An empty group before a selected sibling.
    ([[_g(), _r(1), _g(_r(2), _r(3))]], [(0, 0), (0, 2)],
     "L[r1 r2 r3]", [(0, 1), (0, 2)]),
    # C5: mixed depths in two parents.
    ([[_r(0), _g(_g(_r(1), _r(2)), _r(3)), _g(_r(4), _r(5))]], [(0, 1, 0), (0, 2)],
     "L[r0 G[r1 r2 r3] r4 r5]", [(0, 1, 0), (0, 1, 1), (0, 2), (0, 3)]),
], ids=["C1-nested", "C2-two-layers", "C3-one-parent", "C4-with-ancestor", "empty-group", "C5-mixed"])
def test_ungroup_splices_members_into_the_groups_own_parent(layers, selected, shape, selection):
    assert _ungroup_case(layers, selected) == (shape, selection)


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


def _referenced_rect_store(select: tuple) -> StateStore:
    """A rect, an unrelated rect, and a live reference to the first (built by the
    real make_instance action), with `select` as the canvas selection."""
    doc = _two_rects(_rect(), Rect(x=20, y=0, width=10, height=10))
    doc = replace(doc, selection=frozenset({ElementSelection.all((0, 0))}))
    store = _store(doc)
    _run_yaml_action(store, "make_instance")
    made = _doc_of(store)
    assert type(made.layers[0].children[2]).__name__ == "ReferenceElem"
    store = _store(replace(made, selection=frozenset(ElementSelection.all(p) for p in select)))
    return store


@pytest.mark.parametrize("select, count", [
    ((), 0),                      # nothing selected
    (((0, 1),), 0),               # an unreferenced rect
    (((0, 0),), 1),               # the referenced rect: its reference would dangle
    (((0, 0), (0, 2)), 0),        # the target AND its reference: nothing is left to dangle
], ids=["none", "unreferenced", "referenced", "target-and-reference"])
def test_selection_orphan_count_counts_references_a_delete_would_strand(select, count):
    store = _referenced_rect_store(select)
    assert store._active_document_view()["selection_orphan_count"] == count


def _run_yaml_action_with_dialogs(store: StateStore, name: str, ctx: dict | None = None) -> None:
    import yaml
    root = os.path.join(os.path.dirname(__file__), "..", "..", "workspace")
    with open(os.path.join(root, "actions.yaml"), encoding="utf-8") as f:
        effects = yaml.safe_load(f)["actions"][name]["effects"]
    with open(os.path.join(root, "workspace.json"), encoding="utf-8") as f:
        dialogs = json.load(f)["dialogs"]
    run_effects(effects, ctx or {}, store, dialogs=dialogs)


def test_delete_selection_from_actions_yaml_deletes_when_nothing_would_dangle():
    store = _referenced_rect_store(((0, 1),))
    _run_yaml_action_with_dialogs(store, "delete_selection")
    after = _doc_of(store)
    assert [type(c).__name__ for c in after.layers[0].children] == ["Rect", "ReferenceElem"]
    assert after.selection == frozenset()
    assert store.get_dialog_id() is None


def test_delete_selection_from_actions_yaml_asks_before_stranding_a_reference():
    store = _referenced_rect_store(((0, 0),))
    before = json.dumps(store._document, sort_keys=True)
    _run_yaml_action_with_dialogs(store, "delete_selection")
    assert json.dumps(store._document, sort_keys=True) == before, "nothing is deleted before the answer"
    assert store.get_dialog_id() == "delete_orphan_confirm"
    assert (store.get_dialog_params() or {}).get("count") == 1


def test_place_instance_from_actions_yaml_appends_a_reference_to_the_panel_selected_master():
    """`actions.yaml` place_instance (SYMBOLS.md §7): a by-id reference to the
    master `panel.selected_symbol` names, with a freshly minted id, appended to
    the active layer and selected. No master selected: nothing."""
    import yaml
    master = Rect(x=0, y=0, width=10, height=10, id="m1")
    doc = replace(Document(layers=(Layer(name="L", children=(_rect(),)),)), symbols=(master,))
    path = os.path.join(os.path.dirname(__file__), "..", "..", "workspace", "actions.yaml")
    with open(path, encoding="utf-8") as f:
        effects = yaml.safe_load(f)["actions"]["place_instance"]["effects"]
    store = _store(doc)
    run_effects(effects, {"panel": {"selected_symbol": "m1"}}, store)
    after = _doc_of(store)
    kids = after.layers[0].children
    assert len(kids) == 2, "the instance is appended"
    ref = kids[1]
    assert type(ref).__name__ == "ReferenceElem" and ref.target == "m1"
    assert ref.id is not None and ref.id != "m1", "its id is minted"
    assert {es.path for es in after.selection} == {(0, 1)}, "the instance is selected"

    store = _store(doc)
    before = json.dumps(store._document, sort_keys=True)
    run_effects(effects, {"panel": {"selected_symbol": None}}, store)
    assert json.dumps(store._document, sort_keys=True) == before, "no master: nothing"


def test_a_minted_id_never_repeats_a_symbol_masters_id():
    """The value-in-op mint retries against EVERY id in the document, the
    symbol masters' included (Rust `Document::element_ids`, Swift
    `elementIds`): a mint that offers a master's id first gets a fresh one."""
    from document.controller import make_instance_ops, place_instance_ops
    master = Rect(x=0, y=0, width=10, height=10, id="m1")
    doc = replace(Document(layers=(Layer(name="L", children=(_rect(),)),)), symbols=(master,),
                  selection=frozenset({ElementSelection.all((0, 0))}))
    offers = iter(["m1", "a1", "a2"])
    ops = make_instance_ops(doc, 24, mint=lambda: next(offers))
    assert (ops[0]["target_id"], ops[0]["ref_id"]) == ("a1", "a2")
    offers = iter(["m1", "a1"])
    assert place_instance_ops(doc, "m1", mint=lambda: next(offers)) == [
        {"op": "place_instance", "master_id": "m1", "ref_id": "a1"}]
    assert place_instance_ops(doc, None) is None, "no master: nothing"
def _action_effects(name: str) -> list:
    import yaml
    path = os.path.join(os.path.dirname(__file__), "..", "..", "workspace", "actions.yaml")
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)["actions"][name]["effects"]


def test_place_concept_instance_from_actions_yaml_appends_the_panel_selected_concept():
    """`actions.yaml` place_concept_instance (CONCEPTS.md §6): a generated
    instance of the concept `panel.selected_concept` names, with the concept's
    declared default params and a freshly minted id, appended to the active
    layer and selected. No concept selected, or an unknown one: nothing."""
    doc = Document(layers=(Layer(name="L", children=(_rect(id="r1"),)),))
    effects = _action_effects("place_concept_instance")
    store = _store(doc)
    run_effects(effects, {"panel": {"selected_concept": "star"}}, store)
    after = _doc_of(store)
    kids = after.layers[0].children
    assert len(kids) == 2, "the instance is appended"
    gen = kids[1]
    assert type(gen).__name__ == "GeneratedElem" and gen.concept_id == "star"
    assert dict(gen.params) == {"points": 5, "outer": 50, "inner": 20}, \
        "the concept's declared defaults (workspace/concepts/star.yaml)"
    assert gen.id is not None and gen.id != "r1", "its id is minted"
    assert {es.path for es in after.selection} == {(0, 1)}, "the instance is selected"

    for scope in ({"selected_concept": None}, {"selected_concept": "no_such_concept"}):
        store = _store(doc)
        before = json.dumps(store._document, sort_keys=True)
        run_effects(effects, {"panel": scope}, store)
        assert json.dumps(store._document, sort_keys=True) == before, f"{scope}: nothing"


def test_set_concept_param_from_actions_yaml_writes_the_selected_instance():
    """`actions.yaml` set_concept_param (CONCEPTS.md §6.4): `param.value` is
    written to `params[param.name]` of the ONE selected generated instance. A
    value that is not a number (a numeric string is one), no selection, two
    selected, or a selection that is not a generated instance: nothing."""
    from geometry.element import GeneratedElem
    gen = GeneratedElem(concept_id="star", params={"points": 5, "outer": 50, "inner": 20}, id="g1")
    base = Document(layers=(Layer(name="L", children=(gen, _rect(id="r1"))),))
    sel = lambda *paths: replace(base, selection=frozenset(ElementSelection.all(p) for p in paths))
    effects = _action_effects("set_concept_param")

    for value, want in ((7, 7), (7.5, 7.5), ("9", 9)):
        store = _store(sel((0, 0)))
        run_effects(effects, {"param": {"name": "points", "value": value}}, store)
        got = _doc_of(store).layers[0].children[0].params
        assert got["points"] == want and got["outer"] == 50, f"value {value!r}"

    for doc, value in ((sel((0, 0)), "seven"), (sel((0, 0)), "inf"), (sel((0, 0)), "1e999"),
                       (sel((0, 0)), None), (base, 7),
                       (sel((0, 0), (0, 1)), 7), (sel((0, 1)), 7)):
        store = _store(doc)
        before = json.dumps(store._document, sort_keys=True)
        run_effects(effects, {"param": {"name": "points", "value": value}}, store)
        assert json.dumps(store._document, sort_keys=True) == before, f"{value!r}: nothing"


def test_promote_to_concept_from_actions_yaml_replaces_a_fitted_shape():
    """`actions.yaml` promote_to_concept (CONCEPTS.md §10): the ONE selected
    polygon whose points a registered concept's fitter matches (concepts in
    sorted-id order; the first fitter returning k params + cx, cy, rot wins)
    is replaced at its path by a Generated instance, placed at
    translate(cx, cy) · rotate(rot). The square is the fitter corpus's own
    `[4, 10, 100, 20, 0]` case. A shape no fitter matches, a non-polygon, or
    two selected: nothing."""
    from geometry.element import GeneratedElem, Polygon
    square = Polygon(points=((110, 20), (100, 30), (90, 20), (100, 10)))
    oblong = Polygon(points=((0, 0), (20, 0), (20, 10), (0, 10)))
    effects = _action_effects("promote_to_concept")

    def run(*children, selected):
        doc = Document(layers=(Layer(name="L", children=tuple(children)),),
                       selection=frozenset(ElementSelection.all(p) for p in selected))
        store = _store(doc)
        before = json.dumps(store._document, sort_keys=True)
        run_effects(effects, {}, store)
        return store, before

    store, _ = run(square, _rect(id="r1"), selected=[(0, 0)])
    gen = _doc_of(store).layers[0].children[0]
    assert isinstance(gen, GeneratedElem) and gen.concept_id == "regular_polygon"
    assert (gen.params["sides"], gen.params["radius"]) == (4, 10)
    t = gen.transform
    assert (t.a, t.b, t.c, t.d, t.e, t.f) == (1, 0, 0, 1, 100, 20), t
    assert isinstance(_doc_of(store).layers[0].children[1], Rect), "the sibling is untouched"

    # The element's transform is baked into its points: the corpus's origin
    # square (`[4, 10, 0, 0, 0]`) moved by translate(5, 7) is fitted at (5, 7).
    from geometry.element import Transform
    moved = Polygon(points=((10, 0), (0, 10), (-10, 0), (0, -10)), transform=Transform.translate(5, 7))
    store, _ = run(moved, selected=[(0, 0)])
    t = _doc_of(store).layers[0].children[0].transform
    assert (t.e, t.f) == (5, 7), "fitted in world space"

    for children, selected in (((oblong,), [(0, 0)]), ((_rect(),), [(0, 0)]),
                               ((square, square), [(0, 0), (0, 1)]), ((square,), [])):
        store, before = run(*children, selected=selected)
        assert json.dumps(store._document, sort_keys=True) == before, f"{children} {selected}: nothing"


def test_new_symbol_from_actions_yaml_promotes_and_panel_selects_the_master():
    """`actions.yaml` new_symbol (SYMBOLS.md §7 Make Symbol): the ONE wholly
    selected element becomes a master and a reference to it stays in its
    place, and the Symbols panel selects the master. The master's id is the
    element's own when it has one (make_symbol keeps it) and a minted one
    otherwise, so the id the panel selects is read AFTER the op: the YAML
    binds it (`as: master`) and writes it with `set_panel_state`. Two selected,
    or none: nothing."""
    effects = _action_effects("new_symbol")

    def run(*children, selected):
        doc = Document(layers=(Layer(name="L", children=tuple(children)),),
                       selection=frozenset(ElementSelection.all(p) for p in selected))
        store = _store(doc)
        store.init_panel("symbols_panel_content", {"selected_symbol": None})
        before = json.dumps(store._document, sort_keys=True)
        run_effects(effects, {}, store)
        return store, before

    for elem, kept in ((_rect(id="r1"), "r1"), (_rect(), None)):
        store, _ = run(elem, selected=[(0, 0)])
        after = _doc_of(store)
        assert len(after.symbols) == 1, "one master"
        master = after.symbols[0].id
        assert master and (kept is None or master == kept), (master, kept)
        ref = after.layers[0].children[0]
        assert type(ref).__name__ == "ReferenceElem" and ref.target == master
        assert store.get_panel_state("symbols_panel_content")["selected_symbol"] == master, \
            "the panel selects the master"

    for children, selected in (((_rect(), _rect()), [(0, 0), (0, 1)]), ((_rect(),), [])):
        store, before = run(*children, selected=selected)
        assert json.dumps(store._document, sort_keys=True) == before, f"{selected}: nothing"
        assert store.get_panel_state("symbols_panel_content")["selected_symbol"] is None

    # A PARTIAL selection (some control points) is not a whole element.
    doc = Document(layers=(Layer(name="L", children=(_rect(),)),),
                   selection=frozenset({ElementSelection.partial((0, 0), [0])}))
    store = _store(doc)
    before = json.dumps(store._document, sort_keys=True)
    run_effects(effects, {}, store)
    assert json.dumps(store._document, sort_keys=True) == before, "a partial selection: nothing"


def test_apply_concept_operation_from_actions_yaml_resolves_the_operation():
    """`actions.yaml` apply_concept_operation (CONCEPTS.md §9): the operation
    `param.op_id` of the ONE selected generated instance's concept is looked
    up, its `set:` expressions are evaluated over the instance's CURRENT
    params (bound under `param`), and the numbers are merged into its params.
    An unknown operation, no selection, two selected, or a selection that is
    not a generated instance: nothing."""
    from geometry.element import GeneratedElem
    gen = GeneratedElem(concept_id="regular_polygon", params={"sides": 5, "radius": 40}, id="g1")
    base = Document(layers=(Layer(name="L", children=(gen, _rect(id="r1"))),))
    sel = lambda *paths: replace(base, selection=frozenset(ElementSelection.all(p) for p in paths))
    effects = _action_effects("apply_concept_operation")

    for op_id, want in (("add_side", 6), ("remove_side", 4)):
        store = _store(sel((0, 0)))
        run_effects(effects, {"param": {"op_id": op_id}}, store)
        got = _doc_of(store).layers[0].children[0].params
        assert got["sides"] == want and got["radius"] == 40, f"{op_id}: {got}"

    # The expression reads the CURRENT params: remove_side clamps at 3.
    tri = replace(gen, params={"sides": 3, "radius": 40})
    store = _store(replace(base, layers=(Layer(name="L", children=(tri,)),),
                           selection=frozenset({ElementSelection.all((0, 0))})))
    run_effects(effects, {"param": {"op_id": "remove_side"}}, store)
    assert _doc_of(store).layers[0].children[0].params["sides"] == 3

    for doc, op_id in ((sel((0, 0)), "no_such_operation"), (sel((0, 0)), None), (base, "add_side"),
                       (sel((0, 0), (0, 1)), "add_side"), (sel((0, 1)), "add_side")):
        store = _store(doc)
        before = json.dumps(store._document, sort_keys=True)
        run_effects(effects, {"param": {"op_id": op_id}}, store)
        assert json.dumps(store._document, sort_keys=True) == before, f"{op_id!r}: nothing"


def _symbols_store(instances: int) -> StateStore:
    """Two masters, `m1` with `instances` live references and `m2` with none."""
    from geometry.element import ReferenceElem
    refs = tuple(ReferenceElem(target="m1", id=f"i{k}") for k in range(instances))
    doc = replace(Document(layers=(Layer(name="L", children=(_rect(),) + refs),)),
                  symbols=(_rect(id="m1"), _rect(id="m2")))
    store = _store(doc)
    store.init_panel("symbols_panel_content", {"selected_symbol": "m1"})
    return store


@pytest.mark.parametrize("instances", [0, 1, 2])
def test_symbol_usage_counts_every_masters_live_instances(instances):
    """`active_document.symbol_usage` (runtime_contexts.yaml): every master's
    id -> how many live references target it, 0 for an unused master, so
    `symbol_usage[id] > 0` never reads null for a master that exists."""
    view = _symbols_store(instances)._active_document_view()
    assert view["symbol_usage"] == {"m1": instances, "m2": 0}


def test_symbol_usage_is_empty_without_masters():
    assert _store(Document(layers=(Layer(name="L", children=(_rect(),)),)))._active_document_view()[
        "symbol_usage"] == {}


def _symbol_ids(store: StateStore) -> list:
    return [m.id for m in _doc_of(store).symbols]


def test_delete_symbol_action_from_actions_yaml_deletes_an_unused_master():
    """`actions.yaml` delete_symbol_action (SYMBOLS.md §7): a panel-selected
    master with no live instance is deleted at once and the panel selection
    clears; no dialog opens."""
    store = _symbols_store(0)
    _run_yaml_action_with_dialogs(store, "delete_symbol_action",
                                  {"panel": {"selected_symbol": "m1"}})
    assert _symbol_ids(store) == ["m2"]
    assert store.get_panel_state("symbols_panel_content")["selected_symbol"] is None
    assert store.get_dialog_id() is None


def test_delete_symbol_action_asks_before_emptying_instances_and_the_ok_deletes():
    """A master with live instances is NOT deleted: the confirm opens with the
    count and the master. Its OK deletes the master it was asked about
    (`dialog.master`), clears the panel selection and closes; the instances
    stay in place, resolving to nothing."""
    store = _symbols_store(2)
    before = json.dumps(store._document, sort_keys=True)
    _run_yaml_action_with_dialogs(store, "delete_symbol_action",
                                  {"panel": {"selected_symbol": "m1"}})
    assert json.dumps(store._document, sort_keys=True) == before, "nothing is deleted before the answer"
    assert store.get_dialog_id() == "delete_symbol_orphan_confirm"
    assert {k: (store.get_dialog_params() or {}).get(k) for k in ("count", "master")} == {"count": 2, "master": "m1"}

    # The dialog's Delete button passes its params, evaluated over the
    # dialog's own params, as the OK's `param`.
    from workspace_interpreter.expr import evaluate
    root = os.path.join(os.path.dirname(__file__), "..", "..", "workspace")
    with open(os.path.join(root, "workspace.json"), encoding="utf-8") as f:
        dialog = json.load(f)["dialogs"]["delete_symbol_orphan_confirm"]
    button = next(c for c in dialog["content"]["children"][1]["children"]
                  if c.get("action") == "delete_symbol_orphan_confirm_ok")
    button_params = {k: evaluate(v, {"param": store.get_dialog_params()}).value
                     for k, v in button["params"].items()}
    assert button_params == {"master": "m1"}
    _run_yaml_action_with_dialogs(store, "delete_symbol_orphan_confirm_ok", {"param": button_params})
    assert _symbol_ids(store) == ["m2"]
    assert [type(c).__name__ for c in _doc_of(store).layers[0].children] == \
        ["Rect", "ReferenceElem", "ReferenceElem"], "the instances stay"
    assert store.get_panel_state("symbols_panel_content")["selected_symbol"] is None
    assert store.get_dialog_id() is None


def test_delete_symbol_without_a_master_does_nothing():
    for panel in ({"selected_symbol": None}, {"selected_symbol": "no_such_master"}):
        store = _symbols_store(1)
        before = json.dumps(store._document, sort_keys=True)
        _run_yaml_action_with_dialogs(store, "delete_symbol_action", {"panel": panel})
        assert json.dumps(store._document, sort_keys=True) == before, f"{panel}: nothing"
        assert store.get_dialog_id() is None


def test_layer_walk_reads_and_writes_a_bridged_documents_layers():
    """STATUS-jas item 25. The store's document is in the op bridge's test-JSON
    form (`type: layer`, common props flattened) after ANY op, while the YAML
    reads and writes the native form (`l.common.locked`, `common.locked`).
    `toggle_all_layers_lock` must lock every layer of a bridged document, and
    unlock them on the next run; until 10-26 `top_level_layers` was empty there,
    so the walk saw no layers and the action did nothing."""
    doc = Document(layers=(Layer(name="A", children=(_rect(),)), Layer(name="B", children=())))
    store = _store(doc)
    assert store._document["layers"][0].get("type") == "layer", "the control: a bridged document"
    view = store._active_document_view()
    assert [l["name"] for l in view["top_level_layers"]] == ["A", "B"]
    assert [l["common"]["locked"] for l in view["top_level_layers"]] == [False, False]

    _run_yaml_action(store, "toggle_all_layers_lock")
    assert [l.locked for l in _doc_of(store).layers] == [True, True]
    _run_yaml_action(store, "toggle_all_layers_lock")
    assert [l.locked for l in _doc_of(store).layers] == [False, False]


def test_apply_concept_operation_that_changes_nothing_builds_no_op():
    """flask STATUS § 568: Remove Side on a triangle resolves to sides 3, the
    value it already has. A change equal to the current value is dropped, and
    an operation left with no change builds no op (so nothing is journaled)."""
    from document.controller import apply_concept_operation_ops
    from geometry.element import GeneratedElem
    from workspace_interpreter.loader import concept, load_workspace
    ws = load_workspace(os.path.join(os.path.dirname(__file__), "..", "..", "workspace"))
    reg = concept(ws, "regular_polygon")
    def doc(sides):
        gen = GeneratedElem(concept_id="regular_polygon", params={"sides": sides, "radius": 40})
        return Document(layers=(Layer(name="L", children=(gen,)),),
                        selection=frozenset({ElementSelection.all((0, 0))}))
    assert apply_concept_operation_ops(doc(3), "remove_side", reg) is None
    assert apply_concept_operation_ops(doc(3.0), "remove_side", reg) is None, "3.0 is 3"
    assert apply_concept_operation_ops(doc(4), "remove_side", reg)[0]["changes"] == {"sides": 3}


def test_set_fill_type_gradient_from_actions_yaml_promotes_each_member():
    """`actions.yaml` set_fill_type_gradient (GRADIENT.md §Fill-type coupling,
    "Gradient button → ensure the active attribute is a gradient object"):
    every selected paintable member whose active attribute (fill when
    fill_on_top, else stroke) holds no gradient is promoted from ITS OWN seed
    (solid `C` -> `[C@0, #ffffff@100]`, none -> `[#000000@0, #ffffff@100]`;
    linear, 0°, 100 %, classic); a member that holds one keeps it; a selected
    group reaches its members. The solid fill/stroke stays (the demote
    target), and the other attribute is untouched. Nothing selected, or
    nothing left to promote: nothing."""
    from geometry.element import (Color, Fill, Gradient, GradientStop, GradientType,
                                  Group, Line, Stroke)
    hexc = Color.from_hex
    own = Gradient(type=GradientType.RADIAL, angle=30,
                   stops=(GradientStop("#123456", 0), GradientStop("#abcdef", 100)))
    red = _rect(fill=Fill(hexc("ff0000")), stroke=Stroke(hexc("0000ff")))
    bare = _rect(fill=None)
    held = _rect(fill=Fill(hexc("00ff00")), fill_gradient=own)
    inner = _rect(fill=Fill(hexc("00ff00")))
    effects = _action_effects("set_fill_type_gradient")

    def seed(c):
        return Gradient(stops=(GradientStop(c, 0), GradientStop("#ffffff", 100)))

    def run(children, selected, fill_on_top=True):
        doc = Document(layers=(Layer(name="L", children=tuple(children)),),
                       selection=frozenset(ElementSelection.all(p) for p in selected))
        store = _store(doc)
        store.set("fill_on_top", fill_on_top)
        before = json.dumps(store._document, sort_keys=True)
        run_effects(effects, {}, store)
        return _doc_of(store).layers[0].children, before, store

    kids, _, _ = run([red, bare, held, Group(children=(inner,))],
                     [(0, 0), (0, 1), (0, 2), (0, 3)])
    assert kids[0].fill_gradient == seed("#ff0000"), kids[0].fill_gradient
    assert kids[0].fill == red.fill, "the solid fill stays: it is the demote target"
    assert kids[0].stroke_gradient is None, "the stroke is not the active attribute"
    assert kids[1].fill_gradient == seed("#000000"), "none promotes from black"
    assert kids[2].fill_gradient == own, "a member that holds a gradient keeps it"
    assert kids[3].children[0].fill_gradient == seed("#00ff00"), "a group reaches its member"

    kids, _, _ = run([red], [(0, 0)], fill_on_top=False)
    assert kids[0].stroke_gradient == seed("#0000ff"), kids[0].stroke_gradient
    assert kids[0].fill_gradient is None, "the fill is not the active attribute"

    # A Line carries no fill gradient, so with the fill active it has nothing
    # to promote: no op, not an op that changes nothing.
    line = Line(x1=0, y1=0, x2=10, y2=0, stroke=Stroke(hexc("0000ff")))
    for children, selected in (([red], []), ([held], [(0, 0)]), ([line], [(0, 0)])):
        _, before, store = run(children, selected)
        assert json.dumps(store._document, sort_keys=True) == before, f"{selected}: nothing"

    # ...and the builder says so: an unchanged document is not evidence that
    # no op was built (item 27: a no-op must not report a change).
    from document.controller import promote_to_gradient_ops
    one = lambda e: Document(layers=(Layer(name="L", children=(e,)),),
                             selection=frozenset({ElementSelection.all((0, 0))}))
    assert promote_to_gradient_ops(one(line), True) == []
    assert promote_to_gradient_ops(one(held), True) == []
    assert promote_to_gradient_ops(one(line), False) == [{"op": "promote_to_gradient", "fill_on_top": False}]


def test_the_gradient_button_is_enabled_now_its_action_has_effects():
    """The fill/stroke widget's Gradient button was rendered disabled while
    set_fill_type_gradient declared no effects; its own description said the
    bind comes off when the action grows effects."""
    import yaml
    path = os.path.join(os.path.dirname(__file__), "..", "..", "workspace",
                        "templates", "fill_stroke_widget.yaml")
    with open(path, encoding="utf-8") as f:
        text = f.read()
    found = []

    def walk(node):
        if isinstance(node, dict):
            if isinstance(node.get("id"), str) and node["id"].endswith("gradient_btn"):
                found.append(node)
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    walk(yaml.safe_load(text))
    assert len(found) == 1, found
    assert "disabled" not in (found[0].get("bind") or {}), found[0].get("bind")
    assert _action_effects("set_fill_type_gradient"), "the action has effects"
