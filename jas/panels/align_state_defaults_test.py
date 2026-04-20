"""Tests that the four Align panel state keys load with their
expected defaults from workspace/workspace.json. jas uses
workspace_interpreter's StateStore directly; no typed struct."""

import os

from workspace_interpreter.loader import load_workspace, state_defaults, panel_state_defaults


def _workspace_path() -> str:
    return os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__)))), "workspace")


def test_align_state_keys_load_with_expected_defaults():
    ws = load_workspace(_workspace_path())
    defaults = state_defaults(ws["state"])
    assert defaults["align_to"] == "selection"
    assert defaults["align_key_object_path"] is None
    assert defaults["align_distribute_spacing"] == 0
    assert defaults["align_use_preview_bounds"] is False


def test_align_panel_state_defaults_match_spec():
    ws = load_workspace(_workspace_path())
    spec = ws["panels"]["align_panel_content"]
    defaults = panel_state_defaults(spec)
    assert defaults["align_to"] == "selection"
    assert defaults["key_object_path"] is None
    assert defaults["distribute_spacing_value"] == 0
    assert defaults["use_preview_bounds"] is False
