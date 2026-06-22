"""Menu bar data — projected from the compiled workspace ``menubar``.

The top menu bar is rendered (in ``menu.py``) from :func:`build_menu_model`,
which projects the single source of truth — the compiled ``menubar``
(menubar.yaml, bundled into workspace.json) — into a render model. This
replaced a hand-maintained native menu that had drifted from the spec (it
carried stale shortcuts, an extra Delete item, and was missing the Actual
Size / Fit Artboard / Fit All view entries and most of the Window panel
toggles). Projecting from the bundle means the Python menu bar can no longer
diverge from menubar.yaml.

The dynamic Workspace / Appearance submenus stay runtime-populated by bespoke
code in ``menu.py``; the model only carries their trigger label and identity
(:class:`MenuSubmenu`). Mirrors the Rust ``menu.rs::menu_bar_model`` projector.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum, auto


class SubmenuKind(Enum):
    """Which runtime-populated submenu a :class:`MenuSubmenu` drives."""

    WORKSPACE = auto()
    APPEARANCE = auto()


@dataclass
class MenuSeparator:
    """A menu separator (a bare ``"separator"`` string in the bundle)."""


@dataclass
class MenuSubmenu:
    """A dynamic submenu (Workspace / Appearance) — runtime-populated by
    bespoke native code; the model only carries its label + kind."""

    label: str
    kind: SubmenuKind


@dataclass
class MenuAction:
    """One resolved action entry.

    ``label`` keeps the ``&`` mnemonic markers verbatim (Qt consumes ``&`` as
    its native accelerator marker). ``enabled_when`` is carried for fidelity
    but NOT evaluated here — enable/disable stays native (same as Rust v1).
    """

    label: str
    action: str
    params: dict = field(default_factory=dict)
    shortcut: str = ""
    enabled_when: str | None = None


@dataclass
class MenuModel:
    """One top-level menu (e.g. ``"&File"``) and its entries."""

    label: str
    entries: list = field(default_factory=list)


def build_menu_model() -> list[MenuModel]:
    """Project the compiled ``menubar`` (menubar.yaml) into the render model.

    Returns an empty list if the bundle is missing/corrupt (never raises).
    """
    from panels.yaml_menu import get_workspace_data

    ws = get_workspace_data()
    if not ws:
        return []
    menus = ws.get("menubar")
    if not isinstance(menus, list):
        return []
    return [_project_menu(m) for m in menus if isinstance(m, dict)]


def _project_menu(menu: dict) -> MenuModel:
    label = menu.get("label", "") or ""
    entries = []
    for item in menu.get("items", []) or []:
        entries.append(_project_entry(item))
    return MenuModel(label=label, entries=entries)


def _project_entry(item):
    # A bare "separator" string.
    if item == "separator":
        return MenuSeparator()
    if not isinstance(item, dict):
        return MenuSeparator()
    # A submenu carries nested "items"; the only ones today are the dynamic
    # Workspace / Appearance submenus, rendered natively (runtime-populated).
    if "items" in item:
        label = item.get("label", "") or ""
        ident = item.get("id", "") or ""
        if "appearance" in ident or "Appearance" in label:
            kind = SubmenuKind.APPEARANCE
        else:
            kind = SubmenuKind.WORKSPACE
        return MenuSubmenu(label=label, kind=kind)
    params = item.get("params")
    if not isinstance(params, dict):
        params = {}
    return MenuAction(
        label=item.get("label", "") or "",
        action=item.get("action", "") or "",
        params=params,
        shortcut=item.get("shortcut", "") or "",
        enabled_when=item.get("enabled_when"),
    )
