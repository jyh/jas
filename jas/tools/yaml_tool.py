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

import math
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any

from tools.tool import CanvasTool, ToolContext, KeyMods
from tools import yaml_tool_effects
from workspace_interpreter import (
    anchor_buffers,
    doc_primitives,
    point_buffers,
)
from workspace_interpreter.effects import run_effects
from workspace_interpreter.expr import evaluate
from workspace_interpreter.expr_types import ValueType
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
    # Overlay declarations. Most tools have zero or one entry; the
    # transform-tool family (Scale / Rotate / Shear) uses multiple
    # to layer the reference-point cross over the drag-time bbox
    # ghost. Each entry's guard is evaluated independently.
    overlay: list[OverlaySpec]


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


def _parse_overlay_entry(obj: dict) -> OverlaySpec | None:
    render = obj.get("render")
    if not isinstance(render, dict):
        return None
    guard = obj.get("if")
    return OverlaySpec(
        guard=guard if isinstance(guard, str) else None,
        render=render,
    )


def _parse_overlay(val: Any) -> list[OverlaySpec]:
    """Accept either a single {if, render} dict (most tools) or a
    list of such dicts (transform-tool family). Both produce the
    same list[OverlaySpec] downstream."""
    if isinstance(val, dict):
        entry = _parse_overlay_entry(val)
        return [entry] if entry else []
    if isinstance(val, list):
        return [
            entry for entry in
            (_parse_overlay_entry(item) for item in val if isinstance(item, dict))
            if entry is not None
        ]
    return []


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
        if not self._spec.overlay:
            return None
        eval_ctx = self._store.eval_context()
        # Register the active document for doc-aware primitives. The
        # partial_selection_overlay reads selected elements directly
        # off ctx.document, but other render types use expression
        # helpers that may resolve through the doc primitive shim.
        guard = doc_primitives.register_document(ctx.document)
        try:
            for overlay in self._spec.overlay:
                if overlay.guard is not None:
                    if not evaluate(overlay.guard, eval_ctx).to_bool():
                        continue
                render = overlay.render
                if not isinstance(render, dict):
                    continue
                render_type = render.get("type", "")
                if render_type == "rect":
                    _draw_rect_overlay(painter, render, eval_ctx)
                elif render_type == "line":
                    _draw_line_overlay(painter, render, eval_ctx)
                elif render_type == "polygon":
                    _draw_regular_polygon_overlay(painter, render, eval_ctx)
                elif render_type == "star":
                    _draw_star_overlay(painter, render, eval_ctx)
                elif render_type == "buffer_polygon":
                    _draw_buffer_polygon_overlay(painter, render)
                elif render_type == "buffer_polyline":
                    _draw_buffer_polyline_overlay(painter, render, eval_ctx)
                elif render_type == "pen_overlay":
                    _draw_pen_overlay(painter, render, eval_ctx)
                elif render_type == "partial_selection_overlay":
                    _draw_partial_selection_overlay(
                        painter, render, eval_ctx, ctx.document)
                elif render_type == "oval_cursor":
                    _draw_oval_cursor_overlay(painter, render, eval_ctx)
                elif render_type == "reference_point_cross":
                    _draw_reference_point_cross(
                        painter, render, eval_ctx, ctx.document)
                elif render_type == "bbox_ghost":
                    _draw_bbox_ghost(
                        painter, render, eval_ctx, ctx.document)
        finally:
            guard.restore()


# ═══════════════════════════════════════════════════════════════
# Overlay rendering (Phase 5b)
#
# Ports jas_dioxus/src/tools/yaml_tool.rs draw_*_overlay functions
# to QPainter. Each render type is a module-level _draw_ helper;
# dispatch happens in YamlTool.draw_overlay above.
# ═══════════════════════════════════════════════════════════════


@dataclass(frozen=True)
class OverlayStyle:
    """Subset of CSS style properties the overlay renderer
    understands. Mirrors the Rust / OCaml OverlayStyle."""
    fill: str | None = None
    stroke: str | None = None
    stroke_width: float | None = None
    stroke_dasharray: tuple[float, ...] | None = None


def parse_style(s: str) -> OverlayStyle:
    """Parse a CSS-like ``"key: value; key: value"`` string.
    Unknown keys and malformed rules are ignored."""
    fill = stroke = None
    stroke_width = None
    stroke_dasharray: tuple[float, ...] | None = None
    for rule in s.split(";"):
        rule = rule.strip()
        if not rule or ":" not in rule:
            continue
        key, _, value = rule.partition(":")
        key = key.strip()
        value = value.strip()
        if key == "fill":
            fill = value
        elif key == "stroke":
            stroke = value
        elif key == "stroke-width":
            try:
                stroke_width = float(value)
            except ValueError:
                pass
        elif key == "stroke-dasharray":
            parts: list[float] = []
            for p in value.replace(",", " ").split():
                try:
                    parts.append(float(p))
                except ValueError:
                    pass
            if parts:
                stroke_dasharray = tuple(parts)
    return OverlayStyle(
        fill=fill,
        stroke=stroke,
        stroke_width=stroke_width,
        stroke_dasharray=stroke_dasharray,
    )


def parse_color(s: str) -> tuple[float, float, float, float] | None:
    """Parse a CSS color string into ``(r, g, b, a)`` normalized
    to ``[0.0, 1.0]``. Accepts ``#rrggbb``/``#rgb``/``rgb(...)``/
    ``rgba(...)``/``black``/``white``/``none``. Returns ``None``
    for ``none`` or unparseable input."""
    s = s.strip()
    if not s or s == "none":
        return None
    if s == "black":
        return (0.0, 0.0, 0.0, 1.0)
    if s == "white":
        return (1.0, 1.0, 1.0, 1.0)
    if s.startswith("#"):
        hex_s = s[1:]
        if len(hex_s) == 3:
            hex_s = "".join(c * 2 for c in hex_s)
        if len(hex_s) != 6:
            return None
        try:
            r = int(hex_s[0:2], 16) / 255.0
            g = int(hex_s[2:4], 16) / 255.0
            b = int(hex_s[4:6], 16) / 255.0
            return (r, g, b, 1.0)
        except ValueError:
            return None
    for prefix, has_alpha in (("rgba(", True), ("rgb(", False)):
        if s.startswith(prefix):
            body = s[len(prefix):].rstrip(")").strip()
            parts = [p.strip() for p in body.split(",")]
            try:
                if has_alpha and len(parts) == 4:
                    return (
                        float(parts[0]) / 255.0,
                        float(parts[1]) / 255.0,
                        float(parts[2]) / 255.0,
                        float(parts[3]),
                    )
                if not has_alpha and len(parts) == 3:
                    return (
                        float(parts[0]) / 255.0,
                        float(parts[1]) / 255.0,
                        float(parts[2]) / 255.0,
                        1.0,
                    )
            except ValueError:
                return None
            return None
    return None


def _eval_number_field(ctx: dict, field: Any) -> float:
    """Evaluate an overlay numeric field. None / null / non-numeric
    → 0.0; string → evaluated as an expression."""
    if field is None:
        return 0.0
    if isinstance(field, bool):
        return float(field)
    if isinstance(field, (int, float)):
        return float(field)
    if isinstance(field, str):
        v = evaluate(field, ctx)
        if v.type == ValueType.NUMBER:
            return float(v.value)
    return 0.0


def _eval_bool_field(ctx: dict, field: Any) -> bool:
    """Evaluate an overlay bool field (expression or literal)."""
    if field is None:
        return False
    if isinstance(field, bool):
        return field
    if isinstance(field, str):
        return evaluate(field, ctx).to_bool()
    return False


def _eval_string_field(ctx: dict, field: Any) -> str:
    """Evaluate an overlay string field that may be an expression."""
    if field is None:
        return ""
    if isinstance(field, str):
        v = evaluate(field, ctx)
        if v.type == ValueType.STRING:
            return str(v.value)
        return field
    return ""


def _qcolor(rgba: tuple[float, float, float, float]):
    """Build a QColor from (r, g, b, a) in [0, 1]."""
    from PySide6.QtGui import QColor
    r, g, b, a = rgba
    return QColor(
        max(0, min(255, int(round(r * 255)))),
        max(0, min(255, int(round(g * 255)))),
        max(0, min(255, int(round(b * 255)))),
        max(0, min(255, int(round(a * 255)))),
    )


def _apply_stroke(painter, style: OverlayStyle) -> bool:
    """Configure painter's pen from style. Returns True when a
    stroke was set."""
    if style.stroke is None:
        return False
    rgba = parse_color(style.stroke)
    if rgba is None:
        return False
    from PySide6.QtCore import Qt
    from PySide6.QtGui import QPen
    pen = QPen(_qcolor(rgba))
    if style.stroke_width is not None:
        pen.setWidthF(style.stroke_width)
    else:
        pen.setWidthF(1.0)
    if style.stroke_dasharray:
        pen.setStyle(Qt.PenStyle.CustomDashLine)
        # Qt expresses dash lengths in units of line-width; convert
        # pt lengths to width-units by dividing by width.
        w = pen.widthF() or 1.0
        pen.setDashPattern([d / w for d in style.stroke_dasharray])
    painter.setPen(pen)
    return True


def _apply_fill(painter, style: OverlayStyle) -> bool:
    """Configure painter's brush from style. Returns True when a
    fill was set."""
    if style.fill is None:
        return False
    rgba = parse_color(style.fill)
    if rgba is None:
        return False
    from PySide6.QtGui import QBrush
    painter.setBrush(QBrush(_qcolor(rgba)))
    return True


def _clear_brush(painter):
    """Reset brush to transparent so later stroke() calls don't
    leave behind a fill."""
    from PySide6.QtCore import Qt
    from PySide6.QtGui import QBrush
    painter.setBrush(QBrush(Qt.BrushStyle.NoBrush))


def _clear_pen(painter):
    from PySide6.QtCore import Qt
    from PySide6.QtGui import QPen
    painter.setPen(QPen(Qt.PenStyle.NoPen))


def _rounded_rect_path(x: float, y: float, w: float, h: float,
                       rx: float, ry: float):
    """Build a QPainterPath for a rounded rectangle. Max radius
    clamped to half the shorter side."""
    from PySide6.QtCore import QRectF
    from PySide6.QtGui import QPainterPath
    r = max(0.0, min(max(rx, ry), w / 2.0, h / 2.0))
    path = QPainterPath()
    path.addRoundedRect(QRectF(x, y, w, h), r, r)
    return path


# ── Render handlers ────────────────────────────────────────


def _draw_rect_overlay(painter, render: dict, eval_ctx: dict) -> None:
    x = _eval_number_field(eval_ctx, render.get("x"))
    y = _eval_number_field(eval_ctx, render.get("y"))
    w = _eval_number_field(eval_ctx, render.get("width"))
    h = _eval_number_field(eval_ctx, render.get("height"))
    rx = _eval_number_field(eval_ctx, render.get("rx"))
    ry = _eval_number_field(eval_ctx, render.get("ry"))
    style = parse_style(render.get("style", ""))
    rounded = rx > 0.0 or ry > 0.0

    from PySide6.QtCore import QRectF

    if _apply_fill(painter, style):
        _clear_pen(painter)
        if rounded:
            painter.drawPath(_rounded_rect_path(x, y, w, h, rx, ry))
        else:
            painter.fillRect(QRectF(x, y, w, h), painter.brush())
    if _apply_stroke(painter, style):
        _clear_brush(painter)
        if rounded:
            painter.drawPath(_rounded_rect_path(x, y, w, h, rx, ry))
        else:
            painter.drawRect(QRectF(x, y, w, h))


def _draw_line_overlay(painter, render: dict, eval_ctx: dict) -> None:
    x1 = _eval_number_field(eval_ctx, render.get("x1"))
    y1 = _eval_number_field(eval_ctx, render.get("y1"))
    x2 = _eval_number_field(eval_ctx, render.get("x2"))
    y2 = _eval_number_field(eval_ctx, render.get("y2"))
    style = parse_style(render.get("style", ""))
    if _apply_stroke(painter, style):
        _clear_brush(painter)
        painter.drawLine(x1, y1, x2, y2)


def _draw_closed_polygon_from_points(painter, points, render: dict) -> None:
    """Shared closed-polygon drawing. Builds a path from ``points``,
    applies fill/stroke style."""
    if not points:
        return
    from PySide6.QtGui import QPainterPath
    style = parse_style(render.get("style", ""))
    path = QPainterPath()
    x0, y0 = points[0]
    path.moveTo(x0, y0)
    for px, py in points[1:]:
        path.lineTo(px, py)
    path.closeSubpath()

    if _apply_fill(painter, style):
        _clear_pen(painter)
        painter.drawPath(path)
    if _apply_stroke(painter, style):
        _clear_brush(painter)
        painter.drawPath(path)


def _draw_buffer_polygon_overlay(painter, render: dict) -> None:
    name = render.get("buffer") if isinstance(render.get("buffer"), str) else ""
    if not name:
        return
    points = point_buffers.points(name)
    _draw_closed_polygon_from_points(painter, points, render)


def _draw_buffer_polyline_overlay(painter, render: dict,
                                  eval_ctx: dict) -> None:
    name = render.get("buffer") if isinstance(render.get("buffer"), str) else ""
    if not name:
        return
    points = point_buffers.points(name)
    if len(points) < 2:
        return
    style = parse_style(render.get("style", ""))
    if _apply_stroke(painter, style):
        _clear_brush(painter)
        from PySide6.QtGui import QPainterPath
        path = QPainterPath()
        x0, y0 = points[0]
        path.moveTo(x0, y0)
        for px, py in points[1:]:
            path.lineTo(px, py)
        painter.drawPath(path)
    # Close-at-release hint: dashed line from last buffer point back
    # to the first when close_hint evaluates truthy.
    hint_on = _eval_bool_field(eval_ctx, render.get("close_hint"))
    if hint_on and len(points) >= 2 and style.stroke is not None:
        rgba = parse_color(style.stroke)
        if rgba is not None:
            from PySide6.QtCore import Qt
            from PySide6.QtGui import QPen
            hint_pen = QPen(_qcolor(rgba))
            hint_pen.setWidthF(1.0)
            hint_pen.setStyle(Qt.PenStyle.CustomDashLine)
            hint_pen.setDashPattern([4.0, 4.0])
            painter.setPen(hint_pen)
            _clear_brush(painter)
            sx, sy = points[0]
            ex, ey = points[-1]
            painter.drawLine(ex, ey, sx, sy)


def _draw_regular_polygon_overlay(painter, render: dict,
                                  eval_ctx: dict) -> None:
    from geometry import regular_shapes
    x1 = _eval_number_field(eval_ctx, render.get("x1"))
    y1 = _eval_number_field(eval_ctx, render.get("y1"))
    x2 = _eval_number_field(eval_ctx, render.get("x2"))
    y2 = _eval_number_field(eval_ctx, render.get("y2"))
    sides = int(_eval_number_field(eval_ctx, render.get("sides")))
    if sides <= 0:
        sides = 5
    pts = regular_shapes.regular_polygon_points(x1, y1, x2, y2, sides)
    _draw_closed_polygon_from_points(painter, pts, render)


def _draw_star_overlay(painter, render: dict, eval_ctx: dict) -> None:
    from geometry import regular_shapes
    x1 = _eval_number_field(eval_ctx, render.get("x1"))
    y1 = _eval_number_field(eval_ctx, render.get("y1"))
    x2 = _eval_number_field(eval_ctx, render.get("x2"))
    y2 = _eval_number_field(eval_ctx, render.get("y2"))
    n = int(_eval_number_field(eval_ctx, render.get("points")))
    if n <= 0:
        n = 5
    pts = regular_shapes.star_points(x1, y1, x2, y2, n)
    _draw_closed_polygon_from_points(painter, pts, render)


def _draw_partial_selection_overlay(painter, render: dict, eval_ctx: dict,
                                    document) -> None:
    """Partial Selection tool overlay: blue handle circles on every
    selected Path plus a blue rubber-band rectangle in marquee mode."""
    from PySide6.QtCore import QPointF, QRectF, Qt
    from PySide6.QtGui import QBrush, QColor, QPen
    from geometry.element import Path as PathElem
    from geometry.element import control_points, path_handle_positions

    sel_color = QColor(0, 120, 255)
    for es in document.selection:
        try:
            elem = document.get_element(es.path)
        except Exception:
            continue
        if not isinstance(elem, PathElem):
            continue
        anchors = control_points(elem)
        for ai, (ax, ay) in enumerate(anchors):
            h_in, h_out = path_handle_positions(elem.d, ai)
            for h in (h_in, h_out):
                if h is None:
                    continue
                hx, hy = h
                painter.setPen(QPen(sel_color, 1))
                _clear_brush(painter)
                painter.drawLine(ax, ay, hx, hy)
                painter.setBrush(QBrush(QColor(255, 255, 255)))
                painter.drawEllipse(QPointF(hx, hy), 3.0, 3.0)
    # Marquee rectangle.
    mode = _eval_string_field(eval_ctx, render.get("mode"))
    if mode == "marquee":
        sx = _eval_number_field(eval_ctx, render.get("marquee_start_x"))
        sy = _eval_number_field(eval_ctx, render.get("marquee_start_y"))
        cx = _eval_number_field(eval_ctx, render.get("marquee_cur_x"))
        cy = _eval_number_field(eval_ctx, render.get("marquee_cur_y"))
        rx = min(sx, cx)
        ry = min(sy, cy)
        rw = abs(cx - sx)
        rh = abs(cy - sy)
        fill_brush = QBrush(QColor(0, 120, 215, int(0.1 * 255)))
        painter.fillRect(QRectF(rx, ry, rw, rh), fill_brush)
        painter.setPen(QPen(QColor(0, 120, 215, int(0.8 * 255)), 1))
        _clear_brush(painter)
        painter.drawRect(QRectF(rx, ry, rw, rh))


def _draw_pen_overlay(painter, render: dict, eval_ctx: dict) -> None:
    """Pen tool overlay: committed Bezier curves, preview curve to
    mouse, handle lines + dots, anchor squares, close indicator."""
    from PySide6.QtCore import QPointF, QRectF, Qt
    from PySide6.QtGui import QBrush, QColor, QPainterPath, QPen

    name = render.get("buffer") if isinstance(render.get("buffer"), str) else ""
    if not name:
        return
    anchors = anchor_buffers.anchors(name)
    if not anchors:
        return
    mouse_x = _eval_number_field(eval_ctx, render.get("mouse_x"))
    mouse_y = _eval_number_field(eval_ctx, render.get("mouse_y"))
    close_radius = max(1.0, _eval_number_field(
        eval_ctx, render.get("close_radius")))
    placing = _eval_bool_field(eval_ctx, render.get("placing"))

    # 1. Committed Bezier curves between consecutive anchors.
    if len(anchors) >= 2:
        painter.setPen(QPen(QColor(0, 0, 0), 1))
        _clear_brush(painter)
        path = QPainterPath()
        path.moveTo(anchors[0].x, anchors[0].y)
        for i in range(1, len(anchors)):
            prev = anchors[i - 1]
            curr = anchors[i]
            path.cubicTo(
                prev.hx_out, prev.hy_out,
                curr.hx_in, curr.hy_in,
                curr.x, curr.y,
            )
        painter.drawPath(path)

    # 2. Preview curve from last anchor to mouse.
    if placing:
        last = anchors[-1]
        first = anchors[0]
        dx = mouse_x - first.x
        dy = mouse_y - first.y
        near_start = len(anchors) >= 2 and math.hypot(dx, dy) <= close_radius
        preview_pen = QPen(QColor(100, 100, 100), 1)
        preview_pen.setStyle(Qt.PenStyle.CustomDashLine)
        preview_pen.setDashPattern([4.0, 4.0])
        painter.setPen(preview_pen)
        _clear_brush(painter)
        path = QPainterPath()
        path.moveTo(last.x, last.y)
        if near_start:
            path.cubicTo(last.hx_out, last.hy_out,
                         first.hx_in, first.hy_in,
                         first.x, first.y)
        else:
            path.cubicTo(last.hx_out, last.hy_out,
                         mouse_x, mouse_y,
                         mouse_x, mouse_y)
        painter.drawPath(path)

    # 3. Handle lines + 4. Anchor squares.
    sel_color = QColor(0, 120, 255)
    handle_r = 3.0
    anchor_half = 5.0
    for a in anchors:
        if a.smooth:
            painter.setPen(QPen(sel_color, 1))
            _clear_brush(painter)
            painter.drawLine(a.hx_in, a.hy_in, a.hx_out, a.hy_out)
            painter.setBrush(QBrush(QColor(255, 255, 255)))
            painter.setPen(QPen(sel_color, 1))
            painter.drawEllipse(QPointF(a.hx_in, a.hy_in),
                                handle_r, handle_r)
            painter.drawEllipse(QPointF(a.hx_out, a.hy_out),
                                handle_r, handle_r)
        painter.setPen(QPen(sel_color, 1))
        painter.setBrush(QBrush(sel_color))
        painter.drawRect(QRectF(
            a.x - anchor_half, a.y - anchor_half,
            anchor_half * 2, anchor_half * 2,
        ))

    # 5. Close indicator around the first anchor when cursor is within
    # close_radius of it.
    if len(anchors) >= 2:
        first = anchors[0]
        dx = mouse_x - first.x
        dy = mouse_y - first.y
        if math.hypot(dx, dy) <= close_radius:
            painter.setPen(QPen(QColor(0, 200, 0), 2))
            _clear_brush(painter)
            painter.drawEllipse(
                QPointF(first.x, first.y),
                anchor_half + 2.0, anchor_half + 2.0,
            )


def _add_oval_path(cx: float, cy: float, rx: float, ry: float, rad: float):
    """Return a QPainterPath tracing a 24-segment rotated ellipse."""
    from PySide6.QtGui import QPainterPath
    segments = 24
    cs = math.cos(rad)
    sn = math.sin(rad)
    path = QPainterPath()
    for i in range(segments + 1):
        t = 2.0 * math.pi * i / segments
        lx = rx * math.cos(t)
        ly = ry * math.sin(t)
        x = cx + lx * cs - ly * sn
        y = cy + lx * sn + ly * cs
        if i == 0:
            path.moveTo(x, y)
        else:
            path.lineTo(x, y)
    path.closeSubpath()
    return path


def _draw_oval_cursor_overlay(painter, render: dict, eval_ctx: dict) -> None:
    """Blob Brush oval cursor + drag preview.
    BLOB_BRUSH_TOOL.md Overlay.

    Two responsibilities:
    1. Hover cursor -- oval outline at (x, y) using the effective tip
       shape (size/angle/roundness). When `dashed` is truthy, the
       stroke is dashed to signal erase mode.
    2. Drag preview -- when mode != "idle" and a buffer is named,
       each buffered pointer sample gets an ellipse. Painting mode
       fills semi-transparent; erasing mode strokes dashed outlines.
    """
    from PySide6.QtCore import QPointF, Qt
    from PySide6.QtGui import QBrush, QPen

    cx = _eval_number_field(eval_ctx, render.get("x"))
    cy = _eval_number_field(eval_ctx, render.get("y"))
    size = max(1.0, _eval_number_field(eval_ctx, render.get("default_size")))
    angle_deg = _eval_number_field(eval_ctx, render.get("default_angle"))
    roundness = max(1.0,
        _eval_number_field(eval_ctx, render.get("default_roundness")))
    stroke_color_str = (render.get("stroke_color")
                        if isinstance(render.get("stroke_color"), str) else "")
    if not stroke_color_str:
        stroke_color_str = "#000000"
    rgba = parse_color(stroke_color_str) or (0.0, 0.0, 0.0, 1.0)
    dashed = _eval_bool_field(eval_ctx, render.get("dashed"))
    # Mode may be a literal-quoted string (``"'painting'"``) or an
    # expression evaluating to a string.
    mode = "idle"
    mode_raw = render.get("mode")
    if isinstance(mode_raw, str):
        if (len(mode_raw) >= 2
            and ((mode_raw[0] == "'" and mode_raw[-1] == "'")
                 or (mode_raw[0] == '"' and mode_raw[-1] == '"'))):
            mode = mode_raw[1:-1]
        else:
            v = evaluate(mode_raw, eval_ctx)
            if v.type == ValueType.STRING:
                mode = v.value
            else:
                mode = mode_raw

    rx = size * 0.5
    ry = size * (roundness / 100.0) * 0.5
    rad = math.radians(angle_deg)

    # Drag preview: if a buffer is named and mode != idle, draw each
    # buffered sample as an oval. Painting = semi-transparent fill;
    # erasing = dashed outline.
    if mode != "idle":
        buffer_name = (render.get("buffer")
                       if isinstance(render.get("buffer"), str) else "")
        if buffer_name:
            points = point_buffers.points(buffer_name)
            if len(points) >= 2:
                if mode == "painting":
                    r, g, b, _ = rgba
                    fill_color = _qcolor((r, g, b, 0.3))
                    painter.setBrush(QBrush(fill_color))
                    painter.setPen(QPen(Qt.PenStyle.NoPen))
                    for px, py in points:
                        painter.drawPath(_add_oval_path(px, py, rx, ry, rad))
                elif mode == "erasing":
                    dash_pen = QPen(_qcolor(rgba), 1.0)
                    dash_pen.setStyle(Qt.PenStyle.CustomDashLine)
                    dash_pen.setDashPattern([3.0, 3.0])
                    painter.setPen(dash_pen)
                    _clear_brush(painter)
                    for px, py in points:
                        painter.drawPath(_add_oval_path(px, py, rx, ry, rad))

    # Hover cursor outline at (cx, cy). Dashed when Alt held.
    hover_pen = QPen(_qcolor(rgba), 1.0)
    if dashed:
        hover_pen.setStyle(Qt.PenStyle.CustomDashLine)
        hover_pen.setDashPattern([4.0, 4.0])
    painter.setPen(hover_pen)
    _clear_brush(painter)
    painter.drawPath(_add_oval_path(cx, cy, rx, ry, rad))
    # Center crosshair for precision aiming.
    crosshair_pen = QPen(_qcolor(rgba), 1.0)
    painter.setPen(crosshair_pen)
    painter.drawLine(cx - 3, cy, cx + 3, cy)
    painter.drawLine(cx, cy - 3, cx, cy + 3)


# ── Transform-tool overlays ──────────────────────────────────
#
# reference_point_cross + bbox_ghost overlays for the Scale /
# Rotate / Shear tools. See SCALE_TOOL.md §Reference-point cross
# overlay and §Overlay.

def _resolve_overlay_ref_point(render: dict, eval_ctx: dict, document):
    """Resolve the reference-point coordinate. Reads the ref_point
    field (typically the expression state.transform_reference_point)
    — when it's a list of two numbers, returns those. Otherwise
    falls back to the selection union bbox center. Returns None
    when there is no selection (overlay hides)."""
    from algorithms.align import union_bounds, geometric_bounds
    expr = render.get("ref_point")
    if isinstance(expr, str):
        v = evaluate(expr, eval_ctx)
        try:
            if v.type == ValueType.LIST and len(v.value) >= 2:
                rx = float(v.value[0])
                ry = float(v.value[1])
                return (rx, ry)
        except (TypeError, ValueError):
            pass
    if document is None:
        return None
    elements = []
    for es in document.selection:
        try:
            elements.append(document.get_element(es.path))
        except Exception:
            pass
    if not elements:
        return None
    x, y, w, h = union_bounds(elements, geometric_bounds)
    return (x + w / 2, y + h / 2)


def _draw_reference_point_cross(painter, render: dict,
                                eval_ctx: dict, document) -> None:
    """Cyan-blue 12 px crosshair + 2 px center dot at the
    reference point. Hidden when there is no selection. See
    SCALE_TOOL.md §Reference-point cross overlay."""
    from PySide6.QtCore import QPointF
    from PySide6.QtGui import QColor, QPen
    pt = _resolve_overlay_ref_point(render, eval_ctx, document)
    if pt is None:
        return None
    rx, ry = pt
    color = QColor(0x4A, 0x9E, 0xFF)
    pen = QPen(color, 1.0)
    painter.setPen(pen)
    _clear_brush(painter)
    arm = 6.0
    painter.drawLine(rx - arm, ry, rx + arm, ry)
    painter.drawLine(rx, ry - arm, rx, ry + arm)
    painter.setBrush(color)
    painter.drawEllipse(QPointF(rx, ry), 2.0, 2.0)


def _draw_bbox_ghost(painter, render: dict,
                     eval_ctx: dict, document) -> None:
    """Dashed cyan-blue parallelogram tracking the selection's
    post-transform bounding box during a drag. Builds the matrix
    from (transform_kind, press, cursor, ref, shift_held) using
    jas.algorithms.transform_apply, mirroring the effect-side
    apply logic but without document mutation."""
    from PySide6.QtCore import Qt, QPointF
    from PySide6.QtGui import QColor, QPen, QPolygonF
    from algorithms.align import union_bounds, geometric_bounds
    from jas.algorithms.transform_apply import (
        scale_matrix, rotate_matrix, shear_matrix)
    from jas.geometry.element import Transform
    import math
    pt = _resolve_overlay_ref_point(render, eval_ctx, document)
    if pt is None:
        return None
    rx, ry = pt
    kind_expr = render.get("transform_kind", "''")
    kind = ""
    if isinstance(kind_expr, str):
        v = evaluate(kind_expr, eval_ctx)
        if v.type == ValueType.STRING:
            kind = v.value
    px = _eval_number_field(eval_ctx, render.get("press_x"))
    py = _eval_number_field(eval_ctx, render.get("press_y"))
    cx = _eval_number_field(eval_ctx, render.get("cursor_x"))
    cy = _eval_number_field(eval_ctx, render.get("cursor_y"))
    shift = _eval_bool_field(eval_ctx, render.get("shift_held"))
    if kind == "scale":
        denom_x = px - rx
        denom_y = py - ry
        sx = 1.0 if abs(denom_x) < 1e-9 else (cx - rx) / denom_x
        sy = 1.0 if abs(denom_y) < 1e-9 else (cy - ry) / denom_y
        if shift:
            prod = sx * sy
            sign = 1.0 if prod >= 0 else -1.0
            s = sign * (abs(prod) ** 0.5)
            sx, sy = s, s
        matrix = scale_matrix(sx, sy, rx, ry)
    elif kind == "rotate":
        tp = math.atan2(py - ry, px - rx)
        tc = math.atan2(cy - ry, cx - rx)
        theta_deg = math.degrees(tc - tp)
        if shift:
            theta_deg = round(theta_deg / 45.0) * 45.0
        matrix = rotate_matrix(theta_deg, rx, ry)
    elif kind == "shear":
        dx = cx - px
        dy = cy - py
        if shift:
            if abs(dx) >= abs(dy):
                denom = max(abs(py - ry), 1e-9)
                k = dx / denom
                matrix = shear_matrix(
                    math.degrees(math.atan(k)), "horizontal", 0.0, rx, ry)
            else:
                denom = max(abs(px - rx), 1e-9)
                k = dy / denom
                matrix = shear_matrix(
                    math.degrees(math.atan(k)), "vertical", 0.0, rx, ry)
        else:
            ax = px - rx
            ay = py - ry
            axis_len = max((ax * ax + ay * ay) ** 0.5, 1e-9)
            perp_x = -ay / axis_len
            perp_y = ax / axis_len
            perp_dist = (cx - px) * perp_x + (cy - py) * perp_y
            k = perp_dist / axis_len
            axis_angle_deg = math.degrees(math.atan2(ay, ax))
            matrix = shear_matrix(
                math.degrees(math.atan(k)), "custom", axis_angle_deg, rx, ry)
    else:
        matrix = Transform()
    if document is None:
        return None
    elements = []
    for es in document.selection:
        try:
            elements.append(document.get_element(es.path))
        except Exception:
            pass
    if not elements:
        return None
    bx, by, bw, bh = union_bounds(elements, geometric_bounds)
    corners = [
        matrix.apply_point(bx,        by),
        matrix.apply_point(bx + bw,   by),
        matrix.apply_point(bx + bw,   by + bh),
        matrix.apply_point(bx,        by + bh),
    ]
    color = QColor(0x4A, 0x9E, 0xFF)
    pen = QPen(color, 1.0)
    pen.setStyle(Qt.PenStyle.CustomDashLine)
    pen.setDashPattern([4.0, 2.0])
    painter.setPen(pen)
    _clear_brush(painter)
    poly = QPolygonF([QPointF(c[0], c[1]) for c in corners])
    painter.drawPolygon(poly)
