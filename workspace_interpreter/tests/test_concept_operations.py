"""Concept-operation conformance tests (the Python reference).

Loads the compiled corpus (test_fixtures/concept_operations/conformance.json —
generated from workspace/concepts/*.yaml + workspace/tests/concept_operations.yaml)
and asserts that evaluating each operation's ``set:`` expressions with the case's
params bound under ``param`` reproduces the expected resolved change for each
changed param (within 1e-9).

An operation's effect is just expression evaluation, so this reuses the
evaluator — pinning concept-operation RESOLUTION across all apps (CONCEPTS.md §9).
The production handler bakes exactly these resolved changes into the op
(value-in-op), so the gate also pins what gets journaled. The cross-language
equivalence gate for the ``apply_concept_operation`` verb.
"""

import json
import os

import pytest

from workspace_interpreter.expr import evaluate
from workspace_interpreter.expr_types import ValueType

FIXTURE_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..",
    "test_fixtures", "concept_operations", "conformance.json",
)


def _load_fixture():
    with open(FIXTURE_PATH) as f:
        return json.load(f)


_CASES = _load_fixture()


@pytest.mark.parametrize(
    "case",
    _CASES,
    ids=[
        c["concept"] + "/" + c["op"] + "/"
        + ",".join(f"{k}={v}" for k, v in c["params"].items())
        for c in _CASES
    ],
)
def test_concept_operation_resolves(case):
    # Bind the current params under the `param` namespace (the generator's
    # namespace), exactly as the production handler does at resolve time.
    ctx = {"param": case["params"]}
    set_map = case["set"]
    expected = case["expected"]
    for name, expr_src in set_map.items():
        result = evaluate(expr_src, ctx)
        assert result.type == ValueType.NUMBER, (
            f"{case['concept']}/{case['op']} param {name}: "
            f"non-numeric result ({result.type.name})"
        )
        got = float(result.value)
        want = float(expected[name])
        assert abs(got - want) < 1e-9, (
            f"{case['concept']}/{case['op']} param {name}: "
            f"expected {want}, got {got}"
        )
