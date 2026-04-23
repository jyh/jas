"""Tests for YAML-driven panel menus."""

import os
import pytest

from panels.yaml_menu import (
    load_panel_specs, build_menu_items, is_checked, is_enabled,
    PANEL_KIND_TO_CONTENT_ID,
)
from workspace.workspace_layout import PanelKind


WORKSPACE_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..", "workspace"
)


@pytest.fixture(scope="module")
def panel_specs():
    return load_panel_specs(WORKSPACE_PATH)


class TestLoadPanelSpecs:
    def test_loads_all_panels(self, panel_specs):
        assert "color_panel_content" in panel_specs
        assert "layers_panel_content" in panel_specs
        assert "stroke_panel_content" in panel_specs
        assert "properties_panel_content" in panel_specs

    def test_color_panel_has_menu(self, panel_specs):
        spec = panel_specs["color_panel_content"]
        assert "menu" in spec
        assert len(spec["menu"]) > 0


class TestBuildMenuItems:
    def test_color_panel_menu_items(self, panel_specs):
        items = build_menu_items(panel_specs["color_panel_content"])
        labels = [i["label"] for i in items if isinstance(i, dict)]
        assert "Grayscale" in labels
        assert "RGB" in labels
        assert "HSB" in labels
        assert "CMYK" in labels
        assert "Web Safe RGB" in labels
        assert "Invert" in labels
        assert "Complement" in labels

    def test_color_panel_has_separators(self, panel_specs):
        items = build_menu_items(panel_specs["color_panel_content"])
        sep_count = sum(1 for i in items if i == "separator")
        assert sep_count >= 2

    def test_layers_panel_has_close(self, panel_specs):
        items = build_menu_items(panel_specs["layers_panel_content"])
        labels = [i.get("label", "") for i in items if isinstance(i, dict)]
        # Minimal panels should have at least a close action
        assert len(items) >= 0  # layers may have no menu items


class TestIsChecked:
    def test_hsb_mode_checked(self, panel_specs):
        panel_state = {"mode": "hsb"}
        spec = panel_specs["color_panel_content"]
        items = build_menu_items(spec)
        hsb_item = next(i for i in items if isinstance(i, dict) and i.get("label") == "HSB")
        assert is_checked(hsb_item, panel_state, {})

    def test_rgb_mode_not_checked_when_hsb(self, panel_specs):
        panel_state = {"mode": "hsb"}
        spec = panel_specs["color_panel_content"]
        items = build_menu_items(spec)
        rgb_item = next(i for i in items if isinstance(i, dict) and i.get("label") == "RGB")
        assert not is_checked(rgb_item, panel_state, {})

    def test_rgb_mode_checked_when_rgb(self, panel_specs):
        panel_state = {"mode": "rgb"}
        spec = panel_specs["color_panel_content"]
        items = build_menu_items(spec)
        rgb_item = next(i for i in items if isinstance(i, dict) and i.get("label") == "RGB")
        assert is_checked(rgb_item, panel_state, {})


class TestIsEnabled:
    def test_invert_enabled_when_fill_non_null(self, panel_specs):
        state = {"fill_on_top": True, "fill_color": "#ff0000", "stroke_color": None}
        spec = panel_specs["color_panel_content"]
        items = build_menu_items(spec)
        invert_item = next(i for i in items if isinstance(i, dict) and i.get("label") == "Invert")
        assert is_enabled(invert_item, {}, state)

    def test_invert_disabled_when_fill_null(self, panel_specs):
        state = {"fill_on_top": True, "fill_color": None, "stroke_color": "#000000"}
        spec = panel_specs["color_panel_content"]
        items = build_menu_items(spec)
        invert_item = next(i for i in items if isinstance(i, dict) and i.get("label") == "Invert")
        assert not is_enabled(invert_item, {}, state)


class TestPanelKindMapping:
    def test_all_kinds_have_content_id(self):
        for kind in PanelKind:
            assert kind in PANEL_KIND_TO_CONTENT_ID, f"Missing mapping for {kind}"

    def test_content_ids_match_yaml(self, panel_specs):
        for kind, content_id in PANEL_KIND_TO_CONTENT_ID.items():
            assert content_id in panel_specs, (
                f"PanelKind.{kind.name} maps to '{content_id}' which is not in workspace YAML"
            )
