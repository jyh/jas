"""swap_panel_state: exchange two keys of one panel's state.

Two forms, both in the workspace:
  - ``swap_panel_state: [a, b]`` swaps them in the ACTIVE panel
    (stroke.yaml's ``stk_swap_arrowheads`` widget);
  - ``swap_panel_state: { panel: <id>, keys: [a, b] }`` swaps them in the
    named panel (actions.yaml's ``swap_arrowheads``).

Until this node the reference had no arm for it: the effect was implemented
only by the jas_dioxus web renderer (the array form, hard-wired to the Stroke
panel's typed slot) and the non-gating flask renderer, while JasSwift had no
arm and the engine refused it by name. A key list that is not exactly two
names is a no-op.
"""

from __future__ import annotations

import os

import yaml

from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore

_WS = os.path.join(os.path.dirname(__file__), "..", "..", "workspace")


def _yaml(*parts: str) -> dict:
    with open(os.path.join(_WS, *parts), encoding="utf-8") as f:
        return yaml.safe_load(f)


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


def _stroke_store() -> StateStore:
    store = StateStore({"stroke_start_arrowhead": "simple_arrow", "stroke_end_arrowhead": "none",
                        "stroke_start_arrowhead_scale": 100.0, "stroke_end_arrowhead_scale": 150.0})
    store.init_panel("stroke", {"start_arrowhead": "simple_arrow", "end_arrowhead": "none",
                                "start_arrowhead_scale": 100.0, "end_arrowhead_scale": 150.0})
    store.set_active_panel("stroke")
    return store


def _panel(store: StateStore) -> tuple:
    return tuple(store.get_panel("stroke", k) for k in
                 ("start_arrowhead", "end_arrowhead", "start_arrowhead_scale", "end_arrowhead_scale"))


class TestSwapPanelState:
    def test_array_form_swaps_in_the_active_panel(self):
        store = _stroke_store()
        run_effects([{"swap_panel_state": ["start_arrowhead", "end_arrowhead"]}], {}, store)
        assert _panel(store) == ("none", "simple_arrow", 100.0, 150.0)

    def test_object_form_swaps_in_the_named_panel(self):
        store = _stroke_store()
        store.set_active_panel(None)
        run_effects([{"swap_panel_state": {"panel": "stroke",
                                           "keys": ["start_arrowhead_scale", "end_arrowhead_scale"]}}],
                    {}, store)
        assert _panel(store) == ("simple_arrow", "none", 150.0, 100.0)

    def test_swapping_twice_restores(self):
        store = _stroke_store()
        eff = {"swap_panel_state": ["start_arrowhead", "end_arrowhead"]}
        run_effects([eff, eff], {}, store)
        assert _panel(store) == ("simple_arrow", "none", 100.0, 150.0)

    def test_a_key_list_that_is_not_two_names_is_a_no_op(self):
        # One store PER FORM: run on one store, a wrongly accepted list would
        # swap twice and restore itself (a mutant accepting 3 names survived).
        for keys in (["start_arrowhead"], ["start_arrowhead", "end_arrowhead", "x"], [], "start_arrowhead"):
            for eff in ({"swap_panel_state": keys},
                        {"swap_panel_state": {"panel": "stroke", "keys": keys}}):
                store = _stroke_store()
                run_effects([eff], {}, store)
                assert _panel(store) == ("simple_arrow", "none", 100.0, 150.0), eff

    def test_the_real_swap_arrowheads_widget_swaps_panel_and_globals(self):
        widget = _widget(_yaml("panels", "stroke.yaml"), "stk_swap_arrowheads")
        effects = widget["behavior"][0]["effects"]
        store = _stroke_store()
        run_effects(effects, {}, store)
        assert _panel(store) == ("none", "simple_arrow", 150.0, 100.0)
        assert store.get("stroke_start_arrowhead") == "none"
        assert store.get("stroke_end_arrowhead_scale") == 100.0

    def test_the_real_swap_arrowheads_action_does_the_same(self):
        action = _yaml("actions.yaml")["actions"]["swap_arrowheads"]
        store = _stroke_store()
        run_effects(action["effects"], {}, store)
        assert _panel(store) == ("none", "simple_arrow", 150.0, 100.0)
        assert store.get("stroke_start_arrowhead") == "none"
