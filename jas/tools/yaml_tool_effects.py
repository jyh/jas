"""YAML tool-runtime effects — the ``platform_effects`` dict that
``YamlTool`` (Phase 5) registers before dispatching a tool handler.
Mirrors the ``doc.*`` dispatcher in the Rust / Swift / OCaml ports.

Phase 2 of the Python migration covers the selection-family effects
that only depend on existing :class:`Controller` methods. Later
phases add ``doc.add_element``, the ``buffer.*`` / ``anchor.*``
effects, and the ``doc.path.*`` suite as their supporting
infrastructure lands.
"""

from __future__ import annotations

from typing import Any, Callable, Sequence

from algorithms.fit_curve import fit_curve
from document.controller import Controller
from document.document import (
    Document,
    ElementPath,
    ElementSelection,
    Selection,
    selection_kind_contains,
    selection_kind_to_sorted,
)
from geometry import path_ops, regular_shapes
from geometry.element import (
    ClosePath,
    Color,
    CurveTo,
    Element,
    Fill,
    Group,
    Layer,
    Line,
    LineTo,
    MoveTo,
    Path as PathElem,
    Polygon,
    Rect as RectElem,
    Stroke,
    control_point_count,
    control_points,
    convert_corner_to_smooth,
    convert_smooth_to_corner,
    flatten_path_commands,
    is_smooth_point,
    move_path_handle_independent,
    path_handle_positions,
)
from workspace_interpreter import anchor_buffers, point_buffers
from workspace_interpreter.expr import evaluate
from workspace_interpreter.expr_types import Value, ValueType
from workspace_interpreter.state_store import StateStore

PlatformEffect = Callable[[Any, dict, StateStore], Any]


def eval_number(arg: Any, store: StateStore, ctx: dict) -> float:
    """Evaluate a JSON number field — literal or string expression.
    Missing / unparseable falls back to 0.0."""
    if arg is None:
        return 0.0
    if isinstance(arg, bool):
        return float(arg)
    if isinstance(arg, (int, float)):
        return float(arg)
    if isinstance(arg, str):
        eval_ctx = store.eval_context(ctx)
        result = evaluate(arg, eval_ctx)
        if result.type == ValueType.NUMBER:
            return float(result.value)
    return 0.0


def eval_bool(arg: Any, store: StateStore, ctx: dict) -> bool:
    """Evaluate a JSON bool field — literal or string expression."""
    if arg is None:
        return False
    if isinstance(arg, bool):
        return arg
    if isinstance(arg, str):
        eval_ctx = store.eval_context(ctx)
        result = evaluate(arg, eval_ctx)
        if result.type == ValueType.BOOL:
            return bool(result.value)
    return False


def extract_path(spec: Any, store: StateStore, ctx: dict) -> ElementPath | None:
    """Pull a single :class:`ElementPath` out of a ``doc.*`` spec.
    Accepts:
      - a raw list of ints ``[0, 0]``
      - a ``{"__path__": [...]}`` marker dict
      - a ``{"path": <spec>}`` dict (recurses)
      - a string expression that evaluates to ``Value.PATH`` or list.
    Returns ``None`` when the spec doesn't resolve to a valid path.
    """
    if isinstance(spec, list):
        out: list[int] = []
        for item in spec:
            if isinstance(item, bool) or not isinstance(item, (int, float)):
                return None
            out.append(int(item))
        return out
    if isinstance(spec, dict):
        if "__path__" in spec:
            arr = spec["__path__"]
            if not isinstance(arr, list):
                return None
            out = []
            for item in arr:
                if isinstance(item, bool) or not isinstance(item, (int, float)):
                    return None
                out.append(int(item))
            return out
        if "path" in spec:
            return extract_path(spec["path"], store, ctx)
        return None
    if isinstance(spec, str):
        eval_ctx = store.eval_context(ctx)
        result = evaluate(spec, eval_ctx)
        if result.type == ValueType.PATH:
            return list(result.value)
        if result.type == ValueType.LIST:
            out = []
            for item in result.value:
                if isinstance(item, Value) and item.type == ValueType.NUMBER:
                    out.append(int(item.value))
                elif isinstance(item, (int, float)) and not isinstance(item, bool):
                    out.append(int(item))
                else:
                    return None
            return out
    return None


def extract_path_list(
    spec: Any, store: StateStore, ctx: dict
) -> list[ElementPath]:
    """Pull a list of paths out of a ``{paths: [...]}`` spec."""
    if not isinstance(spec, dict):
        return []
    paths = spec.get("paths")
    if not isinstance(paths, list):
        return []
    out: list[ElementPath] = []
    for item in paths:
        p = extract_path(item, store, ctx)
        if p is not None:
            out.append(p)
    return out


def is_valid_path(doc: Document, path: ElementPath) -> bool:
    """True when ``path`` references an existing element in ``doc``."""
    try:
        doc.get_element(path)
        return True
    except Exception:
        return False


def normalize_rect_args(
    args: dict, store: StateStore, ctx: dict
) -> tuple[float, float, float, float, bool]:
    """Normalize ``{x1, y1, x2, y2, additive}`` to
    ``(x, y, w, h, additive)`` with the min corner + absolute sides."""
    x1 = eval_number(args.get("x1"), store, ctx)
    y1 = eval_number(args.get("y1"), store, ctx)
    x2 = eval_number(args.get("x2"), store, ctx)
    y2 = eval_number(args.get("y2"), store, ctx)
    additive = eval_bool(args.get("additive"), store, ctx)
    return (
        min(x1, x2), min(y1, y2),
        abs(x2 - x1), abs(y2 - y1),
        additive,
    )


def build(controller: Controller) -> dict[str, PlatformEffect]:
    """Build the ``platform_effects`` map that :class:`YamlTool` hands
    to :func:`workspace_interpreter.effects.run_effects` on each
    dispatch. Captures ``controller`` so mutations land on its Model.
    """
    effects: dict[str, PlatformEffect] = {}

    def doc_snapshot(_spec, _ctx, _store):
        controller.model.snapshot()
        return None

    def doc_clear_selection(_spec, _ctx, _store):
        controller.set_selection(frozenset())
        return None

    def doc_set_selection(spec, ctx, store):
        paths = extract_path_list(spec, store, ctx)
        doc = controller.document
        valid = [
            ElementSelection.all(tuple(p))
            for p in paths
            if is_valid_path(doc, tuple(p))
        ]
        controller.set_selection(frozenset(valid))
        return None

    def doc_add_to_selection(spec, ctx, store):
        path = extract_path(spec, store, ctx)
        if path is None:
            return None
        path = tuple(path)
        sel = set(controller.document.selection)
        if any(es.path == path for es in sel):
            return None
        sel.add(ElementSelection.all(path))
        controller.set_selection(frozenset(sel))
        return None

    def doc_toggle_selection(spec, ctx, store):
        path = extract_path(spec, store, ctx)
        if path is None:
            return None
        path = tuple(path)
        sel = set(controller.document.selection)
        existing = next((es for es in sel if es.path == path), None)
        if existing is not None:
            sel.discard(existing)
        else:
            sel.add(ElementSelection.all(path))
        controller.set_selection(frozenset(sel))
        return None

    def doc_translate_selection(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        dx = eval_number(spec.get("dx"), store, ctx)
        dy = eval_number(spec.get("dy"), store, ctx)
        if dx == 0.0 and dy == 0.0:
            return None
        controller.move_selection(dx, dy)
        return None

    # ── brush.* library mutation helpers ─────────────────

    def _eval_string_value(arg, store, ctx) -> str:
        if arg is None:
            return ""
        if isinstance(arg, str):
            v = _eval_value(arg, store, ctx)
            if v.type == ValueType.STRING:
                return v.value
        return ""

    def _eval_string_list(arg, store, ctx) -> list[str]:
        if isinstance(arg, list):
            return [s for s in arg if isinstance(s, str)]
        if isinstance(arg, str):
            v = _eval_value(arg, store, ctx)
            if v.type == ValueType.LIST:
                return [s for s in v.value if isinstance(s, str)]
        return []

    def _resolve_value_or_expr(arg, store, ctx):
        if arg is None:
            return None
        if isinstance(arg, str):
            v = _eval_value(arg, store, ctx)
            return v.to_python() if hasattr(v, 'to_python') else v.value
        return arg

    def _sync_canvas_brushes(store):
        """Push the current data.brush_libraries into the canvas
        renderer's brush registry so the next paint sees the
        update."""
        try:
            from canvas.canvas import set_canvas_brush_libraries
            libs = store.get_data_path("brush_libraries") or {}
            set_canvas_brush_libraries(libs)
        except Exception:
            # Ran outside the canvas context (e.g. tests).
            pass

    def _library_brushes_path(lib_id):
        return f"brush_libraries.{lib_id}.brushes"

    def _brush_filter_library_by_slug(store, lib_id, slugs):
        path = _library_brushes_path(lib_id)
        brushes = store.get_data_path(path)
        if not isinstance(brushes, list):
            return
        slug_set = set(slugs)
        next_brushes = [b for b in brushes
                        if not (isinstance(b, dict) and b.get("slug") in slug_set)]
        store.set_data_path(path, next_brushes)

    def _brush_duplicate_in_library(store, lib_id, slugs):
        path = _library_brushes_path(lib_id)
        brushes = store.get_data_path(path)
        if not isinstance(brushes, list):
            return []
        existing = {b.get("slug") for b in brushes if isinstance(b, dict)}
        new_slugs = []
        next_brushes = []
        for b in brushes:
            next_brushes.append(b)
            if not isinstance(b, dict):
                continue
            slug = b.get("slug")
            if slug not in slugs:
                continue
            new_slug = f"{slug}_copy"
            n = 2
            while new_slug in existing:
                new_slug = f"{slug}_copy_{n}"
                n += 1
            existing.add(new_slug)
            copy = dict(b)
            name = b.get("name", "Brush")
            copy["name"] = f"{name} copy"
            copy["slug"] = new_slug
            new_slugs.append(new_slug)
            next_brushes.append(copy)
        store.set_data_path(path, next_brushes)
        return new_slugs

    def _brush_append_to_library(store, lib_id, brush):
        path = _library_brushes_path(lib_id)
        brushes = store.get_data_path(path)
        if not isinstance(brushes, list):
            brushes = []
        brushes = list(brushes) + [brush]
        store.set_data_path(path, brushes)

    def _brush_update_in_library(store, lib_id, slug, patch):
        path = _library_brushes_path(lib_id)
        brushes = store.get_data_path(path)
        if not isinstance(brushes, list):
            return
        next_brushes = []
        for b in brushes:
            if isinstance(b, dict) and b.get("slug") == slug:
                merged = dict(b)
                merged.update(patch)
                next_brushes.append(merged)
            else:
                next_brushes.append(b)
        store.set_data_path(path, next_brushes)

    def brush_delete_selected(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        lib_id = _eval_string_value(spec.get("library"), store, ctx)
        slugs = _eval_string_list(spec.get("slugs"), store, ctx)
        if not lib_id or not slugs:
            return None
        _brush_filter_library_by_slug(store, lib_id, slugs)
        store.set_panel("brushes", "selected_brushes", [])
        _sync_canvas_brushes(store)
        return None

    def brush_duplicate_selected(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        lib_id = _eval_string_value(spec.get("library"), store, ctx)
        slugs = _eval_string_list(spec.get("slugs"), store, ctx)
        if not lib_id or not slugs:
            return None
        new_slugs = _brush_duplicate_in_library(store, lib_id, slugs)
        store.set_panel("brushes", "selected_brushes", new_slugs)
        _sync_canvas_brushes(store)
        return None

    def brush_append(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        lib_id = _eval_string_value(spec.get("library"), store, ctx)
        if not lib_id:
            return None
        brush = _resolve_value_or_expr(spec.get("brush"), store, ctx)
        if isinstance(brush, dict):
            _brush_append_to_library(store, lib_id, brush)
            _sync_canvas_brushes(store)
        return None

    def brush_update(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        lib_id = _eval_string_value(spec.get("library"), store, ctx)
        slug = _eval_string_value(spec.get("slug"), store, ctx)
        if not lib_id or not slug:
            return None
        patch = _resolve_value_or_expr(spec.get("patch"), store, ctx)
        if isinstance(patch, dict):
            _brush_update_in_library(store, lib_id, slug, patch)
            _sync_canvas_brushes(store)
        return None

    def doc_set_attr_on_selection(spec, ctx, store):
        """Phase 1 supports brush attributes only; other attrs ignored.
        Used by apply_brush_to_selection / remove_brush_from_selection.
        Mirrors the JS Phase 1.8 effect."""
        if not isinstance(spec, dict):
            return None
        attr = spec.get("attr")
        if not isinstance(attr, str) or not attr:
            return None
        value = None
        raw = spec.get("value")
        if raw is not None:
            v = _eval_value(raw, store, ctx)
            if v.type == ValueType.STRING and v.value:
                value = v.value
        if attr == "stroke_brush":
            controller.set_selection_stroke_brush(value)
        elif attr == "stroke_brush_overrides":
            controller.set_selection_stroke_brush_overrides(value)
        # Phase 1: other attrs ignored
        return None

    def doc_copy_selection(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        dx = eval_number(spec.get("dx"), store, ctx)
        dy = eval_number(spec.get("dy"), store, ctx)
        controller.copy_selection(dx, dy)
        return None

    def doc_select_in_rect(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        rx, ry, rw, rh, additive = normalize_rect_args(spec, store, ctx)
        controller.select_rect(rx, ry, rw, rh, extend=additive)
        return None

    def doc_partial_select_in_rect(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        rx, ry, rw, rh, additive = normalize_rect_args(spec, store, ctx)
        controller.partial_select_rect(rx, ry, rw, rh, extend=additive)
        return None

    # ── Buffer effects (Phase 3) ─────────────────────────────

    def buffer_push(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        name = spec.get("buffer")
        if not isinstance(name, str):
            return None
        x = eval_number(spec.get("x"), store, ctx)
        y = eval_number(spec.get("y"), store, ctx)
        point_buffers.push(name, x, y)
        return None

    def buffer_clear(spec, _ctx, _store):
        if not isinstance(spec, dict):
            return None
        name = spec.get("buffer")
        if isinstance(name, str):
            point_buffers.clear(name)
        return None

    def anchor_push(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        name = spec.get("buffer")
        if not isinstance(name, str):
            return None
        x = eval_number(spec.get("x"), store, ctx)
        y = eval_number(spec.get("y"), store, ctx)
        anchor_buffers.push(name, x, y)
        return None

    def anchor_set_last_out(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        name = spec.get("buffer")
        if not isinstance(name, str):
            return None
        hx = eval_number(spec.get("hx"), store, ctx)
        hy = eval_number(spec.get("hy"), store, ctx)
        anchor_buffers.set_last_out_handle(name, hx, hy)
        return None

    def anchor_pop(spec, _ctx, _store):
        if not isinstance(spec, dict):
            return None
        name = spec.get("buffer")
        if isinstance(name, str):
            anchor_buffers.pop(name)
        return None

    def anchor_clear(spec, _ctx, _store):
        if not isinstance(spec, dict):
            return None
        name = spec.get("buffer")
        if isinstance(name, str):
            anchor_buffers.clear(name)
        return None

    def doc_select_polygon_from_buffer(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        name = spec.get("buffer")
        if not isinstance(name, str):
            return None
        additive = eval_bool(spec.get("additive"), store, ctx)
        pts = point_buffers.points(name)
        if len(pts) >= 3:
            controller.select_polygon(pts, extend=additive)
        return None

    # ── Phase 4b: element + path-editing helpers ────────────

    def _eval_value(arg, s, c) -> Value:
        """Evaluate a value-returning field — string expr or raw value."""
        if arg is None:
            return Value.null()
        if isinstance(arg, str):
            return evaluate(arg, s.eval_context(c))
        return Value.from_python(arg)

    def _resolve_fill(arg, has_key, default_fill, s, c):
        if not has_key:
            return default_fill
        v = _eval_value(arg, s, c)
        if v.type == ValueType.NULL:
            return None
        if v.type in (ValueType.COLOR, ValueType.STRING):
            try:
                return Fill(color=Color.from_hex(v.value))
            except Exception:
                return default_fill
        return default_fill

    def _resolve_stroke(arg, has_key, default_stroke, s, c):
        if not has_key:
            return default_stroke
        v = _eval_value(arg, s, c)
        if v.type == ValueType.NULL:
            return None
        if v.type in (ValueType.COLOR, ValueType.STRING):
            try:
                return Stroke(color=Color.from_hex(v.value), width=1.0)
            except Exception:
                return default_stroke
        return default_stroke

    def _build_element(spec, s, c):
        if not isinstance(spec, dict):
            return None
        type_ = spec.get("type")
        if not isinstance(type_, str):
            return None
        has_fill = "fill" in spec
        has_stroke = "stroke" in spec
        # Model default fill/stroke — using StateStore-style constants.
        default_fill = getattr(controller.model, "default_fill", None)
        default_stroke = getattr(controller.model, "default_stroke", None)
        fill = _resolve_fill(spec.get("fill"), has_fill, default_fill, s, c)
        stroke = _resolve_stroke(spec.get("stroke"), has_stroke, default_stroke, s, c)
        if type_ == "rect":
            return RectElem(
                x=eval_number(spec.get("x"), s, c),
                y=eval_number(spec.get("y"), s, c),
                width=eval_number(spec.get("width"), s, c),
                height=eval_number(spec.get("height"), s, c),
                rx=eval_number(spec.get("rx"), s, c),
                ry=eval_number(spec.get("ry"), s, c),
                fill=fill, stroke=stroke,
            )
        if type_ == "line":
            return Line(
                x1=eval_number(spec.get("x1"), s, c),
                y1=eval_number(spec.get("y1"), s, c),
                x2=eval_number(spec.get("x2"), s, c),
                y2=eval_number(spec.get("y2"), s, c),
                stroke=stroke,
            )
        if type_ == "polygon":
            x1 = eval_number(spec.get("x1"), s, c)
            y1 = eval_number(spec.get("y1"), s, c)
            x2 = eval_number(spec.get("x2"), s, c)
            y2 = eval_number(spec.get("y2"), s, c)
            sides_raw = int(eval_number(spec.get("sides"), s, c))
            sides = sides_raw if sides_raw > 0 else 5
            pts = regular_shapes.regular_polygon_points(x1, y1, x2, y2, sides)
            return Polygon(points=tuple(pts), fill=fill, stroke=stroke)
        if type_ == "star":
            x1 = eval_number(spec.get("x1"), s, c)
            y1 = eval_number(spec.get("y1"), s, c)
            x2 = eval_number(spec.get("x2"), s, c)
            y2 = eval_number(spec.get("y2"), s, c)
            raw = int(eval_number(spec.get("points"), s, c))
            n = raw if raw > 0 else 5
            pts = regular_shapes.star_points(x1, y1, x2, y2, n)
            return Polygon(points=tuple(pts), fill=fill, stroke=stroke)
        return None

    def _path_with_commands(pe: PathElem, cmds) -> PathElem:
        return PathElem(
            d=tuple(cmds),
            fill=pe.fill, stroke=pe.stroke,
            width_points=pe.width_points,
            opacity=pe.opacity, transform=pe.transform,
            locked=pe.locked,
            visibility=pe.visibility, blend_mode=pe.blend_mode,
            mask=pe.mask,
            fill_gradient=pe.fill_gradient,
            stroke_gradient=pe.stroke_gradient,
        )

    def doc_add_element(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        elem_spec = spec.get("element")
        if elem_spec is None:
            return None
        elem = _build_element(elem_spec, store, ctx)
        if elem is not None:
            controller.add_element(elem)
        return None

    def _make_path_from_commands(cmds, spec, ctx, store) -> PathElem:
        has_fill = isinstance(spec, dict) and "fill" in spec
        has_stroke = isinstance(spec, dict) and "stroke" in spec
        default_fill = getattr(controller.model, "default_fill", None)
        default_stroke = getattr(controller.model, "default_stroke", None)
        fill = _resolve_fill(
            spec.get("fill") if isinstance(spec, dict) else None,
            has_fill, default_fill, store, ctx)
        stroke = _resolve_stroke(
            spec.get("stroke") if isinstance(spec, dict) else None,
            has_stroke, default_stroke, store, ctx)
        # Optional stroke_brush passthrough — Paintbrush tool's
        # on_mouseup passes "state.stroke_brush" so the active brush
        # rides along onto the new path. Renderer dispatch consumes
        # it via the calligraphic outliner. Mirrors the JS / Rust /
        # Swift / OCaml passthroughs.
        stroke_brush = None
        if isinstance(spec, dict) and "stroke_brush" in spec:
            sb_raw = spec.get("stroke_brush")
            if sb_raw is not None:
                sb_val = _eval_value(sb_raw, store, ctx)
                if sb_val.type == ValueType.STRING and sb_val.value:
                    stroke_brush = sb_val.value
        return PathElem(d=tuple(cmds), fill=fill, stroke=stroke,
                        stroke_brush=stroke_brush)

    def doc_add_path_from_buffer(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        name = spec.get("buffer")
        if not isinstance(name, str):
            return None
        raw = eval_number(spec.get("fit_error"), store, ctx) \
            if "fit_error" in spec else 4.0
        fit_error = raw if raw != 0.0 else 4.0
        pts = point_buffers.points(name)
        if len(pts) < 2:
            return None
        segments = fit_curve(pts, fit_error)
        if not segments:
            return None
        cmds = [MoveTo(segments[0][0], segments[0][1])]
        for seg in segments:
            # seg = (p1x, p1y, c1x, c1y, c2x, c2y, p2x, p2y)
            cmds.append(CurveTo(x1=seg[2], y1=seg[3],
                                x2=seg[4], y2=seg[5],
                                x=seg[6], y=seg[7]))
        elem = _make_path_from_commands(cmds, spec, ctx, store)
        controller.add_element(elem)
        return None

    def doc_add_path_from_anchor_buffer(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        name = spec.get("buffer")
        if not isinstance(name, str):
            return None
        closed = eval_bool(spec.get("closed"), store, ctx)
        anchors = anchor_buffers.anchors(name)
        if len(anchors) < 2:
            return None
        cmds = [MoveTo(anchors[0].x, anchors[0].y)]
        for i in range(1, len(anchors)):
            prev = anchors[i - 1]
            curr = anchors[i]
            cmds.append(CurveTo(
                x1=prev.hx_out, y1=prev.hy_out,
                x2=curr.hx_in, y2=curr.hy_in,
                x=curr.x, y=curr.y,
            ))
        if closed:
            last = anchors[-1]
            first = anchors[0]
            cmds.append(CurveTo(
                x1=last.hx_out, y1=last.hy_out,
                x2=first.hx_in, y2=first.hy_in,
                x=first.x, y=first.y,
            ))
            cmds.append(ClosePath())
        elem = _make_path_from_commands(cmds, spec, ctx, store)
        controller.add_element(elem)
        return None

    def _anchor_index_near(cmds, x, y, radius):
        for i, cmd in enumerate(cmds):
            if isinstance(cmd, (MoveTo, LineTo)):
                pt = (cmd.x, cmd.y)
            elif isinstance(cmd, CurveTo):
                pt = (cmd.x, cmd.y)
            else:
                continue
            dx = x - pt[0]
            dy = y - pt[1]
            if (dx * dx + dy * dy) ** 0.5 <= radius:
                return i
        return None

    def _find_path_anchor_near(doc, x, y, radius):
        for li, layer in enumerate(doc.layers):
            children = getattr(layer, "children", ())
            for ci, child in enumerate(children):
                if isinstance(child, PathElem) and not child.locked:
                    idx = _anchor_index_near(child.d, x, y, radius)
                    if idx is not None:
                        return ((li, ci), idx)
                if isinstance(child, Group) and not child.locked:
                    for gi, g in enumerate(child.children):
                        if isinstance(g, PathElem) and not g.locked:
                            idx = _anchor_index_near(g.d, x, y, radius)
                            if idx is not None:
                                return ((li, ci, gi), idx)
        return None

    def doc_path_delete_anchor_near(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        x = eval_number(spec.get("x"), store, ctx)
        y = eval_number(spec.get("y"), store, ctx)
        raw = eval_number(spec.get("hit_radius"), store, ctx)
        radius = raw if raw != 0.0 else 8.0
        hit = _find_path_anchor_near(controller.document, x, y, radius)
        if hit is None:
            return None
        path, anchor_idx = hit
        elem = controller.document.get_element(path)
        if not isinstance(elem, PathElem):
            return None
        controller.model.snapshot()
        new_cmds = path_ops.delete_anchor_from_path(elem.d, anchor_idx)
        if new_cmds is not None:
            new_elem = _path_with_commands(elem, new_cmds)
            doc = controller.document.replace_element(path, new_elem)
            # Keep path in selection (matches native Delete-anchor).
            sel = {es for es in doc.selection if es.path != path}
            sel.add(ElementSelection.all(path))
            import dataclasses
            controller.set_document(dataclasses.replace(doc, selection=frozenset(sel)))
        else:
            controller.set_document(controller.document.delete_element(path))
        return None

    def _projection_distance(cmds, seg_idx, x, y):
        cx = 0.0
        cy = 0.0
        for i, cmd in enumerate(cmds):
            if isinstance(cmd, MoveTo):
                cx, cy = cmd.x, cmd.y
            elif isinstance(cmd, LineTo):
                if i == seg_idx:
                    d, _ = path_ops.closest_on_line(cx, cy, cmd.x, cmd.y, x, y)
                    return d
                cx, cy = cmd.x, cmd.y
            elif isinstance(cmd, CurveTo):
                if i == seg_idx:
                    d, _ = path_ops.closest_on_cubic(
                        cx, cy, cmd.x1, cmd.y1, cmd.x2, cmd.y2,
                        cmd.x, cmd.y, x, y)
                    return d
                cx, cy = cmd.x, cmd.y
        return float("inf")

    def doc_path_insert_anchor_on_segment_near(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        x = eval_number(spec.get("x"), store, ctx)
        y = eval_number(spec.get("y"), store, ctx)
        raw = eval_number(spec.get("hit_radius"), store, ctx)
        radius = raw if raw != 0.0 else 8.0
        best = None

        def try_path(d, path):
            nonlocal best
            r = path_ops.closest_segment_and_t(d, x, y)
            if r is None:
                return
            seg_idx, t = r
            dist = _projection_distance(d, seg_idx, x, y)
            if best is None or dist < best[3]:
                best = (path, seg_idx, t, dist)

        doc = controller.document
        for li, layer in enumerate(doc.layers):
            children = getattr(layer, "children", ())
            for ci, child in enumerate(children):
                if isinstance(child, PathElem) and not child.locked:
                    try_path(child.d, (li, ci))
                if isinstance(child, Group) and not child.locked:
                    for gi, g in enumerate(child.children):
                        if isinstance(g, PathElem) and not g.locked:
                            try_path(g.d, (li, ci, gi))
        if best is None or best[3] > radius:
            return None
        path, seg_idx, t, _ = best
        elem = doc.get_element(path)
        if not isinstance(elem, PathElem):
            return None
        controller.model.snapshot()
        ins = path_ops.insert_point_in_path(elem.d, seg_idx, t)
        new_elem = _path_with_commands(elem, ins.commands)
        controller.set_document(doc.replace_element(path, new_elem))
        return None

    def doc_path_erase_at_rect(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        last_x = eval_number(spec.get("last_x"), store, ctx)
        last_y = eval_number(spec.get("last_y"), store, ctx)
        x = eval_number(spec.get("x"), store, ctx)
        y = eval_number(spec.get("y"), store, ctx)
        raw = eval_number(spec.get("eraser_size"), store, ctx)
        eraser_size = raw if raw != 0.0 else 2.0
        min_x = min(last_x, x) - eraser_size
        min_y = min(last_y, y) - eraser_size
        max_x = max(last_x, x) + eraser_size
        max_y = max(last_y, y) + eraser_size

        import dataclasses
        doc = controller.document
        layers = list(doc.layers)
        changed = False
        for li, layer in enumerate(layers):
            if not isinstance(layer, Layer):
                continue
            new_children: list[Element] = []
            layer_changed = False
            for child in layer.children:
                if isinstance(child, PathElem) and not child.locked:
                    flat = flatten_path_commands(child.d)
                    if len(flat) < 2:
                        new_children.append(child)
                        continue
                    hit = path_ops.find_eraser_hit(
                        flat, min_x, min_y, max_x, max_y)
                    if hit is None:
                        new_children.append(child)
                        continue
                    bx, by, bw, bh = child.bounds()
                    if bw <= eraser_size * 2 and bh <= eraser_size * 2:
                        layer_changed = True
                        continue  # delete entirely
                    is_closed = any(isinstance(c, ClosePath) for c in child.d)
                    results = path_ops.split_path_at_eraser(child.d, hit, is_closed)
                    for cmds in results:
                        if len(cmds) >= 2:
                            open_cmds = [c for c in cmds if not isinstance(c, ClosePath)]
                            new_children.append(_path_with_commands(child, open_cmds))
                    layer_changed = True
                else:
                    new_children.append(child)
            if layer_changed:
                layers[li] = dataclasses.replace(layer, children=tuple(new_children))
                changed = True
        if changed:
            new_doc = dataclasses.replace(doc, layers=tuple(layers),
                                          selection=frozenset())
            controller.set_document(new_doc)
        return None

    def doc_path_smooth_at_cursor(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        x = eval_number(spec.get("x"), store, ctx)
        y = eval_number(spec.get("y"), store, ctx)
        raw_r = eval_number(spec.get("radius"), store, ctx)
        radius = raw_r if raw_r != 0.0 else 100.0
        raw_e = eval_number(spec.get("fit_error"), store, ctx)
        fit_error = raw_e if raw_e != 0.0 else 8.0
        r2 = radius * radius

        doc = controller.document
        changed = False
        for es in list(doc.selection):
            path = es.path
            try:
                elem = doc.get_element(path)
            except Exception:
                continue
            if not isinstance(elem, PathElem) or elem.locked:
                continue
            if len(elem.d) < 2:
                continue
            flat, cmap = path_ops.flatten_with_cmd_map(elem.d)
            if len(flat) < 2:
                continue
            first_hit = last_hit = None
            for i, (px, py) in enumerate(flat):
                dx = px - x
                dy = py - y
                if dx * dx + dy * dy <= r2:
                    if first_hit is None:
                        first_hit = i
                    last_hit = i
            if first_hit is None or last_hit is None:
                continue
            first_cmd = cmap[first_hit]
            last_cmd = cmap[last_hit]
            if first_cmd >= last_cmd:
                continue
            range_flat = [pt for i, pt in enumerate(flat)
                          if first_cmd <= cmap[i] <= last_cmd]
            start_pt = path_ops.cmd_start_point(elem.d, first_cmd)
            points_to_fit = [start_pt] + range_flat
            if len(points_to_fit) < 2:
                continue
            segments = fit_curve(points_to_fit, fit_error)
            if not segments:
                continue
            new_cmds = list(elem.d[:first_cmd])
            for seg in segments:
                new_cmds.append(CurveTo(x1=seg[2], y1=seg[3],
                                        x2=seg[4], y2=seg[5],
                                        x=seg[6], y=seg[7]))
            new_cmds.extend(elem.d[last_cmd + 1:])
            if len(new_cmds) >= len(elem.d):
                continue
            doc = doc.replace_element(path, _path_with_commands(elem, new_cmds))
            changed = True
        if changed:
            controller.set_document(doc)
        return None

    def _encode_path(path) -> dict:
        return {"__path__": list(path)}

    def _decode_path(v) -> ElementPath | None:
        if isinstance(v, dict) and "__path__" in v:
            arr = v.get("__path__")
            if isinstance(arr, list) and all(
                isinstance(i, (int, float)) and not isinstance(i, bool)
                for i in arr
            ):
                return tuple(int(i) for i in arr)
        return None

    def _find_path_handle_near(doc, x, y, radius):
        def check(pe, path):
            cps = control_points(pe)
            for ai in range(len(cps)):
                h_in, h_out = path_handle_positions(pe.d, ai)
                if h_in is not None:
                    dx = x - h_in[0]
                    dy = y - h_in[1]
                    if (dx * dx + dy * dy) ** 0.5 < radius:
                        return (path, ai, "in")
                if h_out is not None:
                    dx = x - h_out[0]
                    dy = y - h_out[1]
                    if (dx * dx + dy * dy) ** 0.5 < radius:
                        return (path, ai, "out")
            return None

        for li, layer in enumerate(doc.layers):
            for ci, child in enumerate(getattr(layer, "children", ())):
                if isinstance(child, PathElem) and not child.locked:
                    r = check(child, (li, ci))
                    if r is not None:
                        return r
                if isinstance(child, Group) and not child.locked:
                    for gi, g in enumerate(child.children):
                        if isinstance(g, PathElem) and not g.locked:
                            r = check(g, (li, ci, gi))
                            if r is not None:
                                return r
        return None

    def _find_path_anchor_by_cp(doc, x, y, radius):
        def check(elem, path):
            cps = control_points(elem)
            for i, (px, py) in enumerate(cps):
                dx = x - px
                dy = y - py
                if (dx * dx + dy * dy) ** 0.5 < radius:
                    return (path, i)
            return None

        for li, layer in enumerate(doc.layers):
            for ci, child in enumerate(getattr(layer, "children", ())):
                if isinstance(child, PathElem) and not child.locked:
                    r = check(child, (li, ci))
                    if r is not None:
                        return r
                if isinstance(child, Group) and not child.locked:
                    for gi, g in enumerate(child.children):
                        if isinstance(g, PathElem) and not g.locked:
                            r = check(g, (li, ci, gi))
                            if r is not None:
                                return r
        return None

    def doc_path_probe_anchor_hit(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        x = eval_number(spec.get("x"), store, ctx)
        y = eval_number(spec.get("y"), store, ctx)
        raw = eval_number(spec.get("hit_radius"), store, ctx)
        radius = raw if raw != 0.0 else 8.0
        doc = controller.document
        h = _find_path_handle_near(doc, x, y, radius)
        if h is not None:
            path, ai, handle_type = h
            store.set_tool("anchor_point", "mode", "pressed_handle")
            store.set_tool("anchor_point", "handle_type", handle_type)
            store.set_tool("anchor_point", "hit_anchor_idx", ai)
            store.set_tool("anchor_point", "hit_path", _encode_path(path))
            return None
        a = _find_path_anchor_by_cp(doc, x, y, radius)
        if a is not None:
            path, ai = a
            elem = doc.get_element(path)
            mode = "pressed_smooth" if (isinstance(elem, PathElem)
                                         and is_smooth_point(elem.d, ai)) \
                else "pressed_corner"
            store.set_tool("anchor_point", "mode", mode)
            store.set_tool("anchor_point", "hit_anchor_idx", ai)
            store.set_tool("anchor_point", "hit_path", _encode_path(path))
            return None
        store.set_tool("anchor_point", "mode", "idle")
        return None

    def doc_path_commit_anchor_edit(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        tx = eval_number(spec.get("target_x"), store, ctx)
        ty = eval_number(spec.get("target_y"), store, ctx)
        ox = eval_number(spec.get("origin_x"), store, ctx)
        oy = eval_number(spec.get("origin_y"), store, ctx)
        mode = store.get_tool("anchor_point", "mode")
        if mode == "idle" or mode is None:
            return None
        path = _decode_path(store.get_tool("anchor_point", "hit_path"))
        if path is None:
            return None
        ai_raw = store.get_tool("anchor_point", "hit_anchor_idx") or 0
        ai = int(ai_raw)
        try:
            elem = controller.document.get_element(path)
        except Exception:
            return None
        if not isinstance(elem, PathElem):
            return None

        def apply(new_cmds):
            new_elem = _path_with_commands(elem, new_cmds)
            controller.set_document(
                controller.document.replace_element(path, new_elem))

        if mode == "pressed_smooth":
            controller.model.snapshot()
            apply(convert_smooth_to_corner(elem.d, ai))
        elif mode == "pressed_corner":
            moved = ((tx - ox) ** 2 + (ty - oy) ** 2) ** 0.5
            if moved > 1.0:
                controller.model.snapshot()
                apply(convert_corner_to_smooth(elem, ai, tx, ty).d)
        elif mode == "pressed_handle":
            handle_type = store.get_tool("anchor_point", "handle_type") or ""
            dx = tx - ox
            dy = ty - oy
            if abs(dx) > 0.5 or abs(dy) > 0.5:
                controller.model.snapshot()
                apply(move_path_handle_independent(elem, ai, handle_type, dx, dy).d)
        return None

    def doc_move_path_handle(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        dx = eval_number(spec.get("dx"), store, ctx)
        dy = eval_number(spec.get("dy"), store, ctx)
        path = _decode_path(store.get_tool("partial_selection", "handle_path"))
        if path is None:
            return None
        ai_raw = store.get_tool("partial_selection", "handle_anchor_idx") or 0
        ai = int(ai_raw)
        handle_type = store.get_tool("partial_selection", "handle_type") or ""
        controller.move_path_handle(path, ai, handle_type, dx, dy)
        return None

    def doc_path_commit_partial_marquee(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        rx, ry, rw, rh, additive = normalize_rect_args(spec, store, ctx)
        if rw > 1.0 or rh > 1.0:
            controller.model.snapshot()
            controller.partial_select_rect(rx, ry, rw, rh, extend=additive)
        elif not additive:
            controller.set_selection(frozenset())
        return None

    def doc_path_probe_partial_hit(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        x = eval_number(spec.get("x"), store, ctx)
        y = eval_number(spec.get("y"), store, ctx)
        raw = eval_number(spec.get("hit_radius"), store, ctx)
        radius = raw if raw != 0.0 else 8.0
        shift = eval_bool(spec.get("shift"), store, ctx)
        doc = controller.document

        # 1. Handle hit on selected path.
        handle_hit = None
        for es in doc.selection:
            try:
                elem = doc.get_element(es.path)
            except Exception:
                continue
            if not isinstance(elem, PathElem):
                continue
            total = control_point_count(elem)
            for ai in range(total):
                h_in, h_out = path_handle_positions(elem.d, ai)
                if h_in is not None:
                    dx = x - h_in[0]
                    dy = y - h_in[1]
                    if (dx * dx + dy * dy) ** 0.5 < radius:
                        handle_hit = (es.path, ai, "in")
                        break
                if h_out is not None:
                    dx = x - h_out[0]
                    dy = y - h_out[1]
                    if (dx * dx + dy * dy) ** 0.5 < radius:
                        handle_hit = (es.path, ai, "out")
                        break
            if handle_hit is not None:
                break

        if handle_hit is not None:
            path, ai, ht = handle_hit
            store.set_tool("partial_selection", "mode", "handle")
            store.set_tool("partial_selection", "handle_anchor_idx", ai)
            store.set_tool("partial_selection", "handle_type", ht)
            store.set_tool("partial_selection", "handle_path", _encode_path(path))
            return None

        # 2. CP hit on any unlocked element (recurse groups).
        cp_hit = None

        def recurse(elem, path):
            nonlocal cp_hit
            if elem.locked or getattr(elem, "visibility", None) is None:
                pass
            if isinstance(elem, (Group, Layer)):
                for i in range(len(elem.children) - 1, -1, -1):
                    child = elem.children[i]
                    if child.locked:
                        continue
                    recurse(child, path + (i,))
                    if cp_hit is not None:
                        return
                return
            cps = control_points(elem)
            for i, (px, py) in enumerate(cps):
                dx = x - px
                dy = y - py
                if (dx * dx + dy * dy) ** 0.5 < radius:
                    cp_hit = (path, i)
                    return

        for li in range(len(doc.layers) - 1, -1, -1):
            recurse(doc.layers[li], (li,))
            if cp_hit is not None:
                break

        if cp_hit is not None:
            path, cp_idx = cp_hit
            already = any(
                es.path == path and selection_kind_contains(es.kind, cp_idx)
                for es in doc.selection
            )
            if not already or shift:
                controller.model.snapshot()
                if shift:
                    sel = set(doc.selection)
                    existing = next((es for es in sel if es.path == path), None)
                    if existing is not None:
                        total = control_point_count(doc.get_element(path))
                        cps = list(selection_kind_to_sorted(existing.kind, total))
                        if cp_idx in cps:
                            cps.remove(cp_idx)
                        else:
                            cps.append(cp_idx)
                        sel.discard(existing)
                        sel.add(ElementSelection.partial(path, cps))
                    else:
                        sel.add(ElementSelection.partial(path, [cp_idx]))
                    controller.set_selection(frozenset(sel))
                else:
                    controller.select_control_point(path, cp_idx)
            store.set_tool("partial_selection", "mode", "moving_pending")
            return None

        # 3. No hit — marquee.
        store.set_tool("partial_selection", "mode", "marquee")
        return None

    effects["doc.snapshot"] = doc_snapshot
    effects["doc.clear_selection"] = doc_clear_selection
    effects["doc.set_selection"] = doc_set_selection
    effects["doc.add_to_selection"] = doc_add_to_selection
    effects["doc.toggle_selection"] = doc_toggle_selection
    effects["doc.translate_selection"] = doc_translate_selection
    effects["doc.set_attr_on_selection"] = doc_set_attr_on_selection
    effects["brush.delete_selected"] = brush_delete_selected
    effects["brush.duplicate_selected"] = brush_duplicate_selected
    effects["brush.append"] = brush_append
    effects["brush.update"] = brush_update
    effects["doc.copy_selection"] = doc_copy_selection
    effects["doc.select_in_rect"] = doc_select_in_rect
    effects["doc.partial_select_in_rect"] = doc_partial_select_in_rect
    effects["buffer.push"] = buffer_push
    effects["buffer.clear"] = buffer_clear
    effects["anchor.push"] = anchor_push
    effects["anchor.set_last_out"] = anchor_set_last_out
    effects["anchor.pop"] = anchor_pop
    effects["anchor.clear"] = anchor_clear
    effects["doc.select_polygon_from_buffer"] = doc_select_polygon_from_buffer
    # Phase 4b
    effects["doc.add_element"] = doc_add_element
    effects["doc.add_path_from_buffer"] = doc_add_path_from_buffer
    effects["doc.add_path_from_anchor_buffer"] = doc_add_path_from_anchor_buffer
    effects["doc.path.delete_anchor_near"] = doc_path_delete_anchor_near
    effects["doc.path.insert_anchor_on_segment_near"] = doc_path_insert_anchor_on_segment_near
    effects["doc.path.erase_at_rect"] = doc_path_erase_at_rect
    effects["doc.path.smooth_at_cursor"] = doc_path_smooth_at_cursor
    effects["doc.path.probe_anchor_hit"] = doc_path_probe_anchor_hit
    effects["doc.path.commit_anchor_edit"] = doc_path_commit_anchor_edit
    effects["doc.move_path_handle"] = doc_move_path_handle
    effects["doc.path.commit_partial_marquee"] = doc_path_commit_partial_marquee
    effects["doc.path.probe_partial_hit"] = doc_path_probe_partial_hit
    return effects
