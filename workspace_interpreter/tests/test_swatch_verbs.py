"""The Swatches panel's five library verbs, as YAML effects.

``duplicate_swatch``, ``delete_swatch``, ``sort_swatches_by_name``,
``select_all_unused_swatches`` and ``add_used_colors`` were ``log:`` stubs. Two
ports implemented them natively (jas_dioxus ``panels/swatches_panel.rs``,
JasSwift ``SwatchesPanel.dispatchSwatchAction``) as hand copies, and the engine
had none. Each is now a ``swatch.*`` effect over
``data.swatch_libraries.<library>.swatches``, with the selection in the panel's
``selected_swatches`` (indices into the selected library). This file is the
executable meaning of those effects.
"""

from __future__ import annotations

import os

import yaml

from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore

_WS = os.path.join(os.path.dirname(__file__), "..", "..", "workspace")

with open(os.path.join(_WS, "actions.yaml"), encoding="utf-8") as f:
    ACTIONS = yaml.safe_load(f)["actions"]


def _sw(name, color="#000000"):
    return {"name": name, "color": color, "color_mode": "rgb", "color_type": "process", "global": False}


def _rect(fill=None, stroke=None):
    el = {"kind": "Rect", "x": 0.0, "y": 0.0, "width": 10.0, "height": 10.0}
    if fill is not None:
        el["fill"] = {"color": fill}
    if stroke is not None:
        el["stroke"] = {"color": stroke, "width": 1.0}
    return el


def _store(swatches, selected, children=(), library="lib_a"):
    store = StateStore(document={
        "layers": [{
            "kind": "Layer", "name": "L",
            "common": {"visibility": "preview", "locked": False, "opacity": 1.0},
            "children": list(children),
        }],
        "selection": [],
    })
    store.set_data({"swatch_libraries": {
        "lib_a": {"name": "A", "swatches": swatches},
        "lib_b": {"name": "B", "swatches": [_sw("Other", "#123456")]},
    }})
    store.init_panel("swatches", {"selected_library": library, "selected_swatches": selected})
    store.set_active_panel("swatches")
    return store


def _run(store, name):
    run_effects(ACTIONS[name]["effects"], {}, store, actions=ACTIONS)


def _lib(store, lib="lib_a"):
    return store.get_data_path(f"swatch_libraries.{lib}.swatches")


def _names(store, lib="lib_a"):
    return [s["name"] for s in _lib(store, lib)]


def _sel(store):
    return store.get_panel("swatches", "selected_swatches")


ABC = [_sw("A", "#ff0000"), _sw("B", "#00ff00"), _sw("C", "#0000ff")]


class TestDuplicateSwatch:
    def test_the_action_passes_its_operands(self):
        assert ACTIONS["duplicate_swatch"]["effects"] == [{"swatch.duplicate_selected": {
            "library": "panel.selected_library", "indices": "panel.selected_swatches"}}]

    def test_copies_follow_their_originals_and_become_the_selection(self):
        store = _store([dict(s) for s in ABC], [2, 0])        # unsorted on purpose
        _run(store, "duplicate_swatch")
        assert _names(store) == ["A", "A copy", "B", "C", "C copy"]
        assert _sel(store) == [1, 4]
        assert _lib(store)[1]["color"] == "#ff0000"           # the copy keeps the original's fields
        assert _names(store, "lib_b") == ["Other"]

    def test_negative_and_out_of_range_indices_are_skipped(self):
        store = _store([dict(s) for s in ABC], [-1, 1, 7])
        _run(store, "duplicate_swatch")
        assert _names(store) == ["A", "B", "B copy", "C"]
        assert _sel(store) == [2]

    def test_empty_selection_is_a_no_op(self):
        store = _store([dict(s) for s in ABC], [])
        _run(store, "duplicate_swatch")
        assert _names(store) == ["A", "B", "C"]
        assert _sel(store) == []


class TestDeleteSwatch:
    def test_the_action_passes_its_operands(self):
        assert ACTIONS["delete_swatch"]["effects"] == [{"swatch.delete_selected": {
            "library": "panel.selected_library", "indices": "panel.selected_swatches"}}]

    def test_removes_the_selected_and_clears_the_selection(self):
        store = _store([dict(s) for s in ABC], [0, 2])
        _run(store, "delete_swatch")
        assert _names(store) == ["B"]
        assert _sel(store) == []
        assert _names(store, "lib_b") == ["Other"]

    def test_negative_and_out_of_range_indices_are_skipped(self):
        store = _store([dict(s) for s in ABC], [-1, 1, 3])
        _run(store, "delete_swatch")
        assert _names(store) == ["A", "C"]

    def test_an_unknown_library_is_a_no_op(self):
        store = _store([dict(s) for s in ABC], [0], library="nope")
        _run(store, "delete_swatch")
        assert _names(store) == ["A", "B", "C"]
        assert _sel(store) == [0]


class TestSortSwatchesByName:
    def test_the_action_passes_its_operand(self):
        assert ACTIONS["sort_swatches_by_name"]["effects"] == [
            {"swatch.sort_by_name": {"library": "panel.selected_library"}}]

    def test_case_sensitive_code_point_order_and_the_selection_clears(self):
        store = _store([_sw("b"), _sw("B"), _sw("a"), _sw("A")], [1])
        _run(store, "sort_swatches_by_name")
        assert _names(store) == ["A", "B", "a", "b"]
        assert _sel(store) == []

    def test_order_is_by_code_point_not_by_canonical_equivalence(self):
        # A precomposed "é" (U+00E9) sorts after "z"; a decomposed "e" + U+0301
        # sorts with the "e"s. Swift's String `<` would put them together.
        store = _store([_sw("é"), _sw("z"), _sw("é"), _sw("f")], [])
        _run(store, "sort_swatches_by_name")
        assert _names(store) == ["é", "f", "z", "é"]

    def test_equal_names_keep_their_relative_order(self):
        store = _store([_sw("X", "#000001"), _sw("A"), _sw("X", "#000002"), _sw("X", "#000003")], [])
        _run(store, "sort_swatches_by_name")
        assert [s["color"] for s in _lib(store)][1:] == ["#000001", "#000002", "#000003"]

    def test_equal_names_keep_their_order_on_a_large_library(self):
        # The size the Rust and Swift tables use: their unstable sorts behave
        # stably on small arrays, so stability is only witnessed at this size.
        many = [_sw(["Y", "X", "Z"][(i * 7) % 3], f"#{i:06x}") for i in range(64)]
        store = _store(many, [])
        _run(store, "sort_swatches_by_name")
        for name in "XYZ":
            order = [s["color"] for s in _lib(store) if s["name"] == name]
            assert order == sorted(order)

    def test_a_swatch_with_no_name_sorts_as_the_empty_string(self):
        nameless = {"color": "#abcdef"}
        store = _store([_sw("A"), nameless], [])
        _run(store, "sort_swatches_by_name")
        assert _lib(store)[0] == nameless

    def test_only_the_selected_library_moves(self):
        store = _store([_sw("b"), _sw("a")], [], library="lib_b")
        _run(store, "sort_swatches_by_name")
        assert _names(store) == ["b", "a"]


class TestSelectAllUnusedSwatches:
    def test_the_action_passes_its_operand(self):
        assert ACTIONS["select_all_unused_swatches"]["effects"] == [
            {"swatch.select_unused": {"library": "panel.selected_library"}}]

    def test_a_colour_used_as_fill_or_stroke_is_left_out(self):
        # "#FF0000" in the library matches a fill of "#ff0000": both reduce to
        # lower-case hex without the "#".
        store = _store([_sw("R", "#FF0000"), _sw("G", "#00ff00"), _sw("B", "#0000ff")], [],
                       children=[_rect(fill="#ff0000"), _rect(stroke="#0000FF")])
        _run(store, "select_all_unused_swatches")
        assert _sel(store) == [1]

    def test_use_inside_a_group_counts(self):
        group = {"kind": "Group", "children": [_rect(fill="#00ff00")]}
        store = _store([dict(s) for s in ABC], [], children=[group])
        _run(store, "select_all_unused_swatches")
        assert _sel(store) == [0, 2]

    def test_an_empty_document_selects_every_swatch(self):
        store = _store([dict(s) for s in ABC], [1])
        _run(store, "select_all_unused_swatches")
        assert _sel(store) == [0, 1, 2]

    def test_the_library_data_is_not_touched(self):
        store = _store([dict(s) for s in ABC], [])
        _run(store, "select_all_unused_swatches")
        assert _lib(store) == ABC


class TestAddUsedColors:
    def test_the_action_passes_its_operand(self):
        assert ACTIONS["add_used_colors"]["effects"] == [
            {"swatch.add_used_colors": {"library": "panel.selected_library"}}]

    def test_new_colours_are_appended_sorted_by_hex_and_named_by_rgb(self):
        store = _store([_sw("Red", "#FF0000")], [],
                       children=[_rect(fill="#ff0000", stroke="#0a0b0c"), _rect(fill="#00ff00")])
        _run(store, "add_used_colors")
        assert _lib(store) == [
            _sw("Red", "#FF0000"),
            {"name": "R=0 G=255 B=0", "color": "#00ff00", "color_mode": "rgb",
             "color_type": "process", "global": False},
            {"name": "R=10 G=11 B=12", "color": "#0a0b0c", "color_mode": "rgb",
             "color_type": "process", "global": False},
        ]

    def test_a_colour_already_present_is_not_added_twice(self):
        store = _store([dict(s) for s in ABC], [], children=[_rect(fill="#FF0000")])
        _run(store, "add_used_colors")
        assert _names(store) == ["A", "B", "C"]

    def test_the_selection_is_not_touched(self):
        store = _store([dict(s) for s in ABC], [2], children=[_rect(fill="#123123")])
        _run(store, "add_used_colors")
        assert _sel(store) == [2]
