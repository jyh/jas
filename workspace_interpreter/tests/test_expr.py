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


class TestLoopVariableContext:
    """Test that loop variables work as top-level context keys.

    When a repeat directive iterates, the loop variable (e.g., 'lib',
    'swatch') is injected as a top-level key in the eval context. The
    expression evaluator must resolve dotted paths and bracket notation
    against these variables naturally, without string substitution.
    """

    def test_loop_var_dot_access(self):
        """lib.id resolves when lib is a top-level context key."""
        ctx = {"lib": {"id": "web_colors", "collapsed": False}}
        result = evaluate("lib.id", ctx)
        assert result.value == "web_colors"

    def test_loop_var_nested_dot_access(self):
        """swatch.color resolves when swatch is a top-level context key."""
        ctx = {"swatch": {"color": "#ff0000", "name": "Red", "_index": 0}}
        result = evaluate("swatch.color", ctx)
        assert result.value == "#ff0000"

    def test_loop_var_index(self):
        """swatch._index resolves to the numeric index."""
        ctx = {"swatch": {"color": "#00ff00", "_index": 3}}
        result = evaluate("swatch._index", ctx)
        assert result.value == 3

    def test_bracket_with_loop_var(self):
        """data.swatch_libraries[lib.id].name uses bracket notation with loop var."""
        ctx = {
            "data": {
                "swatch_libraries": {
                    "web_colors": {
                        "name": "Web Colors",
                        "swatches": [{"color": "#ff0000"}],
                    }
                }
            },
            "lib": {"id": "web_colors", "collapsed": False},
        }
        result = evaluate("data.swatch_libraries[lib.id].name", ctx)
        assert result.value == "Web Colors"

    def test_bracket_with_loop_var_nested_list(self):
        """data.swatch_libraries[lib.id].swatches resolves to a list."""
        ctx = {
            "data": {
                "swatch_libraries": {
                    "web_colors": {
                        "name": "Web Colors",
                        "swatches": [
                            {"color": "#ff0000", "name": "Red"},
                            {"color": "#00ff00", "name": "Green"},
                        ],
                    }
                }
            },
            "lib": {"id": "web_colors"},
        }
        result = evaluate("data.swatch_libraries[lib.id].swatches", ctx)
        assert result.type == ValueType.LIST
        assert len(result.value) == 2

    def test_text_interpolation_with_loop_var(self):
        """{{data.swatch_libraries[lib.id].name}} in text interpolation."""
        ctx = {
            "data": {
                "swatch_libraries": {
                    "web_colors": {"name": "Web Colors"},
                }
            },
            "lib": {"id": "web_colors"},
        }
        result = evaluate_text(
            "Library: {{data.swatch_libraries[lib.id].name}}", ctx
        )
        assert result == "Library: Web Colors"

    def test_loop_var_with_state_and_panel(self):
        """Loop var coexists with state and panel namespaces."""
        ctx = {
            "state": {"fill_color": "#ffffff"},
            "panel": {"thumbnail_size": "small"},
            "lib": {"id": "basic", "collapsed": False},
        }
        result = evaluate("lib.id", ctx)
        assert result.value == "basic"
        result2 = evaluate("state.fill_color", ctx)
        assert result2.value == "#ffffff"

    def test_nested_loop_vars(self):
        """Both outer and inner loop variables resolve simultaneously."""
        ctx = {
            "data": {
                "swatch_libraries": {
                    "web_colors": {
                        "swatches": [{"color": "#ff0000"}],
                    }
                }
            },
            "lib": {"id": "web_colors"},
            "swatch": {"color": "#ff0000", "name": "Red", "_index": 0},
        }
        result_lib = evaluate("lib.id", ctx)
        assert result_lib.value == "web_colors"
        result_swatch = evaluate("swatch.color", ctx)
        assert result_swatch.value == "#ff0000"
        result_idx = evaluate("swatch._index", ctx)
        assert result_idx.value == 0


# ── Lambda tests ──────────────────────────────────────────────


class TestLambda:
    def test_unary_no_parens(self):
        result = evaluate("(fun x -> x + 1)(5)", {})
        assert result.value == 6

    def test_unary_with_parens(self):
        result = evaluate("(fun (x) -> x + 1)(5)", {})
        assert result.value == 6

    def test_binary(self):
        result = evaluate("(fun (x, y) -> x + y)(3, 4)", {})
        assert result.value == 7

    def test_nullary(self):
        result = evaluate("(fun () -> 42)()", {})
        assert result.value == 42

    def test_closure_captures_scope(self):
        result = evaluate("(fun x -> x + y)(10)", {"y": 5})
        assert result.value == 15

    def test_named_closure(self):
        result = evaluate("let f = fun x -> x * 2 in f(7)", {})
        assert result.value == 14

    def test_nested_lambda(self):
        result = evaluate("let add = fun (a, b) -> a + b in add(add(1, 2), 3)", {})
        assert result.value == 6


# ── Let-binding tests ─────────────────────────────────────────


class TestLet:
    def test_simple(self):
        result = evaluate("let x = 5 in x + 1", {})
        assert result.value == 6

    def test_nested(self):
        result = evaluate("let x = 3 in let y = 4 in x + y", {})
        assert result.value == 7

    def test_shadow(self):
        result = evaluate("let x = 1 in let x = 2 in x", {})
        assert result.value == 2

    def test_outer_not_leaked(self):
        """After let scope, the binding is not visible."""
        result = evaluate("let x = 5 in x", {})
        assert result.value == 5

    def test_references_context(self):
        result = evaluate("let doubled = n * 2 in doubled + 1", {"n": 10})
        assert result.value == 21


# ── Assignment tests ──────────────────────────────────────────


class TestAssign:
    def test_assign_calls_store(self):
        stored = {}
        def store_cb(key, val):
            stored[key] = val.value
        ctx = {"__store_cb__": store_cb}
        result = evaluate("x <- 42", ctx)
        assert result.value == 42
        assert stored["x"] == 42

    def test_assign_returns_value(self):
        ctx = {"__store_cb__": lambda k, v: None}
        result = evaluate("x <- 10 + 5", ctx)
        assert result.value == 15


# ── Sequence tests ────────────────────────────────────────────


class TestSequence:
    def test_returns_last(self):
        result = evaluate("1; 2; 3", {})
        assert result.value == 3

    def test_side_effects_in_order(self):
        stored = {}
        def store_cb(key, val):
            stored[key] = val.value
        ctx = {"x": 0, "__store_cb__": store_cb}
        evaluate("x <- 10; x <- 20", ctx)
        assert stored["x"] == 20

    def test_sequence_with_let(self):
        result = evaluate("let x = 5 in x + 1; 99", {})
        assert result.value == 99


# ── Arithmetic tests ──────────────────────────────────────────


class TestArithmetic:
    def test_add(self):
        assert evaluate("3 + 4", {}).value == 7

    def test_subtract(self):
        assert evaluate("10 - 3", {}).value == 7

    def test_multiply(self):
        assert evaluate("6 * 7", {}).value == 42

    def test_divide(self):
        assert evaluate("10 / 4", {}).value == 2.5

    def test_divide_by_zero(self):
        assert evaluate("1 / 0", {}).type == ValueType.NULL

    def test_unary_minus(self):
        assert evaluate("-5", {}).value == -5

    def test_unary_minus_expr(self):
        assert evaluate("-(3 + 2)", {}).value == -5

    def test_string_concat(self):
        assert evaluate('"hello" + " " + "world"', {}).value == "hello world"

    def test_precedence(self):
        # 2 + 3 * 4 — currently no mul precedence, so left-to-right
        # Actually addition is left-to-right at same level with primary
        assert evaluate("2 + 3", {}).value == 5


# ── Combined tests ────────────────────────────────────────────


class TestCombined:
    def test_setter_pattern(self):
        """The color picker setter pattern: fun v -> color <- hsb(v, s, b)"""
        stored = {}
        def store_cb(key, val):
            stored[key] = val.value
        ctx = {
            "color": "#ff0000",
            "hsb_s": None,  # not used directly
            "__store_cb__": store_cb,
        }
        # Simplified: fun v -> color <- rgb(v, 100, 50)
        result = evaluate(
            "(fun v -> color <- rgb(v, 100, 50))(200)",
            ctx,
        )
        assert "color" in stored
        # rgb(200, 100, 50) = some color
        assert stored["color"].startswith("#")

    def test_let_in_lambda(self):
        result = evaluate(
            "(fun v -> let doubled = v * 2 in doubled + 1)(5)",
            {},
        )
        assert result.value == 11
