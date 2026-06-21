"""Concept-fitter conformance tests (the Python reference).

Loads the compiled corpus (test_fixtures/concept_fitters/conformance.json —
generated from workspace/concepts/*.yaml + workspace/tests/concept_fitters.yaml)
and asserts that evaluating each concept's ``fitter`` expression over the case's
points (bound under ``shape.points``) reproduces the expected result: ``null``
for no match, else the flat ``[params..., cx, cy, rotation]`` list (within 1e-9).

A fitter is the dual of the generator and is just an expression, so this reuses
the evaluator — pinning concept DETECTION across all apps (CONCEPTS.md §10). The
production ``promote`` handler runs exactly this and bakes the recovered values
into the op (value-in-op), so the gate also pins what gets journaled.
"""

import json
import os

import pytest

from workspace_interpreter.expr import evaluate
from workspace_interpreter.expr_types import ValueType

FIXTURE_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..",
    "test_fixtures", "concept_fitters", "conformance.json",
)


def _load_fixture():
    with open(FIXTURE_PATH) as f:
        return json.load(f)


_CASES = _load_fixture()


def _unwrap(v):
    return v.value if hasattr(v, "value") else v


@pytest.mark.parametrize(
    "case",
    _CASES,
    ids=[f"{c['concept']}/{i}" for i, c in enumerate(_CASES)],
)
def test_concept_fitter_detects(case):
    # Bind the input vertices under `shape.points`, exactly as the production
    # promote handler does at detect time.
    ctx = {"shape": {"points": case["points"]}}
    result = evaluate(case["fitter"], ctx)
    expected = case["expected"]

    if expected is None:
        assert result.type == ValueType.NULL, (
            f"{case['concept']}: expected no match (null), got {result.type.name}"
        )
        return

    assert result.type != ValueType.NULL, (
        f"{case['concept']}: expected a match {expected}, got null"
    )
    got = [_unwrap(v) for v in result.value]
    assert len(got) == len(expected), (
        f"{case['concept']}: result arity {len(got)} != expected {len(expected)}"
    )
    for i, (g, e) in enumerate(zip(got, expected)):
        assert abs(float(g) - float(e)) < 1e-9, (
            f"{case['concept']} output[{i}]: expected {e}, got {g}"
        )
