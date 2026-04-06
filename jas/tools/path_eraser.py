"""Path Eraser tool for splitting and removing path segments.

Algorithm
---------
The eraser sweeps a rectangular region (derived from the cursor position and
ERASER_SIZE) across the canvas. For each path that intersects this region:

1. **Flatten** — The path's commands (LineTo, CurveTo, QuadTo, etc.) are
   flattened into a polyline of straight segments. Bezier curves are
   approximated with _FLATTEN_STEPS (20) line segments each.

2. **Hit detection** — Walk the flattened segments to find the first and
   last segments that intersect the eraser rectangle (using Liang-Barsky
   line-rectangle clipping). This gives the contiguous "hit range."

3. **Boundary intersection** — Compute the exact entry and exit points
   where the path crosses the eraser boundary. Liang-Barsky gives t_min
   (entry) and t_max (exit) parameters on the first/last hit flat segments.

4. **Map back to original commands** — flat_index_to_cmd_and_t converts
   each flat segment index + t-on-segment into a (command index, t) pair.
   For a CurveTo with N flatten steps, flat segment j spans
   t = [j/N, (j+1)/N], so command-level t = (j + t_seg) / N.

5. **Curve-preserving split** — De Casteljau's algorithm splits Bezier
   curves at the entry/exit t parameters, producing two sub-curves that
   exactly reconstruct the original. This avoids the loss of shape that
   would occur if curves were replaced with straight lines.

6. **Reassembly** — For open paths, the result is two sub-paths: one from
   the original start to the entry point, and one from the exit point to the
   original end. For closed paths, the path is "unwrapped" into a single
   open path that runs from the exit point around the non-erased portion
   back to the entry point.

Paths whose bounding box is smaller than the eraser are deleted entirely.
"""

from __future__ import annotations

from dataclasses import replace
from typing import TYPE_CHECKING

from geometry.element import (
    ClosePath, CurveTo, LineTo, MoveTo, Path, QuadTo, PathCommand,
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

                hit = _find_eraser_hit(flat, eraser_min_x, eraser_min_y,
                                       eraser_max_x, eraser_max_y)
                if hit is None:
                    new_children.append(child)
                    continue

                # Check if bbox is smaller than eraser.
                bounds = child.bounds()
                if bounds[2] <= ERASER_SIZE * 2.0 and bounds[3] <= ERASER_SIZE * 2.0:
                    layer_changed = True
                    continue  # delete

                is_closed = any(isinstance(c, ClosePath) for c in child.d)
                results = _split_path_at_eraser(child.d, hit, is_closed)

                for cmds in results:
                    if len(cmds) >= 2:
                        new_d = tuple(c for c in cmds if not isinstance(c, ClosePath))
                        new_path = replace(child, d=new_d)
                        new_children.append(new_path)
                layer_changed = True

            if layer_changed:
                new_layers[li] = replace(layer, children=tuple(new_children))
                changed = True

        if changed:
            new_doc = replace(doc, layers=tuple(new_layers), selection=())
            ctx.model.document = new_doc
            ctx.request_update()


class _EraserHit:
    """Result of finding the eraser hit range on a flattened path."""
    __slots__ = ('first_flat_idx', 'last_flat_idx', 'entry_t_seg', 'entry',
                 'exit_t_seg', 'exit')

    def __init__(self, first_flat_idx, last_flat_idx, entry_t_seg, entry,
                 exit_t_seg, exit):
        self.first_flat_idx = first_flat_idx
        self.last_flat_idx = last_flat_idx
        self.entry_t_seg = entry_t_seg
        self.entry = entry
        self.exit_t_seg = exit_t_seg
        self.exit = exit


def _find_eraser_hit(flat, min_x, min_y, max_x, max_y):
    """Find the range of flattened segments that intersect the eraser rectangle,
    and compute the entry/exit points where the path crosses the eraser boundary."""
    first_hit = None
    last_hit = None

    for i in range(len(flat) - 1):
        x1, y1 = flat[i]
        x2, y2 = flat[i + 1]
        if _line_segment_intersects_rect(x1, y1, x2, y2, min_x, min_y, max_x, max_y):
            if first_hit is None:
                first_hit = i
            last_hit = i
        elif first_hit is not None:
            break

    if first_hit is None:
        return None

    # Entry point on first hit segment.
    x1, y1 = flat[first_hit]
    x2, y2 = flat[first_hit + 1]
    if min_x <= x1 <= max_x and min_y <= y1 <= max_y:
        entry_t_seg = 0.0
    else:
        entry_t_seg = _liang_barsky_t_min(x1, y1, x2, y2, min_x, min_y, max_x, max_y)
    entry = (x1 + entry_t_seg * (x2 - x1), y1 + entry_t_seg * (y2 - y1))

    # Exit point on last hit segment.
    x1, y1 = flat[last_hit]
    x2, y2 = flat[last_hit + 1]
    if min_x <= x2 <= max_x and min_y <= y2 <= max_y:
        exit_t_seg = 1.0
    else:
        exit_t_seg = _liang_barsky_t_max(x1, y1, x2, y2, min_x, min_y, max_x, max_y)
    exit_pt = (x1 + exit_t_seg * (x2 - x1), y1 + exit_t_seg * (y2 - y1))

    return _EraserHit(first_hit, last_hit, entry_t_seg, entry, exit_t_seg, exit_pt)


def _liang_barsky_t_min(x1, y1, x2, y2, min_x, min_y, max_x, max_y):
    """Return the Liang-Barsky t_min (entry parameter) for a line segment vs rectangle."""
    dx, dy = x2 - x1, y2 - y1
    t_min = 0.0
    for p, q in [(-dx, x1 - min_x), (dx, max_x - x1),
                 (-dy, y1 - min_y), (dy, max_y - y1)]:
        if abs(p) >= 1e-12 and p < 0.0:
            t_min = max(t_min, q / p)
    return max(0.0, min(1.0, t_min))


def _liang_barsky_t_max(x1, y1, x2, y2, min_x, min_y, max_x, max_y):
    """Return the Liang-Barsky t_max (exit parameter) for a line segment vs rectangle."""
    dx, dy = x2 - x1, y2 - y1
    t_max = 1.0
    for p, q in [(-dx, x1 - min_x), (dx, max_x - x1),
                 (-dy, y1 - min_y), (dy, max_y - y1)]:
        if abs(p) >= 1e-12 and p > 0.0:
            t_max = min(t_max, q / p)
    return max(0.0, min(1.0, t_max))


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


def _flat_index_to_cmd_and_t(cmds, flat_idx, t_on_seg):
    """Map a flattened-segment index + t on that segment to (command index, t within command)."""
    flat_count = 0
    for cmd_idx, cmd in enumerate(cmds):
        if isinstance(cmd, MoveTo):
            segs = 0
        elif isinstance(cmd, LineTo):
            segs = 1
        elif isinstance(cmd, (CurveTo, QuadTo)):
            segs = _FLATTEN_STEPS
        elif isinstance(cmd, ClosePath):
            segs = 1
        else:
            segs = 1
        if segs > 0 and flat_idx < flat_count + segs:
            local = flat_idx - flat_count
            t = (local + t_on_seg) / segs
            return (cmd_idx, max(0.0, min(1.0, t)))
        flat_count += segs
    return (max(0, len(cmds) - 1), 1.0)


def _split_cubic_at(p0, x1, y1, x2, y2, x, y, t):
    """Split a cubic Bezier at parameter t using De Casteljau's algorithm.
    Returns (first_half, second_half) as CurveTo commands."""
    lerp = lambda a, b: a + t * (b - a)
    # Level 1
    ax, ay = lerp(p0[0], x1), lerp(p0[1], y1)
    bx, by = lerp(x1, x2), lerp(y1, y2)
    cx, cy = lerp(x2, x), lerp(y2, y)
    # Level 2
    dx, dy = lerp(ax, bx), lerp(ay, by)
    ex, ey = lerp(bx, cx), lerp(by, cy)
    # Level 3 — point on curve
    fx, fy = lerp(dx, ex), lerp(dy, ey)

    first = CurveTo(ax, ay, dx, dy, fx, fy)
    second = CurveTo(ex, ey, cx, cy, x, y)
    return (first, second)


def _split_quad_at(p0, qx1, qy1, x, y, t):
    """Split a quadratic Bezier at parameter t using De Casteljau's algorithm."""
    lerp = lambda a, b: a + t * (b - a)
    ax, ay = lerp(p0[0], qx1), lerp(p0[1], qy1)
    bx, by = lerp(qx1, x), lerp(qy1, y)
    cx, cy = lerp(ax, bx), lerp(ay, by)

    first = QuadTo(ax, ay, cx, cy)
    second = QuadTo(bx, by, x, y)
    return (first, second)


def _cmd_endpoint(cmd):
    if isinstance(cmd, (MoveTo, LineTo)):
        return (cmd.x, cmd.y)
    elif isinstance(cmd, (CurveTo, QuadTo)):
        return (cmd.x, cmd.y)
    elif isinstance(cmd, ClosePath):
        return None
    if hasattr(cmd, 'x') and hasattr(cmd, 'y'):
        return (cmd.x, cmd.y)
    return None


def _cmd_start_points(cmds):
    """Build the command start points array (current point before each command)."""
    starts = [(0.0, 0.0)] * len(cmds)
    cur = (0.0, 0.0)
    for i, cmd in enumerate(cmds):
        starts[i] = cur
        pt = _cmd_endpoint(cmd)
        if pt is not None:
            cur = pt
    return starts


def _entry_cmd(cmd, start, t):
    """Generate the first-half command ending at the entry point, preserving curves."""
    if isinstance(cmd, CurveTo):
        return _split_cubic_at(start, cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.x, cmd.y, t)[0]
    elif isinstance(cmd, QuadTo):
        return _split_quad_at(start, cmd.x1, cmd.y1, cmd.x, cmd.y, t)[0]
    else:
        end = _cmd_endpoint(cmd) or start
        return LineTo(start[0] + t * (end[0] - start[0]),
                      start[1] + t * (end[1] - start[1]))


def _exit_cmd(cmd, start, t):
    """Generate the second-half command starting from the exit point, preserving curves."""
    if isinstance(cmd, CurveTo):
        return _split_cubic_at(start, cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.x, cmd.y, t)[1]
    elif isinstance(cmd, QuadTo):
        return _split_quad_at(start, cmd.x1, cmd.y1, cmd.x, cmd.y, t)[1]
    else:
        end = _cmd_endpoint(cmd) or start
        return LineTo(end[0], end[1])


def _split_path_at_eraser(cmds, hit, is_closed):
    """Split a path at the eraser hit, with endpoints hugging the eraser boundary
    and curves preserved via De Casteljau splitting."""
    entry_cmd_idx, entry_t = _flat_index_to_cmd_and_t(cmds, hit.first_flat_idx, hit.entry_t_seg)
    exit_cmd_idx, exit_t = _flat_index_to_cmd_and_t(cmds, hit.last_flat_idx, hit.exit_t_seg)
    starts = _cmd_start_points(cmds)

    if is_closed:
        drawing_cmds = [(i, c) for i, c in enumerate(cmds) if not isinstance(c, ClosePath)]
        if not drawing_cmds:
            return []

        open_cmds = []

        # Start at the exit point.
        open_cmds.append(MoveTo(hit.exit[0], hit.exit[1]))

        # If the exit command has a remaining portion, add it as a curve.
        if exit_t < 1.0 - 1e-9:
            for orig_idx, cmd in drawing_cmds:
                if orig_idx == exit_cmd_idx:
                    open_cmds.append(_exit_cmd(cmd, starts[orig_idx], exit_t))
                    break

        # Commands after the last erased command.
        resume_from = exit_cmd_idx + 1
        for orig_idx, cmd in drawing_cmds:
            if orig_idx >= resume_from and orig_idx < len(cmds):
                open_cmds.append(cmd)

        # Wrap around: line to original start, then commands before the erased region.
        if drawing_cmds and isinstance(drawing_cmds[0][1], MoveTo):
            m = drawing_cmds[0][1]
            open_cmds.append(LineTo(m.x, m.y))
        for orig_idx, cmd in drawing_cmds:
            if orig_idx >= 1 and orig_idx < entry_cmd_idx:
                open_cmds.append(cmd)

        # End with the entry portion of the entry command.
        if entry_t > 1e-9:
            open_cmds.append(_entry_cmd(cmds[entry_cmd_idx], starts[entry_cmd_idx], entry_t))
        else:
            open_cmds.append(LineTo(hit.entry[0], hit.entry[1]))

        if len(open_cmds) >= 2:
            return [open_cmds]
        return []
    else:
        part1 = []
        part2 = []

        # Part 1: commands before entry, plus the first portion of the entry command.
        for cmd in cmds[:entry_cmd_idx]:
            part1.append(cmd)
        if entry_t > 1e-9:
            part1.append(_entry_cmd(cmds[entry_cmd_idx], starts[entry_cmd_idx], entry_t))
        else:
            part1.append(LineTo(hit.entry[0], hit.entry[1]))

        # Part 2: start at exit point, add remaining portion of exit command, then rest.
        part2.append(MoveTo(hit.exit[0], hit.exit[1]))
        if exit_t < 1.0 - 1e-9:
            part2.append(_exit_cmd(cmds[exit_cmd_idx], starts[exit_cmd_idx], exit_t))
        for cmd in cmds[exit_cmd_idx + 1:]:
            if not isinstance(cmd, ClosePath):
                part2.append(cmd)

        result = []
        if len(part1) >= 2 and any(not isinstance(c, MoveTo) for c in part1):
            result.append(part1)
        if len(part2) >= 2:
            result.append(part2)
        return result
