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

from document.controller import Controller
from document.document import (
    Document,
    ElementPath,
    ElementSelection,
    Selection,
)
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

    effects["doc.snapshot"] = doc_snapshot
    effects["doc.clear_selection"] = doc_clear_selection
    effects["doc.set_selection"] = doc_set_selection
    effects["doc.add_to_selection"] = doc_add_to_selection
    effects["doc.toggle_selection"] = doc_toggle_selection
    effects["doc.translate_selection"] = doc_translate_selection
    effects["doc.copy_selection"] = doc_copy_selection
    effects["doc.select_in_rect"] = doc_select_in_rect
    effects["doc.partial_select_in_rect"] = doc_partial_select_in_rect
    return effects
