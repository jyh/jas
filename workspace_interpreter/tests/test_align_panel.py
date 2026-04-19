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


class TestAlignActions:
    """Stage 1c: 17 Align actions added to actions.yaml. Operation
    actions fire same-named platform effects preceded by a snapshot;
    mode actions write through the set_panel_state + set dual-write;
    reset_align_panel resets every panel mirror + state field to
    defaults."""

    OPERATION_ACTIONS = [
        "align_left", "align_horizontal_center", "align_right",
        "align_top", "align_vertical_center", "align_bottom",
        "distribute_left", "distribute_horizontal_center", "distribute_right",
        "distribute_top", "distribute_vertical_center", "distribute_bottom",
        "distribute_vertical_spacing", "distribute_horizontal_spacing",
    ]

    MODE_ACTIONS = [
        "set_align_to", "toggle_use_preview_bounds", "reset_align_panel",
    ]

    @pytest.mark.parametrize("name", OPERATION_ACTIONS + MODE_ACTIONS)
    def test_action_declared(self, workspace_path, name):
        ws = load_workspace(workspace_path)
        assert name in ws["actions"], f"action {name!r} not in actions.yaml"
        assert ws["actions"][name].get("category") == "align"

    @pytest.mark.parametrize("name", OPERATION_ACTIONS)
    def test_operation_action_snapshots_and_fires_platform_effect(
            self, workspace_path, name):
        """Each operation fires: snapshot, then <name>: true."""
        ws = load_workspace(workspace_path)
        effects = ws["actions"][name].get("effects", [])
        assert effects[0] == "snapshot"
        assert effects[1] == {name: True}, (
            f"{name} expected a same-named platform effect; got {effects[1]!r}"
        )

    def test_set_align_to_has_enum_target_param(self, workspace_path):
        ws = load_workspace(workspace_path)
        params = ws["actions"]["set_align_to"].get("params", {})
        target = params.get("target", {})
        assert target.get("type") == "enum"
        assert set(target.get("values", [])) == {"selection", "artboard", "key_object"}

    def test_set_align_to_clears_key_object_when_leaving_key_mode(
            self, workspace_path):
        """When target != key_object, the action also clears
        panel.key_object_path and state.align_key_object_path."""
        ws = load_workspace(workspace_path)
        effects = ws["actions"]["set_align_to"]["effects"]
        # Third effect must be an if clause that clears the key when
        # target is anything other than key_object.
        cond_eff = effects[2]
        assert "if" in cond_eff
        assert cond_eff["if"]["condition"] == 'param.target != "key_object"'
        then_effects = cond_eff["if"]["then"]
        assert {"set_panel_state": {"key": "key_object_path", "value": "null"}} in then_effects
        assert {"set": {"align_key_object_path": "null"}} in then_effects

    def test_toggle_use_preview_bounds_toggles_both_mirrors(
            self, workspace_path):
        ws = load_workspace(workspace_path)
        effects = ws["actions"]["toggle_use_preview_bounds"]["effects"]
        assert {
            "set_panel_state": {
                "key": "use_preview_bounds",
                "value": "not panel.use_preview_bounds",
            }
        } in effects
        assert {
            "set": {
                "align_use_preview_bounds": "not state.align_use_preview_bounds"
            }
        } in effects

    def test_reset_align_panel_resets_all_four_fields(self, workspace_path):
        ws = load_workspace(workspace_path)
        effects = ws["actions"]["reset_align_panel"]["effects"]
        # 4 panel-mirror writes + 4 state writes = 8 effects.
        assert len(effects) == 8
        # Four panel-state resets.
        for key, value in [
            ("align_to", '"selection"'),
            ("key_object_path", "null"),
            ("distribute_spacing_value", "0"),
            ("use_preview_bounds", "false"),
        ]:
            assert {"set_panel_state": {"key": key, "value": value}} in effects
        # Four global-state resets.
        for state_key, value in [
            ("align_to", '"selection"'),
            ("align_key_object_path", "null"),
            ("align_distribute_spacing", "0"),
            ("align_use_preview_bounds", "false"),
        ]:
            assert {"set": {state_key: value}} in effects


class TestAlignBindDisabled:
    """Stage 1d: every operation button carries bind.disabled that
    evaluates selection-count thresholds (>=2 for Align, >=3 for
    Distribute / Distribute Spacing) plus the key-object guard
    (no key designated while align_to == key_object). Align To
    toggles dispatch set_align_to, which preserves the radio
    group semantics via panel.align_to updates."""

    ALIGN_BUTTONS = [
        "align_left_button", "align_horizontal_center_button",
        "align_right_button", "align_top_button",
        "align_vertical_center_button", "align_bottom_button",
    ]

    DISTRIBUTE_BUTTONS = [
        "distribute_left_button", "distribute_horizontal_center_button",
        "distribute_right_button", "distribute_top_button",
        "distribute_vertical_center_button", "distribute_bottom_button",
        "distribute_vertical_spacing_button",
        "distribute_horizontal_spacing_button",
    ]

    ALIGN_TO_BUTTONS = [
        "align_to_artboard_button", "align_to_selection_button",
        "align_to_key_object_button",
    ]

    @pytest.mark.parametrize("button_id", ALIGN_BUTTONS)
    def test_align_button_disabled_below_two_selected_or_unkeyed(
            self, workspace_path, button_id):
        ws = load_workspace(workspace_path)
        spec = ws["panels"]["align_panel_content"]
        widget = _find_by_id(spec["content"], button_id)
        expected = (
            'active_document.selection_count < 2 or '
            '(panel.align_to == "key_object" and panel.key_object_path == null)'
        )
        assert widget["bind"]["disabled"] == expected

    @pytest.mark.parametrize("button_id", DISTRIBUTE_BUTTONS)
    def test_distribute_button_disabled_below_three_selected_or_unkeyed(
            self, workspace_path, button_id):
        ws = load_workspace(workspace_path)
        spec = ws["panels"]["align_panel_content"]
        widget = _find_by_id(spec["content"], button_id)
        expected = (
            'active_document.selection_count < 3 or '
            '(panel.align_to == "key_object" and panel.key_object_path == null)'
        )
        assert widget["bind"]["disabled"] == expected

    def test_distribute_spacing_value_disabled_unless_key_mode_with_key(
            self, workspace_path):
        ws = load_workspace(workspace_path)
        spec = ws["panels"]["align_panel_content"]
        widget = _find_by_id(spec["content"], "distribute_spacing_value")
        expected = (
            'not (panel.align_to == "key_object" and '
            'panel.key_object_path != null)'
        )
        assert widget["bind"]["disabled"] == expected

    @pytest.mark.parametrize("button_id,action_name", [
        ("align_left_button", "align_left"),
        ("align_horizontal_center_button", "align_horizontal_center"),
        ("align_right_button", "align_right"),
        ("align_top_button", "align_top"),
        ("align_vertical_center_button", "align_vertical_center"),
        ("align_bottom_button", "align_bottom"),
        ("distribute_left_button", "distribute_left"),
        ("distribute_horizontal_center_button", "distribute_horizontal_center"),
        ("distribute_right_button", "distribute_right"),
        ("distribute_top_button", "distribute_top"),
        ("distribute_vertical_center_button", "distribute_vertical_center"),
        ("distribute_bottom_button", "distribute_bottom"),
        ("distribute_vertical_spacing_button", "distribute_vertical_spacing"),
        ("distribute_horizontal_spacing_button", "distribute_horizontal_spacing"),
    ])
    def test_operation_button_dispatches_same_named_action(
            self, workspace_path, button_id, action_name):
        ws = load_workspace(workspace_path)
        spec = ws["panels"]["align_panel_content"]
        widget = _find_by_id(spec["content"], button_id)
        click = widget["behavior"][0]
        assert click["event"] == "click"
        assert click["effects"] == [{"dispatch": action_name}]

    @pytest.mark.parametrize("button_id,target", [
        ("align_to_artboard_button", "artboard"),
        ("align_to_selection_button", "selection"),
        ("align_to_key_object_button", "key_object"),
    ])
    def test_align_to_button_dispatches_set_align_to_with_target(
            self, workspace_path, button_id, target):
        ws = load_workspace(workspace_path)
        spec = ws["panels"]["align_panel_content"]
        widget = _find_by_id(spec["content"], button_id)
        click = widget["behavior"][0]
        assert click["event"] == "click"
        assert click["effects"] == [
            {"dispatch": {"action": "set_align_to", "params": {"target": target}}}
        ]

    @pytest.mark.parametrize("button_id", ALIGN_TO_BUTTONS)
    def test_align_to_button_has_no_disabled_predicate(
            self, workspace_path, button_id):
        """Align To toggles are always available. Any disabled
        predicate would undermine the radio group."""
        ws = load_workspace(workspace_path)
        spec = ws["panels"]["align_panel_content"]
        widget = _find_by_id(spec["content"], button_id)
        assert "disabled" not in widget.get("bind", {})
