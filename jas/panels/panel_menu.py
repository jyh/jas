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

ALL_PANEL_KINDS = [PanelKind.LAYERS, PanelKind.COLOR, PanelKind.SWATCHES, PanelKind.STROKE, PanelKind.PROPERTIES]

# Color panel mode commands
COLOR_MODE_COMMANDS = {
    "mode_grayscale": "grayscale",
    "mode_rgb": "rgb",
    "mode_hsb": "hsb",
    "mode_cmyk": "cmyk",
    "mode_web_safe_rgb": "web_safe_rgb",
}

COLOR_MODE_TO_CMD = {v: k for k, v in COLOR_MODE_COMMANDS.items()}


# ---------------------------------------------------------------------------
# Per-panel definitions
# ---------------------------------------------------------------------------

_PANEL_LABELS: dict[PanelKind, str] = {
    PanelKind.LAYERS: "Layers",
    PanelKind.COLOR: "Color",
    PanelKind.SWATCHES: "Swatches",
    PanelKind.STROKE: "Stroke",
    PanelKind.PROPERTIES: "Properties",
}


def panel_label(kind: PanelKind) -> str:
    """Human-readable label for a panel kind."""
    return _PANEL_LABELS[kind]


def panel_menu(kind: PanelKind) -> list[PanelMenuItem]:
    """Menu items for a panel kind."""
    if kind == PanelKind.COLOR:
        return [
            PanelMenuItem.radio("Grayscale", "mode_grayscale", "color_mode"),
            PanelMenuItem.radio("RGB", "mode_rgb", "color_mode"),
            PanelMenuItem.radio("HSB", "mode_hsb", "color_mode"),
            PanelMenuItem.radio("CMYK", "mode_cmyk", "color_mode"),
            PanelMenuItem.radio("Web Safe RGB", "mode_web_safe_rgb", "color_mode"),
            PanelMenuItem.separator(),
            PanelMenuItem.action("Invert", "invert_color"),
            PanelMenuItem.action("Complement", "complement_color"),
            PanelMenuItem.separator(),
            PanelMenuItem.action("Close Color", "close_panel"),
        ]
    if kind == PanelKind.LAYERS:
        return [
            PanelMenuItem.action("New Layer...", "new_layer"),
            PanelMenuItem.action("New Group", "new_group"),
            PanelMenuItem.separator(),
            PanelMenuItem.action("Hide All Layers", "toggle_all_layers_visibility"),
            PanelMenuItem.action("Outline All Layers", "toggle_all_layers_outline"),
            PanelMenuItem.action("Lock All Layers", "toggle_all_layers_lock"),
            PanelMenuItem.separator(),
            PanelMenuItem.action("Enter Isolation Mode", "enter_isolation_mode"),
            PanelMenuItem.action("Exit Isolation Mode", "exit_isolation_mode"),
            PanelMenuItem.separator(),
            PanelMenuItem.action("Flatten Artwork", "flatten_artwork"),
            PanelMenuItem.action("Collect in New Layer", "collect_in_new_layer"),
            PanelMenuItem.separator(),
            PanelMenuItem.action("Close Layers", "close_panel"),
        ]
    return [PanelMenuItem.action(f"Close {panel_label(kind)}", "close_panel")]


def panel_dispatch(kind: PanelKind, cmd: str, addr: PanelAddr,
                   layout: WorkspaceLayout, model=None) -> None:
    """Dispatch a menu command for a panel kind."""
    # Mode changes
    if cmd in COLOR_MODE_COMMANDS:
        layout.color_panel_mode = COLOR_MODE_COMMANDS[cmd]
        return
    if cmd == "close_panel":
        layout.close_panel(addr)
    elif cmd == "new_layer" and kind == PanelKind.LAYERS and model is not None:
        import dataclasses
        from geometry.element import Layer
        doc = model.document
        used = {l.name for l in doc.layers if isinstance(l, Layer)}
        n = 1
        while f"Layer {n}" in used:
            n += 1
        new_layer = Layer(name=f"Layer {n}", children=())
        model.snapshot()
        model.document = dataclasses.replace(doc, layers=doc.layers + (new_layer,))
    elif cmd == "toggle_all_layers_visibility" and kind == PanelKind.LAYERS and model is not None:
        import dataclasses
        from geometry.element import Layer, Visibility
        doc = model.document
        any_visible = any(l.visibility != Visibility.INVISIBLE for l in doc.layers)
        target = Visibility.INVISIBLE if any_visible else Visibility.PREVIEW
        new_layers = tuple(
            dataclasses.replace(l, visibility=target) if isinstance(l, Layer) else l
            for l in doc.layers
        )
        model.snapshot()
        model.document = dataclasses.replace(doc, layers=new_layers)
    elif cmd == "toggle_all_layers_outline" and kind == PanelKind.LAYERS and model is not None:
        import dataclasses
        from geometry.element import Layer, Visibility
        doc = model.document
        any_preview = any(l.visibility == Visibility.PREVIEW for l in doc.layers)
        target = Visibility.OUTLINE if any_preview else Visibility.PREVIEW
        new_layers = tuple(
            dataclasses.replace(l, visibility=target) if isinstance(l, Layer) else l
            for l in doc.layers
        )
        model.snapshot()
        model.document = dataclasses.replace(doc, layers=new_layers)
    elif cmd == "toggle_all_layers_lock" and kind == PanelKind.LAYERS and model is not None:
        import dataclasses
        from geometry.element import Layer
        doc = model.document
        any_unlocked = any(not l.locked for l in doc.layers)
        new_layers = tuple(
            dataclasses.replace(l, locked=any_unlocked) if isinstance(l, Layer) else l
            for l in doc.layers
        )
        model.snapshot()
        model.document = dataclasses.replace(doc, layers=new_layers)
    elif cmd in ("new_group", "enter_isolation_mode", "exit_isolation_mode",
                 "flatten_artwork", "collect_in_new_layer") and kind == PanelKind.LAYERS:
        pass  # Tier-3 stubs for actions that need panel selection
    elif cmd == "invert_color" and kind == PanelKind.COLOR and model is not None:
        color = model.default_fill.color if model.fill_on_top and model.default_fill else (
            model.default_stroke.color if not model.fill_on_top and model.default_stroke else None)
        if color is not None:
            r, g, b, _ = color.to_rgba()
            from geometry.element import Color
            inverted = Color.rgb(1.0 - r, 1.0 - g, 1.0 - b)
            set_active_color(inverted, model)
    elif cmd == "complement_color" and kind == PanelKind.COLOR and model is not None:
        color = model.default_fill.color if model.fill_on_top and model.default_fill else (
            model.default_stroke.color if not model.fill_on_top and model.default_stroke else None)
        if color is not None:
            h, s, br, _ = color.to_hsba()
            if s > 0.001:
                from geometry.element import Color
                new_h = (h + 180.0) % 360.0
                complemented = Color.hsb(new_h, s, br)
                set_active_color(complemented, model)


def panel_is_checked(kind: PanelKind, cmd: str, layout: WorkspaceLayout) -> bool:
    """Query whether a toggle/radio command is checked."""
    if cmd in COLOR_MODE_COMMANDS:
        return layout.color_panel_mode == COLOR_MODE_COMMANDS[cmd]
    return False


def set_active_color(color, model) -> None:
    """Set the active color (fill or stroke per fill_on_top), push to recent colors."""
    from geometry.element import Fill, Stroke
    from document.controller import Controller
    if model.fill_on_top:
        model.default_fill = Fill(color=color)
        if model.document.selection:
            model.snapshot()
            ctrl = Controller(model)
            ctrl.set_selection_fill(Fill(color=color))
    else:
        width = model.default_stroke.width if model.default_stroke else 1.0
        model.default_stroke = Stroke(color=color, width=width)
        if model.document.selection:
            model.snapshot()
            ctrl = Controller(model)
            ctrl.set_selection_stroke(Stroke(color=color, width=width))
    push_recent_color(color.to_hex(), model)


def set_active_color_live(color, model) -> None:
    """Set the active color without pushing to recent colors (live slider drag)."""
    from geometry.element import Fill, Stroke
    if model.fill_on_top:
        model.default_fill = Fill(color=color)
    else:
        width = model.default_stroke.width if model.default_stroke else 1.0
        model.default_stroke = Stroke(color=color, width=width)


def push_recent_color(hex_str: str, model) -> None:
    """Push a hex color to recent colors (move-to-front dedup, max 10)."""
    rc = [c for c in model.recent_colors if c != hex_str]
    rc.insert(0, hex_str)
    model.recent_colors = rc[:10]
