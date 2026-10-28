"""`state.brushes_open_libraries` is initialised at startup from
`preferences.brushes.persistent_libraries` (state.yaml; STATUS-jas item 37,
launch half), against the shared fixture
`test_fixtures/preferences/open_libraries_at_launch.json`, which the active
ports read too."""

from __future__ import annotations

import json
import os

import pytest

from workspace_interpreter.loader import state_defaults
from workspace_interpreter.state_store import StateStore, open_libraries_at_launch

_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
_FIXTURE = os.path.join(_ROOT, "test_fixtures", "preferences/open_libraries_at_launch.json")


def _cases():
    with open(_FIXTURE, encoding="utf-8") as f:
        return json.load(f)["cases"]


def _state_defs():
    with open(os.path.join(_ROOT, "workspace", "workspace.json"), encoding="utf-8") as f:
        return json.load(f)["state"]


def test_the_fixture_is_not_vacuous():
    assert len(_cases()) >= 4


@pytest.mark.parametrize("case", _cases(), ids=lambda c: c["name"])
def test_open_libraries_at_launch(case):
    assert open_libraries_at_launch(case["persistent_libraries"]) == case["expected"]


def test_the_store_opens_the_bundles_libraries():
    store = StateStore(defaults=state_defaults(_state_defs()))
    assert store.get("brushes_open_libraries") == [{"id": "default_brushes", "collapsed": False}]


def test_the_store_opens_an_overridden_preference_at_launch():
    """The persisted overrides are read at launch: a store built with them
    opens what the user's preference names, not the static default."""
    store = StateStore(defaults=state_defaults(_state_defs()),
                       preference_overrides={"brushes.persistent_libraries": ["wet_media"]})
    assert store.preferences()["brushes"]["persistent_libraries"] == ["wet_media"]
    assert store.get("brushes_open_libraries") == [{"id": "wet_media", "collapsed": False}]


def test_a_store_without_the_state_key_gains_none():
    assert StateStore(preference_overrides={"brushes.persistent_libraries": ["wet_media"]}).get(
        "brushes_open_libraries") is None
