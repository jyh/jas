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
    any pair of them being confused for one another reds; and a second case
    with the selection MASKED, so the four mask rows are pinned in both
    directions.
  * ``concepts_`` / ``symbols_`` / ``artboards_`` / ``layers_`` — each panel
    whose menu carries an ``enabled_when`` gets one case per DIRECTION, so a
    predicate stuck at either answer reds. ``artboards_both_of_two_selected``
    is the one that separates "delete" (needs fewer than all) from
    "duplicate" (needs any); ``layers_two_shapes_selected_isolated`` is the
    one where ``is_container`` and ``has_group`` are both False while the
    count is 2, so a port that derives ``is_container`` from the count alone
    reds.
  * ``gradient_`` — every row is a literal ``enabled_when: "false"``; the case
    pins that a literal is honoured (both active ports answered ``true`` for
    every gradient row before the enabled arm went live).

WHAT ELSE THIS FILE PINS. Two census arms over the WORKSPACE, not the corpus:
every panel menu that declares ``enabled_when`` is covered here, in both
directions where the predicates admit both; and every read a panel-menu
predicate makes names a namespace an app can build — a bare identifier
outside the OPACITY.md selection predicates, or an ``active_document`` key
``runtime_contexts.yaml`` does not declare, reds. ``canvas_selection_non_empty``
was such a name for months (brushes.yaml's "New Brush"): no port supplied it,
the state-read gate could not see it (it resolves dotted heads only), and the
row was never greyed out anywhere.

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
from workspace_interpreter import expr_parser as ast

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
    assert len(cases) >= 16, f"expected at least 16 cases, got {len(cases)}"
    checked_rows = sum(
        1 for c in cases for r in c["expected"] if r["checked"] is not None
    )
    assert checked_rows >= 29, (
        f"expected at least 29 evaluated checked_when rows, got {checked_rows}"
    )
    # The enabled half has its own floor: a corpus in which every row reads
    # `enabled: true` pins nothing about enabled_when at all.
    disabled_rows = sum(
        1 for c in cases for r in c["expected"] if r["enabled"] is False
    )
    assert disabled_rows >= 30, (
        f"expected at least 30 disabled rows, got {disabled_rows}"
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


def _panel_menu_predicates(ws):
    """Every (panel id, key, expression) a panel's ``menu:`` block declares,
    over the three predicate keys the panel-menu vocabulary uses — and the
    ``keyboard:`` rows' ``enabled_when`` and ``params`` values, which evaluate
    against the same panel context (layers.yaml's rows read
    ``panel.layers_panel_selection[0]``)."""
    out = []
    for pid, spec in ws["panels"].items():
        for item in spec.get("menu", []):
            if not isinstance(item, dict):
                continue
            for key in ("enabled_when", "checked_when", "checked"):
                expr = item.get(key)
                if isinstance(expr, str) and expr:
                    out.append((pid, key, expr))
        for item in spec.get("keyboard", []):
            if not isinstance(item, dict):
                continue
            expr = item.get("enabled_when")
            if isinstance(expr, str) and expr:
                out.append((pid, "keyboard enabled_when", expr))
            for pname, pv in (item.get("params") or {}).items():
                if isinstance(pv, str) and pv:
                    out.append((pid, f"keyboard params.{pname}", pv))
    return out


def test_every_panel_menu_enabled_when_in_the_workspace_is_covered(ws, cases):
    """Census arm, the enabled twin of the checked one above: the fixture must
    exercise EVERY panel whose menu carries an ``enabled_when``."""
    with_enabled = {pid for pid, key, _ in _panel_menu_predicates(ws)
                    if key == "enabled_when"}
    covered = {c["args"]["panel"] for c in cases}
    assert with_enabled, "no panel menu declares enabled_when — census is vacuous"
    assert with_enabled <= covered, (
        f"panel menus with enabled_when not covered by the corpus: "
        f"{sorted(with_enabled - covered)}"
    )


def test_every_enabled_when_panel_is_pinned_in_both_directions(ws, cases):
    """A table's power is in its probes. For each panel with a non-literal
    ``enabled_when``, the corpus must hold a predicate-bearing row that reads
    True AND one that reads False — one direction alone cannot tell a
    predicate from a constant. Gradient's rows are all the literal ``false``
    and are exempt by that rule, not by name."""
    predicated = {}
    for pid, key, expr in _panel_menu_predicates(ws):
        if key == "enabled_when" and expr.strip() not in ("false", "true"):
            predicated.setdefault(pid, set()).add(expr)
    assert len(predicated) >= 7, f"positive control: {sorted(predicated)}"
    for pid in sorted(predicated):
        menu = ws["panels"][pid]["menu"]
        # The actions whose row carries a non-literal predicate.
        rows = {}
        for i, item in enumerate(menu):
            if isinstance(item, dict) and item.get("enabled_when") in predicated[pid]:
                rows[(0, i)] = item.get("action", "")
        seen = {True: set(), False: set()}
        for c in cases:
            if c["args"]["panel"] != pid:
                continue
            for r in c["expected"]:
                if tuple(r["path"]) in rows:
                    seen[r["enabled"]].add(r["action"])
        assert seen[True] and seen[False], (
            f"{pid}: predicate rows pinned enabled={sorted(seen[True])} "
            f"disabled={sorted(seen[False])} — both directions are required"
        )


# The four namespaces a panel-menu context publishes (the reference's
# ``eval_context`` and both active ports' ``panel_menu_ctx``), plus the bare
# OPACITY.md selection predicates the body and the menu place at top level.
_MENU_NAMESPACES = {"state", "panel", "active_document", "preferences"}
_BARE_PREDICATES = {
    "selection_has_mask", "selection_mask_clip", "selection_mask_invert",
    "selection_mask_linked", "editing_target_is_mask",
}


def _reads(node, bound=frozenset()):
    """Every free read in an expression AST as a tuple of path segments,
    with lambda parameters and ``let`` names excluded where they are bound.
    Parses with THIS package's own parser — a regex over the string would be
    a receiver assumption of its own (it is, in the two active ports' twins
    of this census, and this arm is the one that reads bare names)."""
    if isinstance(node, ast.Path):
        return [] if node.segments[0] in bound else [tuple(node.segments)]
    if isinstance(node, ast.Literal):
        return []
    if isinstance(node, ast.DotAccess):
        return _reads(node.obj, bound)
    if isinstance(node, ast.IndexAccess):
        return _reads(node.obj, bound) + _reads(node.index, bound)
    if isinstance(node, ast.FuncCall):
        return [r for a in node.args for r in _reads(a, bound)]
    if isinstance(node, (ast.BinaryOp, ast.LogicalOp, ast.Sequence)):
        return _reads(node.left, bound) + _reads(node.right, bound)
    if isinstance(node, ast.UnaryOp):
        return _reads(node.operand, bound)
    if isinstance(node, ast.Ternary):
        return (_reads(node.condition, bound) + _reads(node.true_expr, bound)
                + _reads(node.false_expr, bound))
    if isinstance(node, ast.Lambda):
        return _reads(node.body, bound | frozenset(node.params))
    if isinstance(node, ast.Let):
        return _reads(node.value, bound) + _reads(node.body, bound | {node.name})
    if isinstance(node, ast.Assign):
        return _reads(node.value, bound)
    raise AssertionError(f"unhandled AST node {type(node).__name__}")


def _undeclared_reads(expr: str, declared_active_document: set[str]) -> list[str]:
    """The reads in ``expr`` no app can build: a bare name outside the
    OPACITY.md five, a namespace head outside the four, or an
    ``active_document`` key ``runtime_contexts.yaml`` does not declare."""
    out = []
    for segs in _reads(ast.parse(expr)):
        if len(segs) == 1:
            if segs[0] not in _BARE_PREDICATES:
                out.append(segs[0])
        elif segs[0] not in _MENU_NAMESPACES:
            out.append(".".join(segs[:2]))
        elif segs[0] == "active_document" and segs[1] not in declared_active_document:
            out.append(".".join(segs[:2]))
    return out


@pytest.fixture(scope="module")
def declared_active_document():
    import yaml
    with open(os.path.join(REPO_ROOT, "workspace", "runtime_contexts.yaml"),
              encoding="utf-8") as f:
        ad = yaml.safe_load(f)["runtime_contexts"]["active_document"]
    return set(ad.get("properties", {})) | set(ad.get("defaults", {}))


def test_undeclared_read_census_catches_the_three_shapes(declared_active_document):
    """Self-test, FIRST: the census must red on each shape it exists to catch
    and stay green on the shapes it must not report."""
    assert _undeclared_reads("canvas_selection_non_empty", declared_active_document) == [
        "canvas_selection_non_empty"]
    assert _undeclared_reads("not active_document.no_such_key", declared_active_document) == [
        "active_document.no_such_key"]
    assert _undeclared_reads("document.recent_colors.length > 0", declared_active_document) == [
        "document.recent_colors"]
    # A lambda parameter is bound, a `let` name is bound, a string literal
    # is not a read, and every legitimate namespace passes.
    assert _undeclared_reads(
        'any(preferences.brushes.persistent_libraries, fun lib -> lib == panel.selected_library)',
        declared_active_document) == []
    assert _undeclared_reads('let n = panel.items.length in n > 0 and n < 5',
                             declared_active_document) == []
    assert _undeclared_reads('panel.view_mode == "thumbnail" and !selection_has_mask '
                             'and active_document.has_selection and state.fill_color != null',
                             declared_active_document) == []


def test_every_panel_menu_predicate_reads_a_namespace_an_app_can_build(
        ws, declared_active_document):
    """Every read in every panel-menu predicate resolves to a namespace the
    menu context publishes and, for ``active_document``, a key the runtime
    contract declares. The active ports' twins of this arm check that their
    LIVE context publishes each read; this arm checks that the read is one
    the contract admits at all, and it is the one that sees bare names."""
    preds = _panel_menu_predicates(ws)
    assert len(preds) >= 60, f"positive control: only {len(preds)} predicates"
    offenders = []
    for pid, key, expr in preds:
        for read in _undeclared_reads(expr, declared_active_document):
            offenders.append(f"{pid}: {key}: {expr!r} reads {read}")
    assert not offenders, "\n".join(offenders)


def _doc_with_a_rect_and_a_group():
    """A layer holding a rect at (0, 0) and a group at (0, 1): a layer is a
    container and not a group; a group is both; a rect is neither."""
    return {"layers": [{
        "kind": "Layer", "name": "L0",
        "children": [
            {"kind": "Rect", "x": 0, "y": 0, "width": 10, "height": 10},
            {"kind": "Group", "children": [
                {"kind": "Rect", "x": 20, "y": 0, "width": 10, "height": 10}]},
        ],
    }]}


@pytest.mark.parametrize("selection,is_container,has_group", [
    ([[0]], True, False),          # the layer: a container, not a group
    ([[0, 0]], False, False),      # the rect: neither
    ([[0, 1]], True, True),        # the group: both
    ([[0, 0], [0, 1]], False, True),  # two items: not the SOLE one; one is a group
    ([], False, False),
])
def test_reference_view_publishes_the_layers_rollups(ws, selection, is_container, has_group):
    """``runtime_contexts.yaml`` declared ``layers_panel_selection_is_container``
    and ``_has_group`` and NO port built them — layers.yaml's Enter Isolation
    Mode and Flatten Artwork rows read null wherever anything evaluated them.
    The reference builds them from the layers-panel selection now, and the
    layers menu evaluated against the LIVE context follows."""
    from workspace_interpreter.state_store import StateStore
    store = StateStore(document=_doc_with_a_rect_and_a_group())
    store.init_panel("layers", {
        "layers_panel_selection": [{"__path__": p} for p in selection],
        "isolation_stack": [],
    })
    store.set_active_panel("layers")
    ctx = store.eval_context()
    ad = ctx["active_document"]
    assert ad["layers_panel_selection_count"] == len(selection)
    assert ad["layers_panel_selection_is_container"] is is_container
    assert ad["layers_panel_selection_has_group"] is has_group
    rows = {r["action"]: r["enabled"]
            for r in menu_state([{"items": ws["panels"]["layers_panel_content"]["menu"]}], ctx)}
    assert rows["enter_isolation_mode"] is (len(selection) == 1 and is_container)
    assert rows["flatten_artwork"] is has_group
    assert rows["new_group"] is (len(selection) > 0)
    assert rows["collect_in_new_layer"] is (len(selection) > 0)
    assert rows["exit_isolation_mode"] is False

