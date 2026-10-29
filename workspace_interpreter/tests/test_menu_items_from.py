"""`items_from` -- a dynamic submenu's rows, declared in YAML.

    items_from: { source: <expr>, as: <name>,
                  item: { label, action, params, checked_when, enabled_when } }

`items_from_entries(spec, ctx)` evaluates `source` against `ctx` and, for each
element bound to `as`, returns `{label, action, params, enabled, checked}`:
the label is a `{{}}` template, every `params` value is an EXPRESSION, the
predicates are booleans (`enabled` True without `enabled_when`, `checked`
None without `checked_when`), the action is verbatim. A source that is not a
list gives no rows. The generic form of `workspace_entries` /
`appearance_entries`. Design: the 2026-10-28 jas brush-library design, A.2.
"""

from workspace_interpreter.menu_state import items_from_entries

_SPEC = {
    "source": "keys(data.brush_libraries)",
    "as": "lib",
    "item": {
        "label": "{{data.brush_libraries[lib].name}}",
        "action": "toggle_brush_library_open",
        "params": {"library": "lib"},
        "checked_when": "any(panel.open_libraries, fun o -> o.id == lib)",
    },
}

_CTX = {
    "data": {"brush_libraries": {
        "zeta": {"name": "Zeta Brushes"},
        "default_brushes": {"name": "Default Brushes"},
    }},
    "panel": {"open_libraries": [{"id": "default_brushes", "collapsed": False}]},
}


def test_one_row_per_source_element_in_source_order():
    rows = items_from_entries(_SPEC, _CTX)
    assert rows == [
        {"label": "Default Brushes", "action": "toggle_brush_library_open",
         "params": {"library": "default_brushes"}, "enabled": True, "checked": True},
        {"label": "Zeta Brushes", "action": "toggle_brush_library_open",
         "params": {"library": "zeta"}, "enabled": True, "checked": False},
    ]


def test_the_checked_rows_differ():
    # The control for the arm above: the two rows' `checked` are not equal, so
    # a predicate evaluated once (not per element) cannot pass it.
    rows = items_from_entries(_SPEC, _CTX)
    assert rows[0]["checked"] != rows[1]["checked"]


def test_enabled_when_is_evaluated_per_element():
    spec = {**_SPEC, "item": {**_SPEC["item"], "enabled_when": 'lib != "zeta"'}}
    assert [r["enabled"] for r in items_from_entries(spec, _CTX)] == [True, False]


def test_without_checked_when_checked_is_none():
    spec = {**_SPEC, "item": {k: v for k, v in _SPEC["item"].items() if k != "checked_when"}}
    assert [r["checked"] for r in items_from_entries(spec, _CTX)] == [None, None]


def test_params_are_expressions():
    spec = {**_SPEC, "item": {**_SPEC["item"], "params": {"library": 'lib + "/x"', "n": "1 + 1"}}}
    assert items_from_entries(spec, _CTX)[0]["params"] == {"library": "default_brushes/x", "n": 2}


def test_the_binding_does_not_leak_into_the_callers_ctx():
    ctx = {**_CTX}
    items_from_entries(_SPEC, ctx)
    assert "lib" not in ctx


def test_a_non_list_source_gives_no_rows():
    for src in ("data.brush_libraries", "null", "3"):
        assert items_from_entries({**_SPEC, "source": src}, _CTX) == []


def test_an_empty_source_gives_no_rows():
    assert items_from_entries(_SPEC, {"data": {"brush_libraries": {}}, "panel": {}}) == []
