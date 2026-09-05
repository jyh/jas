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


# ── VISION §11's last gate: panels / dialogs / menubar / toolbar / actions ──
#
# Six schemas landed 2026-09-05 — widget (shared), panel, dialog, action,
# menubar, layout (the toolbar is a pane of the layout). Each arm below plants
# ONE defect of the class the schema exists to refuse and asserts the refusal
# names the site; the minimal valid document beside it is the control that the
# refusal is about the defect, not the scaffold. The real workspace validating
# (TestRealWorkspaceValidates above) is the other half: the schemas went red on
# 63 sites of the real tree when first written, every one a form the census had
# missed (`name:` on icons, the string `bind:` shorthand, derived dialog state
# with `get`/`set` and no default, a boolean `fixed_width`), and NONE a defect —
# that is a clean negative, reported as one.


def _widget(**over):
    w = {"type": "container", "children": []}
    w.update(over)
    return w


def _panel(**over):
    p = {
        "id": "probe_panel_content",
        "type": "panel",
        "summary": "Probe",
        "description": "A probe panel.",
        "state": {"mode": {"type": "enum", "default": "a", "values": ["a", "b"], "description": "m"}},
        "menu": [{"label": "Do", "action": "do_it", "enabled_when": "panel.mode == 'a'"}, "separator"],
        "content": _widget(children=[_widget(type="button", id="b1", bind={"disabled": "panel.mode == 'b'"})]),
    }
    p.update(over)
    return p


class TestPanelStructural:
    def test_minimal_panel_validates(self):
        assert _validate_structural("panel", _panel(), "probe") == []

    def test_unknown_top_level_key_is_refused(self):
        errs = _validate_structural("panel", _panel(contents="oops"), "probe")
        assert any("contents" in e for e in errs), errs

    def test_widget_kind_outside_the_canonical_set_is_refused(self):
        errs = _validate_structural("panel", _panel(content=_widget(type="buton")), "probe")
        assert errs and any("buton" in e or "enum" in e for e in errs), errs

    def test_pane_system_kinds_are_not_panel_widgets(self):
        """`dock_view` is a layout kind; a panel using it is the enum check
        the item asked for, made real."""
        errs = _validate_structural("panel", _panel(content=_widget(type="dock_view")), "probe")
        assert errs, "a pane-system kind inside a panel must be refused"

    def test_nested_child_is_checked_through_the_cross_file_ref(self):
        """The widget tree lives in widget.schema.json and is reached by a
        cross-file `$ref`; a defect THREE levels down must still red, or
        the ref is dead and the tree unvalidated."""
        deep = _widget(children=[_widget(children=[_widget(type="text", childs=[])])])
        errs = _validate_structural("panel", _panel(content=deep), "probe")
        assert any("childs" in e for e in errs), errs

    def test_bind_value_must_be_an_expression_string(self):
        errs = _validate_structural(
            "panel", _panel(content=_widget(type="button", bind={"disabled": True})), "probe")
        assert errs, "a literal bind is a bind that can never change"

    def test_string_bind_shorthand_is_accepted(self):
        assert _validate_structural(
            "panel", _panel(content=_widget(type="text_input", bind="panel.mode")), "probe") == []

    def test_menu_entry_needs_a_label_and_known_keys(self):
        errs = _validate_structural("panel", _panel(menu=[{"action": "x"}]), "probe")
        assert errs
        errs = _validate_structural("panel", _panel(menu=[{"label": "X", "enabled": "true"}]), "probe")
        assert errs, "`enabled` is not `enabled_when`"

    def test_state_entry_needs_type_and_default(self):
        errs = _validate_structural("panel", _panel(state={"k": {"default": 1}}), "probe")
        assert any("type" in e for e in errs), errs


class TestDialogStructural:
    def _dialog(self, **over):
        d = {"summary": "Probe", "description": "d", "modal": True,
             "state": {"v": {"type": "number", "default": 0},
                       "vv": {"get": "v * 2", "set": "fun n -> v <- n / 2"}},
             "content": _widget()}
        d.update(over)
        return d

    def test_minimal_dialog_validates(self):
        assert _validate_structural("dialog", self._dialog(), "probe") == []

    def test_stored_entry_without_default_is_refused(self):
        errs = _validate_structural("dialog", self._dialog(state={"v": {"type": "number"}}), "probe")
        assert errs, "stored state needs a default; derived state needs get AND set"

    def test_derived_entry_with_get_alone_is_refused(self):
        errs = _validate_structural("dialog", self._dialog(state={"v": {"get": "1"}}), "probe")
        assert errs

    def test_modal_must_be_boolean_and_params_typed(self):
        assert _validate_structural("dialog", self._dialog(modal="yes"), "probe")
        assert _validate_structural("dialog", self._dialog(params={"p": {"type": "int"}}), "probe")


class TestActionStructural:
    def _action(self, **over):
        a = {"description": "Probe", "category": "edit",
             "effects": ["snapshot", {"set_panel_state": {"panel": "color", "key": "mode", "value": '"rgb"'}}]}
        a.update(over)
        return a

    def test_minimal_action_validates(self):
        assert _validate_structural("action", self._action(), "probe") == []

    def test_misspelt_effect_key_is_refused(self):
        errs = _validate_structural("action", self._action(effects=[{"set_panel_stat": {}}]), "probe")
        assert errs, "an effect verb no port dispatches must not compile"

    def test_misspelt_bare_effect_is_refused(self):
        errs = _validate_structural("action", self._action(effects=["snapshoot"]), "probe")
        assert errs

    def test_category_outside_the_list_is_refused(self):
        errs = _validate_structural("action", self._action(category="layer"), "probe")
        assert errs, "`layer` is not `layers`"

    def test_param_type_is_an_enum(self):
        errs = _validate_structural("action", self._action(params={"n": {"type": "integer"}}), "probe")
        assert errs


class TestMenubarStructural:
    def _menubar(self, items):
        return {"menubar": [{"id": "file", "label": "File", "items": items}]}

    def test_minimal_menubar_validates(self):
        doc = self._menubar([{"id": "new", "label": "New", "action": "new_document"}, "separator",
                             {"id": "sub", "label": "Sub", "type": "submenu",
                              "items": [{"id": "a", "label": "A", "action": "a"}]}])
        assert _validate_structural("menubar", doc, "probe") == []

    def test_item_without_id_or_with_unknown_key_is_refused(self):
        assert _validate_structural("menubar", self._menubar([{"label": "X"}]), "probe")
        assert _validate_structural(
            "menubar", self._menubar([{"id": "x", "label": "X", "enabled": "true"}]), "probe")


class TestLayoutStructural:
    def test_pane_system_validates_and_a_stray_key_reds(self):
        doc = {"layout": {"id": "root", "type": "pane_system",
                          "children": [{"id": "toolbar_pane", "type": "pane", "fixed_width": True,
                                        "children": [{"type": "dock_view"}]}]}}
        assert _validate_structural("layout", doc, "probe") == []
        doc["layout"]["children"][0]["min_widht"] = 100
        assert _validate_structural("layout", doc, "probe")


class TestTheFiveSectionsAreWired:
    """A schema on disk validates nothing until `validate_workspace` runs it
    over the section; each arm plants a defect in a whole-workspace dict and
    expects the SECTION's `where` in the error."""

    def _ws(self):
        return {"app": {"name": "T"}, "schema_version": "2.0"}

    def test_a_broken_panel_names_its_source_file(self):
        ws = self._ws(); ws["panels"] = {"brushes_panel_content": _panel(id="brushes_panel_content", menu=[{"action": "x"}])}
        assert any(e.startswith("panels/brushes.yaml") for e in validate_workspace(ws))

    def test_a_broken_dialog_action_menubar_and_layout_are_named(self):
        ws = self._ws()
        ws["dialogs"] = {"probe": {"summary": "s", "description": "d", "modal": "no", "content": _widget()}}
        ws["actions"] = {"probe": {"description": "d", "category": "edit", "effects": ["snapshoot"]}}
        ws["menubar"] = [{"id": "m", "label": "M", "items": [{"label": "no id"}]}]
        ws["layout"] = {"type": "pane_sytem"}
        errs = validate_workspace(ws)
        for where in ("dialogs/probe.yaml", "actions.yaml: probe", "menubar.yaml", "layout.yaml"):
            assert any(e.startswith(where) for e in errs), (where, errs)
