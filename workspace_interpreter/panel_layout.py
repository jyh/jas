"""Shared canonical panel widget-layout pass (Path B).

A pure, integer-arithmetic layout of a compiled panel node into widget
rects, byte-identical across all five apps.  This is the language-neutral
"layout truth": every app consumes these rects rather than delegating
intra-panel layout to its own GUI framework (Qt / GTK / AppKit / Dioxus /
CSS), which is the cross-app drift surface Path B exists to kill.

The full contract is PATH_B_DESIGN.md Appendix A.  Key invariants:

  - ALL arithmetic is integer; there is no float anywhere, so the four
    native implementations are byte-identical and the corpus
    (test_fixtures/algorithms/panel_layout.json) needs no tolerance.
  - text / intrinsic widths use the deterministic stub measure
    ``len(text) * CHAR_WIDTH`` (CHAR_WIDTH = 10) instead of real font
    metrics, so rects are portable.
  - columns use the Bootstrap-12 rule ``cell_w = round_half_up(inner_w *
    N / 12)`` implemented as the exact integer ``(2*inner_w*N + 12) // 24``.

Output is a pre-order (parent before children) list of
``{"path": [int, ...], "rect": {"x","y","w","h": int}}`` where ``path`` is
the element's tree path relative to the panel content root (root = ``[]``,
its i-th child = ``[i]``) and rects are panel-relative.
"""
from __future__ import annotations

from typing import Any

CHAR_WIDTH = 10  # stub glyph advance; integer so text widths are exact

_CONTAINER_TYPES = ("container", "row", "col", "panel")

# Leaf kinds that take the available width handed to them (fill their cell
# in a grid, or the inner width in a column).  Everything else is an inline
# leaf taking its intrinsic width, left-aligned.
_FILL_KINDS = frozenset({
    "select", "number_input", "text_input", "length_input",
    "slider", "placeholder", "separator",
    "combo_box", "icon_select", "spacer",
    # Composite / data-driven widgets: the layout pass places the widget BOX at
    # a canonical fixed height (fill width); the widget renders its own internals
    # and any data-driven rows (a separate concern needing a data fixture).
    "color_bar", "fill_stroke_widget", "gradient_slider", "gradient_tile",
    "dropdown", "tree_view",
})

# Canonical intrinsic heights per widget kind (px).
_KIND_HEIGHT = {
    "text": 20, "button": 24, "checkbox": 20, "icon_button": 24, "icon": 20,
    "select": 20, "number_input": 20, "text_input": 20, "length_input": 20,
    "slider": 12, "placeholder": 40, "separator": 1,
    "combo_box": 20, "icon_select": 20, "spacer": 0, "color_swatch": 16,
    "toggle": 20,
    # composite box heights (provisional — ratified as the corpus broadens)
    "color_bar": 24, "fill_stroke_widget": 44, "gradient_slider": 24,
    "gradient_tile": 24, "dropdown": 20, "tree_view": 200,
}

# Fallback widths for fill kinds when no available width is supplied
# (e.g. a fill leaf inside a flow row, which has no single fill target).
_KIND_FALLBACK_W = {
    "select": 80, "number_input": 45, "text_input": 80, "length_input": 80,
    "slider": 100, "placeholder": 60, "separator": 0,
    "combo_box": 80, "icon_select": 80, "spacer": 0,
    "color_bar": 0, "fill_stroke_widget": 50, "gradient_slider": 0,
    "gradient_tile": 32, "dropdown": 80, "tree_view": 0,
}


def layout_panel(panel_node: dict, avail_w: int) -> list[dict]:
    """Lay out a compiled panel node into widget rects.

    ``panel_node`` is a ``{"type": "panel", "content": <root>}`` object
    from workspace.json; layout starts at ``content`` (path ``[]``).
    """
    root = panel_node.get("content")
    if not isinstance(root, dict):
        return []
    _w, _h, items = _measure(root, [], int(avail_w))
    return [
        {"path": it["path"], "rect": {"x": it["x"], "y": it["y"], "w": it["w"], "h": it["h"]}}
        for it in items
    ]


# ── internals ────────────────────────────────────────────────────────

def _style(node: dict) -> dict:
    s = node.get("style")
    return s if isinstance(s, dict) else {}


def _is_container(node: dict) -> bool:
    return node.get("type") in _CONTAINER_TYPES


def _resolved_layout(node: dict) -> str:
    lay = node.get("layout")
    if lay in ("row", "column"):
        return lay
    return "row" if node.get("type") == "row" else "column"


def _has_col(node: dict) -> bool:
    return node.get("col") is not None


def _text_w(s: str) -> int:
    return len(s) * CHAR_WIDTH


def _parse_padding(v: Any) -> tuple[int, int, int, int]:
    """CSS 1/2/4-value shorthand -> (top, right, bottom, left), ints."""
    if v is None:
        return (0, 0, 0, 0)
    if isinstance(v, (int, float)):
        n = int(v)
        return (n, n, n, n)
    if isinstance(v, str):
        parts = [int(p) for p in v.split()]
    elif isinstance(v, (list, tuple)):
        parts = [int(p) for p in v]
    else:
        return (0, 0, 0, 0)
    if len(parts) == 1:
        n = parts[0]
        return (n, n, n, n)
    if len(parts) == 2:
        vv, hh = parts
        return (vv, hh, vv, hh)
    if len(parts) >= 4:
        return (parts[0], parts[1], parts[2], parts[3])
    return (0, 0, 0, 0)


def _visible_children(node: dict) -> list[tuple[int, dict]]:
    out = []
    for i, c in enumerate(node.get("children") or []):
        if isinstance(c, dict) and c.get("visible") is False:
            continue
        if isinstance(c, dict):
            out.append((i, c))
    return out


def _resolve_dim(v: Any, avail: int) -> int | None:
    """Resolve a style dimension to integer px, or None to ignore.

    Numbers truncate toward zero; ``"N%"`` is N percent of ``avail`` (integer,
    ignored when ``avail <= 0``, e.g. heights, which have no reference); a bare
    numeric string is that int; anything else (``"auto"``, junk) is ignored.
    """
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return int(v)
    if isinstance(v, str):
        s = v.strip()
        if s.endswith("%"):
            num = s[:-1]
            try:
                p = int(num)
            except ValueError:
                try:
                    p = int(float(num))
                except ValueError:
                    return None
            return (avail * p) // 100 if avail > 0 else None
        try:
            return int(float(s))
        except ValueError:
            return None
    return None


def _leaf_size(node: dict, avail_w: int) -> tuple[int, int, bool]:
    """Return (width, height, fill) for a leaf widget."""
    t = node.get("type")
    st = _style(node)
    h = _resolve_dim(st.get("height"), 0)
    if h is None:
        h = _KIND_HEIGHT.get(t, 20)
    fill = t in _FILL_KINDS
    if fill:
        w = avail_w if avail_w > 0 else _KIND_FALLBACK_W.get(t, 0)
    elif t == "text":
        content = node.get("content")
        w = _text_w(content if isinstance(content, str) else "")
    elif t == "button":
        label = node.get("label")
        w = _text_w(label if isinstance(label, str) else "") + 16
    elif t == "checkbox" or t == "toggle":
        label = node.get("label")
        w = 16 + 4 + _text_w(label if isinstance(label, str) else "")
    elif t == "color_swatch":
        w = 16
    elif t == "icon_button":
        w = 24
    elif t == "icon":
        w = 20
    else:
        w = 0
    rw = _resolve_dim(st.get("width"), avail_w)
    if rw is not None:
        w = rw
    rmw = _resolve_dim(st.get("min_width"), avail_w)
    if rmw is not None:
        w = max(w, rmw)
    return (w, h, fill)


def _measure(node: dict, path: list[int], avail_w: int) -> tuple[int, int, list[dict]]:
    """Measure a node at the given available width.

    Returns ``(w, h, items)`` where each item is
    ``{"path", "x", "y", "w", "h"}`` with x/y RELATIVE to this node's
    origin (0, 0); the caller offsets them.  Items are pre-order.
    """
    st = _style(node)
    pt, pr, pb, pl = _parse_padding(st.get("padding"))
    gap = int(st.get("gap") or 0)
    inner_w = avail_w - pl - pr

    if _is_container(node):
        children = _visible_children(node)
        lay = _resolved_layout(node)
        if lay == "row" and any(_has_col(c) for _, c in children):
            ch_items, content_h = _grid(children, path, inner_w, gap)
        elif lay == "row":
            ch_items, content_h = _flow(children, path, inner_w, gap)
        else:
            ch_items, content_h = _column(children, path, inner_w, gap)
        w = avail_w
        h = content_h + pt + pb
        items = [{"path": list(path), "x": 0, "y": 0, "w": w, "h": h}]
        for it in ch_items:
            it["x"] += pl
            it["y"] += pt
            items.append(it)
        return (w, h, items)

    w, h, _fill = _leaf_size(node, avail_w)
    return (w, h, [{"path": list(path), "x": 0, "y": 0, "w": w, "h": h}])


def _column(children, path, inner_w, gap) -> tuple[list[dict], int]:
    items: list[dict] = []
    cy = 0
    n = 0
    for i, c in children:
        _cw, ch, cit = _measure(c, path + [i], inner_w)
        for it in cit:
            it["y"] += cy
        items.extend(cit)
        cy += ch + gap
        n += 1
    return items, (cy - gap if n else 0)


def _flow(children, path, inner_w, gap) -> tuple[list[dict], int]:
    # Measure each child at intrinsic width (fill leaves use fallbacks; a
    # flow row has no single fill target).
    measured = []  # (i, c, w, h, items)
    for i, c in children:
        cw, ch, cit = _measure(c, path + [i], -1)
        measured.append((i, c, cw, ch, cit))
    n = len(measured)
    fixed = sum(m[2] for m in measured) + (gap * (n - 1) if n else 0)
    leftover = max(0, inner_w - fixed)
    weights = []
    for m in measured:
        wt = int(_style(m[1]).get("flex") or 0)
        if wt == 0 and m[1].get("type") == "spacer":
            wt = 1  # a spacer with no explicit flex consumes leftover
        weights.append(wt)
    sumw = sum(weights)
    extra = [0] * n
    if sumw > 0 and leftover > 0:
        base = [leftover * weights[k] // sumw for k in range(n)]
        rem = leftover - sum(base)
        for k in range(n):
            if rem <= 0:
                break
            if weights[k] > 0:
                base[k] += 1
                rem -= 1
        extra = base
    row_h = max((m[3] for m in measured), default=0)
    items: list[dict] = []
    cx = 0
    for k, (i, c, cw, ch, cit) in enumerate(measured):
        fw = cw + extra[k]
        dy = (row_h - ch) // 2
        for it in cit:
            it["x"] += cx
            it["y"] += dy
        # Widen the child's own root rect by any flex extra (subtree not
        # re-laid-out in v1; flow-flex is unused by the seed corpus).
        if extra[k] and cit:
            cit[0]["w"] = fw
        items.extend(cit)
        cx += fw + gap
    return items, row_h


def _grid(children, path, inner_w, gap) -> tuple[list[dict], int]:
    # Wrap into lines so each line's column span sums to <= 12.
    lines: list[list[tuple[int, dict, int]]] = []
    cur: list[tuple[int, dict, int]] = []
    cur_span = 0
    for i, c in children:
        span = int(c.get("col") or 1)
        if cur and cur_span + span > 12:
            lines.append(cur)
            cur = []
            cur_span = 0
        cur.append((i, c, span))
        cur_span += span
    if cur:
        lines.append(cur)

    items: list[dict] = []
    line_y = 0
    for li, line in enumerate(lines):
        cx = 0
        line_h = 0
        cells = []  # (items, h, cell_x)
        for i, c, span in line:
            cell_w = (2 * inner_w * span + 12) // 24  # round-half-up, exact
            _cw, ch, cit = _measure(c, path + [i], cell_w)
            cells.append((cit, ch, cx))
            line_h = max(line_h, ch)
            cx += cell_w + gap
        for cit, ch, cell_x in cells:
            dy = (line_h - ch) // 2
            for it in cit:
                it["x"] += cell_x
                it["y"] += line_y + dy
            items.extend(cit)
        line_y += line_h + gap
    return items, (line_y - gap if lines else 0)
