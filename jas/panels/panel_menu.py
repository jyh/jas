"""Panel menu item types and per-panel lookup functions."""

from __future__ import annotations
from dataclasses import dataclass
from enum import Enum, auto

from workspace.workspace_layout import PanelKind, PanelAddr, WorkspaceLayout


# ---------------------------------------------------------------------------
# PanelMenuItem
# ---------------------------------------------------------------------------

class PanelMenuItemKind(Enum):
    ACTION = auto()
    TOGGLE = auto()
    RADIO = auto()
    SEPARATOR = auto()


@dataclass
class PanelMenuItem:
    kind: PanelMenuItemKind
    label: str = ""
    command: str = ""
    shortcut: str = ""
    group: str = ""

    @staticmethod
    def action(label: str, command: str, shortcut: str = "") -> PanelMenuItem:
        return PanelMenuItem(PanelMenuItemKind.ACTION, label=label, command=command, shortcut=shortcut)

    @staticmethod
    def toggle(label: str, command: str) -> PanelMenuItem:
        return PanelMenuItem(PanelMenuItemKind.TOGGLE, label=label, command=command)

    @staticmethod
    def radio(label: str, command: str, group: str) -> PanelMenuItem:
        return PanelMenuItem(PanelMenuItemKind.RADIO, label=label, command=command, group=group)

    @staticmethod
    def separator() -> PanelMenuItem:
        return PanelMenuItem(PanelMenuItemKind.SEPARATOR)


# ---------------------------------------------------------------------------
# All panel kinds
# ---------------------------------------------------------------------------

ALL_PANEL_KINDS = [PanelKind.LAYERS, PanelKind.COLOR, PanelKind.STROKE, PanelKind.PROPERTIES]


# ---------------------------------------------------------------------------
# Per-panel definitions
# ---------------------------------------------------------------------------

_PANEL_LABELS: dict[PanelKind, str] = {
    PanelKind.LAYERS: "Layers",
    PanelKind.COLOR: "Color",
    PanelKind.STROKE: "Stroke",
    PanelKind.PROPERTIES: "Properties",
}


def panel_label(kind: PanelKind) -> str:
    """Human-readable label for a panel kind."""
    return _PANEL_LABELS[kind]


def panel_menu(kind: PanelKind) -> list[PanelMenuItem]:
    """Menu items for a panel kind."""
    return [PanelMenuItem.action(f"Close {panel_label(kind)}", "close_panel")]


def panel_dispatch(kind: PanelKind, cmd: str, addr: PanelAddr, layout: WorkspaceLayout) -> None:
    """Dispatch a menu command for a panel kind."""
    if cmd == "close_panel":
        layout.close_panel(addr)


def panel_is_checked(kind: PanelKind, cmd: str, layout: WorkspaceLayout) -> bool:
    """Query whether a toggle/radio command is checked."""
    return False
