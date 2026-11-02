"""O96 row 72(a), G6: a Layers row names its element by PATH, never by `node.id`.

`element_tree` rows carry the element's own `id`, which is null on every
element that was never given one (every layer in the shared element_tree
fixture). The row template passed
`node.id` as `layer_id` to Options for Layer, so on an id-less layer
`open_layer_options` saw null, opened in edit mode with nothing to edit, and its
OK took `layer_options_confirm`'s CREATE arm: a new layer instead of an edit.
The isolation entries (the double-click and the context-menu item) passed
`node.id` as `container_id` too, and worked only because `enter_isolation_mode`
falls back to the sole panel-selected row.

Every such param must be the row's path as the dotted id `path_from_id` reads:
`'' + as_path(node.path)` (the corpus pins that coercion in every port,
workspace/tests/expressions.yaml, `as_path`).
"""

from __future__ import annotations

import json
import os

import pytest

from workspace_interpreter.expr import evaluate

_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
_ID_PARAMS = {"open_layer_options": "layer_id", "enter_isolation_mode": "container_id"}


def _bundle():
    with open(os.path.join(_ROOT, "workspace", "workspace.json"), encoding="utf-8") as f:
        return json.load(f)


def _find(node, widget_id):
    if isinstance(node, dict):
        if node.get("id") == widget_id:
            return node
        for v in node.values():
            hit = _find(v, widget_id)
            if hit is not None:
                return hit
    elif isinstance(node, list):
        for v in node:
            hit = _find(v, widget_id)
            if hit is not None:
                return hit
    return None


def _id_sites():
    """Every (where, action, expression) in lp_tree that passes an element id
    to an action that resolves it with path_from_id."""
    tree = _find(_bundle(), "lp_tree")
    assert tree is not None, "lp_tree is in the bundle"
    out = []

    def walk(n, where):
        if isinstance(n, dict):
            action = n.get("action")
            params = n.get("params")
            if isinstance(params, dict):
                for name, key in _ID_PARAMS.items():
                    if isinstance(action, str) and name in action and key in params:
                        out.append((where + ":" + (n.get("label") or n.get("event") or "?"), name, params[key]))
            for k, v in n.items():
                walk(v, where + "." + k)
        elif isinstance(n, list):
            for i, v in enumerate(n):
                walk(v, where + "[%d]" % i)

    walk(tree, "lp_tree")
    return out


def test_the_sites_are_the_three_known_ones():
    sites = _id_sites()
    names = sorted(a for _, a, _ in sites)
    assert names == ["enter_isolation_mode", "enter_isolation_mode", "open_layer_options"], sites


@pytest.mark.parametrize("site", _id_sites(), ids=lambda s: s[0])
def test_an_id_less_row_resolves_to_its_own_path(site):
    _, _, expr = site
    row = {"path": [1, 0], "id": None, "name": "Inks", "type": "layer",
           "type_label": "Layer", "is_container": True}
    got = evaluate(expr, {"node": row})
    resolved = evaluate("path_from_id(v) == path(1, 0)", {"v": got.value})
    assert resolved.value is True, (expr, got.value)


@pytest.mark.parametrize("site", _id_sites(), ids=lambda s: s[0])
def test_a_row_with_an_id_still_resolves_by_path(site):
    """An element's own id is not a path: one that HAS an id must not pass it."""
    _, _, expr = site
    row = {"path": [0], "id": "el_7", "name": "Back", "type": "layer",
           "type_label": "Layer", "is_container": True}
    got = evaluate(expr, {"node": row})
    assert evaluate("path_from_id(v) == path(0)", {"v": got.value}).value is True, (expr, got.value)
