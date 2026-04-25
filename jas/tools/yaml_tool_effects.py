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

import dataclasses
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
    Transform,
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

    # ── Generic data.* primitives ─────────────────────────

    def data_set(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        path = _eval_string_value(spec.get("path"), store, ctx)
        if not path:
            return None
        value = _resolve_value_or_expr(spec.get("value"), store, ctx)
        store.set_data_path(path, value)
        return None

    def data_list_append(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        path = _eval_string_value(spec.get("path"), store, ctx)
        if not path:
            return None
        value = _resolve_value_or_expr(spec.get("value"), store, ctx)
        cur = store.get_data_path(path)
        arr = list(cur) if isinstance(cur, list) else []
        arr.append(value)
        store.set_data_path(path, arr)
        return None

    def data_list_remove(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        path = _eval_string_value(spec.get("path"), store, ctx)
        index = int(eval_number(spec.get("index"), store, ctx))
        cur = store.get_data_path(path)
        if not isinstance(cur, list) or index < 0 or index >= len(cur):
            return None
        arr = list(cur)
        arr.pop(index)
        store.set_data_path(path, arr)
        return None

    def data_list_insert(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        path = _eval_string_value(spec.get("path"), store, ctx)
        if not path:
            return None
        value = _resolve_value_or_expr(spec.get("value"), store, ctx)
        index = int(eval_number(spec.get("index"), store, ctx))
        cur = store.get_data_path(path)
        arr = list(cur) if isinstance(cur, list) else []
        i = max(0, min(index, len(arr)))
        arr.insert(i, value)
        store.set_data_path(path, arr)
        return None

    def brush_options_confirm(spec, ctx, store):
        """Per-mode dispatch reading dialog state. Phase 1
        Calligraphic only. The YAML brush_options_confirm action
        calls this. Mirrors the Rust apply_dialog_confirm and
        Swift brush.options_confirm handlers."""
        dialog = store.get_dialog_state() if hasattr(store, 'get_dialog_state') else {}
        params = (store.get_dialog_params() if hasattr(store, 'get_dialog_params') else None) or {}
        mode = params.get("mode") or "create"
        library = params.get("library") or ""
        brush_slug = params.get("brush_slug") or ""
        name = dialog.get("brush_name") or "Brush"
        brush_type = dialog.get("brush_type") or "calligraphic"
        angle = float(dialog.get("angle") or 0.0)
        roundness = float(dialog.get("roundness") or 100.0)
        size = float(dialog.get("size") or 5.0)
        angle_var = dialog.get("angle_variation") or {"mode": "fixed"}
        roundness_var = dialog.get("roundness_variation") or {"mode": "fixed"}
        size_var = dialog.get("size_variation") or {"mode": "fixed"}

        lib_key = library
        if not lib_key:
            libs = store.get_data_path("brush_libraries") or {}
            keys = sorted(libs.keys()) if isinstance(libs, dict) else []
            if keys:
                lib_key = keys[0]
        if not lib_key:
            return None

        def _slug_from_name(s: str) -> str:
            return "".join(
                c.lower() if c.isalnum() else "_" for c in s
            )

        if mode == "create":
            raw = _slug_from_name(name)
            path = _library_brushes_path(lib_key)
            existing = set()
            cur = store.get_data_path(path)
            if isinstance(cur, list):
                existing = {b.get("slug") for b in cur if isinstance(b, dict)}
            slug = raw
            n = 2
            while slug in existing:
                slug = f"{raw}_{n}"
                n += 1
            brush = {"name": name, "slug": slug, "type": brush_type}
            if brush_type == "calligraphic":
                brush["angle"] = angle
                brush["roundness"] = roundness
                brush["size"] = size
                brush["angle_variation"] = angle_var
                brush["roundness_variation"] = roundness_var
                brush["size_variation"] = size_var
            _brush_append_to_library(store, lib_key, brush)
            _sync_canvas_brushes(store)

        elif mode == "library_edit" and brush_slug:
            patch = {"name": name}
            if brush_type == "calligraphic":
                patch["angle"] = angle
                patch["roundness"] = roundness
                patch["size"] = size
                patch["angle_variation"] = angle_var
                patch["roundness_variation"] = roundness_var
                patch["size_variation"] = size_var
            _brush_update_in_library(store, lib_key, brush_slug, patch)
            _sync_canvas_brushes(store)

        elif mode == "instance_edit":
            import json as _json
            overrides = {"angle": angle, "roundness": roundness, "size": size}
            controller.set_selection_stroke_brush_overrides(_json.dumps(overrides))

        return None

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

    def _paintbrush_stroke_width(stroke_brush, overrides, store, ctx):
        """Paintbrush stroke-width commit rule per PAINTBRUSH_TOOL.md
        §Fill and stroke: no brush → state.stroke_width; brush with
        size (Calligraphic/Scatter/Bristle) → overrides.size, else
        brush.size; brush with no size (Art/Pattern) →
        state.stroke_width."""
        sw_val = _eval_value("state.stroke_width", store, ctx)
        state_width = sw_val.value if sw_val.type == ValueType.NUMBER else 1.0
        if not stroke_brush:
            return state_width
        # overrides.size wins over brush.size.
        if overrides:
            try:
                import json
                obj = json.loads(overrides)
                if isinstance(obj, dict) and "size" in obj:
                    sz = obj["size"]
                    if isinstance(sz, (int, float)):
                        return float(sz)
            except Exception:
                pass
        parts = stroke_brush.split("/", 1)
        if len(parts) != 2:
            return state_width
        lib_id, brush_slug = parts
        path = f"brush_libraries.{lib_id}.brushes"
        brushes = store.get_data_path(path)
        if not isinstance(brushes, list):
            return state_width
        for b in brushes:
            if isinstance(b, dict) and b.get("slug") == brush_slug:
                sz = b.get("size")
                if isinstance(sz, (int, float)):
                    return float(sz)
                return state_width
        return state_width

    def _make_path_from_commands(cmds, spec, ctx, store) -> PathElem:
        has_stroke_brush_arg = isinstance(spec, dict) and "stroke_brush" in spec
        stroke_brush = None
        if has_stroke_brush_arg and spec.get("stroke_brush") is not None:
            sb_val = _eval_value(spec["stroke_brush"], store, ctx)
            if sb_val.type == ValueType.STRING and sb_val.value:
                stroke_brush = sb_val.value
        stroke_brush_overrides = None
        if isinstance(spec, dict) and "stroke_brush_overrides" in spec \
           and spec.get("stroke_brush_overrides") is not None:
            sbo_val = _eval_value(spec["stroke_brush_overrides"], store, ctx)
            if sbo_val.type == ValueType.STRING and sbo_val.value:
                stroke_brush_overrides = sbo_val.value

        # Fill: fill_new_strokes takes precedence (Paintbrush rule).
        if isinstance(spec, dict) and "fill_new_strokes" in spec:
            if eval_bool(spec.get("fill_new_strokes"), store, ctx):
                fc_val = _eval_value("state.fill_color", store, ctx)
                color_str = fc_val.value \
                    if fc_val.type in (ValueType.COLOR, ValueType.STRING) else ""
                color = Color.from_hex(color_str) if color_str else None
                fill = Fill(color=color) if color else None
            else:
                fill = None
        else:
            has_fill = isinstance(spec, dict) and "fill" in spec
            default_fill = getattr(controller.model, "default_fill", None)
            fill = _resolve_fill(
                spec.get("fill") if isinstance(spec, dict) else None,
                has_fill, default_fill, store, ctx)

        # Stroke: presence of stroke_brush key signals Paintbrush
        # rules (compute from state); else pencil-style fall-through.
        if has_stroke_brush_arg:
            sc_val = _eval_value("state.stroke_color", store, ctx)
            color_str = sc_val.value \
                if sc_val.type in (ValueType.COLOR, ValueType.STRING) else "#000000"
            color = Color.from_hex(color_str) or Color.rgb(0.0, 0.0, 0.0)
            width = _paintbrush_stroke_width(stroke_brush,
                                             stroke_brush_overrides,
                                             store, ctx)
            stroke = Stroke(color=color, width=width)
        else:
            has_stroke = isinstance(spec, dict) and "stroke" in spec
            default_stroke = getattr(controller.model, "default_stroke", None)
            stroke = _resolve_stroke(
                spec.get("stroke") if isinstance(spec, dict) else None,
                has_stroke, default_stroke, store, ctx)

        return PathElem(d=tuple(cmds), fill=fill, stroke=stroke,
                        stroke_brush=stroke_brush,
                        stroke_brush_overrides=stroke_brush_overrides)

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
        # Paintbrush §Gestures close-at-release: append ClosePath when
        # the effect was called with close=true.
        if eval_bool(spec.get("close"), store, ctx):
            cmds.append(ClosePath())
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

    def _encode_path(path):
        return {"__path__": list(path)}

    def _decode_path(v):
        if not isinstance(v, dict):
            return None
        arr = v.get("__path__")
        if not isinstance(arr, list):
            return None
        out = []
        for n in arr:
            if isinstance(n, int):
                out.append(n)
            else:
                return None
        return out

    def doc_paintbrush_edit_start(spec, ctx, store):
        """Paintbrush edit-gesture target selection per
        PAINTBRUSH_TOOL.md §Edit gesture — Target selection.

        Scans selected Paths, picks the one whose closest flat
        point is nearest and ≤ `within` px of (x, y). Writes
        tool.paintbrush.mode='edit' + edit_target_path + entry_idx.
        No-op when no target qualifies."""
        if not isinstance(spec, dict):
            return None
        x = eval_number(spec.get("x"), store, ctx)
        y = eval_number(spec.get("y"), store, ctx)
        within = eval_number(spec.get("within"), store, ctx)
        within_sq = within * within
        best = None  # (path, entry_idx, dsq)
        doc = controller.document
        for es in doc.selection:
            path = es.path
            try:
                elem = doc.get_element(path)
            except Exception:
                continue
            if not isinstance(elem, PathElem) or elem.locked:
                continue
            if len(elem.d) < 2:
                continue
            flat, _cmd_map = path_ops.flatten_with_cmd_map(elem.d)
            if not flat:
                continue
            for i, (fx, fy) in enumerate(flat):
                dx = fx - x
                dy = fy - y
                dsq = dx * dx + dy * dy
                if dsq > within_sq:
                    continue
                if best is not None and best[2] <= dsq:
                    continue
                best = (path, i, dsq)
        if best is not None:
            target_path, entry_idx, _ = best
            store.set_tool("paintbrush", "mode", "edit")
            store.set_tool("paintbrush", "edit_target_path",
                           _encode_path(target_path))
            store.set_tool("paintbrush", "edit_entry_idx", entry_idx)
        return None

    def doc_paintbrush_edit_commit(spec, ctx, store):
        """Paintbrush edit-gesture splice per PAINTBRUSH_TOOL.md
        §Edit gesture — Splice.

        Reads target + entry_idx from tool state, computes exit_idx
        on the target's flat polyline nearest the buffer's last
        point, and if within range, replaces the target's [c0..c1]
        command range with a fit_curve of the drag buffer (start
        point prepended for seamless splice). Preserves all non-`d`
        attributes."""
        if not isinstance(spec, dict):
            return None
        buffer = spec.get("buffer")
        if not isinstance(buffer, str):
            return None
        raw_e = eval_number(spec.get("fit_error"), store, ctx)
        fit_error = 4.0 if raw_e == 0.0 else raw_e
        within = eval_number(spec.get("within"), store, ctx)
        within_sq = within * within
        target_path = _decode_path(store.get_tool("paintbrush",
                                                  "edit_target_path"))
        if target_path is None:
            return None
        entry_idx = store.get_tool("paintbrush", "edit_entry_idx")
        if not isinstance(entry_idx, int) or entry_idx < 0:
            return None
        drag_points = point_buffers.points(buffer)
        if len(drag_points) < 2:
            return None
        doc = controller.document
        try:
            target_elem = doc.get_element(target_path)
        except Exception:
            return None
        if not isinstance(target_elem, PathElem) or target_elem.locked:
            return None
        if len(target_elem.d) < 2:
            return None
        flat, cmd_map = path_ops.flatten_with_cmd_map(target_elem.d)
        if not flat or entry_idx >= len(flat):
            return None
        last_x, last_y = drag_points[-1]
        best = None  # (idx, dsq)
        for i, (fx, fy) in enumerate(flat):
            dx = fx - last_x
            dy = fy - last_y
            dsq = dx * dx + dy * dy
            if best is not None and best[1] <= dsq:
                continue
            best = (i, dsq)
        if best is None or best[1] > within_sq:
            return None
        exit_idx, _ = best
        if exit_idx == entry_idx:
            return None
        lo_flat = min(entry_idx, exit_idx)
        hi_flat = max(entry_idx, exit_idx)
        c0 = cmd_map[lo_flat]
        c1 = cmd_map[hi_flat]
        if c0 >= c1 or c1 >= len(target_elem.d):
            return None
        ordered_drag = list(reversed(drag_points)) \
            if exit_idx < entry_idx else list(drag_points)
        start_pt = path_ops.cmd_start_point(target_elem.d, c0)
        points_to_fit = [start_pt] + ordered_drag
        if len(points_to_fit) < 2:
            return None
        segments = fit_curve(points_to_fit, fit_error)
        if not segments:
            return None
        prefix = list(target_elem.d[:c0])
        suffix = list(target_elem.d[c1 + 1:])
        new_curves = [
            CurveTo(x1=seg[2], y1=seg[3],
                    x2=seg[4], y2=seg[5],
                    x=seg[6], y=seg[7])
            for seg in segments
        ]
        new_cmds = prefix + new_curves + suffix
        import dataclasses
        new_elem = dataclasses.replace(target_elem, d=tuple(new_cmds))
        new_doc = doc.replace_element(target_path, new_elem)
        controller.set_document(new_doc)
        return None

    # ── Blob Brush commit helpers + effects ─────────────

    def _blob_brush_effective_tip(store, ctx):
        """Runtime tip resolution per BLOB_BRUSH_TOOL.md. When
        state.stroke_brush refers to a Calligraphic library brush,
        its size/angle/roundness drive the tip (with
        stroke_brush_overrides layered). Otherwise the dialog
        defaults state.blob_brush_* are used. Variation modes other
        than `fixed` are evaluated as the base value in Phase 1.
        Returns (size, angle_deg, roundness_pct)."""
        def num_or(expr, default):
            v = _eval_value(expr, store, ctx)
            return v.value if v.type == ValueType.NUMBER else default

        default_size = num_or("state.blob_brush_size", 10.0)
        default_angle = num_or("state.blob_brush_angle", 0.0)
        default_roundness = num_or("state.blob_brush_roundness", 100.0)

        slug_val = _eval_value("state.stroke_brush", store, ctx)
        if slug_val.type != ValueType.STRING or not slug_val.value:
            return (default_size, default_angle, default_roundness)
        slug = slug_val.value
        if "/" not in slug:
            return (default_size, default_angle, default_roundness)
        lib_id, _, brush_slug = slug.partition("/")
        brushes = store.get_data_path(
            f"brush_libraries.{lib_id}.brushes")
        if not isinstance(brushes, list):
            return (default_size, default_angle, default_roundness)
        brush = next(
            (b for b in brushes
             if isinstance(b, dict) and b.get("slug") == brush_slug),
            None)
        if brush is None or brush.get("type") != "calligraphic":
            return (default_size, default_angle, default_roundness)
        size = float(brush.get("size", default_size))
        angle = float(brush.get("angle", default_angle))
        roundness = float(brush.get("roundness", default_roundness))

        # Apply state.stroke_brush_overrides (compact JSON) if present.
        ovr_val = _eval_value("state.stroke_brush_overrides", store, ctx)
        if ovr_val.type == ValueType.STRING and ovr_val.value:
            import json
            try:
                ovr = json.loads(ovr_val.value)
                if isinstance(ovr, dict):
                    size = float(ovr.get("size", size))
                    angle = float(ovr.get("angle", angle))
                    roundness = float(ovr.get("roundness", roundness))
            except Exception:
                pass
        return (size, angle, roundness)

    def _blob_brush_oval_ring(cx, cy, size, angle_deg, roundness_pct):
        """16-segment rotated-ellipse ring at (cx, cy)."""
        import math
        segments = 16
        rx = size * 0.5
        ry = size * (roundness_pct / 100.0) * 0.5
        rad = angle_deg * math.pi / 180.0
        cs = math.cos(rad)
        sn = math.sin(rad)
        out = []
        for i in range(segments):
            t = 2.0 * math.pi * i / segments
            lx = rx * math.cos(t)
            ly = ry * math.sin(t)
            x = cx + lx * cs - ly * sn
            y = cy + lx * sn + ly * cs
            out.append((x, y))
        return out

    def _blob_brush_arc_length_subsample(points, spacing):
        """Arc-length resample a point sequence at uniform intervals.
        Always keeps first and last points. Interpolation is
        essential: naive sample-at-existing-points leaves seams when
        OS mousemove events are coarser than the tip radius."""
        import math
        if len(points) < 2 or spacing <= 0.0:
            return list(points)
        out = [points[0]]
        remaining = spacing
        for i in range(len(points) - 1):
            ax, ay = points[i]
            bx, by = points[i + 1]
            dx = bx - ax
            dy = by - ay
            seg_len = math.sqrt(dx * dx + dy * dy)
            if seg_len <= 0.0:
                continue
            t_at = 0.0
            while t_at + remaining <= seg_len:
                t_at += remaining
                t = t_at / seg_len
                out.append((ax + dx * t, ay + dy * t))
                remaining = spacing
            remaining -= seg_len - t_at
        tail = points[-1]
        if out[-1] != tail:
            out.append(tail)
        return out

    def _blob_brush_sweep_region(points, tip):
        """Build the swept region from buffer points and tip params.
        Subsamples at 1/2 * min tip dimension, places an oval at
        each sample, and unions them via boolean_union."""
        from algorithms.boolean import boolean_union
        size, angle, roundness = tip
        min_dim = min(size, size * roundness / 100.0)
        spacing = max(min_dim * 0.5, 0.5)
        samples = _blob_brush_arc_length_subsample(points, spacing)
        region: list = []
        for cx, cy in samples:
            oval = [_blob_brush_oval_ring(cx, cy, size, angle, roundness)]
            if not region:
                region = oval
            else:
                region = boolean_union(region, oval)
        return region

    def _blob_brush_fill_matches(a, b):
        """Merge condition: both solid, matching sRGB hex + opacity."""
        if a is None or b is None:
            return False
        return (a.color.to_hex().lower() == b.color.to_hex().lower()
                and abs(a.opacity - b.opacity) < 1e-9)

    def _blob_brush_insert_at(doc, layer_idx, child_idx, elem):
        """Insert elem at doc.layers[layer_idx].children[child_idx]
        via dataclasses.replace. Shifts later children down."""
        import dataclasses
        if layer_idx < 0 or layer_idx >= len(doc.layers):
            return doc
        layer = doc.layers[layer_idx]
        children = list(layer.children)
        clamped = max(0, min(child_idx, len(children)))
        children.insert(clamped, elem)
        new_layer = dataclasses.replace(layer, children=tuple(children))
        new_layers = list(doc.layers)
        new_layers[layer_idx] = new_layer
        return dataclasses.replace(doc, layers=tuple(new_layers))

    def doc_blob_brush_commit_painting(spec, ctx, store):
        """BLOB_BRUSH_TOOL.md Commit pipeline + Multi-element merge.
        Builds the swept region, finds matching existing blob-brush
        elements (tool_origin == "blob_brush" + fill matches +
        optional selection-scoped), unions all matches with the
        sweep, replaces them with a single merged Path at the lowest
        matching z-index (or appends to layer 0 if no matches)."""
        from algorithms.boolean import boolean_intersect, boolean_union
        import dataclasses
        if not isinstance(spec, dict):
            return None
        buffer = spec.get("buffer")
        if not isinstance(buffer, str) or not buffer:
            return None
        _ = eval_number(spec.get("fidelity_epsilon"), store, ctx)
        merge_only_with_selection = eval_bool(
            spec.get("merge_only_with_selection"), store, ctx)
        _keep_selected = eval_bool(spec.get("keep_selected"), store, ctx)
        points = point_buffers.points(buffer)
        if len(points) < 2:
            return None
        tip = _blob_brush_effective_tip(store, ctx)
        swept = _blob_brush_sweep_region(points, tip)
        if not swept:
            return None
        # Resolve fill from state.fill_color.
        fill_val = _eval_value("state.fill_color", store, ctx)
        new_fill = None
        if fill_val.type in (ValueType.COLOR, ValueType.STRING):
            try:
                new_fill = Fill(color=Color.from_hex(fill_val.value))
            except Exception:
                new_fill = None
        doc = controller.document
        selected_paths = {tuple(es.path) for es in doc.selection}
        matches = []  # list of (layer_idx, child_idx)
        unified = swept
        for li, layer in enumerate(doc.layers):
            for ci, child in enumerate(layer.children):
                if not isinstance(child, PathElem):
                    continue
                if child.tool_origin != "blob_brush":
                    continue
                if not _blob_brush_fill_matches(child.fill, new_fill):
                    continue
                path = (li, ci)
                if merge_only_with_selection and path not in selected_paths:
                    continue
                existing = path_ops.path_to_polygon_set(list(child.d))
                if not boolean_intersect(unified, existing):
                    continue
                unified = boolean_union(unified, existing)
                matches.append(path)
        # Insertion z = lowest matching (layer, child); default append
        # to layer 0.
        if not matches:
            insert_layer = 0
            insert_idx = None
        else:
            lowest = matches[0]
            insert_layer = lowest[0]
            insert_idx = lowest[1]
        new_d = path_ops.polygon_set_to_path(unified)
        if not new_d:
            return None
        new_elem = PathElem(
            d=tuple(new_d),
            fill=new_fill,
            stroke=None,
            width_points=(),
            tool_origin="blob_brush",
        )
        # Remove matches in reverse so earlier indices stay valid.
        new_doc = doc
        for path in sorted(matches, reverse=True):
            new_doc = new_doc.delete_element(list(path))
        if insert_idx is not None:
            new_doc = _blob_brush_insert_at(
                new_doc, insert_layer, insert_idx, new_elem)
        else:
            n = len(new_doc.layers[insert_layer].children)
            new_doc = _blob_brush_insert_at(
                new_doc, insert_layer, n, new_elem)
        controller.set_document(new_doc)
        return None

    def doc_blob_brush_commit_erasing(spec, ctx, store):
        """BLOB_BRUSH_TOOL.md Erase gesture → Commit. boolean_subtract
        the swept region from each intersecting tool_origin ==
        "blob_brush" element. Empty remainder → delete; non-empty →
        update in place. Non-blob-brush elements are untouched."""
        from algorithms.boolean import boolean_intersect, boolean_subtract
        import dataclasses
        if not isinstance(spec, dict):
            return None
        buffer = spec.get("buffer")
        if not isinstance(buffer, str) or not buffer:
            return None
        _ = eval_number(spec.get("fidelity_epsilon"), store, ctx)
        points = point_buffers.points(buffer)
        if len(points) < 2:
            return None
        tip = _blob_brush_effective_tip(store, ctx)
        swept = _blob_brush_sweep_region(points, tip)
        if not swept:
            return None
        doc = controller.document
        new_doc = doc
        # Iterate in reverse so deletions don't invalidate earlier
        # indices.
        for li in range(len(doc.layers) - 1, -1, -1):
            layer = doc.layers[li]
            for ci in range(len(layer.children) - 1, -1, -1):
                child = layer.children[ci]
                if not isinstance(child, PathElem):
                    continue
                if child.tool_origin != "blob_brush":
                    continue
                existing = path_ops.path_to_polygon_set(list(child.d))
                if not boolean_intersect(existing, swept):
                    continue
                remainder = boolean_subtract(existing, swept)
                path = [li, ci]
                new_d = path_ops.polygon_set_to_path(remainder)
                if not new_d:
                    new_doc = new_doc.delete_element(path)
                else:
                    new_pe = dataclasses.replace(child, d=tuple(new_d))
                    new_doc = new_doc.replace_element(path, new_pe)
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

    # ── Magic Wand effect ─────────────────────────────────────
    # See MAGIC_WAND_TOOL.md §Predicate + §Eligibility filter.

    def _read_magic_wand_config(s, c):
        from algorithms.magic_wand import MagicWandConfig
        d = MagicWandConfig()

        def bool_at(key: str, fallback: bool) -> bool:
            v = _eval_value(f"state.{key}", s, c)
            return bool(v.value) if v.type == ValueType.BOOL else fallback

        def num_at(key: str, fallback: float) -> float:
            v = _eval_value(f"state.{key}", s, c)
            return float(v.value) if v.type == ValueType.NUMBER else fallback

        return MagicWandConfig(
            fill_color=bool_at("magic_wand_fill_color", d.fill_color),
            fill_tolerance=num_at("magic_wand_fill_tolerance", d.fill_tolerance),
            stroke_color=bool_at("magic_wand_stroke_color", d.stroke_color),
            stroke_tolerance=num_at("magic_wand_stroke_tolerance", d.stroke_tolerance),
            stroke_weight=bool_at("magic_wand_stroke_weight", d.stroke_weight),
            stroke_weight_tolerance=num_at(
                "magic_wand_stroke_weight_tolerance", d.stroke_weight_tolerance),
            opacity=bool_at("magic_wand_opacity", d.opacity),
            opacity_tolerance=num_at(
                "magic_wand_opacity_tolerance", d.opacity_tolerance),
            blending_mode=bool_at("magic_wand_blending_mode", d.blending_mode),
        )

    def _walk_eligible(doc):
        """Yield (path, element) for every leaf element that passes the
        §Eligibility filter — locked / hidden are skipped, Group / Layer
        descend into their children rather than acting as candidates."""
        from geometry.element import Group, Visibility

        def walk(elem, cur_path):
            if elem.locked:
                return
            if elem.visibility == Visibility.INVISIBLE:
                return
            if isinstance(elem, Group):
                for i, child in enumerate(elem.children):
                    yield from walk(child, cur_path + (i,))
            else:
                yield (cur_path, elem)

        for li, layer in enumerate(doc.layers):
            yield from walk(layer, (li,))

    def doc_magic_wand_apply(spec, ctx, store):
        from algorithms.magic_wand import magic_wand_match

        if not isinstance(spec, dict):
            return None
        seed_path = extract_path(spec.get("seed"), store, ctx)
        if seed_path is None:
            return None
        mode_raw = _eval_string_value(spec.get("mode"), store, ctx)
        mode = mode_raw if mode_raw else "replace"

        doc = controller.document
        try:
            seed_elem = doc.get_element(seed_path)
        except Exception:
            return None
        cfg = _read_magic_wand_config(store, ctx)

        matches: list[ElementPath] = []
        for path, candidate in _walk_eligible(doc):
            if path == seed_path:
                matches.append(path)
            elif magic_wand_match(seed_elem, candidate, cfg):
                matches.append(path)

        new_set = frozenset(ElementSelection.all(p) for p in matches)
        new_paths = {es.path for es in new_set}

        if mode == "add":
            existing = set(doc.selection)
            existing.update(new_set)
            controller.set_selection(frozenset(existing))
        elif mode == "subtract":
            kept = {es for es in doc.selection if es.path not in new_paths}
            controller.set_selection(frozenset(kept))
        else:  # replace (default)
            controller.set_selection(new_set)
        return None

    # ── Transform tools (Scale / Rotate / Shear) ────────────
    # See SCALE_TOOL.md / ROTATE_TOOL.md / SHEAR_TOOL.md
    # §Apply behavior.

    def _eval_number_arg(arg, store, ctx) -> float:
        if arg is None:
            return 0.0
        if isinstance(arg, (int, float)) and not isinstance(arg, bool):
            return float(arg)
        if isinstance(arg, str):
            v = _eval_value(arg, store, ctx)
            if v.type == ValueType.NUMBER:
                return float(v.value)
        return 0.0

    def _eval_bool_arg(arg, store, ctx) -> bool:
        if arg is None:
            return False
        if isinstance(arg, bool):
            return arg
        if isinstance(arg, str):
            v = _eval_value(arg, store, ctx)
            if v.type == ValueType.BOOL:
                return bool(v.value)
        return False

    def _resolve_reference_point(store, ctx) -> tuple[float, float]:
        """state.transform_reference_point as a list of two numbers,
        else fall back to selection union bbox center."""
        v = _eval_value("state.transform_reference_point", store, ctx)
        if v.type == ValueType.LIST and len(v.value) >= 2:
            try:
                rx = float(v.value[0])
                ry = float(v.value[1])
                return (rx, ry)
            except (TypeError, ValueError):
                pass
        from jas.algorithms.align import union_bounds, geometric_bounds
        doc = controller.document
        elements = []
        for es in doc.selection:
            try:
                elements.append(doc.get_element(es.path))
            except Exception:
                pass
        if not elements:
            return (0.0, 0.0)
        x, y, w, h = union_bounds(elements, geometric_bounds)
        return (x + w / 2, y + h / 2)

    def _drag_to_scale_factors(px, py, cx, cy, rx, ry, shift):
        denom_x = px - rx
        denom_y = py - ry
        sx = 1.0 if abs(denom_x) < 1e-9 else (cx - rx) / denom_x
        sy = 1.0 if abs(denom_y) < 1e-9 else (cy - ry) / denom_y
        if shift:
            prod = sx * sy
            sign = 1.0 if prod >= 0 else -1.0
            s = sign * (abs(prod) ** 0.5)
            return (s, s)
        return (sx, sy)

    def _drag_to_rotate_angle(px, py, cx, cy, rx, ry, shift):
        import math
        theta_press = math.atan2(py - ry, px - rx)
        theta_cursor = math.atan2(cy - ry, cx - rx)
        theta_deg = math.degrees(theta_cursor - theta_press)
        if shift:
            theta_deg = round(theta_deg / 45.0) * 45.0
        return theta_deg

    def _drag_to_shear_params(px, py, cx, cy, rx, ry, shift):
        import math
        dx = cx - px
        dy = cy - py
        if shift:
            if abs(dx) >= abs(dy):
                denom = max(abs(py - ry), 1e-9)
                k = dx / denom
                return (math.degrees(math.atan(k)), "horizontal", 0.0)
            denom = max(abs(px - rx), 1e-9)
            k = dy / denom
            return (math.degrees(math.atan(k)), "vertical", 0.0)
        ax = px - rx
        ay = py - ry
        axis_len = max((ax * ax + ay * ay) ** 0.5, 1e-9)
        perp_x = -ay / axis_len
        perp_y = ax / axis_len
        perp_dist = (cx - px) * perp_x + (cy - py) * perp_y
        k = perp_dist / axis_len
        axis_angle_deg = math.degrees(math.atan2(ay, ax))
        return (math.degrees(math.atan(k)), "custom", axis_angle_deg)

    def _apply_matrix_to_selection(
        matrix,
        stroke_factor: float | None = None,
        corner_factors: tuple[float, float] | None = None,
    ) -> None:
        """Pre-multiply matrix onto every selected element's
        transform via dataclasses.replace. Optionally multiplies
        stroke widths (when stroke_factor is set) and rounded_rect
        rx / ry (when corner_factors is set with axis-independent
        |sx|, |sy| factors)."""
        from geometry.element import Rect as RectElem
        doc = controller.document
        new_doc = doc
        for es in doc.selection:
            try:
                elem = new_doc.get_element(es.path)
            except Exception:
                continue
            current = getattr(elem, "transform", None) or Transform()
            new_t = matrix.multiply(current)
            elem = dataclasses.replace(elem, transform=new_t)
            if stroke_factor is not None:
                stroke = getattr(elem, "stroke", None)
                if stroke is not None:
                    new_stroke = dataclasses.replace(
                        stroke, width=stroke.width * stroke_factor)
                    elem = dataclasses.replace(elem, stroke=new_stroke)
            if corner_factors is not None and isinstance(elem, RectElem):
                sx_abs, sy_abs = corner_factors
                elem = dataclasses.replace(
                    elem,
                    rx=elem.rx * sx_abs,
                    ry=elem.ry * sy_abs)
            new_doc = new_doc.replace_element(es.path, elem)
        controller.set_document(new_doc)

    def doc_scale_apply(spec, ctx, store):
        from jas.algorithms.transform_apply import (
            scale_matrix, stroke_width_factor)
        if not isinstance(spec, dict):
            return None
        copy = _eval_bool_arg(spec.get("copy"), store, ctx)
        if "sx" in spec:
            sx = _eval_number_arg(spec.get("sx"), store, ctx)
            sy = _eval_number_arg(spec.get("sy"), store, ctx)
        else:
            rx, ry = _resolve_reference_point(store, ctx)
            px = _eval_number_arg(spec.get("press_x"), store, ctx)
            py = _eval_number_arg(spec.get("press_y"), store, ctx)
            cx = _eval_number_arg(spec.get("cursor_x"), store, ctx)
            cy = _eval_number_arg(spec.get("cursor_y"), store, ctx)
            shift = _eval_bool_arg(spec.get("shift"), store, ctx)
            sx, sy = _drag_to_scale_factors(px, py, cx, cy, rx, ry, shift)
        if abs(sx - 1.0) < 1e-9 and abs(sy - 1.0) < 1e-9:
            return None
        if copy:
            controller.copy_selection(0.0, 0.0)
        rx, ry = _resolve_reference_point(store, ctx)
        # Read state.scale_strokes (default true) and state.scale_corners
        # (default false) — see SCALE_TOOL.md §Apply behavior.
        strokes_v = _eval_value("state.scale_strokes", store, ctx)
        scale_strokes = strokes_v.value if strokes_v.type == ValueType.BOOL else True
        corners_v = _eval_value("state.scale_corners", store, ctx)
        scale_corners = corners_v.value if corners_v.type == ValueType.BOOL else False
        _apply_matrix_to_selection(
            scale_matrix(sx, sy, rx, ry),
            stroke_factor=stroke_width_factor(sx, sy) if scale_strokes else None,
            corner_factors=(abs(sx), abs(sy)) if scale_corners else None,
        )
        return None

    def doc_rotate_apply(spec, ctx, store):
        from jas.algorithms.transform_apply import rotate_matrix
        if not isinstance(spec, dict):
            return None
        copy = _eval_bool_arg(spec.get("copy"), store, ctx)
        if "angle" in spec:
            theta_deg = _eval_number_arg(spec.get("angle"), store, ctx)
        else:
            rx, ry = _resolve_reference_point(store, ctx)
            px = _eval_number_arg(spec.get("press_x"), store, ctx)
            py = _eval_number_arg(spec.get("press_y"), store, ctx)
            cx = _eval_number_arg(spec.get("cursor_x"), store, ctx)
            cy = _eval_number_arg(spec.get("cursor_y"), store, ctx)
            shift = _eval_bool_arg(spec.get("shift"), store, ctx)
            theta_deg = _drag_to_rotate_angle(px, py, cx, cy, rx, ry, shift)
        if abs(theta_deg) < 1e-9:
            return None
        if copy:
            controller.copy_selection(0.0, 0.0)
        rx, ry = _resolve_reference_point(store, ctx)
        _apply_matrix_to_selection(rotate_matrix(theta_deg, rx, ry))
        return None

    def doc_shear_apply(spec, ctx, store):
        from jas.algorithms.transform_apply import shear_matrix
        if not isinstance(spec, dict):
            return None
        copy = _eval_bool_arg(spec.get("copy"), store, ctx)
        if "angle" in spec and "axis" in spec:
            angle_deg = _eval_number_arg(spec.get("angle"), store, ctx)
            axis = _eval_string_value(spec.get("axis"), store, ctx)
            axis_angle_deg = _eval_number_arg(spec.get("axis_angle"), store, ctx)
        else:
            rx, ry = _resolve_reference_point(store, ctx)
            px = _eval_number_arg(spec.get("press_x"), store, ctx)
            py = _eval_number_arg(spec.get("press_y"), store, ctx)
            cx = _eval_number_arg(spec.get("cursor_x"), store, ctx)
            cy = _eval_number_arg(spec.get("cursor_y"), store, ctx)
            shift = _eval_bool_arg(spec.get("shift"), store, ctx)
            angle_deg, axis, axis_angle_deg = _drag_to_shear_params(
                px, py, cx, cy, rx, ry, shift)
        if abs(angle_deg) < 1e-9:
            return None
        if copy:
            controller.copy_selection(0.0, 0.0)
        rx, ry = _resolve_reference_point(store, ctx)
        _apply_matrix_to_selection(
            shear_matrix(angle_deg, axis, axis_angle_deg, rx, ry))
        return None

    def doc_preview_capture(spec, ctx, store):
        controller.model.capture_preview_snapshot()
        return None

    def doc_preview_restore(spec, ctx, store):
        controller.model.restore_preview_snapshot()
        return None

    def doc_preview_clear(spec, ctx, store):
        controller.model.clear_preview_snapshot()
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

    # ── doc.zoom.* and doc.pan.apply — view-state effects per
    #    ZOOM_TOOL.md and HAND_TOOL.md. None of these modify document
    #    content; they only update the per-tab view state on
    #    Model: zoom_level, view_offset_x, view_offset_y.

    def _read_pref_number(key: str, default: float) -> float:
        """Read preferences.viewport.<key> from workspace.json."""
        try:
            from interpreter.workspace_loader import load_workspace
            ws = load_workspace()
            if ws is None:
                return default
            prefs = ws.get("preferences", {})
            viewport = prefs.get("viewport", {})
            value = viewport.get(key, default)
            return float(value)
        except Exception:
            return default

    def _read_tool_zoom_state(ctx: dict, key: str, default: float) -> float:
        try:
            return float(ctx.get("tool", {}).get("zoom", {}).get(key, default))
        except (TypeError, ValueError):
            return default

    def _fit_rect_into_viewport(
        x: float, y: float, w: float, h: float, padding: float
    ) -> None:
        """Compute and write the fit-to-viewport zoom + pan."""
        if w <= 0 or h <= 0:
            return
        m = controller.model
        vw, vh = m.viewport_w, m.viewport_h
        if vw <= 0 or vh <= 0:
            return
        avail_w = vw - 2.0 * padding
        avail_h = vh - 2.0 * padding
        if avail_w <= 0 or avail_h <= 0:
            return
        min_zoom = _read_pref_number("min_zoom", 0.1)
        max_zoom = _read_pref_number("max_zoom", 64.0)
        z = max(min_zoom, min(max_zoom, min(avail_w / w, avail_h / h)))
        rect_cx = x + w / 2.0
        rect_cy = y + h / 2.0
        m.zoom_level = z
        m.view_offset_x = vw / 2.0 - rect_cx * z
        m.view_offset_y = vh / 2.0 - rect_cy * z

    def _document_bounds(doc) -> tuple[float, float, float, float]:
        if not doc.layers:
            return (0.0, 0.0, 0.0, 0.0)
        from geometry.element import bounds as elem_bounds
        min_x = float("inf")
        min_y = float("inf")
        max_x = float("-inf")
        max_y = float("-inf")
        for layer in doc.layers:
            bx, by, bw, bh = elem_bounds(layer)
            if bx < min_x:
                min_x = bx
            if by < min_y:
                min_y = by
            if bx + bw > max_x:
                max_x = bx + bw
            if by + bh > max_y:
                max_y = by + bh
        if min_x == float("inf"):
            return (0.0, 0.0, 0.0, 0.0)
        return (min_x, min_y, max_x - min_x, max_y - min_y)

    def doc_zoom_apply(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        factor = eval_number(spec.get("factor"), store, ctx)
        ax_raw = eval_number(spec.get("anchor_x"), store, ctx)
        ay_raw = eval_number(spec.get("anchor_y"), store, ctx)
        min_zoom = _read_pref_number("min_zoom", 0.1)
        max_zoom = _read_pref_number("max_zoom", 64.0)
        m = controller.model
        z, px, py = m.zoom_level, m.view_offset_x, m.view_offset_y
        ax = px if ax_raw < 0 else ax_raw
        ay = py if ay_raw < 0 else ay_raw
        doc_ax = (ax - px) / z
        doc_ay = (ay - py) / z
        z_new = max(min_zoom, min(max_zoom, z * factor))
        m.zoom_level = z_new
        m.view_offset_x = ax - doc_ax * z_new
        m.view_offset_y = ay - doc_ay * z_new
        return None

    def doc_zoom_set(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        level = eval_number(spec.get("level"), store, ctx)
        min_zoom = _read_pref_number("min_zoom", 0.1)
        max_zoom = _read_pref_number("max_zoom", 64.0)
        controller.model.zoom_level = max(min_zoom, min(max_zoom, level))
        return None

    def doc_zoom_set_full(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        zoom = eval_number(spec.get("zoom"), store, ctx)
        offx = eval_number(spec.get("offset_x"), store, ctx)
        offy = eval_number(spec.get("offset_y"), store, ctx)
        min_zoom = _read_pref_number("min_zoom", 0.1)
        max_zoom = _read_pref_number("max_zoom", 64.0)
        m = controller.model
        m.zoom_level = max(min_zoom, min(max_zoom, zoom))
        m.view_offset_x = offx
        m.view_offset_y = offy
        return None

    def doc_zoom_scrubby(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        from math import exp
        press_x = eval_number(spec.get("press_x"), store, ctx)
        press_y = eval_number(spec.get("press_y"), store, ctx)
        cursor_x = eval_number(spec.get("cursor_x"), store, ctx)
        _ = eval_number(spec.get("cursor_y"), store, ctx)
        alt_held = eval_bool(spec.get("alt_held"), store, ctx)
        alt_at_press = eval_bool(spec.get("alt_at_press"), store, ctx)
        gain = _read_pref_number("scrubby_zoom_gain", 144.0)
        min_zoom = _read_pref_number("min_zoom", 0.1)
        max_zoom = _read_pref_number("max_zoom", 64.0)
        initial_zoom = _read_tool_zoom_state(ctx, "initial_zoom", 1.0)
        initial_offx = _read_tool_zoom_state(ctx, "initial_offx", 0.0)
        initial_offy = _read_tool_zoom_state(ctx, "initial_offy", 0.0)
        dx = cursor_x - press_x
        direction = -1.0 if alt_at_press != alt_held else 1.0
        factor = exp(dx * direction / gain)
        z_new = max(min_zoom, min(max_zoom, initial_zoom * factor))
        doc_ax = (press_x - initial_offx) / initial_zoom
        doc_ay = (press_y - initial_offy) / initial_zoom
        m = controller.model
        m.zoom_level = z_new
        m.view_offset_x = press_x - doc_ax * z_new
        m.view_offset_y = press_y - doc_ay * z_new
        return None

    def doc_pan_apply(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        press_x = eval_number(spec.get("press_x"), store, ctx)
        press_y = eval_number(spec.get("press_y"), store, ctx)
        cursor_x = eval_number(spec.get("cursor_x"), store, ctx)
        cursor_y = eval_number(spec.get("cursor_y"), store, ctx)
        initial_offx = eval_number(spec.get("initial_offx"), store, ctx)
        initial_offy = eval_number(spec.get("initial_offy"), store, ctx)
        m = controller.model
        m.view_offset_x = initial_offx + (cursor_x - press_x)
        m.view_offset_y = initial_offy + (cursor_y - press_y)
        return None

    def doc_zoom_fit_rect(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        rx = eval_number(spec.get("rect_x"), store, ctx)
        ry = eval_number(spec.get("rect_y"), store, ctx)
        rw = eval_number(spec.get("rect_w"), store, ctx)
        rh = eval_number(spec.get("rect_h"), store, ctx)
        padding = eval_number(spec.get("padding"), store, ctx)
        _fit_rect_into_viewport(rx, ry, rw, rh, padding)
        return None

    def doc_zoom_fit_marquee(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        press_x = eval_number(spec.get("press_x"), store, ctx)
        press_y = eval_number(spec.get("press_y"), store, ctx)
        cursor_x = eval_number(spec.get("cursor_x"), store, ctx)
        cursor_y = eval_number(spec.get("cursor_y"), store, ctx)
        mx = min(press_x, cursor_x)
        my = min(press_y, cursor_y)
        mw = abs(press_x - cursor_x)
        mh = abs(press_y - cursor_y)
        if mw < 10 or mh < 10:
            return None
        m = controller.model
        z, px, py = m.zoom_level, m.view_offset_x, m.view_offset_y
        _fit_rect_into_viewport((mx - px) / z, (my - py) / z,
                                mw / z, mh / z, 0.0)
        return None

    def doc_zoom_fit_elements(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        padding = eval_number(spec.get("padding"), store, ctx)
        m = controller.model
        bx, by, bw, bh = _document_bounds(m._document)
        if bw <= 0 or bh <= 0:
            m.zoom_level = 1.0
            m.view_offset_x = m.viewport_w / 2.0
            m.view_offset_y = m.viewport_h / 2.0
        else:
            _fit_rect_into_viewport(bx, by, bw, bh, padding)
        return None

    def doc_zoom_fit_all_artboards(spec, ctx, store):
        if not isinstance(spec, dict):
            return None
        padding = eval_number(spec.get("padding"), store, ctx)
        abs_list = list(controller.document.artboards)
        if not abs_list:
            return None
        min_x = float("inf")
        min_y = float("inf")
        max_x = float("-inf")
        max_y = float("-inf")
        for ab in abs_list:
            min_x = min(min_x, float(ab.x))
            min_y = min(min_y, float(ab.y))
            max_x = max(max_x, float(ab.x + ab.width))
            max_y = max(max_y, float(ab.y + ab.height))
        _fit_rect_into_viewport(
            min_x, min_y, max_x - min_x, max_y - min_y, padding)
        return None

    effects["doc.snapshot"] = doc_snapshot
    effects["doc.clear_selection"] = doc_clear_selection
    effects["doc.set_selection"] = doc_set_selection
    effects["doc.add_to_selection"] = doc_add_to_selection
    effects["doc.toggle_selection"] = doc_toggle_selection
    effects["doc.translate_selection"] = doc_translate_selection
    effects["doc.set_attr_on_selection"] = doc_set_attr_on_selection
    effects["data.set"] = data_set
    effects["data.list_append"] = data_list_append
    effects["data.list_remove"] = data_list_remove
    effects["data.list_insert"] = data_list_insert
    effects["brush.delete_selected"] = brush_delete_selected
    effects["brush.duplicate_selected"] = brush_duplicate_selected
    effects["brush.append"] = brush_append
    effects["brush.update"] = brush_update
    effects["brush.options_confirm"] = brush_options_confirm
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
    effects["doc.magic_wand.apply"] = doc_magic_wand_apply
    effects["doc.scale.apply"] = doc_scale_apply
    effects["doc.rotate.apply"] = doc_rotate_apply
    effects["doc.shear.apply"] = doc_shear_apply
    effects["doc.preview.capture"] = doc_preview_capture
    effects["doc.preview.restore"] = doc_preview_restore
    effects["doc.preview.clear"] = doc_preview_clear
    effects["doc.paintbrush.edit_start"] = doc_paintbrush_edit_start
    effects["doc.paintbrush.edit_commit"] = doc_paintbrush_edit_commit
    effects["doc.blob_brush.commit_painting"] = doc_blob_brush_commit_painting
    effects["doc.blob_brush.commit_erasing"] = doc_blob_brush_commit_erasing
    effects["doc.path.probe_anchor_hit"] = doc_path_probe_anchor_hit
    effects["doc.path.commit_anchor_edit"] = doc_path_commit_anchor_edit
    effects["doc.move_path_handle"] = doc_move_path_handle
    effects["doc.path.commit_partial_marquee"] = doc_path_commit_partial_marquee
    effects["doc.path.probe_partial_hit"] = doc_path_probe_partial_hit
    # View-state effects per ZOOM_TOOL.md and HAND_TOOL.md.
    effects["doc.zoom.apply"] = doc_zoom_apply
    effects["doc.zoom.set"] = doc_zoom_set
    effects["doc.zoom.set_full"] = doc_zoom_set_full
    effects["doc.zoom.scrubby"] = doc_zoom_scrubby
    effects["doc.pan.apply"] = doc_pan_apply
    effects["doc.zoom.fit_rect"] = doc_zoom_fit_rect
    effects["doc.zoom.fit_marquee"] = doc_zoom_fit_marquee
    effects["doc.zoom.fit_elements"] = doc_zoom_fit_elements
    effects["doc.zoom.fit_all_artboards"] = doc_zoom_fit_all_artboards
    return effects
