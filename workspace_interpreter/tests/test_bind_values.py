"""Reference-side gate for the panel bind-VALUE snapshot pass.

Three jobs, in increasing order of what they prove:

1. ``test_canon_*`` — hand-written expectations for the value stringifier over a
   synthetic panel, so the canonical form of each expression-language type is
   pinned without depending on the compiled bundle.
2. ``test_fixture_is_fresh`` — the shared corpus
   (``test_fixtures/algorithms/panel_bind_values.json``) still equals what this
   reference produces, so a golden the two ports are asserting against cannot
   silently go stale relative to the spec's executable meaning.
3. ``test_equal_length_hex_*`` — the census §5.8 claim, as a live regression pin:
   ``"664040"`` vs ``"664141"`` is invisible to ``panel_layout`` (which pins a
   scalar COUNT times a constant) and to ``widget_tree`` (which pins the sorted
   KEY NAMES of ``bind``), and visible to this pass. That difference is the whole
   reason the family exists, so it is asserted rather than described.
"""
from __future__ import annotations

import json
import os

from workspace_interpreter.bind_values import bind_values
from workspace_interpreter.panel_layout import layout_panel
from workspace_interpreter.widget_tree import widget_tree

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURE = os.path.join(
    REPO_ROOT, "test_fixtures", "algorithms", "panel_bind_values.json")
BUNDLE = os.path.join(REPO_ROOT, "workspace", "workspace.json")


def _bundle_panels() -> dict:
    with open(BUNDLE, encoding="utf-8") as f:
        return json.load(f)["panels"]


# --------------------------------------------------------------------------
# 1. The canonical value form, per expression-language type
# --------------------------------------------------------------------------

def _synthetic_panel() -> dict:
    """A hand-built panel exercising one row of each canonical value type."""
    return {
        "type": "panel",
        "content": {
            "type": "col",
            "id": "root",
            "children": [
                {"type": "color_swatch", "id": "w_color",
                 "bind": {"color": "state.fill_color"}},
                {"type": "color_swatch", "id": "w_null",
                 "bind": {"color": "state.missing"}},
                {"type": "number_input", "id": "w_int",
                 "bind": {"value": "state.n_int"}},
                {"type": "number_input", "id": "w_frac",
                 "bind": {"value": "state.n_frac"}},
                {"type": "text_input", "id": "w_str",
                 "bind": {"value": "state.hex"}},
                {"type": "checkbox", "id": "w_bool",
                 "bind": {"checked": "state.flag"}},
                {"type": "container", "id": "w_list",
                 "bind": {"selected_in": "state.picked"}},
                {"type": "text", "id": "w_text",
                 "content": "{{state.hex}} / {{state.n_frac}}"},
                {"type": "text", "id": "w_static", "content": "literal"},
                {"type": "container", "id": "w_dynvis",
                 "visible": "state.flag"},
                {"type": "container", "id": "w_nothing"},
            ],
        },
    }


_SYN_CTX = {
    "state": {
        "fill_color": "#664040",
        "n_int": 4,
        "n_frac": 2.5,
        "hex": "664040",
        "flag": False,
        "picked": ["a", "b"],
    },
}


def test_canon_covers_every_type_and_skips_valueless_nodes():
    rows = bind_values(_synthetic_panel(), _SYN_CTX)
    assert rows == [
        {"path": [0], "id": "w_color", "key": "bind.color",
         "type": "color", "value": "#664040"},
        {"path": [1], "id": "w_null", "key": "bind.color",
         "type": "null", "value": ""},
        {"path": [2], "id": "w_int", "key": "bind.value",
         "type": "number", "value": "4"},
        {"path": [3], "id": "w_frac", "key": "bind.value",
         "type": "number", "value": "2.5"},
        {"path": [4], "id": "w_str", "key": "bind.value",
         "type": "string", "value": "664040"},
        {"path": [5], "id": "w_bool", "key": "bind.checked",
         "type": "bool", "value": "false"},
        {"path": [6], "id": "w_list", "key": "bind.selected_in",
         "type": "list", "value": "[a,b]"},
        {"path": [7], "id": "w_text", "key": "content",
         "type": "string", "value": "664040 / 2.5"},
        {"path": [9], "id": "w_dynvis", "key": "visible",
         "type": "bool", "value": "false"},
    ]


def test_canon_row_order_is_visible_then_sorted_bind_then_content_then_label():
    panel = {
        "type": "panel",
        "content": {
            "type": "col",
            "children": [{
                "type": "button", "id": "w",
                "visible": "state.flag",
                "bind": {"value": "state.n_int", "checked": "state.flag",
                         "label": "state.hex", "disabled": "state.flag"},
                "label": "{{state.hex}}",
                "content": "{{state.n_int}}",
            }],
        },
    }
    rows = bind_values(panel, _SYN_CTX)
    assert [r["key"] for r in rows] == [
        "visible", "bind.checked", "bind.disabled", "bind.label", "bind.value",
        "content", "label",
    ]


def test_canon_null_and_empty_string_differ_only_in_type():
    panel = {
        "type": "panel",
        "content": {
            "type": "col",
            "children": [
                {"type": "text_input", "id": "a", "bind": {"value": "state.missing"}},
                {"type": "text_input", "id": "b", "bind": {"value": "state.empty"}},
            ],
        },
    }
    rows = bind_values(panel, {"state": {"empty": ""}})
    assert [(r["type"], r["value"]) for r in rows] == [("null", ""), ("string", "")]


def test_canon_foreach_resolves_the_per_item_scope():
    panel = {
        "type": "panel",
        "content": {
            "type": "col",
            "children": [{
                "type": "container",
                "foreach": {"source": "data.items", "as": "it"},
                "do": {"type": "color_swatch", "bind": {"color": "it.color"}},
            }],
        },
    }
    ctx = {"data": {"items": [{"color": "#111111"}, {"color": "#222222"}]}}
    rows = bind_values(panel, ctx)
    assert rows == [
        {"path": [0, 0], "id": "", "key": "bind.color",
         "type": "color", "value": "#111111"},
        {"path": [0, 1], "id": "", "key": "bind.color",
         "type": "color", "value": "#222222"},
    ]


# --------------------------------------------------------------------------
# 2. The shared corpus is what this reference produces
# --------------------------------------------------------------------------

def test_fixture_is_fresh():
    with open(FIXTURE, encoding="utf-8") as f:
        cases = json.load(f)
    panels = _bundle_panels()
    assert cases, "the corpus must not be empty"
    for tc in cases:
        assert tc["function"] == "bind_values", tc["name"]
        args = tc["args"]
        actual = bind_values(panels[args["panel"]], args.get("ctx") or {})
        assert actual == tc["expected"], (
            f"{tc['name']}: golden is stale relative to the reference "
            "(re-run scripts/gen_panel_layout_fixture.py)")


def test_fixture_covers_the_four_expression_shapes():
    """The family's stated scope: a colour swatch, a numeric field with units,
    a conditional `visible`, and a `foreach`. Asserted so shrinking the corpus
    to a shape it no longer covers reddens here rather than passing quietly."""
    with open(FIXTURE, encoding="utf-8") as f:
        cases = json.load(f)
    panels = _bundle_panels()
    rows = [r for tc in cases
            for r in bind_values(panels[tc["args"]["panel"]],
                                 tc["args"].get("ctx") or {})]
    kinds = {(r["key"], r["type"]) for r in rows}
    assert ("bind.color", "color") in kinds       # a colour swatch
    assert ("bind.value", "number") in kinds      # a numeric field
    assert ("bind.visible", "bool") in kinds      # a conditional `visible`
    # a foreach: the only rows with a path deeper than the declared tree are
    # foreach expansions, and the swatches vector nests two of them.
    assert any(len(r["path"]) >= 4 for r in rows)
    # the `{{ }}` text surface panel_layout reduces to a scalar count
    assert any(r["key"] in ("content", "label") for r in rows)


# --------------------------------------------------------------------------
# 3. The census §5.8 claim, pinned
# --------------------------------------------------------------------------

def _hex_ctx(hex_value: str) -> dict:
    return {
        "state": {"fill_color": "#664040", "fill_on_top": True},
        "panel": {"mode": "hsb", "hex": hex_value},
    }


def test_equal_length_hex_is_invisible_to_the_two_older_panel_gates():
    """The blind spot, asserted so it cannot be quietly closed elsewhere and
    leave this family looking redundant."""
    panel = _bundle_panels()["color_panel_content"]
    a, b = _hex_ctx("664040"), _hex_ctx("664141")
    assert widget_tree(panel, a) == widget_tree(panel, b)
    assert layout_panel(panel, 228, 600, a) == layout_panel(panel, 228, 600, b)


def test_equal_length_hex_is_visible_to_bind_values():
    panel = _bundle_panels()["color_panel_content"]
    rows_a = bind_values(panel, _hex_ctx("664040"))
    rows_b = bind_values(panel, _hex_ctx("664141"))
    diff = [(x, y) for x, y in zip(rows_a, rows_b) if x != y]
    assert len(rows_a) == len(rows_b)
    assert len(diff) == 1, f"expected exactly one differing row, got {diff}"
    x, y = diff[0]
    assert x["id"] == "cp_hex" and x["key"] == "bind.value"
    assert (x["value"], y["value"]) == ("664040", "664141")
