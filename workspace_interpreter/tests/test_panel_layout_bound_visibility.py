"""Two row laws the Layers indent needed (flask STATUS §603, §617, §618).

1. A child hidden by a dynamic visibility (``bind.visible`` or a string
   ``visible:`` that evaluates false in its scope) takes no space and gets no
   rect, as a static ``visible: false`` already did (CSS ``display: none``).
   The Layers row laid out ``lp_name_edit`` beside ``lp_name`` on every row,
   so the row was over-subscribed and the shrink squeezed the indent.
2. A spacer that declares ``style.width`` keeps that width; only a spacer
   with no width fills the leftover. Once the row fit, the indent spacer's
   default flex grew it on every short row.

Synthetic panels; the shipped cases are pinned by ``panel_layout.json``'s
``layers@228``, ``artboards@228``, ``concepts@228`` and ``color@228``, which
Rust and Swift replay.
"""

from workspace_interpreter.panel_layout import layout_panel


def _rects(content, ctx, avail_w=200):
    return {tuple(r["path"]): r["rect"]
            for r in layout_panel({"content": content}, avail_w, 0, ctx)}


def _row(*children):
    return {"type": "container", "layout": "row", "children": list(children)}


def _box(w, **extra):
    return {"type": "icon_button", "style": {"size": w}, **extra}


# ── law 1: a hidden child takes no space ──────────────────────────────

def test_a_static_hidden_child_is_the_control():
    r = _rects(_row(_box(16, visible=False), _box(16)), {})
    assert (0,) not in r
    assert r[(1,)]["x"] == 0


def test_a_bind_visible_false_child_takes_no_space():
    r = _rects(_row(_box(16, bind={"visible": "flag"}), _box(16)), {"flag": False})
    assert (0,) not in r
    assert r[(1,)]["x"] == 0


def test_a_bind_visible_true_child_keeps_its_space():
    r = _rects(_row(_box(16, bind={"visible": "flag"}), _box(16)), {"flag": True})
    assert r[(0,)]["w"] == 16
    assert r[(1,)]["x"] == 16


def test_a_string_visible_false_child_takes_no_space():
    r = _rects(_row(_box(16, visible="flag"), _box(16)), {"flag": False})
    assert (0,) not in r
    assert r[(1,)]["x"] == 0


def test_visibility_is_evaluated_per_foreach_row():
    panel = {"type": "container", "foreach": {"source": "rows", "as": "node"},
             "do": _row(_box(16, bind={"visible": "node.on"}), _box(16))}
    r = _rects(panel, {"rows": [{"on": True}, {"on": False}]})
    assert r[(0, 1)]["x"] == 16
    assert r[(1, 1)]["x"] == 0
    assert (1, 0) not in r


def test_a_hidden_sibling_no_longer_squeezes_a_fixed_child():
    # 32 + 16 + a 100 px name fit 200; the 80 px rename field beside them
    # does not. Hidden, it must not squeeze the fixed 32 px indent (the
    # Layers row). The renaming row is the control: it IS over-subscribed.
    name = {"type": "text", "content": "x" * 10, "style": {"flex": 1}}
    edit = {"type": "text_input", "style": {"flex": 1},
            "bind": {"visible": "renaming"}}
    row = _row({"type": "spacer", "style": {"width": 32}}, _box(16), name, edit)
    assert _rects(row, {"renaming": True})[(1,)]["x"] < 32
    r = _rects(row, {"renaming": False})
    assert (3,) not in r
    assert r[(1,)]["x"] == 32


# ── law 2: a spacer with a declared width does not flex ───────────────

def test_an_undeclared_spacer_still_fills_the_leftover():
    r = _rects(_row(_box(16), {"type": "spacer"}, _box(16)), {})
    assert r[(2,)]["x"] == 200 - 16


def test_a_declared_width_spacer_keeps_its_width_on_a_short_row():
    r = _rects(_row({"type": "spacer", "style": {"width": 16}}, _box(16)), {})
    assert r[(1,)]["x"] == 16


def test_a_templated_width_spacer_keeps_its_width_on_a_short_row():
    row = _row({"type": "spacer", "style": {"width": "{{node.depth * 16}}"}}, _box(16))
    for depth in (0, 1, 2):
        r = _rects(row, {"node": {"depth": depth}})
        assert r[(1,)]["x"] == depth * 16, depth
