"""`apply_artboard_preset`: the Artboard Options preset dropdown sets
dialog.width / dialog.height to the preset's size.

The law lives in `workspace/actions.yaml` as effects, so every port runs
the same table. The expected sizes are NOT typed here: they are parsed
from the dropdown's own option labels ("A4 (595.28 × 841.89)") in the
compiled bundle, so this arm fails if a label and the action disagree.
"Custom" has no size and leaves the dialog alone.
"""

from __future__ import annotations

import json
import os
import re

from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore

BUNDLE = os.path.join(os.path.dirname(__file__), "..", "..", "workspace", "workspace.json")
SIZE = re.compile(r"\(([0-9.]+) × ([0-9.]+)\)$")


def _bundle() -> dict:
    with open(BUNDLE, encoding="utf-8") as f:
        return json.load(f)


def _find(node, wid):
    if isinstance(node, dict):
        if node.get("id") == wid:
            return node
        for v in node.values():
            hit = _find(v, wid)
            if hit is not None:
                return hit
    elif isinstance(node, list):
        for v in node:
            hit = _find(v, wid)
            if hit is not None:
                return hit
    return None


def _options() -> list[tuple[str, tuple[float, float] | None]]:
    """(value, (w, h)) for every preset option; None for Custom."""
    sel = _find(_bundle()["dialogs"]["artboard_options"], "ao_preset")
    assert sel is not None, "the preset select is in the bundle"
    out = []
    for o in sel["options"]:
        m = SIZE.search(o["label"])
        out.append((o["value"], (float(m.group(1)), float(m.group(2))) if m else None))
    return out


def _apply(preset: str) -> tuple[object, object]:
    b = _bundle()
    store = StateStore()
    store.init_dialog("artboard_options", {"width": 123.0, "height": 45.0, "preset": preset})
    run_effects(b["actions"]["apply_artboard_preset"]["effects"],
                {"param": {"preset": preset}}, store,
                actions=b["actions"], dialogs=b["dialogs"])
    return store.get_dialog("width"), store.get_dialog("height")


def test_the_option_list_is_what_this_arm_expects():
    opts = _options()
    # Ten sized presets and Custom: a population check, so a label edit
    # that breaks the size parse cannot shrink this arm to nothing.
    assert len(opts) == 11
    assert [v for v, s in opts if s is None] == ["custom"]


def test_every_sized_preset_sets_its_labelled_size():
    for value, size in _options():
        if size is None:
            continue
        w, h = _apply(value)
        assert (w, h) == size, f"{value}: dialog {w} x {h}, label says {size}"


def test_custom_leaves_the_size_alone():
    assert _apply("custom") == (123.0, 45.0)
