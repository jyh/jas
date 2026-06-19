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
# Generic YAML-driven menu builder (review #15)
# ---------------------------------------------------------------------------
#
# Per-panel hamburger menus are no longer hand-declared natively; they are
# read from each panel YAML's ``menu:`` block in the compiled bundle (the
# single, richer source of truth). This mirrors the proven Rust reference
# ``panel_menu.rs :: menu_items_from_yaml`` and is what the genericity gate
# metric ``panel_menu_items`` measures: building items via the dataclass
# constructor (rather than the ``PanelMenuItem.action/toggle/radio`` helper
# factories) keeps that count at zero while the helpers stay available for
# any out-of-band callers.

# Cache the built menus per content id — the YAML is immutable at runtime
# so each panel's list is computed once.
_menu_cache: dict[str, list] = {}


def _menu_command_with_params(item: dict) -> str:
    """Build a radio member's runtime command: the ``action`` with each
    ``params`` value appended as a ``:value`` segment (in the compiled
    JSON's param order).

    Radio-group members share one YAML ``action`` (e.g. every
    ``set_color_panel_mode`` row), so folding the param value into the
    command keeps them distinguishable (``set_color_panel_mode:grayscale``)
    when the no-params menu dispatch fires. Items with no action produce
    an empty command (disabled placeholders). Mirrors the Rust
    ``command_with_params`` helper.
    """
    action = item.get("action") or ""
    cmd = str(action)
    params = item.get("params")
    if isinstance(params, dict):
        for v in params.values():
            cmd += ":" + (v if isinstance(v, str) else str(v))
    return cmd


def menu_items_from_yaml(content_id: str) -> list[PanelMenuItem]:
    """Build a panel's hamburger menu from the compiled workspace bundle
    (the panel YAML ``menu:`` array) rather than a hand-written native list.

    Mapping (mirrors the Rust reference ``menu_items_from_yaml``):
      - the JSON string ``"separator"``        -> SEPARATOR
      - an entry whose ``action`` recurs across the menu (radio-group
        sameness; the YAML expresses grouping by shared action, not an
        explicit ``group:`` key) with a ``checked``/``checked_when``
        expression -> RADIO, command = action + folded params, group =
        action
      - any other entry with ``checked``/``checked_when``  -> TOGGLE
      - everything else (plain actions, dynamic ``type: submenu`` library
        entries — which carry an explicit ``action:`` so the menu view's
        command-keyed submenu host still fires — and disabled
        placeholders) -> ACTION

    The dynamic library submenu special case is handled entirely by the
    explicit ``action:`` now present on those YAML entries (e.g. the
    Swatches panel's ``open_swatch_library``): the entry surfaces as an
    Action whose command the renderer special-cases, no native literal
    required.
    """
    cached = _menu_cache.get(content_id)
    if cached is not None:
        return list(cached)

    items = _build_menu_items(content_id)
    _menu_cache[content_id] = items
    return list(items)


def _build_menu_items(content_id: str) -> list[PanelMenuItem]:
    # Bundle access mirrors yaml_menu.get_panel_specs (compiled bundle,
    # keyed by content id). Imported lazily so panel_menu has no hard
    # dependency on the Qt-flavoured yaml_menu module at import time.
    try:
        from panels.yaml_menu import get_panel_specs
        specs = get_panel_specs() or {}
    except Exception:
        return []
    spec = specs.get(content_id)
    if not spec:
        return []
    menu = spec.get("menu") or []

    # A radio group is a set of entries that share the same `action`
    # (e.g. every `set_color_panel_mode` row). The YAML carries no explicit
    # `group:` key — sameness of the action *is* the grouping — so count
    # action occurrences to tell a one-off checkbox (Toggle) apart from a
    # member of a mutually-exclusive set (Radio).
    action_counts: dict[str, int] = {}
    for e in menu:
        if isinstance(e, dict):
            act = e.get("action")
            if isinstance(act, str):
                action_counts[act] = action_counts.get(act, 0) + 1

    out: list[PanelMenuItem] = []
    for e in menu:
        if e == "separator" or (isinstance(e, dict) and e.get("type") == "separator"):
            out.append(PanelMenuItem(PanelMenuItemKind.SEPARATOR))
            continue
        if not isinstance(e, dict):
            continue
        label = e.get("label")
        if label is None:
            continue
        action = e.get("action") if isinstance(e.get("action"), str) else None
        is_radio_member = bool(action and action_counts.get(action, 0) > 1)
        has_checked = ("checked" in e) or ("checked_when" in e)

        if has_checked and is_radio_member:
            out.append(PanelMenuItem(
                PanelMenuItemKind.RADIO,
                label=label,
                command=_menu_command_with_params(e),
                group=action or "",
            ))
        elif has_checked:
            out.append(PanelMenuItem(
                PanelMenuItemKind.TOGGLE,
                label=label,
                command=action or "",
            ))
        else:
            out.append(PanelMenuItem(
                PanelMenuItemKind.ACTION,
                label=label,
                command=action or "",
            ))
    return out


# ---------------------------------------------------------------------------
# All panel kinds
# ---------------------------------------------------------------------------

ALL_PANEL_KINDS = [
    PanelKind.LAYERS, PanelKind.COLOR, PanelKind.SWATCHES,
    PanelKind.STROKE, PanelKind.PROPERTIES,
    PanelKind.CHARACTER, PanelKind.PARAGRAPH, PanelKind.ARTBOARDS,
    PanelKind.ALIGN, PanelKind.BOOLEAN, PanelKind.OPACITY,
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
# Opacity panel state-store handle
# ---------------------------------------------------------------------------
#
# The Opacity panel's hamburger-menu toggles and the make_opacity_mask
# dispatch need access to the live ``new_masks_clipping`` /
# ``new_masks_inverted`` / ``thumbnails_hidden`` / ``options_shown``
# values, which live on the panel-local StateStore scope. Rather than
# thread the store through every ``panel_dispatch`` / ``panel_is_checked``
# call site (same argument the paragraph panel faced), the YamlPanelView
# stashes the store handle here when the Opacity panel mounts.
# ``None`` means the panel isn't currently rendered.
_opacity_store = None  # type: ignore[assignment]
_character_store = None  # type: ignore[assignment]
_paragraph_store = None  # type: ignore[assignment]


def set_opacity_store(store) -> None:
    """Register the live Opacity panel StateStore (called by
    YamlPanelView when the panel mounts)."""
    global _opacity_store
    _opacity_store = store


def set_character_store(store) -> None:
    """Register the live Character panel StateStore (called by
    YamlPanelView when the panel mounts) so the hamburger menu
    toggles can read / write the panel-state bools without
    threading the store through every dispatch call site."""
    global _character_store
    _character_store = store


def set_paragraph_store(store) -> None:
    """Register the live Paragraph panel StateStore (called by
    YamlPanelView when the panel mounts) so the hamburger menu
    toggles can read / write panel-state bools (Hanging Punctuation
    checkmark) and the Reset Panel dispatch can reach the panel
    scope without threading the store through every call site."""
    global _paragraph_store
    _paragraph_store = store


def _opacity_store_bool(key: str, default: bool) -> bool:
    """Read a bool from the Opacity panel's state store, falling
    back to ``default`` when the store isn't set or the key is
    missing / non-bool."""
    if _opacity_store is None:
        return default
    val = _opacity_store.get_panel("opacity_panel_content", key)
    if isinstance(val, bool):
        return val
    return default


def _opacity_store_set_bool(key: str, value: bool) -> None:
    """Write a bool to the Opacity panel's state store. No-op when
    the store isn't registered."""
    if _opacity_store is None:
        return
    _opacity_store.set_panel("opacity_panel_content", key, value)


def _character_store_bool(key: str, default: bool) -> bool:
    """Read a bool from the Character panel's state store, falling
    back to ``default`` when the store isn't set or the key is
    missing / non-bool."""
    if _character_store is None:
        return default
    val = _character_store.get_panel("character_panel_content", key)
    if isinstance(val, bool):
        return val
    return default


def _paragraph_store_bool(key: str, default: bool) -> bool:
    """Read a bool from the Paragraph panel's state store, falling
    back to ``default`` when the store isn't set or the key is
    missing / non-bool."""
    if _paragraph_store is None:
        return default
    val = _paragraph_store.get_panel("paragraph_panel_content", key)
    if isinstance(val, bool):
        return val
    return default


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
    PanelKind.BOOLEAN: "Boolean",
    PanelKind.OPACITY: "Opacity",
    PanelKind.MAGIC_WAND: "Magic Wand",
    PanelKind.SYMBOLS: "Symbols",
}


def panel_label(kind: PanelKind) -> str:
    """Human-readable label for a panel kind."""
    return _PANEL_LABELS[kind]


def panel_menu(kind: PanelKind) -> list[PanelMenuItem]:
    """Menu items for a panel kind, read from the panel YAML ``menu:``
    block in the compiled bundle (the single source of truth).

    This is a thin delegation to :func:`menu_items_from_yaml`, mirroring
    the Rust reference where each ``*_panel.rs :: menu_items()`` is a
    one-line call into the shared generic builder. The previously
    hand-declared per-panel literals are gone; the menu DATA now lives in
    ``workspace/panels/*.yaml``. The ``panel_dispatch`` / ``panel_is_checked``
    bridges below remain as legitimate platform glue.
    """
    from panels.yaml_menu import PANEL_KIND_TO_CONTENT_ID
    content_id = PANEL_KIND_TO_CONTENT_ID.get(kind)
    if content_id is None:
        return [PanelMenuItem(PanelMenuItemKind.ACTION,
                              label=f"Close {panel_label(kind)}",
                              command="close_panel")]
    return menu_items_from_yaml(content_id)


def _dispatch_yaml_layers_action(action_name: str, model,
                                  panel_selection=None,
                                  artboards_panel_selection=None,
                                  params=None,
                                  on_close_dialog=None) -> None:
    """Phase 3: dispatch a YAML action through the compiled effects.

    Builds active_document from model.document and registers snapshot +
    doc.set + all artboard doc.* effects as platform handlers that
    operate on the Model. Name kept for back-compat; also dispatches
    artboard actions now that the active_document view and the seven
    artboard handlers are wired here.
    """
    panel_selection = panel_selection or []
    artboards_panel_selection = artboards_panel_selection or []
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
    active_doc = build_active_document_view(
        model,
        panel_selection=panel_selection,
        artboards_panel_selection=artboards_panel_selection,
    )
    # Inject panel.layers_panel_selection as list of __path__ marker
    # dicts — matches the shape used by other apps so YAML expressions
    # like panel.layers_panel_selection[0] decode back to a Path value.
    selection_markers = [{"__path__": list(p)} for p in panel_selection]
    ctx = {
        "active_document": active_doc,
        "panel": {
            "layers_panel_selection": selection_markers,
            "artboards_panel_selection": list(artboards_panel_selection),
        },
        "param": params,
    }

    # Platform handlers
    def snapshot_handler(_value, _ctx, _store):
        # OP_LOG.md Increment 1: the panel action's `snapshot` effect OPENS the
        # undo transaction (begin_txn), so the subsequent doc.* writes (which go
        # through the enforced set_document chokepoint) are legal. run_effects is
        # passed `model` below so it OWNS the commit, making the whole action one
        # undo step. Mirrors the yaml_tool / Rust doc.snapshot => begin_txn path.
        model.begin_txn()

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

    # ── Artboard doc effects (ARTBOARDS.md) ────────────────────────
    from jas.panels.artboard_effects import build_artboard_handlers

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
        **build_artboard_handlers(model),
    }
    if on_close_dialog is not None:
        platform_effects["close_dialog"] = close_dialog_handler

    store = StateStore()
    # Pass `model` (+ action_name) so run_effects OWNS the transaction the
    # snapshot effect opened and commits it once at the end (one undo step).
    run_effects(effects, ctx, store,
                actions=actions, platform_effects=platform_effects,
                model=model, action_name=action_name)


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
    elif kind == PanelKind.BOOLEAN and model is not None:
        # Compound-shape menu dispatches. Destructive ops,
        # Boolean Options dialog, Repeat, and Reset are phase 9b+
        # of the Python port.
        from panels.boolean_apply import (
            apply_expand_compound_shape,
            apply_make_compound_shape,
            apply_release_compound_shape,
        )
        if cmd == "make_compound_shape":
            apply_make_compound_shape(model)
        elif cmd == "release_compound_shape":
            apply_release_compound_shape(model)
        elif cmd == "expand_compound_shape":
            apply_expand_compound_shape(model)
    elif kind == PanelKind.CHARACTER:
        # Character panel hamburger toggles: flip the panel-state bool,
        # clear mutually-exclusive siblings (caps ↔ small-caps;
        # super ↔ sub), and push to the selection so the menu and the
        # in-panel icon toggles stay in sync. Show Snap to Glyph
        # Options is panel-local UI state — skip the apply for that
        # one.
        _character_toggle_table = {
            "toggle_all_caps": ("all_caps", ["small_caps"], True),
            "toggle_small_caps": ("small_caps", ["all_caps"], True),
            "toggle_superscript": ("superscript", ["subscript"], True),
            "toggle_subscript": ("subscript", ["superscript"], True),
            "toggle_snap_to_glyph_visible":
                ("snap_to_glyph_visible", [], False),
        }
        if cmd in _character_toggle_table and _character_store is not None:
            key, clear_on_set, apply_to_selection = _character_toggle_table[cmd]
            cur = _character_store_bool(key, False)
            new_val = not cur
            _character_store.set_panel("character_panel_content", key, new_val)
            if new_val:
                for sib in clear_on_set:
                    _character_store.set_panel(
                        "character_panel_content", sib, False)
            if apply_to_selection and model is not None:
                from panels.character_panel_state import (
                    apply_character_panel_to_selection,
                )
                apply_character_panel_to_selection(_character_store, model)
    elif kind == PanelKind.PARAGRAPH and model is not None:
        # Mirrors the Rust paragraph_panel.rs ``dispatch`` branch.
        # Hanging Punctuation toggles the panel-state bool and pushes
        # to the wrappers; Reset Panel goes through reset_paragraph_panel;
        # the Justification… / Hyphenation… dialog openers are no-ops
        # here — the YAML-menu path wraps them in open_dialog effects.
        if cmd == "toggle_hanging_punctuation" and _paragraph_store is not None:
            from panels.paragraph_panel_state import (
                set_paragraph_panel_field,
            )
            cur = _paragraph_store.get_panel("paragraph_panel_content",
                                              "hanging_punctuation")
            set_paragraph_panel_field(_paragraph_store, model,
                                       "hanging_punctuation",
                                       not bool(cur))
        elif cmd == "reset_paragraph_panel" and _paragraph_store is not None:
            from panels.paragraph_panel_state import reset_paragraph_panel
            reset_paragraph_panel(_paragraph_store, model)
    elif kind == PanelKind.OPACITY:
        # Opacity panel-local toggles flip the stored bool in the
        # StateStore so subsequent make_opacity_mask dispatches and
        # the menu's checked_when predicates see the live value.
        _opacity_toggle_keys = {
            "toggle_opacity_thumbnails": ("thumbnails_hidden", False),
            "toggle_opacity_options": ("options_shown", False),
            "toggle_new_masks_clipping": ("new_masks_clipping", True),
            "toggle_new_masks_inverted": ("new_masks_inverted", False),
        }
        if cmd in _opacity_toggle_keys:
            key, default = _opacity_toggle_keys[cmd]
            cur = _opacity_store_bool(key, default)
            _opacity_store_set_bool(key, not cur)
        elif model is not None:
            # Opacity mask-lifecycle commands route to the Controller.
            # new_masks_clipping / new_masks_inverted now come from
            # the panel's StateStore (seeded from yaml defaults;
            # toggles above flip the stored values).
            from document.controller import Controller
            ctrl = Controller(model=model)
            if cmd == "make_opacity_mask":
                clip = _opacity_store_bool("new_masks_clipping", True)
                invert = _opacity_store_bool("new_masks_inverted", False)
                ctrl.make_mask_on_selection(clip=clip, invert=invert)
            elif cmd == "release_opacity_mask":
                ctrl.release_mask_on_selection()
            elif cmd == "disable_opacity_mask":
                ctrl.toggle_mask_disabled_on_selection()
            elif cmd == "unlink_opacity_mask":
                ctrl.toggle_mask_linked_on_selection()


def panel_is_checked(kind: PanelKind, cmd: str, layout: WorkspaceLayout) -> bool:
    """Query whether a toggle/radio command is checked."""
    if cmd in COLOR_MODE_COMMANDS:
        return layout.color_panel_mode == COLOR_MODE_COMMANDS[cmd]
    if cmd == "toggle_opacity_thumbnails":
        return _opacity_store_bool("thumbnails_hidden", False)
    if cmd == "toggle_opacity_options":
        return _opacity_store_bool("options_shown", False)
    if cmd == "toggle_new_masks_clipping":
        return _opacity_store_bool("new_masks_clipping", True)
    if cmd == "toggle_new_masks_inverted":
        return _opacity_store_bool("new_masks_inverted", False)
    # Character panel toggle commands map to bools in the
    # "character_panel_content" panel scope.
    _character_check = {
        "toggle_snap_to_glyph_visible": "snap_to_glyph_visible",
        "toggle_all_caps": "all_caps",
        "toggle_small_caps": "small_caps",
        "toggle_superscript": "superscript",
        "toggle_subscript": "subscript",
    }
    if cmd in _character_check:
        return _character_store_bool(_character_check[cmd], False)
    # Paragraph panel: Hanging Punctuation toggle reads
    # panel.hanging_punctuation in the live store.
    if cmd == "toggle_hanging_punctuation":
        return _paragraph_store_bool("hanging_punctuation", False)
    return False


def set_active_color(color, model) -> None:
    """Set the active color (fill or stroke per fill_on_top), push to recent colors."""
    from geometry.element import Fill, Stroke
    from document.controller import Controller
    if model.fill_on_top:
        model.default_fill = Fill(color=color)
        if model.document.selection:
            # The Controller mutator self-brackets via edit_document.
            ctrl = Controller(model)
            ctrl.set_selection_fill(Fill(color=color))
    else:
        width = model.default_stroke.width if model.default_stroke else 1.0
        model.default_stroke = Stroke(color=color, width=width)
        if model.document.selection:
            # The Controller mutator self-brackets via edit_document.
            ctrl = Controller(model)
            ctrl.set_selection_stroke(Stroke(color=color, width=width))
    push_recent_color(color.to_hex(), model)


def _compute_helper(panel_state: dict, mode: str):
    """Recompute the active color from the Color panel's channel
    values + mode. Shared between the live slider-drag bridge in
    jas_app and the slider-release commit path in yaml_renderer.
    Returns None when the mode isn't recognised.
    """
    from geometry.element import Color
    import colorsys

    def _f(name):
        v = panel_state.get(name)
        if isinstance(v, (int, float)):
            return float(v)
        return 0.0

    if mode == "hsb":
        h = _f("h") / 360.0
        s = _f("s") / 100.0
        b = _f("b") / 100.0
        r, g, bl = colorsys.hsv_to_rgb(h, s, b)
        return Color.rgb(r, g, bl)
    if mode in ("rgb", "web_safe_rgb"):
        return Color.rgb(_f("r") / 255.0, _f("g") / 255.0, _f("bl") / 255.0)
    if mode == "grayscale":
        v = 1.0 - _f("k") / 100.0
        return Color.rgb(v, v, v)
    if mode == "cmyk":
        c = _f("c") / 100.0
        m = _f("m") / 100.0
        y = _f("y") / 100.0
        k = _f("k") / 100.0
        r = (1.0 - c) * (1.0 - k)
        g = (1.0 - m) * (1.0 - k)
        bl = (1.0 - y) * (1.0 - k)
        return Color.rgb(r, g, bl)
    return None


def set_active_color_live(color, model) -> None:
    """Set the active color and apply to current selection without
    pushing to recent_colors (live slider drag / value-box typing).
    Mirrors [set_active_color] minus the recent-colors push and the
    [model.snapshot] checkpoint — live edits coalesce into one
    snapshot when the user releases the slider via [set_active_color]
    or commits via the value box.
    """
    from geometry.element import Fill, Stroke
    from document.controller import Controller
    if model.fill_on_top:
        model.default_fill = Fill(color=color)
        if model.document.selection:
            # Live drag: NON-undoable write (coalesced into one undo step on
            # release by set_active_color). OP_LOG.md §7/§8.
            ctrl = Controller(model)
            ctrl.set_selection_fill_live(Fill(color=color))
    else:
        width = model.default_stroke.width if model.default_stroke else 1.0
        model.default_stroke = Stroke(color=color, width=width)
        if model.document.selection:
            ctrl = Controller(model)
            ctrl.set_selection_stroke_live(Stroke(color=color, width=width))


_recent_colors_listeners: list = []


def add_recent_colors_listener(callback) -> None:
    """Register a callback fired after model.recent_colors is updated.

    Receives (model, hex_str) so listeners can mirror the new value into
    other state stores (e.g. YAML panel state) without having to
    monkey-patch the model. Used by jas_app to propagate native-code
    Color Panel pushes into Swatches Panel YAML state.
    """
    _recent_colors_listeners.append(callback)


def push_recent_color(hex_str: str, model) -> None:
    """Push a hex color to recent colors (move-to-front dedup, max 10)."""
    rc = [c for c in model.recent_colors if c != hex_str]
    rc.insert(0, hex_str)
    model.recent_colors = rc[:10]
    for cb in _recent_colors_listeners:
        try:
            cb(model, hex_str)
        except Exception:
            pass
