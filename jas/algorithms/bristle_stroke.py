"""Bristle brush: N semi-transparent bristle lines spread across the brush
width, each following the path at a fixed perpendicular offset.

Port of jas_dioxus/src/algorithms/bristle_stroke.rs (BRUSHES.md §Brush types
> Bristle). Reuses art_along_path's _flatten. The caller strokes each
polyline in the stroke colour with alpha() / line_width(). Phase 1: straight
offset bristles, first subpath.
"""

import math
from dataclasses import dataclass

from algorithms.art_along_path import _flatten


@dataclass
class BristleBrush:
    size: float          # diameter at 1 pt stroke
    density: float       # percent -> bristle count
    thickness: float     # percent -> per-bristle line width
    opacity: float       # percent -> per-bristle alpha
    stroke_weight: float  # pt

    def count(self) -> int:
        return min(max(round(self.density / 12.5), 2), 12)

    def line_width(self) -> float:
        bw = self.size * self.stroke_weight
        return max((self.thickness / 100.0) * (bw / self.count()), 0.5)

    def alpha(self) -> float:
        return min(max(self.opacity / 100.0, 0.0), 1.0)


def bristle_stroke(commands, brush: "BristleBrush"):
    """Bristle polylines: one per bristle, each the path offset perpendicular
    by that bristle's centre offset. [] for degenerate input."""
    pts = _flatten(commands)
    if len(pts) < 2:
        return []
    bw = brush.size * brush.stroke_weight
    if bw <= 0:
        return []
    n = brush.count()
    m = len(pts)
    normals = []
    for i in range(m):
        if i + 1 < m:
            tx, ty = pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1]
        else:
            tx, ty = pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]
        length = math.hypot(tx, ty)
        normals.append((-ty / length, tx / length) if length > 0 else (0.0, 1.0))
    out = []
    for b in range(n):
        oc = (b / (n - 1) - 0.5) * bw
        line = []
        for i in range(m):
            nx, ny = normals[i]
            line.append((pts[i][0] + nx * oc, pts[i][1] + ny * oc))
        out.append(line)
    return out
