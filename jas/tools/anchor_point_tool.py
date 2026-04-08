"""Anchor Point (Convert) tool.

Three interactions, mirroring jas_dioxus/src/tools/anchor_point_tool.rs:

- Drag on a corner anchor: pull out symmetric handles -> smooth.
- Click on a smooth anchor: collapse handles to anchor -> corner.
- Drag on a control handle: move it independently -> cusp.

Hit-test priority: handles before anchors.
"""

from __future__ import annotations

import dataclasses
import math
from typing import TYPE_CHECKING

from geometry.element import (
    ClosePath, CurveTo, LineTo, MoveTo, Path, PathCommand,
    convert_corner_to_smooth, convert_smooth_to_corner,
    is_smooth_point, move_path_handle_independent, path_handle_positions,
)
from document.document import ElementSelection
from tools.tool import CanvasTool, HIT_RADIUS

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter
    from tools.tool import ToolContext


def _anchor_points(d: tuple[PathCommand, ...]) -> list[tuple[float, float]]:
    """Anchor positions of a path, indexed by anchor index (closePath skipped)."""
    pts: list[tuple[float, float]] = []
    for cmd in d:
        if isinstance(cmd, ClosePath):
            continue
        if isinstance(cmd, (MoveTo, LineTo)):
            pts.append((cmd.x, cmd.y))
        elif isinstance(cmd, CurveTo):
            pts.append((cmd.x, cmd.y))
        else:
            # Other path command types: use endpoint via attribute access.
            x = getattr(cmd, "x", None)
            y = getattr(cmd, "y", None)
            if x is not None and y is not None:
                pts.append((x, y))
    return pts


def _find_anchor_idx_at(
    d: tuple[PathCommand, ...], px: float, py: float,
) -> int | None:
    """Find the anchor index of a point near (px, py)."""
    for i, (ax, ay) in enumerate(_anchor_points(d)):
        if math.hypot(px - ax, py - ay) < HIT_RADIUS:
            return i
    return None


def _find_handle_at(
    d: tuple[PathCommand, ...], px: float, py: float,
) -> tuple[int, str, float, float] | None:
    """Find a handle (anchor_idx, handle_type, hx, hy) near (px, py)."""
    n = len(_anchor_points(d))
    for ai in range(n):
        h_in, h_out = path_handle_positions(d, ai)
        if h_in is not None:
            hx, hy = h_in
            if math.hypot(px - hx, py - hy) < HIT_RADIUS:
                return (ai, "in", hx, hy)
        if h_out is not None:
            hx, hy = h_out
            if math.hypot(px - hx, py - hy) < HIT_RADIUS:
                return (ai, "out", hx, hy)
    return None


def _each_path(ctx: ToolContext):
    """Yield (path_tuple, element) for every Path element, walking one
    level into unlocked groups."""
    from geometry.element import Group
    doc = ctx.model.document
    for li, layer in enumerate(doc.layers):
        for ci, child in enumerate(layer.children):
            if isinstance(child, Path):
                yield (li, ci), child
            elif isinstance(child, Group) and not child.locked:
                for gi, gc in enumerate(child.children):
                    if isinstance(gc, Path):
                        yield (li, ci, gi), gc


def _hit_test_anchor(
    ctx: ToolContext, x: float, y: float,
) -> tuple[tuple[int, ...], Path, int] | None:
    for path, pe in _each_path(ctx):
        idx = _find_anchor_idx_at(pe.d, x, y)
        if idx is not None:
            return path, pe, idx
    return None


def _hit_test_handle(
    ctx: ToolContext, x: float, y: float,
) -> tuple[tuple[int, ...], Path, int, str, float, float] | None:
    for path, pe in _each_path(ctx):
        hit = _find_handle_at(pe.d, x, y)
        if hit is not None:
            ai, ht, hx, hy = hit
            return path, pe, ai, ht, hx, hy
    return None


def _select_all_cps(ctx: ToolContext, path: tuple[int, ...]) -> None:
    doc = ctx.model.document
    new_sel_entry = ElementSelection.all(path)
    new_selection = frozenset(es for es in doc.selection if es.path != path) | {new_sel_entry}
    ctx.model.document = dataclasses.replace(doc, selection=new_selection)


def _replace(ctx: ToolContext, path: tuple[int, ...], pe: Path, new_pe: Path) -> None:
    doc = ctx.model.document.replace_element(path, new_pe)
    ctx.model.document = doc
    ctx.request_update()


class AnchorPointTool(CanvasTool):
    """Convert anchor points between smooth, corner, and cusp states."""

    def __init__(self) -> None:
        # State is one of:
        #   None
        #   ("dragging_corner", path, pe, anchor_idx, sx, sy)
        #   ("dragging_handle", path, pe, anchor_idx, handle_type, shx, shy)
        #   ("pressed_smooth", path, pe, anchor_idx, sx, sy)
        self._state: tuple | None = None

    def on_press(
        self, ctx: ToolContext, x: float, y: float,
        shift: bool = False, alt: bool = False,
    ) -> None:
        # Handle hit takes priority (cusp behaviour).
        h = _hit_test_handle(ctx, x, y)
        if h is not None:
            path, pe, ai, ht, hx, hy = h
            self._state = ("dragging_handle", path, pe, ai, ht, hx, hy)
            return
        a = _hit_test_anchor(ctx, x, y)
        if a is None:
            return
        path, pe, ai = a
        if is_smooth_point(pe.d, ai):
            self._state = ("pressed_smooth", path, pe, ai, x, y)
        else:
            self._state = ("dragging_corner", path, pe, ai, x, y)

    def on_move(
        self, ctx: ToolContext, x: float, y: float,
        shift: bool = False, dragging: bool = False,
    ) -> None:
        if not dragging or self._state is None:
            return
        kind = self._state[0]
        if kind == "dragging_corner":
            _, path, pe, ai, _sx, _sy = self._state
            new_pe = convert_corner_to_smooth(pe, ai, x, y)
            _replace(ctx, path, pe, new_pe)
        elif kind == "dragging_handle":
            _, path, pe, ai, ht, shx, shy = self._state
            dx = x - shx
            dy = y - shy
            new_pe = move_path_handle_independent(pe, ai, ht, dx, dy)
            _replace(ctx, path, pe, new_pe)
        elif kind == "pressed_smooth":
            _, path, pe, ai, sx, sy = self._state
            if math.hypot(x - sx, y - sy) > 3.0:
                corner_pe = convert_smooth_to_corner(pe, ai)
                new_pe = convert_corner_to_smooth(corner_pe, ai, x, y)
                _replace(ctx, path, pe, new_pe)
                self._state = ("dragging_corner", path, corner_pe, ai, sx, sy)

    def on_release(
        self, ctx: ToolContext, x: float, y: float,
        shift: bool = False, alt: bool = False,
    ) -> None:
        s = self._state
        self._state = None
        if s is None:
            return
        kind = s[0]
        if kind == "pressed_smooth":
            _, path, pe, ai, _sx, _sy = s
            ctx.snapshot()
            new_pe = convert_smooth_to_corner(pe, ai)
            _replace(ctx, path, pe, new_pe)
            _select_all_cps(ctx, path)
        elif kind == "dragging_corner":
            _, path, pe, ai, sx, sy = s
            if math.hypot(x - sx, y - sy) > 1.0:
                ctx.snapshot()
                new_pe = convert_corner_to_smooth(pe, ai, x, y)
                _replace(ctx, path, pe, new_pe)
                _select_all_cps(ctx, path)
        elif kind == "dragging_handle":
            _, path, pe, ai, ht, shx, shy = s
            dx = x - shx
            dy = y - shy
            if abs(dx) > 0.5 or abs(dy) > 0.5:
                ctx.snapshot()
                new_pe = move_path_handle_independent(pe, ai, ht, dx, dy)
                _replace(ctx, path, pe, new_pe)
                _select_all_cps(ctx, path)

    def draw_overlay(self, ctx: ToolContext, painter: "QPainter") -> None:
        pass
