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


class TestAlignPanelSpec:
    """Stage 1b: panels/align.yaml loads with state, init, and
    content sections populated per ALIGN.md."""

    def test_panel_loads_under_expected_id(self, workspace_path):
        ws = load_workspace(workspace_path)
        assert "align_panel_content" in ws.get("panels", {})

    def test_panel_state_defaults_match_state_yaml(self, workspace_path):
        """Panel-local defaults mirror the four state.align_* keys."""
        from workspace_interpreter.loader import panel_state_defaults
        ws = load_workspace(workspace_path)
        spec = ws["panels"]["align_panel_content"]
        defaults = panel_state_defaults(spec)
        assert defaults["align_to"] == "selection"
        assert defaults["key_object_path"] is None
        assert defaults["distribute_spacing_value"] == 0
        assert defaults["use_preview_bounds"] is False

    def test_panel_init_mirrors_state_keys(self, workspace_path):
        """Init expressions re-seed panel mirrors from state.align_*
        on each panel open."""
        ws = load_workspace(workspace_path)
        init = ws["panels"]["align_panel_content"].get("init", {})
        assert init["align_to"] == "state.align_to"
        assert init["key_object_path"] == "state.align_key_object_path"
        assert init["distribute_spacing_value"] == "state.align_distribute_spacing"
        assert init["use_preview_bounds"] == "state.align_use_preview_bounds"

    @pytest.mark.parametrize("widget_id", [
        # 6 align buttons
        "align_left_button",
        "align_horizontal_center_button",
        "align_right_button",
        "align_top_button",
        "align_vertical_center_button",
        "align_bottom_button",
        # 6 distribute buttons
        "distribute_left_button",
        "distribute_horizontal_center_button",
        "distribute_right_button",
        "distribute_top_button",
        "distribute_vertical_center_button",
        "distribute_bottom_button",
        # 2 spacing buttons + 1 numeric input
        "distribute_vertical_spacing_button",
        "distribute_horizontal_spacing_button",
        "distribute_spacing_value",
        # 3 align-to radio buttons
        "align_to_artboard_button",
        "align_to_selection_button",
        "align_to_key_object_button",
    ])
    def test_panel_contains_widget_id(self, workspace_path, widget_id):
        """Every widget ID named in ALIGN.md appears in the content
        tree exactly once."""
        ws = load_workspace(workspace_path)
        spec = ws["panels"]["align_panel_content"]
        found = list(_collect_ids(spec.get("content", {})))
        assert found.count(widget_id) == 1, (
            f"{widget_id!r} appeared {found.count(widget_id)} times; "
            f"ids in spec: {sorted(set(found))}"
        )

    def test_align_to_buttons_have_radio_binding(self, workspace_path):
        """The three Align To buttons bind.checked to
        panel.align_to == '<target>', forming a mutually-exclusive
        radio group."""
        ws = load_workspace(workspace_path)
        spec = ws["panels"]["align_panel_content"]
        content = spec.get("content", {})
        for token in ("artboard", "selection", "key_object"):
            widget = _find_by_id(content, f"align_to_{token}_button")
            assert widget is not None, f"button align_to_{token}_button missing"
            assert widget.get("bind", {}).get("checked") == f'panel.align_to == "{token}"'


def _collect_ids(node, out=None):
    """Yield every ``id`` string nested inside a widget tree."""
    if out is None:
        out = []
    if isinstance(node, dict):
        if "id" in node and isinstance(node["id"], str):
            out.append(node["id"])
        for v in node.values():
            _collect_ids(v, out)
    elif isinstance(node, list):
        for item in node:
            _collect_ids(item, out)
    return out


def _find_by_id(node, target_id):
    """Return the first dict whose id matches, else None."""
    if isinstance(node, dict):
        if node.get("id") == target_id:
            return node
        for v in node.values():
            result = _find_by_id(v, target_id)
            if result is not None:
                return result
    elif isinstance(node, list):
        for item in node:
            result = _find_by_id(item, target_id)
            if result is not None:
                return result
    return None
