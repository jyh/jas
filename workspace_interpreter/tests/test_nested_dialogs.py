"""A dialog opened from inside another dialog (the Color Picker from Layer
Options or Artboard Options) returns to its parent.

Before the dialog stack, every store held ONE dialog: the child replaced the
parent, the picker's OK wrote the APP's stroke colour (its target enum was
fill or stroke only), and closing it left no dialog open. These tests drive the
SHIPPED workspace: the openers' params and the picker's OK effects are read
from `workspace.json`, never typed here.
"""

import json
import pathlib

import pytest

from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore

WORKSPACE = json.loads(
    (pathlib.Path(__file__).resolve().parents[2] / "workspace" / "workspace.json").read_text(encoding="utf-8"))
ACTIONS = WORKSPACE["actions"]
DIALOGS = WORKSPACE["dialogs"]


def _find(node, pred):
    """The first node under `node` (depth first) for which `pred` holds."""
    if isinstance(node, dict):
        if pred(node):
            return node
        for v in node.values():
            hit = _find(v, pred)
            if hit is not None:
                return hit
    elif isinstance(node, list):
        for v in node:
            hit = _find(v, pred)
            if hit is not None:
                return hit
    return None


def _picker_opener(parent):
    """The params the parent's swatch passes to `open_color_picker`."""
    node = _find(DIALOGS[parent]["content"], lambda n: any(
        b.get("action") == "open_color_picker" for b in n.get("behavior", []) if isinstance(b, dict)))
    assert node is not None, f"{parent} opens no colour picker"
    return next(b for b in node["behavior"] if b.get("action") == "open_color_picker")["params"]


def _picker_ok_effects():
    """The picker's OK button's click effects, as the spec writes them."""
    ok = _find(DIALOGS["color_picker"]["content"],
               lambda n: n.get("type") == "button" and n.get("label") == "OK")
    assert ok is not None, "the colour picker has no OK button"
    return next(b for b in ok["behavior"] if b.get("event") == "click")["effects"]


def _dispatch(store, action, params):
    run_effects([{"dispatch": {"action": action, "params": params}}], {}, store,
                actions=ACTIONS, dialogs=DIALOGS)


@pytest.mark.parametrize("parent,field", [("layer_options", "color"), ("artboard_options", "fill")])
def test_the_swatch_targets_its_own_dialog_field(parent, field):
    # The census the defect was found by: each nested opener names a field of
    # its OWN dialog, which the picker's OK must write. A dispatch param is an
    # EXPRESSION, so the name is a quoted string literal (a bare `dialog.color`
    # would pass the colour itself), and the field's colour rides beside it.
    params = _picker_opener(parent)
    assert params["target"] == f'"dialog.{field}"'
    assert params["color"] == f"dialog.{field}"


def test_ok_in_a_nested_picker_writes_the_parent_field_and_returns_to_it():
    store = StateStore({"stroke_color": "#000000", "fill_color": "#ffffff"})
    _dispatch(store, "open_layer_options", {"mode": '"create"'})
    assert store.get_dialog_id() == "layer_options"
    store.set_dialog("name", "Edited")

    _dispatch(store, "open_color_picker", _picker_opener("layer_options"))
    assert store.get_dialog_id() == "color_picker"
    assert store.get_dialog("color") == "#4a90d9", "the picker starts from the parent's colour"
    store.set_dialog("color", "#ff0000")

    run_effects(_picker_ok_effects(), {}, store, actions=ACTIONS, dialogs=DIALOGS)

    assert store.get_dialog_id() == "layer_options", "OK returns to the parent"
    assert store.get_dialog("name") == "Edited", "the parent keeps its edits"
    assert store.get_dialog("color") == "#ff0000", "the picked colour lands in the parent's field"
    assert store.get("stroke_color") == "#000000", "the app's stroke is not the target"
    assert store.get("fill_color") == "#ffffff"


def test_cancel_in_a_nested_picker_returns_to_the_parent_unchanged():
    store = StateStore({"stroke_color": "#000000"})
    _dispatch(store, "open_layer_options", {"mode": '"create"'})
    before = store.get_dialog("color")
    _dispatch(store, "open_color_picker", _picker_opener("layer_options"))
    store.set_dialog("color", "#ff0000")

    _dispatch(store, "dismiss_dialog", {})

    assert store.get_dialog_id() == "layer_options"
    assert store.get_dialog("color") == before
    assert store.get("stroke_color") == "#000000"


def test_closing_the_parent_after_the_child_leaves_no_dialog():
    store = StateStore()
    _dispatch(store, "open_layer_options", {"mode": '"create"'})
    _dispatch(store, "open_color_picker", _picker_opener("layer_options"))
    _dispatch(store, "dismiss_dialog", {})
    _dispatch(store, "dismiss_dialog", {})
    assert store.get_dialog_id() is None
