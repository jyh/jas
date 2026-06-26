"""Line-tool gesture-seam tests — Python port of the Rust line seam tests in
jas_dioxus/src/tools/yaml_tool.rs (the ``line_parity_*`` family).

These drive the production ``line`` tool loaded from the compiled workspace
bundle through the full gesture pipeline — on_press / on_move / on_release — and
assert the externally-observable outcomes (the committed Line element + the
tool's "mode" state).

The line tool is SIMPLE: a press-drag-release commits a single Line whose
endpoints are the press point (x1,y1) and the release point (x2,y2) in doc
space; under the identity view used here doc coords == screen coords. A drag
whose endpoint-to-endpoint distance (hypot) is shorter than 2px is rejected. The
tool reads NO app-level state, so — unlike the blob-brush seam tests — there is
no app-state seeding/bridge step.

Seam mapping from Rust to this app (Python / PySide6):
    on_press            -> on_press(ctx, x, y, shift, alt)
    on_move(drag)       -> on_move(ctx, x, y, shift, alt, dragging)
    on_release          -> on_release(ctx, x, y, shift, alt)
    tool_state("mode")  -> tool.tool_state("mode")

Committed lines land at ``layers[0].children[0]``.
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
from geometry.element import Layer, Line
from tools.tool import ToolContext
from tools.yaml_tool import YamlTool


# ── Loader + harness helpers ───────────────────────────────


def _line_tool() -> YamlTool | None:
    """Load the "line" spec from the compiled workspace bundle and build a
    YamlTool, mirroring the loader in yaml_tool_blob_brush_test.py."""
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
    spec = tools.get("line")
    return YamlTool.from_workspace_tool(spec) if spec else None


def _empty_layer_model() -> Model:
    """A document with a single empty top-level layer — the empty-layer model
    the Rust port builds (committed lines land at layers[0].children[0])."""
    layer = Layer(name="L", children=())
    return Model(document=Document(layers=(layer,)))


def _ctx(model: Model) -> ToolContext:
    """A faithful headless ToolContext over a live document, with inert
    hit-test callbacks (the line tool does no hit-testing). Mirrors the
    seam-test harness ToolContext."""
    return ToolContext(
        model=model,
        controller=Controller(model=model),
        hit_test_selection=lambda x, y: False,
        hit_test_handle=lambda x, y: None,
        hit_test_text=lambda x, y: None,
        hit_test_path_curve=lambda x, y: None,
        request_update=lambda: None,
    )


def _children(model: Model):
    return model.document.layers[0].children


class TestLineTool:
    # ── Loader sanity (non-vacuity guard) ──────────────────

    def test_line_tool_loads_from_workspace(self):
        tool = _line_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "line"

    # ── 1. Draw line commits exactly one Line element ──────

    def test_draw_line(self):
        tool = _line_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 10.0, 20.0, False, False)
        tool.on_move(ctx, 30.0, 40.0, False, False, True)
        tool.on_release(ctx, 50.0, 60.0, False, False)

        children = _children(model)
        assert len(children) == 1, "draw commits exactly one element"
        le = children[0]
        assert isinstance(le, Line), f"expected Line, got {type(le).__name__}"
        assert le.x1 == 10.0
        assert le.y1 == 20.0
        assert le.x2 == 50.0
        assert le.y2 == 60.0

    # ── 2. Zero-length drag commits nothing ────────────────

    def test_short_line_not_created(self):
        tool = _line_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        # Press and release at same point — hypot distance = 0.
        tool.on_press(ctx, 10.0, 20.0, False, False)
        tool.on_release(ctx, 10.0, 20.0, False, False)
        assert len(_children(model)) == 0, (
            "a drag shorter than 2px is rejected — no line committed")

    # ── 3. Mode latches drawing on press, idle on release ──

    def test_idle_after_release(self):
        tool = _line_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        assert tool.tool_state("mode") == "idle"
        tool.on_press(ctx, 10.0, 20.0, False, False)
        assert tool.tool_state("mode") == "drawing"
        tool.on_release(ctx, 50.0, 60.0, False, False)
        assert tool.tool_state("mode") == "idle"

    # ── 4. Move without a prior press is a no-op ───────────

    def test_move_without_press_is_noop(self):
        tool = _line_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        # on_move's handler is guarded by mode == "drawing"; without a prior
        # on_press, mode stays "idle" and nothing happens.
        tool.on_move(ctx, 50.0, 60.0, False, False, True)
        assert tool.tool_state("mode") == "idle"
        assert len(_children(model)) == 0, "no element committed by a bare move"
