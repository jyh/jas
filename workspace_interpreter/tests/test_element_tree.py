"""`active_document.element_tree`: the document's rows for the Layers panel's
`tree_view` (STATUS-jas item 38 step 1), against the shared fixture
`test_fixtures/layers/element_tree.json`, which the active ports read too."""

from __future__ import annotations

import json
import os

import pytest

from workspace_interpreter.state_store import StateStore, tree_visible_rows

_FIXTURE = os.path.join(os.path.dirname(__file__), "..", "..", "test_fixtures", "layers", "element_tree.json")


def _cases():
    with open(_FIXTURE, encoding="utf-8") as f:
        return json.load(f)["cases"]


def test_the_fixture_is_not_vacuous():
    cases = _cases()
    assert len(cases) >= 2
    assert sum(len(c["expected"]) for c in cases) >= 5


@pytest.mark.parametrize("case", _cases(), ids=lambda c: c["name"])
def test_element_tree_rows(case):
    store = StateStore(document=json.loads(json.dumps(case["document"])))
    assert store.eval_context()["active_document"]["element_tree"] == case["expected"]


def _visible_cases():
    with open(_FIXTURE, encoding="utf-8") as f:
        return json.load(f)["visible_cases"]


def test_the_visible_cases_are_not_vacuous():
    cases = _visible_cases()
    assert len(cases) >= 4
    marks = [r for c in cases for r in c["expected"] if r["collapsed"] or r["panel_selected"] or r["renaming"]]
    assert {k for r in marks for k in ("collapsed", "panel_selected", "renaming") if r[k]} == {
        "collapsed", "panel_selected", "renaming"}


@pytest.mark.parametrize("case", _visible_cases(), ids=lambda c: c["name"])
def test_tree_visible_rows(case):
    """Step 1b: the rows to draw, resolved from `element_tree` and the
    widget's binds by the one shared function (flask §591)."""
    store = StateStore(document=json.loads(json.dumps(case["document"])))
    rows = store.eval_context()["active_document"]["element_tree"]
    b = case["binds"]
    assert tree_visible_rows(rows, b["collapsed"], b["panel_selection"], b["renaming"]) == case["expected"]


@pytest.mark.parametrize("case", _visible_cases(), ids=lambda c: c["name"])
def test_tree_visible_rows_through_the_evaluator(case):
    """The plan's `foreach` source calls the resolve as an expression function
    (`layers.yaml` `lp_tree`); the panel selection arrives as path markers,
    as the panel scope publishes it."""
    from workspace_interpreter.expr import evaluate
    store = StateStore(document=json.loads(json.dumps(case["document"])))
    b = case["binds"]
    ctx = {"active_document": store.eval_context()["active_document"],
           "panel": {"layers_panel_selection": [{"__path__": p} for p in b["panel_selection"]]},
           "collapsed": b["collapsed"], "renaming": b["renaming"]}
    got = evaluate("tree_visible_rows(active_document.element_tree, collapsed, "
                   "panel.layers_panel_selection, renaming)", ctx)
    assert got.value == case["expected"]


def _rows_at_cases():
    with open(_FIXTURE, encoding="utf-8") as f:
        return json.load(f)["rows_at_cases"]


def test_the_rows_at_cases_are_not_vacuous():
    cases = _rows_at_cases()
    assert len(cases) >= 4
    assert sum(len(c["expected"]) for c in cases) >= 5
    assert any(len(c["expected"]) < len(c["paths"]) for c in cases), "a skipped path"
    orders = [[tuple(r["path"]) for r in c["expected"]] for c in cases]
    assert any(o != sorted(o) for o in orders) and any(len(o) > 1 and o == sorted(o) for o in orders), \
        "both orders, so a filter in tree order cannot pass"


@pytest.mark.parametrize("marker", [True, False], ids=["path_markers", "plain_lists"])
@pytest.mark.parametrize("case", _rows_at_cases(), ids=lambda c: c["name"])
def test_tree_rows_at_through_the_evaluator(case, marker):
    """Row 72(a): the Layers breadcrumb's foreach source. The isolation stack
    arrives as path markers, as the panel scope publishes it."""
    from workspace_interpreter.expr import evaluate
    doc = json.loads(json.dumps(_cases()[0]["document"]))
    store = StateStore(document=doc)
    paths = [{"__path__": p} if marker else p for p in case["paths"]]
    ctx = {"active_document": store.eval_context()["active_document"],
           "panel": {"isolation_stack": paths}}
    got = evaluate("tree_rows_at(active_document.element_tree, panel.isolation_stack)", ctx)
    assert got.value == case["expected"]


@pytest.mark.parametrize("expr", [
    "tree_rows_at(5, panel.isolation_stack)",
    "tree_rows_at(active_document.element_tree)",
])
def test_tree_rows_at_refuses_a_malformed_call_with_null(expr):
    from workspace_interpreter.expr import evaluate
    store = StateStore(document=json.loads(json.dumps(_cases()[0]["document"])))
    ctx = {"active_document": store.eval_context()["active_document"],
           "panel": {"isolation_stack": [{"__path__": [0]}]}}
    assert evaluate(expr, ctx).value is None


def test_tree_rows_at_a_non_list_of_paths_is_no_rows():
    from workspace_interpreter.expr import evaluate
    store = StateStore(document=json.loads(json.dumps(_cases()[0]["document"])))
    ctx = {"active_document": store.eval_context()["active_document"]}
    assert evaluate("tree_rows_at(active_document.element_tree, null)", ctx).value == []


# ── tree_reveal (row 78): the Layers reveal as a store effect ─────────────


def _reveal_cases():
    with open(_FIXTURE, encoding="utf-8") as f:
        return json.load(f)["reveal_cases"]


def test_the_reveal_cases_are_not_vacuous():
    cases = _reveal_cases()
    assert len(cases) >= 5
    assert any(c["expected"] == [] and c["collapsed"] for c in cases), "an entry removed"
    assert any(c["expected"] == c["collapsed"] and c["selection"] for c in cases), \
        "a selection that opens nothing"
    assert any(c["expected"] and c["expected"] != c["collapsed"] for c in cases), "a partial removal"


def _marker(p):
    return {"__path__": p}


@pytest.mark.parametrize("marker", [True, False], ids=["path_markers", "plain_lists"])
@pytest.mark.parametrize("case", _reveal_cases(), ids=lambda c: c["name"])
def test_tree_reveal_through_the_evaluator(case, marker):
    """`scroll_to_selected`'s effect value: the collapsed entries that are not a
    strict ancestor of any selected path, each in the form the store holds it."""
    from workspace_interpreter.expr import evaluate
    wrap = _marker if marker else (lambda p: p)
    ctx = {"panel": {"collapsed_paths": [wrap(p) for p in case["collapsed"]]},
           "active_document": {"element_selection": [_marker(p) for p in case["selection"]]}}
    got = evaluate("tree_reveal(panel.collapsed_paths, active_document.element_selection)", ctx)
    assert got.value == [wrap(p) for p in case["expected"]]


def test_tree_reveal_reads_the_selection_as_path_values():
    """The live context holds `element_selection` as PATH values, not markers."""
    from workspace_interpreter.expr import evaluate
    from workspace_interpreter.expr_types import Value
    ctx = {"panel": {"collapsed_paths": [[0], [1]]},
           "active_document": {"element_selection": [Value.path((0, 3))]}}
    got = evaluate("tree_reveal(panel.collapsed_paths, active_document.element_selection)", ctx)
    assert got.value == [[1]]


@pytest.mark.parametrize("expr", [
    "tree_reveal(panel.collapsed_paths)",
    "tree_reveal(5, panel.sel)",
])
def test_tree_reveal_refuses_a_malformed_call_with_null(expr):
    from workspace_interpreter.expr import evaluate
    ctx = {"panel": {"collapsed_paths": [[0]], "sel": [[0, 1]]}}
    assert evaluate(expr, ctx).value is None


def test_tree_reveal_keeps_an_entry_that_is_not_a_path():
    """It removes ancestors and nothing else; it does not tidy the list."""
    from workspace_interpreter.expr import evaluate
    ctx = {"panel": {"collapsed_paths": ["junk", [0]], "sel": [[0, 1]]}}
    assert evaluate("tree_reveal(panel.collapsed_paths, panel.sel)", ctx).value == ["junk"]


def _scroll_to_selected_effects():
    import yaml
    path = os.path.join(os.path.dirname(__file__), "..", "..", "workspace", "actions.yaml")
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)["actions"]["scroll_to_selected"]["effects"]


def test_scroll_to_selected_opens_the_selections_collapsed_ancestors():
    """Row 78: actions.yaml's scroll_to_selected writes the reveal to the
    Layers panel's collapsed_paths. The fixture document selects [0,1] (a
    group): its ancestor [0] opens, the selected group itself stays collapsed,
    and an unrelated [1] keeps its state.

    THE CALLER'S CONTRACT: the action reads `panel.collapsed_paths`, so it runs
    in the LAYERS scope, as every Layers action does through its port's Layers
    dispatcher (Swift `LayersPanel.actionContext`, Rust `build_appstate_ctx`).
    The canvas trigger dispatches it the same way; with another panel active
    and no such dispatcher, `panel` is that panel's scope."""
    from workspace_interpreter.effects import run_effects
    store = StateStore(document=json.loads(json.dumps(_cases()[0]["document"])))
    store.init_panel("layers", {"collapsed_paths": [{"__path__": [1]}, {"__path__": [0]}, {"__path__": [0, 1]}]})
    store.set_active_panel("layers")
    run_effects(_scroll_to_selected_effects(), store.eval_context(), store)
    assert store.get_panel("layers", "collapsed_paths") == [{"__path__": [1]}, {"__path__": [0, 1]}]


def _element_at_cases():
    with open(_FIXTURE, encoding="utf-8") as f:
        return json.load(f)["element_at_cases"]


def test_the_element_at_cases_are_not_vacuous():
    """A nested hit and a null are both present, or the cases cannot tell a
    view that carries children from one that does not."""
    cases = _element_at_cases()
    assert any(len(c["path"]) > 1 and c["expected"] is not None for c in cases)
    assert any(c["expected"] is None for c in cases)
    assert any(c["expected"] and c["expected"]["kind"] == "Layer" and len(c["path"]) > 1 for c in cases)


@pytest.mark.parametrize("case", _element_at_cases(), ids=lambda c: c["name"])
def test_element_at_through_the_view(case):
    """STATUS-jas row 75: `element_at` read through the store's OWN
    active_document view, the four fields Layer Options reads (actions.yaml
    `open_layer_options`)."""
    from workspace_interpreter.expr import evaluate
    store = StateStore(document=json.loads(json.dumps(case["document"])))
    ctx = store.eval_context()
    at = "element_at(path(" + ", ".join(str(i) for i in case["path"]) + "))"
    want = case["expected"]
    if want is None:
        assert evaluate(f"{at} == null", ctx).value is True
        return
    assert evaluate(f"{at} != null", ctx).value is True
    got = {k: evaluate(f"{at}.{e}", ctx).value for k, e in
           (("kind", "kind"), ("name", "name"), ("locked", "common.locked"), ("visibility", "common.visibility"))}
    assert got == want
