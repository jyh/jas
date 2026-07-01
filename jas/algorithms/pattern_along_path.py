"""Pattern brush: the side artwork tile repeated along the stroke path.

Port of jas_dioxus/src/algorithms/pattern_along_path.rs (BRUSHES.md §Brush
types > Pattern). Reuses art_along_path's _flatten + _point_at_arclength.
Phase 1: SIDE tile only (corner tiles deferred), polygon artwork.
"""

import math
from dataclasses import dataclass

from algorithms.art_along_path import _flatten, _point_at_arclength


@dataclass
class PatternBrush:
    tile_width: float
    tile_height: float
    side: list       # list of side-tile polygons, each a list of (x, y)
    scale: float     # percent
    spacing: float   # percent of tile width
    flip_across: bool
    flip_along: bool
    stroke_weight: float  # pt


def pattern_along_path(commands, brush: "PatternBrush"):
    """Tile ``brush.side`` along ``commands``. Returns one warped polygon
    per (tile placement x side polygon); [] for degenerate input."""
    if brush.tile_width <= 0 or brush.tile_height <= 0:
        return []
    pts = _flatten(commands)
    if len(pts) < 2:
        return []
    cum = [0.0] * len(pts)
    for i in range(1, len(pts)):
        cum[i] = cum[i - 1] + math.hypot(pts[i][0] - pts[i - 1][0],
                                         pts[i][1] - pts[i - 1][1])
    total = cum[-1]
    if total <= 0:
        return []
    ribbon = (brush.scale / 100.0) * brush.stroke_weight
    tile_w = ribbon * (brush.tile_width / brush.tile_height)
    if tile_w <= 0:
        return []
    gap = tile_w * (brush.spacing / 100.0)
    step = tile_w + gap
    if step <= 0:
        return []
    n = max(int(total // step), 1)
    out = []
    for i in range(n):
        start = i * step
        for poly in brush.side:
            warped = []
            for ax, ay in poly:
                u = min(max(ax / brush.tile_width, 0.0), 1.0)
                if brush.flip_along:
                    u = 1.0 - u
                s = start + u * tile_w
                px, py, tan = _point_at_arclength(pts, cum, total, s)
                off = (ay - brush.tile_height / 2.0) / brush.tile_height * ribbon
                if brush.flip_across:
                    off = -off
                nx = -math.sin(tan)
                ny = math.cos(tan)
                warped.append((px + nx * off, py + ny * off))
            out.append(warped)
    return out
