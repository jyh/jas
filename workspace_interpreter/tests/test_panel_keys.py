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


def test_every_keyboard_row_names_an_action_and_only_its_params(ws):
    """A `keyboard:` row is a dispatch: its action must exist, and every param
    it passes must be one the action declares, or the action reads null. The
    Layers tree's F2 and Enter rows passed `element_id` to `rename_element`,
    which declares `path`, so the keys renamed nothing (found 2026-10-28,
    before any host routed a panel key). A templated action is checked per
    branch it can name."""
    import re
    from workspace_interpreter.panel_keys import keyboard_rows
    actions = ws["actions"]
    rows = [(pid, r) for pid, spec in ws["panels"].items() for r in keyboard_rows(spec)]
    assert len(rows) >= 15, f"positive control: only {len(rows)} keyboard rows"
    bad = []
    for pid, row in rows:
        raw = row.get("action", "")
        names = re.findall(r"'([a-z_]+)'", raw) if "{{" in raw else [raw]
        assert names, f"{pid} {row.get('key')}: no action name in {raw!r}"
        for name in names:
            if name not in actions:
                bad.append(f"{pid} {row.get('key')}: no action {name!r}")
                continue
            declared = set((actions[name].get("params") or {}).keys())
            for p in (row.get("params") or {}):
                if p not in declared:
                    bad.append(f"{pid} {row.get('key')}: {name} declares {sorted(declared)}, the row passes {p!r}")
    assert not bad, "\n".join(bad)
