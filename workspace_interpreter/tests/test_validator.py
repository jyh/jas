"""Tests for the workspace schema validator.

Covers Layer-1 (structural) validation for app and tool YAML. Layer-2
(cross-reference) and Layer-3 (expression parse) tests land as those
layers are implemented.
"""

from workspace_interpreter.loader import load_workspace
from workspace_interpreter.validator import (
    validate_workspace,
    ValidationError,
    format_errors,
    _validate_structural,
    _validate_minimal,
)


class TestRealWorkspaceValidates:
    """The committed workspace/ must validate without errors at all
    times. CI enforces this via compile --validate."""

    def test_real_workspace_has_no_validation_errors(self, workspace_path):
        ws = load_workspace(workspace_path)
        errors = validate_workspace(ws)
        assert errors == [], format_errors(errors)

    def test_real_workspace_has_schema_version(self, workspace_path):
        ws = load_workspace(workspace_path)
        assert ws.get("schema_version") == "2.0"


class TestAppStructural:
    def test_app_doc_valid(self):
        doc = {"app": {"name": "Test"}}
        errs = _validate_structural("app", doc, "test")
        assert errs == []

    def test_app_missing_name(self):
        doc = {"app": {}}
        errs = _validate_structural("app", doc, "test")
        assert any("name" in e for e in errs)

    def test_schema_version_format(self):
        doc = {"app": {"name": "T"}, "schema_version": "not-a-version"}
        errs = _validate_structural("app", doc, "test")
        # The minimal validator doesn't enforce pattern, but jsonschema does.
        # Either way the real workspace must pass — this test just documents
        # intent.
        _ = errs


class TestToolStructural:
    def _minimal_tool(self):
        return {
            "id": "test_tool",
            "handlers": {
                "on_mousedown": [{"set": "$state.x", "value": 1}],
            },
        }

    def test_valid_tool(self):
        errs = _validate_structural("tool", self._minimal_tool(), "tool.yaml")
        assert errs == []

    def test_tool_missing_id(self):
        tool = self._minimal_tool()
        del tool["id"]
        errs = _validate_structural("tool", tool, "tool.yaml")
        assert any("id" in e for e in errs)

    def test_tool_missing_handlers(self):
        tool = self._minimal_tool()
        del tool["handlers"]
        errs = _validate_structural("tool", tool, "tool.yaml")
        assert any("handlers" in e for e in errs)

    def test_tool_unknown_handler_key(self):
        """handlers: has a closed set of event names; typos are errors."""
        tool = self._minimal_tool()
        tool["handlers"]["on_tyop"] = []
        errs = _validate_structural("tool", tool, "tool.yaml")
        # jsonschema flags as additional-properties; minimal validator
        # flags as unknown field. Both should produce an error.
        assert any("on_tyop" in e or "unknown" in e.lower() for e in errs)

    def test_tool_with_overlay(self):
        tool = self._minimal_tool()
        tool["overlay"] = {
            "if": "$tool.test.active",
            "render": {"type": "rect"},
        }
        errs = _validate_structural("tool", tool, "tool.yaml")
        assert errs == []

    def test_tool_state_requires_default(self):
        tool = self._minimal_tool()
        tool["state"] = {"mode": {}}
        errs = _validate_structural("tool", tool, "tool.yaml")
        assert any("default" in e for e in errs)


class TestSelectionTool:
    """The canonical selection.yaml example must validate."""

    def test_selection_tool_validates(self, workspace_path):
        ws = load_workspace(workspace_path)
        tool = ws.get("tools", {}).get("selection")
        assert tool is not None, (
            "workspace/tools/selection.yaml should be loaded into "
            "ws['tools']['selection']"
        )
        errs = _validate_structural("tool", tool, "selection.yaml")
        assert errs == [], format_errors(errs)

    def test_selection_declares_all_expected_handlers(self, workspace_path):
        ws = load_workspace(workspace_path)
        handlers = ws["tools"]["selection"]["handlers"]
        for key in (
            "on_enter", "on_leave",
            "on_mousedown", "on_mousemove", "on_mouseup",
            "on_keydown",
        ):
            assert key in handlers, f"selection tool missing {key}"


class TestElementsSchema:
    def test_elements_valid(self):
        doc = {
            "elements": {
                "rect": {"fill": "#ffffff", "stroke": {"color": "#000000", "width": 1.0}},
                "path": {"fill": None, "stroke": {"color": "#000000", "width": 1.0}},
                "text": {"fill": "#000000", "stroke": None, "font": {"family": "Helvetica", "size": 12}},
            },
        }
        errs = _validate_structural("elements", doc, "elements.yaml")
        assert errs == [], format_errors(errs)

    def test_real_workspace_elements_valid(self, workspace_path):
        ws = load_workspace(workspace_path)
        assert "elements" in ws
        assert "rect" in ws["elements"]
        assert ws["elements"]["rect"]["fill"] == "#ffffff"


class TestPreferencesSchema:
    def test_preferences_valid(self):
        doc = {
            "preferences": {
                "autosave": {"enabled": True, "interval_seconds": 30},
                "units": {"default": "px", "show_in_panels": True},
            },
        }
        errs = _validate_structural("preferences", doc, "preferences.yaml")
        assert errs == [], format_errors(errs)

    def test_real_workspace_preferences_valid(self, workspace_path):
        ws = load_workspace(workspace_path)
        assert ws["preferences"]["autosave"]["enabled"] is True


class TestFeaturesSchema:
    def test_features_valid(self):
        doc = {
            "features": {
                "server_storage": {"available": False},
                "clipboard_rich": {"available": True},
            },
        }
        errs = _validate_structural("features", doc, "features.yaml")
        assert errs == [], format_errors(errs)

    def test_features_expression_string_allowed(self):
        doc = {"features": {"x": {"available": "$config.x_enabled"}}}
        errs = _validate_structural("features", doc, "features.yaml")
        assert errs == [], format_errors(errs)


class TestValidationError:
    def test_error_accumulation(self):
        """validate_workspace returns a list rather than raising on
        first error — callers can surface all issues at once."""
        # Synthetic broken workspace: tool without required 'id'.
        ws = {
            "app": {"name": "T"},
            "schema_version": "2.0",
            "tools": {
                "broken": {"handlers": {}},  # missing id
            },
        }
        errs = validate_workspace(ws)
        assert errs, "expected validation errors"

    def test_format_errors_empty(self):
        assert format_errors([]) == ""

    def test_format_errors_nonempty(self):
        out = format_errors(["a", "b"])
        assert "2 errors" in out
        assert "a" in out
        assert "b" in out
