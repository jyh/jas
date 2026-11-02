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
