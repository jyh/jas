"""`active_document.element_tree`: the document's rows for the Layers panel's
`tree_view` (STATUS-jas item 38 step 1), against the shared fixture
`test_fixtures/layers/element_tree.json`, which the active ports read too."""

from __future__ import annotations

import json
import os

import pytest

from workspace_interpreter.state_store import StateStore

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
