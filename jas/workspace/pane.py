"""Pane layout: floating, movable, resizable panes.

A PaneLayout manages the positions, sizes, and snap constraints
for the top-level panes (toolbar, canvas, dock). Each Pane carries
a PaneConfig that drives generic behavior like tiling, resizing,
and title bar chrome.

This module contains only pure data types and state operations — no
rendering code.
"""

from __future__ import annotations
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Optional

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

MIN_TOOLBAR_WIDTH = 72.0
MIN_TOOLBAR_HEIGHT = 200.0
MIN_CANVAS_WIDTH = 200.0
MIN_CANVAS_HEIGHT = 200.0
MIN_PANE_DOCK_WIDTH = 150.0
MIN_PANE_DOCK_HEIGHT = 100.0
DEFAULT_TOOLBAR_WIDTH = 72.0
DEFAULT_PANE_DOCK_WIDTH = 240.0
SNAP_DISTANCE = 20.0
BORDER_HIT_TOLERANCE = 6.0
MIN_PANE_VISIBLE = 50.0

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

class PaneKind(Enum):
    TOOLBAR = auto()
    CANVAS = auto()
    DOCK = auto()

class TileWidth(Enum):
    FIXED = auto()
    KEEP_CURRENT = auto()
    FLEX = auto()

@dataclass
class TileFixed:
    width: float

@dataclass
class PaneConfig:
    label: str
    min_width: float
    min_height: float
    fixed_width: bool
    closable: bool
    collapsible: bool
    maximizable: bool
    always_visible: bool
    collapsed_width: float | None
    tile_order: int
    tile_width: object  # TileFixed | TileWidth.KEEP_CURRENT | TileWidth.FLEX

    @staticmethod
    def for_kind(kind: PaneKind) -> PaneConfig:
        if kind == PaneKind.TOOLBAR:
            return PaneConfig("Tools", MIN_TOOLBAR_WIDTH, MIN_TOOLBAR_HEIGHT,
                              True, True, False, False, False, None,
                              0, TileFixed(DEFAULT_TOOLBAR_WIDTH))
        elif kind == PaneKind.CANVAS:
            return PaneConfig("Canvas", MIN_CANVAS_WIDTH, MIN_CANVAS_HEIGHT,
                              False, False, False, True, True, None,
                              1, TileWidth.FLEX)
        else:
            return PaneConfig("Panels", MIN_PANE_DOCK_WIDTH, MIN_PANE_DOCK_HEIGHT,
                              False, True, True, False, False, 36.0,
                              2, TileWidth.KEEP_CURRENT)

@dataclass
class Pane:
    id: int
    kind: PaneKind
    config: PaneConfig
    x: float
    y: float
    width: float
    height: float

class EdgeSide(Enum):
    LEFT = auto()
    RIGHT = auto()
    TOP = auto()
    BOTTOM = auto()

@dataclass(frozen=True)
class WindowTarget:
    edge: EdgeSide

@dataclass(frozen=True)
class PaneTarget:
    pane_id: int
    edge: EdgeSide

@dataclass(frozen=True)
class SnapConstraint:
    pane: int
    edge: EdgeSide
    target: object  # WindowTarget | PaneTarget

# ---------------------------------------------------------------------------
# PaneLayout
# ---------------------------------------------------------------------------

ALL_EDGES = [EdgeSide.LEFT, EdgeSide.RIGHT, EdgeSide.TOP, EdgeSide.BOTTOM]

class PaneLayout:
    def __init__(self, panes: list[Pane], snaps: list[SnapConstraint],
                 z_order: list[int], hidden_panes: list[PaneKind],
                 canvas_maximized: bool, viewport_width: float,
                 viewport_height: float, next_pane_id: int):
        self.panes = panes
        self.snaps = snaps
        self.z_order = z_order
        self.hidden_panes = hidden_panes
        self.canvas_maximized = canvas_maximized
        self.viewport_width = viewport_width
        self.viewport_height = viewport_height
        self.next_pane_id = next_pane_id

    # -- Construction --

    @staticmethod
    def default_three_pane(viewport_w: float, viewport_h: float) -> PaneLayout:
        toolbar_w = DEFAULT_TOOLBAR_WIDTH
        dock_w = DEFAULT_PANE_DOCK_WIDTH
        canvas_w = max(viewport_w - toolbar_w - dock_w, MIN_CANVAS_WIDTH)
        tid, cid, did = 0, 1, 2
        panes = [
            Pane(tid, PaneKind.TOOLBAR, PaneConfig.for_kind(PaneKind.TOOLBAR),
                 0, 0, toolbar_w, viewport_h),
            Pane(cid, PaneKind.CANVAS, PaneConfig.for_kind(PaneKind.CANVAS),
                 toolbar_w, 0, canvas_w, viewport_h),
            Pane(did, PaneKind.DOCK, PaneConfig.for_kind(PaneKind.DOCK),
                 toolbar_w + canvas_w, 0, dock_w, viewport_h),
        ]
        snaps = [
            SnapConstraint(tid, EdgeSide.LEFT, WindowTarget(EdgeSide.LEFT)),
            SnapConstraint(tid, EdgeSide.TOP, WindowTarget(EdgeSide.TOP)),
            SnapConstraint(tid, EdgeSide.BOTTOM, WindowTarget(EdgeSide.BOTTOM)),
            SnapConstraint(tid, EdgeSide.RIGHT, PaneTarget(cid, EdgeSide.LEFT)),
            SnapConstraint(cid, EdgeSide.TOP, WindowTarget(EdgeSide.TOP)),
            SnapConstraint(cid, EdgeSide.BOTTOM, WindowTarget(EdgeSide.BOTTOM)),
            SnapConstraint(cid, EdgeSide.RIGHT, PaneTarget(did, EdgeSide.LEFT)),
            SnapConstraint(did, EdgeSide.RIGHT, WindowTarget(EdgeSide.RIGHT)),
            SnapConstraint(did, EdgeSide.TOP, WindowTarget(EdgeSide.TOP)),
            SnapConstraint(did, EdgeSide.BOTTOM, WindowTarget(EdgeSide.BOTTOM)),
        ]
        return PaneLayout(panes, snaps, [cid, tid, did], [], False,
                          viewport_w, viewport_h, 3)

    # -- Lookup --

    def find_pane(self, id: int) -> Optional[Pane]:
        for p in self.panes:
            if p.id == id:
                return p
        return None

    def pane_by_kind(self, kind: PaneKind) -> Optional[Pane]:
        for p in self.panes:
            if p.kind == kind:
                return p
        return None

    # -- Move --

    def set_pane_position(self, id: int, x: float, y: float):
        p = self.find_pane(id)
        if p:
            p.x, p.y = x, y
        self.snaps = [s for s in self.snaps
                      if s.pane != id and not (isinstance(s.target, PaneTarget) and s.target.pane_id == id)]

    # -- Resize --

    def resize_pane(self, id: int, width: float, height: float):
        p = self.find_pane(id)
        if p:
            p.width = max(width, p.config.min_width)
            p.height = max(height, p.config.min_height)

    # -- Snap detection --

    @staticmethod
    def pane_edge_coord(pane: Pane, edge: EdgeSide) -> float:
        if edge == EdgeSide.LEFT: return pane.x
        if edge == EdgeSide.RIGHT: return pane.x + pane.width
        if edge == EdgeSide.TOP: return pane.y
        return pane.y + pane.height

    @staticmethod
    def _window_edge_coord(edge: EdgeSide, vw: float, vh: float) -> float:
        if edge in (EdgeSide.LEFT, EdgeSide.TOP): return 0.0
        if edge == EdgeSide.RIGHT: return vw
        return vh

    @staticmethod
    def _edges_can_snap(a: EdgeSide, b: EdgeSide) -> bool:
        return (a, b) in ((EdgeSide.RIGHT, EdgeSide.LEFT), (EdgeSide.LEFT, EdgeSide.RIGHT),
                          (EdgeSide.BOTTOM, EdgeSide.TOP), (EdgeSide.TOP, EdgeSide.BOTTOM))

    def detect_snaps(self, dragged: int, viewport_w: float, viewport_h: float) -> list[SnapConstraint]:
        dp = self.find_pane(dragged)
        if not dp:
            return []
        result = []
        for edge in ALL_EDGES:
            coord = self.pane_edge_coord(dp, edge)
            wcoord = self._window_edge_coord(edge, viewport_w, viewport_h)
            if abs(coord - wcoord) <= SNAP_DISTANCE:
                result.append(SnapConstraint(dragged, edge, WindowTarget(edge)))
        for other in self.panes:
            if other.id == dragged:
                continue
            for d_edge in ALL_EDGES:
                for o_edge in ALL_EDGES:
                    if not self._edges_can_snap(d_edge, o_edge):
                        continue
                    d_coord = self.pane_edge_coord(dp, d_edge)
                    o_coord = self.pane_edge_coord(other, o_edge)
                    if abs(d_coord - o_coord) <= SNAP_DISTANCE:
                        if d_edge in (EdgeSide.LEFT, EdgeSide.RIGHT):
                            overlaps = dp.y < other.y + other.height and dp.y + dp.height > other.y
                        else:
                            overlaps = dp.x < other.x + other.width and dp.x + dp.width > other.x
                        if overlaps:
                            if d_edge in (EdgeSide.RIGHT, EdgeSide.BOTTOM):
                                snap = SnapConstraint(dragged, d_edge, PaneTarget(other.id, o_edge))
                            else:
                                snap = SnapConstraint(other.id, o_edge, PaneTarget(dragged, d_edge))
                            result.append(snap)
        return result

    # -- Snap application --

    def _align_pane_impl(self, pane_id: int, snaps: list[SnapConstraint],
                         viewport_w: float, viewport_h: float):
        for snap in snaps:
            if snap.pane == pane_id:
                if isinstance(snap.target, WindowTarget):
                    tc = self._window_edge_coord(snap.target.edge, viewport_w, viewport_h)
                elif isinstance(snap.target, PaneTarget):
                    other = self.find_pane(snap.target.pane_id)
                    if not other:
                        continue
                    tc = self.pane_edge_coord(other, snap.target.edge)
                else:
                    continue
                p = self.find_pane(pane_id)
                if p:
                    if snap.edge == EdgeSide.LEFT: p.x = tc
                    elif snap.edge == EdgeSide.RIGHT: p.x = tc - p.width
                    elif snap.edge == EdgeSide.TOP: p.y = tc
                    elif snap.edge == EdgeSide.BOTTOM: p.y = tc - p.height
            elif isinstance(snap.target, PaneTarget) and snap.target.pane_id == pane_id:
                anchor = self.find_pane(snap.pane)
                if not anchor:
                    continue
                ac = self.pane_edge_coord(anchor, snap.edge)
                p = self.find_pane(pane_id)
                if p:
                    te = snap.target.edge
                    if te == EdgeSide.LEFT: p.x = ac
                    elif te == EdgeSide.RIGHT: p.x = ac - p.width
                    elif te == EdgeSide.TOP: p.y = ac
                    elif te == EdgeSide.BOTTOM: p.y = ac - p.height

    def align_to_snaps(self, pane_id: int, snaps: list[SnapConstraint],
                       viewport_w: float, viewport_h: float):
        self._align_pane_impl(pane_id, snaps, viewport_w, viewport_h)

    def apply_snaps(self, pane_id: int, new_snaps: list[SnapConstraint],
                    viewport_w: float, viewport_h: float):
        self.snaps = [s for s in self.snaps
                      if s.pane != pane_id and not (isinstance(s.target, PaneTarget) and s.target.pane_id == pane_id)]
        self._align_pane_impl(pane_id, new_snaps, viewport_w, viewport_h)
        self.snaps.extend(new_snaps)

    # -- Shared border --

    def shared_border_at(self, x: float, y: float, tolerance: float) -> Optional[tuple[int, EdgeSide]]:
        for i, snap in enumerate(self.snaps):
            if not isinstance(snap.target, PaneTarget):
                continue
            other_id, other_edge = snap.target.pane_id, snap.target.edge
            is_vertical = snap.edge == EdgeSide.RIGHT and other_edge == EdgeSide.LEFT
            is_horizontal = snap.edge == EdgeSide.BOTTOM and other_edge == EdgeSide.TOP
            if not is_vertical and not is_horizontal:
                continue
            pa = self.find_pane(snap.pane)
            pb = self.find_pane(other_id)
            if not pa or not pb:
                continue
            if is_vertical:
                bx = pa.x + pa.width
                min_y, max_y = max(pa.y, pb.y), min(pa.y + pa.height, pb.y + pb.height)
                if abs(x - bx) <= tolerance and min_y <= y <= max_y:
                    return (i, EdgeSide.LEFT)
            else:
                by = pa.y + pa.height
                min_x, max_x = max(pa.x, pb.x), min(pa.x + pa.width, pb.x + pb.width)
                if abs(y - by) <= tolerance and min_x <= x <= max_x:
                    return (i, EdgeSide.TOP)
        return None

    # -- Border dragging --

    def _propagate_border_shift(self, source_pane: int, source_edge: EdgeSide, is_vertical: bool):
        chained = [(s.target.pane_id, s.target.edge) for s in self.snaps
                   if s.pane == source_pane and s.edge == source_edge and isinstance(s.target, PaneTarget)]
        source = self.find_pane(source_pane)
        if not source:
            return
        ec = self.pane_edge_coord(source, source_edge)
        for pid, pe in chained:
            p = self.find_pane(pid)
            if not p:
                continue
            if is_vertical:
                if pe == EdgeSide.LEFT: p.x = ec
                elif pe == EdgeSide.RIGHT: p.x = ec - p.width
            else:
                if pe == EdgeSide.TOP: p.y = ec
                elif pe == EdgeSide.BOTTOM: p.y = ec - p.height

    def drag_shared_border(self, snap_idx: int, delta: float):
        if snap_idx >= len(self.snaps):
            return
        snap = self.snaps[snap_idx]
        if not isinstance(snap.target, PaneTarget):
            return
        other_id = snap.target.pane_id
        pa = self.find_pane(snap.pane)
        pb = self.find_pane(other_id)
        if not pa or not pb:
            return
        is_vertical = snap.edge == EdgeSide.RIGHT
        if is_vertical:
            max_expand = 0 if pb.config.fixed_width else pb.width - pb.config.min_width
            max_shrink = 0 if pa.config.fixed_width else pa.width - pa.config.min_width
            clamped = min(max(delta, -max_shrink), max_expand)
            if not pa.config.fixed_width:
                pa.width += clamped
            if not pb.config.fixed_width:
                pb.x += clamped
                pb.width -= clamped
            self._propagate_border_shift(other_id, EdgeSide.RIGHT, True)
        else:
            max_expand = 0 if pb.config.fixed_width else pb.height - pb.config.min_height
            max_shrink = 0 if pa.config.fixed_width else pa.height - pa.config.min_height
            clamped = min(max(delta, -max_shrink), max_expand)
            if not pa.config.fixed_width:
                pa.height += clamped
            if not pb.config.fixed_width:
                pb.y += clamped
                pb.height -= clamped
            self._propagate_border_shift(other_id, EdgeSide.BOTTOM, False)

    # -- Canvas maximization --

    def toggle_canvas_maximized(self):
        self.canvas_maximized = not self.canvas_maximized

    # -- Tiling --

    def tile_panes(self, collapsed_override: Optional[tuple[int, float]] = None):
        vw, vh = self.viewport_width, self.viewport_height
        self.canvas_maximized = False
        self.hidden_panes = []
        visible = [(p.id, p.config.tile_width, p.width, p.config.tile_order) for p in self.panes]
        visible.sort(key=lambda t: t[3])
        if not visible:
            return
        fixed_total = 0.0
        flex_count = 0
        widths = []
        for pid, tw, cw, _ in visible:
            if isinstance(tw, TileFixed):
                fixed_total += tw.width
                widths.append(tw.width)
            elif tw == TileWidth.KEEP_CURRENT:
                w = cw
                if collapsed_override and collapsed_override[0] == pid:
                    w = collapsed_override[1]
                fixed_total += w
                widths.append(w)
            else:
                flex_count += 1
                widths.append(0.0)
        if flex_count > 0:
            min_flex = max((p.config.min_width for p in self.panes if p.config.tile_width == TileWidth.FLEX), default=0)
            flex_each = max((vw - fixed_total) / flex_count, min_flex)
        else:
            flex_each = 0.0
        widths = [flex_each if (isinstance(tw, type) and False) or tw == TileWidth.FLEX else w
                  for (_, tw, _, _), w in zip(visible, widths)]
        # Correct flex assignment
        final_widths = []
        for (_, tw, _, _), w in zip(visible, widths):
            if tw == TileWidth.FLEX:
                final_widths.append(flex_each)
            else:
                final_widths.append(w)
        x = 0.0
        for (pid, _, _, _), w in zip(visible, final_widths):
            p = self.find_pane(pid)
            if p:
                p.x, p.y, p.width, p.height = x, 0, w, vh
            x += w
        self.snaps = []
        n = len(visible)
        for i, (pid, _, _, _) in enumerate(visible):
            if i == 0:
                self.snaps.append(SnapConstraint(pid, EdgeSide.LEFT, WindowTarget(EdgeSide.LEFT)))
            if i == n - 1:
                self.snaps.append(SnapConstraint(pid, EdgeSide.RIGHT, WindowTarget(EdgeSide.RIGHT)))
            self.snaps.append(SnapConstraint(pid, EdgeSide.TOP, WindowTarget(EdgeSide.TOP)))
            self.snaps.append(SnapConstraint(pid, EdgeSide.BOTTOM, WindowTarget(EdgeSide.BOTTOM)))
            if i + 1 < n:
                nid = visible[i + 1][0]
                self.snaps.append(SnapConstraint(pid, EdgeSide.RIGHT, PaneTarget(nid, EdgeSide.LEFT)))

    # -- Pane visibility --

    def hide_pane(self, kind: PaneKind):
        if kind not in self.hidden_panes:
            self.hidden_panes.append(kind)

    def show_pane(self, kind: PaneKind):
        self.hidden_panes = [k for k in self.hidden_panes if k != kind]

    def is_pane_visible(self, kind: PaneKind) -> bool:
        return kind not in self.hidden_panes

    # -- Z-order --

    def bring_pane_to_front(self, id: int):
        if id in self.z_order:
            self.z_order.remove(id)
            self.z_order.append(id)

    def pane_z_index(self, id: int) -> int:
        try:
            return self.z_order.index(id)
        except ValueError:
            return 0

    # -- Viewport resize --

    def on_viewport_resize(self, new_w: float, new_h: float):
        if self.viewport_width <= 0 or self.viewport_height <= 0:
            self.viewport_width, self.viewport_height = new_w, new_h
            return
        sx, sy = new_w / self.viewport_width, new_h / self.viewport_height
        for p in self.panes:
            p.x *= sx
            p.y *= sy
            p.width = max(p.width * sx, p.config.min_width)
            p.height = max(p.height * sy, p.config.min_height)
        self.viewport_width, self.viewport_height = new_w, new_h
        self.clamp_panes(new_w, new_h)

    # -- Clamping --

    def clamp_panes(self, viewport_w: float, viewport_h: float):
        for p in self.panes:
            p.x = min(max(p.x, -p.width + MIN_PANE_VISIBLE), viewport_w - MIN_PANE_VISIBLE)
            p.y = min(max(p.y, -p.height + MIN_PANE_VISIBLE), viewport_h - MIN_PANE_VISIBLE)

    # -- Repair snaps --

    def repair_snaps(self, viewport_w: float, viewport_h: float):
        tolerance = SNAP_DISTANCE
        pane_copies = list(self.panes)
        for a in pane_copies:
            for edge in ALL_EDGES:
                coord = self.pane_edge_coord(a, edge)
                wcoord = self._window_edge_coord(edge, viewport_w, viewport_h)
                if abs(coord - wcoord) <= tolerance:
                    exists = any(s.pane == a.id and s.edge == edge and s.target == WindowTarget(edge)
                                 for s in self.snaps)
                    if not exists:
                        self.snaps.append(SnapConstraint(a.id, edge, WindowTarget(edge)))
            for b in pane_copies:
                if a.id == b.id:
                    continue
                if abs(self.pane_edge_coord(a, EdgeSide.RIGHT) - self.pane_edge_coord(b, EdgeSide.LEFT)) <= tolerance:
                    if a.y < b.y + b.height and a.y + a.height > b.y:
                        exists = any(s.pane == a.id and s.edge == EdgeSide.RIGHT
                                     and s.target == PaneTarget(b.id, EdgeSide.LEFT) for s in self.snaps)
                        if not exists:
                            self.snaps.append(SnapConstraint(a.id, EdgeSide.RIGHT, PaneTarget(b.id, EdgeSide.LEFT)))
                if abs(self.pane_edge_coord(a, EdgeSide.BOTTOM) - self.pane_edge_coord(b, EdgeSide.TOP)) <= tolerance:
                    if a.x < b.x + b.width and a.x + a.width > b.x:
                        exists = any(s.pane == a.id and s.edge == EdgeSide.BOTTOM
                                     and s.target == PaneTarget(b.id, EdgeSide.TOP) for s in self.snaps)
                        if not exists:
                            self.snaps.append(SnapConstraint(a.id, EdgeSide.BOTTOM, PaneTarget(b.id, EdgeSide.TOP)))

# ---------------------------------------------------------------------------
# Serialization
# ---------------------------------------------------------------------------

def pane_layout_to_dict(pl: PaneLayout) -> dict:
    def _config(c):
        tw = c.tile_width
        if isinstance(tw, TileFixed):
            tw_d = {"Fixed": tw.width}
        elif tw == TileWidth.KEEP_CURRENT:
            tw_d = "KeepCurrent"
        else:
            tw_d = "Flex"
        result = {"label": c.label, "min_width": c.min_width, "min_height": c.min_height,
                "fixed_width": c.fixed_width, "closable": c.closable,
                "collapsible": c.collapsible, "maximizable": c.maximizable,
                "always_visible": c.always_visible,
                "tile_order": c.tile_order, "tile_width": tw_d}
        if c.collapsed_width is not None:
            result["collapsed_width"] = c.collapsed_width
        return result
    def _pane(p):
        return {"id": p.id, "kind": p.kind.name, "config": _config(p.config),
                "x": p.x, "y": p.y, "width": p.width, "height": p.height}
    def _target(t):
        if isinstance(t, WindowTarget):
            return {"Window": t.edge.name}
        return {"Pane": [t.pane_id, t.edge.name]}
    def _snap(s):
        return {"pane": s.pane, "edge": s.edge.name, "target": _target(s.target)}
    return {
        "panes": [_pane(p) for p in pl.panes],
        "snaps": [_snap(s) for s in pl.snaps],
        "z_order": pl.z_order,
        "hidden_panes": [k.name for k in pl.hidden_panes],
        "canvas_maximized": pl.canvas_maximized,
        "viewport_width": pl.viewport_width,
        "viewport_height": pl.viewport_height,
        "next_pane_id": pl.next_pane_id,
    }

def pane_layout_from_dict(d: dict) -> PaneLayout:
    def _tw(v):
        if isinstance(v, dict) and "Fixed" in v:
            return TileFixed(v["Fixed"])
        if v == "KeepCurrent":
            return TileWidth.KEEP_CURRENT
        return TileWidth.FLEX
    def _config(cd, kind):
        try:
            return PaneConfig(cd["label"], cd["min_width"], cd["min_height"],
                              cd["fixed_width"], cd["closable"], cd["collapsible"],
                              cd["maximizable"],
                              cd.get("always_visible", False),
                              cd.get("collapsed_width"),
                              cd["tile_order"], _tw(cd["tile_width"]))
        except (KeyError, TypeError):
            return PaneConfig.for_kind(kind)
    def _pane(pd):
        kind = PaneKind[pd["kind"]]
        config = _config(pd.get("config", {}), kind) if "config" in pd else PaneConfig.for_kind(kind)
        return Pane(pd["id"], kind, config, pd["x"], pd["y"], pd["width"], pd["height"])
    def _target(td):
        if "Window" in td:
            return WindowTarget(EdgeSide[td["Window"]])
        pid, edge = td["Pane"]
        return PaneTarget(pid, EdgeSide[edge])
    def _snap(sd):
        return SnapConstraint(sd["pane"], EdgeSide[sd["edge"]], _target(sd["target"]))
    return PaneLayout(
        panes=[_pane(p) for p in d["panes"]],
        snaps=[_snap(s) for s in d["snaps"]],
        z_order=d["z_order"],
        hidden_panes=[PaneKind[k] for k in d.get("hidden_panes", [])],
        canvas_maximized=d.get("canvas_maximized", False),
        viewport_width=d["viewport_width"],
        viewport_height=d["viewport_height"],
        next_pane_id=d["next_pane_id"],
    )
