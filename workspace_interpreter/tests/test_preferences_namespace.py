"""The `preferences` namespace in the reference's expression context.

`workspace/preferences.yaml` is compiled into the bundle, and both active ports
put its `preferences` into their expression contexts from the BUNDLED workspace
(Rust `renderer.rs` `Workspace::load()`, Swift `PanelMenu.swift` `ws.data`), so
`zoom_in`'s `preferences.viewport.zoom_step` and the Brushes menu's
`checked_when` over `preferences.brushes.persistent_libraries` resolve there.
The reference's context had no such namespace, so both read null.
"""

from __future__ import annotations

import json
import os

import yaml

from workspace_interpreter.expr import evaluate
from workspace_interpreter.state_store import StateStore

_WS = os.path.join(os.path.dirname(__file__), "..", "..", "workspace")


def _bundle_preferences() -> dict:
    with open(os.path.join(_WS, "workspace.json"), encoding="utf-8") as f:
        return json.load(f)["preferences"]


def test_the_context_carries_the_bundled_preferences():
    prefs = _bundle_preferences()
    assert prefs["viewport"]["zoom_step"] not in (None, 0), "the control: the bundle has the value"
    ctx = StateStore().eval_context()
    assert ctx["preferences"] == prefs
    assert evaluate("preferences.viewport.zoom_step", ctx).value == prefs["viewport"]["zoom_step"]


def test_the_brushes_persistent_check_reads_them():
    with open(os.path.join(_WS, "panels", "brushes.yaml"), encoding="utf-8") as f:
        text = f.read()
    expr = 'any(preferences.brushes.persistent_libraries, fun lib -> lib == panel.selected_library)'
    assert text.count(expr) == 1, "the control: the menu's own predicate"
    persistent = _bundle_preferences()["brushes"]["persistent_libraries"]
    assert persistent, "the control: the bundle names a persistent library"
    store = StateStore()
    store.init_panel("brushes", {"selected_library": persistent[0]})
    store.set_active_panel("brushes")
    assert evaluate(expr, store.eval_context()).value is True
    store.set_panel("brushes", "selected_library", persistent[0] + "_not")
    assert evaluate(expr, store.eval_context()).value is False


def _actions() -> dict:
    with open(os.path.join(_WS, "actions.yaml"), encoding="utf-8") as f:
        return yaml.safe_load(f)["actions"]


def test_the_persistent_toggle_writes_an_override_and_the_check_follows():
    """STATUS-jas item 37: `toggle_brush_library_persistent` adds the selected
    library to `preferences.brushes.persistent_libraries` when absent and
    removes it when present, as a user override over the bundle's default;
    the Brushes menu's `checked_when` reads the result."""
    from workspace_interpreter.effects import run_effects
    actions = _actions()
    expr = 'any(preferences.brushes.persistent_libraries, fun lib -> lib == panel.selected_library)'
    bundled = _bundle_preferences()["brushes"]["persistent_libraries"]
    lib = "a_library_not_in_the_bundle"
    assert lib not in bundled, "the control"
    store = StateStore()
    store.init_panel("brushes", {"selected_library": lib})
    store.set_active_panel("brushes")
    checked = lambda: evaluate(expr, store.eval_context()).value
    assert checked() is False
    run_effects(actions["toggle_brush_library_persistent"]["effects"], {}, store, actions=actions)
    assert checked() is True
    assert store.eval_context()["preferences"]["brushes"]["persistent_libraries"] == bundled + [lib]
    from workspace_interpreter.state_store import _bundled_preferences
    assert _bundled_preferences()["brushes"]["persistent_libraries"] == bundled, \
        "the cached bundle is not written either"
    run_effects(actions["toggle_brush_library_persistent"]["effects"], {}, store, actions=actions)
    assert checked() is False
    assert store.eval_context()["preferences"]["brushes"]["persistent_libraries"] == bundled
    assert _bundle_preferences()["brushes"]["persistent_libraries"] == bundled, "the bundle is never written"


def test_the_preference_action_corpus_holds():
    """STATUS-jas item 7: the shared corpus case for the toggle
    (test_fixtures/preference_actions/), each case on a fresh store (no
    overrides). Rust ``the_preference_action_corpus_holds``."""
    import json
    import os
    from workspace_interpreter.effects import run_effects
    path = os.path.join(os.path.dirname(__file__), "..", "..", "test_fixtures",
                        "preference_actions", "toggle_brush_library_persistent.json")
    with open(path, encoding="utf-8") as f:
        cases = json.load(f)["cases"]
    assert len(cases) >= 4, "the fixture is not vacuous"
    actions = _actions()
    bundled = _bundle_preferences()["brushes"]["persistent_libraries"]
    for case in cases:
        sel = case["selected_library"]
        if sel.startswith("bundle["):
            sel = bundled[int(sel[len("bundle["):-1])]
        store = StateStore()
        store.init_panel("brushes", {"selected_library": sel})
        store.set_active_panel("brushes")
        for a in case["actions"]:
            run_effects(actions[a["action"]]["effects"], {}, store, actions=actions)
        want = {"bundle": bundled,
                "bundle + selected": bundled + [sel],
                "bundle - selected": [b for b in bundled if b != sel]}[case["expected"]]
        got = store.eval_context()["preferences"]["brushes"]["persistent_libraries"]
        assert got == want, case["name"]


def test_the_toggle_refuses_a_key_that_is_not_a_bundled_list():
    store = StateStore()
    before = store.eval_context()["preferences"]
    assert isinstance(before["viewport"]["zoom_step"], (int, float)), "the control: a scalar"
    assert store.toggle_preference_member("viewport.zoom_step", 2) is False
    assert store.toggle_preference_member("brushes.no_such_list", "x") is False
    assert store.eval_context()["preferences"] == before
