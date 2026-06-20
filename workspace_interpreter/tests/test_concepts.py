"""Concept-generator conformance tests (the Python reference).

Loads the compiled corpus (test_fixtures/concepts/conformance.json — generated
from workspace/concepts/*.yaml + workspace/tests/concepts.yaml) and asserts that
evaluating each concept's generator expression with its parameters bound under
`param` reproduces the expected list of [x, y] points. See CONCEPTS.md.
"""

import json
import os

import pytest

from workspace_interpreter.expr import evaluate
from workspace_interpreter.expr_types import ValueType

FIXTURE_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..",
    "test_fixtures", "concepts", "conformance.json",
)


def _load_fixture():
    with open(FIXTURE_PATH) as f:
        return json.load(f)


_CASES = _load_fixture()


def _points(value):
    """Extract [(x, y), ...] from an evaluated list-of-pairs Value."""
    assert value.type == ValueType.LIST, (
        f"generator did not return a list (got {value.type.name})"
    )
    out = []
    for item in value.value:
        assert isinstance(item, (list, tuple)) and len(item) == 2, (
            f"point is not a 2-element list: {item!r}"
        )
        out.append((float(item[0]), float(item[1])))
    return out


@pytest.mark.parametrize(
    "case",
    _CASES,
    ids=[
        c["concept"] + "/" + ",".join(f"{k}={v}" for k, v in c["params"].items())
        for c in _CASES
    ],
)
def test_concept_generates(case):
    result = evaluate(case["generator"], {"param": case["params"]})
    pts = _points(result)
    expected = case["expected"]
    assert len(pts) == len(expected), (
        f"{case['concept']}: point count — expected {len(expected)}, got {len(pts)}"
    )
    for i, ((x, y), exp) in enumerate(zip(pts, expected)):
        ex, ey = float(exp[0]), float(exp[1])
        assert abs(x - ex) < 1e-9 and abs(y - ey) < 1e-9, (
            f"{case['concept']} point {i}: expected ({ex}, {ey}), got ({x}, {y})"
        )


# ── Concept registry (increment 3a): concepts are bundled into workspace.json
#    and loadable as a registry. See CONCEPTS.md §6/§7. ──

class TestConceptRegistry:
    def _ws(self):
        from workspace_interpreter.loader import load_workspace
        ws_dir = os.path.join(os.path.dirname(__file__), "..", "..", "workspace")
        return load_workspace(ws_dir)

    def test_registry_has_concepts(self):
        from workspace_interpreter.loader import concepts
        reg = concepts(self._ws())
        assert {"regular_polygon", "spiral", "star", "gear"} <= set(reg.keys())

    def test_registry_concept_fields(self):
        from workspace_interpreter.loader import concept
        gear = concept(self._ws(), "gear")
        assert gear is not None
        assert gear["closed"] is True
        assert "mod(" in gear["generator"]
        assert [p["name"] for p in gear["params"]] == ["teeth", "outer", "root"]

    def test_registry_generator_evaluates(self):
        # Registry -> evaluator round-trip: the bundled generator produces
        # geometry. This is the foundation the document Generated arm builds on.
        from workspace_interpreter.loader import concept
        poly = concept(self._ws(), "regular_polygon")
        result = evaluate(poly["generator"], {"param": {"sides": 4, "radius": 10}})
        assert result.type == ValueType.LIST
        assert len(result.value) == 4

    def test_registry_unknown_concept_is_none(self):
        from workspace_interpreter.loader import concept
        assert concept(self._ws(), "no_such_concept") is None
