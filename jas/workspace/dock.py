"""Dock and panel infrastructure.

A DockLayout manages multiple docks: anchored docks snapped to screen
edges and floating docks at arbitrary positions. Each Dock contains a
vertical list of PanelGroups. Each group has tabbed PanelKind entries,
one of which is active at a time.

This module contains only pure data types and state operations — no
rendering code.
"""

from __future__ import annotations
import json
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Optional

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

MIN_DOCK_WIDTH = 150.0
MAX_DOCK_WIDTH = 500.0
MIN_GROUP_HEIGHT = 40.0
MIN_CANVAS_WIDTH = 200.0
DEFAULT_DOCK_WIDTH = 240.0
DEFAULT_FLOATING_WIDTH = 220.0
SNAP_DISTANCE = 20.0
DEFAULT_LAYOUT_NAME = "Default"

# ---------------------------------------------------------------------------
# Core types
# ---------------------------------------------------------------------------

class DockEdge(Enum):
    LEFT = auto()
    RIGHT = auto()
    BOTTOM = auto()

class PanelKind(Enum):
    LAYERS = auto()
    COLOR = auto()
    STROKE = auto()
    PROPERTIES = auto()

@dataclass
class PanelGroup:
    panels: list[PanelKind]
    active: int = 0
    collapsed: bool = False
    height: Optional[float] = None

    def active_panel(self) -> Optional[PanelKind]:
        if self.active < len(self.panels):
            return self.panels[self.active]
        return None

@dataclass
class Dock:
    id: int
    groups: list[PanelGroup]
    collapsed: bool = False
    auto_hide: bool = False
    width: float = DEFAULT_DOCK_WIDTH
    min_width: float = MIN_DOCK_WIDTH

@dataclass
class FloatingDock:
    dock: Dock
    x: float
    y: float

# ---------------------------------------------------------------------------
# Addressing
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class GroupAddr:
    dock_id: int
    group_idx: int

@dataclass(frozen=True)
class PanelAddr:
    group: GroupAddr
    panel_idx: int

# ---------------------------------------------------------------------------
# Drag state types
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class DragGroup:
    addr: GroupAddr

@dataclass(frozen=True)
class DragPanel:
    addr: PanelAddr

@dataclass(frozen=True)
class DropGroupSlot:
    dock_id: int
    group_idx: int

@dataclass(frozen=True)
class DropTabBar:
    group: GroupAddr
    index: int

@dataclass(frozen=True)
class DropEdge:
    edge: DockEdge

# ---------------------------------------------------------------------------
# AppConfig
# ---------------------------------------------------------------------------

@dataclass
class AppConfig:
    active_layout: str = DEFAULT_LAYOUT_NAME
    saved_layouts: list[str] = field(default_factory=lambda: [DEFAULT_LAYOUT_NAME])

    STORAGE_KEY = "jas_app_config"

    def to_json(self) -> str:
        return json.dumps({
            "active_layout": self.active_layout,
            "saved_layouts": self.saved_layouts,
        })

    @staticmethod
    def from_json(s: str) -> AppConfig:
        try:
            d = json.loads(s)
            return AppConfig(
                active_layout=d.get("active_layout", DEFAULT_LAYOUT_NAME),
                saved_layouts=d.get("saved_layouts", [DEFAULT_LAYOUT_NAME]),
            )
        except (json.JSONDecodeError, KeyError, TypeError):
            return AppConfig()

    def register_layout(self, name: str) -> None:
        if name not in self.saved_layouts:
            self.saved_layouts.append(name)

# ---------------------------------------------------------------------------
# DockLayout
# ---------------------------------------------------------------------------

STORAGE_PREFIX = "jas_layout:"

class DockLayout:
    def __init__(self, name: str, anchored: list[tuple[DockEdge, Dock]],
                 floating: list[FloatingDock], hidden_panels: list[PanelKind],
                 z_order: list[int], focused_panel: Optional[PanelAddr],
                 next_id: int):
        self.name = name
        self.anchored = anchored
        self.floating = floating
        self.hidden_panels = hidden_panels
        self.z_order = z_order
        self.focused_panel = focused_panel
        self._next_id = next_id
        self._generation = 0
        self._saved_generation = 0

    # -- Construction --

    @staticmethod
    def default_layout() -> DockLayout:
        return DockLayout.named(DEFAULT_LAYOUT_NAME)

    @staticmethod
    def named(name: str) -> DockLayout:
        return DockLayout(
            name=name,
            anchored=[(DockEdge.RIGHT, Dock(
                id=0,
                groups=[
                    PanelGroup(panels=[PanelKind.LAYERS]),
                    PanelGroup(panels=[PanelKind.COLOR, PanelKind.STROKE, PanelKind.PROPERTIES]),
                ],
            ))],
            floating=[],
            hidden_panels=[],
            z_order=[],
            focused_panel=None,
            next_id=1,
        )

    # -- Generation --

    def _bump(self):
        self._generation += 1

    def needs_save(self) -> bool:
        return self._generation != self._saved_generation

    def mark_saved(self):
        self._saved_generation = self._generation

    # -- Dock lookup --

    def _next_dock_id(self) -> int:
        did = self._next_id
        self._next_id += 1
        return did

    def dock(self, id: int) -> Optional[Dock]:
        for _, d in self.anchored:
            if d.id == id:
                return d
        for fd in self.floating:
            if fd.dock.id == id:
                return fd.dock
        return None

    def anchored_dock(self, edge: DockEdge) -> Optional[Dock]:
        for e, d in self.anchored:
            if e == edge:
                return d
        return None

    def floating_dock(self, id: int) -> Optional[FloatingDock]:
        for fd in self.floating:
            if fd.dock.id == id:
                return fd
        return None

    # -- Cleanup --

    def _cleanup(self, dock_id: int):
        d = self.dock(dock_id)
        if d is not None:
            d.groups = [g for g in d.groups if len(g.panels) > 0]
            for g in d.groups:
                if g.active >= len(g.panels) and len(g.panels) > 0:
                    g.active = len(g.panels) - 1
        removed = [fd.dock.id for fd in self.floating if len(fd.dock.groups) == 0]
        self.floating = [fd for fd in self.floating if len(fd.dock.groups) > 0]
        self.z_order = [zid for zid in self.z_order if zid not in removed]

    # -- Collapse --

    def toggle_dock_collapsed(self, id: int):
        d = self.dock(id)
        if d is not None:
            d.collapsed = not d.collapsed
        self._bump()

    def toggle_group_collapsed(self, addr: GroupAddr):
        d = self.dock(addr.dock_id)
        if d is not None and addr.group_idx < len(d.groups):
            d.groups[addr.group_idx].collapsed = not d.groups[addr.group_idx].collapsed
        self._bump()

    # -- Active panel --

    def set_active_panel(self, addr: PanelAddr):
        d = self.dock(addr.group.dock_id)
        if d is not None and addr.group.group_idx < len(d.groups):
            g = d.groups[addr.group.group_idx]
            if addr.panel_idx < len(g.panels):
                g.active = addr.panel_idx
        self._bump()

    # -- Move group within dock --

    def move_group_within_dock(self, dock_id: int, from_idx: int, to_idx: int):
        d = self.dock(dock_id)
        if d is not None and from_idx < len(d.groups):
            group = d.groups.pop(from_idx)
            to_idx = min(to_idx, len(d.groups))
            d.groups.insert(to_idx, group)
        self._bump()

    # -- Move group between docks --

    def move_group_to_dock(self, from_addr: GroupAddr, to_dock: int, to_idx: int):
        src = self.dock(from_addr.dock_id)
        if src is None or from_addr.group_idx >= len(src.groups):
            return
        group = src.groups.pop(from_addr.group_idx)
        dst = self.dock(to_dock)
        if dst is None:
            src.groups.insert(min(from_addr.group_idx, len(src.groups)), group)
            return
        idx = min(to_idx, len(dst.groups))
        dst.groups.insert(idx, group)
        self._cleanup(from_addr.dock_id)
        self._bump()

    # -- Detach group --

    def detach_group(self, from_addr: GroupAddr, x: float, y: float) -> Optional[int]:
        src = self.dock(from_addr.dock_id)
        if src is None or from_addr.group_idx >= len(src.groups):
            return None
        group = src.groups.pop(from_addr.group_idx)
        did = self._next_dock_id()
        self.floating.append(FloatingDock(
            dock=Dock(id=did, groups=[group], width=DEFAULT_FLOATING_WIDTH),
            x=x, y=y,
        ))
        self.z_order.append(did)
        self._cleanup(from_addr.dock_id)
        self._bump()
        return did

    # -- Reorder panel --

    def reorder_panel(self, group: GroupAddr, from_idx: int, to_idx: int):
        d = self.dock(group.dock_id)
        if d is not None and group.group_idx < len(d.groups):
            g = d.groups[group.group_idx]
            if from_idx < len(g.panels):
                panel = g.panels.pop(from_idx)
                to_idx = min(to_idx, len(g.panels))
                g.panels.insert(to_idx, panel)
                g.active = to_idx
        self._bump()

    # -- Move panel between groups --

    def move_panel_to_group(self, from_addr: PanelAddr, to: GroupAddr):
        if from_addr.group == to:
            return
        src_d = self.dock(from_addr.group.dock_id)
        if src_d is None or from_addr.group.group_idx >= len(src_d.groups):
            return
        src_g = src_d.groups[from_addr.group.group_idx]
        if from_addr.panel_idx >= len(src_g.panels):
            return
        panel = src_g.panels.pop(from_addr.panel_idx)
        dst_d = self.dock(to.dock_id)
        if dst_d is None or to.group_idx >= len(dst_d.groups):
            src_g.panels.insert(min(from_addr.panel_idx, len(src_g.panels)), panel)
            return
        dst_g = dst_d.groups[to.group_idx]
        dst_g.panels.append(panel)
        dst_g.active = len(dst_g.panels) - 1
        self._cleanup(from_addr.group.dock_id)
        self._bump()

    # -- Insert panel as new group --

    def insert_panel_as_new_group(self, from_addr: PanelAddr, to_dock: int, at_idx: int):
        src_d = self.dock(from_addr.group.dock_id)
        if src_d is None or from_addr.group.group_idx >= len(src_d.groups):
            return
        src_g = src_d.groups[from_addr.group.group_idx]
        if from_addr.panel_idx >= len(src_g.panels):
            return
        panel = src_g.panels.pop(from_addr.panel_idx)
        dst_d = self.dock(to_dock)
        if dst_d is None:
            src_g.panels.insert(min(from_addr.panel_idx, len(src_g.panels)), panel)
            return
        idx = min(at_idx, len(dst_d.groups))
        dst_d.groups.insert(idx, PanelGroup(panels=[panel]))
        self._cleanup(from_addr.group.dock_id)
        self._bump()

    # -- Detach panel --

    def detach_panel(self, from_addr: PanelAddr, x: float, y: float) -> Optional[int]:
        src_d = self.dock(from_addr.group.dock_id)
        if src_d is None or from_addr.group.group_idx >= len(src_d.groups):
            return None
        src_g = src_d.groups[from_addr.group.group_idx]
        if from_addr.panel_idx >= len(src_g.panels):
            return None
        panel = src_g.panels.pop(from_addr.panel_idx)
        did = self._next_dock_id()
        self.floating.append(FloatingDock(
            dock=Dock(id=did, groups=[PanelGroup(panels=[panel])], width=DEFAULT_FLOATING_WIDTH),
            x=x, y=y,
        ))
        self.z_order.append(did)
        self._cleanup(from_addr.group.dock_id)
        self._bump()
        return did

    # -- Floating position --

    def set_floating_position(self, id: int, x: float, y: float):
        for fd in self.floating:
            if fd.dock.id == id:
                fd.x = x
                fd.y = y
        self._bump()

    # -- Resize --

    def resize_group(self, addr: GroupAddr, height: float):
        d = self.dock(addr.dock_id)
        if d is not None and addr.group_idx < len(d.groups):
            d.groups[addr.group_idx].height = max(height, MIN_GROUP_HEIGHT)
        self._bump()

    def set_dock_width(self, id: int, width: float):
        d = self.dock(id)
        if d is not None:
            d.width = max(d.min_width, min(width, MAX_DOCK_WIDTH))
        self._bump()

    # -- Labels --

    @staticmethod
    def panel_label(kind: PanelKind) -> str:
        return {
            PanelKind.LAYERS: "Layers",
            PanelKind.COLOR: "Color",
            PanelKind.STROKE: "Stroke",
            PanelKind.PROPERTIES: "Properties",
        }[kind]

    # -- Close / show panels --

    def close_panel(self, addr: PanelAddr):
        d = self.dock(addr.group.dock_id)
        if d is not None and addr.group.group_idx < len(d.groups):
            g = d.groups[addr.group.group_idx]
            if addr.panel_idx < len(g.panels):
                panel = g.panels.pop(addr.panel_idx)
                if panel not in self.hidden_panels:
                    self.hidden_panels.append(panel)
        self._cleanup(addr.group.dock_id)
        self._bump()

    def show_panel(self, kind: PanelKind):
        if kind not in self.hidden_panels:
            return
        self.hidden_panels.remove(kind)
        if self.anchored:
            _, dock = self.anchored[0]
            if not dock.groups:
                dock.groups.append(PanelGroup(panels=[kind]))
            else:
                dock.groups[0].panels.append(kind)
                dock.groups[0].active = len(dock.groups[0].panels) - 1
        self._bump()

    def is_panel_visible(self, kind: PanelKind) -> bool:
        return kind not in self.hidden_panels

    def panel_menu_items(self) -> list[tuple[PanelKind, bool]]:
        all_kinds = [PanelKind.LAYERS, PanelKind.COLOR, PanelKind.STROKE, PanelKind.PROPERTIES]
        return [(k, self.is_panel_visible(k)) for k in all_kinds]

    # -- Z-index --

    def bring_to_front(self, id: int):
        if id in self.z_order:
            self.z_order.remove(id)
            self.z_order.append(id)
        self._bump()

    def z_index_for(self, id: int) -> int:
        try:
            return self.z_order.index(id)
        except ValueError:
            return 0

    # -- Snap & re-dock --

    def snap_to_edge(self, id: int, edge: DockEdge):
        fd = next((fd for fd in self.floating if fd.dock.id == id), None)
        if fd is None:
            return
        self.floating.remove(fd)
        self.z_order = [zid for zid in self.z_order if zid != id]
        existing = next(((i, d) for i, (e, d) in enumerate(self.anchored) if e == edge), None)
        if existing is not None:
            _, dock = existing
            dock.groups.extend(fd.dock.groups)
        else:
            self.anchored.append((edge, fd.dock))
        self._bump()

    def redock(self, id: int):
        self.snap_to_edge(id, DockEdge.RIGHT)

    @staticmethod
    def is_near_edge(x: float, y: float, viewport_w: float, viewport_h: float) -> Optional[DockEdge]:
        if x <= SNAP_DISTANCE:
            return DockEdge.LEFT
        if x >= viewport_w - SNAP_DISTANCE:
            return DockEdge.RIGHT
        if y >= viewport_h - SNAP_DISTANCE:
            return DockEdge.BOTTOM
        return None

    # -- Multi-edge --

    def add_anchored_dock(self, edge: DockEdge) -> int:
        for e, d in self.anchored:
            if e == edge:
                return d.id
        did = self._next_dock_id()
        self.anchored.append((edge, Dock(id=did, groups=[], width=DEFAULT_DOCK_WIDTH)))
        self._bump()
        return did

    def remove_anchored_dock(self, edge: DockEdge) -> Optional[int]:
        idx = next((i for i, (e, _) in enumerate(self.anchored) if e == edge), None)
        if idx is None:
            return None
        _, dock = self.anchored.pop(idx)
        if not dock.groups:
            return None
        fid = self._next_dock_id()
        self.floating.append(FloatingDock(
            dock=Dock(id=fid, groups=dock.groups, width=dock.width),
            x=100.0, y=100.0,
        ))
        self.z_order.append(fid)
        self._bump()
        return fid

    # -- Context-sensitive --

    @staticmethod
    def panels_for_selection(has_selection: bool, has_text: bool = False) -> list[PanelKind]:
        panels = [PanelKind.LAYERS]
        if has_selection:
            panels.extend([PanelKind.PROPERTIES, PanelKind.COLOR, PanelKind.STROKE])
        return panels

    # -- Persistence --

    def reset_to_default(self):
        name = self.name
        fresh = DockLayout.named(name)
        self.name = fresh.name
        self.anchored = fresh.anchored
        self.floating = fresh.floating
        self.hidden_panels = fresh.hidden_panels
        self.z_order = fresh.z_order
        self.focused_panel = fresh.focused_panel
        self._next_id = fresh._next_id
        self._bump()

    def storage_key(self) -> str:
        return f"{STORAGE_PREFIX}{self.name}"

    @staticmethod
    def storage_key_for(name: str) -> str:
        return f"{STORAGE_PREFIX}{name}"

    # -- Focus --

    def set_focused_panel(self, addr: Optional[PanelAddr]):
        self.focused_panel = addr

    def _all_panel_addrs(self) -> list[PanelAddr]:
        addrs = []
        for _, dock in self.anchored:
            for gi, group in enumerate(dock.groups):
                for pi in range(len(group.panels)):
                    addrs.append(PanelAddr(group=GroupAddr(dock_id=dock.id, group_idx=gi), panel_idx=pi))
        for fd in self.floating:
            for gi, group in enumerate(fd.dock.groups):
                for pi in range(len(group.panels)):
                    addrs.append(PanelAddr(group=GroupAddr(dock_id=fd.dock.id, group_idx=gi), panel_idx=pi))
        return addrs

    def focus_next_panel(self):
        addrs = self._all_panel_addrs()
        if not addrs:
            self.focused_panel = None
            return
        cur_idx = None
        if self.focused_panel is not None:
            for i, a in enumerate(addrs):
                if a == self.focused_panel:
                    cur_idx = i
                    break
        if cur_idx is not None:
            self.focused_panel = addrs[(cur_idx + 1) % len(addrs)]
        else:
            self.focused_panel = addrs[0]

    def focus_prev_panel(self):
        addrs = self._all_panel_addrs()
        if not addrs:
            self.focused_panel = None
            return
        cur_idx = None
        if self.focused_panel is not None:
            for i, a in enumerate(addrs):
                if a == self.focused_panel:
                    cur_idx = i
                    break
        if cur_idx is not None:
            self.focused_panel = addrs[(cur_idx - 1) % len(addrs)]
        else:
            self.focused_panel = addrs[-1]

    # -- Safety --

    def clamp_floating_docks(self, viewport_w: float, viewport_h: float):
        min_visible = 50.0
        for fd in self.floating:
            fd.x = max(-fd.dock.width + min_visible, min(fd.x, viewport_w - min_visible))
            fd.y = max(0.0, min(fd.y, viewport_h - min_visible))
        self._bump()

    def set_auto_hide(self, id: int, auto_hide: bool):
        d = self.dock(id)
        if d is not None:
            d.auto_hide = auto_hide
        self._bump()
