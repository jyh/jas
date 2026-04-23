"""Phase 5 + 6 of the Python YAML tool-runtime migration.

Covers the :class:`YamlTool` class and end-to-end Selection
validation loaded from workspace/workspace.json.
"""

from __future__ import annotations

import json
import os
import sys

_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)
_JAS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _JAS_DIR not in sys.path:
    sys.path.insert(0, _JAS_DIR)

import pytest

from document.controller import Controller
from document.document import Document, ElementSelection
from document.model import Model
from geometry.element import Layer, Rect as RectElem
from tools.tool import KeyMods
from tools.yaml_tool import YamlTool, tool_spec_from_workspace


# ── ToolSpec parsing ────────────────────────────────────


class TestToolSpec:
    def test_requires_id(self):
        assert tool_spec_from_workspace({}) is None
        assert tool_spec_from_workspace({"id": "foo"}) is not None

    def test_parses_cursor_and_menu_label(self):
        spec = tool_spec_from_workspace({
            "id": "foo", "cursor": "crosshair",
            "menu_label": "Foo", "shortcut": "F",
        })
        assert spec is not None
        assert spec.cursor == "crosshair"
        assert spec.menu_label == "Foo"
        assert spec.shortcut == "F"

    def test_parses_state_shorthand(self):
        spec = tool_spec_from_workspace({
            "id": "foo",
            "state": {"count": 3, "active": False},
        })
        assert spec is not None
        assert spec.state_defaults == {"count": 3, "active": False}

    def test_parses_state_long_form(self):
        spec = tool_spec_from_workspace({
            "id": "foo",
            "state": {"mode": {"default": "idle", "enum": ["idle"]}},
        })
        assert spec is not None
        assert spec.state_defaults == {"mode": "idle"}

    def test_parses_handlers(self):
        spec = tool_spec_from_workspace({
            "id": "foo",
            "handlers": {
                "on_mousedown": [{"doc.snapshot": None}],
            },
        })
        assert spec is not None
        assert len(spec.handlers["on_mousedown"]) == 1

    def test_parses_overlay(self):
        spec = tool_spec_from_workspace({
            "id": "foo",
            "overlay": {
                "if": "tool.foo.show",
                "render": {"type": "rect"},
            },
        })
        assert spec is not None
        assert spec.overlay is not None
        assert spec.overlay.guard == "tool.foo.show"
        assert spec.overlay.render["type"] == "rect"


# ── Helpers ────────────────────────────────────────────


def _make_rect(x, y, w, h):
    return RectElem(x=x, y=y, width=w, height=h)


def _two_rect_model() -> Model:
    layer = Layer(name="L", children=(
        _make_rect(0.0, 0.0, 10.0, 10.0),
        _make_rect(50.0, 50.0, 10.0, 10.0),
    ))
    return Model(document=Document(layers=(layer,)))


def _ctx(model: Model):
    ctrl = Controller(model)
    ctx_obj = type("Ctx", (), {})()
    ctx_obj.model = model
    ctx_obj.controller = ctrl
    ctx_obj.document = model.document
    ctx_obj.request_update = lambda: None
    return ctx_obj, ctrl


# ── Dispatch ───────────────────────────────────────────


class TestDispatch:
    def test_seeds_state_defaults(self):
        tool = YamlTool.from_workspace_tool({
            "id": "foo",
            "state": {"count": 7},
        })
        assert tool is not None
        assert tool.tool_state("count") == 7

    def test_mousedown_dispatches_handler(self):
        tool = YamlTool.from_workspace_tool({
            "id": "foo",
            "handlers": {
                "on_mousedown": [
                    {"set": {"$tool.foo.pressed": "true"}},
                ],
            },
        })
        assert tool is not None
        model = Model()
        ctx, _ = _ctx(model)
        tool.on_press(ctx, 10, 20)
        assert tool.tool_state("pressed") is True

    def test_mouseup_payload_carries_coordinates(self):
        tool = YamlTool.from_workspace_tool({
            "id": "foo",
            "handlers": {
                "on_mouseup": [
                    {"set": {"$tool.foo.x_at_release": "event.x"}},
                ],
            },
        })
        assert tool is not None
        model = Model()
        ctx, _ = _ctx(model)
        tool.on_release(ctx, 42, 0)
        v = tool.tool_state("x_at_release")
        # Value may be int or float depending on how the evaluator
        # coerces event.x (integer-literal value → int).
        assert v == 42

    def test_empty_handler_is_noop(self):
        tool = YamlTool.from_workspace_tool({"id": "foo"})
        assert tool is not None
        model = Model()
        ctx, _ = _ctx(model)
        tool.on_press(ctx, 0, 0)
        assert len(model.document.selection) == 0

    def test_activate_resets_state_defaults(self):
        tool = YamlTool.from_workspace_tool({
            "id": "foo",
            "state": {"mode": "idle"},
            "handlers": {
                "on_mousedown": [
                    {"set": {"$tool.foo.mode": "'busy'"}},
                ],
            },
        })
        assert tool is not None
        model = Model()
        ctx, _ = _ctx(model)
        tool.on_press(ctx, 0, 0)
        assert tool.tool_state("mode") == "busy"
        tool.activate(ctx)
        assert tool.tool_state("mode") == "idle"

    def test_keydown_dispatches_when_declared(self):
        tool = YamlTool.from_workspace_tool({
            "id": "foo",
            "handlers": {
                "on_keydown": [
                    {"set": {"$tool.foo.last_key": "event.key"}},
                ],
            },
        })
        assert tool is not None
        model = Model()
        ctx, _ = _ctx(model)
        consumed = tool.on_key_event(ctx, "Escape", KeyMods())
        assert consumed
        assert tool.tool_state("last_key") == "Escape"

    def test_keydown_returns_false_when_undeclared(self):
        tool = YamlTool.from_workspace_tool({"id": "foo"})
        assert tool is not None
        model = Model()
        ctx, _ = _ctx(model)
        assert not tool.on_key_event(ctx, "Escape", KeyMods())

    def test_cursor_override_reflects_spec(self):
        tool = YamlTool.from_workspace_tool({
            "id": "foo", "cursor": "crosshair",
        })
        assert tool is not None
        assert tool.cursor_css_override() == "crosshair"

    def test_dispatches_doc_effects(self):
        tool = YamlTool.from_workspace_tool({
            "id": "foo",
            "handlers": {
                "on_mousedown": [{
                    "doc.add_element": {
                        "element": {
                            "type": "rect",
                            "x": "event.x", "y": "event.y",
                            "width": 10, "height": 10,
                        },
                    },
                }],
            },
        })
        assert tool is not None
        layer = Layer(name="L", children=())
        model = Model(document=Document(layers=(layer,)))
        ctx, _ = _ctx(model)
        tool.on_press(ctx, 5, 7)
        assert len(model.document.layers[0].children) == 1


# ── Phase 6: Selection validation ───────────────────────


def _load_selection_tool() -> YamlTool | None:
    ws_path = os.path.abspath(os.path.join(
        _REPO_ROOT, "workspace", "workspace.json",
    ))
    if not os.path.exists(ws_path):
        return None
    with open(ws_path, "r") as f:
        data = json.load(f)
    tools = data.get("tools")
    if not isinstance(tools, dict):
        return None
    spec = tools.get("selection")
    return YamlTool.from_workspace_tool(spec) if spec else None


class TestSelectionValidation:
    def test_loads_from_workspace(self):
        tool = _load_selection_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "selection"
        assert tool.spec.cursor == "arrow"
        assert tool.spec.shortcut == "V"

    def test_click_on_element_selects(self):
        tool = _load_selection_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _two_rect_model()
        ctx, _ = _ctx(model)
        tool.on_press(ctx, 5, 5)
        tool.on_release(ctx, 5, 5)
        paths = {es.path for es in model.document.selection}
        assert (0, 0) in paths

    def test_click_empty_space_clears(self):
        tool = _load_selection_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _two_rect_model()
        ctx, ctrl = _ctx(model)
        ctrl.select_element((0, 0))
        tool.on_press(ctx, 200, 200)
        tool.on_release(ctx, 200, 200)
        assert len(model.document.selection) == 0

    def test_shift_click_toggles_selection(self):
        tool = _load_selection_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _two_rect_model()
        ctx, _ = _ctx(model)
        tool.on_press(ctx, 5, 5, shift=True)
        tool.on_release(ctx, 5, 5, shift=True)
        assert len(model.document.selection) == 1
        tool.on_press(ctx, 5, 5, shift=True)
        tool.on_release(ctx, 5, 5, shift=True)
        assert len(model.document.selection) == 0

    def test_drag_moves_selected_element(self):
        tool = _load_selection_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _two_rect_model()
        ctx, _ = _ctx(model)
        tool.on_press(ctx, 5, 5)
        tool.on_move(ctx, 15, 15, dragging=True)
        tool.on_release(ctx, 15, 15)
        r = model.document.layers[0].children[0]
        assert isinstance(r, RectElem)
        assert r.x == 10.0 and r.y == 10.0

    def test_marquee_release_selects_elements(self):
        tool = _load_selection_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _two_rect_model()
        ctx, _ = _ctx(model)
        tool.on_press(ctx, -5, -5)
        tool.on_move(ctx, 12, 12, dragging=True)
        tool.on_release(ctx, 12, 12)
        paths = {es.path for es in model.document.selection}
        assert (0, 0) in paths

    def test_alt_drag_copies_selection(self):
        tool = _load_selection_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _two_rect_model()
        ctx, _ = _ctx(model)
        tool.on_press(ctx, 5, 5, alt=True)
        tool.on_move(ctx, 100, 100, dragging=True)
        tool.on_release(ctx, 100, 100, alt=True)
        assert len(model.document.layers[0].children) == 3

    def test_escape_idles_state(self):
        tool = _load_selection_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _two_rect_model()
        ctx, _ = _ctx(model)
        tool.on_press(ctx, -5, -5)
        assert tool.tool_state("mode") == "marquee"
        tool.on_key_event(ctx, "Escape", KeyMods())
        assert tool.tool_state("mode") == "idle"
