"""Path Eraser tool for splitting and removing path segments.

When dragged over a path, the eraser splits the path at the drag area,
creating two endpoints on either side. Closed paths become open; open paths
become two separate paths. Paths with bounding boxes smaller than the eraser
size are deleted entirely.
"""

from __future__ import annotations

from dataclasses import replace
from typing import TYPE_CHECKING

from geometry.element import (
    ClosePath, CurveTo, LineTo, MoveTo, Path, PathCommand,
    flatten_path_commands,
)
from tools.tool import CanvasTool, ToolContext

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter

ERASER_SIZE = 2.0
_FLATTEN_STEPS = 20


class PathEraserTool(CanvasTool):
    def __init__(self):
        self._erasing = False
        self._last_pos = (0.0, 0.0)

    def on_press(self, ctx: ToolContext, x: float, y: float,
                 shift: bool = False, alt: bool = False) -> None:
        ctx.snapshot()
        self._erasing = True
        self._last_pos = (x, y)
        self._erase_at(ctx, x, y)

    def on_move(self, ctx: ToolContext, x: float, y: float,
                shift: bool = False, dragging: bool = False) -> None:
        if self._erasing:
            self._erase_at(ctx, x, y)
            self._last_pos = (x, y)

    def on_release(self, ctx: ToolContext, x: float, y: float,
                   shift: bool = False, alt: bool = False) -> None:
        self._erasing = False

    def draw_overlay(self, ctx: ToolContext, painter: "QPainter") -> None:
        if not self._erasing:
            return
        from PySide6.QtCore import QPointF
        from PySide6.QtGui import QColor, QPen
        x, y = self._last_pos
        painter.setPen(QPen(QColor(255, 0, 0, 128), 1.0))
        painter.setBrush(QColor(0, 0, 0, 0))
        painter.drawEllipse(QPointF(x, y), ERASER_SIZE, ERASER_SIZE)

    def _erase_at(self, ctx: ToolContext, x: float, y: float) -> None:
        doc = ctx.model.document
        half = ERASER_SIZE
        eraser_min_x = min(self._last_pos[0], x) - half
        eraser_min_y = min(self._last_pos[1], y) - half
        eraser_max_x = max(self._last_pos[0], x) + half
        eraser_max_y = max(self._last_pos[1], y) + half

        changed = False
        new_layers = list(doc.layers)

        for li, layer in enumerate(doc.layers):
            children = list(layer.children)
            new_children = []
            layer_changed = False

            for child in children:
                if not isinstance(child, Path) or getattr(child, 'locked', False):
                    new_children.append(child)
                    continue

                flat = flatten_path_commands(child.d)
                if len(flat) < 2:
                    new_children.append(child)
                    continue

                hit_idx = _find_hit_segment(flat, eraser_min_x, eraser_min_y,
                                            eraser_max_x, eraser_max_y)
                if hit_idx is None:
                    new_children.append(child)
                    continue

                # Check if bbox is smaller than eraser.
                bounds = child.bounds()
                if bounds[2] <= ERASER_SIZE * 2.0 and bounds[3] <= ERASER_SIZE * 2.0:
                    layer_changed = True
                    continue  # delete

                is_closed = any(isinstance(c, ClosePath) for c in child.d)
                results = _split_path_at_segment(child.d, hit_idx, is_closed)

                for cmds in results:
                    if len(cmds) >= 2:
                        new_path = replace(child, d=tuple(cmds))
                        # Remove ClosePath if present (path is now open).
                        new_d = tuple(c for c in new_path.d if not isinstance(c, ClosePath))
                        new_path = replace(new_path, d=new_d)
                        new_children.append(new_path)
                layer_changed = True

            if layer_changed:
                new_layers[li] = replace(layer, children=tuple(new_children))
                changed = True

        if changed:
            new_doc = replace(doc, layers=tuple(new_layers), selection=())
            ctx.model.document = new_doc
            ctx.request_update()


def _find_hit_segment(flat, min_x, min_y, max_x, max_y):
    for i in range(len(flat) - 1):
        x1, y1 = flat[i]
        x2, y2 = flat[i + 1]
        if _line_segment_intersects_rect(x1, y1, x2, y2, min_x, min_y, max_x, max_y):
            return i
    return None


def _line_segment_intersects_rect(x1, y1, x2, y2, min_x, min_y, max_x, max_y):
    if min_x <= x1 <= max_x and min_y <= y1 <= max_y:
        return True
    if min_x <= x2 <= max_x and min_y <= y2 <= max_y:
        return True
    # Liang-Barsky clipping.
    t_min, t_max = 0.0, 1.0
    dx, dy = x2 - x1, y2 - y1
    for p, q in [(-dx, x1 - min_x), (dx, max_x - x1),
                 (-dy, y1 - min_y), (dy, max_y - y1)]:
        if abs(p) < 1e-12:
            if q < 0:
                return False
        else:
            t = q / p
            if p < 0:
                t_min = max(t_min, t)
            else:
                t_max = min(t_max, t)
            if t_min > t_max:
                return False
    return True


def _flat_index_to_cmd_index(cmds, flat_idx):
    flat_count = 0
    for cmd_idx, cmd in enumerate(cmds):
        if isinstance(cmd, MoveTo):
            segs = 0
        elif isinstance(cmd, LineTo):
            segs = 1
        elif isinstance(cmd, CurveTo):
            segs = _FLATTEN_STEPS
        elif isinstance(cmd, ClosePath):
            segs = 1
        else:
            segs = 1
        if segs > 0 and flat_idx < flat_count + segs:
            return cmd_idx
        flat_count += segs
    return max(0, len(cmds) - 1)


def _cmd_endpoint(cmd):
    if isinstance(cmd, (MoveTo, LineTo)):
        return (cmd.x, cmd.y)
    elif isinstance(cmd, CurveTo):
        return (cmd.x, cmd.y)
    elif isinstance(cmd, ClosePath):
        return None
    # Fallback for other command types.
    if hasattr(cmd, 'x') and hasattr(cmd, 'y'):
        return (cmd.x, cmd.y)
    return None


def _split_path_at_segment(cmds, flat_hit_idx, is_closed):
    cmd_idx = _flat_index_to_cmd_index(cmds, flat_hit_idx)

    if is_closed:
        drawing_cmds = [c for c in cmds if not isinstance(c, ClosePath)]
        if not drawing_cmds:
            return []

        split_after = min(cmd_idx + 1, len(drawing_cmds))
        after = drawing_cmds[split_after:]
        before = drawing_cmds[1:min(cmd_idx, len(drawing_cmds))] if len(drawing_cmds) > 1 else []

        open_cmds = []
        ref_cmd = drawing_cmds[min(split_after - 1, len(drawing_cmds) - 1)] if split_after > 0 else drawing_cmds[0]
        end_pt = _cmd_endpoint(ref_cmd)
        if end_pt:
            open_cmds.append(MoveTo(end_pt[0], end_pt[1]))

        open_cmds.extend(after)
        if isinstance(drawing_cmds[0], MoveTo):
            open_cmds.append(LineTo(drawing_cmds[0].x, drawing_cmds[0].y))
        open_cmds.extend(before)

        if len(open_cmds) >= 2:
            return [open_cmds]
        return []
    else:
        part1 = []
        cur = (0.0, 0.0)
        for cmd in cmds[:cmd_idx]:
            part1.append(cmd)
            pt = _cmd_endpoint(cmd)
            if pt:
                cur = pt

        part2 = []
        if cmd_idx < len(cmds):
            pt = _cmd_endpoint(cmds[cmd_idx])
            if pt:
                part2.append(MoveTo(pt[0], pt[1]))
            else:
                part2.append(MoveTo(cur[0], cur[1]))

        for cmd in cmds[cmd_idx + 1:]:
            if isinstance(cmd, ClosePath):
                continue
            part2.append(cmd)

        result = []
        if len(part1) >= 2 and any(not isinstance(c, MoveTo) for c in part1):
            result.append(part1)
        if len(part2) >= 2:
            result.append(part2)
        return result
