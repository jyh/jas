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
from workspace_interpreter.tests.store_docs import Color, Fill, Group, Layer, Rect, Stroke, store_doc

_WS = os.path.join(os.path.dirname(__file__), "..", "..", "workspace")

with open(os.path.join(_WS, "actions.yaml"), encoding="utf-8") as f:
    ACTIONS = yaml.safe_load(f)["actions"]


def _sw(name, color="#000000"):
    return {"name": name, "color": color, "color_mode": "rgb", "color_type": "process", "global": False}


def _rect(fill=None, stroke=None):
    return Rect(x=0.0, y=0.0, width=10.0, height=10.0,
                fill=None if fill is None else Fill(color=Color.from_hex(fill)),
                stroke=None if stroke is None else Stroke(color=Color.from_hex(stroke), width=1.0))


def _store(swatches, selected, children=(), library="lib_a"):
    store = StateStore(document=store_doc(Layer(name="L", children=tuple(children))))
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
        group = Group(children=(_rect(fill="#00ff00"),))
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


# ══════════════════════════════════════════════════════════════════
# Swatch Options: open in edit mode from the selection, and OK
# ══════════════════════════════════════════════════════════════════
#
# The panel menu's "Swatch Options..." passes only {mode: edit}, so the dialog
# names its swatch through the panel selection (the first selected swatch of
# the selected library), and OK stores through `swatch.store`.

with open(os.path.join(_WS, "dialogs", "swatch_options.yaml"), encoding="utf-8") as f:
    DIALOGS = yaml.safe_load(f)


def _open(store, params):
    run_effects(ACTIONS["open_swatch_options"]["effects"], {"param": params}, store,
                actions=ACTIONS, dialogs=DIALOGS)


def _ok_params(store):
    """The OK button's params, resolved in the dialog's scope, as a button click does."""
    from workspace_interpreter.expr import evaluate
    button = [b for b in _buttons(DIALOGS["swatch_options"]["content"]) if b.get("label") == "OK"][0]
    ctx = store.eval_context()
    return {k: evaluate(v, ctx).value for k, v in (button.get("params") or {}).items()}


def _buttons(node):
    if isinstance(node, dict):
        if node.get("type") == "button":
            yield node
        for c in node.get("children") or []:
            yield from _buttons(c)


def _ok(store):
    params = _ok_params(store)
    run_effects(ACTIONS["swatch_options_confirm"]["effects"], {"param": params}, store,
                actions=ACTIONS, dialogs=DIALOGS)


class TestSwatchOptions:
    def test_edit_mode_opens_on_the_first_selected_swatch(self):
        store = _store([dict(s) for s in ABC], [1, 2])
        _open(store, {"mode": "edit"})
        assert store.get_dialog_id() == "swatch_options"
        assert store.get_dialog("swatch_name") == "B"
        assert store.get_dialog("color") == "#00ff00"

    def test_ok_in_edit_mode_replaces_that_swatch(self):
        store = _store([dict(s) for s in ABC], [1])
        _open(store, {"mode": "edit"})
        store.set_dialog("swatch_name", "Bee")
        _ok(store)
        assert store.get_dialog_id() is None
        assert _lib(store)[1] == {"name": "Bee", "color": "#00ff00", "color_mode": "rgb",
                                  "color_type": "process", "global": False}
        assert _names(store) == ["A", "Bee", "C"]

    def test_ok_in_create_mode_appends_to_the_selected_library(self):
        store = _store([dict(s) for s in ABC], [])
        _open(store, {"mode": "create", "color": "#123456"})
        store.set_dialog("swatch_name", "New")
        _ok(store)
        assert _lib(store)[-1]["name"] == "New"
        assert _lib(store)[-1]["color"] == "#123456"
        assert _names(store, "lib_b") == ["Other"]

    def test_a_tile_names_its_own_swatch_over_the_selection(self):
        # A library tile's double-click passes its library and index; with a
        # multi-selection, the first selected swatch is NOT the one edited.
        store = _store([dict(s) for s in ABC], [0, 2])
        _open(store, {"mode": "edit", "swatch_name": "C", "color": "#0000ff",
                      "color_mode": "rgb", "library": "lib_a", "index": 2})
        assert store.get_dialog("swatch_name") == "C"
        store.set_dialog("swatch_name", "Sea")
        _ok(store)
        assert _names(store) == ["A", "B", "Sea"]

    def test_cancel_stores_nothing(self):
        store = _store([dict(s) for s in ABC], [0])
        _open(store, {"mode": "edit"})
        store.set_dialog("swatch_name", "Changed")
        run_effects(ACTIONS["dismiss_dialog"]["effects"], {}, store, actions=ACTIONS, dialogs=DIALOGS)
        assert _names(store) == ["A", "B", "C"]
