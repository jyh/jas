"""Pen-tool behavioral tests — Python port of the Rust pen seam tests in
jas_dioxus/src/tools/yaml_tool.rs (the ``pen_parity_*`` family) and the Swift
port in JasSwift/Tests/Tools/YamlToolPenTests.swift.

These cover the externally-observable outcomes of the YAML-driven pen tool
loaded from the compiled workspace bundle: click-click-click creates a
polyline, click-drag sets the out-handle, click-near-first closes the path,
double-click commits open, and Escape either commits (>= 2 anchors) or
discards (< 2 anchors).

Seam mapping from Rust to this app (Python / PySide6):
    on_press        -> on_press(ctx, x, y, shift, alt)
    on_move(drag)   -> on_move(ctx, x, y, shift, alt, dragging)
    on_release      -> on_release(ctx, x, y, shift, alt)
    on_double_click -> on_double_click(ctx, x, y)   (dispatches on_dblclick)
    on_key_event    -> on_key_event(ctx, key, mods) (dispatches on_keydown)

ESCAPE ENTRY POINT (the Rust on_key vs on_key_event regression guard).
Rust's app shell calls ``tool.on_key`` for Escape/Enter, so a YamlTool that
only overrode ``on_key_event`` would miss Escape (the dx-serve bug that
surfaced the guard). In THIS app the split is different but the conclusion is
the same as Swift's: ``CanvasTool.on_key`` is the int-keyCode handler and
``YamlTool`` does NOT override it (it returns False — see
tools/yaml_tool.py on_key). The string ``on_key_event`` is the handler
YamlTool actually implements (it dispatches the spec's ``on_keydown``). The
canvas's real Escape path for a NON-CAPTURING tool like the pen is, in
canvas/canvas.py keyPressEvent: ``on_key`` is tried first (returns False for
the pen), then the Escape branch calls
``self._active_tool.on_key_event(self._tool_ctx, "Escape", mods)``
(canvas.py ~line 2238). So in Python the Rust on_key regression guard and the
on_key_event path collapse onto the SAME method, ``on_key_event``. Test #4
drives that exact entry point — the one the canvas dispatches — which is the
equivalent regression guard.

The committed element is a Path whose ``d`` is a tuple of path commands
(MoveTo / LineTo / CurveTo / ClosePath dataclasses from geometry.element).
Each test asserts on the committed Path at ``layers[0].children[0]``.
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
from document.document import Document
from document.model import Model
from geometry.element import (
    ClosePath, CurveTo, Layer, MoveTo, Path,
)
from tools.tool import KeyMods, ToolContext
from tools.yaml_tool import YamlTool


# ── Loader + harness helpers ───────────────────────────────


def _pen_tool() -> YamlTool | None:
    """Load the "pen" spec from the compiled workspace bundle and build a
    YamlTool, mirroring the selection-tool loader in yaml_tool_test.py."""
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
    spec = tools.get("pen")
    return YamlTool.from_workspace_tool(spec) if spec else None


def _empty_layer_model() -> Model:
    """A document with a single empty top-level layer — the empty-layer model
    the Rust/Swift ports build (committed paths land at layers[0].children[0])."""
    layer = Layer(name="L", children=())
    return Model(document=Document(layers=(layer,)))


def _ctx(model: Model) -> ToolContext:
    """A faithful headless ToolContext over a live document, with inert
    hit-test callbacks (the pen tool does no hit-testing). Mirrors the
    cross_language_test.py gesture harness ToolContext."""
    return ToolContext(
        model=model,
        controller=Controller(model=model),
        hit_test_selection=lambda x, y: False,
        hit_test_handle=lambda x, y: None,
        hit_test_text=lambda x, y: None,
        hit_test_path_curve=lambda x, y: None,
        request_update=lambda: None,
    )


def _click(tool: YamlTool, ctx: ToolContext, x: float, y: float) -> None:
    """A single pen "click": press + release at the same point, no modifiers."""
    tool.on_press(ctx, x, y, False, False)
    tool.on_release(ctx, x, y, False, False)


def _committed_path(model: Model) -> Path:
    children = model.document.layers[0].children
    assert len(children) == 1, f"expected exactly one child, got {len(children)}"
    el = children[0]
    assert isinstance(el, Path), f"expected Path, got {type(el).__name__}"
    return el


class TestPenTool:
    # ── Loader sanity ──────────────────────────────────────

    def test_pen_tool_loads_from_workspace(self):
        tool = _pen_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "pen"

    # ── 1. Three clicks + double-click -> open polyline ────

    def test_three_clicks_then_double_click_creates_polyline(self):
        tool = _pen_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        # Click, click, click — each mouseup lands mode=placing and leaves the
        # anchor in the buffer. Handles stay at anchor position (corner anchors).
        _click(tool, ctx, 10, 10)
        _click(tool, ctx, 50, 10)
        _click(tool, ctx, 50, 50)
        # Double-click (the second press pushed a fourth anchor; the dblclick
        # handler pops it, leaving 3 anchors), then double-clicks at (50,50).
        _click(tool, ctx, 50, 50)
        tool.on_double_click(ctx, 50, 50)

        pe = _committed_path(model)
        # MoveTo + 2 CurveTos (3 anchors -> 2 segments). No ClosePath because
        # dblclick commits open.
        assert len(pe.d) == 3
        assert isinstance(pe.d[0], MoveTo)
        assert pe.d[0].x == 10.0 and pe.d[0].y == 10.0
        assert isinstance(pe.d[1], CurveTo)
        assert isinstance(pe.d[2], CurveTo)
        assert not isinstance(pe.d[-1], ClosePath), (
            "dblclick should commit OPEN, but last command is ClosePath")

    # ── 2. Click-drag sets out-handle ──────────────────────

    def test_click_drag_sets_out_handle(self):
        tool = _pen_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        # First anchor: click + drag out to (60, 10). on_move sets the handle;
        # the first anchor's out = (60, 10), in mirrors to (-40, 10).
        tool.on_press(ctx, 10, 10, False, False)
        tool.on_move(ctx, 60, 10, False, False, True)
        tool.on_release(ctx, 60, 10, False, False)
        # Second anchor: plain click at (50, 50).
        _click(tool, ctx, 50, 50)
        # Escape commits open — exercising the on_keydown path too.
        tool.on_key_event(ctx, "Escape", KeyMods())

        pe = _committed_path(model)
        # d[0] = MoveTo(10,10); d[1] = CurveTo(prev_out=(60,10), curr_in=(50,50),
        # curr=(50,50)) because the second anchor is a corner.
        assert len(pe.d) == 2
        c = pe.d[1]
        assert isinstance(c, CurveTo)
        assert c.x1 == 60.0, "prev anchor out-handle x"
        assert c.y1 == 10.0, "prev anchor out-handle y"
        assert c.x == 50.0
        assert c.y == 50.0

    # ── 3. Click near first anchor closes ──────────────────

    def test_click_near_first_closes(self):
        tool = _pen_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        # Three corner anchors.
        _click(tool, ctx, 10, 10)
        _click(tool, ctx, 50, 10)
        _click(tool, ctx, 50, 50)
        # Fourth click within 8 px of the first anchor (10, 10).
        _click(tool, ctx, 11, 11)

        pe = _committed_path(model)
        # Should end with ClosePath.
        assert isinstance(pe.d[-1], ClosePath), (
            f"expected last command ClosePath, got {type(pe.d[-1]).__name__}")

    # ── 4. Escape via the canvas's actual key path ─────────

    def test_escape_via_shell_key_path_commits(self):
        # Regression guard for the canvas keyboard path. The Rust shell calls
        # tool.on_key() (NOT on_key_event); a YamlTool overriding only
        # on_key_event would miss Escape (the dx-serve bug that surfaced this).
        # This app's canvas dispatches Escape for a NON-CAPTURING tool via
        # canvas.py keyPressEvent -> on_key (returns False for the pen) -> the
        # Escape branch -> on_key_event(ctx, "Escape", mods) (canvas.py ~2238).
        # So on_key_event is exactly the entry point the canvas drives here.
        tool = _pen_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        _click(tool, ctx, 10, 10)
        _click(tool, ctx, 50, 50)
        # The canvas's actual Escape dispatch for a non-capturing tool.
        tool.on_key_event(ctx, "Escape", KeyMods())

        pe = _committed_path(model)
        assert isinstance(pe.d[0], MoveTo)
        assert not isinstance(pe.d[-1], ClosePath), (
            "Escape should commit OPEN, but last command is ClosePath")

    # ── 5. Escape with a single anchor discards ────────────

    def test_escape_without_enough_anchors_discards(self):
        tool = _pen_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        # One anchor — not enough to make a path (commit gates on
        # anchor_buffer_length('pen') >= 2).
        _click(tool, ctx, 10, 10)
        tool.on_key_event(ctx, "Escape", KeyMods())
        assert len(model.document.layers[0].children) == 0, (
            "single anchor should not produce a path")
