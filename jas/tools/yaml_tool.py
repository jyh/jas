"""YAML-driven canvas tool — Python analogue of
jas_dioxus/src/tools/yaml_tool.rs, JasSwift/Sources/Tools/YamlTool.swift,
and jas_ocaml/lib/tools/yaml_tool.ml.

Parses a tool spec (typically from workspace.json under ``tools.<id>``)
into a :class:`ToolSpec`, seeds a private :class:`StateStore` with its
state defaults, and routes :class:`CanvasTool` events through the
declared handlers via :func:`run_effects` +
:func:`yaml_tool_effects.build`.

Phase 5 of the Python YAML tool-runtime migration: CanvasTool
conformance + event dispatch. Overlay rendering is stubbed —
render types land in Phase 5b alongside their tool ports.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any

from tools.tool import CanvasTool, ToolContext, KeyMods
from tools import yaml_tool_effects
from workspace_interpreter import doc_primitives
from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter


@dataclass(frozen=True)
class OverlaySpec:
    """Tool-overlay declaration — guard expression plus render JSON."""
    guard: str | None
    render: dict


@dataclass(frozen=True)
class ToolSpec:
    """Parsed shape of a tool YAML spec."""
    id: str
    cursor: str | None
    menu_label: str | None
    shortcut: str | None
    state_defaults: dict
    handlers: dict[str, list]
    overlay: OverlaySpec | None


def _parse_state_defaults(val: Any) -> dict:
    if not isinstance(val, dict):
        return {}
    out: dict = {}
    for key, defn in val.items():
        if isinstance(defn, dict):
            out[key] = defn.get("default")
        else:
            out[key] = defn
    return out


def _parse_handlers(val: Any) -> dict[str, list]:
    if not isinstance(val, dict):
        return {}
    out: dict[str, list] = {}
    for name, effects in val.items():
        if isinstance(effects, list):
            out[name] = effects
    return out


def _parse_overlay(val: Any) -> OverlaySpec | None:
    if not isinstance(val, dict):
        return None
    render = val.get("render")
    if not isinstance(render, dict):
        return None
    guard = val.get("if")
    return OverlaySpec(
        guard=guard if isinstance(guard, str) else None,
        render=render,
    )


def tool_spec_from_workspace(spec: Any) -> ToolSpec | None:
    """Parse a workspace tool spec. Returns None if id is missing."""
    if not isinstance(spec, dict):
        return None
    tid = spec.get("id")
    if not isinstance(tid, str):
        return None
    return ToolSpec(
        id=tid,
        cursor=spec.get("cursor") if isinstance(spec.get("cursor"), str) else None,
        menu_label=spec.get("menu_label") if isinstance(spec.get("menu_label"), str) else None,
        shortcut=spec.get("shortcut") if isinstance(spec.get("shortcut"), str) else None,
        state_defaults=_parse_state_defaults(spec.get("state")),
        handlers=_parse_handlers(spec.get("handlers")),
        overlay=_parse_overlay(spec.get("overlay")),
    )


def _pointer_payload(event_type: str, x: float, y: float,
                     shift: bool, alt: bool,
                     dragging: bool | None = None) -> dict:
    payload = {
        "type": event_type,
        "x": x, "y": y,
        "modifiers": {
            "shift": shift, "alt": alt,
            "ctrl": False, "meta": False,
        },
    }
    if dragging is not None:
        payload["dragging"] = dragging
    return payload


class YamlTool(CanvasTool):
    """YAML-driven tool. Holds a parsed :class:`ToolSpec` and a
    private :class:`StateStore` seeded with the tool's defaults."""

    def __init__(self, spec: ToolSpec):
        self._spec = spec
        self._store = StateStore()
        self._store.init_tool(spec.id, dict(spec.state_defaults))

    @classmethod
    def from_workspace_tool(cls, spec: Any) -> "YamlTool | None":
        ts = tool_spec_from_workspace(spec)
        return cls(ts) if ts is not None else None

    @property
    def spec(self) -> ToolSpec:
        return self._spec

    def tool_state(self, key: str) -> Any:
        return self._store.get_tool(self._spec.id, key)

    def _handler(self, event_name: str) -> list:
        return self._spec.handlers.get(event_name, [])

    def _dispatch(self, event_name: str, payload: dict,
                  ctx: ToolContext) -> None:
        effects = self._handler(event_name)
        if not effects:
            return
        eff_ctx = {"event": payload}
        guard = doc_primitives.register_document(ctx.document)
        try:
            platform_effects = yaml_tool_effects.build(ctx.controller)
            run_effects(effects, eff_ctx, self._store,
                        platform_effects=platform_effects)
        finally:
            guard.restore()

    # ── CanvasTool interface ────────────────────────────

    def on_press(self, ctx, x, y, shift=False, alt=False):
        self._dispatch(
            "on_mousedown",
            _pointer_payload("mousedown", x, y, shift, alt),
            ctx,
        )
        ctx.request_update()

    def on_move(self, ctx, x, y, shift=False, dragging=False):
        self._dispatch(
            "on_mousemove",
            _pointer_payload("mousemove", x, y, shift, False, dragging=dragging),
            ctx,
        )
        ctx.request_update()

    def on_release(self, ctx, x, y, shift=False, alt=False):
        self._dispatch(
            "on_mouseup",
            _pointer_payload("mouseup", x, y, shift, alt),
            ctx,
        )
        ctx.request_update()

    def on_double_click(self, ctx, x, y):
        self._dispatch(
            "on_dblclick",
            {"type": "dblclick", "x": x, "y": y},
            ctx,
        )
        ctx.request_update()

    def on_key(self, ctx, key):
        return False

    def on_key_release(self, ctx, key):
        return False

    def activate(self, ctx):
        # Re-seed tool-local state to declared defaults, then fire on_enter.
        self._store.init_tool(self._spec.id, dict(self._spec.state_defaults))
        self._dispatch("on_enter", {"type": "enter"}, ctx)
        ctx.request_update()

    def deactivate(self, ctx):
        self._dispatch("on_leave", {"type": "leave"}, ctx)
        ctx.request_update()

    def on_key_event(self, ctx, key, mods):
        if not self._handler("on_keydown"):
            return False
        payload = {
            "type": "keydown",
            "key": key,
            "modifiers": {
                "shift": mods.shift, "alt": mods.alt,
                "ctrl": mods.ctrl, "meta": mods.meta,
            },
        }
        self._dispatch("on_keydown", payload, ctx)
        ctx.request_update()
        return True

    def captures_keyboard(self) -> bool:
        return False

    def cursor_css_override(self) -> str | None:
        return self._spec.cursor

    def is_editing(self) -> bool:
        return False

    def paste_text(self, ctx, text) -> bool:
        return False

    def draw_overlay(self, ctx, painter) -> None:
        # Phase 5a stub — overlay rendering land in Phase 5b.
        # OverlaySpec is parsed and the guard can be evaluated, but
        # the rect / line / polygon / star / buffer / pen / partial
        # renderers go in alongside each tool's migration.
        return None
