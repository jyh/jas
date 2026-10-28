"""A leaf's ``style.width`` may be a template (``"{{node.depth * 16}}"``, the
Layers row's indent spacer, STATUS-jas item 38): the layout pass evaluates it
in the leaf's own scope, as it already does a bound text, and lays out the
number. Until then the pass could not parse it, so the indent read 1-2 px at
every depth.

Synthetic panels; the shipped case is pinned by ``panel_layout.json``'s
``layers@228``, which Rust and Swift replay.
"""

from workspace_interpreter.panel_layout import layout_panel


def _row(depth_expr):
    return {"type": "container", "layout": "row", "children": [
        {"type": "spacer", "style": {"width": depth_expr}},
        {"type": "text", "content": "x"},
    ]}


def _rects(content, ctx, avail_w=200):
    return {tuple(r["path"]): r["rect"] for r in layout_panel({"content": content}, avail_w, 0, ctx)}


def test_a_literal_width_is_the_control():
    r = _rects(_row(32), {})
    assert r[(0,)]["w"] == 32


def test_a_templated_width_is_evaluated_in_the_leafs_scope():
    for depth in (0, 1, 2):
        r = _rects(_row("{{node.depth * 16}}"), {"node": {"depth": depth}})
        assert r[(0,)]["w"] == depth * 16, depth


def test_a_foreach_row_evaluates_the_width_per_row():
    panel = {"type": "container", "foreach": {"source": "rows", "as": "node"},
             "do": _row("{{node.depth * 16}}")}
    r = _rects(panel, {"rows": [{"depth": 0}, {"depth": 2}, {"depth": 1}]})
    assert [r[(i, 0)]["w"] for i in range(3)] == [0, 32, 16]


def test_a_template_that_does_not_resolve_to_a_number_is_ignored():
    r = _rects(_row("{{node.missing}}"), {"node": {}})
    assert r[(0,)]["w"] == _rects(_row(None), {})[(0,)]["w"]
