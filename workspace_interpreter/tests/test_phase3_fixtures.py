"""Fixture-based cross-language tests for Phase 3 actions.

Each YAML in workspace/tests/phase3/ describes one scenario:
  description:     human-readable label
  action:          the action name from workspace/actions.yaml
  initial_doc:     {layers: [...]} — starting document tree
  expected_doc:    {layers: [...]} — tree after running the action
  expected_snapshots: int — how many snapshots should be taken

This test loads the real workspace/actions.yaml, runs the action's
effects against the initial_doc, and asserts the tree matches
expected_doc. The same fixtures must pass in all 4 language
implementations (PHASE3.md §10.1).
"""

from __future__ import annotations

import glob
import os

import pytest
import yaml

from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore


_FIXTURES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "workspace", "tests", "phase3")
)

_ACTIONS_PATH = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "workspace", "actions.yaml")
)


def _fixture_paths() -> list[str]:
    if not os.path.isdir(_FIXTURES_DIR):
        return []
    return sorted(glob.glob(os.path.join(_FIXTURES_DIR, "*.yaml")))


def _load_actions() -> dict:
    with open(_ACTIONS_PATH) as f:
        loaded = yaml.safe_load(f)
    return loaded.get("actions", {})


_ACTIONS = _load_actions()
_paths = _fixture_paths()
_ids = [os.path.splitext(os.path.basename(p))[0] for p in _paths]


@pytest.mark.parametrize("fixture_path", _paths, ids=_ids)
def test_phase3_fixture(fixture_path: str) -> None:
    with open(fixture_path) as f:
        fixture = yaml.safe_load(f)

    action_name = fixture["action"]
    action_def = _ACTIONS.get(action_name)
    assert action_def is not None, f"Action {action_name!r} not found in actions.yaml"
    effects = action_def.get("effects", [])

    store = StateStore(defaults={"tab_count": 1}, document=fixture["initial_doc"])
    run_effects(effects, {}, store)

    # Assert the document tree matches expected_doc
    expected = fixture["expected_doc"]
    actual = store.document()
    assert actual == expected, (
        f"\n--- Fixture: {os.path.basename(fixture_path)} ---\n"
        f"Expected: {expected}\n"
        f"Actual:   {actual}"
    )

    # Assert snapshot count
    expected_snapshots = fixture.get("expected_snapshots", 0)
    assert len(store.snapshots()) == expected_snapshots, (
        f"Expected {expected_snapshots} snapshot(s), got {len(store.snapshots())}"
    )
