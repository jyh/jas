"""Tests for the Align panel workspace spec.

Tests land alongside each Align panel Phase 1 stage:
- Stage 1a: state.yaml has the 4 align_* global state keys.
- Stage 1b will add panel-spec loading + default-state tests.
- Stage 1c will add action-dispatch tests.
- Stage 1d will add bind.disabled predicate tests.
- Stage 1e will add panel-menu tests.
"""

from __future__ import annotations

import pytest

from workspace_interpreter.loader import load_workspace, state_defaults


class TestAlignStateKeys:
    """Stage 1a: state.yaml declares 4 align_* global state keys that
    back the Align panel's mirror state (per ALIGN.md Panel state).
    Values are the fields a panel writes through to update document-
    authoritative state."""

    def test_align_to_default_is_selection(self, workspace_path):
        ws = load_workspace(workspace_path)
        defaults = state_defaults(ws["state"])
        assert defaults["align_to"] == "selection"

    def test_align_key_object_path_default_is_null(self, workspace_path):
        ws = load_workspace(workspace_path)
        defaults = state_defaults(ws["state"])
        assert defaults["align_key_object_path"] is None

    def test_align_distribute_spacing_default_is_zero(self, workspace_path):
        ws = load_workspace(workspace_path)
        defaults = state_defaults(ws["state"])
        assert defaults["align_distribute_spacing"] == 0

    def test_align_use_preview_bounds_default_is_false(self, workspace_path):
        ws = load_workspace(workspace_path)
        defaults = state_defaults(ws["state"])
        assert defaults["align_use_preview_bounds"] is False

    def test_align_to_enum_values_cover_all_three_modes(self, workspace_path):
        """align_to must permit exactly {selection, artboard, key_object}."""
        ws = load_workspace(workspace_path)
        spec = ws["state"]["align_to"]
        assert spec["type"] == "enum"
        assert set(spec["values"]) == {"selection", "artboard", "key_object"}

    def test_align_key_object_path_is_nullable_path(self, workspace_path):
        ws = load_workspace(workspace_path)
        spec = ws["state"]["align_key_object_path"]
        assert spec["type"] == "path"
        assert spec.get("nullable") is True
