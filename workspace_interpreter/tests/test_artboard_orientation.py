"""`toggle_artboard_orientation`: Artboard Options' orientation pair swaps
dialog.width and dialog.height AROUND the reference-point anchor (its own
description, actions.yaml): the anchor point stays where it was.

Until 2026-10-15 the action was a `log:` stub in every port (`dead_both` in
check_action_implementations), so Landscape was refused as a platform effect
(flask STATUS §290). The law lives in actions.yaml as effects, so every port
runs the same table. Expected positions are DERIVED from the anchor rule, not
typed: the anchor point before equals the anchor point after.
"""

from __future__ import annotations

import json
import os

import pytest

from workspace_interpreter.effects import run_effects
from workspace_interpreter.expr import evaluate
from workspace_interpreter.state_store import StateStore

BUNDLE = os.path.join(os.path.dirname(__file__), "..", "..", "workspace", "workspace.json")
ANCHORS = ("top_left", "top_center", "top_right", "middle_left", "center",
           "middle_right", "bottom_left", "bottom_center", "bottom_right")


def _bundle() -> dict:
    with open(BUNDLE, encoding="utf-8") as f:
        return json.load(f)


def _anchor_point(store, anchor):
    ctx = store.eval_context({})
    ox = evaluate(f"anchor_offset_x('{anchor}', dialog.width)", ctx).value
    oy = evaluate(f"anchor_offset_y('{anchor}', dialog.height)", ctx).value
    return (store.get_dialog("x_stored") + ox, store.get_dialog("y_stored") + oy)


def _toggle(anchor, w=100.0, h=200.0, x=10.0, y=20.0):
    b = _bundle()
    store = StateStore()
    store.init_panel("artboards", {"reference_point": anchor})
    store.set_active_panel("artboards")
    store.init_dialog("artboard_options", {"width": w, "height": h, "x_stored": x, "y_stored": y})
    before = _anchor_point(store, anchor)
    run_effects(b["actions"]["toggle_artboard_orientation"]["effects"], {}, store,
                actions=b["actions"])
    return store, before


@pytest.mark.parametrize("anchor", ANCHORS)
def test_the_size_swaps_and_the_anchor_point_stays(anchor):
    store, before = _toggle(anchor)
    assert (store.get_dialog("width"), store.get_dialog("height")) == (200.0, 100.0)
    assert _anchor_point(store, anchor) == pytest.approx(before), anchor


def test_the_centre_example_written_out():
    # 100x200 at (10, 20) around its centre (60, 120): 200x100 there is at (-40, 70).
    store, _ = _toggle("center")
    assert (store.get_dialog("x_stored"), store.get_dialog("y_stored")) == pytest.approx((-40.0, 70.0))


def test_toggling_twice_is_the_identity():
    store, _ = _toggle("bottom_right", w=37.5, h=81.0, x=-3.0, y=12.25)
    # The control: one toggle moved something, or "twice" proves nothing (a
    # stub that does nothing is also the identity).
    assert store.get_dialog("width") == 81.0, "the first toggle swapped"
    b = _bundle()
    run_effects(b["actions"]["toggle_artboard_orientation"]["effects"], {}, store, actions=b["actions"])
    got = tuple(store.get_dialog(k) for k in ("width", "height", "x_stored", "y_stored"))
    assert got == pytest.approx((37.5, 81.0, -3.0, 12.25))


def test_it_is_no_longer_a_log_stub():
    effects = _bundle()["actions"]["toggle_artboard_orientation"]["effects"]
    assert not any("log" in e for e in effects), effects
