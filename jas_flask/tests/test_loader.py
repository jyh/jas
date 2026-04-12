"""Tests for loader.py — YAML loading, validation, interpolation, element lookup."""

import os
import sys
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


class TestLoadWorkspace:
    def test_load_real_workspace(self, workspace_path):
        from loader import load_workspace
        data = load_workspace(workspace_path)
        assert data["version"] == 1
        assert "app" in data
        assert "theme" in data
        assert "state" in data
        assert "actions" in data
        assert "shortcuts" in data
        assert "menubar" in data
        assert "layout" in data

    def test_load_has_all_required_keys(self, workspace_path):
        from loader import load_workspace
        data = load_workspace(workspace_path)
        required = {"version", "app", "theme", "state", "actions", "shortcuts", "menubar", "layout"}
        assert required.issubset(set(data.keys()))

    def test_load_missing_keys_raises(self, tmp_path):
        from loader import load_workspace
        bad_file = tmp_path / "bad.yaml"
        bad_file.write_text("version: 1\napp:\n  name: test\n")
        with pytest.raises(ValueError, match="Missing"):
            load_workspace(str(bad_file))

    def test_load_nonexistent_file_raises(self):
        from loader import load_workspace
        with pytest.raises(FileNotFoundError):
            load_workspace("/nonexistent/path.yaml")


class TestResolveInterpolation:
    def test_theme_color(self):
        from loader import resolve_interpolation
        theme = {"colors": {"bg": "#000"}}
        result = resolve_interpolation("{{theme.colors.bg}}", theme, {})
        assert result == "#000"

    def test_theme_size(self):
        from loader import resolve_interpolation
        theme = {"sizes": {"button": 32}}
        result = resolve_interpolation("{{theme.sizes.button}}", theme, {})
        assert result == "32"

    def test_state_ref(self):
        from loader import resolve_interpolation
        state = {"active_tool": "pen"}
        result = resolve_interpolation("{{state.active_tool}}", {"colors": {}, "sizes": {}}, state)
        assert result == "pen"

    def test_param_ref(self):
        from loader import resolve_interpolation
        result = resolve_interpolation("{{param.filename}}", {"colors": {}, "sizes": {}}, {}, {"filename": "test.svg"})
        assert result == "test.svg"

    def test_no_interpolation(self):
        from loader import resolve_interpolation
        result = resolve_interpolation("plain text", {}, {})
        assert result == "plain text"

    def test_mixed_text_and_interpolation(self):
        from loader import resolve_interpolation
        theme = {"colors": {"bg": "#000"}}
        result = resolve_interpolation("color: {{theme.colors.bg}};", theme, {})
        assert result == "color: #000;"

    def test_missing_ref_returns_empty(self):
        from loader import resolve_interpolation
        result = resolve_interpolation("{{theme.colors.nonexistent}}", {"colors": {}}, {})
        assert "nonexistent" not in result or result == ""


class TestFindElementById:
    def test_find_root(self, sample_workspace):
        from loader import find_element_by_id
        result = find_element_by_id(sample_workspace["layout"], "root")
        assert result is not None
        assert result["id"] == "root"

    def test_find_nested_child(self, sample_workspace):
        from loader import find_element_by_id
        result = find_element_by_id(sample_workspace["layout"], "btn_1")
        assert result is not None
        assert result["id"] == "btn_1"
        assert result["type"] == "icon_button"

    def test_find_in_content(self, sample_workspace):
        from loader import find_element_by_id
        result = find_element_by_id(sample_workspace["layout"], "grid_a")
        assert result is not None
        assert result["type"] == "grid"

    def test_find_placeholder(self, sample_workspace):
        from loader import find_element_by_id
        result = find_element_by_id(sample_workspace["layout"], "placeholder_b")
        assert result is not None
        assert result["type"] == "placeholder"

    def test_not_found_returns_none(self, sample_workspace):
        from loader import find_element_by_id
        result = find_element_by_id(sample_workspace["layout"], "nonexistent")
        assert result is None


class TestLoadSubdirectories:
    def test_load_includes_dialogs(self, workspace_path):
        from loader import load_workspace
        data = load_workspace(workspace_path)
        assert "dialogs" in data
        assert "color_picker" in data["dialogs"]
        assert "save_changes_tab" in data["dialogs"]
        assert "save_changes_window" in data["dialogs"]
        assert "workspace_save_as" in data["dialogs"]

    def test_load_includes_panels(self, workspace_path):
        from loader import load_workspace
        data = load_workspace(workspace_path)
        assert "panels" in data
        # Panel files are keyed by their id field
        assert "layers_panel_content" in data["panels"]
        assert "color_panel_content" in data["panels"]
        assert "stroke_panel_content" in data["panels"]
        assert "properties_panel_content" in data["panels"]

    def test_load_includes_default_layouts(self, workspace_path):
        from loader import load_workspace
        data = load_workspace(workspace_path)
        assert "default_layouts" in data
        assert "Default" in data["default_layouts"]

    def test_load_includes_runtime_contexts(self, workspace_path):
        from loader import load_workspace
        data = load_workspace(workspace_path)
        assert "runtime_contexts" in data
        assert "active_document" in data["runtime_contexts"]
        assert "workspace" in data["runtime_contexts"]


class TestResolveIncludes:
    def test_include_replaces_node(self, workspace_path):
        from loader import load_workspace
        data = load_workspace(workspace_path)
        layout = data["layout"]
        # After include resolution, there should be no 'include' keys
        # remaining in the layout tree
        def _has_include(node):
            if not isinstance(node, dict):
                return False
            if "include" in node:
                return True
            for child in node.get("children", []):
                if _has_include(child):
                    return True
            content = node.get("content")
            if isinstance(content, dict) and _has_include(content):
                return True
            return False
        assert not _has_include(layout), "Layout tree still contains unresolved include directives"

    def test_include_preserves_bind(self, workspace_path):
        from loader import load_workspace, find_element_by_id
        data = load_workspace(workspace_path)
        # The dock_view element should be present with groups
        dock_main = find_element_by_id(data["layout"], "dock_main")
        assert dock_main is not None
        assert dock_main.get("type") == "dock_view"
        assert "groups" in dock_main
        assert len(dock_main["groups"]) == 2


class TestResolveAppearance:
    def test_returns_base_when_no_override(self):
        from loader import resolve_appearance
        theme_config = {
            "active": "dark_gray",
            "base": {
                "colors": {"window_bg": "#2e2e2e", "text": "#cccccc"},
                "fonts": {"default": {"family": "sans-serif", "size": 12}},
                "sizes": {"tool_button": 32},
            },
            "appearances": {
                "dark_gray": {"label": "Dark Gray"},
            },
        }
        result = resolve_appearance(theme_config, "dark_gray")
        assert result["colors"]["window_bg"] == "#2e2e2e"
        assert result["colors"]["text"] == "#cccccc"
        assert result["fonts"]["default"]["family"] == "sans-serif"
        assert result["sizes"]["tool_button"] == 32

    def test_overrides_merge_on_top_of_base(self):
        from loader import resolve_appearance
        theme_config = {
            "active": "dark_gray",
            "base": {
                "colors": {"window_bg": "#2e2e2e", "text": "#cccccc"},
                "fonts": {"default": {"family": "sans-serif", "size": 12}},
                "sizes": {"tool_button": 32},
            },
            "appearances": {
                "dark_gray": {"label": "Dark Gray"},
                "light_gray": {
                    "label": "Light Gray",
                    "colors": {"window_bg": "#d0d0d0", "text": "#333333"},
                },
            },
        }
        result = resolve_appearance(theme_config, "light_gray")
        assert result["colors"]["window_bg"] == "#d0d0d0"
        assert result["colors"]["text"] == "#333333"
        # fonts and sizes unchanged from base
        assert result["fonts"]["default"]["size"] == 12
        assert result["sizes"]["tool_button"] == 32

    def test_partial_color_override_preserves_other_colors(self):
        from loader import resolve_appearance
        theme_config = {
            "active": "dark_gray",
            "base": {
                "colors": {"window_bg": "#2e2e2e", "text": "#cccccc", "accent": "#4a90d9"},
                "fonts": {"default": {"family": "sans-serif", "size": 12}},
                "sizes": {},
            },
            "appearances": {
                "custom": {
                    "label": "Custom",
                    "colors": {"window_bg": "#ffffff"},
                },
            },
        }
        result = resolve_appearance(theme_config, "custom")
        assert result["colors"]["window_bg"] == "#ffffff"
        assert result["colors"]["text"] == "#cccccc"
        assert result["colors"]["accent"] == "#4a90d9"

    def test_font_override(self):
        from loader import resolve_appearance
        theme_config = {
            "active": "dark_gray",
            "base": {
                "colors": {},
                "fonts": {"default": {"family": "sans-serif", "size": 12}},
                "sizes": {},
            },
            "appearances": {
                "big_font": {
                    "label": "Big Font",
                    "fonts": {"default": {"size": 16}},
                },
            },
        }
        result = resolve_appearance(theme_config, "big_font")
        assert result["fonts"]["default"]["size"] == 16
        assert result["fonts"]["default"]["family"] == "sans-serif"

    def test_uses_active_when_name_is_none(self):
        from loader import resolve_appearance
        theme_config = {
            "active": "medium_gray",
            "base": {
                "colors": {"window_bg": "#2e2e2e"},
                "fonts": {},
                "sizes": {},
            },
            "appearances": {
                "medium_gray": {
                    "label": "Medium Gray",
                    "colors": {"window_bg": "#505050"},
                },
            },
        }
        result = resolve_appearance(theme_config)
        assert result["colors"]["window_bg"] == "#505050"

    def test_unknown_appearance_raises(self):
        from loader import resolve_appearance
        theme_config = {
            "active": "dark_gray",
            "base": {"colors": {}, "fonts": {}, "sizes": {}},
            "appearances": {"dark_gray": {"label": "Dark Gray"}},
        }
        with pytest.raises(ValueError, match="Unknown appearance"):
            resolve_appearance(theme_config, "nonexistent")

    def test_does_not_mutate_base(self):
        from loader import resolve_appearance
        base_colors = {"window_bg": "#2e2e2e", "text": "#cccccc"}
        theme_config = {
            "active": "dark_gray",
            "base": {"colors": base_colors.copy(), "fonts": {}, "sizes": {}},
            "appearances": {
                "light": {
                    "label": "Light",
                    "colors": {"window_bg": "#ffffff"},
                },
            },
        }
        resolve_appearance(theme_config, "light")
        assert theme_config["base"]["colors"]["window_bg"] == "#2e2e2e"

    def test_result_has_no_metadata_keys(self):
        from loader import resolve_appearance
        theme_config = {
            "active": "dark_gray",
            "base": {"colors": {"bg": "#000"}, "fonts": {}, "sizes": {}},
            "appearances": {"dark_gray": {"label": "Dark Gray"}},
        }
        result = resolve_appearance(theme_config, "dark_gray")
        assert "active" not in result
        assert "base" not in result
        assert "appearances" not in result
        assert "label" not in result

    def test_real_workspace_theme(self, workspace_path):
        from loader import load_workspace, resolve_appearance
        data = load_workspace(workspace_path)
        theme_config = data["theme"]
        # Should have the new structure
        assert "base" in theme_config
        assert "appearances" in theme_config
        assert "active" in theme_config
        # Resolve each appearance
        for name in theme_config["appearances"]:
            result = resolve_appearance(theme_config, name)
            assert "colors" in result
            assert "fonts" in result
            assert "sizes" in result


class TestListAppearances:
    def test_returns_names_and_labels(self):
        from loader import list_appearances
        theme_config = {
            "active": "dark_gray",
            "base": {"colors": {}, "fonts": {}, "sizes": {}},
            "appearances": {
                "dark_gray": {"label": "Dark Gray"},
                "light_gray": {"label": "Light Gray"},
            },
        }
        result = list_appearances(theme_config)
        assert result == [
            {"name": "dark_gray", "label": "Dark Gray"},
            {"name": "light_gray", "label": "Light Gray"},
        ]

    def test_preserves_yaml_order(self):
        from loader import list_appearances
        theme_config = {
            "active": "a",
            "base": {"colors": {}, "fonts": {}, "sizes": {}},
            "appearances": {
                "c_theme": {"label": "C"},
                "a_theme": {"label": "A"},
                "b_theme": {"label": "B"},
            },
        }
        names = [a["name"] for a in list_appearances(theme_config)]
        assert names == ["c_theme", "a_theme", "b_theme"]


class TestAppearanceLoading:
    def test_appearances_loaded_from_directory(self, workspace_path):
        from loader import load_workspace
        data = load_workspace(workspace_path)
        theme = data["theme"]
        assert "appearances" in theme
        assert "dark_gray" in theme["appearances"]
        assert "medium_gray" in theme["appearances"]
        assert "light_gray" in theme["appearances"]

    def test_appearance_has_label(self, workspace_path):
        from loader import load_workspace
        data = load_workspace(workspace_path)
        for name, app in data["theme"]["appearances"].items():
            assert "label" in app, f"Appearance {name} missing label"

    def test_metrics_separate_from_sizes(self, workspace_path):
        from loader import load_workspace, resolve_appearance
        data = load_workspace(workspace_path)
        theme = data["theme"]
        assert "metrics" in theme
        assert "snap_distance" in theme["metrics"]
        assert "long_press_ms" in theme["metrics"]
        # Resolved appearance should NOT contain metric keys
        resolved = resolve_appearance(theme)
        for metric_key in theme["metrics"]:
            assert metric_key not in resolved.get("sizes", {})

    def test_pane_shadow_in_resolved_colors(self, workspace_path):
        from loader import load_workspace, resolve_appearance
        data = load_workspace(workspace_path)
        resolved = resolve_appearance(data["theme"])
        assert "pane_shadow" in resolved["colors"]

    def test_resolved_shape_matches_old_format(self, workspace_path):
        """Resolved appearance has same top-level keys as old flat theme."""
        from loader import load_workspace, resolve_appearance
        data = load_workspace(workspace_path)
        resolved = resolve_appearance(data["theme"])
        assert set(resolved.keys()) == {"colors", "fonts", "sizes"}


class TestValidateActionRefs:
    def test_all_shortcut_actions_exist(self, workspace_path):
        from loader import load_workspace
        data = load_workspace(workspace_path)
        actions = data["actions"]
        for shortcut in data["shortcuts"]:
            assert shortcut["action"] in actions, f"Shortcut action '{shortcut['action']}' not in actions"

    def test_all_menu_actions_exist(self, workspace_path):
        from loader import load_workspace
        data = load_workspace(workspace_path)
        actions = data["actions"]

        def check_items(items):
            for item in items:
                if isinstance(item, str):
                    continue
                if "action" in item:
                    assert item["action"] in actions, f"Menu action '{item['action']}' not in actions"
                if "items" in item:
                    check_items(item["items"])

        for menu in data["menubar"]:
            check_items(menu["items"])

    def test_all_element_ids_unique(self, workspace_path):
        from loader import load_workspace, collect_element_ids
        data = load_workspace(workspace_path)
        ids = collect_element_ids(data["layout"])
        seen = set()
        for eid in ids:
            assert eid not in seen, f"Duplicate element id: '{eid}'"
            seen.add(eid)
