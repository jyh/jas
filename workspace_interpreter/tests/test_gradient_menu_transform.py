"""The Gradient panel menu's three stop transforms (reference arm).

Runs the shared cross-language corpus
``test_fixtures/gradient_stop/menu_transform.json`` against
``gradient_law.reverse_stops`` / ``distribute_stops`` / ``reset_midpoints``
and against the expression builtins the menu's YAML calls
(``gradient_reversed`` / ``gradient_distributed`` /
``gradient_midpoints_reset``). The Rust (``cross_language_test.rs``) and
Swift (``GradientStopCorpusTests``) arms read the SAME fixture.
"""

from __future__ import annotations

import copy
import json
import os

import pytest

from workspace_interpreter import gradient_law
from workspace_interpreter.expr import evaluate
from workspace_interpreter.expr_types import ValueType

FIXTURE = os.path.join(
    os.path.dirname(__file__), "..", "..", "test_fixtures", "gradient_stop",
    "menu_transform.json",
)

with open(FIXTURE, encoding="utf-8") as _f:
    _VECTORS = json.load(_f)["vectors"]

#: Each fixture op with its law function and its expression builtin.
OPS = {
    "reverse": ("reverse_stops", "gradient_reversed"),
    "distribute": ("distribute_stops", "gradient_distributed"),
    "reset_midpoints": ("reset_midpoints", "gradient_midpoints_reset"),
}


def _py(v):
    """A list Value's items, ``None`` for null, and the Value itself for
    anything else (so a wrong type fails the comparison loudly)."""
    if v.type == ValueType.NULL:
        return None
    return v.value if v.type == ValueType.LIST else v


def test_corpus_is_not_vacuous():
    # Every op must be witnessed both writing and refusing, or a law that
    # refuses everything (or writes everything) for that op could pass.
    for op in OPS:
        mine = [v for v in _VECTORS if v["op"] == op]
        assert sum(v["expected"] is None for v in mine) >= 2, op
        assert sum(v["expected"] is not None for v in mine) >= 2, op
    assert {v["op"] for v in _VECTORS} == set(OPS)


def test_corpus_names_are_distinct():
    names = [v["name"] for v in _VECTORS]
    assert len(names) == len(set(names))


@pytest.mark.parametrize("vec", _VECTORS, ids=lambda v: v["name"])
def test_law(vec):
    before = copy.deepcopy(vec["stops"])
    got = getattr(gradient_law, OPS[vec["op"]][0])(vec["stops"])
    assert got == vec["expected"]
    assert vec["stops"] == before, "the law must not mutate its input"


@pytest.mark.parametrize("vec", _VECTORS, ids=lambda v: v["name"])
def test_expression_builtin(vec):
    # The YAML calls the law through the expression language, with the
    # panel's stops as the argument: `gradient_reversed(panel.stops)`.
    ctx = {"panel": {"stops": copy.deepcopy(vec["stops"])}}
    got = evaluate(f"{OPS[vec['op']][1]}(panel.stops)", ctx)
    assert _py(got) == vec["expected"]


@pytest.mark.parametrize("fn", [b for _, b in OPS.values()])
def test_builtin_arity_is_one(fn):
    ctx = {"panel": {"stops": _VECTORS[0]["stops"]}}
    assert _py(evaluate(f"{fn}()", ctx)) is None
    assert _py(evaluate(f"{fn}(panel.stops, panel.stops)", ctx)) is None
