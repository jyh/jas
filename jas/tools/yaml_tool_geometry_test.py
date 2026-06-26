"""Geometry-tool gesture-seam tests — Python port of the Rust geometry seam
tests in jas_dioxus/src/tools/yaml_tool.rs (the ``rect_parity_*``,
``ellipse_parity_*``, ``rounded_rect_parity_*``, ``polygon_parity_*`` and
``star_parity_*`` families).

These drive the five production shape-drawing tools — ``rect``, ``ellipse``,
``rounded_rect``, ``polygon`` and ``star`` — loaded from the compiled workspace
bundle through the full gesture pipeline (on_press / on_move (dragging) /
on_release) and assert the externally-observable outcome: the committed element,
its exact geometry, and the child count.

All five tools fit the press→release bounding box and read NO app-level state,
so — unlike the blob-brush seam tests — there is no app-state seeding / bridge
step. Under the identity view used here doc coords == screen coords.

Seam mapping from Rust to this app (Python / PySide6):
    on_press            -> on_press(ctx, x, y, shift, alt)
    on_move(drag)       -> on_move(ctx, x, y, shift, alt, dragging)
    on_release          -> on_release(ctx, x, y, shift, alt)

Committed elements land at ``layers[0].children[0]``.

Element-type parity with Rust:
    rect / rounded_rect -> Element::Rect      <-> geometry.element.Rect
    ellipse             -> Element::Ellipse   <-> geometry.element.Ellipse
    polygon / star      -> Element::Polygon   <-> geometry.element.Polygon
The polygon AND the star both commit a Polygon element (the star is a 10-vertex
Polygon, not a dedicated Star element) — identical to the Rust port.
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
    Ellipse,
    Fill,
    Layer,
    Polygon,
    Rect,
    RgbColor,
    Stroke,
)
from tools.tool import ToolContext
from tools.yaml_tool import YamlTool


# ── Loader + harness helpers ───────────────────────────────


def _geometry_tool(tool_id: str) -> YamlTool | None:
    """Load ``tool_id``'s spec from the compiled workspace bundle and build a
    YamlTool, mirroring the loader in yaml_tool_line_test.py."""
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
    spec = tools.get(tool_id)
    return YamlTool.from_workspace_tool(spec) if spec else None


def _empty_layer_model() -> Model:
    """A document with a single empty top-level layer — the empty-layer model
    the Rust port builds (committed elements land at layers[0].children[0])."""
    layer = Layer(name="L", children=())
    return Model(document=Document(layers=(layer,)))


def _ctx(model: Model) -> ToolContext:
    """A faithful headless ToolContext over a live document, with inert
    hit-test callbacks (the geometry tools do no hit-testing). Mirrors the
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


# ── Rect tool ──────────────────────────────────────────────


class TestRectTool:
    def test_rect_tool_loads_from_workspace(self):
        tool = _geometry_tool("rect")
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "rect"

    def test_draw_rect(self):
        # Press (10,20) → drag (110,70) → release: 100×50 rect at (10,20).
        tool = _geometry_tool("rect")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 10.0, 20.0, False, False)
        tool.on_move(ctx, 110.0, 70.0, False, False, True)
        tool.on_release(ctx, 110.0, 70.0, False, False)

        children = _children(model)
        assert len(children) == 1, "draw commits exactly one element"
        el = children[0]
        assert isinstance(el, Rect), f"expected Rect, got {type(el).__name__}"
        assert el.x == 10.0
        assert el.y == 20.0
        assert el.width == 100.0
        assert el.height == 50.0

    def test_zero_size_rect_not_created(self):
        tool = _geometry_tool("rect")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 10.0, 20.0, False, False)
        tool.on_release(ctx, 10.0, 20.0, False, False)
        assert len(_children(model)) == 0

    def test_negative_drag_normalizes(self):
        # Press (100,80) → drag back to (10,20): normalized to
        # (10,20,90,60).
        tool = _geometry_tool("rect")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 100.0, 80.0, False, False)
        tool.on_move(ctx, 10.0, 20.0, False, False, True)
        tool.on_release(ctx, 10.0, 20.0, False, False)

        children = _children(model)
        assert len(children) == 1
        el = children[0]
        assert isinstance(el, Rect), f"expected Rect, got {type(el).__name__}"
        assert el.x == 10.0
        assert el.y == 20.0
        assert el.width == 90.0
        assert el.height == 60.0

    def test_uses_model_defaults(self):
        # A committed rect picks up the model's default fill / stroke.
        # Rust: default_fill = rgb(1,0,0); default_stroke = rgb(0,0,1) @ 3.
        tool = _geometry_tool("rect")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        model.default_fill = Fill(color=RgbColor(1.0, 0.0, 0.0))
        model.default_stroke = Stroke(color=RgbColor(0.0, 0.0, 1.0), width=3.0)
        ctx = _ctx(model)
        tool.on_press(ctx, 10.0, 20.0, False, False)
        tool.on_move(ctx, 110.0, 70.0, False, False, True)
        tool.on_release(ctx, 110.0, 70.0, False, False)

        children = _children(model)
        assert len(children) == 1
        el = children[0]
        assert isinstance(el, Rect), f"expected Rect, got {type(el).__name__}"
        assert el.fill == Fill(color=RgbColor(1.0, 0.0, 0.0))
        assert el.stroke == Stroke(color=RgbColor(0.0, 0.0, 1.0), width=3.0)


# ── Ellipse tool ───────────────────────────────────────────


class TestEllipseTool:
    def test_ellipse_tool_loads_from_workspace(self):
        tool = _geometry_tool("ellipse")
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "ellipse"

    def test_draw_ellipse(self):
        # bbox 100×50 → cx=60, cy=45, rx=50, ry=25.
        tool = _geometry_tool("ellipse")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 10.0, 20.0, False, False)
        tool.on_move(ctx, 110.0, 70.0, False, False, True)
        tool.on_release(ctx, 110.0, 70.0, False, False)

        children = _children(model)
        assert len(children) == 1
        el = children[0]
        assert isinstance(el, Ellipse), (
            f"expected Ellipse, got {type(el).__name__}")
        assert el.cx == 60.0
        assert el.cy == 45.0
        assert el.rx == 50.0
        assert el.ry == 25.0

    def test_zero_size_not_created(self):
        tool = _geometry_tool("ellipse")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 10.0, 20.0, False, False)
        tool.on_release(ctx, 10.0, 20.0, False, False)
        assert len(_children(model)) == 0

    def test_negative_drag_yields_positive_radii(self):
        # Press (100,80) → drag back (10,20): cx=55, cy=50, rx=45, ry=30.
        tool = _geometry_tool("ellipse")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 100.0, 80.0, False, False)
        tool.on_move(ctx, 10.0, 20.0, False, False, True)
        tool.on_release(ctx, 10.0, 20.0, False, False)

        children = _children(model)
        assert len(children) == 1
        el = children[0]
        assert isinstance(el, Ellipse), (
            f"expected Ellipse, got {type(el).__name__}")
        assert el.cx == 55.0
        assert el.cy == 50.0
        assert el.rx == 45.0
        assert el.ry == 30.0


# ── RoundedRect tool ───────────────────────────────────────


class TestRoundedRectTool:
    def test_rounded_rect_tool_loads_from_workspace(self):
        tool = _geometry_tool("rounded_rect")
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "rounded_rect"

    def test_draw_with_radius(self):
        # Commits a Rect with rx/ry > 0 (Rust asserts rx=ry=10).
        tool = _geometry_tool("rounded_rect")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 10.0, 20.0, False, False)
        tool.on_move(ctx, 110.0, 70.0, False, False, True)
        tool.on_release(ctx, 110.0, 70.0, False, False)

        children = _children(model)
        assert len(children) == 1
        el = children[0]
        assert isinstance(el, Rect), f"expected Rect, got {type(el).__name__}"
        assert el.x == 10.0
        assert el.y == 20.0
        assert el.width == 100.0
        assert el.height == 50.0
        assert el.rx == 10.0
        assert el.ry == 10.0

    def test_zero_size_not_created(self):
        tool = _geometry_tool("rounded_rect")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 10.0, 20.0, False, False)
        tool.on_release(ctx, 10.0, 20.0, False, False)
        assert len(_children(model)) == 0

    def test_negative_drag_normalizes(self):
        # Press (100,80) → drag back (10,20): (10,20,90,60), rx=10.
        tool = _geometry_tool("rounded_rect")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 100.0, 80.0, False, False)
        tool.on_move(ctx, 10.0, 20.0, False, False, True)
        tool.on_release(ctx, 10.0, 20.0, False, False)

        children = _children(model)
        assert len(children) == 1
        el = children[0]
        assert isinstance(el, Rect), f"expected Rect, got {type(el).__name__}"
        assert el.x == 10.0
        assert el.y == 20.0
        assert el.width == 90.0
        assert el.height == 60.0
        assert el.rx == 10.0


# ── Polygon tool ───────────────────────────────────────────


class TestPolygonTool:
    def test_polygon_tool_loads_from_workspace(self):
        tool = _geometry_tool("polygon")
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "polygon"

    def test_draw_polygon(self):
        # Drag → a Polygon element with 5 vertices (default pentagon).
        tool = _geometry_tool("polygon")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 50.0, 50.0, False, False)
        tool.on_move(ctx, 100.0, 50.0, False, False, True)
        tool.on_release(ctx, 100.0, 50.0, False, False)

        children = _children(model)
        assert len(children) == 1
        el = children[0]
        assert isinstance(el, Polygon), (
            f"expected Polygon, got {type(el).__name__}")
        assert len(el.points) == 5

    def test_short_drag_no_polygon(self):
        tool = _geometry_tool("polygon")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 50.0, 50.0, False, False)
        tool.on_release(ctx, 50.0, 50.0, False, False)
        assert len(_children(model)) == 0


# ── Star tool ──────────────────────────────────────────────


class TestStarTool:
    def test_star_tool_loads_from_workspace(self):
        tool = _geometry_tool("star")
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "star"

    def test_draw_star(self):
        # Drag → a Polygon element with 10 vertices
        # (5 outer × 2 alternating inner/outer). Star commits a Polygon,
        # not a dedicated Star element — matches the Rust port.
        tool = _geometry_tool("star")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 10.0, 20.0, False, False)
        tool.on_move(ctx, 110.0, 120.0, False, False, True)
        tool.on_release(ctx, 110.0, 120.0, False, False)

        children = _children(model)
        assert len(children) == 1
        el = children[0]
        assert isinstance(el, Polygon), (
            f"expected Polygon, got {type(el).__name__}")
        assert len(el.points) == 10

    def test_zero_size_not_created(self):
        tool = _geometry_tool("star")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 10.0, 20.0, False, False)
        tool.on_release(ctx, 10.0, 20.0, False, False)
        assert len(_children(model)) == 0

    def test_negative_drag_normalizes(self):
        # Press (100,100) → drag back (0,0): 10 vertices, first outer point
        # at top-center of the normalized bbox (center.x=50, top.y=0).
        tool = _geometry_tool("star")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 100.0, 100.0, False, False)
        tool.on_move(ctx, 0.0, 0.0, False, False, True)
        tool.on_release(ctx, 0.0, 0.0, False, False)

        children = _children(model)
        assert len(children) == 1
        el = children[0]
        assert isinstance(el, Polygon), (
            f"expected Polygon, got {type(el).__name__}")
        assert len(el.points) == 10
        assert abs(el.points[0][0] - 50.0) < 1e-9
        assert abs(el.points[0][1] - 0.0) < 1e-9
