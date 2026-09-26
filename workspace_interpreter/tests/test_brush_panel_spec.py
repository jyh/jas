"""W2b-18: the Brushes panel's two canvas gates and its two library actions.

Three spec defects, each binding every port:

1. ``bp_remove_brush_stroke_btn`` and ``bp_options_for_selection_btn`` were
   gated on ``canvas_selection_has_brushed_stroke`` and
   ``canvas_selection_is_single_brushed_stroke``: bare root names that NO code
   builds, in any port. An unbuilt name evaluates null, ``not null`` is true,
   so both buttons were disabled forever. They are now ``active_document``
   facts, declared in ``runtime_contexts.yaml`` and built here first.
2. ``delete_brush`` and ``duplicate_brush`` passed ``{}`` to
   ``brush.delete_selected`` / ``brush.duplicate_selected``. Both active ports'
   arms no-op without ``library`` and ``slugs``; only the non-gating flask
   renderer defaulted them. The spec now passes both as expressions, and this
   reference gains the two arms it never had.

The meaning of both gates is BRUSHES.md §Bottom toolbar: Remove Brush Stroke is
"disabled when the canvas selection contains no brushed stroke"; Brush Options
for Selection is "disabled unless exactly one brushed stroke is selected".
"""

from __future__ import annotations

import os

import pytest
import yaml

from workspace_interpreter.effects import run_effects
from workspace_interpreter.expr import evaluate
from workspace_interpreter.state_store import StateStore

_WS = os.path.join(os.path.dirname(__file__), "..", "..", "workspace")


def _yaml(*parts: str) -> dict:
    with open(os.path.join(_WS, *parts), encoding="utf-8") as f:
        return yaml.safe_load(f)


ACTIONS = _yaml("actions.yaml")["actions"]
BRUSHES = _yaml("panels", "brushes.yaml")


def _path(x: float, brush: str | None) -> dict:
    return {
        "kind": "Path",
        "d": [{"MoveTo": {"x": x, "y": 0.0}}, {"LineTo": {"x": x + 50.0, "y": 40.0}}],
        "stroke": {"color": "#000000", "width": 2.0},
        "stroke_brush": brush,
    }


def _rect() -> dict:
    return {"kind": "Rect", "x": 0.0, "y": 0.0, "width": 10.0, "height": 10.0}


def _store(children: list, selection: list) -> StateStore:
    return StateStore(document={
        "layers": [{
            "kind": "Layer", "name": "L",
            "common": {"visibility": "preview", "locked": False, "opacity": 1.0},
            "children": children,
        }],
        "selection": selection,
    })


BRUSHED = "default_brushes/flat_10"

# (name, children, selection, has_brushed_stroke, is_single_brushed_stroke).
# Every row differs from every other in at least one of the two facts OR in the
# selection shape that produces them, and the table covers all four value pairs
# except (False, True), which cannot occur.
CASES = [
    ("one brushed path", [_path(0, BRUSHED)], [[0, 0]], True, True),
    ("one plain path", [_path(0, None)], [[0, 0]], False, False),
    ("brushed + plain selected", [_path(0, BRUSHED), _path(60, None)], [[0, 0], [0, 1]], True, False),
    ("two brushed selected", [_path(0, BRUSHED), _path(60, BRUSHED)], [[0, 0], [0, 1]], True, False),
    ("brushed but NOT selected", [_path(0, BRUSHED), _path(60, None)], [[0, 1]], False, False),
    ("a rect (no stroke_brush key)", [_rect()], [[0, 0]], False, False),
    ("empty brush id", [_path(0, "")], [[0, 0]], False, False),
    ("nothing selected", [_path(0, BRUSHED)], [], False, False),
]


class TestBrushedStrokeFacts:
    @pytest.mark.parametrize("name,children,selection,has,single", CASES, ids=[c[0] for c in CASES])
    def test_facts(self, name, children, selection, has, single):
        view = _store(children, selection).eval_context()["active_document"]
        assert view["selection_has_brushed_stroke"] is has
        assert view["selection_is_single_brushed_stroke"] is single

    def test_no_document(self):
        view = StateStore().eval_context()["active_document"]
        assert view["selection_has_brushed_stroke"] is False
        assert view["selection_is_single_brushed_stroke"] is False

    def test_declared_in_runtime_contexts(self):
        ad = _yaml("runtime_contexts.yaml")["runtime_contexts"]["active_document"]
        for key in ("selection_has_brushed_stroke", "selection_is_single_brushed_stroke"):
            assert ad["defaults"][key] is False, key
            assert ad["properties"][key]["type"] == "bool", key


def _widget(node, wid):
    if isinstance(node, dict):
        if node.get("id") == wid:
            return node
        node = list(node.values())
    if isinstance(node, list):
        for child in node:
            hit = _widget(child, wid)
            if hit is not None:
                return hit
    return None


class TestBrushGatesAsSpecified:
    """The gates AS WRITTEN in brushes.yaml, evaluated against the reference's
    own context. Before this node both read unbuilt names and were disabled on
    every row."""

    @pytest.mark.parametrize("wid,fact", [
        ("bp_remove_brush_stroke_btn", 3),
        ("bp_options_for_selection_btn", 4),
    ])
    @pytest.mark.parametrize("case", CASES, ids=[c[0] for c in CASES])
    def test_disabled_follows_the_fact(self, wid, fact, case):
        expr = _widget(BRUSHES, wid)["bind"]["disabled"]
        store = _store(case[1], case[2])
        disabled = evaluate(expr, store.eval_context()).value
        assert disabled is (not case[fact]), (wid, expr)


def _brush_store(selected: list[str]) -> StateStore:
    store = _store([_path(0, None)], [])
    store.set_data({"brush_libraries": {
        "lib_a": {"name": "A", "brushes": [
            {"slug": "a", "name": "Alpha", "type": "calligraphic"},
            {"slug": "b", "name": "Beta", "type": "calligraphic"},
            {"slug": "c", "name": "Gamma", "type": "calligraphic"},
            {"slug": "a_copy", "name": "Alpha copy", "type": "calligraphic"},
        ]},
        "lib_b": {"name": "B", "brushes": [
            {"slug": "a", "name": "Other alpha", "type": "art"},
        ]},
    }})
    store.init_panel("brushes", {"selected_library": "lib_a", "selected_brushes": selected})
    store.set_active_panel("brushes")
    return store


def _slugs(store: StateStore, lib: str) -> list[str]:
    return [b["slug"] for b in store.get_data_path(f"brush_libraries.{lib}.brushes")]


def _run(store: StateStore, name: str) -> None:
    run_effects(ACTIONS[name]["effects"], {}, store, actions=ACTIONS)


class TestDeleteBrush:
    def test_the_action_passes_its_operands(self):
        spec = ACTIONS["delete_brush"]["effects"][0]["brush.delete_selected"]
        assert spec == {"library": "panel.selected_library", "slugs": "panel.selected_brushes"}

    def test_removes_the_selected_slugs_from_the_selected_library_only(self):
        store = _brush_store(["a", "c"])
        _run(store, "delete_brush")
        assert _slugs(store, "lib_a") == ["b", "a_copy"]
        assert _slugs(store, "lib_b") == ["a"]                 # the same slug elsewhere is untouched
        assert store.get_panel("brushes", "selected_brushes") == []

    def test_empty_selection_is_a_no_op(self):
        store = _brush_store([])
        _run(store, "delete_brush")
        assert _slugs(store, "lib_a") == ["a", "b", "c", "a_copy"]


class TestDuplicateBrush:
    def test_the_action_passes_its_operands(self):
        spec = ACTIONS["duplicate_brush"]["effects"][0]["brush.duplicate_selected"]
        assert spec == {"library": "panel.selected_library", "slugs": "panel.selected_brushes"}

    def test_copies_follow_their_originals_with_unique_slugs(self):
        store = _brush_store(["a", "b"])
        _run(store, "duplicate_brush")
        # `a_copy` is taken, so a's copy is `a_copy_2`; b's is `b_copy`.
        assert _slugs(store, "lib_a") == ["a", "a_copy_2", "b", "b_copy", "c", "a_copy"]
        names = {b["slug"]: b["name"] for b in store.get_data_path("brush_libraries.lib_a.brushes")}
        assert names["a_copy_2"] == "Alpha copy" and names["b_copy"] == "Beta copy"
        assert store.get_panel("brushes", "selected_brushes") == ["a_copy_2", "b_copy"]
        assert _slugs(store, "lib_b") == ["a"]

    def test_empty_selection_is_a_no_op(self):
        store = _brush_store([])
        _run(store, "duplicate_brush")
        assert _slugs(store, "lib_a") == ["a", "b", "c", "a_copy"]
