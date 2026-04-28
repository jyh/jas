"""Dash-alignment renderer for stroked paths.

Pure-function path → list-of-sub-paths transformation. Implements the
algorithm specified in DASH_ALIGN.md §Algorithm — see that document
for the conceptual model, edge cases, and per-language parity test
inputs.

Phase 3 ships lines-only support: MoveTo, LineTo, ClosePath. The
typical workspace use cases (rectangles, polygons, hand-drawn
polylines, segment-only paths) are covered. Curve segments
(CurveTo / QuadTo / ArcTo) are deferred to a follow-up phase that
adds De Casteljau subdivision to the inner kernel — the API stays
unchanged.

Path commands are represented as plain tuples for ease of porting:
- ("M", x, y)
- ("L", x, y)
- ("Z",)

Output: a tuple of sub-paths. Each sub-path is a tuple of path
command tuples and represents one solid dash. Sub-paths are emitted
in arc-length order along the path. The caller draws each sub-path
with its existing solid-stroke pipeline (no stroke-dasharray /
setLineDash).
"""

from __future__ import annotations

import math
from typing import Iterable

# ── Public API ───────────────────────────────────────────────────


def expand_dashed_stroke(
    path: Iterable[tuple],
    dash_array: tuple[float, ...],
    align_anchors: bool,
) -> tuple[tuple[tuple, ...], ...]:
    """Expand a dashed stroke into a list of solid sub-paths.

    Inputs:
    - path: sequence of path commands (MoveTo / LineTo / ClosePath)
    - dash_array: alternating dash, gap, dash, gap... lengths in pt
    - align_anchors: when True, per-segment dash and gap lengths flex
      so a dash is centered on every interior anchor and a full dash
      sits at each open-path endpoint. When False, the dash pattern
      lays out by exact length along the path.

    Returns a tuple of sub-paths, one per emitted dash. Empty for
    inputs that produce no visible dashes (empty path, all-zero
    dash array). Returns ((path,),) for an empty / no-effect dash
    array — the caller should treat that as "no dashing, draw the
    path as a single solid stroke".
    """
    path = tuple(path)
    if not path:
        return ()

    # No dashing → single solid sub-path equal to the original path.
    if not dash_array or _all_zero(dash_array):
        # Skip pure-MoveTo paths (no segments to draw).
        if any(c[0] != "M" for c in path):
            return (path,)
        return ()

    # Pad odd-length pattern to even by repeating it (SVG semantics:
    # an odd-length dasharray is duplicated to make it even).
    pattern = tuple(dash_array)
    if len(pattern) % 2 == 1:
        pattern = pattern + pattern

    subpaths = _split_at_moveto(path)
    result: list[tuple[tuple, ...]] = []
    for sp in subpaths:
        if not _has_segments(sp):
            continue
        if align_anchors:
            result.extend(_expand_align(sp, pattern))
        else:
            result.extend(_expand_preserve(sp, pattern))
    return tuple(result)


# ── Path utilities ───────────────────────────────────────────────


def _all_zero(arr: tuple[float, ...]) -> bool:
    return all(v == 0 for v in arr)


def _split_at_moveto(path: tuple) -> list[tuple]:
    """Split a path into subpaths, one per leading MoveTo."""
    subs: list[list[tuple]] = []
    cur: list[tuple] = []
    for cmd in path:
        if cmd[0] == "M":
            if cur:
                subs.append(cur)
            cur = [cmd]
        else:
            cur.append(cmd)
    if cur:
        subs.append(cur)
    return [tuple(s) for s in subs]


def _has_segments(subpath: tuple) -> bool:
    """True if the subpath has at least one drawable segment (L or Z
    after the leading M)."""
    return any(c[0] in ("L", "Z") for c in subpath)


def _is_closed(subpath: tuple) -> bool:
    return any(c[0] == "Z" for c in subpath)


def _anchor_points(subpath: tuple) -> list[tuple[float, float]]:
    """Extract the (x, y) anchors from a lines-only subpath. The
    first MoveTo is anchor 0; each LineTo is the next anchor. For
    a closed subpath, the implicit return-to-start is NOT included
    in the returned list — the caller handles the cyclic wrap."""
    pts: list[tuple[float, float]] = []
    for cmd in subpath:
        if cmd[0] in ("M", "L"):
            pts.append((cmd[1], cmd[2]))
    return pts


def _seg_len(a: tuple[float, float], b: tuple[float, float]) -> float:
    return math.hypot(b[0] - a[0], b[1] - a[1])


# ── Preserve mode ────────────────────────────────────────────────


def _expand_preserve(
    subpath: tuple,
    pattern: tuple[float, ...],
) -> list[tuple[tuple, ...]]:
    """Walk one subpath end-to-end with a uniform dash period."""
    anchors = _anchor_points(subpath)
    if _is_closed(subpath):
        anchors_walk = anchors + [anchors[0]]
    else:
        anchors_walk = anchors
    if len(anchors_walk) < 2:
        return []

    seg_lengths = [_seg_len(a, b) for a, b in zip(anchors_walk, anchors_walk[1:])]
    cum_lengths = _cumulative([0.0] + seg_lengths)
    total = cum_lengths[-1]
    if total <= 0:
        return []

    return _emit_dashes(anchors_walk, cum_lengths, pattern,
                        period_offset=0.0, t_start=0.0, t_end=total)


# ── Align mode ───────────────────────────────────────────────────


def _expand_align(
    subpath: tuple,
    pattern: tuple[float, ...],
) -> list[tuple[tuple, ...]]:
    """Walk one subpath with per-segment dash flex. A dash centered on
    an interior anchor spans the anchor as a single sub-path — the
    last half-dash of the segment ending at the anchor merges with
    the first half-dash of the segment starting at the anchor, so
    the rendered stroke crosses the anchor with the platform's
    natural linejoin behavior (DASH_ALIGN.md Option 2)."""
    anchors = _anchor_points(subpath)
    closed = _is_closed(subpath)
    if closed:
        anchors_walk = anchors + [anchors[0]]
    else:
        anchors_walk = anchors

    n_segs = len(anchors_walk) - 1
    if n_segs < 1:
        return []
    base_period = sum(pattern)
    if base_period <= 0:
        return []

    seg_lengths = [_seg_len(anchors_walk[i], anchors_walk[i + 1])
                   for i in range(n_segs)]
    if all(L <= 0 for L in seg_lengths):
        return []
    cum_lengths = _cumulative([0.0] + seg_lengths)

    # Compute (start, end) dash ranges in global arc-length, per segment.
    all_ranges: list[tuple[float, float]] = []
    for i in range(n_segs):
        L_i = seg_lengths[i]
        if L_i <= 0:
            continue
        kind = _boundary_kind(i, n_segs, closed)
        scale = _solve_segment_scale(L_i, pattern, kind)
        seg_offset_global = cum_lengths[i]
        local_ranges = _segment_dash_ranges(L_i, pattern, scale, kind)
        for (a, b) in local_ranges:
            all_ranges.append((a + seg_offset_global, b + seg_offset_global))

    # Stitch ranges that meet exactly at an interior anchor — those are
    # the two halves of a dash centered on the anchor.
    merged = _merge_adjacent_ranges(all_ranges)

    # Closed-path cyclic stitch: if the last range ends exactly at the
    # cyclic anchor (cum_lengths[-1] == cum_lengths[0]+total) and the
    # first range starts at 0, they're the two halves of the dash
    # centered on the start anchor. Wrap the last range over to absorb
    # the first.
    if closed and len(merged) >= 2:
        total = cum_lengths[-1]
        if (abs(merged[-1][1] - total) < _EPS
                and abs(merged[0][0]) < _EPS):
            wrapped_end = merged[0][1] + total
            wrapped = (merged[-1][0], wrapped_end)
            merged = [wrapped] + list(merged[1:-1])

    # Convert each global (start, end) range to a sub-path.
    result: list[tuple[tuple, ...]] = []
    for (gs, ge) in merged:
        sub = _subpath_between_wrapping(anchors_walk, cum_lengths, gs, ge,
                                        closed=closed)
        if sub is not None:
            result.append(sub)
    return result


_EPS = 1e-9


def _boundary_kind(i: int, n_segs: int, closed: bool) -> str:
    """Return one of EE, EI, IE, II per DASH_ALIGN.md §boundary_kind."""
    if closed:
        return "II"
    if n_segs == 1:
        return "EE"
    if i == 0:
        return "EI"
    if i == n_segs - 1:
        return "IE"
    return "II"


def _solve_segment_scale(
    seg_l: float, pattern: tuple[float, ...], kind: str
) -> float:
    """Pick the per-segment scale that fits an integer number of
    repeats with the boundary-kind's residual half-dash (if any).

    Layout per kind:
    - II: half-dash, gap, dash, gap, ..., dash, gap, half-dash
          → m gaps + (m-1) full dashes + 2 half-dashes = m * P
          → m = round(L/P)
    - EE: dash, gap, dash, ..., gap, dash
          → m gaps + (m+1) full dashes = m * P + d
          → m = round((L - d) / P)
    - EI / IE: dash, gap, ..., gap, dash, gap, half-dash
               (or symmetric reverse)
          → m gaps + m full dashes + 1 half-dash = m * P + 0.5 * d
          → m = round((L - 0.5 * d) / P)
    """
    base_period = sum(pattern)
    d0 = pattern[0]
    if kind == "II":
        m = max(1, round(seg_l / base_period))
        return seg_l / (m * base_period)
    if kind == "EE":
        m = max(0, round((seg_l - d0) / base_period))
        denom = m * base_period + d0
        return seg_l / denom if denom > 0 else 1.0
    # EI or IE
    m = max(1, round((seg_l - 0.5 * d0) / base_period))
    denom = m * base_period + 0.5 * d0
    return seg_l / denom if denom > 0 else 1.0


def _segment_dash_ranges(
    seg_l: float,
    pattern: tuple[float, ...],
    scale: float,
    kind: str,
) -> list[tuple[float, float]]:
    """Compute the within-segment arc-length ranges where dashes
    appear. Returns a list of (dash_start, dash_end) pairs in the
    segment's local frame (0 = segment start, seg_l = segment end).

    The dash boundaries are determined by the boundary kind:
    - II: starts mid-dash (within-period offset = half-first-dash),
          ends mid-dash; the start and end ranges may be half-dashes.
    - EE: starts at full dash boundary (offset 0), ends with full dash
          terminating at segment end.
    - EI: starts at full dash boundary, ends with half-dash (offset
          = within-pattern equivalent of half-first-dash before period
          end).
    - IE: starts mid-dash, ends with full dash terminating at segment end.
    """
    scaled = tuple(p * scale for p in pattern)
    period = sum(scaled)
    if period <= 0 or seg_l <= 0:
        return []
    half_d = scaled[0] * 0.5

    # Within-period position at within-segment t = 0.
    if kind in ("EE", "EI"):
        offset0 = 0.0
    else:  # II or IE
        offset0 = half_d

    # Walk the pattern from offset0 emitting dash ranges in
    # within-segment arc-length, clamped to [0, seg_l].
    ranges: list[tuple[float, float]] = []
    t = 0.0
    cur_idx, in_idx = _locate_in_pattern(offset0, scaled)
    while t < seg_l - _EPS:
        remaining_in_idx = scaled[cur_idx] - in_idx
        next_t = min(t + remaining_in_idx, seg_l)
        is_dash = (cur_idx % 2 == 0)
        if is_dash and next_t > t + _EPS:
            ranges.append((t, next_t))
        consumed = next_t - t
        in_idx += consumed
        if in_idx >= scaled[cur_idx] - _EPS:
            in_idx = 0.0
            cur_idx = (cur_idx + 1) % len(scaled)
        t = next_t
    return ranges


def _merge_adjacent_ranges(
    ranges: list[tuple[float, float]],
) -> list[tuple[float, float]]:
    """Merge ranges where range[i].end == range[i+1].start (within
    EPS). At interior anchors, the two halves of an anchor-centered
    dash meet exactly here; merging stitches them into one range
    that covers both segments."""
    if not ranges:
        return []
    out: list[tuple[float, float]] = [ranges[0]]
    for (s, e) in ranges[1:]:
        last_s, last_e = out[-1]
        if abs(last_e - s) < _EPS:
            out[-1] = (last_s, e)
        else:
            out.append((s, e))
    return out


def _subpath_between_wrapping(
    anchors: list[tuple[float, float]],
    cum_lengths: list[float],
    t0: float,
    t1: float,
    closed: bool,
) -> tuple[tuple, ...] | None:
    """Like _subpath_between but handles closed-path wrapping when
    t1 > total arc-length. The dash continues from the cyclic start
    of the path."""
    total = cum_lengths[-1]
    if not closed or t1 <= total + _EPS:
        return _subpath_between(anchors, cum_lengths, t0, min(t1, total))
    # Wrap: emit the segment from t0 to total, then continue from 0
    # to (t1 - total). Concatenate into a single sub-path.
    head = _subpath_between(anchors, cum_lengths, t0, total)
    tail = _subpath_between(anchors, cum_lengths, 0.0, t1 - total)
    if head is None:
        return tail
    if tail is None:
        return head
    # Drop tail's leading M (it would be at the same point as head's
    # last L, since the closing edge brings us back to anchors[0]).
    tail_no_m: list[tuple] = []
    for cmd in tail:
        if cmd[0] == "M":
            continue
        tail_no_m.append(cmd)
    return tuple(list(head) + tail_no_m)


# ── Dash walk ─────────────────────────────────────────────────────


def _emit_dashes(
    anchors_walk: list[tuple[float, float]],
    cum_lengths: list[float],
    pattern: tuple[float, ...],
    period_offset: float,
    t_start: float,
    t_end: float,
) -> list[tuple[tuple, ...]]:
    """Walk arc-length from t_start to t_end, alternating dash/gap
    according to pattern (with period_offset = within-period position
    at t_start). Emit one sub-path per dash interval — its commands
    follow anchors_walk's geometry between the dash's start and end
    arc-length parameters.

    pattern is even-length [d0, g0, d1, g1, ...]. Even indices are
    dashes; odd indices are gaps.
    """
    out: list[tuple[tuple, ...]] = []
    period = sum(pattern)
    if period <= 0:
        return out

    # Find the (within-pattern offset, current pattern index) at t_start.
    # period_offset is the cumulative position within the pattern from
    # its start. Convert to (idx, offset_in_idx).
    cur_idx, offset_in_idx = _locate_in_pattern(period_offset, pattern)

    t = t_start
    while t < t_end - 1e-12:
        seg_len_remaining = pattern[cur_idx] - offset_in_idx
        next_t = min(t + seg_len_remaining, t_end)
        is_dash = (cur_idx % 2 == 0)
        if is_dash and next_t > t + 1e-12:
            sub = _subpath_between(anchors_walk, cum_lengths, t, next_t)
            if sub is not None:
                out.append(sub)
        # Advance pattern position
        consumed = next_t - t
        offset_in_idx += consumed
        if offset_in_idx >= pattern[cur_idx] - 1e-12:
            offset_in_idx = 0.0
            cur_idx = (cur_idx + 1) % len(pattern)
        t = next_t
    return out


def _locate_in_pattern(
    offset: float, pattern: tuple[float, ...]
) -> tuple[int, float]:
    """Convert a within-pattern offset to (pattern_index, offset_in_index)."""
    period = sum(pattern)
    if period <= 0:
        return 0, 0.0
    o = offset % period
    for i, w in enumerate(pattern):
        if o < w - 1e-12:
            return i, o
        o -= w
    return 0, 0.0


def _subpath_between(
    anchors: list[tuple[float, float]],
    cum_lengths: list[float],
    t0: float,
    t1: float,
) -> tuple[tuple, ...] | None:
    """Return the path commands for the segment of `anchors` between
    arc-length parameters t0 and t1. Returns None if t0 >= t1.

    For a lines-only polyline this is straightforward: locate the
    segments containing t0 and t1, interpolate the start/end points,
    and emit M start, L intermediate-anchors..., L end.
    """
    if t1 <= t0 + 1e-12:
        return None
    p0 = _interpolate(anchors, cum_lengths, t0)
    p1 = _interpolate(anchors, cum_lengths, t1)
    i = _locate_segment(cum_lengths, t0)
    j = _locate_segment(cum_lengths, t1)
    cmds: list[tuple] = [("M", p0[0], p0[1])]
    # Intermediate anchors strictly between (i+1) and (j) inclusive.
    for k in range(i + 1, j + 1):
        cmds.append(("L", anchors[k][0], anchors[k][1]))
    # Avoid emitting a redundant final L when p1 coincides with the
    # last anchor we just emitted.
    last_x, last_y = cmds[-1][1], cmds[-1][2]
    if abs(last_x - p1[0]) > 1e-9 or abs(last_y - p1[1]) > 1e-9:
        cmds.append(("L", p1[0], p1[1]))
    return tuple(cmds)


def _interpolate(
    anchors: list[tuple[float, float]],
    cum_lengths: list[float],
    t: float,
) -> tuple[float, float]:
    """Find the (x, y) point at arc-length t along the polyline."""
    if t <= 0:
        return anchors[0]
    total = cum_lengths[-1]
    if t >= total:
        return anchors[-1]
    i = _locate_segment(cum_lengths, t)
    seg_l = cum_lengths[i + 1] - cum_lengths[i]
    if seg_l <= 0:
        return anchors[i]
    alpha = (t - cum_lengths[i]) / seg_l
    a = anchors[i]
    b = anchors[i + 1]
    return (a[0] + alpha * (b[0] - a[0]), a[1] + alpha * (b[1] - a[1]))


def _locate_segment(cum_lengths: list[float], t: float) -> int:
    """Find the segment index i such that cum_lengths[i] <= t <
    cum_lengths[i+1]. Clamps to the valid range."""
    n = len(cum_lengths) - 1
    if t <= cum_lengths[0]:
        return 0
    if t >= cum_lengths[-1]:
        return n - 1
    # Linear search — fine for typical anchor counts (<= dozens).
    for i in range(n):
        if cum_lengths[i] <= t < cum_lengths[i + 1]:
            return i
    return n - 1


def _cumulative(values: list[float]) -> list[float]:
    out = [0.0]
    s = 0.0
    for v in values[1:]:
        s += v
        out.append(s)
    return out
