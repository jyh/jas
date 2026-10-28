"""The panel-key resolution corpus (test_fixtures/panel_keys/), run against the
reference: a chord resolves against one panel's `keyboard:` rows, found at any
depth, to {action, params} or null. Rust and Swift run the same file
(STATUS-jas item 8 class L, step 2)."""

import json
import os
from pathlib import Path

import pytest

from workspace_interpreter.loader import load_workspace
from workspace_interpreter.panel_keys import resolve_panel_key

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CORPUS = Path(REPO_ROOT, "test_fixtures", "panel_keys", "panel_key_resolution.json")


@pytest.fixture(scope="module")
def ws():
    return load_workspace(os.path.join(REPO_ROOT, "workspace"))


def _cases():
    return json.loads(CORPUS.read_text(encoding="utf-8"))["cases"]


def test_the_corpus_is_not_empty():
    cases = _cases()
    assert len(cases) >= 18, len(cases)
    # Both outcomes, or a resolver that always answers null passes half.
    assert any(c["expected"] is None for c in cases)
    assert sum(c["expected"] is not None for c in cases) >= 10


@pytest.mark.parametrize("case", _cases(), ids=lambda c: c["name"])
def test_panel_key_resolution(ws, case):
    panel = case["panel_spec"] if "panel_spec" in case else ws["panels"][case["panel"]]
    assert resolve_panel_key(panel, case["chord"], case["ctx"]) == case["expected"]
