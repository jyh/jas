"""The Layers tree's row template, expanded by the plan (STATUS-jas item 38
step 3): its binds read each row's PATH, because element ids are optional and
every row in the shared fixture has none.

flask §602 measured the defect this pins, on the box: with nothing renaming,
every row showed its rename box and no name, because `lp_name_edit`'s
`visible` compared `panel.renaming_element` (null) with `node.id` (null).
"""

from __future__ import annotations

import json
import os

from workspace_interpreter.expr import evaluate

_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")


def _panel():
    with open(os.path.join(_ROOT, "workspace", "workspace.json"), encoding="utf-8") as f:
        return json.load(f)["panels"]["layers_panel_content"]


def _rows():
    with open(os.path.join(_ROOT, "test_fixtures", "layers/element_tree.json"), encoding="utf-8") as f:
        return json.load(f)["cases"][0]["expected"]


def _tree():
    def find(n):
        if isinstance(n, dict):
            if n.get("id") == "lp_tree":
                return n
            for v in n.values():
                hit = find(v)
                if hit:
                    return hit
        elif isinstance(n, list):
            for v in n:
                hit = find(v)
                if hit:
                    return hit
        return None
    return find(_panel())


def _widget(template, widget_id):
    for c in template.get("children", []):
        if c.get("id") == widget_id:
            return c
    raise AssertionError(f"{widget_id} not in the row template")


def _visible(ctx, widget_id):
    """`bind.visible` of `widget_id` in each expanded row, by the row's path:
    the tree's own foreach source, each row bound as its `as` name.
    (Through `evaluate`, not `bind_values`: the latter cannot render the
    tree's own list-of-objects `bind.source`; see the step-3 PR.)"""
    tree = _tree()
    rows = evaluate(tree["foreach"]["source"], ctx).value or []
    expr = _widget(tree["do"], widget_id)["bind"]["visible"]
    name = tree["foreach"].get("as", "item")
    return {tuple(r["path"]): evaluate(expr, {**ctx, name: r}).value for r in rows}


def _ctx(renaming=None, collapsed=None):
    return {"active_document": {"element_tree": _rows()},
            "panel": {"layers_panel_selection": [], "isolation_stack": [],
                      "collapsed_paths": collapsed or [], "renaming_element": renaming}}


def test_the_rows_expand():
    assert len(_visible(_ctx(), "lp_name")) == len(_rows()) == 5


def test_with_nothing_renaming_every_row_shows_its_name_and_no_rename_box():
    names, edits = _visible(_ctx(), "lp_name"), _visible(_ctx(), "lp_name_edit")
    assert set(names.values()) == {True}, names
    assert set(edits.values()) == {False}, edits


def test_renaming_one_path_shows_one_rename_box():
    rows = _rows()
    target = rows[2]["path"]
    edits = _visible(_ctx(renaming=target), "lp_name_edit")
    assert sorted(edits.values()) == [False] * (len(rows) - 1) + [True], edits


def test_a_collapsed_path_hides_its_children_and_closes_its_twirl():
    rows = _rows()
    group = [r["path"] for r in rows if r["type"] == "group"][0]
    names = _visible(_ctx(collapsed=[group]), "lp_name")
    hidden = [r for r in rows if len(r["path"]) > len(group) and r["path"][:len(group)] == group]
    assert hidden, "the control: the group has a child"
    assert len(names) == len(rows) - len(hidden)


def test_the_twirl_icon_reads_the_collapsed_paths():
    tree = _tree()
    twirl = _widget(tree["do"], "lp_twirl")["bind"]["icon"]
    group = [r for r in _rows() if r["type"] == "group"][0]
    icon = lambda collapsed: evaluate(twirl, {**_ctx(collapsed=collapsed), "node": group}).value
    assert icon([]) == "twirl_open"
    assert icon([group["path"]]) == "twirl_closed"
    assert icon([[9, 9]]) == "twirl_open", "another path does not close it"


def test_the_expanded_tree_is_not_also_drawn_as_a_leaf():
    """flask §603: the render plan sent the expanded `lp_tree` as a leaf of
    type `tree_view` as well as its rows, so the shell drew a placeholder
    behind them. An expanded tree is layout-only, like any foreach container."""
    from workspace_interpreter.panel_layout import render_plan
    plan = render_plan(_panel(), 228, 600, _ctx())
    kinds = [leaf["node"].get("type") for leaf in plan["leaves"]]
    assert "tree_view" not in kinds, kinds
    assert kinds.count("icon_button") >= 2 * len(_rows()), "the control: the rows' leaves are there"


def test_the_eye_and_lock_icons_are_bound_from_the_row():
    """The 10-30 Windows sitting, finding 4: the row's eye, lock and twirl drew
    as TEXT on Windows, because their `icon:` was a `{{...}}` template, which
    the plan withholds by design. They are `bind.icon` expressions, which every
    shell already resolves. Each of the three visibilities and both lock states
    names its own icon."""
    tree = _tree()
    eye = _widget(tree["do"], "lp_eye")["bind"]["icon"]
    lock = _widget(tree["do"], "lp_lock")["bind"]["icon"]
    at = lambda expr, **node: evaluate(expr, {**_ctx(), "node": node}).value
    assert at(eye, visibility="preview") == "eye_preview"
    assert at(eye, visibility="outline") == "eye_outline"
    assert at(eye, visibility="invisible") == "eye_invisible"
    assert at(lock, locked=True) == "lock_locked"
    assert at(lock, locked=False) == "lock_unlocked"


def test_the_select_square_binds_its_fill_and_border():
    """The 10-30 Windows sitting, finding 6: no select square in the Layers
    row. Its click already ran (flask STATUS §674), but its background and
    border were `{{...}}` style strings, which the plan withholds, so the box
    drew nothing on Windows. They are `bind` expressions, evaluated per row:
    the fill is the row's layer colour when the element is selected and
    transparent otherwise; the border is themed."""
    tree = _tree()
    sq = _widget(tree["do"], "lp_select")
    assert "background" not in sq.get("style", {}) and "border" not in sq.get("style", {}), \
        "the fill and border are binds, not templated style"
    fill, border = sq["bind"]["background"], sq["bind"]["border"]
    ctx = {**_ctx(), "theme": {"colors": {"border": "#6a6a6a"}}}
    at = lambda expr, **node: evaluate(expr, {**ctx, "node": node}).value
    assert at(fill, element_selected=True, ancestor_layer_color="#4a90d9") == "#4a90d9"
    assert at(fill, element_selected=False, ancestor_layer_color="#4a90d9") == "transparent"
    assert at(border) == "1px solid #6a6a6a", "the border follows the theme"
