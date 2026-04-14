"""Expression language conformance tests.

Loads test cases from workspace/tests/expressions.yaml and validates
that evaluate() produces the expected result and type for each case.
"""

import os
import pytest
import yaml

from workspace_interpreter.expr import evaluate, evaluate_text
from workspace_interpreter.expr_types import Value, ValueType


FIXTURE_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..", "workspace", "tests", "expressions.yaml"
)


def _load_fixture():
    with open(FIXTURE_PATH) as f:
        data = yaml.safe_load(f)
    return data["tests"]


def _to_value_type(type_str: str) -> ValueType:
    return {
        "bool": ValueType.BOOL,
        "number": ValueType.NUMBER,
        "string": ValueType.STRING,
        "color": ValueType.COLOR,
        "null": ValueType.NULL,
        "list": ValueType.LIST,
    }[type_str]


def _build_context(case: dict) -> dict:
    ctx = {}
    if "state" in case:
        ctx["state"] = case["state"]
    if "data" in case:
        ctx["data"] = case["data"]
    return ctx


_CASES = _load_fixture()


@pytest.mark.parametrize(
    "case",
    _CASES,
    ids=[c.get("expr", "?")[:60] for c in _CASES],
)
def test_conformance(case):
    ctx = _build_context(case)
    result = evaluate(case["expr"], ctx)

    expected_type = _to_value_type(case["type"])
    assert result.type == expected_type, (
        f"Type mismatch for {case['expr']!r}: "
        f"expected {expected_type.name}, got {result.type.name} (value={result.value!r})"
    )

    expected = case["expected"]
    if expected_type == ValueType.NULL:
        assert result.value is None
    elif expected_type == ValueType.BOOL:
        assert result.value is (True if expected else False)
    elif expected_type == ValueType.NUMBER:
        assert result.value == expected, (
            f"Value mismatch for {case['expr']!r}: expected {expected}, got {result.value}"
        )
    elif expected_type == ValueType.STRING:
        assert result.value == expected
    elif expected_type == ValueType.COLOR:
        assert result.value == expected


# ── Additional unit tests beyond the YAML fixture ──


class TestEvaluateText:
    def test_plain_string(self):
        result = evaluate_text("hello world", {})
        assert result == "hello world"

    def test_interpolation(self):
        result = evaluate_text("color is {{state.c}}", {"state": {"c": "#ff0000"}})
        assert result == "color is #ff0000"

    def test_no_braces(self):
        result = evaluate_text("no interpolation here", {})
        assert result == "no interpolation here"

    def test_null_interpolation(self):
        result = evaluate_text("val={{state.missing}}", {"state": {}})
        assert result == "val="

    def test_number_interpolation(self):
        result = evaluate_text("count={{state.n}}", {"state": {"n": 42}})
        assert result == "count=42"

    def test_multiple_interpolations(self):
        result = evaluate_text(
            "{{state.a}} and {{state.b}}",
            {"state": {"a": "hello", "b": "world"}},
        )
        assert result == "hello and world"


class TestEvaluateEdgeCases:
    def test_empty_string(self):
        result = evaluate("", {})
        assert result.type == ValueType.NULL

    def test_syntax_error(self):
        result = evaluate("state.x ==", {})
        assert result.type == ValueType.NULL

    def test_unknown_function(self):
        result = evaluate("unknown_fn(5)", {})
        assert result.type == ValueType.NULL

    def test_nested_path_on_null(self):
        result = evaluate("state.a.b.c", {"state": {}})
        assert result.type == ValueType.NULL

    def test_color_3digit_normalizes(self):
        result = evaluate("#fff", {})
        assert result.type == ValueType.COLOR
        assert result.value == "#ffffff"

    def test_string_literal(self):
        result = evaluate('"hello"', {})
        assert result.type == ValueType.STRING
        assert result.value == "hello"

    def test_number_literal(self):
        result = evaluate("42", {})
        assert result.type == ValueType.NUMBER
        assert result.value == 42

    def test_negative_number(self):
        result = evaluate("-5", {})
        assert result.type == ValueType.NUMBER
        assert result.value == -5

    def test_bool_literal_true(self):
        result = evaluate("true", {})
        assert result.type == ValueType.BOOL
        assert result.value is True

    def test_bool_literal_false(self):
        result = evaluate("false", {})
        assert result.type == ValueType.BOOL
        assert result.value is False

    def test_null_literal(self):
        result = evaluate("null", {})
        assert result.type == ValueType.NULL

    def test_parentheses(self):
        result = evaluate("(5 == 5)", {})
        assert result.type == ValueType.BOOL
        assert result.value is True

    def test_short_circuit_and(self):
        # false and X should not evaluate X
        result = evaluate("false and state.missing.deep", {})
        assert result.value is False

    def test_short_circuit_or(self):
        # true or X should not evaluate X
        result = evaluate("true or state.missing.deep", {})
        assert result.value is True

    def test_theme_path(self):
        ctx = {"theme": {"colors": {"bg": "#333333"}}}
        result = evaluate("theme.colors.bg", ctx)
        assert result.value == "#333333"

    def test_data_path(self):
        ctx = {"data": {"libs": {"web": {"name": "Web Colors"}}}}
        result = evaluate("data.libs.web.name", ctx)
        assert result.value == "Web Colors"

    def test_list_index_out_of_bounds(self):
        result = evaluate("state.items.99", {"state": {"items": [1, 2, 3]}})
        assert result.type == ValueType.NULL
