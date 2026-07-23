"""Blocking reference validation of workspace/tests/gradient_primitives.yaml.

Until Arc 1 S4 this fixture's only consumer was the NON-GATING flask
reference renderer (jas_flask/tests/test_renderer.py), i.e. no blocking
consumer at all — the corpus-completeness gate
(scripts/check_corpus_manifest.py) now requires this file.

HONEST DEPTH: the reference interpreter has no widget RENDERER, so this
test validates the fixture as far as the reference's real passes reach —
and no further:

  * STRUCTURE of every gradient case and the slider stops — types,
    color/opacity/location domains, stop ordering, midpoint placement,
    selection indices. This is a data-shape validation written here (the
    workspace schema does not cover ad-hoc fixture state).
  * WIDGET TREE through the real ``widget_tree`` pass — every
    gradient_tile / gradient_slider must be recorded with its declared
    kind (NOT ``placeholder``), which pins that the reference's canonical
    widget vocabulary genuinely contains the two gradient primitives.
  * LAYOUT through the real ``layout_panel`` pass — every gradient widget
    must receive a rect (the pass knows the primitives' intrinsic sizes).
  * EXPRESSION EVALUATION where the reference's evaluator covers this
    fixture: every ``bind`` target is resolved through ``expr.evaluate``
    against the fixture's state and must return the bound structure. The
    fixture contains no computed expressions, so bare state lookups are
    the full evaluable surface.

What is NOT validated (and cannot be, from the reference): the pixel
rendering of tiles/sliders (checkerboards, midpoint diamonds, selection
chrome). That remains with the non-gating flask renderer and the ports'
own widget tests.

The fixture's ``panel`` uses a fixture-local shorthand (``.row`` /
``.hr`` / bare strings) that the compiled workspace vocabulary does not
carry; ``_normalize`` expands it into compiled-bundle-shaped nodes before
the real passes run, and asserts it saw only the shorthand forms it
understands (so a new shorthand cannot silently skip validation).
"""

from __future__ import annotations

import os
import re

import pytest
import yaml

from workspace_interpreter import expr
from workspace_interpreter.panel_layout import layout_panel
from workspace_interpreter.widget_tree import widget_tree

_FIXTURE_PATH = os.path.normpath(os.path.join(
    os.path.dirname(__file__), "..", "..",
    "workspace", "tests", "gradient_primitives.yaml",
))

_HEX_COLOR = re.compile(r"^#[0-9a-fA-F]{6}$")

_TILE_SIZES = {"small", "medium", "large"}


@pytest.fixture(scope="module")
def fixture() -> dict:
    with open(_FIXTURE_PATH, encoding="utf-8") as f:
        return yaml.safe_load(f)


# ---------------------------------------------------------------------------
# Fixture-local shorthand expansion (documented in the module docstring)
# ---------------------------------------------------------------------------

def _normalize(item):
    """Expand one fixture panel item into a compiled-bundle-shaped node."""
    if isinstance(item, str):
        if item == ".hr":
            return {"type": "separator"}
        return {"type": "text", "content": item}
    if isinstance(item, dict):
        if ".row" in item:
            children = item[".row"]
            assert isinstance(children, list), ".row must hold a list"
            return {"type": "row",
                    "children": [_normalize(c) for c in children]}
        assert "type" in item, f"panel dict without type: {item!r}"
        return item
    raise AssertionError(f"unknown panel shorthand: {item!r}")


def _panel_node(fixture: dict) -> dict:
    items = fixture.get("panel")
    assert isinstance(items, list) and items, "fixture must declare a panel"
    return {"content": {"type": "col",
                        "children": [_normalize(i) for i in items]}}


# ---------------------------------------------------------------------------
# Structural validation of the gradient data
# ---------------------------------------------------------------------------

def _validate_stops(stops, label: str):
    assert isinstance(stops, list) and len(stops) >= 2, \
        f"{label}: at least two stops"
    locations = []
    for i, stop in enumerate(stops):
        assert isinstance(stop, dict), f"{label} stop {i}: not a mapping"
        assert _HEX_COLOR.match(str(stop.get("color", ""))), \
            f"{label} stop {i}: color must be #rrggbb, got {stop.get('color')!r}"
        opacity = stop.get("opacity")
        assert isinstance(opacity, (int, float)) and 0 <= opacity <= 100, \
            f"{label} stop {i}: opacity out of [0,100]: {opacity!r}"
        loc = stop.get("location")
        assert isinstance(loc, (int, float)) and 0 <= loc <= 100, \
            f"{label} stop {i}: location out of [0,100]: {loc!r}"
        locations.append(loc)
        mid = stop.get("midpoint_to_next")
        if i < len(stops) - 1:
            assert isinstance(mid, (int, float)) and 0 < mid < 100, \
                f"{label} stop {i}: midpoint_to_next out of (0,100): {mid!r}"
        else:
            assert mid is None, \
                f"{label} last stop must not carry midpoint_to_next"
    assert locations == sorted(locations), \
        f"{label}: stop locations must be non-decreasing: {locations}"
    assert locations[0] == 0 and locations[-1] == 100, \
        f"{label}: stops must span 0..100, got {locations}"


def _gradient_state_keys(state: dict) -> list[str]:
    return [k for k, v in state.items()
            if isinstance(v, dict) and "stops" in v]


def test_fixture_loads(fixture):
    assert isinstance(fixture.get("description"), str) and fixture["description"]
    assert isinstance(fixture.get("state"), dict)
    assert isinstance(fixture.get("panel"), list)


def test_every_gradient_case_is_structurally_valid(fixture):
    state = fixture["state"]
    gradients = _gradient_state_keys(state)
    assert len(gradients) == 3, f"expected 3 gradient cases, got {gradients}"
    for key in gradients:
        g = state[key]
        assert g.get("type") in ("linear", "radial"), \
            f"{key}: gradient type must be linear|radial, got {g.get('type')!r}"
        angle = g.get("angle")
        assert isinstance(angle, (int, float)) and 0 <= angle < 360, \
            f"{key}: angle out of [0,360): {angle!r}"
        ar = g.get("aspect_ratio")
        assert isinstance(ar, (int, float)) and ar > 0, \
            f"{key}: aspect_ratio must be positive: {ar!r}"
        assert g.get("method") in ("classic", "smooth"), \
            f"{key}: method must be classic|smooth, got {g.get('method')!r}"
        assert isinstance(g.get("dither"), bool), f"{key}: dither must be bool"
        _validate_stops(g["stops"], key)
    # The corpus must exercise both gradient geometries.
    types = {state[k]["type"] for k in gradients}
    assert types == {"linear", "radial"}, \
        f"gradient cases must cover linear AND radial, got {types}"


def test_slider_stops_and_selection_are_valid(fixture):
    state = fixture["state"]
    stops = state.get("slider_stops")
    _validate_stops(stops, "slider_stops")
    sel = state.get("selected_stop_index")
    assert isinstance(sel, int) and 0 <= sel < len(stops), \
        f"selected_stop_index out of range: {sel!r}"
    mid = state.get("selected_midpoint_index")
    # None (no midpoint selected) or a valid midpoint index (between stops).
    assert mid is None or (isinstance(mid, int) and 0 <= mid < len(stops) - 1), \
        f"selected_midpoint_index invalid: {mid!r}"


# ---------------------------------------------------------------------------
# The real reference passes: widget tree + layout
# ---------------------------------------------------------------------------

def test_widget_tree_records_all_gradient_primitives(fixture):
    records = widget_tree(_panel_node(fixture))
    tiles = [r for r in records if r["type"] == "gradient_tile"]
    sliders = [r for r in records if r["type"] == "gradient_slider"]
    # 3 sizes x 3 gradients + 1 slider.
    assert len(tiles) == 9, f"expected 9 gradient tiles, got {len(tiles)}"
    assert len(sliders) == 1, f"expected 1 gradient slider, got {len(sliders)}"
    for r in tiles + sliders:
        # kind == type pins that the reference's canonical widget
        # vocabulary contains the gradient primitives (a placeholder here
        # would mean the reference does not know the widget).
        assert r["kind"] == r["type"], \
            f"{r['type']} at {r['path']} degraded to {r['kind']}"
    for r in tiles:
        assert r["bind"] == ["gradient"], \
            f"tile at {r['path']}: bind keys {r['bind']}"
    assert sliders[0]["bind"] == \
        ["selected_midpoint_index", "selected_stop_index", "stops"], \
        f"slider bind keys: {sliders[0]['bind']}"


def test_tiles_cover_all_three_sizes(fixture):
    node = _panel_node(fixture)["content"]
    sizes: list[str] = []

    def walk(n):
        if n.get("type") == "gradient_tile":
            assert n.get("size") in _TILE_SIZES, \
                f"gradient_tile size invalid: {n.get('size')!r}"
            sizes.append(n["size"])
        for c in n.get("children") or []:
            if isinstance(c, dict):
                walk(c)

    walk(node)
    assert sorted(sizes) == sorted(["small", "medium", "large"] * 3), \
        f"expected 3 tiles of each size, got {sizes}"


def test_layout_pass_gives_every_gradient_widget_a_rect(fixture):
    node = _panel_node(fixture)
    records = widget_tree(node)
    rects = {tuple(r["path"]): r["rect"] for r in layout_panel(node, 320)}
    for r in records:
        if r["type"] not in ("gradient_tile", "gradient_slider"):
            continue
        rect = rects.get(tuple(r["path"]))
        assert rect is not None, f"{r['type']} at {r['path']} got no rect"
        assert rect["w"] > 0 and rect["h"] > 0, \
            f"{r['type']} at {r['path']} has a degenerate rect: {rect}"


# ---------------------------------------------------------------------------
# Expression evaluation of the binds (the fixture's evaluable surface)
# ---------------------------------------------------------------------------

def test_every_bind_resolves_through_the_reference_evaluator(fixture):
    state = fixture["state"]
    ctx = {"state": state}
    node = _panel_node(fixture)["content"]
    checked = 0

    def walk(n):
        nonlocal checked
        for key, target in (n.get("bind") or {}).items():
            assert isinstance(target, str) and target, \
                f"bind {key} must name a state key, got {target!r}"
            assert target in state, \
                f"bind {key} -> {target!r} names no fixture state key"
            result = expr.evaluate(f"state.{target}", ctx)
            value = getattr(result, "value", result)
            assert value == state[target], \
                f"evaluator resolved state.{target} to {value!r}"
            checked += 1
        for c in n.get("children") or []:
            if isinstance(c, dict):
                walk(c)

    walk(node)
    # 9 tiles x 1 bind + 1 slider x 3 binds.
    assert checked == 12, f"expected 12 bind resolutions, checked {checked}"
