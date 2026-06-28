"""Shared canonical panel widget-layout pass (Path B).

A pure, integer-arithmetic layout of a compiled panel node into widget
rects, byte-identical across all five apps.  This is the language-neutral
"layout truth": every app consumes these rects rather than delegating
intra-panel layout to its own GUI framework (Qt / GTK / AppKit / Dioxus /
CSS), which is the cross-app drift surface Path B exists to kill.

The full contract is PATH_B_DESIGN.md (Appendix A + Appendix B for foreach).
Key invariants:

  - ALL arithmetic is integer; there is no float anywhere, so the four
    native implementations are byte-identical and the corpus
    (test_fixtures/algorithms/panel_layout.json) needs no tolerance.
  - text / intrinsic widths use the deterministic stub measure
    ``len(text) * CHAR_WIDTH`` (CHAR_WIDTH = 10) instead of real font
    metrics, so rects are portable.  Text ``content`` / ``label`` is first
    resolved through ``evaluate_text`` against the data scope ``ctx`` so a
    bound ``"{{sym.name}}"`` is measured at its resolved value (a literal
    passes through unchanged).
  - columns use the Bootstrap-12 rule ``cell_w = round_half_up(inner_w *
    N / 12)`` implemented as the exact integer ``(2*inner_w*N + 12) // 24``.
  - ``foreach`` containers expand their ``do`` template once per item of
    ``evaluate(foreach.source, ctx)`` (each item bound as ``foreach.as``).
  - a column distributes ``avail_h`` leftover to ``flex``-weighted children
    (vertical flex), so a ``foreach`` list grows to fill the dock height.

Output is a pre-order (parent before children) list of
``{"path": [int, ...], "rect": {"x","y","w","h": int}}`` where ``path`` is
the element's tree path relative to the panel content root (root = ``[]``,
its i-th child = ``[i]``, a foreach's i-th expansion = ``[..., i]``).
"""
from __future__ import annotations

from typing import Any

from .expr import evaluate, evaluate_text

CHAR_WIDTH = 10  # stub glyph advance; integer so text widths are exact

_CONTAINER_TYPES = ("container", "row", "col", "panel")

_FILL_KINDS = frozenset({
    "select", "number_input", "text_input", "length_input",
    "slider", "placeholder", "separator",
    "combo_box", "icon_select", "spacer",
    "color_bar", "fill_stroke_widget", "gradient_slider", "gradient_tile",
    "dropdown", "tree_view",
})

_KIND_HEIGHT = {
    "text": 20, "button": 24, "checkbox": 20, "icon_button": 24, "icon": 20,
    "select": 20, "number_input": 20, "text_input": 20, "length_input": 20,
    "slider": 12, "placeholder": 40, "separator": 1,
    "combo_box": 20, "icon_select": 20, "spacer": 0, "color_swatch": 16,
    "toggle": 20,
    "color_bar": 24, "fill_stroke_widget": 44, "gradient_slider": 24,
    "gradient_tile": 24, "dropdown": 20, "tree_view": 200,
}

_KIND_FALLBACK_W = {
    "select": 80, "number_input": 45, "text_input": 80, "length_input": 80,
    "slider": 100, "placeholder": 60, "separator": 0,
    "combo_box": 80, "icon_select": 80, "spacer": 0,
    "color_bar": 0, "fill_stroke_widget": 50, "gradient_slider": 0,
    "gradient_tile": 32, "dropdown": 80, "tree_view": 0,
}


def layout_panel(panel_node: dict, avail_w: int, avail_h: int = 0,
                 ctx: dict | None = None) -> list[dict]:
    """Lay out a compiled panel node into widget rects.

    ``ctx`` is the data scope (``state`` / ``panel`` / ``data`` /
    ``active_document`` namespaces) used to evaluate ``foreach`` sources and
    text bindings; defaults to empty (literals only). ``avail_h`` drives
    vertical flex; 0 means content-height (no vertical flex).
    """
    root = panel_node.get("content")
    if not isinstance(root, dict):
        return []
    _w, _h, items = _measure(root, [], int(avail_w), int(avail_h), ctx or {})
    return [
        {"path": it["path"], "rect": {"x": it["x"], "y": it["y"], "w": it["w"], "h": it["h"]}}
        for it in items
    ]


# Layout-only node types: they position their children but draw no widget of
# their own in the absolute render (their children are the rendered leaves).
_LAYOUT_CONTAINER_TYPES = frozenset({
    "container", "row", "col", "grid", "panel", "disclosure",
})


def _has_chrome(node: dict) -> bool:
    """A layout-only container still worth drawing — it carries a border /
    background (static or a `bind.background`, e.g. a selected-row highlight)."""
    st = _style(node)
    if isinstance(st, dict) and ("border" in st or "background" in st or "bg" in st):
        return True
    b = node.get("bind")
    return isinstance(b, dict) and "background" in b


def render_plan(panel_node: dict, avail_w: int, avail_h: int = 0,
                ctx: dict | None = None) -> dict:
    """Render-side projection of the same layout pass. Returns
    ``{"height", "chrome": [...], "leaves": [...]}`` where each entry is
    ``{"rect", "node", "ctx"}``: ``leaves`` are renderable widgets (each with the
    per-row child scope, so foreach rows resolve) and ``chrome`` are layout-only
    containers that carry a border/background to draw BEHIND the leaves (e.g. a
    selected-row highlight). ``height`` is the canonical panel content height.
    Layout-only containers without chrome are omitted. ``layout_panel`` is
    unchanged (rects only) so the cross-app byte-gate stays byte-exact — one
    traversal, two projections.
    """
    root = panel_node.get("content")
    if not isinstance(root, dict):
        return {"height": 0, "chrome": [], "leaves": []}
    _w, _h, items = _measure(root, [], int(avail_w), int(avail_h), ctx or {})
    height = items[0]["h"] if items else 0
    chrome = []
    leaves = []
    for it in items:
        node = it.get("node")
        if not isinstance(node, dict):
            continue
        entry = {
            "rect": {"x": it["x"], "y": it["y"], "w": it["w"], "h": it["h"]},
            "node": node,
            "ctx": it.get("ctx") or {},
        }
        if node.get("type") in _LAYOUT_CONTAINER_TYPES:
            if _has_chrome(node):
                chrome.append(entry)
        else:
            leaves.append(entry)
    return {"height": height, "chrome": chrome, "leaves": leaves}


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


def _text_w(node: dict, key: str, ctx: dict) -> int:
    """Resolved text width: evaluate_text(node[key], ctx) length * CHAR_WIDTH."""
    raw = node.get(key)
    if not isinstance(raw, str):
        return 0
    try:
        resolved = evaluate_text(raw, ctx)
    except Exception:
        resolved = raw
    return len(resolved) * CHAR_WIDTH


def _resolve_dim(v: Any, avail: int) -> int | None:
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


def _parse_padding(v: Any) -> tuple[int, int, int, int]:
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


def _gap(node: dict) -> int:
    g = _style(node).get("gap")
    return int(g) if isinstance(g, (int, float)) else 0


def _flex(node: dict) -> int:
    f = _style(node).get("flex")
    w = int(f) if isinstance(f, (int, float)) else 0
    if w == 0 and node.get("type") == "spacer":
        w = 1
    return w


def _leaf_size(node: dict, avail_w: int, ctx: dict) -> int:
    """Return width for a leaf widget (height handled by the caller)."""
    t = node.get("type")
    st = _style(node)
    if t in _FILL_KINDS:
        w = avail_w if avail_w > 0 else _KIND_FALLBACK_W.get(t, 0)
    elif t == "text":
        w = _text_w(node, "content", ctx)
    elif t == "button":
        w = _text_w(node, "label", ctx) + 16
    elif t in ("checkbox", "toggle"):
        w = 16 + 4 + _text_w(node, "label", ctx)
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
    return w


def _leaf_h(node: dict) -> int:
    t = node.get("type")
    h = _resolve_dim(_style(node).get("height"), 0)
    return h if h is not None else _KIND_HEIGHT.get(t, 20)


def _grid_lines(children: list) -> list[list]:
    """Group ``(i, node)`` children into Bootstrap-12 rows by their ``col`` span."""
    lines: list[list] = []
    cur: list = []
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
    return lines


def _natural_w(node: dict, ctx: dict) -> int:
    """Min-content width a node wants, ignoring the width available to it.

    A leaf reports its own intrinsic width; a container reports the width its
    content needs (row = sum of children + gaps, column = widest child, grid =
    widest 12-col line). Used so a row can grow cells / columns to fit nested
    content and shrink-to-fit deterministically when over-subscribed, instead
    of letting a wide label or input overrun its neighbour.
    """
    if not (_is_container(node) or node.get("type") == "disclosure"):
        return _leaf_size(node, -1, ctx)
    st = _style(node)
    _pt, pr, _pb, pl = _parse_padding(st.get("padding"))
    gap = _gap(node)
    if node.get("type") == "disclosure":
        kids = _visible_children(node)
        inner = max((_natural_w(c, ctx) for _, c in kids), default=0)
        return inner + pl + pr
    if isinstance(node.get("foreach"), dict) and node.get("do"):
        return _natural_w(node["do"], ctx) + pl + pr
    kids = _visible_children(node)
    lay = _resolved_layout(node)
    if lay == "row" and any(_has_col(c) for _, c in kids):
        best = 0
        for line in _grid_lines(kids):
            m = len(line)
            line_w = sum(_natural_w(c, ctx) for _, c, _span in line) + gap * (m - 1 if m else 0)
            best = max(best, line_w)
        return best + pl + pr
    if lay == "row":
        n = len(kids)
        tot = sum(_natural_w(c, ctx) for _, c in kids) + (gap * (n - 1) if n else 0)
        return tot + pl + pr
    inner = max((_natural_w(c, ctx) for _, c in kids), default=0)
    return inner + pl + pr


def _measure(node: dict, path: list[int], avail_w: int, avail_h: int,
             ctx: dict) -> tuple[int, int, list[dict]]:
    """Measure a node; return (w, h, items) with item coords relative to it."""
    st = _style(node)
    pt, pr, pb, pl = _parse_padding(st.get("padding"))
    gap = _gap(node)
    inner_w = avail_w - pl - pr
    inner_h = (avail_h - pt - pb) if avail_h > 0 else 0

    if _is_container(node) or node.get("type") == "disclosure":
        if node.get("type") == "disclosure":
            ch_items, content_h = _disclosure(node, path, inner_w, gap, ctx)
        elif isinstance(node.get("foreach"), dict) and node.get("do"):
            ch_items, content_h = _foreach(node, path, inner_w, gap, ctx)
        else:
            children = _visible_children(node)
            lay = _resolved_layout(node)
            if lay == "row" and any(_has_col(c) for _, c in children):
                ch_items, content_h = _grid(children, path, inner_w, gap, ctx)
            elif lay == "row":
                ch_items, content_h = _flow(children, path, inner_w, gap, ctx)
            else:
                ch_items, content_h = _column(children, path, inner_w, gap, inner_h, ctx)
        exp_h = _resolve_dim(st.get("height"), 0)
        # Fill the width given; with no constraint (avail_w <= 0) report the
        # container's natural content width so a parent row can size it.
        w = avail_w if avail_w > 0 else _natural_w(node, ctx)
        h = exp_h if exp_h is not None else content_h + pt + pb
        items = [{"path": list(path), "x": 0, "y": 0, "w": w, "h": h, "node": node, "ctx": ctx}]
        for it in ch_items:
            it["x"] += pl
            it["y"] += pt
            items.append(it)
        return (w, h, items)

    w = _leaf_size(node, avail_w, ctx)
    # A leaf renders at its own width regardless of its slot; clamp it to the
    # width available so it cannot overrun a neighbour (text/labels may clip).
    if avail_w > 0 and w > avail_w:
        w = avail_w
    h = _leaf_h(node)
    return (w, h, [{"path": list(path), "x": 0, "y": 0, "w": w, "h": h, "node": node, "ctx": ctx}])


def _column(children, path, inner_w, gap, avail_h, ctx) -> tuple[list[dict], int]:
    measured = []  # (node, height, items)
    for i, c in children:
        _cw, ch, cit = _measure(c, path + [i], inner_w, 0, ctx)
        measured.append((c, ch, cit))
    n = len(measured)
    natural = sum(m[1] for m in measured) + (gap * (n - 1) if n else 0)
    extra = [0] * n
    if avail_h > 0:
        leftover = avail_h - natural
        if leftover > 0:
            weights = [_flex(m[0]) for m in measured]
            sumw = sum(weights)
            if sumw > 0:
                base = [leftover * weights[k] // sumw for k in range(n)]
                rem = leftover - sum(base)
                for k in range(n):
                    if rem <= 0:
                        break
                    if weights[k] > 0:
                        base[k] += 1
                        rem -= 1
                extra = base
    items: list[dict] = []
    cy = 0
    for k, (_c, ch, cit) in enumerate(measured):
        hk = ch + extra[k]
        for it in cit:
            it["y"] += cy
        if extra[k] and cit:
            cit[0]["h"] = hk
        items.extend(cit)
        cy += hk + gap
    return items, (cy - gap if n else 0)


def _flow(children, path, inner_w, gap, ctx) -> tuple[list[dict], int]:
    n = len(children)
    nat = [_natural_w(c, ctx) for _i, c in children]
    weights = [_flex(c) for _i, c in children]
    sumw = sum(weights)
    fixed = sum(nat) + (gap * (n - 1) if n else 0)
    widths = list(nat)
    if inner_w > 0 and fixed > inner_w:
        # Over-subscribed: shrink every cell proportionally to fit the row, then
        # hand out the rounding remainder one pixel at a time (deterministic).
        avail = inner_w - gap * (n - 1 if n else 0)
        total = sum(nat)
        if total > 0 and avail > 0:
            widths = [w * avail // total for w in nat]
            rem = avail - sum(widths)
            k = 0
            while rem > 0 and n:
                widths[k] += 1
                rem -= 1
                k = (k + 1) % n
    elif inner_w > 0 and sumw > 0:
        # Fits: distribute the leftover width to flex-weighted children.
        leftover = inner_w - fixed
        if leftover > 0:
            base = [leftover * weights[k] // sumw for k in range(n)]
            rem = leftover - sum(base)
            for k in range(n):
                if rem <= 0:
                    break
                if weights[k] > 0:
                    base[k] += 1
                    rem -= 1
            widths = [nat[k] + base[k] for k in range(n)]
    # Lay each child out at its final width; a leaf already clamps itself to the
    # width it is given (see _measure), so nothing overruns the next cell.
    placed = []
    row_h = 0
    for k, (i, c) in enumerate(children):
        _cw, ch, cit = _measure(c, path + [i], widths[k], 0, ctx)
        if cit and cit[0]["w"] > widths[k]:
            cit[0]["w"] = widths[k]
        placed.append((cit, ch))
        row_h = max(row_h, ch)
    items: list[dict] = []
    cx = 0
    for k, (cit, ch) in enumerate(placed):
        dy = (row_h - ch) // 2
        for it in cit:
            it["x"] += cx
            it["y"] += dy
        items.extend(cit)
        cx += widths[k] + gap
    return items, row_h


def _grid(children, path, inner_w, gap, ctx) -> tuple[list[dict], int]:
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
    for line in lines:
        n = len(line)
        # Each cell wants at least its Bootstrap-12 share, grown to fit its
        # content's intrinsic width: a leaf renders at its own width regardless
        # of how narrow its column is, so a wide label / icon must not overrun
        # its neighbour. Layout containers fill their cell, so they contribute
        # no intrinsic minimum (they shrink/grow with the cell).
        desired = []
        for i, c, span in line:
            bw = (2 * inner_w * span + 12) // 24
            desired.append(max(bw, _natural_w(c, ctx)))
        avail = inner_w - gap * (n - 1)
        total = sum(desired)
        if total <= avail or total <= 0:
            widths = desired
        else:
            # Over-subscribed row: shrink cells proportionally to fit, then
            # hand the rounding remainder out one pixel at a time (deterministic
            # so every app produces byte-identical rects).
            widths = [d * avail // total for d in desired]
            rem = avail - sum(widths)
            k = 0
            while rem > 0:
                widths[k] += 1
                rem -= 1
                k = (k + 1) % n
        cx = 0
        line_h = 0
        cells = []
        for (i, c, span), cell_w in zip(line, widths):
            _cw, ch, cit = _measure(c, path + [i], cell_w, 0, ctx)
            # Clamp the child to its cell so it cannot overrun the next column.
            if cit and cit[0]["w"] > cell_w:
                cit[0]["w"] = cell_w
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


_DISCLOSURE_HEADER_H = 24  # canonical disclosure header bar height


def _disclosure(node, path, inner_w, gap, ctx) -> tuple[list[dict], int]:
    """A disclosure is a header bar (the bound label) + a body. v1 lays out the
    body (children, column) below a fixed-height header (assumed expanded); the
    header is drawn by the widget itself (no separate rect). The body's inner
    foreach (swatch / brush grids) expands through the normal recursion.
    """
    children = _visible_children(node)
    ch_items, body_h = _column(children, path, inner_w, gap, 0, ctx)
    for it in ch_items:
        it["y"] += _DISCLOSURE_HEADER_H
    return ch_items, _DISCLOSURE_HEADER_H + body_h


def _foreach(node, path, inner_w, gap, ctx) -> tuple[list[dict], int]:
    """Expand a foreach container's `do` template once per item, laid out per
    the container's `layout`: ``column`` (vertical stack), ``row`` (horizontal,
    single line), or ``wrap`` (horizontal, wrapping at ``inner_w``).

    Each item is bound as ``foreach.as`` (plus ``_index``) in a child scope.
    Row/wrap items are measured at intrinsic width; ``item_w`` is the subtree's
    actual extent (so a container item gets its content width, not the unbounded
    sentinel), and the item's own rect width is corrected to that extent.
    """
    spec = node.get("foreach") or {}
    src = spec.get("source", "")
    var = spec.get("as", "item")
    template = node.get("do") or {}
    lay = node.get("layout") or "column"
    try:
        res = evaluate(src, ctx)
        items = res.value if hasattr(res, "value") else res
    except Exception:
        items = []
    if not isinstance(items, list):
        items = []

    # Measure every expansion (column fills inner_w; row/wrap are intrinsic).
    avail = inner_w if lay == "column" else -1
    measured = []  # (item_w, item_h, items)
    for i, item in enumerate(items):
        item_data = dict(item) if isinstance(item, dict) else {"_value": item}
        item_data["_index"] = i
        child_ctx = dict(ctx)
        child_ctx[var] = item_data
        w, h, cit = _measure(template, path + [i], avail, 0, child_ctx)
        if lay != "column":
            iw = max((it["x"] + it["w"] for it in cit), default=0)
            if cit:
                cit[0]["w"] = iw
            w = iw
        measured.append((w, h, cit))

    out: list[dict] = []
    if lay == "row":
        row_h = max((m[1] for m in measured), default=0)
        cx = 0
        for w, h, cit in measured:
            dy = (row_h - h) // 2
            for it in cit:
                it["x"] += cx
                it["y"] += dy
            out.extend(cit)
            cx += w + gap
        return out, row_h
    if lay == "wrap":
        cx = 0
        line_y = 0
        line_h = 0
        for w, h, cit in measured:
            if cx > 0 and cx + w > inner_w:
                line_y += line_h + gap
                cx = 0
                line_h = 0
            for it in cit:
                it["x"] += cx
                it["y"] += line_y
            out.extend(cit)
            cx += w + gap
            line_h = max(line_h, h)
        return out, (line_y + line_h if measured else 0)
    # column
    cy = 0
    for w, h, cit in measured:
        for it in cit:
            it["y"] += cy
        out.extend(cit)
        cy += h + gap
    return out, (cy - gap if measured else 0)
