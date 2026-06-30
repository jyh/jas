"""The single LAYOUT-op dispatcher -- ``layout_apply`` (OP_LOG.md section 12,
Fork 5, Increment 3d-2). The layout analogue of ``document.op_apply.op_apply``.

PROMOTED from the cross-language test harness (``cross_language_test.py``'s
``_apply_workspace_op``) into a RUNTIME module so production layout mutations
and the test harness share ONE dispatcher and ONE per-verb mutation body --
exactly the unification 3b-B did for document ops. The harness method now
delegates here, and the production layout-mutation sites (menu / dock panel /
per-panel hamburger menus / toolbar / app click sites) build a resolved op
dict and call ``layout_apply`` instead of calling the ``WorkspaceLayout``
method directly. The mutation is byte-identical to the pre-3d-2 direct call
(same args, now routed dict -> dispatch).

LAYOUT STAYS NON-UNDOABLE (OP_LOG.md section 12, Option B): there is NO layout
journal, NO layout undo, and NO checkpoint-vs-journal gate (that is Option C,
deliberately NOT done). ``layout_apply`` is purely the shared parse -> apply
envelope.

DIRTY SIGNAL: the per-verb ``WorkspaceLayout`` mutators (close_panel,
show_panel, toggle_group_collapsed, set_active_panel, reorder_panel,
move_panel_to_group, detach_group, redock) already call ``self._bump()``
internally, so routing a PANEL op through ``layout_apply`` preserves the dirty
signal at no extra cost. The PANE mutators live on ``PaneLayout`` and do NOT
bump; ``layout_apply`` mutates ``layout.pane_layout`` directly WITHOUT bumping,
mirroring the pre-3d-2 direct ``pane_layout.<method>`` calls. Each production
PANE site preserves ITS OWN existing dirty signal exactly as before (e.g. the
``panes_mut`` wrapper in jas_app bumps; the menu Tile/toggle paths bump via
``panes_mut``). The harness corpus only checks the serialized layout, so the
bump policy is invisible to it.

Production input must never panic, so every param read is hardened: numbers
resolve through ``_u`` / ``_f`` (missing/garbage -> 0); a missing REQUIRED
string (the verb name, a panel/pane ``kind``) returns/skips rather than
KeyError; an unknown verb skips. The harness fixtures (which always carry
well-formed params) replay byte-identically.
"""

from __future__ import annotations

from workspace.workspace_layout import (
    WorkspaceLayout, PanelKind, GroupAddr, PanelAddr,
)
from workspace.pane import PaneKind


# ---------------------------------------------------------------------------
# Kind parsing / serialization. Complete over all 13 PanelKinds and all 3
# PaneKinds, matching workspace_test_json. An unknown/garbage string falls back
# (Layers / Canvas) so a malformed op never crashes. The pre-3d-2 harness shim
# carried a 4-kind PanelKind subset; the runtime dispatcher needs the full set
# because the production show_panel handler covers every PanelKind.
# ---------------------------------------------------------------------------

def parse_panel_kind(s) -> PanelKind:
    return {
        "layers": PanelKind.LAYERS,
        "color": PanelKind.COLOR,
        "swatches": PanelKind.SWATCHES,
        "stroke": PanelKind.STROKE,
        "properties": PanelKind.PROPERTIES,
        "character": PanelKind.CHARACTER,
        "paragraph": PanelKind.PARAGRAPH,
        "artboards": PanelKind.ARTBOARDS,
        "align": PanelKind.ALIGN,
        "boolean": PanelKind.BOOLEAN,
        "opacity": PanelKind.OPACITY,
        "magic_wand": PanelKind.MAGIC_WAND,
        "symbols": PanelKind.SYMBOLS,
        "brushes": PanelKind.BRUSHES,
    }.get(s, PanelKind.LAYERS)


def panel_kind_str(k: PanelKind) -> str:
    return {
        PanelKind.LAYERS: "layers",
        PanelKind.COLOR: "color",
        PanelKind.SWATCHES: "swatches",
        PanelKind.STROKE: "stroke",
        PanelKind.PROPERTIES: "properties",
        PanelKind.CHARACTER: "character",
        PanelKind.PARAGRAPH: "paragraph",
        PanelKind.ARTBOARDS: "artboards",
        PanelKind.ALIGN: "align",
        PanelKind.BOOLEAN: "boolean",
        PanelKind.OPACITY: "opacity",
        PanelKind.MAGIC_WAND: "magic_wand",
        PanelKind.SYMBOLS: "symbols",
        PanelKind.BRUSHES: "brushes",
    }[k]


def parse_pane_kind(s) -> PaneKind:
    return {
        "toolbar": PaneKind.TOOLBAR,
        "dock": PaneKind.DOCK,
    }.get(s, PaneKind.CANVAS)


def pane_kind_str(k: PaneKind) -> str:
    return {
        PaneKind.TOOLBAR: "toolbar",
        PaneKind.CANVAS: "canvas",
        PaneKind.DOCK: "dock",
    }[k]


# ---------------------------------------------------------------------------
# Op-dict builders (production -> dispatcher).
#
# Production layout-mutation sites build their op via these typed constructors
# and pass the result to ``layout_apply``, so the dict SHAPE for each verb lives
# in exactly one place (alongside the parser above) and a shape drift between
# the producer and the consumer is impossible. Each builder mirrors the field
# names the matching ``layout_apply`` branch reads.
# ---------------------------------------------------------------------------

def op_close_panel(addr: PanelAddr) -> dict:
    return {
        "op": "close_panel",
        "dock_id": addr.group.dock_id,
        "group_idx": addr.group.group_idx,
        "panel_idx": addr.panel_idx,
    }


def op_set_active_panel(addr: PanelAddr) -> dict:
    return {
        "op": "set_active_panel",
        "dock_id": addr.group.dock_id,
        "group_idx": addr.group.group_idx,
        "panel_idx": addr.panel_idx,
    }


def op_show_panel(kind: PanelKind) -> dict:
    return {"op": "show_panel", "kind": panel_kind_str(kind)}


def op_toggle_group_collapsed(addr: GroupAddr) -> dict:
    return {
        "op": "toggle_group_collapsed",
        "dock_id": addr.dock_id,
        "group_idx": addr.group_idx,
    }


def op_reorder_panel(group: GroupAddr, from_idx: int, to_idx: int) -> dict:
    return {
        "op": "reorder_panel",
        "dock_id": group.dock_id,
        "group_idx": group.group_idx,
        "from": from_idx,
        "to": to_idx,
    }


def op_move_panel_to_group(from_addr: PanelAddr, to: GroupAddr) -> dict:
    return {
        "op": "move_panel_to_group",
        "from_dock_id": from_addr.group.dock_id,
        "from_group_idx": from_addr.group.group_idx,
        "from_panel_idx": from_addr.panel_idx,
        "to_dock_id": to.dock_id,
        "to_group_idx": to.group_idx,
    }


def op_detach_group(addr: GroupAddr, x: float, y: float) -> dict:
    return {
        "op": "detach_group",
        "dock_id": addr.dock_id,
        "group_idx": addr.group_idx,
        "x": x,
        "y": y,
    }


def op_redock(dock_id: int) -> dict:
    return {"op": "redock", "dock_id": dock_id}


def op_hide_pane(kind: PaneKind) -> dict:
    return {"op": "hide_pane", "kind": pane_kind_str(kind)}


def op_show_pane(kind: PaneKind) -> dict:
    return {"op": "show_pane", "kind": pane_kind_str(kind)}


def op_bring_pane_to_front(pane_id: int) -> dict:
    return {"op": "bring_pane_to_front", "pane_id": pane_id}


def op_set_pane_position(pane_id: int, x: float, y: float) -> dict:
    return {"op": "set_pane_position", "pane_id": pane_id, "x": x, "y": y}


def op_resize_pane(pane_id: int, width: float, height: float) -> dict:
    return {"op": "resize_pane", "pane_id": pane_id, "width": width, "height": height}


def op_toggle_canvas_maximized() -> dict:
    return {"op": "toggle_canvas_maximized"}


def op_tile_panes(override_pane=None) -> dict:
    """``{op:"tile_panes"[, override_pane_id, override_width]}``.

    ``override_pane`` is the collapsed-dock fixed-width override the menu Tile
    handler may supply as ``(pane_id, width)`` (``None`` for the plain corpus
    path, which leaves ``tile_panes`` with no collapsed override)."""
    v: dict = {"op": "tile_panes"}
    if override_pane is not None:
        v["override_pane_id"] = override_pane[0]
        v["override_width"] = override_pane[1]
    return v


# ---------------------------------------------------------------------------
# Hardened readers: a malformed production payload never raises. A
# missing/wrong-typed numeric field reads as 0, mirroring the document
# ``op_apply`` discipline (the harness fixtures always carry well-formed
# params, so they replay byte-identically).
# ---------------------------------------------------------------------------

def _u(op: dict, key: str) -> int:
    v = op.get(key, 0)
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0


def _f(op: dict, key: str) -> float:
    v = op.get(key, 0.0)
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def layout_apply(layout: WorkspaceLayout, op: dict) -> None:
    """Apply one primitive LAYOUT op to ``layout``. The SINGLE per-verb
    mutation body shared by production and the cross-language harness.

    Hardened: an unknown verb or a missing required ``kind`` / ``op`` string
    SKIPS (no exception, no mutation). The PANEL branches call
    ``WorkspaceLayout`` mutators that bump internally (preserving the dirty
    signal); the PANE branches mutate ``layout.pane_layout`` directly without
    bumping, mirroring the pre-3d-2 direct calls -- each pane call site keeps
    its own dirty signal.
    """
    name = op.get("op")
    if not isinstance(name, str):
        return  # malformed op envelope: skip

    # ---- Panel / dock operations (mutate WorkspaceLayout; these bump) ----
    if name == "toggle_group_collapsed":
        layout.toggle_group_collapsed(GroupAddr(
            dock_id=_u(op, "dock_id"), group_idx=_u(op, "group_idx")))
    elif name == "set_active_panel":
        layout.set_active_panel(PanelAddr(
            group=GroupAddr(dock_id=_u(op, "dock_id"), group_idx=_u(op, "group_idx")),
            panel_idx=_u(op, "panel_idx")))
    elif name == "close_panel":
        layout.close_panel(PanelAddr(
            group=GroupAddr(dock_id=_u(op, "dock_id"), group_idx=_u(op, "group_idx")),
            panel_idx=_u(op, "panel_idx")))
    elif name == "show_panel":
        kind_s = op.get("kind")
        if not isinstance(kind_s, str):
            return  # required field missing: skip
        layout.show_panel(parse_panel_kind(kind_s))
    elif name == "reorder_panel":
        layout.reorder_panel(
            GroupAddr(dock_id=_u(op, "dock_id"), group_idx=_u(op, "group_idx")),
            _u(op, "from"), _u(op, "to"))
    elif name == "move_panel_to_group":
        layout.move_panel_to_group(
            PanelAddr(
                group=GroupAddr(dock_id=_u(op, "from_dock_id"),
                                group_idx=_u(op, "from_group_idx")),
                panel_idx=_u(op, "from_panel_idx")),
            GroupAddr(dock_id=_u(op, "to_dock_id"),
                      group_idx=_u(op, "to_group_idx")))
    elif name == "detach_group":
        layout.detach_group(
            GroupAddr(dock_id=_u(op, "dock_id"), group_idx=_u(op, "group_idx")),
            _f(op, "x"), _f(op, "y"))
    elif name == "redock":
        layout.redock(_u(op, "dock_id"))

    # ---- Pane operations (mutate the inner PaneLayout; do NOT bump here) ----
    # Each early-returns (skips) when there is no pane layout, matching the
    # production handlers which all guard on a present pane layout.
    elif name == "set_pane_position":
        pl = layout.pane_layout
        if pl is None:
            return
        pl.set_pane_position(_u(op, "pane_id"), _f(op, "x"), _f(op, "y"))
    elif name == "tile_panes":
        pl = layout.pane_layout
        if pl is None:
            return
        # Optional collapsed-dock fixed-width override: absent in the fixtures
        # (which call tile_panes() bare), present only from the menu handler
        # when a dock is collapsed.
        override = None
        if "override_pane_id" in op:
            override = (_u(op, "override_pane_id"), _f(op, "override_width"))
        pl.tile_panes(override)
    elif name == "toggle_canvas_maximized":
        pl = layout.pane_layout
        if pl is None:
            return
        pl.toggle_canvas_maximized()
    elif name == "resize_pane":
        pl = layout.pane_layout
        if pl is None:
            return
        pl.resize_pane(_u(op, "pane_id"), _f(op, "width"), _f(op, "height"))
    elif name == "hide_pane":
        pl = layout.pane_layout
        if pl is None:
            return
        kind_s = op.get("kind")
        if not isinstance(kind_s, str):
            return  # required field missing: skip
        pl.hide_pane(parse_pane_kind(kind_s))
    elif name == "show_pane":
        pl = layout.pane_layout
        if pl is None:
            return
        kind_s = op.get("kind")
        if not isinstance(kind_s, str):
            return  # required field missing: skip
        pl.show_pane(parse_pane_kind(kind_s))
    elif name == "bring_pane_to_front":
        pl = layout.pane_layout
        if pl is None:
            return
        pl.bring_pane_to_front(_u(op, "pane_id"))

    # Unknown verb: skip rather than raise (a malformed / forward-compat op
    # must not crash production; the corpus only ever sends known verbs).
    else:
        return
