"""Path-level operations: anchor insertion / deletion, eraser
split, cubic/quad evaluation + projection.

Python analogue of jas_dioxus/src/geometry/path_ops.rs,
JasSwift/Sources/Geometry/PathOps.swift, and
jas_ocaml/lib/geometry/path_ops.ml.

L2 primitives per NATIVE_BOUNDARY.md §5 — path geometry is shared
across vector-illustration apps.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from geometry.element import (
    FLATTEN_STEPS,
    ClosePath,
    CurveTo,
    LineTo,
    MoveTo,
    PathCommand,
    QuadTo,
    SmoothCurveTo,
    SmoothQuadTo,
)

# ── Basic helpers ────────────────────────────────────────


def lerp(a: float, b: float, t: float) -> float:
    """Linear interpolation."""
    return a + t * (b - a)


def eval_cubic(
    x0: float, y0: float,
    x1: float, y1: float,
    x2: float, y2: float,
    x3: float, y3: float,
    t: float,
) -> tuple[float, float]:
    """Evaluate a cubic Bezier at parameter t."""
    mt = 1.0 - t
    x = (mt ** 3) * x0 + 3 * (mt ** 2) * t * x1 \
        + 3 * mt * (t ** 2) * x2 + (t ** 3) * x3
    y = (mt ** 3) * y0 + 3 * (mt ** 2) * t * y1 \
        + 3 * mt * (t ** 2) * y2 + (t ** 3) * y3
    return (x, y)


def cmd_endpoint(cmd: PathCommand) -> tuple[float, float] | None:
    """Endpoint of a path command (``None`` for ``ClosePath``)."""
    if isinstance(cmd, (MoveTo, LineTo)):
        return (cmd.x, cmd.y)
    if isinstance(cmd, CurveTo):
        return (cmd.x, cmd.y)
    if isinstance(cmd, QuadTo):
        return (cmd.x, cmd.y)
    if isinstance(cmd, SmoothCurveTo):
        return (cmd.x, cmd.y)
    if isinstance(cmd, SmoothQuadTo):
        return (cmd.x, cmd.y)
    return None


def cmd_start_points(cmds: tuple[PathCommand, ...] | list) -> list[tuple[float, float]]:
    """Build a parallel list of "pen position before each command."""
    starts: list[tuple[float, float]] = []
    cur = (0.0, 0.0)
    for cmd in cmds:
        starts.append(cur)
        ep = cmd_endpoint(cmd)
        if ep is not None:
            cur = ep
    return starts


def cmd_start_point(cmds, cmd_idx: int) -> tuple[float, float]:
    """Start point of command at ``cmd_idx``. ``(0, 0)`` when
    ``cmd_idx == 0`` or the prior command has no endpoint."""
    if cmd_idx <= 0:
        return (0.0, 0.0)
    prev = cmds[cmd_idx - 1]
    ep = cmd_endpoint(prev)
    return ep if ep is not None else (0.0, 0.0)


# ── Flattening ───────────────────────────────────────────


def flatten_with_cmd_map(
    cmds,
) -> tuple[list[tuple[float, float]], list[int]]:
    """Flatten path commands into a polyline with a parallel
    cmd-index map. Mirrors the Rust/Swift/OCaml kernels."""
    steps = FLATTEN_STEPS
    pts: list[tuple[float, float]] = []
    cmap: list[int] = []
    cx = 0.0
    cy = 0.0
    for i, cmd in enumerate(cmds):
        if isinstance(cmd, (MoveTo, LineTo)):
            pts.append((cmd.x, cmd.y))
            cmap.append(i)
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, CurveTo):
            for k in range(1, steps + 1):
                t = k / steps
                bx, by = eval_cubic(cx, cy, cmd.x1, cmd.y1,
                                    cmd.x2, cmd.y2, cmd.x, cmd.y, t)
                pts.append((bx, by))
                cmap.append(i)
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, QuadTo):
            for k in range(1, steps + 1):
                t = k / steps
                mt = 1.0 - t
                bx = mt * mt * cx + 2 * mt * t * cmd.x1 + t * t * cmd.x
                by = mt * mt * cy + 2 * mt * t * cmd.y1 + t * t * cmd.y
                pts.append((bx, by))
                cmap.append(i)
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, ClosePath):
            pass
        else:
            ep = cmd_endpoint(cmd)
            if ep is not None:
                pts.append(ep)
                cmap.append(i)
                cx, cy = ep
    return (pts, cmap)


# ── Projection ───────────────────────────────────────────


def closest_on_line(
    x0: float, y0: float, x1: float, y1: float,
    px: float, py: float,
) -> tuple[float, float]:
    """Closest-point projection onto a line segment.
    Returns ``(distance, t)``."""
    dx = x1 - x0
    dy = y1 - y0
    len_sq = dx * dx + dy * dy
    if len_sq == 0.0:
        d = math.hypot(px - x0, py - y0)
        return (d, 0.0)
    t = ((px - x0) * dx + (py - y0) * dy) / len_sq
    t = max(0.0, min(1.0, t))
    qx = x0 + t * dx
    qy = y0 + t * dy
    return (math.hypot(px - qx, py - qy), t)


def closest_on_cubic(
    x0: float, y0: float,
    x1: float, y1: float,
    x2: float, y2: float,
    x3: float, y3: float,
    px: float, py: float,
) -> tuple[float, float]:
    """Closest-point projection onto a cubic. 50-sample coarse +
    20-iter trisection refinement. Matches the other ports."""
    steps = 50
    best_dist = float("inf")
    best_t = 0.0
    for i in range(steps + 1):
        t = i / steps
        bx, by = eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, t)
        d = math.hypot(px - bx, py - by)
        if d < best_dist:
            best_dist = d
            best_t = t
    lo = max(best_t - 1.0 / steps, 0.0)
    hi = min(best_t + 1.0 / steps, 1.0)
    for _ in range(20):
        t1 = lo + (hi - lo) / 3.0
        t2 = hi - (hi - lo) / 3.0
        bx1, by1 = eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, t1)
        bx2, by2 = eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, t2)
        d1 = math.hypot(px - bx1, py - by1)
        d2 = math.hypot(px - bx2, py - by2)
        if d1 < d2:
            hi = t2
        else:
            lo = t1
    best_t = (lo + hi) / 2.0
    bx, by = eval_cubic(x0, y0, x1, y1, x2, y2, x3, y3, best_t)
    return (math.hypot(px - bx, py - by), best_t)


def closest_segment_and_t(
    cmds, px: float, py: float,
) -> tuple[int, float] | None:
    """Find which segment of the path ``(px, py)`` is closest to,
    plus the t-on-that-segment."""
    best_dist = float("inf")
    best_seg = 0
    best_t = 0.0
    cx = 0.0
    cy = 0.0
    for i, cmd in enumerate(cmds):
        if isinstance(cmd, MoveTo):
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, LineTo):
            dist, t = closest_on_line(cx, cy, cmd.x, cmd.y, px, py)
            if dist < best_dist:
                best_dist = dist
                best_seg = i
                best_t = t
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, CurveTo):
            dist, t = closest_on_cubic(cx, cy, cmd.x1, cmd.y1,
                                       cmd.x2, cmd.y2, cmd.x, cmd.y, px, py)
            if dist < best_dist:
                best_dist = dist
                best_seg = i
                best_t = t
            cx, cy = cmd.x, cmd.y
    if not math.isfinite(best_dist):
        return None
    return (best_seg, best_t)


# ── Splitting ────────────────────────────────────────────


def split_cubic(
    x0: float, y0: float,
    x1: float, y1: float,
    x2: float, y2: float,
    x3: float, y3: float,
    t: float,
) -> tuple[tuple[float, float, float, float, float, float],
           tuple[float, float, float, float, float, float]]:
    """Split a cubic at ``t``. Returns ``(first, second)`` where
    each is a ``(x1, y1, x2, y2, x, y)`` tuple."""
    a1x = lerp(x0, x1, t); a1y = lerp(y0, y1, t)
    a2x = lerp(x1, x2, t); a2y = lerp(y1, y2, t)
    a3x = lerp(x2, x3, t); a3y = lerp(y2, y3, t)
    b1x = lerp(a1x, a2x, t); b1y = lerp(a1y, a2y, t)
    b2x = lerp(a2x, a3x, t); b2y = lerp(a2y, a3y, t)
    mx = lerp(b1x, b2x, t); my = lerp(b1y, b2y, t)
    return (
        (a1x, a1y, b1x, b1y, mx, my),
        (b2x, b2y, a3x, a3y, x3, y3),
    )


def split_cubic_cmd_at(
    p0: tuple[float, float],
    x1: float, y1: float, x2: float, y2: float, x: float, y: float,
    t: float,
) -> tuple[CurveTo, CurveTo]:
    """Split a cubic at ``t``, returning two ``CurveTo`` commands."""
    first, second = split_cubic(p0[0], p0[1], x1, y1, x2, y2, x, y, t)
    return (
        CurveTo(x1=first[0], y1=first[1], x2=first[2], y2=first[3],
                x=first[4], y=first[5]),
        CurveTo(x1=second[0], y1=second[1], x2=second[2], y2=second[3],
                x=second[4], y=second[5]),
    )


def split_quad_cmd_at(
    p0: tuple[float, float],
    qx: float, qy: float, x: float, y: float,
    t: float,
) -> tuple[QuadTo, QuadTo]:
    """Split a quadratic at ``t``, returning two ``QuadTo`` commands."""
    ax = lerp(p0[0], qx, t); ay = lerp(p0[1], qy, t)
    bx = lerp(qx, x, t); by = lerp(qy, y, t)
    cx = lerp(ax, bx, t); cy = lerp(ay, by, t)
    return (
        QuadTo(x1=ax, y1=ay, x=cx, y=cy),
        QuadTo(x1=bx, y1=by, x=x, y=y),
    )


# ── Anchor deletion ──────────────────────────────────────


def _count_anchors(cmds) -> int:
    return sum(1 for c in cmds if isinstance(c, (MoveTo, LineTo, CurveTo)))


def delete_anchor_from_path(cmds, anchor_idx: int):
    """Delete the anchor at ``anchor_idx``. Returns ``None`` if the
    result would have < 2 anchors. Interior deletion merges adjacent
    segments preserving outer handles."""
    cmds = list(cmds)
    if _count_anchors(cmds) <= 2:
        return None

    if anchor_idx == 0:
        if len(cmds) < 2:
            return None
        second = cmds[1]
        if isinstance(second, LineTo):
            nx, ny = second.x, second.y
        elif isinstance(second, CurveTo):
            nx, ny = second.x, second.y
        else:
            return None
        return [MoveTo(nx, ny)] + cmds[2:]

    last_cmd_idx = len(cmds) - 1
    has_close = isinstance(cmds[last_cmd_idx], ClosePath)
    effective_last = max(last_cmd_idx - 1, 0) if has_close else last_cmd_idx

    if anchor_idx == effective_last:
        result = cmds[:anchor_idx]
        if effective_last < last_cmd_idx:
            result.append(ClosePath())
        return result

    cmd_at = cmds[anchor_idx]
    cmd_after = cmds[anchor_idx + 1]
    merged = None
    if isinstance(cmd_at, CurveTo) and isinstance(cmd_after, CurveTo):
        merged = CurveTo(x1=cmd_at.x1, y1=cmd_at.y1,
                         x2=cmd_after.x2, y2=cmd_after.y2,
                         x=cmd_after.x, y=cmd_after.y)
    elif isinstance(cmd_at, CurveTo) and isinstance(cmd_after, LineTo):
        merged = CurveTo(x1=cmd_at.x1, y1=cmd_at.y1,
                         x2=cmd_after.x, y2=cmd_after.y,
                         x=cmd_after.x, y=cmd_after.y)
    elif isinstance(cmd_at, LineTo) and isinstance(cmd_after, CurveTo):
        if anchor_idx > 0:
            ep = cmd_endpoint(cmds[anchor_idx - 1]) or (0.0, 0.0)
        else:
            ep = (0.0, 0.0)
        merged = CurveTo(x1=ep[0], y1=ep[1],
                         x2=cmd_after.x2, y2=cmd_after.y2,
                         x=cmd_after.x, y=cmd_after.y)
    elif isinstance(cmd_at, LineTo) and isinstance(cmd_after, LineTo):
        merged = LineTo(cmd_after.x, cmd_after.y)

    result = []
    for i, c in enumerate(cmds):
        if i == anchor_idx:
            if merged is not None:
                result.append(merged)
            continue
        if i == anchor_idx + 1:
            continue
        result.append(c)
    return result


# ── Anchor insertion ─────────────────────────────────────


@dataclass
class InsertAnchorResult:
    commands: list
    first_new_idx: int
    anchor_x: float
    anchor_y: float


def insert_point_in_path(cmds, seg_idx: int, t: float) -> InsertAnchorResult:
    """Insert an anchor at parameter ``t`` along the segment at
    ``seg_idx``. Returns the new command list plus the new anchor's
    position."""
    cmds = list(cmds)
    result: list = []
    cx = 0.0
    cy = 0.0
    first_new_idx = 0
    anchor_x = 0.0
    anchor_y = 0.0
    for i, cmd in enumerate(cmds):
        if i == seg_idx:
            if isinstance(cmd, CurveTo):
                first, second = split_cubic(cx, cy, cmd.x1, cmd.y1,
                                            cmd.x2, cmd.y2, cmd.x, cmd.y, t)
                first_new_idx = len(result)
                anchor_x = first[4]
                anchor_y = first[5]
                result.append(CurveTo(x1=first[0], y1=first[1],
                                      x2=first[2], y2=first[3],
                                      x=first[4], y=first[5]))
                result.append(CurveTo(x1=second[0], y1=second[1],
                                      x2=second[2], y2=second[3],
                                      x=second[4], y=second[5]))
                cx, cy = cmd.x, cmd.y
                continue
            if isinstance(cmd, LineTo):
                mx = lerp(cx, cmd.x, t)
                my = lerp(cy, cmd.y, t)
                first_new_idx = len(result)
                anchor_x = mx
                anchor_y = my
                result.append(LineTo(mx, my))
                result.append(LineTo(cmd.x, cmd.y))
                cx, cy = cmd.x, cmd.y
                continue
        if isinstance(cmd, MoveTo):
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, LineTo):
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, CurveTo):
            cx, cy = cmd.x, cmd.y
        result.append(cmd)
    return InsertAnchorResult(
        commands=result, first_new_idx=first_new_idx,
        anchor_x=anchor_x, anchor_y=anchor_y,
    )


# ── Liang-Barsky (eraser clipping) ───────────────────────


def liang_barsky_t_min(
    x1: float, y1: float, x2: float, y2: float,
    min_x: float, min_y: float, max_x: float, max_y: float,
) -> float:
    dx = x2 - x1
    dy = y2 - y1
    t_min = 0.0
    for p, q in [(-dx, x1 - min_x), (dx, max_x - x1),
                 (-dy, y1 - min_y), (dy, max_y - y1)]:
        if abs(p) >= 1e-12 and p < 0.0:
            t_min = max(t_min, q / p)
    return max(0.0, min(1.0, t_min))


def liang_barsky_t_max(
    x1: float, y1: float, x2: float, y2: float,
    min_x: float, min_y: float, max_x: float, max_y: float,
) -> float:
    dx = x2 - x1
    dy = y2 - y1
    t_max = 1.0
    for p, q in [(-dx, x1 - min_x), (dx, max_x - x1),
                 (-dy, y1 - min_y), (dy, max_y - y1)]:
        if abs(p) >= 1e-12 and p > 0.0:
            t_max = min(t_max, q / p)
    return max(0.0, min(1.0, t_max))


def line_segment_intersects_rect(
    x1: float, y1: float, x2: float, y2: float,
    min_x: float, min_y: float, max_x: float, max_y: float,
) -> bool:
    if min_x <= x1 <= max_x and min_y <= y1 <= max_y:
        return True
    if min_x <= x2 <= max_x and min_y <= y2 <= max_y:
        return True
    t_min = 0.0
    t_max = 1.0
    dx = x2 - x1
    dy = y2 - y1
    for p, q in [(-dx, x1 - min_x), (dx, max_x - x1),
                 (-dy, y1 - min_y), (dy, max_y - y1)]:
        if abs(p) < 1e-12:
            if q < 0.0:
                return False
        else:
            t = q / p
            if p < 0.0:
                t_min = max(t_min, t)
            else:
                t_max = min(t_max, t)
            if t_min > t_max:
                return False
    return True


# ── Eraser (find_eraser_hit + split_path_at_eraser) ──────


@dataclass(frozen=True)
class EraserHit:
    first_flat_idx: int
    last_flat_idx: int
    entry_t_seg: float
    entry: tuple[float, float]
    exit_t_seg: float
    exit_pt: tuple[float, float]


def find_eraser_hit(
    flat: list[tuple[float, float]],
    min_x: float, min_y: float, max_x: float, max_y: float,
) -> EraserHit | None:
    """Walk the flattened polyline and return the first contiguous
    run of segments that intersect the rect."""
    n = len(flat)
    if n < 2:
        return None
    first_hit = -1
    last_hit = -1
    for i in range(n - 1):
        x1, y1 = flat[i]
        x2, y2 = flat[i + 1]
        if line_segment_intersects_rect(x1, y1, x2, y2,
                                         min_x, min_y, max_x, max_y):
            if first_hit < 0:
                first_hit = i
            last_hit = i
        elif first_hit >= 0:
            break
    if first_hit < 0:
        return None

    ex1, ey1 = flat[first_hit]
    ex2, ey2 = flat[first_hit + 1]
    if min_x <= ex1 <= max_x and min_y <= ey1 <= max_y:
        entry_t_seg = 0.0
    else:
        entry_t_seg = liang_barsky_t_min(ex1, ey1, ex2, ey2,
                                          min_x, min_y, max_x, max_y)
    entry = (ex1 + entry_t_seg * (ex2 - ex1),
             ey1 + entry_t_seg * (ey2 - ey1))

    lx1, ly1 = flat[last_hit]
    lx2, ly2 = flat[last_hit + 1]
    if min_x <= lx2 <= max_x and min_y <= ly2 <= max_y:
        exit_t_seg = 1.0
    else:
        exit_t_seg = liang_barsky_t_max(lx1, ly1, lx2, ly2,
                                         min_x, min_y, max_x, max_y)
    exit_pt = (lx1 + exit_t_seg * (lx2 - lx1),
               ly1 + exit_t_seg * (ly2 - ly1))

    return EraserHit(first_flat_idx=first_hit, last_flat_idx=last_hit,
                     entry_t_seg=entry_t_seg, entry=entry,
                     exit_t_seg=exit_t_seg, exit_pt=exit_pt)


def flat_index_to_cmd_and_t(cmds, flat_idx: int, t_on_seg: float) -> tuple[int, float]:
    """Map (flat_idx, t_on_seg) back to (cmd_idx, t) on the command list."""
    steps = FLATTEN_STEPS
    flat_count = 0
    for i, cmd in enumerate(cmds):
        if isinstance(cmd, MoveTo):
            segs = 0
        elif isinstance(cmd, LineTo):
            segs = 1
        elif isinstance(cmd, (CurveTo, QuadTo)):
            segs = steps
        elif isinstance(cmd, ClosePath):
            segs = 1
        else:
            segs = 1
        if segs > 0 and flat_idx < flat_count + segs:
            local = flat_idx - flat_count
            t = (local + t_on_seg) / segs
            return (i, max(0.0, min(1.0, t)))
        flat_count += segs
    return (max(0, len(cmds) - 1), 1.0)


def entry_cmd(cmd: PathCommand, start: tuple[float, float], t: float) -> PathCommand:
    """First half of a command split at ``t``."""
    if isinstance(cmd, CurveTo):
        return split_cubic_cmd_at(start, cmd.x1, cmd.y1, cmd.x2, cmd.y2,
                                  cmd.x, cmd.y, t)[0]
    if isinstance(cmd, QuadTo):
        return split_quad_cmd_at(start, cmd.x1, cmd.y1, cmd.x, cmd.y, t)[0]
    ep = cmd_endpoint(cmd) or start
    return LineTo(start[0] + t * (ep[0] - start[0]),
                  start[1] + t * (ep[1] - start[1]))


def exit_cmd(cmd: PathCommand, start: tuple[float, float], t: float) -> PathCommand:
    """Second half of a command split at ``t``."""
    if isinstance(cmd, CurveTo):
        return split_cubic_cmd_at(start, cmd.x1, cmd.y1, cmd.x2, cmd.y2,
                                  cmd.x, cmd.y, t)[1]
    if isinstance(cmd, QuadTo):
        return split_quad_cmd_at(start, cmd.x1, cmd.y1, cmd.x, cmd.y, t)[1]
    ep = cmd_endpoint(cmd) or start
    return LineTo(ep[0], ep[1])


def split_path_at_eraser(cmds, hit: EraserHit, is_closed: bool) -> list[list]:
    """Cut ``cmds`` at the eraser hit."""
    cmds = list(cmds)
    entry_cmd_idx, entry_t = flat_index_to_cmd_and_t(
        cmds, hit.first_flat_idx, hit.entry_t_seg)
    exit_cmd_idx, exit_t = flat_index_to_cmd_and_t(
        cmds, hit.last_flat_idx, hit.exit_t_seg)
    starts = cmd_start_points(cmds)

    if is_closed:
        drawing = [(i, c) for i, c in enumerate(cmds)
                   if not isinstance(c, ClosePath)]
        if not drawing:
            return []
        open_cmds: list = [MoveTo(hit.exit_pt[0], hit.exit_pt[1])]
        if exit_t < 1.0 - 1e-9:
            for idx, c in drawing:
                if idx == exit_cmd_idx:
                    open_cmds.append(exit_cmd(c, starts[idx], exit_t))
                    break
        resume = exit_cmd_idx + 1
        for idx, c in drawing:
            if resume <= idx < len(cmds):
                open_cmds.append(c)
        if drawing and isinstance(drawing[0][1], MoveTo):
            mv = drawing[0][1]
            open_cmds.append(LineTo(mv.x, mv.y))
        for idx, c in drawing:
            if 1 <= idx < entry_cmd_idx:
                open_cmds.append(c)
        if entry_t > 1e-9:
            open_cmds.append(entry_cmd(cmds[entry_cmd_idx],
                                       starts[entry_cmd_idx], entry_t))
        else:
            open_cmds.append(LineTo(hit.entry[0], hit.entry[1]))
        return [open_cmds] if len(open_cmds) >= 2 else []

    # Open path.
    part1: list = list(cmds[:entry_cmd_idx])
    if entry_t > 1e-9:
        part1.append(entry_cmd(cmds[entry_cmd_idx],
                               starts[entry_cmd_idx], entry_t))
    else:
        part1.append(LineTo(hit.entry[0], hit.entry[1]))
    part2: list = [MoveTo(hit.exit_pt[0], hit.exit_pt[1])]
    if exit_t < 1.0 - 1e-9:
        part2.append(exit_cmd(cmds[exit_cmd_idx],
                              starts[exit_cmd_idx], exit_t))
    if exit_cmd_idx + 1 < len(cmds):
        for c in cmds[exit_cmd_idx + 1:]:
            if not isinstance(c, ClosePath):
                part2.append(c)
    result: list[list] = []
    part1_has_non_move = any(not isinstance(c, MoveTo) for c in part1)
    if len(part1) >= 2 and part1_has_non_move:
        result.append(part1)
    if len(part2) >= 2:
        result.append(part2)
    return result
