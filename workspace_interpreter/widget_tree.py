"""Shared canonical panel widget-TREE snapshot pass (TESTING_STRATEGY.md §4).

The structural sibling of ``panel_layout.layout_panel``.  Where the layout pass
computes per-widget *rects*, this pass emits a per-widget *structural record*,
byte-identical across all four native apps, so the panel widget tree itself —
its shape, kinds, and which widgets dispatch vs. fall to a placeholder — is a
cross-app byte-gate instead of five framework renderings eyeballed side by side.

It closes the panel-bug classes that are about *structure* rather than geometry:

  - **widget missing** — a declared widget that an app drops surfaces as a row
    that exists in the golden but not the app's output (or vice-versa).
  - **wrong kind / placeholder** — a widget whose ``type:`` is outside the
    canonical vocabulary renders as a placeholder box in every app; here it is
    recorded as ``kind: "placeholder"`` (≠ its declared ``type``), visible as
    data with no rendering.
  - **statically hidden** — a ``visible: false`` widget is *recorded* (not
    dropped, unlike the layout pass) with ``visible: false``, so "the widget is
    missing because it was wrongly hidden" is catchable.

Determinism / portability (the same contract as ``panel_layout``):

  - Every field is read straight from the compiled bundle; the ONLY expression
    evaluated is a ``foreach`` source (to know how many expansions) — the exact
    same evaluation ``layout_panel`` already does and the panel_layout corpus
    already pins, so no new cross-language eval surface is introduced.
  - ``bind`` / ``style`` record the SORTED KEY SETS (not the expressions/values),
    so the snapshot captures structure without depending on per-value formatting.

Output is a pre-order (parent before children) list of records; ``path`` is the
node's tree path relative to the panel content root (root = ``[]``, its i-th
declared child = ``[i]``, a foreach's i-th expansion = ``[..., i]``) — the same
path scheme as ``panel_layout`` except that statically-hidden children are kept.
"""
from __future__ import annotations

from .expr import evaluate

# Canonical widget-kind vocabulary: the union of kinds rendered by at least one
# app's panel/dialog dispatch.  THIS is the single source of truth (the widget-
# kind coverage gate imports it); the four native widget_tree ports each bake a
# copy, and the panel_widget_tree.json golden enforces that they stay in sync —
# a drifted copy changes a `kind` from its `type` to "placeholder" (or back) and
# reddens the cross-app gate.
CANONICAL_WIDGET_KINDS = frozenset({
    "container", "row", "col", "grid",
    "text", "button", "icon", "icon_button", "icon_select",
    "slider", "number_input", "text_input", "length_input",
    "toggle", "checkbox", "select", "combo_box", "dropdown",
    "color_swatch", "color_gradient", "color_hue_bar", "color_bar",
    "radio_group", "radio", "gradient_tile", "gradient_slider",
    "separator", "spacer", "disclosure", "panel",
    "fill_stroke_widget", "tree_view", "element_preview", "tabs",
    "icon_button_group", "reference_point_widget",
    "brush_preview",
    "placeholder",
})


def widget_tree(panel_node: dict, ctx: dict | None = None) -> list[dict]:
    """Walk a compiled panel node into a pre-order list of structural records.

    ``ctx`` is the data scope (``state`` / ``panel`` / ``data`` /
    ``active_document`` namespaces) used only to evaluate ``foreach`` sources;
    defaults to empty (a foreach over an undefined source expands to nothing).
    """
    root = panel_node.get("content")
    if not isinstance(root, dict):
        return []
    out: list[dict] = []
    _walk(root, [], ctx or {}, out)
    return out


def _record(node: dict, path: list[int]) -> dict:
    """The structural record for one widget node (no recursion)."""
    t = node.get("type")
    t = t if isinstance(t, str) else ""
    nid = node.get("id")
    nid = nid if isinstance(nid, str) else ""
    kind = t if t in CANONICAL_WIDGET_KINDS else "placeholder"
    col = int(node["col"]) if isinstance(node.get("col"), (int, float)) else 0
    # `visible` is the static literal only (false iff `visible: false`); a
    # string `visible:` expr or a `bind.visible` is dynamic — recorded as
    # `dyn_visible` rather than evaluated, so the snapshot stays eval-free.
    v = node.get("visible")
    visible = False if v is False else True
    bind = node.get("bind")
    style = node.get("style")
    dyn_visible = (isinstance(v, str)
                   or (isinstance(bind, dict) and "visible" in bind))
    return {
        "path": list(path),
        "type": t,
        "id": nid,
        "kind": kind,
        "col": col,
        "visible": visible,
        "dyn_visible": bool(dyn_visible),
        "bind": sorted(bind.keys()) if isinstance(bind, dict) else [],
        "style": sorted(style.keys()) if isinstance(style, dict) else [],
    }


def _walk(node: dict, path: list[int], ctx: dict, out: list[dict]) -> None:
    out.append(_record(node, path))
    # A foreach container expands its `do` template once per item of
    # evaluate(foreach.source, ctx) — mirrors panel_layout._foreach exactly so
    # the expansion count (and thus the path set) is identical to the rects.
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
    # A plain container recurses its declared children. Unlike the layout pass
    # (which drops `visible: false`), every dict child is kept and recorded so a
    # wrongly-hidden widget is catchable; non-dict entries (e.g. a stray string)
    # occupy their index but emit nothing, matching the layout pass's skip.
    for i, child in enumerate(node.get("children") or []):
        if isinstance(child, dict):
            _walk(child, path + [i], ctx, out)
