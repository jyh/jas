"""Anchor-edit gesture-seam tests — Python port of the Rust anchor-edit seam
tests in jas_dioxus/src/tools/yaml_tool.rs (the ``anchor_point_parity_*``,
``add_anchor_parity_*`` and ``delete_anchor_parity_*`` families).

These drive the three production anchor-editing tools — ``anchor_point``,
``add_anchor_point`` and ``delete_anchor_point`` — loaded from the compiled
workspace bundle through the full gesture pipeline (on_press / on_release) and
assert the externally-observable outcome at the path-command level: the exact
PathCommand list (MoveTo / LineTo / CurveTo handle coordinates), the
smooth-vs-corner flag of an anchor, the child count of the layer, and whether
the edit produced an undo step.

Unlike the shape-drawing seam tests, these tools mutate an EXISTING path that
the fixture seeds into the document; the tools read no app-level ``state.*`` —
they locate the hit path directly off the live document — so there is no
app-state seeding / bridge step. Under the identity view used here doc coords
== screen coords.

Seam mapping from Rust to this app (Python / PySide6):
    on_press            -> on_press(ctx, x, y, shift, alt)
    on_release          -> on_release(ctx, x, y, shift, alt)

The fixtures reproduce the Rust ``model_with_smooth_three_anchor_path``,
``model_with_four_anchor_path`` and the corner-only / horizontal-line / single-
cubic helpers EXACTLY (same MoveTo / LineTo / CurveTo x1/y1/x2/y2/x/y), so the
asserted numbers match the Rust port byte-for-byte.

Element-type parity with Rust:
    every fixture is a single Element::Path  <-> geometry.element.Path
committed at ``layers[0].children[0]``.
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
    CurveTo,
    Layer,
    LineTo,
    MoveTo,
    Path,
    is_smooth_point,
)
from tools.tool import ToolContext
from tools.yaml_tool import YamlTool


# ── Loader + harness helpers ───────────────────────────────


def _anchor_tool(tool_id: str) -> YamlTool | None:
    """Load ``tool_id``'s spec from the compiled workspace bundle and build a
    YamlTool, mirroring the loader in yaml_tool_geometry_test.py."""
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


def _ctx(model: Model) -> ToolContext:
    """A faithful headless ToolContext over a live document, with inert
    hit-test callbacks (the anchor tools hit-test the document themselves).
    Mirrors the geometry seam-test harness ToolContext. The Controller shares
    the SAME Model instance so the effects' ``controller.model.begin_txn`` and
    ``model.can_undo`` observe one undo journal."""
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


def _path(model: Model) -> Path:
    el = _children(model)[0]
    assert isinstance(el, Path), f"expected Path, got {type(el).__name__}"
    return el


# ── Fixtures (exact ports of the Rust model_* builders) ────


def _model_with_smooth_three_anchor_path() -> Model:
    """Port of Rust ``model_with_smooth_three_anchor_path``: a single Path =
    MoveTo(0,0), CurveTo(10,20, 40,20, 50,0), CurveTo(60,-20, 90,-20, 100,0),
    fill=None, stroke=None, in one layer named "L", no selection. Anchor 1 (the
    middle anchor at (50,0)) is SMOOTH; its outgoing handle is at (60,-20)."""
    pe = Path(
        d=(
            MoveTo(0.0, 0.0),
            CurveTo(10.0, 20.0, 40.0, 20.0, 50.0, 0.0),
            CurveTo(60.0, -20.0, 90.0, -20.0, 100.0, 0.0),
        ),
        fill=None,
        stroke=None,
    )
    return Model(document=Document(layers=(Layer(name="L", children=(pe,)),)))


def _model_with_corner_three_anchor_path() -> Model:
    """Port of the corner-only path built inline in the Rust
    ``anchor_point_parity_drag_corner_pulls_out_smooth_handles`` test: a single
    Path = MoveTo(0,0), LineTo(50,0), LineTo(100,0) — all corner anchors."""
    pe = Path(
        d=(
            MoveTo(0.0, 0.0),
            LineTo(50.0, 0.0),
            LineTo(100.0, 0.0),
        ),
        fill=None,
        stroke=None,
    )
    return Model(document=Document(layers=(Layer(name="L", children=(pe,)),)))


def _model_with_horizontal_line_path() -> Model:
    """Port of Rust ``model_with_horizontal_line_path``: a single Path =
    MoveTo(0,0), LineTo(100,0), fill=None, stroke=None."""
    pe = Path(
        d=(
            MoveTo(0.0, 0.0),
            LineTo(100.0, 0.0),
        ),
        fill=None,
        stroke=None,
    )
    return Model(document=Document(layers=(Layer(name="L", children=(pe,)),)))


def _model_with_single_cubic_path() -> Model:
    """Port of the single-cubic path built inline in the Rust
    ``add_anchor_parity_click_on_curve_splits_it`` test: a single Path =
    MoveTo(0,0), CurveTo(25,50, 75,50, 100,0) — one cubic from (0,0) to
    (100,0) with symmetric handles."""
    pe = Path(
        d=(
            MoveTo(0.0, 0.0),
            CurveTo(25.0, 50.0, 75.0, 50.0, 100.0, 0.0),
        ),
        fill=None,
        stroke=None,
    )
    return Model(document=Document(layers=(Layer(name="L", children=(pe,)),)))


def _model_with_four_anchor_path() -> Model:
    """Port of Rust ``model_with_four_anchor_path``: a single Path =
    MoveTo(0,0), CurveTo(10,0, 20,0, 30,0), CurveTo(40,0, 50,0, 60,0),
    CurveTo(70,0, 80,0, 90,0) — four anchors at x = 0/30/60/90 on y=0."""
    pe = Path(
        d=(
            MoveTo(0.0, 0.0),
            CurveTo(10.0, 0.0, 20.0, 0.0, 30.0, 0.0),
            CurveTo(40.0, 0.0, 50.0, 0.0, 60.0, 0.0),
            CurveTo(70.0, 0.0, 80.0, 0.0, 90.0, 0.0),
        ),
        fill=None,
        stroke=None,
    )
    return Model(document=Document(layers=(Layer(name="L", children=(pe,)),)))


def _eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, t):
    """De Casteljau cubic eval — Python equivalent of the Rust
    ``geometry::path_ops::eval_cubic`` used to find the curve midpoint."""
    mt = 1.0 - t
    bx = (mt * mt * mt * x0 + 3 * mt * mt * t * x1
          + 3 * mt * t * t * x2 + t * t * t * x3)
    by = (mt * mt * mt * y0 + 3 * mt * mt * t * y1
          + 3 * mt * t * t * y2 + t * t * t * y3)
    return bx, by


# ── Anchor Point tool ──────────────────────────────────────


class TestAnchorPointTool:
    def test_anchor_point_tool_loads_from_workspace(self):
        tool = _anchor_tool("anchor_point")
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "anchor_point"

    def test_click_smooth_makes_corner(self):
        # Port of anchor_point_parity_click_smooth_makes_corner. The smooth
        # anchor lives at (50,0) — anchor index 1. A click (press+release at
        # the same point, no drag) converts it to a corner: is_smooth_point
        # false at that anchor, and the edit is undoable.
        tool = _anchor_tool("anchor_point")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_smooth_three_anchor_path()
        ctx = _ctx(model)
        tool.on_press(ctx, 50.0, 0.0, False, False)
        tool.on_release(ctx, 50.0, 0.0, False, False)

        pe = _path(model)
        assert not is_smooth_point(pe.d, 1), (
            "click on smooth anchor should convert it to corner")
        assert model.can_undo

    def test_drag_handle_moves_it(self):
        # Port of anchor_point_parity_drag_handle_moves_it. Press the OUTGOING
        # handle of anchor 1 at (60,-20), release at (70,-15). The outgoing
        # handle is x1/y1 of cmd[2]; it moves to (70,-15). The INCOMING handle
        # of anchor 1 is x2/y2 of cmd[1]; it stays UNCHANGED at (40,20) — the
        # move is independent (no symmetric mirroring).
        tool = _anchor_tool("anchor_point")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_smooth_three_anchor_path()
        ctx = _ctx(model)
        tool.on_press(ctx, 60.0, -20.0, False, False)
        tool.on_release(ctx, 70.0, -15.0, False, False)

        pe = _path(model)
        c2 = pe.d[2]
        assert isinstance(c2, CurveTo)
        assert abs(c2.x1 - 70.0) < 0.01
        assert abs(c2.y1 - (-15.0)) < 0.01
        c1 = pe.d[1]
        assert isinstance(c1, CurveTo)
        assert abs(c1.x2 - 40.0) < 0.01
        assert abs(c1.y2 - 20.0) < 0.01

    def test_drag_corner_pulls_out_smooth_handles(self):
        # Port of anchor_point_parity_drag_corner_pulls_out_smooth_handles.
        # A corner-only path; dragging the corner anchor at (50,0) to (50,30)
        # pulls out symmetric smooth handles — anchor 1 becomes smooth.
        tool = _anchor_tool("anchor_point")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_corner_three_anchor_path()
        ctx = _ctx(model)
        tool.on_press(ctx, 50.0, 0.0, False, False)
        tool.on_release(ctx, 50.0, 30.0, False, False)

        pe = _path(model)
        assert is_smooth_point(pe.d, 1)

    def test_click_without_hit_is_noop(self):
        # Port of anchor_point_parity_click_without_hit_is_noop. A click far
        # from any anchor or handle changes nothing — no undo step.
        tool = _anchor_tool("anchor_point")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_smooth_three_anchor_path()
        ctx = _ctx(model)
        tool.on_press(ctx, 500.0, 500.0, False, False)
        tool.on_release(ctx, 500.0, 500.0, False, False)
        assert not model.can_undo


# ── Add Anchor Point tool ──────────────────────────────────


class TestAddAnchorPointTool:
    def test_add_anchor_point_tool_loads_from_workspace(self):
        tool = _anchor_tool("add_anchor_point")
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "add_anchor_point"

    def test_click_on_line_inserts_midpoint(self):
        # Port of add_anchor_parity_click_on_line_inserts_midpoint. Clicking at
        # (50,0) — exactly on the horizontal line at t=0.5 — subdivides the
        # segment: the path becomes MoveTo, LineTo(50,0), LineTo(100,0), and
        # the insert is undoable.
        tool = _anchor_tool("add_anchor_point")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_horizontal_line_path()
        ctx = _ctx(model)
        tool.on_press(ctx, 50.0, 0.0, False, False)
        tool.on_release(ctx, 50.0, 0.0, False, False)

        pe = _path(model)
        assert len(pe.d) == 3
        mid = pe.d[1]
        assert isinstance(mid, LineTo), "expected inserted LineTo at midpoint"
        assert abs(mid.x - 50.0) < 0.01
        assert abs(mid.y) < 0.01
        assert model.can_undo

    def test_click_far_from_path_is_noop(self):
        # Port of add_anchor_parity_click_far_from_path_is_noop. A click far
        # off the path leaves it unchanged (still 2 commands), no undo step.
        tool = _anchor_tool("add_anchor_point")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_horizontal_line_path()
        ctx = _ctx(model)
        tool.on_press(ctx, 500.0, 500.0, False, False)
        tool.on_release(ctx, 500.0, 500.0, False, False)

        pe = _path(model)
        assert len(pe.d) == 2
        assert not model.can_undo

    def test_click_on_curve_splits_it(self):
        # Port of add_anchor_parity_click_on_curve_splits_it. A single cubic
        # from (0,0) to (100,0) with handles (25,50)/(75,50). Clicking at the
        # curve's t=0.5 midpoint splits it into two CurveTos: the path becomes
        # MoveTo + 2 CurveTos, and the first CurveTo's endpoint is the midpoint.
        tool = _anchor_tool("add_anchor_point")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_single_cubic_path()
        ctx = _ctx(model)
        mid_x, mid_y = _eval_cubic(
            0.0, 0.0, 25.0, 50.0, 75.0, 50.0, 100.0, 0.0, 0.5)
        tool.on_press(ctx, mid_x, mid_y, False, False)
        tool.on_release(ctx, mid_x, mid_y, False, False)

        pe = _path(model)
        assert len(pe.d) == 3
        assert isinstance(pe.d[1], CurveTo)
        assert isinstance(pe.d[2], CurveTo)
        assert abs(pe.d[1].x - mid_x) < 0.1
        assert abs(pe.d[1].y - mid_y) < 0.1


# ── Delete Anchor Point tool ───────────────────────────────


class TestDeleteAnchorPointTool:
    def test_delete_anchor_point_tool_loads_from_workspace(self):
        tool = _anchor_tool("delete_anchor_point")
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "delete_anchor_point"

    def test_click_on_interior_removes_anchor(self):
        # Port of delete_anchor_parity_click_on_interior_removes_anchor.
        # Clicking on the interior anchor at (60,0) — command index 2 of the
        # four-anchor path — removes it and re-fits the neighbours: the path
        # still exists (one child) and goes from 4 anchors to 3. Undoable.
        tool = _anchor_tool("delete_anchor_point")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_four_anchor_path()
        ctx = _ctx(model)
        tool.on_press(ctx, 60.0, 0.0, False, False)
        tool.on_release(ctx, 60.0, 0.0, False, False)

        children = _children(model)
        assert len(children) == 1, "path should still exist"
        pe = children[0]
        assert isinstance(pe, Path)
        assert len(pe.d) == 3
        assert model.can_undo, "delete should be undoable"

    def test_click_empty_is_noop(self):
        # Port of delete_anchor_parity_click_empty_is_noop. A click on empty
        # space leaves the path unchanged (still 4 commands), no undo step.
        tool = _anchor_tool("delete_anchor_point")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_four_anchor_path()
        ctx = _ctx(model)
        tool.on_press(ctx, 500.0, 500.0, False, False)
        tool.on_release(ctx, 500.0, 500.0, False, False)

        pe = _path(model)
        assert len(pe.d) == 4
        assert not model.can_undo
