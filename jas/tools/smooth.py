"""Smooth tool for simplifying path curves by re-fitting anchor points.

Overview
--------
The Smooth tool is a brush-like tool that simplifies vector paths by
reducing the number of anchor points while preserving the overall shape.
The user drags the tool over a selected path, and the portion of the path
that falls within the tool's circular influence region (radius =
SMOOTH_SIZE, currently 100 pt) is simplified in real time.

Only selected, unlocked Path elements are affected. Non-path elements
(rectangles, ellipses, text, etc.) and locked paths are skipped.

Algorithm
---------
Each time the tool processes a cursor position (on press and on drag),
it runs the following pipeline on every selected path:

1. **Flatten with command map** — The path's command list (MoveTo, LineTo,
   CurveTo, QuadTo, etc.) is converted into a dense polyline of (x, y)
   points. Curves are subdivided into ``_FLATTEN_STEPS`` (20) evenly-spaced
   samples using de Casteljau evaluation. Straight segments produce a
   single point.

   Alongside the flat point list, a parallel **command map** list is built:
   ``cmd_map[i]`` records the index of the original path command that
   produced flat point ``i``. This mapping is the key data structure that
   connects the polyline back to the original command list.

2. **Hit detection** — The flat points are scanned to find the contiguous
   range that lies within the tool's circular influence region (distance
   ≤ SMOOTH_SIZE from the cursor). The scan records ``first_hit`` and
   ``last_hit`` — the indices of the first and last flat points inside the
   circle. If no flat points are within range, the path is skipped.

3. **Command mapping** — The flat-point hit indices are mapped back to
   original command indices via the command map:
   ``first_cmd = cmd_map[first_hit]`` and ``last_cmd = cmd_map[last_hit]``.
   These define the range of original commands ``[first_cmd, last_cmd]``
   that will be replaced. If ``first_cmd == last_cmd``, only one command
   is affected and there is nothing to merge, so the path is skipped.

4. **Re-fit (Schneider curve fitting)** — All flat points whose command
   index falls in ``[first_cmd, last_cmd]`` are collected. The start point
   of ``first_cmd`` (the endpoint of the preceding command) is prepended,
   ensuring the re-fitted curve begins exactly where the unaffected prefix
   ends. These points are passed to ``fit_curve()``, which implements the
   Schneider curve-fitting algorithm with ``_SMOOTH_ERROR`` (8.0) as the
   maximum allowed deviation. Because this tolerance is relatively generous,
   the fitter typically produces fewer Bezier segments than the original
   commands — that is the simplification.

5. **Reassembly** — The original command list is reconstructed in three
   parts:

   - **Prefix**: commands ``[0, first_cmd)`` — unchanged.
   - **Middle**: the re-fitted CurveTo commands from step 4.
   - **Suffix**: commands ``(last_cmd, end]`` — unchanged.

   If the resulting command count is not strictly less than the original,
   the replacement is discarded (no improvement). Otherwise the path
   element is replaced in the document.

Cumulative effect
-----------------
The effect is cumulative: each drag pass removes more detail, producing
progressively smoother curves. Repeatedly dragging over the same region
continues to simplify until the path can be represented by a single
Bezier segment (or the fit can no longer reduce the command count).

Overlay
-------
While the tool is active, a cornflower-blue circle (rgba 100, 149, 237,
0.4) is drawn at the cursor position showing the influence region.
"""

from __future__ import annotations

from dataclasses import replace
from typing import TYPE_CHECKING

from geometry.element import (
    CurveTo, LineTo, MoveTo, Path, QuadTo, PathCommand,
    flatten_path_commands,
)
from geometry.fit_curve import fit_curve
from tools.tool import CanvasTool, ToolContext

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter

SMOOTH_SIZE = 100.0
_SMOOTH_ERROR = 8.0
_FLATTEN_STEPS = 20


class SmoothTool(CanvasTool):
    def __init__(self):
        self._smoothing = False
        self._last_pos = (0.0, 0.0)

    def on_press(self, ctx: ToolContext, x: float, y: float,
                 shift: bool = False, alt: bool = False) -> None:
        ctx.snapshot()
        self._smoothing = True
        self._last_pos = (x, y)
        self._smooth_at(ctx, x, y)

    def on_move(self, ctx: ToolContext, x: float, y: float,
                shift: bool = False, dragging: bool = False) -> None:
        if self._smoothing:
            self._smooth_at(ctx, x, y)
        self._last_pos = (x, y)

    def on_release(self, ctx: ToolContext, x: float, y: float,
                   shift: bool = False, alt: bool = False) -> None:
        self._smoothing = False

    def draw_overlay(self, ctx: ToolContext, painter: "QPainter") -> None:
        from PySide6.QtCore import QPointF
        from PySide6.QtGui import QColor, QPen
        x, y = self._last_pos
        painter.setPen(QPen(QColor(100, 149, 237, 102), 1.0))
        painter.setBrush(QColor(0, 0, 0, 0))
        painter.drawEllipse(QPointF(x, y), SMOOTH_SIZE, SMOOTH_SIZE)

    def _smooth_at(self, ctx: ToolContext, x: float, y: float) -> None:
        """Run the smoothing pipeline at cursor position (x, y).

        For each selected, unlocked path with at least 2 commands:
          1. Flatten the path into a polyline with a command-index map.
          2. Find which flat points fall inside the influence circle.
          3. Map those flat indices back to original command indices.
          4. Re-fit the affected region with Schneider curve fitting.
          5. Splice the re-fitted curves into the original command list.
        If the result has fewer commands, update the document.
        """
        doc = ctx.model.document
        radius_sq = SMOOTH_SIZE * SMOOTH_SIZE
        new_doc = doc

        for es in doc.selection:
            path = es.path
            try:
                elem = doc.get_element(path)
            except (ValueError, IndexError):
                continue
            if not isinstance(elem, Path):
                continue
            if getattr(elem, 'locked', False):
                continue
            if len(elem.d) < 2:
                continue

            # Flatten with command mapping.
            flat, cmd_map = _flatten_with_cmd_map(elem.d)
            if len(flat) < 2:
                continue

            # Find contiguous range of flat points within the circle.
            first_hit = None
            last_hit = None
            for i, (px, py) in enumerate(flat):
                dx = px - x
                dy = py - y
                if dx * dx + dy * dy <= radius_sq:
                    if first_hit is None:
                        first_hit = i
                    last_hit = i

            if first_hit is None or last_hit is None:
                continue

            # Map to command indices.
            first_cmd = cmd_map[first_hit]
            last_cmd = cmd_map[last_hit]

            # Need at least 2 commands affected to smooth.
            if first_cmd >= last_cmd:
                continue

            # Collect flattened points for the affected command range.
            range_flat = [
                flat[i] for i in range(len(flat))
                if first_cmd <= cmd_map[i] <= last_cmd
            ]

            # Include the start point of the first affected command.
            start_point = _cmd_start_point(elem.d, first_cmd)
            points_to_fit = [start_point] + range_flat

            if len(points_to_fit) < 2:
                continue

            # Re-fit the points.
            segments = fit_curve(points_to_fit, _SMOOTH_ERROR)
            if not segments:
                continue

            # Build replacement commands.
            new_cmds: list[PathCommand] = []
            # Commands before the affected range.
            new_cmds.extend(elem.d[:first_cmd])
            # Re-fitted curves.
            for seg in segments:
                new_cmds.append(CurveTo(seg[2], seg[3], seg[4], seg[5],
                                        seg[6], seg[7]))
            # Commands after the affected range.
            new_cmds.extend(elem.d[last_cmd + 1:])

            # Skip if no actual reduction.
            if len(new_cmds) >= len(elem.d):
                continue

            new_elem = replace(elem, d=tuple(new_cmds))
            new_doc = new_doc.replace_element(path, new_elem)

        if new_doc is not doc:
            ctx.model.document = new_doc
            ctx.request_update()


def _cmd_endpoint(cmd: PathCommand) -> tuple[float, float]:
    """Return the endpoint (final pen position) of a path command.

    Every path command except ClosePath moves the pen to a new position.
    For ClosePath (which returns to the last MoveTo), we return (0, 0)
    as a fallback — ClosePath is not expected in a smoothable region.
    """
    if isinstance(cmd, (MoveTo, LineTo)):
        return (cmd.x, cmd.y)
    if isinstance(cmd, CurveTo):
        return (cmd.x, cmd.y)
    if isinstance(cmd, QuadTo):
        return (cmd.x, cmd.y)
    return (0.0, 0.0)


def _cmd_start_point(cmds: tuple[PathCommand, ...], cmd_idx: int) -> tuple[float, float]:
    """Return the start point of command at cmd_idx.

    A path command's start point is the endpoint of the preceding command,
    since each command implicitly begins where the previous one ended. For
    the first command (index 0), the start point is the origin (0, 0).

    Used during re-fitting to prepend the correct start point to the
    collected flat points, ensuring the re-fitted curve connects seamlessly
    with the unaffected prefix of the path.
    """
    if cmd_idx == 0:
        return (0.0, 0.0)
    return _cmd_endpoint(cmds[cmd_idx - 1])


def _flatten_with_cmd_map(
    cmds: tuple[PathCommand, ...],
) -> tuple[list[tuple[float, float]], list[int]]:
    """Flatten path commands into a polyline with a parallel command-index map.

    Returns ``(flat_points, cmd_map)`` where:
      - ``flat_points[i]`` is the (x, y) position of the i-th polyline sample.
      - ``cmd_map[i]`` is the index of the original path command that produced
        ``flat_points[i]``.

    MoveTo and LineTo commands produce exactly one flat point each.
    CurveTo commands are subdivided into ``_FLATTEN_STEPS`` samples using
    the cubic Bezier formula:
        B(t) = (1-t)³·P0 + 3(1-t)²t·P1 + 3(1-t)t²·P2 + t³·P3
    evaluated at t = 1/steps, 2/steps, …, 1. This captures the curve's
    shape as a dense polyline while recording which command each sample
    came from. QuadTo commands are similarly subdivided using the quadratic
    formula. ClosePath produces no points.
    """
    pts: list[tuple[float, float]] = []
    cmd_map: list[int] = []
    cx, cy = 0.0, 0.0
    steps = _FLATTEN_STEPS

    for cmd_idx, cmd in enumerate(cmds):
        if isinstance(cmd, MoveTo):
            pts.append((cmd.x, cmd.y))
            cmd_map.append(cmd_idx)
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, LineTo):
            pts.append((cmd.x, cmd.y))
            cmd_map.append(cmd_idx)
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, CurveTo):
            x1, y1 = cmd.x1, cmd.y1
            x2, y2 = cmd.x2, cmd.y2
            ex, ey = cmd.x, cmd.y
            for i in range(1, steps + 1):
                t = i / steps
                mt = 1.0 - t
                px = (mt ** 3 * cx + 3 * mt ** 2 * t * x1
                      + 3 * mt * t ** 2 * x2 + t ** 3 * ex)
                py = (mt ** 3 * cy + 3 * mt ** 2 * t * y1
                      + 3 * mt * t ** 2 * y2 + t ** 3 * ey)
                pts.append((px, py))
                cmd_map.append(cmd_idx)
            cx, cy = ex, ey
        elif isinstance(cmd, QuadTo):
            x1, y1 = cmd.x1, cmd.y1
            ex, ey = cmd.x, cmd.y
            for i in range(1, steps + 1):
                t = i / steps
                mt = 1.0 - t
                px = mt ** 2 * cx + 2 * mt * t * x1 + t ** 2 * ex
                py = mt ** 2 * cy + 2 * mt * t * y1 + t ** 2 * ey
                pts.append((px, py))
                cmd_map.append(cmd_idx)
            cx, cy = ex, ey
        else:
            # ClosePath or unknown — skip.
            pass

    return pts, cmd_map
