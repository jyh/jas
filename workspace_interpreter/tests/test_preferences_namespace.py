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
