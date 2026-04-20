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

ALL_PANEL_KINDS = [
    PanelKind.LAYERS, PanelKind.COLOR, PanelKind.SWATCHES,
    PanelKind.STROKE, PanelKind.PROPERTIES,
    PanelKind.CHARACTER, PanelKind.PARAGRAPH, PanelKind.ARTBOARDS,
    PanelKind.ALIGN,
]

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
    PanelKind.CHARACTER: "Character",
    PanelKind.PARAGRAPH: "Paragraph",
    PanelKind.ARTBOARDS: "Artboards",
    PanelKind.ALIGN: "Align",
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
    if kind == PanelKind.CHARACTER:
        return [
            PanelMenuItem.toggle("Show Snap to Glyph Options", "toggle_snap_to_glyph_visible"),
            PanelMenuItem.separator(),
            PanelMenuItem.toggle("All Caps", "toggle_all_caps"),
            PanelMenuItem.toggle("Small Caps", "toggle_small_caps"),
            PanelMenuItem.toggle("Superscript", "toggle_superscript"),
            PanelMenuItem.toggle("Subscript", "toggle_subscript"),
            PanelMenuItem.separator(),
            PanelMenuItem.action("Close Character", "close_panel"),
        ]
    if kind == PanelKind.ALIGN:
        return [
            PanelMenuItem.toggle("Use Preview Bounds", "toggle_use_preview_bounds"),
            PanelMenuItem.separator(),
            PanelMenuItem.action("Reset Panel", "reset_align_panel"),
            PanelMenuItem.separator(),
            PanelMenuItem.action("Close Align", "close_panel"),
        ]
    return [PanelMenuItem.action(f"Close {panel_label(kind)}", "close_panel")]


def _dispatch_yaml_layers_action(action_name: str, model,
                                  panel_selection=None,
                                  params=None,
                                  on_close_dialog=None) -> None:
    """Phase 3: dispatch a layers action through the compiled YAML effects.

    Builds active_document.top_level_layers / top_level_layer_paths from
    model.document.layers and registers snapshot + doc.set as platform
    effect handlers that operate on the Model.
    """
    panel_selection = panel_selection or []
    params = params or {}
    import dataclasses
    from geometry.element import Layer, Visibility
    from workspace_interpreter.loader import load_workspace
    from workspace_interpreter.state_store import StateStore
    from workspace_interpreter.effects import run_effects
    from workspace_interpreter.expr import evaluate
    import os

    # Locate workspace.json — the compiled actions catalog.
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    ws_dir = os.path.join(repo_root, "workspace")
    try:
        ws = load_workspace(ws_dir)
    except Exception:
        return
    actions = ws.get("actions", {})
    action_def = actions.get(action_name)
    if not action_def:
        return
    effects = action_def.get("effects", [])

    from panels.active_document_view import build_active_document_view
    active_doc = build_active_document_view(model, panel_selection=panel_selection)
    # Inject panel.layers_panel_selection as list of __path__ marker
    # dicts — matches the shape used by other apps so YAML expressions
    # like panel.layers_panel_selection[0] decode back to a Path value.
    selection_markers = [{"__path__": list(p)} for p in panel_selection]
    ctx = {
        "active_document": active_doc,
        "panel": {"layers_panel_selection": selection_markers},
        "param": params,
    }

    # Platform handlers
    def snapshot_handler(_value, _ctx, _store):
        model.snapshot()

    def doc_set_handler(spec, call_ctx, _store):
        if not isinstance(spec, dict):
            return
        path_expr = spec.get("path", "")
        fields = spec.get("fields", {})
        path_val = evaluate(path_expr, call_ctx)
        if path_val.type.name != "PATH":
            return
        indices = path_val.value
        if len(indices) != 1:
            return
        idx = indices[0]
        if idx < 0 or idx >= len(model.document.layers):
            return
        elem = model.document.layers[idx]
        if not isinstance(elem, Layer):
            return
        updates = {}
        for dotted, expr_v in fields.items():
            v = evaluate(str(expr_v) if expr_v is not None else "", call_ctx)
            if dotted == "common.visibility" and v.type.name == "STRING":
                vis_map = {"invisible": Visibility.INVISIBLE,
                           "outline": Visibility.OUTLINE,
                           "preview": Visibility.PREVIEW}
                if v.value in vis_map:
                    updates["visibility"] = vis_map[v.value]
            elif dotted == "common.locked" and v.type.name == "BOOL":
                updates["locked"] = v.value
            elif dotted == "name" and v.type.name == "STRING":
                updates["name"] = v.value
        if updates:
            new_layer = dataclasses.replace(elem, **updates)
            new_layers = tuple(
                new_layer if j == idx else l
                for j, l in enumerate(model.document.layers)
            )
            model.document = dataclasses.replace(
                model.document, layers=new_layers
            )

    # doc.create_layer: factory returning a Layer dataclass.
    def doc_create_layer_handler(spec, call_ctx, _store):
        if not isinstance(spec, dict):
            return None
        name_expr = spec.get("name", "'Layer'")
        v = evaluate(str(name_expr), call_ctx)
        name = v.value if v.type.name == "STRING" else "Layer"
        return Layer(name=name, children=())

    # doc.insert_at: top-level insertion for jas's Document dataclass.
    def doc_insert_at_handler(spec, call_ctx, _store):
        if not isinstance(spec, dict):
            return None
        parent_expr = spec.get("parent_path", "path()")
        parent_val = evaluate(str(parent_expr), call_ctx)
        if parent_val.type.name != "PATH" or parent_val.value != ():
            # Only top-level insertion supported here
            return None
        idx_raw = spec.get("index", 0)
        if isinstance(idx_raw, str):
            idx_v = evaluate(idx_raw, call_ctx)
            idx = int(idx_v.value) if idx_v.type.name == "NUMBER" else 0
        else:
            idx = int(idx_raw) if isinstance(idx_raw, (int, float)) else 0
        # Resolve element: raw Layer or ctx-bound name
        elem = None
        el_spec = spec.get("element")
        if isinstance(el_spec, Layer):
            elem = el_spec
        elif isinstance(el_spec, str):
            ctx_val = call_ctx.get(el_spec)
            if isinstance(ctx_val, Layer):
                elem = ctx_val
        if elem is None:
            return None
        layers = list(model.document.layers)
        insert_idx = max(0, min(idx, len(layers)))
        layers.insert(insert_idx, elem)
        model.document = dataclasses.replace(
            model.document, layers=tuple(layers)
        )
        return None

    # doc.delete_at: "path(...)". Deletes the element at the given path
    # (supports arbitrary depth) and returns the removed element so
    # duplicate_layer_selection's clone-then-insert chain can thread it
    # through the as:-binding ctx.
    def doc_delete_at_handler(value, call_ctx, _store):
        path_expr = value if isinstance(value, str) else ""
        v = evaluate(path_expr, call_ctx)
        if v.type.name != "PATH":
            return None
        indices = tuple(v.value)
        if not indices:
            return None
        doc = model.document
        try:
            elem = doc.get_element(indices)
        except Exception:
            return None
        model.document = doc.delete_element(indices)
        return elem

    def doc_clone_at_handler(value, call_ctx, _store):
        path_expr = value if isinstance(value, str) else ""
        v = evaluate(path_expr, call_ctx)
        if v.type.name != "PATH":
            return None
        indices = tuple(v.value)
        if not indices:
            return None
        try:
            return model.document.get_element(indices)
        except Exception:
            return None

    def doc_insert_after_handler(spec, call_ctx, _store):
        if not isinstance(spec, dict):
            return None
        path_expr = spec.get("path", "")
        v = evaluate(str(path_expr), call_ctx)
        if v.type.name != "PATH":
            return None
        indices = tuple(v.value)
        if not indices:
            return None
        # element: raw element or a ctx-bound name from as:.
        el_spec = spec.get("element")
        elem = None
        if isinstance(el_spec, str):
            # Identifier lookup: ctx value set by an earlier as:-binding.
            ctx_val = call_ctx.get(el_spec)
            if ctx_val is not None and not isinstance(ctx_val, (str, int, float, bool, dict, list)):
                elem = ctx_val
        if elem is None and el_spec is not None and not isinstance(el_spec, (str, int, float, bool, dict, list)):
            elem = el_spec
        if elem is None:
            return None
        model.document = model.document.insert_element_after(indices, elem)
        return None

    def doc_unpack_group_at_handler(value, call_ctx, _store):
        from geometry.element import Group as _Group
        path_expr = value if isinstance(value, str) else ""
        v = evaluate(path_expr, call_ctx)
        if v.type.name != "PATH":
            return None
        indices = tuple(v.value)
        if not indices:
            return None
        doc = model.document
        try:
            elem = doc.get_element(indices)
        except Exception:
            return None
        if not isinstance(elem, _Group):
            return None
        children = list(elem.children)
        new_doc = doc.delete_element(indices)
        # Insert each child at the group's position in reverse order so
        # they end up in the original child order at the parent site.
        for child in reversed(children):
            new_doc = new_doc.insert_element_after(
                indices[:-1] + (indices[-1] - 1,) if indices[-1] > 0 else indices,
                child,
            ) if indices[-1] == 0 else new_doc.insert_element_after(
                indices[:-1] + (indices[-1] - 1,), child
            )
        model.document = new_doc
        return None

    def doc_wrap_in_layer_handler(spec, call_ctx, _store):
        import dataclasses as _dc
        from geometry.element import Layer as _Layer
        if not isinstance(spec, dict):
            return None
        paths_expr = spec.get("paths", "[]")
        v = evaluate(str(paths_expr), call_ctx)
        if v.type.name != "LIST":
            return None
        # Decode list of __path__ markers into index tuples.
        paths = []
        for item in v.value:
            if isinstance(item, dict) and "__path__" in item:
                indices = item["__path__"]
                if isinstance(indices, (list, tuple)):
                    paths.append(tuple(int(i) for i in indices))
        if not paths:
            return None
        # Resolve name expression (defaults to "'Layer'").
        name_expr = spec.get("name", "'Layer'")
        nm = evaluate(str(name_expr), call_ctx)
        name = nm.value if nm.type.name == "STRING" else "Layer"
        # Collect elements in document order, then remove sources from
        # bottom-up so earlier indices stay valid.
        sorted_paths = sorted(paths)
        try:
            elems = tuple(model.document.get_element(pp) for pp in sorted_paths)
        except Exception:
            return None
        new_doc = model.document
        for pp in sorted(sorted_paths, reverse=True):
            new_doc = new_doc.delete_element(pp)
        new_layer = _Layer(name=name, children=elems)
        model.document = _dc.replace(
            new_doc, layers=new_doc.layers + (new_layer,)
        )
        return None

    # list_push: {target, value}. Phase 3 Group D (enter_isolation_mode).
    # Only target=panel.isolation_stack is handled here; writes the
    # evaluated Path value to layers_panel_state.
    from jas.panels import layers_panel_state as _lps

    def list_push_handler(spec, call_ctx, _store):
        if not isinstance(spec, dict):
            return None
        if spec.get("target") != "panel.isolation_stack":
            return None
        value_expr = spec.get("value", "null")
        v = evaluate(str(value_expr), call_ctx)
        if v.type.name == "PATH":
            _lps.push_isolation_level(tuple(v.value))
        return None

    # pop: "panel.isolation_stack" (Phase 3 Group D, exit_isolation_mode).
    def pop_handler(value, _ctx, _store):
        if value == "panel.isolation_stack":
            _lps.pop_isolation_level()
        return None

    # close_dialog: invoke the on_close_dialog callback when the YAML
    # action ends with close_dialog. Layer Options uses this to dismiss
    # its Qt dialog after layer_options_confirm commits.
    def close_dialog_handler(_value, _ctx, _store):
        if on_close_dialog is not None:
            on_close_dialog()
        return None

    platform_effects = {
        "snapshot": snapshot_handler,
        "doc.set": doc_set_handler,
        "doc.create_layer": doc_create_layer_handler,
        "doc.insert_at": doc_insert_at_handler,
        "doc.delete_at": doc_delete_at_handler,
        "doc.clone_at": doc_clone_at_handler,
        "doc.insert_after": doc_insert_after_handler,
        "doc.unpack_group_at": doc_unpack_group_at_handler,
        "doc.wrap_in_layer": doc_wrap_in_layer_handler,
        "list_push": list_push_handler,
        "pop": pop_handler,
    }
    if on_close_dialog is not None:
        platform_effects["close_dialog"] = close_dialog_handler

    store = StateStore()
    run_effects(effects, ctx, store,
                actions=actions, platform_effects=platform_effects)


def panel_dispatch(kind: PanelKind, cmd: str, addr: PanelAddr,
                   layout: WorkspaceLayout, model=None) -> None:
    """Dispatch a menu command for a panel kind."""
    # Mode changes
    if cmd in COLOR_MODE_COMMANDS:
        layout.color_panel_mode = COLOR_MODE_COMMANDS[cmd]
        return
    if cmd == "close_panel":
        layout.close_panel(addr)
    elif cmd in ("new_layer",
                 "toggle_all_layers_visibility",
                 "toggle_all_layers_outline",
                 "toggle_all_layers_lock",
                 "exit_isolation_mode") and kind == PanelKind.LAYERS and model is not None:
        _dispatch_yaml_layers_action(cmd, model)
    elif cmd in ("enter_isolation_mode",
                  "delete_layer_selection",
                  "duplicate_layer_selection",
                  "new_group",
                  "flatten_artwork",
                  "collect_in_new_layer") and kind == PanelKind.LAYERS and model is not None:
        # Selection-aware commands. The menu-bar callsite has no handle
        # on the current tree selection, so routing here acts as a
        # no-op unless the caller plumbs one in via
        # _dispatch_yaml_layers_action directly (yaml_renderer does).
        _dispatch_yaml_layers_action(cmd, model)
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
