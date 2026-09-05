"""The panel-state WRITE arm of the shared chrome seam
(``test_fixtures/algorithms/panel_state_writes.json``).

WHY THIS FILE EXISTS
--------------------
``panel_menu_state.json`` pins how a panel menu's check marks are DERIVED from
a panel scope: it seeds the scope directly and asks each port to evaluate the
bundle's ``checked_when``.  What it deliberately did not pin is how that scope
comes to hold the user's choices — and that is exactly where the two active
ports diverged next.  ``jas_dioxus`` stored no Brushes panel state at all: its
``set_panel_state`` handler dispatched on the effect's ``key`` alone, ignored
the ``panel:`` the effect names, and fell through to the STROKE panel, so
``set_brush_view_mode`` wrote nothing and every Brushes check mark evaluated
the declared default forever.  ``JasSwift`` wrote the same effect into its
shared panel store and the check marks moved.  One description, two answers.

The subject of these vectors is therefore the ROUND TRIP, not the predicate:

    panel_state_defaults(panel)  ->  the generic set_panel_state effect  ->
    the panel scope read back    ->  menu_state over the panel's own menu

Each port drives it through its OWN storage: the reference through
``StateStore.init_panel`` / ``set_panel``, jas_dioxus through
``renderer::apply_set_panel_state_with_ctx`` and ``panels::panel_menu_ctx``,
JasSwift through ``StateStore`` and ``panelMenuContext``.  A port that stores
nothing returns the declared defaults and reds on the first case.

WHAT THE CASES COVER, and why each is here rather than one big case:

  * ``brushes_view_mode_list_disables_the_sizes`` — a write that moves a RADIO
    (Thumbnail/List) and, through ``enabled_when``, disables three other rows,
    so a port that stores the write but does not publish it into the menu
    context reds on the enabled column too.
  * ``brushes_thumbnail_size_large`` — a second, independent radio, so a port
    that hard-wires one key reds.
  * ``brushes_category_art_toggled_off`` — the write's VALUE is an expression
    over the panel's own live scope
    (``filter(panel.category_filter, ...)``).  A port that evaluates a write
    value against an empty or foreign ``panel`` scope reds here and nowhere
    else.
  * ``brushes_category_only_art`` — the opposite direction: exactly one
    category lit.  Together with the previous case, a predicate stuck True and
    a set of five predicates collapsed to one both red.
  * ``brushes_two_writes_accumulate`` — two writes in one case, so a store that
    replaces the scope instead of updating one key reds.
  * ``brushes_selected_library_{leaves,joins}_the_persistent_list`` — the
    ``Make Persistent`` row reads BOTH tiers
    (``preferences.brushes.persistent_libraries`` and
    ``panel.selected_library``); the two cases differ in both and answer
    False / True, so neither tier can be dropped.
  * ``symbols_selected_symbol`` — a second panel with no menu predicate at all,
    which is the anti-special-case arm: the storage must be generic, not a
    Brushes hook wearing a generic name.

WHAT THIS DOES NOT PIN.  The identifier a port uses for a panel scope: every
write here names the panel by its CONTENT id, which all three ports accept
verbatim.  Production actions name panels by the short form (``panel:
brushes``) and each port normalises that itself; those normalisations are each
port's own tests' subject.  Nor does it pin any action's effect LIST — the
cases issue the generic effect directly, so they say what storage must do, not
which action carries it.
"""
from __future__ import annotations

import json
import os

import pytest

from workspace_interpreter.effects import run_effects
from workspace_interpreter.loader import load_workspace, panel_state_defaults
from workspace_interpreter.menu_state import menu_state
from workspace_interpreter.state_store import StateStore

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURE = os.path.join(REPO_ROOT, "test_fixtures", "algorithms", "panel_state_writes.json")


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
    assert len(cases) >= 8, f"expected at least 8 cases, got {len(cases)}"
    assert all(c["args"]["writes"] for c in cases), "a case with no write pins nothing"
    checked_rows = sum(
        1 for c in cases for r in c["expected"]["menu"] if r["checked"] is not None
    )
    assert checked_rows >= 70, (
        f"expected at least 70 evaluated checked rows, got {checked_rows}"
    )


def test_every_case_moves_the_panel_scope(ws, cases):
    """The whole point is that a write CHANGES something.  A case whose expected
    scope equals the declared defaults is green in a port that stores nothing,
    which is the exact defect these vectors exist to catch."""
    for case in cases:
        pid = case["args"]["panel"]
        defaults = panel_state_defaults(ws["panels"][pid])
        assert case["expected"]["panel_state"] != defaults, (
            f"case {case['name']} expects the declared defaults — it cannot fail"
        )


def test_every_case_writes_through_the_yaml_spelling(cases):
    """The `write_as` field is the arm that pins the store-boundary rule; a
    case that writes by the content id it reads back by exercises nothing
    about spelling. Every case carries the SHORT kind."""
    for case in cases:
        pid = case["args"]["panel"]
        assert case["args"].get("write_as") == pid[: -len("_panel_content")], (
            f"case {case['name']} does not write through the YAML's spelling"
        )


def test_more_than_one_panel_is_covered(cases):
    """Generic storage means generic: a corpus naming a single panel would be
    satisfied by a Brushes-shaped special case."""
    assert len({c["args"]["panel"] for c in cases}) >= 2


def _run(ws, case):
    """The one description all three ports answer, in this port's storage."""
    pid = case["args"]["panel"]
    spec = ws["panels"][pid]
    store = StateStore()
    store.init_panel(pid, panel_state_defaults(spec))
    store.set_active_panel(pid)
    # `write_as` is the spelling the WRITE uses — the YAML's short kind
    # (`panel: brushes`) — while the scope is initialised and read back by
    # the content id. A store that does not canonicalise at its boundary
    # writes into a scope nothing initialised and reds here.
    write_as = case["args"].get("write_as", pid)
    for write in case["args"]["writes"]:
        run_effects(
            [{"set_panel_state": {"panel": write_as, "key": write["key"], "value": write["value"]}}],
            {},
            store,
        )
    scope = store.get_panel_state(pid)
    ctx = {"panel": scope, "preferences": case["args"]["preferences"]}
    return scope, menu_state([{"items": spec.get("menu", [])}], ctx)


def test_panel_state_write_vectors(ws, cases):
    for case in cases:
        assert case["function"] == "panel_state_writes", case["function"]
        scope, rows = _run(ws, case)
        assert scope == case["expected"]["panel_state"], f"scope for {case['name']}"
        assert rows == case["expected"]["menu"], f"menu for {case['name']}"
