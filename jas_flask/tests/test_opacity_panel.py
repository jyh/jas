"""Tests against the real workspace Opacity panel spec.

Flask's phase-1 scope for Opacity is yaml wiring only — the document
model for per-element opacity, per-element blend mode, and opacity
masks lands in later phases in the native apps (same posture as
Artboards / Boolean / Align). Phase-1 behavior:

  - MODE_DROPDOWN and OPACITY_INPUT are functional (bind to panel-local
    state).
  - OPACITY_PREVIEW, LINK_INDICATOR, MASK_PREVIEW render as placeholder
    boxes.
  - MAKE_MASK_BUTTON, CLIP_CHECKBOX, INVERT_MASK_CHECKBOX are present
    but disabled (bind.disabled = "true").
  - Mask-lifecycle and page-level menu items use `enabled_when: "false"`
    until the document model / renderer supports them.

Spec source: workspace/panels/opacity.yaml.
Design doc: transcripts/OPACITY.md.
"""

import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

WORKSPACE_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "workspace")

EXPECTED_MODES = [
    "normal",
    "darken", "multiply", "color_burn",
    "lighten", "screen", "color_dodge",
    "overlay", "soft_light", "hard_light",
    "difference", "exclusion",
    "hue", "saturation", "color", "luminosity",
]


@pytest.fixture
def theme():
    return {
        "colors": {
            "bg": "#000",
            "text": "#ccc",
            "border": "#555",
            "selection": "#3b72c6",
            "pane_bg_dark": "#222",
            "text_dim": "#666",
            "button_checked": "#505050",
        },
        "fonts": {"default": {"family": "sans-serif", "size": 12}},
        "sizes": {"tool_button": 32, "title_bar_height": 20},
    }


@pytest.fixture
def state():
    return {"active_tool": "pen"}


class TestOpacityPanel:
    @pytest.fixture(autouse=True)
    def load_ws(self):
        from loader import load_workspace
        from renderer import set_icons, set_panels, set_initial_state
        ws = load_workspace(WORKSPACE_PATH)
        set_icons(ws.get("icons", {}))
        set_panels(ws.get("panels", {}))
        set_initial_state(ws.get("state", {}))

    @pytest.fixture
    def panel(self):
        from loader import load_workspace
        ws = load_workspace(WORKSPACE_PATH)
        return ws.get("panels", {}).get("opacity_panel_content", {})

    @pytest.fixture
    def panel_html(self, panel, theme, state):
        from renderer import render_element
        return render_element(panel, theme, state, mode="normal")

    # ── Panel spec loads ───────────────────────────────────────

    def test_panel_spec_present(self, panel):
        assert panel, "opacity_panel_content spec missing from workspace"
        assert panel.get("summary") == "Opacity"

    def test_panel_renders(self, panel_html):
        assert panel_html

    # ── State block ────────────────────────────────────────────

    def test_state_blend_mode_enum_default_normal_sixteen_values(self, panel):
        entry = panel.get("state", {}).get("blend_mode")
        assert entry is not None
        assert entry.get("type") == "enum"
        assert entry.get("default") == "normal"
        assert len(entry.get("values", [])) == 16

    def test_state_blend_mode_includes_all_expected_values(self, panel):
        values = panel.get("state", {}).get("blend_mode", {}).get("values", [])
        for m in EXPECTED_MODES:
            assert m in values, f"Mode '{m}' missing from state.blend_mode.values"

    def test_state_opacity_number_default_100(self, panel):
        entry = panel.get("state", {}).get("opacity")
        assert entry is not None
        assert entry.get("type") == "number"
        assert entry.get("default") == 100

    def test_state_thumbnails_hidden_bool_default_false(self, panel):
        entry = panel.get("state", {}).get("thumbnails_hidden")
        assert entry is not None
        assert entry.get("type") == "bool"
        assert entry.get("default") is False

    def test_state_options_shown_bool_default_false(self, panel):
        entry = panel.get("state", {}).get("options_shown")
        assert entry is not None
        assert entry.get("type") == "bool"
        assert entry.get("default") is False

    def test_state_new_masks_clipping_per_document_default_true(self, panel):
        entry = panel.get("state", {}).get("new_masks_clipping")
        assert entry is not None
        assert entry.get("type") == "bool"
        assert entry.get("default") is True
        assert entry.get("per_document") is True

    def test_state_new_masks_inverted_per_document_default_false(self, panel):
        entry = panel.get("state", {}).get("new_masks_inverted")
        assert entry is not None
        assert entry.get("type") == "bool"
        assert entry.get("default") is False
        assert entry.get("per_document") is True

    # ── Menu entries ───────────────────────────────────────────

    def test_menu_contains_all_entries(self, panel):
        labels = [m.get("label") for m in panel.get("menu", []) if isinstance(m, dict)]
        expected = [
            "Hide Thumbnails", "Show Options",
            "Make Opacity Mask", "Release Opacity Mask",
            "Disable Opacity Mask", "Unlink Opacity Mask",
            "New Opacity Masks Are Clipping", "New Opacity Masks Are Inverted",
            "Page Isolated Blending", "Page Knockout Group",
        ]
        for label in expected:
            assert label in labels, f"Menu entry '{label}' missing"

    def test_menu_has_three_separators(self, panel):
        menu = panel.get("menu", [])
        sep_count = sum(1 for m in menu if m == "separator")
        assert sep_count == 3

    def test_menu_make_mask_phase1_deferred(self, panel):
        entry = self._menu_by_label(panel, "Make Opacity Mask")
        assert entry.get("enabled_when") == "false"

    def test_menu_release_mask_phase1_deferred(self, panel):
        entry = self._menu_by_label(panel, "Release Opacity Mask")
        assert entry.get("enabled_when") == "false"

    def test_menu_disable_mask_pending_model(self, panel):
        entry = self._menu_by_label(panel, "Disable Opacity Mask")
        assert entry.get("enabled_when") == "false"

    def test_menu_unlink_mask_pending_model(self, panel):
        entry = self._menu_by_label(panel, "Unlink Opacity Mask")
        assert entry.get("enabled_when") == "false"

    def test_menu_page_isolated_blending_pending_renderer(self, panel):
        entry = self._menu_by_label(panel, "Page Isolated Blending")
        assert entry.get("enabled_when") == "false"

    def test_menu_page_knockout_group_pending_renderer(self, panel):
        entry = self._menu_by_label(panel, "Page Knockout Group")
        assert entry.get("enabled_when") == "false"

    def test_menu_hide_thumbnails_checkmark_bound(self, panel):
        entry = self._menu_by_label(panel, "Hide Thumbnails")
        assert "thumbnails_hidden" in entry.get("checked_when", "")

    def test_menu_show_options_checkmark_bound(self, panel):
        entry = self._menu_by_label(panel, "Show Options")
        assert "options_shown" in entry.get("checked_when", "")

    def test_menu_new_masks_clipping_checkmark_bound(self, panel):
        entry = self._menu_by_label(panel, "New Opacity Masks Are Clipping")
        assert "new_masks_clipping" in entry.get("checked_when", "")

    def test_menu_new_masks_inverted_checkmark_bound(self, panel):
        entry = self._menu_by_label(panel, "New Opacity Masks Are Inverted")
        assert "new_masks_inverted" in entry.get("checked_when", "")

    # ── Content row 1: Mode + Opacity controls ─────────────────

    def test_content_has_controls_row(self, panel):
        assert self._find_by_id(panel, "op_controls_row") is not None

    def test_controls_row_has_mode_input_disclosure(self, panel):
        row = self._find_by_id(panel, "op_controls_row")
        ids = [ch.get("id") for ch in row.get("children", []) if isinstance(ch, dict)]
        assert "op_mode" in ids
        assert "op_opacity" in ids
        assert "op_disclosure" in ids

    def test_mode_dropdown_binds_panel_blend_mode(self, panel):
        mode_el = self._find_by_id(panel, "op_mode")
        assert mode_el.get("bind", {}).get("value") == "panel.blend_mode"

    def test_opacity_input_binds_panel_opacity(self, panel):
        op_el = self._find_by_id(panel, "op_opacity")
        assert op_el.get("bind", {}).get("value") == "panel.opacity"

    def test_opacity_input_range_0_to_100(self, panel):
        op_el = self._find_by_id(panel, "op_opacity")
        assert op_el.get("min") == 0
        assert op_el.get("max") == 100

    def test_mode_dropdown_options_include_all_modes(self, panel):
        mode_el = self._find_by_id(panel, "op_mode")
        values = [o.get("value") for o in mode_el.get("options", []) if isinstance(o, dict)]
        for m in EXPECTED_MODES:
            assert m in values, f"Mode '{m}' missing from op_mode options"

    def test_mode_dropdown_has_five_separators_between_groups(self, panel):
        """Six mode groups divided by five separators."""
        mode_el = self._find_by_id(panel, "op_mode")
        options = mode_el.get("options", [])
        sep_count = sum(1 for o in options if o == "separator")
        assert sep_count == 5

    # ── Content row 2: Preview cells + Mask buttons ────────────

    def test_content_has_preview_row(self, panel):
        assert self._find_by_id(panel, "op_preview_row") is not None

    def test_opacity_preview_is_placeholder(self, panel):
        el = self._find_by_id(panel, "op_preview")
        assert el is not None
        assert el.get("type") == "placeholder"

    def test_link_indicator_is_placeholder(self, panel):
        el = self._find_by_id(panel, "op_link_indicator")
        assert el is not None
        assert el.get("type") == "placeholder"

    def test_mask_preview_is_placeholder(self, panel):
        el = self._find_by_id(panel, "op_mask_preview")
        assert el is not None
        assert el.get("type") == "placeholder"

    def test_preview_row_hidden_when_thumbnails_hidden(self, panel):
        row = self._find_by_id(panel, "op_preview_row")
        vis = row.get("bind", {}).get("visible", "")
        assert "thumbnails_hidden" in vis

    # ── Mask controls: Phase-1 disabled ────────────────────────

    def test_make_mask_button_phase1_disabled(self, panel):
        btn = self._find_by_id(panel, "op_make_mask")
        assert btn is not None
        assert btn.get("bind", {}).get("disabled") == "true"

    def test_clip_checkbox_phase1_disabled(self, panel):
        cb = self._find_by_id(panel, "op_clip")
        assert cb is not None
        assert cb.get("type") == "checkbox"
        assert cb.get("bind", {}).get("disabled") == "true"

    def test_invert_mask_checkbox_phase1_disabled(self, panel):
        cb = self._find_by_id(panel, "op_invert_mask")
        assert cb is not None
        assert cb.get("type") == "checkbox"
        assert cb.get("bind", {}).get("disabled") == "true"

    # ── Appearance theming ────────────────────────────────────

    def test_panel_does_not_hardcode_colors(self, panel):
        import json as _json
        import re
        yaml_dump = _json.dumps(panel)
        offenders = re.findall(r"#[0-9a-fA-F]{6}", yaml_dump)
        assert offenders == [], (
            "Panel yaml contains hardcoded hex colors: " + ", ".join(offenders)
        )

    # ── Helpers ───────────────────────────────────────────────

    def _menu_by_label(self, panel, label):
        for m in panel.get("menu", []):
            if isinstance(m, dict) and m.get("label") == label:
                return m
        raise AssertionError(f"Menu entry '{label}' not found")

    def _find_by_id(self, panel, target_id):
        def walk(node):
            if isinstance(node, dict):
                if node.get("id") == target_id:
                    return node
                for key in ("children", "do"):
                    child = node.get(key)
                    if isinstance(child, list):
                        for c in child:
                            found = walk(c)
                            if found is not None:
                                return found
                    elif isinstance(child, dict):
                        found = walk(child)
                        if found is not None:
                            return found
            return None
        return walk(panel.get("content", {}))
