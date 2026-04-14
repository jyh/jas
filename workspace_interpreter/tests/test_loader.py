"""Tests for workspace loader — YAML loading, validation, element lookup, state defaults."""

import pytest

from workspace_interpreter.loader import (
    load_workspace, resolve_appearance, list_appearances,
    find_element_by_id, collect_element_ids,
    state_defaults, panel_state_defaults,
    resolve_templates, substitute_params,
)


class TestLoadWorkspace:
    def test_load_real_workspace(self, workspace_path):
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
        data = load_workspace(workspace_path)
        from workspace_interpreter.loader import REQUIRED_KEYS
        assert REQUIRED_KEYS.issubset(set(data.keys()))

    def test_load_missing_keys_raises(self, tmp_path):
        bad_file = tmp_path / "bad.yaml"
        bad_file.write_text("version: 1\napp:\n  name: test\n")
        with pytest.raises(ValueError, match="Missing"):
            load_workspace(str(bad_file))

    def test_load_nonexistent_file_raises(self):
        with pytest.raises(FileNotFoundError):
            load_workspace("/nonexistent/path.yaml")


class TestLoadSubdirectories:
    def test_load_includes_dialogs(self, workspace_path):
        data = load_workspace(workspace_path)
        assert "dialogs" in data
        assert "color_picker" in data["dialogs"]
        assert "save_changes_tab" in data["dialogs"]

    def test_load_includes_panels(self, workspace_path):
        data = load_workspace(workspace_path)
        assert "panels" in data
        assert "layers_panel_content" in data["panels"]
        assert "color_panel_content" in data["panels"]
        assert "stroke_panel_content" in data["panels"]
        assert "properties_panel_content" in data["panels"]

    def test_load_includes_default_layouts(self, workspace_path):
        data = load_workspace(workspace_path)
        assert "default_layouts" in data
        assert "Default" in data["default_layouts"]

    def test_load_includes_runtime_contexts(self, workspace_path):
        data = load_workspace(workspace_path)
        assert "runtime_contexts" in data
        assert "active_document" in data["runtime_contexts"]

    def test_load_swatch_libraries(self, workspace_path):
        import os
        swatches_dir = os.path.join(workspace_path, "swatches")
        if not os.path.isdir(swatches_dir):
            pytest.skip("swatches/ directory not present on this branch")
        data = load_workspace(workspace_path)
        assert "swatch_libraries" in data


class TestResolveIncludes:
    def test_no_include_keys_remain(self, workspace_path):
        data = load_workspace(workspace_path)

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

        assert not _has_include(data["layout"])

    def test_include_preserves_bind(self, workspace_path):
        data = load_workspace(workspace_path)
        dock_main = find_element_by_id(data["layout"], "dock_main")
        assert dock_main is not None
        assert dock_main.get("type") == "dock_view"
        assert "groups" in dock_main


class TestFindElementById:
    def test_find_root(self, sample_workspace):
        result = find_element_by_id(sample_workspace["layout"], "root")
        assert result is not None
        assert result["id"] == "root"

    def test_find_nested_child(self, sample_workspace):
        result = find_element_by_id(sample_workspace["layout"], "btn_1")
        assert result is not None
        assert result["type"] == "icon_button"

    def test_find_in_content(self, sample_workspace):
        result = find_element_by_id(sample_workspace["layout"], "grid_a")
        assert result is not None
        assert result["type"] == "grid"

    def test_find_placeholder(self, sample_workspace):
        result = find_element_by_id(sample_workspace["layout"], "placeholder_b")
        assert result is not None
        assert result["type"] == "placeholder"

    def test_not_found_returns_none(self, sample_workspace):
        result = find_element_by_id(sample_workspace["layout"], "nonexistent")
        assert result is None


class TestCollectElementIds:
    def test_collects_all_ids(self, sample_workspace):
        ids = collect_element_ids(sample_workspace["layout"])
        assert "root" in ids
        assert "pane_a" in ids
        assert "grid_a" in ids
        assert "btn_1" in ids
        assert "btn_2" in ids
        assert "pane_b" in ids
        assert "placeholder_b" in ids

    def test_all_ids_unique_in_real_workspace(self, workspace_path):
        data = load_workspace(workspace_path)
        ids = collect_element_ids(data["layout"])
        seen = set()
        for eid in ids:
            assert eid not in seen, f"Duplicate element id: '{eid}'"
            seen.add(eid)


class TestResolveAppearance:
    def test_returns_base_when_no_override(self):
        theme_config = {
            "active": "dark_gray",
            "base": {
                "colors": {"window_bg": "#2e2e2e", "text": "#cccccc"},
                "fonts": {"default": {"family": "sans-serif", "size": 12}},
                "sizes": {"tool_button": 32},
            },
            "appearances": {"dark_gray": {"label": "Dark Gray"}},
        }
        result = resolve_appearance(theme_config, "dark_gray")
        assert result["colors"]["window_bg"] == "#2e2e2e"
        assert result["fonts"]["default"]["family"] == "sans-serif"
        assert result["sizes"]["tool_button"] == 32

    def test_overrides_merge_on_top_of_base(self):
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
        assert result["fonts"]["default"]["size"] == 12

    def test_font_override(self):
        theme_config = {
            "active": "dark_gray",
            "base": {
                "colors": {},
                "fonts": {"default": {"family": "sans-serif", "size": 12}},
                "sizes": {},
            },
            "appearances": {
                "big_font": {"label": "Big Font", "fonts": {"default": {"size": 16}}},
            },
        }
        result = resolve_appearance(theme_config, "big_font")
        assert result["fonts"]["default"]["size"] == 16
        assert result["fonts"]["default"]["family"] == "sans-serif"

    def test_uses_active_when_name_is_none(self):
        theme_config = {
            "active": "medium_gray",
            "base": {"colors": {"window_bg": "#2e2e2e"}, "fonts": {}, "sizes": {}},
            "appearances": {
                "medium_gray": {"label": "Medium Gray", "colors": {"window_bg": "#505050"}},
            },
        }
        result = resolve_appearance(theme_config)
        assert result["colors"]["window_bg"] == "#505050"

    def test_unknown_appearance_raises(self):
        theme_config = {
            "active": "dark_gray",
            "base": {"colors": {}, "fonts": {}, "sizes": {}},
            "appearances": {"dark_gray": {"label": "Dark Gray"}},
        }
        with pytest.raises(ValueError, match="Unknown appearance"):
            resolve_appearance(theme_config, "nonexistent")

    def test_does_not_mutate_base(self):
        theme_config = {
            "active": "dark_gray",
            "base": {"colors": {"window_bg": "#2e2e2e"}, "fonts": {}, "sizes": {}},
            "appearances": {
                "light": {"label": "Light", "colors": {"window_bg": "#ffffff"}},
            },
        }
        resolve_appearance(theme_config, "light")
        assert theme_config["base"]["colors"]["window_bg"] == "#2e2e2e"

    def test_real_workspace_theme(self, workspace_path):
        data = load_workspace(workspace_path)
        theme_config = data["theme"]
        assert "base" in theme_config
        assert "appearances" in theme_config
        for name in theme_config["appearances"]:
            result = resolve_appearance(theme_config, name)
            assert "colors" in result
            assert "fonts" in result
            assert "sizes" in result


class TestListAppearances:
    def test_returns_names_and_labels(self):
        theme_config = {
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


class TestAppearanceLoading:
    def test_appearances_loaded_from_directory(self, workspace_path):
        data = load_workspace(workspace_path)
        theme = data["theme"]
        assert "dark_gray" in theme["appearances"]
        assert "medium_gray" in theme["appearances"]
        assert "light_gray" in theme["appearances"]

    def test_appearance_has_label(self, workspace_path):
        data = load_workspace(workspace_path)
        for name, app in data["theme"]["appearances"].items():
            assert "label" in app, f"Appearance {name} missing label"


class TestValidateActionRefs:
    def test_all_shortcut_actions_exist(self, workspace_path):
        data = load_workspace(workspace_path)
        actions = data["actions"]
        for shortcut in data["shortcuts"]:
            assert shortcut["action"] in actions, (
                f"Shortcut action '{shortcut['action']}' not in actions"
            )

    def test_all_menu_actions_exist(self, workspace_path):
        data = load_workspace(workspace_path)
        actions = data["actions"]

        def check_items(items):
            for item in items:
                if isinstance(item, str):
                    continue
                if "action" in item:
                    assert item["action"] in actions, (
                        f"Menu action '{item['action']}' not in actions"
                    )
                if "items" in item:
                    check_items(item["items"])

        for menu in data["menubar"]:
            check_items(menu["items"])


class TestStateDefaults:
    def test_extracts_defaults(self):
        state_defs = {
            "active_tool": {"type": "enum", "values": ["pen", "rect"], "default": "pen"},
            "fill_color": {"type": "color", "default": "#ffffff", "nullable": True},
            "tab_count": {"type": "number", "default": 0},
        }
        result = state_defaults(state_defs)
        assert result == {"active_tool": "pen", "fill_color": "#ffffff", "tab_count": 0}

    def test_missing_default_is_none(self):
        state_defs = {"flag": {"type": "bool"}}
        result = state_defaults(state_defs)
        assert result == {"flag": None}

    def test_empty_state(self):
        assert state_defaults({}) == {}
        assert state_defaults(None) == {}


class TestPanelStateDefaults:
    def test_extracts_panel_defaults(self):
        panel_spec = {
            "id": "color_panel_content",
            "type": "panel",
            "state": {
                "mode": {"type": "enum", "values": ["hsb", "rgb"], "default": "hsb"},
                "h": {"type": "number", "default": 0},
                "recent_colors": {"type": "list", "default": [], "per_document": True},
            },
        }
        result = panel_state_defaults(panel_spec)
        assert result == {"mode": "hsb", "h": 0, "recent_colors": []}

    def test_panel_with_no_state(self):
        panel_spec = {"id": "layers_panel_content", "type": "panel"}
        assert panel_state_defaults(panel_spec) == {}


class TestSubstituteParams:
    def test_whole_value_string(self):
        assert substitute_params("${name}", {"name": "hello"}) == "hello"

    def test_whole_value_number(self):
        assert substitute_params("${min}", {"min": 360}) == 360

    def test_whole_value_bool(self):
        assert substitute_params("${flag}", {"flag": True}) is True

    def test_whole_value_dict(self):
        result = substitute_params("${style}", {"style": {"flex": 1}})
        assert result == {"flex": 1}

    def test_whole_value_list(self):
        result = substitute_params("${items}", {"items": [1, 2, 3]})
        assert result == [1, 2, 3]

    def test_string_interpolation(self):
        assert substitute_params("${label}:", {"label": "H"}) == "H:"

    def test_multiple_interpolations(self):
        result = substitute_params("${a} and ${b}", {"a": "x", "b": "y"})
        assert result == "x and y"

    def test_no_substitution(self):
        assert substitute_params("plain text", {"x": 1}) == "plain text"

    def test_dict_recursion(self):
        result = substitute_params(
            {"gap": "${gap}", "alignment": "center"},
            {"gap": 4},
        )
        assert result == {"gap": 4, "alignment": "center"}

    def test_list_recursion(self):
        result = substitute_params(
            [{"min": "${min}"}, {"max": "${max}"}],
            {"min": 0, "max": 100},
        )
        assert result == [{"min": 0}, {"max": 100}]

    def test_missing_param_unchanged(self):
        assert substitute_params("${missing}", {}) == "${missing}"

    def test_nested_dict_in_list(self):
        result = substitute_params(
            [{"bind": {"value": "${bind}"}}],
            {"bind": "dialog.h"},
        )
        assert result == [{"bind": {"value": "dialog.h"}}]


class TestResolveTemplates:
    def test_simple_expansion(self):
        templates = {
            "greeting": {
                "params": {"name": {"type": "string"}},
                "content": {"type": "text", "content": "Hello ${name}"},
            }
        }
        element = {
            "type": "container",
            "children": [
                {"template": "greeting", "params": {"name": "World"}},
            ],
        }
        resolve_templates(element, templates)
        assert element["children"][0] == {"type": "text", "content": "Hello World"}

    def test_typed_number_substitution(self):
        templates = {
            "slider": {
                "params": {"min": {"type": "number"}, "max": {"type": "number"}},
                "content": {"type": "slider", "min": "${min}", "max": "${max}"},
            }
        }
        element = {
            "type": "container",
            "children": [
                {"template": "slider", "params": {"min": 0, "max": 360}},
            ],
        }
        resolve_templates(element, templates)
        child = element["children"][0]
        assert child["min"] == 0
        assert child["max"] == 360
        assert isinstance(child["min"], int)

    def test_default_params(self):
        templates = {
            "box": {
                "params": {
                    "color": {"type": "string", "default": "red"},
                    "size": {"type": "number", "default": 10},
                },
                "content": {"type": "box", "color": "${color}", "size": "${size}"},
            }
        }
        element = {
            "type": "container",
            "children": [
                {"template": "box", "params": {}},
            ],
        }
        resolve_templates(element, templates)
        child = element["children"][0]
        assert child["color"] == "red"
        assert child["size"] == 10

    def test_sibling_merge(self):
        templates = {
            "label": {
                "params": {"text": {"type": "string"}},
                "content": {"type": "text", "content": "${text}"},
            }
        }
        element = {
            "type": "container",
            "children": [
                {"template": "label", "params": {"text": "hi"}, "id": "my_label", "style": {"color": "red"}},
            ],
        }
        resolve_templates(element, templates)
        child = element["children"][0]
        assert child["type"] == "text"
        assert child["content"] == "hi"
        assert child["id"] == "my_label"
        assert child["style"] == {"color": "red"}

    def test_nested_templates(self):
        templates = {
            "inner": {
                "params": {"val": {"type": "string"}},
                "content": {"type": "text", "content": "${val}"},
            },
            "outer": {
                "params": {"msg": {"type": "string"}},
                "content": {
                    "type": "container",
                    "children": [
                        {"template": "inner", "params": {"val": "${msg}"}},
                    ],
                },
            },
        }
        element = {
            "type": "container",
            "children": [
                {"template": "outer", "params": {"msg": "hello"}},
            ],
        }
        resolve_templates(element, templates)
        inner = element["children"][0]["children"][0]
        assert inner == {"type": "text", "content": "hello"}

    def test_no_template_key_remains(self):
        templates = {
            "simple": {
                "params": {},
                "content": {"type": "spacer"},
            }
        }
        element = {
            "type": "container",
            "children": [{"template": "simple", "params": {}}],
        }
        resolve_templates(element, templates)
        child = element["children"][0]
        assert "template" not in child
        assert "params" not in child

    def test_content_with_children(self):
        """Template content that has children should expand correctly."""
        templates = {
            "row": {
                "params": {"label": {"type": "string"}},
                "content": {
                    "type": "container",
                    "layout": "row",
                    "children": [
                        {"type": "text", "content": "${label}"},
                        {"type": "spacer"},
                    ],
                },
            }
        }
        element = {
            "type": "container",
            "children": [
                {"template": "row", "params": {"label": "Name"}},
            ],
        }
        resolve_templates(element, templates)
        child = element["children"][0]
        assert child["type"] == "container"
        assert child["layout"] == "row"
        assert len(child["children"]) == 2
        assert child["children"][0]["content"] == "Name"

    def test_full_workspace_loads(self, workspace_path):
        """Real workspace loads without errors after template support."""
        data = load_workspace(workspace_path)
        assert data["version"] == 1


class TestCompile:
    def test_compile_produces_valid_json(self, workspace_path, tmp_path):
        import json
        from workspace_interpreter.compile import main
        import sys

        output_file = tmp_path / "workspace.json"
        old_argv = sys.argv
        sys.argv = ["compile", workspace_path, str(output_file)]
        try:
            main()
        finally:
            sys.argv = old_argv

        with open(output_file) as f:
            data = json.load(f)
        assert data["version"] == 1
        assert "panels" in data
        assert "actions" in data
