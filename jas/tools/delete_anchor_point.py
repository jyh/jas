"""Delete Anchor Point tool.

Clicking on an anchor point removes it from the path, merging the
adjacent segments into a single curve that preserves the outer
control handles.
"""

from __future__ import annotations

import dataclasses
import math
from typing import TYPE_CHECKING

from geometry.element import (
    ClosePath, CurveTo, LineTo, MoveTo, Path, PathCommand,
    control_point_count,
)
from document.document import ElementSelection
from tools.tool import CanvasTool, HIT_RADIUS

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter
    from tools.tool import ToolContext


def _find_anchor_at(
    d: tuple[PathCommand, ...], px: float, py: float, threshold: float,
) -> int | None:
    """Find the command index of an anchor point near (px, py)."""
    for i, cmd in enumerate(d):
        if isinstance(cmd, (MoveTo, LineTo, CurveTo)):
            ax, ay = cmd.x, cmd.y
        else:
            continue
        dist = math.sqrt((px - ax) ** 2 + (py - ay) ** 2)
        if dist <= threshold:
            return i
    return None


def _hit_test_anchor(
    ctx: ToolContext, x: float, y: float,
) -> tuple[tuple[int, ...], Path, int] | None:
    """Find an existing anchor point on any path near (x, y)."""
    doc = ctx.model.document
    threshold = HIT_RADIUS
    for li, layer in enumerate(doc.layers):
        for ci, child in enumerate(layer.children):
            if isinstance(child, Path):
                idx = _find_anchor_at(child.d, x, y, threshold)
                if idx is not None:
                    return (li, ci), child, idx
    return None


def _delete_anchor_from_path(
    d: tuple[PathCommand, ...], anchor_idx: int,
) -> tuple[PathCommand, ...] | None:
    """Delete the anchor at anchor_idx, merging adjacent segments.

    Returns None if the resulting path would have fewer than 2 anchors
    (i.e. the path should be removed entirely).
    """
    anchor_count = sum(
        1 for cmd in d if isinstance(cmd, (MoveTo, LineTo, CurveTo))
    )
    if anchor_count <= 2:
        return None

    cmds = list(d)

    # Case 1: Deleting the first point (MoveTo at index 0)
    if anchor_idx == 0:
        if len(cmds) > 1:
            nxt = cmds[1]
            result = [MoveTo(x=nxt.x, y=nxt.y)]
            result.extend(cmds[2:])
            return tuple(result)
        return None

    # Case 2: Deleting the last anchor point
    last_idx = len(cmds) - 1
    effective_last = last_idx - 1 if isinstance(cmds[last_idx], ClosePath) else last_idx
    if anchor_idx == effective_last:
        result = list(cmds[:anchor_idx])
        if effective_last < last_idx:
            result.append(ClosePath())
        return tuple(result)

    # Case 3: Deleting an interior anchor - merge adjacent segments
    cmd_at = cmds[anchor_idx]
    cmd_after = cmds[anchor_idx + 1]
    result = []

    for i, cmd in enumerate(cmds):
        if i == anchor_idx:
            # Merge this and the next command
            if isinstance(cmd_at, CurveTo) and isinstance(cmd_after, CurveTo):
                result.append(CurveTo(
                    x1=cmd_at.x1, y1=cmd_at.y1,
                    x2=cmd_after.x2, y2=cmd_after.y2,
                    x=cmd_after.x, y=cmd_after.y,
                ))
            elif isinstance(cmd_at, CurveTo) and isinstance(cmd_after, LineTo):
                result.append(CurveTo(
                    x1=cmd_at.x1, y1=cmd_at.y1,
                    x2=cmd_after.x, y2=cmd_after.y,
                    x=cmd_after.x, y=cmd_after.y,
                ))
            elif isinstance(cmd_at, LineTo) and isinstance(cmd_after, CurveTo):
                prev_cmd = cmds[anchor_idx - 1] if anchor_idx > 0 else None
                px = prev_cmd.x if prev_cmd else 0.0
                py = prev_cmd.y if prev_cmd else 0.0
                result.append(CurveTo(
                    x1=px, y1=py,
                    x2=cmd_after.x2, y2=cmd_after.y2,
                    x=cmd_after.x, y=cmd_after.y,
                ))
            elif isinstance(cmd_at, LineTo) and isinstance(cmd_after, LineTo):
                result.append(LineTo(x=cmd_after.x, y=cmd_after.y))
            continue
        if i == anchor_idx + 1:
            continue
        result.append(cmd)

    return tuple(result)


class DeleteAnchorPointTool(CanvasTool):
    def on_press(
        self, ctx: ToolContext, x: float, y: float,
        shift: bool = False, alt: bool = False,
    ) -> None:
        hit = _hit_test_anchor(ctx, x, y)
        if hit is None:
            return

        elem_path, pe, anchor_idx = hit
        ctx.snapshot()
        new_cmds = _delete_anchor_from_path(pe.d, anchor_idx)
        if new_cmds is not None:
            new_elem = dataclasses.replace(pe, d=new_cmds)
            doc = ctx.model.document.replace_element(elem_path, new_elem)
            # Select all remaining control points
            cp_count = control_point_count(new_elem)
            all_cps = frozenset(range(cp_count))
            new_sel_entry = ElementSelection(
                path=elem_path, control_points=all_cps)
            new_selection = frozenset(
                (new_sel_entry if es.path == elem_path else es)
                for es in doc.selection
            ) | frozenset({new_sel_entry})
            doc = dataclasses.replace(doc, selection=new_selection)
            ctx.model.document = doc
        else:
            # Path too small - remove entirely
            doc = ctx.model.document.delete_element(elem_path)
            ctx.model.document = doc
        ctx.request_update()

    def on_move(
        self, ctx: ToolContext, x: float, y: float,
        shift: bool = False, dragging: bool = False,
    ) -> None:
        pass

    def on_release(
        self, ctx: ToolContext, x: float, y: float,
        shift: bool = False, alt: bool = False,
    ) -> None:
        pass

    def draw_overlay(self, ctx: ToolContext, painter: "QPainter") -> None:
        pass
