"""Pane rendering helpers: pure functions that compute rendering data
from PaneLayout state. No Qt code."""

from __future__ import annotations
from dataclasses import dataclass
from workspace.pane import (
    PaneLayout, PaneKind, PaneConfig, EdgeSide, SnapConstraint,
    PaneTarget,
)


@dataclass
class PaneGeometry:
    id: int
    kind: PaneKind
    config: PaneConfig
    x: float
    y: float
    width: float
    height: float
    z_index: int
    visible: bool


@dataclass
class SharedBorder:
    snap_idx: int
    x: float
    y: float
    width: float
    height: float
    is_vertical: bool


@dataclass
class SnapLine:
    x: float
    y: float
    width: float
    height: float


def compute_pane_geometries(pl: PaneLayout | None) -> list[PaneGeometry]:
    if pl is None:
        return []
    maximized = pl.canvas_maximized
    result = []
    for p in pl.panes:
        visible = True if p.kind == PaneKind.CANVAS else pl.is_pane_visible(p.kind)
        if p.kind == PaneKind.CANVAS and maximized:
            x, y, w, h, z = 0, 0, pl.viewport_width, pl.viewport_height, 0
        else:
            x, y, w, h, z = p.x, p.y, p.width, p.height, pl.pane_z_index(p.id)
        result.append(PaneGeometry(
            id=p.id, kind=p.kind, config=p.config,
            x=x, y=y, width=w, height=h, z_index=z, visible=visible
        ))
    return result


def compute_shared_borders(pl: PaneLayout | None) -> list[SharedBorder]:
    if pl is None or pl.canvas_maximized:
        return []
    result = []
    for i, snap in enumerate(pl.snaps):
        if not isinstance(snap.target, PaneTarget):
            continue
        other_id, other_edge = snap.target.pane_id, snap.target.edge
        is_vert = snap.edge == EdgeSide.RIGHT and other_edge == EdgeSide.LEFT
        is_horiz = snap.edge == EdgeSide.BOTTOM and other_edge == EdgeSide.TOP
        if not is_vert and not is_horiz:
            continue
        pa = pl.find_pane(snap.pane)
        pb = pl.find_pane(other_id)
        if not pa or not pb:
            continue
        if pa.config.fixed_width or pb.config.fixed_width:
            continue
        if is_vert:
            bx = pa.x + pa.width
            by = max(pa.y, pb.y)
            bh = min(pa.y + pa.height, pb.y + pb.height) - by
            if bh > 0:
                result.append(SharedBorder(i, bx - 3, by, 6, bh, True))
        else:
            by2 = pa.y + pa.height
            bx2 = max(pa.x, pb.x)
            bw = min(pa.x + pa.width, pb.x + pb.width) - bx2
            if bw > 0:
                result.append(SharedBorder(i, bx2, by2 - 3, bw, 6, False))
    return result


def compute_snap_lines(preview: list[SnapConstraint], pl: PaneLayout | None) -> list[SnapLine]:
    if pl is None:
        return []
    result = []
    for snap in preview:
        p = pl.find_pane(snap.pane)
        if not p:
            continue
        coord = PaneLayout.pane_edge_coord(p, snap.edge)
        if snap.edge in (EdgeSide.LEFT, EdgeSide.RIGHT):
            result.append(SnapLine(coord - 2, p.y, 4, p.height))
        else:
            result.append(SnapLine(p.x, coord - 2, p.width, 4))
    return result
