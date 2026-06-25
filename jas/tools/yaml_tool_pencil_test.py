"""Pencil-tool behavioral tests — Python port of the Rust pencil seam tests in
jas_dioxus/src/tools/yaml_tool.rs (the ``pencil_parity_*`` family).

These cover the externally-observable outcomes of the YAML-driven pencil tool
loaded from the compiled workspace bundle: a freehand drag fits a smooth Bezier
path (MoveTo + CurveTos), a click without a drag still commits a degenerate
path, the committed Path carries a stroke and no fill, a release with no prior
press is a no-op, and the path starts at the press point.

Seam mapping from Rust to this app (Python / PySide6):
    on_press        -> on_press(ctx, x, y, shift, alt)
    on_move(drag)   -> on_move(ctx, x, y, shift, alt, dragging)
    on_release      -> on_release(ctx, x, y, shift, alt)

Mirrors the empty-layer model the Rust port builds: committed paths land at
``layers[0].children[0]``. The committed element is a Path whose ``d`` is a
tuple of path commands (MoveTo / CurveTo dataclasses from geometry.element).
"""

from __future__ import annotations

import json
import math
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
    CurveTo, Layer, MoveTo, Path,
)
from tools.tool import ToolContext
from tools.yaml_tool import YamlTool


# ── Loader + harness helpers ───────────────────────────────


def _pencil_tool() -> YamlTool | None:
    """Load the "pencil" spec from the compiled workspace bundle and build a
    YamlTool, mirroring the pen-tool loader in yaml_tool_pen_test.py."""
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
    spec = tools.get("pencil")
    return YamlTool.from_workspace_tool(spec) if spec else None


def _empty_layer_model() -> Model:
    """A document with a single empty top-level layer — the empty-layer model
    the Rust port builds (committed paths land at layers[0].children[0])."""
    layer = Layer(name="L", children=())
    return Model(document=Document(layers=(layer,)))


def _ctx(model: Model) -> ToolContext:
    """A faithful headless ToolContext over a live document, with inert
    hit-test callbacks (the pencil tool does no hit-testing). Mirrors the
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


def _committed_path(model: Model) -> Path:
    children = model.document.layers[0].children
    assert len(children) == 1, f"expected exactly one child, got {len(children)}"
    el = children[0]
    assert isinstance(el, Path), f"expected Path, got {type(el).__name__}"
    return el


class TestPencilTool:
    # ── Loader sanity ──────────────────────────────────────

    def test_pencil_tool_loads_from_workspace(self):
        tool = _pencil_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "pencil"

    # ── 1. Freehand draw -> smooth Bezier path ─────────────

    def test_freehand_draw_creates_path(self):
        tool = _pencil_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 0.0, 0.0, False, False)
        for i in range(1, 21):
            x = i * 5.0
            y = math.sin(i * 0.1) * 20.0
            tool.on_move(ctx, x, y, False, False, True)
        tool.on_release(ctx, 100.0, 0.0, False, False)

        pe = _committed_path(model)
        # MoveTo + at least one CurveTo from fitting the freehand samples.
        assert len(pe.d) >= 2, (
            "path should have MoveTo + at least one CurveTo")
        assert isinstance(pe.d[0], MoveTo)
        for cmd in pe.d[1:]:
            assert isinstance(cmd, CurveTo), (
                f"every command after MoveTo should be CurveTo, "
                f"got {type(cmd).__name__}")

    # ── 2. Click-without-drag degenerate path ──────────────

    def test_click_without_drag_creates_degenerate_path(self):
        tool = _pencil_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        # Press + release at the same point — on_release pushes the final
        # point, giving the buffer 2 identical points. Fitting returns one
        # degenerate segment, which still lands a Path.
        tool.on_press(ctx, 10.0, 20.0, False, False)
        tool.on_release(ctx, 10.0, 20.0, False, False)
        assert len(model.document.layers[0].children) == 1, (
            "degenerate point should still commit a single Path")

    # ── 3. Committed path uses model defaults (stroke, no fill) ─

    def test_path_uses_model_defaults(self):
        tool = _pencil_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 0.0, 0.0, False, False)
        tool.on_move(ctx, 50.0, 50.0, False, False, True)
        tool.on_release(ctx, 100.0, 0.0, False, False)

        pe = _committed_path(model)
        assert pe.stroke is not None, "pencil path should have a stroke"
        assert pe.fill is None, "pencil path should have no fill"

    # ── 4. Release without press is a no-op ────────────────

    def test_release_without_press_is_noop(self):
        tool = _pencil_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_release(ctx, 50.0, 60.0, False, False)
        assert len(model.document.layers[0].children) == 0, (
            "release with no prior press should create no children")

    # ── 5. Path starts at the press point ──────────────────

    def test_path_starts_at_press_point(self):
        tool = _pencil_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 15.0, 25.0, False, False)
        tool.on_move(ctx, 50.0, 50.0, False, False, True)
        tool.on_release(ctx, 100.0, 0.0, False, False)

        pe = _committed_path(model)
        assert isinstance(pe.d[0], MoveTo), "first command should be MoveTo"
        assert pe.d[0].x == 15.0
        assert pe.d[0].y == 25.0
