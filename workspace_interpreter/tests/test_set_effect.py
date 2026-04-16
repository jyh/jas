"""Fixture-based tests for the schema-driven set: effect.

Each YAML file in workspace/tests/set_effect/ describes one scenario:
  schema:        inline SchemaTable definition (state + panels)
  active_panel:  (optional) panel id to treat as active
  initial_state: flat key→value map; panel keys are "panel.<id>.<field>"
  effect:        { set: { key: value, ... } }
  expected_state:       flat key→value assertions (same key format)
  expected_diagnostics: list of { level, key, reason } dicts

Values in effect.set are treated as already-evaluated Python values
(no expression-engine evaluation), so fixtures can use native YAML types.
"""

from __future__ import annotations

import glob
import os

import pytest
import yaml

from workspace_interpreter.effects import apply_set_schemadriven
from workspace_interpreter.schema import load_schema_from_dict
from workspace_interpreter.state_store import StateStore

_FIXTURES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "workspace", "tests", "set_effect")
)


def _fixture_paths() -> list[str]:
    if not os.path.isdir(_FIXTURES_DIR):
        return []
    return sorted(glob.glob(os.path.join(_FIXTURES_DIR, "*.yaml")))


def _build_store(fixture: dict, schema_block: dict) -> StateStore:
    store = StateStore()

    active_panel = fixture.get("active_panel")
    if active_panel:
        store.set_active_panel(active_panel)

    # Initialize panel scopes declared in the fixture schema
    for panel_id, panel_fields in (schema_block.get("panels") or {}).items():
        defaults = {
            k: v.get("default")
            for k, v in panel_fields.items()
            if isinstance(v, dict)
        }
        store.init_panel(panel_id, defaults)

    # Load initial_state values; panel keys use "panel.<id>.<field>" format
    for key, value in (fixture.get("initial_state") or {}).items():
        parts = key.split(".")
        if len(parts) == 3 and parts[0] == "panel":
            store.set_panel(parts[1], parts[2], value)
        else:
            store._state[key] = value  # set directly to skip change-guard

    return store


def _assert_state(store: StateStore, expected: dict) -> None:
    for key, expected_value in expected.items():
        parts = key.split(".")
        if len(parts) == 3 and parts[0] == "panel":
            actual = store.get_panel(parts[1], parts[2])
        else:
            actual = store.get(key)
        assert actual == expected_value, (
            f"State[{key!r}]: expected {expected_value!r}, got {actual!r}"
        )


def _run_fixture(fixture: dict) -> None:
    schema_block = fixture.get("schema", {})
    schema = load_schema_from_dict(
        schema_block.get("state", {}),
        schema_block.get("panels"),
    )
    store = _build_store(fixture, schema_block)

    diagnostics: list[dict] = []
    effect = fixture.get("effect", {})
    if "set" in effect:
        apply_set_schemadriven(
            effect["set"],
            store,
            schema,
            diagnostics,
            active_panel=fixture.get("active_panel"),
        )

    _assert_state(store, fixture.get("expected_state", {}))

    expected_diags = fixture.get("expected_diagnostics", [])
    assert len(diagnostics) == len(expected_diags), (
        f"Expected {len(expected_diags)} diagnostic(s), got {len(diagnostics)}: {diagnostics}"
    )
    for i, (exp, act) in enumerate(zip(expected_diags, diagnostics)):
        for field_name, val in exp.items():
            assert act.get(field_name) == val, (
                f"Diagnostic[{i}][{field_name!r}]: expected {val!r}, got {act.get(field_name)!r}"
            )


_paths = _fixture_paths()
_ids = [os.path.splitext(os.path.basename(p))[0] for p in _paths]


@pytest.mark.parametrize("fixture_path", _paths, ids=_ids)
def test_set_effect_fixture(fixture_path: str) -> None:
    with open(fixture_path) as f:
        fixture = yaml.safe_load(f)
    _run_fixture(fixture)
