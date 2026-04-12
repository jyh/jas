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
        # The color panel is included with a bind override
        color_panel = find_element_by_id(data["layout"], "color_panel_content")
        assert color_panel is not None
        assert "bind" in color_panel or "visible" in str(color_panel.get("bind", {}))


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
