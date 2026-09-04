"""The panel-menu arm of the shared chrome seam
(``test_fixtures/algorithms/panel_menu_state.json``).

WHY THIS FILE EXISTS
--------------------
``test_fixtures/algorithms/menu_state.json`` pins the MENUBAR's dynamic state
across the ports. Nothing pinned a PANEL menu's, and the gap was not academic:
until this corpus landed, ``jas_dioxus`` answered every panel-menu
``checked_when`` with a hard-coded ``false`` while ``JasSwift`` answered five of
the Brushes panel's with a HAND-CODED native rule. Five check marks worked in
one active port and did nothing in the other — a live prime-directive
divergence that no gate could see, because the actions themselves dispatched
fine and it was the *checked* affordance that diverged.

The subject is the SAME ``menu_state`` walk the menubar arm uses, applied to a
panel's ``menu:`` array wrapped as a single menu (``[{"items": menu}]``), so
paths read ``[0, i]``. Nothing panel-specific is evaluated: the fixture is the
one description all three implementations answer, and each port drives it
through its own ``menu_state`` port.

WHAT THE CASES COVER, and why each is here rather than one big case:

  * ``brushes_*`` — two cases, deliberately in OPPOSITE directions. The first
    lights every category (so a predicate stuck at True passes it), the second
    lights exactly ONE (so a predicate stuck at True, and a set of five
    predicates COLLAPSED to one, both red). They also flip view_mode and
    thumbnail_size between them, and flip the persistent-library membership.
  * ``color_``/``stroke_``/``swatches_`` — radio groups where exactly one row
    is lit, so a member that ignores its own params value reds.
  * ``opacity_`` — four independent toggles set to True/False/False/True, so
    any pair of them being confused for one another reds.

WHAT THIS DOES NOT PIN. The fixture seeds its context directly, exactly as the
menubar arm does; it says nothing about whether an app BUILDS that context from
its live state. That is each port's own responsibility and each port's own
tests' subject.
"""
from __future__ import annotations

import json
import os

import pytest

from workspace_interpreter.loader import load_workspace
from workspace_interpreter.menu_state import menu_state

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURE = os.path.join(REPO_ROOT, "test_fixtures", "algorithms", "panel_menu_state.json")


@pytest.fixture(scope="module")
def ws():
    return load_workspace(os.path.join(REPO_ROOT, "workspace"))


@pytest.fixture(scope="module")
def cases():
    with open(FIXTURE, encoding="utf-8") as f:
        return json.load(f)


def test_fixture_is_not_empty(cases):
    """A corpus runner that iterates an empty list passes vacuously; assert the
    work exists before asserting it is correct."""
    assert len(cases) >= 6, f"expected at least 6 cases, got {len(cases)}"
    checked_rows = sum(
        1 for c in cases for r in c["expected"] if r["checked"] is not None
    )
    assert checked_rows >= 29, (
        f"expected at least 29 evaluated checked_when rows, got {checked_rows}"
    )


def test_every_panel_menu_checked_when_in_the_workspace_is_covered(ws):
    """Census arm: the fixture must exercise EVERY panel whose menu carries a
    ``checked_when``. Without this the corpus silently stops covering a panel
    the day one is added."""
    with_checked = {
        pid
        for pid, spec in ws["panels"].items()
        for item in spec.get("menu", [])
        if isinstance(item, dict) and item.get("checked_when")
    }
    with open(FIXTURE, encoding="utf-8") as f:
        covered = {c["args"]["panel"] for c in json.load(f)}
    assert with_checked, "no panel menu declares checked_when — census is vacuous"
    assert with_checked <= covered, (
        f"panel menus with checked_when not covered by the corpus: "
        f"{sorted(with_checked - covered)}"
    )


def test_panel_menu_state_vectors(ws, cases):
    for case in cases:
        assert case["function"] == "panel_menu_state", case["function"]
        pid = case["args"]["panel"]
        menu = ws["panels"][pid]["menu"]
        actual = menu_state([{"items": menu}], case["args"]["ctx"])
        assert actual == case["expected"], f"case {case['name']} ({pid})"
