"""Add Anchor Point tool.

Clicking on a path inserts a new smooth anchor point at that location,
splitting the clicked bezier segment into two while preserving the
curve shape (de Casteljau subdivision).
"""

from __future__ import annotations

import dataclasses
import math
from dataclasses import dataclass
from typing import TYPE_CHECKING

from document.document import ElementSelection
from geometry.element import (
    ClosePath, CurveTo, LineTo, MoveTo, Path, PathCommand,
    control_point_count, path_distance_to_point,
)
from tools.tool import CanvasTool, ToolContext, HIT_RADIUS, HANDLE_DRAW_SIZE

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter

_ADD_POINT_THRESHOLD = HIT_RADIUS + 2.0
_HANDLE_CIRCLE_RADIUS = HANDLE_DRAW_SIZE / 2.0


def _lerp(a: float, b: float, t: float) -> float:
    return a + t * (b - a)


def _eval_cubic(
    x0: float, y0: float,
    x1: float, y1: float,
    x2: float, y2: float,
    x3: float, y3: float,
    t: float,
) -> tuple[float, float]:
    """Evaluate a cubic bezier at parameter t."""
    mt = 1.0 - t
    x = (mt ** 3 * x0
         + 3.0 * mt ** 2 * t * x1
         + 3.0 * mt * t ** 2 * x2
         + t ** 3 * x3)
    y = (mt ** 3 * y0
         + 3.0 * mt ** 2 * t * y1
         + 3.0 * mt * t ** 2 * y2
         + t ** 3 * y3)
    return x, y


def split_cubic(
    x0: float, y0: float,
    x1: float, y1: float,
    x2: float, y2: float,
    x3: float, y3: float,
    t: float,
) -> tuple[tuple[float, float, float, float, float, float],
           tuple[float, float, float, float, float, float]]:
    """Split a cubic bezier at parameter t using de Casteljau's algorithm.

    Returns two tuples of (cp1x, cp1y, cp2x, cp2y, ex, ey) for each half.
    """
    # Level 1
    a1x = _lerp(x0, x1, t)
    a1y = _lerp(y0, y1, t)
    a2x = _lerp(x1, x2, t)
    a2y = _lerp(y1, y2, t)
    a3x = _lerp(x2, x3, t)
    a3y = _lerp(y2, y3, t)
    # Level 2
    b1x = _lerp(a1x, a2x, t)
    b1y = _lerp(a1y, a2y, t)
    b2x = _lerp(a2x, a3x, t)
    b2y = _lerp(a2y, a3y, t)
    # Level 3 (split point)
    mx = _lerp(b1x, b2x, t)
    my = _lerp(b1y, b2y, t)

    return (
        (a1x, a1y, b1x, b1y, mx, my),
        (b2x, b2y, a3x, a3y, x3, y3),
    )


def _closest_on_line(
    x0: float, y0: float,
    x1: float, y1: float,
    px: float, py: float,
) -> tuple[float, float]:
    """Find closest point on a line segment. Returns (distance, t)."""
    dx = x1 - x0
    dy = y1 - y0
    len_sq = dx * dx + dy * dy
    if len_sq == 0.0:
        d = math.sqrt((px - x0) ** 2 + (py - y0) ** 2)
        return d, 0.0
    t = ((px - x0) * dx + (py - y0) * dy) / len_sq
    t = max(0.0, min(1.0, t))
    qx = x0 + t * dx
    qy = y0 + t * dy
    d = math.sqrt((px - qx) ** 2 + (py - qy) ** 2)
    return d, t


def _closest_on_cubic(
    x0: float, y0: float,
    x1: float, y1: float,
    x2: float, y2: float,
    x3: float, y3: float,
    px: float, py: float,
) -> tuple[float, float]:
    """Find closest point on a cubic bezier by sampling + ternary search.

    Returns (distance, t).
    """
    steps = 50
    best_dist = float('inf')
    best_t = 0.0
    for i in range(steps + 1):
        t = i / steps
        bx, by = _eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, t)
        d = math.sqrt((px - bx) ** 2 + (py - by) ** 2)
        if d < best_dist:
            best_dist = d
            best_t = t

    # Ternary search refinement
    lo = max(best_t - 1.0 / steps, 0.0)
    hi = min(best_t + 1.0 / steps, 1.0)
    for _ in range(20):
        t1 = lo + (hi - lo) / 3.0
        t2 = hi - (hi - lo) / 3.0
        bx1, by1 = _eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, t1)
        bx2, by2 = _eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, t2)
        d1 = math.sqrt((px - bx1) ** 2 + (py - by1) ** 2)
        d2 = math.sqrt((px - bx2) ** 2 + (py - by2) ** 2)
        if d1 < d2:
            hi = t2
        else:
            lo = t1
    best_t = (lo + hi) / 2.0
    bx, by = _eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, best_t)
    best_dist = math.sqrt((px - bx) ** 2 + (py - by) ** 2)
    return best_dist, best_t


def closest_segment_and_t(
    d: tuple[PathCommand, ...], px: float, py: float,
) -> tuple[int, float] | None:
    """Find which segment of the path the point (px, py) is closest to.

    Returns (segment_index, t) or None.
    """
    best_dist = float('inf')
    best_seg = 0
    best_t = 0.0
    cx, cy = 0.0, 0.0

    for cmd_idx, cmd in enumerate(d):
        if isinstance(cmd, MoveTo):
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, LineTo):
            dist, t = _closest_on_line(cx, cy, cmd.x, cmd.y, px, py)
            if dist < best_dist:
                best_dist = dist
                best_seg = cmd_idx
                best_t = t
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, CurveTo):
            dist, t = _closest_on_cubic(
                cx, cy, cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.x, cmd.y, px, py,
            )
            if dist < best_dist:
                best_dist = dist
                best_seg = cmd_idx
                best_t = t
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, ClosePath):
            pass

    if best_dist < float('inf'):
        return best_seg, best_t
    return None


@dataclass
class _InsertResult:
    commands: tuple[PathCommand, ...]
    first_new_idx: int
    anchor_x: float
    anchor_y: float


def insert_point_in_path(
    d: tuple[PathCommand, ...], seg_idx: int, t: float,
) -> _InsertResult:
    """Insert a new anchor point into the path at the given segment and t.

    Returns new commands, index of the first new command, and anchor position.
    """
    result: list[PathCommand] = []
    cx, cy = 0.0, 0.0
    first_new_idx = 0
    anchor_x, anchor_y = 0.0, 0.0

    for i, cmd in enumerate(d):
        if i == seg_idx:
            if isinstance(cmd, CurveTo):
                (a1x, a1y, b1x, b1y, mx, my), (b2x, b2y, a3x, a3y, ex, ey) = \
                    split_cubic(cx, cy, cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.x, cmd.y, t)
                first_new_idx = len(result)
                anchor_x, anchor_y = mx, my
                result.append(CurveTo(x1=a1x, y1=a1y, x2=b1x, y2=b1y, x=mx, y=my))
                result.append(CurveTo(x1=b2x, y1=b2y, x2=a3x, y2=a3y, x=ex, y=ey))
                cx, cy = cmd.x, cmd.y
                continue
            elif isinstance(cmd, LineTo):
                mx = _lerp(cx, cmd.x, t)
                my = _lerp(cy, cmd.y, t)
                first_new_idx = len(result)
                anchor_x, anchor_y = mx, my
                result.append(LineTo(x=mx, y=my))
                result.append(LineTo(x=cmd.x, y=cmd.y))
                cx, cy = cmd.x, cmd.y
                continue

        # Default: copy command and update current position
        if isinstance(cmd, MoveTo):
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, (LineTo, CurveTo)):
            cx, cy = cmd.x, cmd.y
        result.append(cmd)

    return _InsertResult(
        commands=tuple(result),
        first_new_idx=first_new_idx,
        anchor_x=anchor_x,
        anchor_y=anchor_y,
    )


def _update_handles(
    cmds: list[PathCommand],
    first_cmd_idx: int,
    anchor_x: float, anchor_y: float,
    drag_x: float, drag_y: float,
    cusp: bool,
) -> list[PathCommand]:
    """Update handles of the newly inserted anchor point.

    Returns a new list of commands with modified handles.
    """
    result = list(cmds)
    # Outgoing handle = drag position
    out_cmd = result[first_cmd_idx + 1]
    if isinstance(out_cmd, CurveTo):
        result[first_cmd_idx + 1] = CurveTo(
            x1=drag_x, y1=drag_y,
            x2=out_cmd.x2, y2=out_cmd.y2,
            x=out_cmd.x, y=out_cmd.y,
        )
    # Incoming handle: mirror (smooth) or leave unchanged (cusp)
    if not cusp:
        in_cmd = result[first_cmd_idx]
        if isinstance(in_cmd, CurveTo):
            result[first_cmd_idx] = CurveTo(
                x1=in_cmd.x1, y1=in_cmd.y1,
                x2=2.0 * anchor_x - drag_x,
                y2=2.0 * anchor_y - drag_y,
                x=in_cmd.x, y=in_cmd.y,
            )
    return result


def _reposition_anchor(
    cmds: list[PathCommand],
    first_cmd_idx: int,
    new_ax: float, new_ay: float,
    dx: float, dy: float,
) -> list[PathCommand]:
    """Move the anchor point by (dx, dy), shifting its handles by the same delta."""
    result = list(cmds)
    cmd = result[first_cmd_idx]
    if isinstance(cmd, CurveTo):
        result[first_cmd_idx] = CurveTo(
            x1=cmd.x1, y1=cmd.y1,
            x2=cmd.x2 + dx, y2=cmd.y2 + dy,
            x=new_ax, y=new_ay,
        )
    if first_cmd_idx + 1 < len(result):
        out_cmd = result[first_cmd_idx + 1]
        if isinstance(out_cmd, CurveTo):
            result[first_cmd_idx + 1] = CurveTo(
                x1=out_cmd.x1 + dx, y1=out_cmd.y1 + dy,
                x2=out_cmd.x2, y2=out_cmd.y2,
                x=out_cmd.x, y=out_cmd.y,
            )
    return result


def _find_prev_anchor(cmds: tuple[PathCommand, ...], idx: int) -> tuple[float, float] | None:
    for i in range(idx - 1, -1, -1):
        cmd = cmds[i]
        if isinstance(cmd, (MoveTo, LineTo, CurveTo)):
            return cmd.x, cmd.y
    return None


def _find_next_anchor(cmds: tuple[PathCommand, ...], idx: int) -> tuple[float, float] | None:
    for i in range(idx + 1, len(cmds)):
        cmd = cmds[i]
        if isinstance(cmd, (MoveTo, LineTo, CurveTo)):
            return cmd.x, cmd.y
    return None


def _find_anchor_at(
    d: tuple[PathCommand, ...], px: float, py: float, threshold: float,
) -> int | None:
    """Find the command index of an anchor point near (px, py)."""
    for i, cmd in enumerate(d):
        if isinstance(cmd, MoveTo):
            ax, ay = cmd.x, cmd.y
        elif isinstance(cmd, LineTo):
            ax, ay = cmd.x, cmd.y
        elif isinstance(cmd, CurveTo):
            ax, ay = cmd.x, cmd.y
        else:
            continue
        dist = math.sqrt((px - ax) ** 2 + (py - ay) ** 2)
        if dist <= threshold:
            return i
    return None


def _toggle_smooth_corner(cmds: tuple[PathCommand, ...], anchor_idx: int) -> tuple[PathCommand, ...]:
    """Toggle a point between smooth and corner. Returns new commands tuple."""
    result = list(cmds)
    cmd = result[anchor_idx]
    if isinstance(cmd, MoveTo):
        ax, ay = cmd.x, cmd.y
    elif isinstance(cmd, LineTo):
        ax, ay = cmd.x, cmd.y
    elif isinstance(cmd, CurveTo):
        ax, ay = cmd.x, cmd.y
    else:
        return cmds

    # Check if currently a corner (handles at anchor position)
    in_at_anchor = True
    if isinstance(result[anchor_idx], CurveTo):
        c = result[anchor_idx]
        in_at_anchor = abs(c.x2 - ax) < 0.5 and abs(c.y2 - ay) < 0.5

    out_at_anchor = True
    if anchor_idx + 1 < len(result) and isinstance(result[anchor_idx + 1], CurveTo):
        c = result[anchor_idx + 1]
        out_at_anchor = abs(c.x1 - ax) < 0.5 and abs(c.y1 - ay) < 0.5

    is_corner = in_at_anchor and out_at_anchor

    if is_corner:
        # Convert corner to smooth: extend handles along prev->next direction
        prev = _find_prev_anchor(cmds, anchor_idx)
        nxt = _find_next_anchor(cmds, anchor_idx)
        if prev is not None and nxt is not None:
            px_, py_ = prev
            nx, ny = nxt
            dx = nx - px_
            dy = ny - py_
            length = math.sqrt(dx * dx + dy * dy)
            if length > 0.0:
                prev_dist = math.sqrt((ax - px_) ** 2 + (ay - py_) ** 2)
                next_dist = math.sqrt((nx - ax) ** 2 + (ny - ay) ** 2)
                ux = dx / length
                uy = dy / length
                in_len = prev_dist / 3.0
                out_len = next_dist / 3.0
                # Set incoming handle
                if isinstance(result[anchor_idx], CurveTo):
                    c = result[anchor_idx]
                    result[anchor_idx] = CurveTo(
                        x1=c.x1, y1=c.y1,
                        x2=ax - ux * in_len, y2=ay - uy * in_len,
                        x=c.x, y=c.y,
                    )
                # Set outgoing handle
                if anchor_idx + 1 < len(result) and isinstance(result[anchor_idx + 1], CurveTo):
                    c = result[anchor_idx + 1]
                    result[anchor_idx + 1] = CurveTo(
                        x1=ax + ux * out_len, y1=ay + uy * out_len,
                        x2=c.x2, y2=c.y2,
                        x=c.x, y=c.y,
                    )
    else:
        # Convert smooth to corner: collapse handles to anchor position
        if isinstance(result[anchor_idx], CurveTo):
            c = result[anchor_idx]
            result[anchor_idx] = CurveTo(
                x1=c.x1, y1=c.y1, x2=ax, y2=ay, x=c.x, y=c.y,
            )
        if anchor_idx + 1 < len(result) and isinstance(result[anchor_idx + 1], CurveTo):
            c = result[anchor_idx + 1]
            result[anchor_idx + 1] = CurveTo(
                x1=ax, y1=ay, x2=c.x2, y2=c.y2, x=c.x, y=c.y,
            )

    return tuple(result)


def _hit_test_path(
    ctx: ToolContext, x: float, y: float,
) -> tuple[tuple[int, ...], Path] | None:
    """Find nearest Path element to (x, y) within threshold."""
    result = ctx.hit_test_path_curve(x, y)
    if result is not None:
        path, elem = result
        if isinstance(elem, Path):
            return path, elem
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


@dataclass
class _DragState:
    elem_path: tuple[int, ...]
    first_cmd_idx: int
    anchor_x: float
    anchor_y: float
    last_x: float
    last_y: float


class AddAnchorPointTool(CanvasTool):
    def __init__(self):
        self._drag: _DragState | None = None
        self._space_held: bool = False

    def on_press(self, ctx: ToolContext, x: float, y: float,
                 shift: bool = False, alt: bool = False) -> None:
        self._drag = None

        # Alt+click on existing anchor: toggle smooth/corner
        if alt:
            result = _hit_test_anchor(ctx, x, y)
            if result is not None:
                elem_path, pe, anchor_idx = result
                ctx.snapshot()
                new_cmds = _toggle_smooth_corner(pe.d, anchor_idx)
                new_elem = dataclasses.replace(pe, d=new_cmds)
                ctx.model.document = ctx.model.document.replace_element(elem_path, new_elem)
                ctx.request_update()
                return

        # Click on path: insert anchor point
        result = _hit_test_path(ctx, x, y)
        if result is not None:
            elem_path, pe = result
            seg_result = closest_segment_and_t(pe.d, x, y)
            if seg_result is not None:
                seg_idx, t = seg_result
                ctx.snapshot()
                ins = insert_point_in_path(pe.d, seg_idx, t)
                new_elem = dataclasses.replace(pe, d=ins.commands)
                doc = ctx.model.document.replace_element(elem_path, new_elem)

                # Update selection: shift CP indices after the insertion point
                new_anchor_idx = ins.first_new_idx
                old_sel = ctx.model.document.get_element_selection(elem_path)
                if old_sel is not None:
                    shifted = set()
                    for cp in old_sel.control_points:
                        if cp >= new_anchor_idx:
                            shifted.add(cp + 1)
                        else:
                            shifted.add(cp)
                    shifted.add(new_anchor_idx)
                    new_sel_entry = ElementSelection(
                        path=elem_path, control_points=frozenset(shifted))
                    new_selection = frozenset(
                        (new_sel_entry if es.path == elem_path else es)
                        for es in doc.selection
                    )
                    doc = dataclasses.replace(doc, selection=new_selection)

                ctx.model.document = doc
                ctx.request_update()

                # Allow handle dragging if the split produced CurveTo pairs
                if (ins.first_new_idx + 1 < len(ins.commands)
                        and isinstance(ins.commands[ins.first_new_idx], CurveTo)
                        and isinstance(ins.commands[ins.first_new_idx + 1], CurveTo)):
                    self._drag = _DragState(
                        elem_path=elem_path,
                        first_cmd_idx=ins.first_new_idx,
                        anchor_x=ins.anchor_x,
                        anchor_y=ins.anchor_y,
                        last_x=x,
                        last_y=y,
                    )

    def on_move(self, ctx: ToolContext, x: float, y: float,
                shift: bool = False, dragging: bool = False) -> None:
        if not dragging or self._drag is None:
            return

        drag = self._drag

        # Check modifier key state
        from PySide6.QtWidgets import QApplication
        from PySide6.QtCore import Qt
        modifiers = QApplication.queryKeyboardModifiers()
        alt = bool(modifiers & Qt.KeyboardModifier.AltModifier)
        space = self._space_held

        doc = ctx.model.document
        elem = doc.get_element(drag.elem_path)
        if not isinstance(elem, Path):
            return

        if space:
            # Space held: reposition the anchor point
            dx = x - drag.last_x
            dy = y - drag.last_y
            drag.last_x = x
            drag.last_y = y
            drag.anchor_x += dx
            drag.anchor_y += dy
            new_cmds = _reposition_anchor(
                list(elem.d), drag.first_cmd_idx,
                drag.anchor_x, drag.anchor_y,
                dx, dy,
            )
        else:
            drag.last_x = x
            drag.last_y = y
            new_cmds = _update_handles(
                list(elem.d), drag.first_cmd_idx,
                drag.anchor_x, drag.anchor_y,
                x, y, alt,
            )
        new_elem = dataclasses.replace(elem, d=tuple(new_cmds))
        ctx.model.document = doc.replace_element(drag.elem_path, new_elem)
        ctx.request_update()

    def on_release(self, ctx: ToolContext, x: float, y: float,
                   shift: bool = False, alt: bool = False) -> None:
        self._drag = None
        self._space_held = False

    def on_key(self, ctx: ToolContext, key: int) -> bool:
        from PySide6.QtCore import Qt
        if key == Qt.Key.Key_Space and self._drag is not None:
            self._space_held = True
            return True
        return False

    def on_key_release(self, ctx: ToolContext, key: int) -> bool:
        from PySide6.QtCore import Qt
        if key == Qt.Key.Key_Space:
            self._space_held = False
            return True
        return False

    def draw_overlay(self, ctx: ToolContext, painter: "QPainter") -> None:
        if self._drag is None:
            return

        drag = self._drag
        doc = ctx.model.document
        elem = doc.get_element(drag.elem_path)
        if not isinstance(elem, Path):
            return

        idx = drag.first_cmd_idx
        if idx + 1 >= len(elem.d):
            return

        # Extract handle positions
        in_cmd = elem.d[idx]
        out_cmd = elem.d[idx + 1]
        if not isinstance(in_cmd, CurveTo) or not isinstance(out_cmd, CurveTo):
            return

        in_x, in_y = in_cmd.x2, in_cmd.y2
        out_x, out_y = out_cmd.x1, out_cmd.y1
        ax, ay = drag.anchor_x, drag.anchor_y

        from PySide6.QtCore import QPointF, QRectF
        from PySide6.QtGui import QColor, QPen, QBrush

        sel_color = QColor(0, 120, 255)

        # Determine if cusp (handles not collinear through anchor)
        d_in_x = in_x - ax
        d_in_y = in_y - ay
        d_out_x = out_x - ax
        d_out_y = out_y - ay
        cross = d_in_x * d_out_y - d_in_y * d_out_x
        dot = d_in_x * d_out_x + d_in_y * d_out_y
        in_len = math.sqrt(d_in_x ** 2 + d_in_y ** 2)
        out_len = math.sqrt(d_out_x ** 2 + d_out_y ** 2)
        max_len = max(in_len, out_len)
        is_cusp = max_len > 0.5 and (abs(cross) > max_len * 0.01 or dot > 0.0)

        painter.setPen(QPen(sel_color, 1.0))
        if is_cusp:
            # Draw two separate lines: anchor->in, anchor->out
            painter.drawLine(QPointF(ax, ay), QPointF(in_x, in_y))
            painter.drawLine(QPointF(ax, ay), QPointF(out_x, out_y))
        else:
            # Smooth: draw one line through anchor
            painter.drawLine(QPointF(in_x, in_y), QPointF(out_x, out_y))

        # Handle circles
        painter.setBrush(QBrush(QColor("white")))
        painter.setPen(QPen(sel_color, 1.0))
        for hx, hy in [(in_x, in_y), (out_x, out_y)]:
            painter.drawEllipse(
                QPointF(hx, hy), _HANDLE_CIRCLE_RADIUS, _HANDLE_CIRCLE_RADIUS,
            )

        # Anchor point square
        half = HANDLE_DRAW_SIZE / 2.0
        painter.setPen(QPen(sel_color, 1.0))
        painter.setBrush(QBrush(sel_color))
        painter.drawRect(QRectF(ax - half, ay - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE))
