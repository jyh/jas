"""Concept-constraint conformance tests (the Python reference).

Loads the compiled corpus (test_fixtures/concept_constraints/conformance.json —
generated from workspace/concepts/*.yaml + workspace/tests/concept_constraints.yaml)
and asserts that evaluating each constraint's ``check`` expression over the case's
params (bound under ``param``) and collecting the constraints whose result is NOT
truthy reproduces the expected list of violated ids, in declared order.

A constraint is just a boolean expression, so this reuses the evaluator — pinning
concept CHECKING across all apps (CONCEPTS.md §11). Checking is advisory and
read-only (no op-log verb); this gate fixes which params an instance's invariants
flag as violated.
"""

import json
import os

import pytest

from workspace_interpreter.expr import evaluate
from workspace_interpreter.expr_types import ValueType

FIXTURE_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..",
    "test_fixtures", "concept_constraints", "conformance.json",
)


def _load_fixture():
    with open(FIXTURE_PATH) as f:
        return json.load(f)


_CASES = _load_fixture()


def _truthy(v):
    # The same truthiness the language's `if` uses: a constraint is satisfied iff
    # its check evaluates truthy; violated otherwise.
    if v.type == ValueType.BOOL:
        return bool(v.value)
    if v.type == ValueType.NUMBER:
        return v.value != 0
    if v.type == ValueType.NULL:
        return False
    return True


@pytest.mark.parametrize(
    "case",
    _CASES,
    ids=[f"{c['concept']}/{i}" for i, c in enumerate(_CASES)],
)
def test_concept_constraints_check(case):
    ctx = {"param": case["params"]}
    violated = [
        c["id"]
        for c in case["constraints"]
        if not _truthy(evaluate(c["check"], ctx))
    ]
    assert violated == case["expected"], (
        f"{case['concept']}: expected violations {case['expected']}, got {violated}"
    )
