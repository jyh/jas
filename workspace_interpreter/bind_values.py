"""Shared canonical panel bind-VALUE snapshot pass (TESTING_STRATEGY.md §4).

The third sibling of :mod:`workspace_interpreter.panel_layout` (per-widget
*rects*) and :mod:`workspace_interpreter.widget_tree` (per-widget *structural
records*).  Where those two are deliberately value-blind, this pass RESOLVES the
panel's data bindings and pins the resulting strings.

Why a third pass instead of widening one of the other two:

  * ``widget_tree`` records the sorted KEY NAMES of ``bind`` / ``style`` and
    collapses a dynamic ``visible`` to a ``dyn_visible`` flag, on purpose — its
    contract is "structure without depending on per-value formatting", which is
    what makes it stable.  Widening it would change every record it emits.
  * ``panel_layout`` resolves ``{{ }}`` text but consumes it as
    ``scalar_count(text) * CHAR_WIDTH``, so any two strings of equal length are
    the same rect.

Together those leave the bind-VALUE surface unpinned in every port.  Measured on
the Color panel: the two data scopes that differ only in ``panel.hex`` —
``"664040"`` vs ``"664141"``, the byte pattern of the colour divergence the
corpus census was written to answer — produce IDENTICAL ``widget_tree`` output
and IDENTICAL ``layout_panel`` rects, and differ in exactly one row here.  Both
halves of that are asserted in ``tests/test_bind_values.py`` rather than merely
described.

WHAT IT PINS.  A pre-order list of one record per resolved binding:

    {"path": [int, ...], "id": str, "key": str, "type": str, "value": str}

``path`` is the node's tree path relative to the panel content root, in the same
scheme as ``widget_tree`` (root = ``[]``, i-th declared child = ``[i]``, a
foreach's i-th expansion = ``[..., i]``).  ``key`` names the binding:

  * ``"visible"``      — a dynamic ``visible: <expr>`` string, evaluated and
    coerced through the shared truthiness rule (``Value.to_bool``).  This is one
    of the two forms ``widget_tree`` collapses into ``dyn_visible``.  Counted
    over the compiled bundle's 16 panels: the string form occurs 0 times and
    ``bind.visible`` 13 times (the YAML author writes ``visible: <expr>`` and
    the compiler lands it under ``bind``), so this row is carried for
    completeness and is unexercised by today's corpus.
  * ``"bind.<name>"``  — one row per ``bind`` key, in sorted key order.
  * ``"content"`` / ``"label"`` — a node ``content``/``label`` string containing
    ``{{ }}``, resolved through ``evaluate_text``.  A literal (no ``{{``) is not
    recorded: it is already in the bundle and pinning it would only add churn.

A node with none of the above emits NO row, so the snapshot's size tracks the
panel's binding surface rather than its widget count.

``type`` is the expression-language type of the result (``null``, ``bool``,
``number``, ``string``, ``color``, ``list``, ``path``, ``closure``), which is
what keeps a null distinguishable from an empty string — both render as ``""``.

DETERMINISM.  ``value`` is built only from the string coercion each port already
uses for ``{{ }}`` interpolation — ``Value.to_string`` here,
``Value::to_string_coerce`` in Rust, ``Value.toStringCoerce()`` in Swift — so
this pass adds no new number-formatting surface of its own.  (This port and
Swift factor the number arm out as ``number_to_canonical_string`` /
``numberToCanonicalString``; Rust inlines the same rule in ``expr_types.rs``.
The three agree on every number the corpus reaches, which is what the shared
golden proves.)  Lists are bracketed and
comma-joined element-wise.  A ``bind`` expression whose value is a JSON OBJECT
is coerced to a JSON string by the evaluator itself, and the key order of that
string is a known cross-port divergence (census row #50) — no vector in
``panel_bind_values.json`` binds an object, and one should not be added until
that row closes.
"""
from __future__ import annotations

from .expr import evaluate, evaluate_text
from .expr_types import Value, ValueType

# Expression-language type name per ValueType, used as the record's `type`.
_TYPE_NAMES = {
    ValueType.NULL: "null",
    ValueType.BOOL: "bool",
    ValueType.NUMBER: "number",
    ValueType.STRING: "string",
    ValueType.COLOR: "color",
    ValueType.LIST: "list",
    ValueType.PATH: "path",
    ValueType.CLOSURE: "closure",
}


def canon_value(v: Value) -> tuple[str, str]:
    """The canonical ``(type, value)`` pair for one evaluated value.

    Scalars use the shared interpolation coercion (``Value.to_string``); a list is
    ``"[" + elements joined by "," + "]"`` with each element canonicalized the
    same way (so a nested list nests its brackets).
    """
    if v.type is ValueType.LIST:
        parts = [canon_value(Value.from_python(e))[1] for e in v.value]
        return ("list", "[" + ",".join(parts) + "]")
    return (_TYPE_NAMES.get(v.type, "unknown"), v.to_string())


def bind_values(panel_node: dict, ctx: dict | None = None) -> list[dict]:
    """Walk a compiled panel node into a pre-order list of resolved bindings.

    ``ctx`` is the data scope (``state`` / ``panel`` / ``data`` /
    ``active_document`` namespaces, plus any ``foreach`` item bindings added
    during the walk); defaults to empty, where every binding resolves to null.
    """
    root = panel_node.get("content")
    if not isinstance(root, dict):
        return []
    out: list[dict] = []
    _walk(root, [], ctx or {}, out)
    return out


def _row(path: list[int], node_id: str, key: str, v: Value) -> dict:
    ty, val = canon_value(v)
    return {"path": list(path), "id": node_id, "key": key,
            "type": ty, "value": val}


def _rows_for(node: dict, path: list[int], ctx: dict) -> list[dict]:
    """Every resolved-binding record for one node (no recursion)."""
    nid = node.get("id")
    nid = nid if isinstance(nid, str) else ""
    rows: list[dict] = []
    # A dynamic `visible:` expression, coerced to bool the way the renderers do.
    vis = node.get("visible")
    if isinstance(vis, str):
        rows.append(_row(path, nid, "visible",
                         Value.bool_(evaluate(vis, ctx).to_bool())))
    bind = node.get("bind")
    if isinstance(bind, dict):
        for key in sorted(bind.keys()):
            expr = bind[key]
            if isinstance(expr, str):
                rows.append(_row(path, nid, "bind." + key, evaluate(expr, ctx)))
            else:
                # A non-string `bind` entry is a literal in the bundle; record it
                # through the same coercion so the row shape stays uniform.
                rows.append(_row(path, nid, "bind." + key,
                                 Value.from_python(expr)))
    # `{{ }}`-bearing content / label: the surface panel_layout reduces to a
    # scalar count. A literal string carries no binding and is not recorded.
    for key in ("content", "label"):
        raw = node.get(key)
        if isinstance(raw, str) and "{{" in raw:
            rows.append(_row(path, nid, key,
                             Value.string(evaluate_text(raw, ctx))))
    return rows


def _walk(node: dict, path: list[int], ctx: dict, out: list[dict]) -> None:
    out.extend(_rows_for(node, path, ctx))
    # A foreach container expands its `do` template once per item of
    # evaluate(foreach.source, ctx) — the same expansion widget_tree performs,
    # so a path here names the same node it names there. (panel_layout expands
    # identically but DROPS `visible: false` children, so its path set is a
    # subset.)
    if isinstance(node.get("foreach"), dict) and node.get("do"):
        spec = node.get("foreach") or {}
        src = spec.get("source", "")
        var = spec.get("as", "item")
        template = node.get("do") or {}
        try:
            res = evaluate(src, ctx)
            items = res.value if hasattr(res, "value") else res
        except Exception:
            items = []
        if not isinstance(items, list):
            items = []
        for i, item in enumerate(items):
            item_data = dict(item) if isinstance(item, dict) else {"_value": item}
            item_data["_index"] = i
            child_ctx = dict(ctx)
            child_ctx[var] = item_data
            if isinstance(template, dict):
                _walk(template, path + [i], child_ctx, out)
        return
    # Plain container: recurse every dict child at its declared index, including
    # statically-hidden ones (mirrors widget_tree, not the layout pass) so a
    # binding on a wrongly-hidden widget stays comparable.
    for i, child in enumerate(node.get("children") or []):
        if isinstance(child, dict):
            _walk(child, path + [i], ctx, out)


__all__ = ["bind_values", "canon_value"]
