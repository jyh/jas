"""Canonical Test JSON serialization for workspace layout cross-language
equivalence testing.

Follows the same conventions as ``geometry.test_json``: sorted keys,
normalized floats (4 decimals), all optional fields explicit (``null``),
enums as lowercase strings.  Byte-for-byte comparison is a valid
equivalence check.
"""

import json
import math

from workspace.workspace_layout import (
    WorkspaceLayout, DockEdge, PanelKind, PanelGroup, Dock, FloatingDock,
    GroupAddr, PanelAddr, LAYOUT_VERSION,
)
from workspace.pane import (
    PaneLayout, Pane, PaneConfig, PaneKind, DoubleClickAction,
    EdgeSide, SnapConstraint, WindowTarget, PaneTarget,
)

# ------------------------------------------------------------------ #
# Float formatting                                                    #
# ------------------------------------------------------------------ #

def _fmt(v: float) -> str:
    # Use math.floor(x + 0.5) instead of round() to avoid Python's
    # banker's rounding (round-half-to-even), matching the other languages.
    rounded = math.floor(v * 10000 + 0.5) / 10000
    if rounded == math.trunc(rounded) and rounded % 1 == 0:
        return f"{rounded:.1f}"
    s = f"{rounded:.4f}"
    # Strip trailing zeros but keep at least one digit after decimal.
    while s.endswith("0") and not s.endswith(".0"):
        s = s[:-1]
    return s

# ------------------------------------------------------------------ #
# JSON building helpers                                               #
# ------------------------------------------------------------------ #

class _JsonObj:
    def __init__(self):
        self._entries: list[tuple[str, str]] = []

    def str(self, key: str, v: str):
        escaped = v.replace("\\", "\\\\").replace('"', '\\"')
        self._entries.append((key, f'"{escaped}"'))

    def num(self, key: str, v: float):
        self._entries.append((key, _fmt(v)))

    def int_(self, key: str, v: int):
        self._entries.append((key, str(v)))

    def bool_(self, key: str, v: bool):
        self._entries.append((key, "true" if v else "false"))

    def null(self, key: str):
        self._entries.append((key, "null"))

    def raw(self, key: str, json_str: str):
        self._entries.append((key, json_str))

    def build(self) -> str:
        self._entries.sort(key=lambda e: e[0])
        pairs = [f'"{k}":{v}' for k, v in self._entries]
        return "{" + ",".join(pairs) + "}"


def _json_array(items: list[str]) -> str:
    return "[" + ",".join(items) + "]"


# ------------------------------------------------------------------ #
# Enum -> lowercase string                                            #
# ------------------------------------------------------------------ #

def _dock_edge_str(e: DockEdge) -> str:
    return {
        DockEdge.LEFT: "left",
        DockEdge.RIGHT: "right",
        DockEdge.BOTTOM: "bottom",
    }[e]


def _panel_kind_str(k: PanelKind) -> str:
    return {
        PanelKind.LAYERS: "layers",
        PanelKind.COLOR: "color",
        PanelKind.STROKE: "stroke",
        PanelKind.PROPERTIES: "properties",
    }[k]


def _pane_kind_str(k: PaneKind) -> str:
    return {
        PaneKind.TOOLBAR: "toolbar",
        PaneKind.CANVAS: "canvas",
        PaneKind.DOCK: "dock",
    }[k]


def _edge_side_str(e: EdgeSide) -> str:
    return {
        EdgeSide.LEFT: "left",
        EdgeSide.RIGHT: "right",
        EdgeSide.TOP: "top",
        EdgeSide.BOTTOM: "bottom",
    }[e]


def _double_click_action_str(a: DoubleClickAction) -> str:
    return {
        DoubleClickAction.MAXIMIZE: "maximize",
        DoubleClickAction.REDOCK: "redock",
        DoubleClickAction.NONE: "none",
    }[a]


# ------------------------------------------------------------------ #
# Type serializers                                                    #
# ------------------------------------------------------------------ #

def _snap_target_json(t) -> str:
    if isinstance(t, WindowTarget):
        o = _JsonObj()
        o.str("window", _edge_side_str(t.edge))
        return o.build()
    elif isinstance(t, PaneTarget):
        inner = _JsonObj()
        inner.str("edge", _edge_side_str(t.edge))
        inner.int_("id", t.pane_id)
        o = _JsonObj()
        o.raw("pane", inner.build())
        return o.build()
    return "{}"


def _snap_constraint_json(s: SnapConstraint) -> str:
    o = _JsonObj()
    o.str("edge", _edge_side_str(s.edge))
    o.int_("pane", s.pane)
    o.raw("target", _snap_target_json(s.target))
    return o.build()


def _pane_config_json(c: PaneConfig) -> str:
    o = _JsonObj()
    if c.collapsed_width is not None:
        o.num("collapsed_width", c.collapsed_width)
    else:
        o.null("collapsed_width")
    o.str("double_click_action", _double_click_action_str(c.double_click_action))
    o.bool_("fixed_width", c.fixed_width)
    o.str("label", c.label)
    o.num("min_height", c.min_height)
    o.num("min_width", c.min_width)
    return o.build()


def _pane_json(p: Pane) -> str:
    o = _JsonObj()
    o.raw("config", _pane_config_json(p.config))
    o.num("height", p.height)
    o.int_("id", p.id)
    o.str("kind", _pane_kind_str(p.kind))
    o.num("width", p.width)
    o.num("x", p.x)
    o.num("y", p.y)
    return o.build()


def _pane_layout_json(pl: PaneLayout) -> str:
    o = _JsonObj()
    o.bool_("canvas_maximized", pl.canvas_maximized)
    hidden = [f'"{_pane_kind_str(k)}"' for k in pl.hidden_panes]
    o.raw("hidden_panes", _json_array(hidden))
    o.int_("next_pane_id", pl.next_pane_id)
    panes = [_pane_json(p) for p in pl.panes]
    o.raw("panes", _json_array(panes))
    snaps = [_snap_constraint_json(s) for s in pl.snaps]
    o.raw("snaps", _json_array(snaps))
    o.num("viewport_height", pl.viewport_height)
    o.num("viewport_width", pl.viewport_width)
    z = [str(zid) for zid in pl.z_order]
    o.raw("z_order", _json_array(z))
    return o.build()


def _panel_group_json(g: PanelGroup) -> str:
    o = _JsonObj()
    o.int_("active", g.active)
    o.bool_("collapsed", g.collapsed)
    if g.height is not None:
        o.num("height", g.height)
    else:
        o.null("height")
    panels = [f'"{_panel_kind_str(k)}"' for k in g.panels]
    o.raw("panels", _json_array(panels))
    return o.build()


def _dock_json(d: Dock) -> str:
    o = _JsonObj()
    o.bool_("auto_hide", d.auto_hide)
    o.bool_("collapsed", d.collapsed)
    groups = [_panel_group_json(g) for g in d.groups]
    o.raw("groups", _json_array(groups))
    o.int_("id", d.id)
    o.num("min_width", d.min_width)
    o.num("width", d.width)
    return o.build()


def _floating_dock_json(fd: FloatingDock) -> str:
    o = _JsonObj()
    o.raw("dock", _dock_json(fd.dock))
    o.num("x", fd.x)
    o.num("y", fd.y)
    return o.build()


def _group_addr_json(g: GroupAddr) -> str:
    o = _JsonObj()
    o.int_("dock_id", g.dock_id)
    o.int_("group_idx", g.group_idx)
    return o.build()


def _panel_addr_json(a: PanelAddr) -> str:
    o = _JsonObj()
    o.raw("group", _group_addr_json(a.group))
    o.int_("panel_idx", a.panel_idx)
    return o.build()


# ------------------------------------------------------------------ #
# Toolbar structure (static data for cross-language fixture)          #
# ------------------------------------------------------------------ #

def toolbar_structure_json() -> str:
    """Return canonical JSON for the toolbar slot layout."""
    slots = [
        (0, 0, ["selection"]),
        (0, 1, ["direct_selection", "group_selection"]),
        (1, 0, ["pen", "add_anchor_point", "delete_anchor_point", "anchor_point"]),
        (1, 1, ["pencil", "path_eraser", "smooth"]),
        (2, 0, ["type", "type_on_path"]),
        (2, 1, ["line"]),
        (3, 0, ["rect", "rounded_rect", "polygon", "star"]),
        (3, 1, ["lasso"]),
    ]

    total = sum(len(tools) for _, _, tools in slots)

    slot_jsons = []
    for row, col, tools in slots:
        o = _JsonObj()
        o.int_("col", col)
        o.int_("row", row)
        tool_strs = [f'"{t}"' for t in tools]
        o.raw("tools", _json_array(tool_strs))
        slot_jsons.append(o.build())

    o = _JsonObj()
    o.raw("slots", _json_array(slot_jsons))
    o.int_("total_tools", total)
    return o.build()


# ------------------------------------------------------------------ #
# Menu bar data                                                       #
# ------------------------------------------------------------------ #

# Static menu bar definition matching the Rust MENU_BAR constant.
# Each entry is (title, [(label, command, shortcut), ...]).
# Label "---" denotes a separator.
MENU_BAR = [
    ("File", [
        ("New", "new", "\u2318N"),
        ("Open...", "open", "\u2318O"),
        ("Save", "save", "\u2318S"),
        ("---", "", ""),
        ("Close Tab", "close", "\u2318W"),
    ]),
    ("Edit", [
        ("Undo", "undo", "\u2318Z"),
        ("Redo", "redo", "\u21e7\u2318Z"),
        ("---", "", ""),
        ("Cut", "cut", "\u2318X"),
        ("Copy", "copy", "\u2318C"),
        ("Paste", "paste", "\u2318V"),
        ("Paste in Place", "paste_in_place", "\u21e7\u2318V"),
        ("---", "", ""),
        ("Delete", "delete", "\u232b"),
        ("Select All", "select_all", "\u2318A"),
    ]),
    ("Object", [
        ("Group", "group", "\u2318G"),
        ("Ungroup", "ungroup", "\u21e7\u2318G"),
        ("Ungroup All", "ungroup_all", ""),
        ("---", "", ""),
        ("Lock", "lock", "\u23182"),
        ("Unlock All", "unlock_all", "\u2325\u23182"),
        ("---", "", ""),
        ("Hide", "hide", "\u23183"),
        ("Show All", "show_all", "\u2325\u23183"),
    ]),
    ("Window", [
        ("Workspace \u25b6", "workspace_submenu", ""),
        ("---", "", ""),
        ("Tile", "tile_panes", ""),
        ("---", "", ""),
        ("Toolbar", "toggle_pane_toolbar", ""),
        ("Panels", "toggle_pane_dock", ""),
        ("---", "", ""),
        ("Layers", "toggle_panel_layers", ""),
        ("Color", "toggle_panel_color", ""),
        ("Stroke", "toggle_panel_stroke", ""),
        ("Properties", "toggle_panel_properties", ""),
    ]),
]


def menu_structure_json() -> str:
    """Return canonical JSON for the menu bar structure."""
    total = sum(len(items) for _, items in MENU_BAR)

    menu_jsons = []
    for title, items in MENU_BAR:
        item_jsons = []
        for label, cmd, shortcut in items:
            if label == "---":
                o = _JsonObj()
                o.bool_("separator", True)
                item_jsons.append(o.build())
            else:
                o = _JsonObj()
                o.str("command", cmd)
                o.str("label", label)
                o.str("shortcut", shortcut)
                item_jsons.append(o.build())
        o = _JsonObj()
        o.raw("items", _json_array(item_jsons))
        o.str("title", title)
        menu_jsons.append(o.build())

    o = _JsonObj()
    o.raw("menus", _json_array(menu_jsons))
    o.int_("total_items", total)
    return o.build()


# ------------------------------------------------------------------ #
# State defaults (from workspace YAML state.yaml)                     #
# ------------------------------------------------------------------ #

# Canonical state variable defaults — must match workspace/state.yaml.
# Only user-facing state; internal _-prefixed variables are excluded.
STATE_DEFAULTS = [
    ("active_tab", "number", -1),
    ("active_tool", "enum", "selection"),
    ("canvas_maximized", "bool", False),
    ("canvas_visible", "bool", True),
    ("dock_collapsed", "bool", False),
    ("dock_visible", "bool", True),
    ("fill_color", "color", "#ffffff"),
    ("fill_on_top", "bool", True),
    ("stroke_color", "color", "#000000"),
    ("stroke_width", "number", 1.0),
    ("tab_count", "number", 0),
    ("toolbar_visible", "bool", True),
]


def state_defaults_json() -> str:
    """Return canonical JSON for all user-facing state variable defaults."""
    var_jsons = []
    for name, stype, default in STATE_DEFAULTS:
        o = _JsonObj()
        if isinstance(default, bool):
            o.bool_("default", default)
        elif isinstance(default, (int, float)) and not isinstance(default, bool):
            if isinstance(default, int) or default == int(default):
                o.int_("default", int(default))
            else:
                o.num("default", default)
        elif default is None:
            o.null("default")
        else:
            o.str("default", str(default))
        o.str("name", name)
        o.str("type", stype)
        var_jsons.append(o.build())

    o = _JsonObj()
    o.int_("count", len(STATE_DEFAULTS))
    o.raw("variables", _json_array(var_jsons))
    return o.build()


# ------------------------------------------------------------------ #
# Shortcut structure (from workspace YAML shortcuts.yaml)             #
# ------------------------------------------------------------------ #

# Canonical shortcuts — must match workspace/shortcuts.yaml.
SHORTCUTS = [
    ("Ctrl+N", "new_document", None),
    ("Ctrl+O", "open_file", None),
    ("Ctrl+S", "save", None),
    ("Ctrl+Shift+S", "save_as", None),
    ("Ctrl+Q", "quit", None),
    ("Ctrl+Z", "undo", None),
    ("Ctrl+Shift+Z", "redo", None),
    ("Ctrl+X", "cut", None),
    ("Ctrl+C", "copy", None),
    ("Ctrl+V", "paste", None),
    ("Ctrl+Shift+V", "paste_in_place", None),
    ("Ctrl+A", "select_all", None),
    ("Delete", "delete_selection", None),
    ("Backspace", "delete_selection", None),
    ("Ctrl+G", "group", None),
    ("Ctrl+Shift+G", "ungroup", None),
    ("Ctrl+2", "lock", None),
    ("Ctrl+Alt+2", "unlock_all", None),
    ("Ctrl+3", "hide_selection", None),
    ("Ctrl+Alt+3", "show_all", None),
    ("Ctrl+=", "zoom_in", None),
    ("Ctrl+-", "zoom_out", None),
    ("Ctrl+0", "fit_in_window", None),
    ("V", "select_tool", {"tool": "selection"}),
    ("A", "select_tool", {"tool": "direct_selection"}),
    ("P", "select_tool", {"tool": "pen"}),
    ("=", "select_tool", {"tool": "add_anchor"}),
    ("-", "select_tool", {"tool": "delete_anchor"}),
    ("T", "select_tool", {"tool": "type"}),
    ("\\", "select_tool", {"tool": "line"}),
    ("M", "select_tool", {"tool": "rect"}),
    ("N", "select_tool", {"tool": "pencil"}),
    ("Shift+E", "select_tool", {"tool": "path_eraser"}),
    ("Q", "select_tool", {"tool": "lasso"}),
    ("D", "reset_fill_stroke", None),
    ("X", "toggle_fill_on_top", None),
    ("Shift+X", "swap_fill_stroke", None),
]


def shortcut_structure_json() -> str:
    """Return canonical JSON for all keyboard shortcuts."""
    shortcut_jsons = []
    for key, action, params in SHORTCUTS:
        o = _JsonObj()
        o.str("action", action)
        o.str("key", key)
        if params:
            po = _JsonObj()
            for pk in sorted(params.keys()):
                po.str(pk, params[pk])
            o.raw("params", po.build())
        else:
            o.null("params")
        shortcut_jsons.append(o.build())

    o = _JsonObj()
    o.int_("count", len(SHORTCUTS))
    o.raw("shortcuts", _json_array(shortcut_jsons))
    return o.build()


# ------------------------------------------------------------------ #
# Public API: workspace -> test JSON                                  #
# ------------------------------------------------------------------ #

def workspace_to_test_json(layout: WorkspaceLayout) -> str:
    """Serialize a WorkspaceLayout to canonical test JSON.

    The output is a compact JSON string with sorted keys and normalized
    floats, suitable for byte-for-byte cross-language comparison.
    """
    o = _JsonObj()

    # anchored: array of {dock, edge}
    anchored = []
    for edge, d in layout.anchored:
        ao = _JsonObj()
        ao.raw("dock", _dock_json(d))
        ao.str("edge", _dock_edge_str(edge))
        anchored.append(ao.build())
    o.raw("anchored", _json_array(anchored))

    # floating
    floating = [_floating_dock_json(fd) for fd in layout.floating]
    o.raw("floating", _json_array(floating))

    # focused_panel
    if layout.focused_panel is not None:
        o.raw("focused_panel", _panel_addr_json(layout.focused_panel))
    else:
        o.null("focused_panel")

    # hidden_panels
    hidden = [f'"{_panel_kind_str(k)}"' for k in layout.hidden_panels]
    o.raw("hidden_panels", _json_array(hidden))

    # name
    o.str("name", layout.name)

    # next_id
    o.int_("next_id", layout._next_id)

    # pane_layout
    if layout.pane_layout is not None:
        o.raw("pane_layout", _pane_layout_json(layout.pane_layout))
    else:
        o.null("pane_layout")

    # version
    o.int_("version", layout.version)

    # z_order
    z = [str(zid) for zid in layout.z_order]
    o.raw("z_order", _json_array(z))

    return o.build()


# ------------------------------------------------------------------ #
# JSON parser helpers                                                 #
# ------------------------------------------------------------------ #

def _parse_f(v) -> float:
    if v is None:
        return 0.0
    return float(v)


def _parse_int(v) -> int:
    if v is None:
        return 0
    return int(v)


def _parse_dock_edge(v) -> DockEdge:
    return {
        "left": DockEdge.LEFT,
        "bottom": DockEdge.BOTTOM,
    }.get(v, DockEdge.RIGHT)


def _parse_panel_kind(v) -> PanelKind:
    return {
        "color": PanelKind.COLOR,
        "stroke": PanelKind.STROKE,
        "properties": PanelKind.PROPERTIES,
    }.get(v, PanelKind.LAYERS)


def _parse_pane_kind(v) -> PaneKind:
    return {
        "toolbar": PaneKind.TOOLBAR,
        "dock": PaneKind.DOCK,
    }.get(v, PaneKind.CANVAS)


def _parse_edge_side(v) -> EdgeSide:
    return {
        "right": EdgeSide.RIGHT,
        "top": EdgeSide.TOP,
        "bottom": EdgeSide.BOTTOM,
    }.get(v, EdgeSide.LEFT)


def _parse_double_click_action(v) -> DoubleClickAction:
    return {
        "maximize": DoubleClickAction.MAXIMIZE,
        "redock": DoubleClickAction.REDOCK,
    }.get(v, DoubleClickAction.NONE)


def _parse_snap_target(d: dict):
    if "window" in d:
        return WindowTarget(_parse_edge_side(d["window"]))
    elif "pane" in d:
        pane_obj = d["pane"]
        return PaneTarget(_parse_int(pane_obj["id"]), _parse_edge_side(pane_obj["edge"]))
    return WindowTarget(EdgeSide.LEFT)


def _parse_snap_constraint(d: dict) -> SnapConstraint:
    return SnapConstraint(
        pane=_parse_int(d["pane"]),
        edge=_parse_edge_side(d["edge"]),
        target=_parse_snap_target(d["target"]),
    )


def _parse_pane_config(d: dict) -> PaneConfig:
    collapsed_width = None if d.get("collapsed_width") is None else _parse_f(d["collapsed_width"])
    return PaneConfig(
        label=d.get("label", ""),
        min_width=_parse_f(d.get("min_width", 0)),
        min_height=_parse_f(d.get("min_height", 0)),
        fixed_width=d.get("fixed_width", False),
        collapsed_width=collapsed_width,
        double_click_action=_parse_double_click_action(d.get("double_click_action", "none")),
    )


def _parse_pane(d: dict) -> Pane:
    return Pane(
        id=_parse_int(d["id"]),
        kind=_parse_pane_kind(d["kind"]),
        config=_parse_pane_config(d["config"]),
        x=_parse_f(d["x"]),
        y=_parse_f(d["y"]),
        width=_parse_f(d["width"]),
        height=_parse_f(d["height"]),
    )


def _parse_pane_layout(d: dict) -> PaneLayout:
    panes = [_parse_pane(p) for p in d.get("panes", [])]
    snaps = [_parse_snap_constraint(s) for s in d.get("snaps", [])]
    z_order = [_parse_int(z) for z in d.get("z_order", [])]
    hidden_panes = [_parse_pane_kind(k) for k in d.get("hidden_panes", [])]
    return PaneLayout(
        panes=panes,
        snaps=snaps,
        z_order=z_order,
        hidden_panes=hidden_panes,
        canvas_maximized=d.get("canvas_maximized", False),
        viewport_width=_parse_f(d.get("viewport_width", 0)),
        viewport_height=_parse_f(d.get("viewport_height", 0)),
        next_pane_id=_parse_int(d.get("next_pane_id", 0)),
    )


def _parse_panel_group(d: dict) -> PanelGroup:
    panels = [_parse_panel_kind(k) for k in d.get("panels", [])]
    return PanelGroup(
        panels=panels,
        active=_parse_int(d.get("active", 0)),
        collapsed=d.get("collapsed", False),
        height=None if d.get("height") is None else _parse_f(d["height"]),
    )


def _parse_dock(d: dict) -> Dock:
    groups = [_parse_panel_group(g) for g in d.get("groups", [])]
    return Dock(
        id=_parse_int(d["id"]),
        groups=groups,
        collapsed=d.get("collapsed", False),
        auto_hide=d.get("auto_hide", False),
        width=_parse_f(d.get("width", 240.0)),
        min_width=_parse_f(d.get("min_width", 150.0)),
    )


def _parse_floating_dock(d: dict) -> FloatingDock:
    return FloatingDock(
        dock=_parse_dock(d["dock"]),
        x=_parse_f(d["x"]),
        y=_parse_f(d["y"]),
    )


def _parse_group_addr(d: dict) -> GroupAddr:
    return GroupAddr(
        dock_id=_parse_int(d["dock_id"]),
        group_idx=_parse_int(d["group_idx"]),
    )


def _parse_panel_addr(d: dict) -> PanelAddr:
    return PanelAddr(
        group=_parse_group_addr(d["group"]),
        panel_idx=_parse_int(d["panel_idx"]),
    )


# ------------------------------------------------------------------ #
# Public API: test JSON -> workspace                                  #
# ------------------------------------------------------------------ #

def test_json_to_workspace(json_str: str) -> WorkspaceLayout:
    """Parse canonical test JSON into a WorkspaceLayout.

    This is the inverse of :func:`workspace_to_test_json`.
    """
    d = json.loads(json_str)

    anchored = [
        (_parse_dock_edge(a["edge"]), _parse_dock(a["dock"]))
        for a in d.get("anchored", [])
    ]

    floating = [_parse_floating_dock(f) for f in d.get("floating", [])]

    hidden_panels = [_parse_panel_kind(k) for k in d.get("hidden_panels", [])]

    z_order = [_parse_int(z) for z in d.get("z_order", [])]

    focused_panel = None
    if d.get("focused_panel") is not None:
        focused_panel = _parse_panel_addr(d["focused_panel"])

    pane_layout = None
    if d.get("pane_layout") is not None:
        pane_layout = _parse_pane_layout(d["pane_layout"])

    name = d.get("name", "Default")
    version = d.get("version", LAYOUT_VERSION)
    next_id = _parse_int(d.get("next_id", 1))

    return WorkspaceLayout(
        name=name,
        anchored=anchored,
        floating=floating,
        hidden_panels=hidden_panels,
        z_order=z_order,
        focused_panel=focused_panel,
        next_id=next_id,
        pane_layout=pane_layout,
        version=version,
    )


# Prevent pytest from collecting this function as a test.
test_json_to_workspace.__test__ = False  # type: ignore[attr-defined]
