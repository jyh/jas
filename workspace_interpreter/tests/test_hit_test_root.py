"""G11 (STATUS-jas row 73): `hit_test(x, y, root)` against the shared fixture
`test_fixtures/layers/hit_test_root.json`, which the active ports read too."""

from __future__ import annotations

import json
import os
import sys

_JAS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "jas"))
if _JAS_DIR not in sys.path:
    sys.path.insert(0, _JAS_DIR)

import pytest

from workspace_interpreter import doc_primitives
from workspace_interpreter.expr import evaluate
from workspace_interpreter.expr_types import ValueType

_FIXTURE = os.path.join(os.path.dirname(__file__), "..", "..", "test_fixtures", "layers", "hit_test_root.json")


def _fixture():
    with open(_FIXTURE, encoding="utf-8") as f:
        return json.load(f)


def _call(case):
    root = case["root"]
    arg = "null" if root is None else "path(" + ", ".join(str(i) for i in root) + ")"
    return f"hit_test({case['x']}, {case['y']}, {arg})"


def test_the_fixture_is_not_vacuous():
    cases = _fixture()["cases"]
    assert sum(1 for c in cases if c["root"] and c["expected"]) >= 4
    assert sum(1 for c in cases if c["root"] and c["expected"] is None) >= 4


@pytest.mark.parametrize("case", _fixture()["cases"], ids=lambda c: c["name"])
def test_hit_test_with_a_root(case):
    from geometry.test_json import test_json_to_document
    doc = test_json_to_document(json.dumps(_fixture()["document"]))
    with doc_primitives.with_doc(doc):
        v = evaluate(_call(case), {})
    if case["expected"] is None:
        assert v.type == ValueType.NULL, v
    else:
        assert v.type == ValueType.PATH and list(v.value) == case["expected"], v


def test_two_arguments_are_the_old_scan():
    """The two-argument call is unchanged: it agrees with the fixture's no-root rows."""
    from geometry.test_json import test_json_to_document
    doc = test_json_to_document(json.dumps(_fixture()["document"]))
    for c in _fixture()["cases"]:
        if c["root"] is None:
            with doc_primitives.with_doc(doc):
                v = evaluate(f"hit_test({c['x']}, {c['y']})", {})
            assert list(v.value) == c["expected"]


@pytest.mark.parametrize("case", _fixture()["is_group_cases"], ids=lambda c: c["name"])
def test_is_group(case):
    from geometry.test_json import test_json_to_document
    doc = test_json_to_document(json.dumps(_fixture()["document"]))
    arg = "path(" + ", ".join(str(i) for i in case["path"]) + ")"
    with doc_primitives.with_doc(doc):
        assert evaluate(f"is_group({arg})", {}).value is case["expected"]


def test_is_group_refuses_a_non_path_and_no_document():
    doc_primitives._current = None
    assert evaluate("is_group(path(0, 0))", {}).value is False
    from geometry.test_json import test_json_to_document
    with doc_primitives.with_doc(test_json_to_document(json.dumps(_fixture()["document"]))):
        assert evaluate("is_group('0.0')", {}).value is False
