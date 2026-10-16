"""Brush Options in library_edit loads the brush it edits.

Its five scalar inits read the brush through
`filter(data.brush_libraries[param.library].brushes, fun b -> b.slug == param.brush_slug)[0]`.
Until 2026-10-15 they read a `brushes_by_slug` index that no port builds, so
every edit-mode init was null: the dialog opened with no name, no type and no
size. Create mode keeps the declared defaults.

The library is seeded in the STORE's `data`, as app startup does, never in the
call's context: a dialog init reads `data` through `StateStore.eval_context`,
which did not carry it until 2026-10-15 in any port.
"""
from __future__ import annotations

import json
import os

from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore

ROOT = os.path.join(os.path.dirname(__file__), "..", "..", "workspace")
KEYS = ("brush_name", "brush_type", "angle", "roundness", "size")


def _open(params: dict) -> StateStore:
    with open(os.path.join(ROOT, "workspace.json"), encoding="utf-8") as f:
        b = json.load(f)
    with open(os.path.join(ROOT, "brushes", "default_brushes", "library.json"), encoding="utf-8") as f:
        lib = json.load(f)
    store = StateStore()
    store.set_data({"brush_libraries": {"default_brushes": lib}})
    run_effects(b["actions"]["open_brush_options"]["effects"], {"param": params},
                store, actions=b["actions"], dialogs=b["dialogs"])
    return store


def test_library_edit_loads_the_brush_it_edits():
    store = _open({"mode": "library_edit", "library": "default_brushes", "brush_slug": "round_7pt"})
    got = {k: store.get_dialog(k) for k in KEYS}
    assert got == {"brush_name": "7 pt. Round", "brush_type": "calligraphic",
                   "angle": 0, "roundness": 100, "size": 7}


def test_create_keeps_the_declared_defaults():
    store = _open({"mode": "create"})
    got = {k: store.get_dialog(k) for k in KEYS}
    assert got == {"brush_name": "", "brush_type": "calligraphic",
                   "angle": 0, "roundness": 100, "size": 5}


def test_the_store_context_carries_data():
    store = StateStore()
    store.set_data({"brush_libraries": {"x": {"brushes": []}}})
    assert store.eval_context()["data"] == {"brush_libraries": {"x": {"brushes": []}}}
