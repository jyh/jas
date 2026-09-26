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


# ══════════════════════════════════════════════════════════════════
# Sort by Name and Select All Unused: the two log-only stubs, built
# ══════════════════════════════════════════════════════════════════
#
# Both were `log:` stubs in every port. Sort by Name's earlier declaration
# interpolated ``panel.selected_library`` into a ``data.list_sort`` path with
# ``${...}``, which never runs on an effect payload, so it was a silent no-op
# (VISION.md §11). Both now take ``library:`` as an EXPRESSION, the shape of
# ``brush.delete_selected``.


def _sort_store(names: list[str], selected: list[str]) -> StateStore:
    store = _store([_path(0, None)], [])
    store.set_data({"brush_libraries": {
        "lib_a": {"name": "A", "brushes": [
            {"slug": f"s{i}", "name": n, "type": "calligraphic"} for i, n in enumerate(names)
        ]},
        "lib_b": {"name": "B", "brushes": [
            {"slug": "z", "name": "Zed", "type": "art"},
            {"slug": "a", "name": "Ay", "type": "art"},
        ]},
    }})
    store.init_panel("brushes", {"selected_library": "lib_a", "selected_brushes": selected})
    store.set_active_panel("brushes")
    return store


def _names(store: StateStore, lib: str) -> list[str]:
    return [b["name"] for b in store.get_data_path(f"brush_libraries.{lib}.brushes")]


class TestSortBrushesByName:
    def test_the_action_passes_its_operand(self):
        effects = ACTIONS["sort_brushes_by_name"]["effects"]
        assert effects == [{"brush.sort_by_name": {"library": "panel.selected_library"}}]

    def test_brp_130_case_sensitive_order(self):
        # BRUSHES_TESTS.md BRP-130, plus a lower-case name: case-SENSITIVE means
        # every upper-case letter sorts before every lower-case one.
        store = _sort_store(["Zebra", "Apple", "mango", "Mango"], [])
        _run(store, "sort_brushes_by_name")
        assert _names(store, "lib_a") == ["Apple", "Mango", "Zebra", "mango"]

    def test_brp_131_selection_and_slugs_are_preserved(self):
        store = _sort_store(["Zebra", "Apple", "Mango"], ["s2"])
        _run(store, "sort_brushes_by_name")
        brushes = store.get_data_path("brush_libraries.lib_a.brushes")
        assert [(b["slug"], b["name"]) for b in brushes] == \
            [("s1", "Apple"), ("s2", "Mango"), ("s0", "Zebra")]
        assert store.get_panel("brushes", "selected_brushes") == ["s2"]

    def test_only_the_selected_library_moves(self):
        store = _sort_store(["B", "A"], [])
        _run(store, "sort_brushes_by_name")
        assert _names(store, "lib_b") == ["Zed", "Ay"]

    def test_order_is_by_code_point_not_by_locale_or_canonical_equivalence(self):
        # The equivalence trap between ports: a string comparison that is
        # locale-aware, or that treats canonically-equivalent strings as equal
        # (Swift's String `<`), orders these differently. The law is code-point
        # order: "Z" (0x5A) before every lower-case letter; the decomposed "é"
        # (0x65 0x301) after "ezra" (0x65 0x7A), because U+0301 > "z"; and the
        # precomposed "é" (0xE9) after that. Swift's String `<` reads the two
        # "éclair"s as EQUAL, so a stable sort there keeps the input order
        # (precomposed first) -- the reverse of this law. Escapes, never literal
        # combining marks: a literal U+0301 is invisible in review.
        pre, dec = "\u00e9clair", "e\u0301clair"
        store = _sort_store([pre, "eclair", dec, "Zed", "ezra"], [])
        _run(store, "sort_brushes_by_name")
        assert _names(store, "lib_a") == ["Zed", "eclair", "ezra", dec, pre]

    def test_equal_names_keep_their_relative_order(self):
        # Stable: duplicate names are the normal state after Duplicate Brush
        # renames nothing twice, and a sort must not shuffle them.
        store = _sort_store(["B", "A", "B", "A"], [])
        _run(store, "sort_brushes_by_name")
        slugs = [b["slug"] for b in store.get_data_path("brush_libraries.lib_a.brushes")]
        assert slugs == ["s1", "s3", "s0", "s2"]

    def test_a_brush_with_no_name_sorts_as_the_empty_string(self):
        store = _sort_store(["B", "A"], [])
        brushes = store.get_data_path("brush_libraries.lib_a.brushes")
        store.set_data_path("brush_libraries.lib_a.brushes",
                            brushes + [{"slug": "nameless", "type": "art"}])
        _run(store, "sort_brushes_by_name")
        slugs = [b["slug"] for b in store.get_data_path("brush_libraries.lib_a.brushes")]
        assert slugs == ["nameless", "s1", "s0"]

    def test_no_selected_library_is_a_no_op(self):
        store = _sort_store(["B", "A"], [])
        store.set_panel("brushes", "selected_library", None)
        _run(store, "sort_brushes_by_name")
        assert _names(store, "lib_a") == ["B", "A"]

    def test_an_unknown_library_is_a_no_op(self):
        store = _sort_store(["B", "A"], [])
        store.set_panel("brushes", "selected_library", "no_such_lib")
        _run(store, "sort_brushes_by_name")
        assert _names(store, "lib_a") == ["B", "A"]
        assert store.get_data_path("brush_libraries.no_such_lib") is None


def _group(children: list) -> dict:
    return {"kind": "Group", "children": children}


def _unused_store(children: list, selected: list[str]) -> StateStore:
    store = _store(children, [])
    store.set_data({"brush_libraries": {
        "lib_a": {"name": "A", "brushes": [
            {"slug": "a", "name": "Alpha", "type": "calligraphic"},
            {"slug": "b", "name": "Beta", "type": "calligraphic"},
            {"slug": "c", "name": "Gamma", "type": "calligraphic"},
        ]},
        "lib_b": {"name": "B", "brushes": [
            {"slug": "a", "name": "Other alpha", "type": "art"},
        ]},
    }})
    store.init_panel("brushes", {"selected_library": "lib_a", "selected_brushes": selected})
    store.set_active_panel("brushes")
    return store


class TestSelectAllUnusedBrushes:
    def test_the_action_passes_its_operand(self):
        effects = ACTIONS["select_all_unused_brushes"]["effects"]
        assert effects == [{"brush.select_unused": {"library": "panel.selected_library"}}]

    def test_nothing_on_canvas_selects_every_brush_in_library_order(self):
        store = _unused_store([_path(0, None)], [])
        _run(store, "select_all_unused_brushes")
        assert store.get_panel("brushes", "selected_brushes") == ["a", "b", "c"]

    def test_a_used_brush_is_left_out_and_the_selection_is_replaced(self):
        store = _unused_store([_path(0, "lib_a/b")], ["b"])
        _run(store, "select_all_unused_brushes")
        assert store.get_panel("brushes", "selected_brushes") == ["a", "c"]

    def test_use_is_library_qualified(self):
        # `lib_b/a` on canvas uses lib_b's `a`, not lib_a's: the attribute is
        # `<library>/<slug>` (BRUSHES.md), so a bare-slug match would be wrong.
        store = _unused_store([_path(0, "lib_b/a")], [])
        _run(store, "select_all_unused_brushes")
        assert store.get_panel("brushes", "selected_brushes") == ["a", "b", "c"]

    def test_use_inside_a_group_counts(self):
        store = _unused_store([_group([_group([_path(0, "lib_a/c")])]), _path(60, "lib_a/a")], [])
        _run(store, "select_all_unused_brushes")
        assert store.get_panel("brushes", "selected_brushes") == ["b"]

    def test_use_on_an_unselected_element_counts(self):
        # "on any element in the document" -- not the canvas selection.
        store = _unused_store([_path(0, "lib_a/a"), _path(60, None)], [])
        store.document()["selection"] = [[0, 1]]
        _run(store, "select_all_unused_brushes")
        assert store.get_panel("brushes", "selected_brushes") == ["b", "c"]

    def test_every_brush_used_selects_nothing(self):
        store = _unused_store([_path(0, "lib_a/a"), _path(20, "lib_a/b"), _path(40, "lib_a/c")], ["a"])
        _run(store, "select_all_unused_brushes")
        assert store.get_panel("brushes", "selected_brushes") == []

    def test_no_selected_library_is_a_no_op(self):
        store = _unused_store([_path(0, None)], ["b"])
        store.set_panel("brushes", "selected_library", None)
        _run(store, "select_all_unused_brushes")
        assert store.get_panel("brushes", "selected_brushes") == ["b"]

    def test_the_library_data_is_not_touched(self):
        store = _unused_store([_path(0, "lib_a/b")], [])
        _run(store, "select_all_unused_brushes")
        assert [b["slug"] for b in store.get_data_path("brush_libraries.lib_a.brushes")] == ["a", "b", "c"]
