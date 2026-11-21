"""The Gradient panel's stop-edit law (reference arm).

Runs the shared cross-language corpus
``test_fixtures/gradient_stop/stop_edit.json`` against
``workspace_interpreter.gradient_law.edit_stop``. The Rust
(``cross_language_test.rs``) and Swift (``GradientStopCorpusTests``) arms
read the SAME fixture.
"""

from __future__ import annotations

import copy
import json
import os

import pytest

from workspace_interpreter.gradient_law import edit_stop

FIXTURE = os.path.join(
    os.path.dirname(__file__), "..", "..", "test_fixtures", "gradient_stop",
    "stop_edit.json",
)

with open(FIXTURE, encoding="utf-8") as _f:
    _VECTORS = json.load(_f)["vectors"]


def test_corpus_is_not_vacuous():
    # Both outcomes and both fields must be present, or a law that
    # refuses everything (or writes everything) could pass.
    refused = [v for v in _VECTORS if v["expected"] is None]
    written = [v for v in _VECTORS if v["expected"] is not None]
    assert len(refused) >= 3 and len(written) >= 5
    assert {v["field"] for v in written} == {"opacity", "location"}
    assert any(v["expected"]["index"] != v["index"] for v in written)


@pytest.mark.parametrize("vec", _VECTORS, ids=[v["name"] for v in _VECTORS])
def test_stop_edit_vector(vec):
    stops = copy.deepcopy(vec["stops"])
    got = edit_stop(stops, vec["index"], vec["field"], vec["value"])
    assert stops == vec["stops"], "edit_stop must not mutate its input"
    if vec["expected"] is None:
        assert got is None
    else:
        assert got is not None
        new_stops, new_index = got
        assert new_stops == vec["expected"]["stops"]
        assert new_index == vec["expected"]["index"]


def test_the_corpus_rejects_a_law_that_never_resets_midpoints():
    # Anti-vacuity for the reorder half: a law that sorts but never resets
    # midpoints must fail at least one vector.
    def no_reset(stops, index, field, value):
        got = edit_stop(stops, index, field, value)
        if got is None or field != "location":
            return got
        out, idx = got
        by_color = {s["color"]: s["midpoint_to_next"] for s in stops}
        return [dict(s, midpoint_to_next=by_color[s["color"]]) for s in out], idx
    fails = [v["name"] for v in _VECTORS if v["expected"] is not None
             and no_reset(v["stops"], v["index"], v["field"], v["value"])
             != (v["expected"]["stops"], v["expected"]["index"])]
    assert fails


# ── The Location combo on a selected MIDPOINT (row 198) ──────────────────
# GRADIENT.md STOP_LOCATION_COMBO: "For a selected midpoint: the midpoint's
# absolute location, clamped between the two neighbor stops." The bind_values
# corpus carries the panel at a midpoint and at a stop; the expectation is
# derived from each case's own ctx, never typed.

def _bind_case(name):
    path = os.path.join(os.path.dirname(__file__), "..", "..", "test_fixtures",
                        "algorithms", "panel_bind_values.json")
    with open(path, encoding="utf-8") as f:
        cases = json.load(f)
    hits = [c for c in cases if c["name"] == name]
    assert len(hits) == 1, f"{name}: {len(hits)} cases"
    return hits[0]


def _location_row(case):
    rows = [r for r in case["expected"]
            if r["id"] == "grad_stop_location_combo" and r["key"] == "bind.value"]
    assert len(rows) == 1, rows
    return rows[0]


def _ctx_panel(case):
    ctx = case["args"]["ctx"] if "ctx" in case["args"] else case["args"][-1]
    return ctx["panel"]


@pytest.mark.parametrize("name", ["gradient@midpoint_selected", "gradient@stop_selected"])
def test_the_location_combo_shows_the_selected_marker(name):
    case = _bind_case(name)
    panel = _ctx_panel(case)
    stops, mid, stop = panel["stops"], panel["selected_midpoint_index"], panel["selected_stop_index"]
    if mid >= 0:
        a, b = stops[mid], stops[mid + 1]
        want = a["location"] + (b["location"] - a["location"]) * a["midpoint_to_next"] / 100
    else:
        want = stops[stop]["location"]
    row = _location_row(case)
    assert row["type"] == "number", row
    assert float(row["value"]) == pytest.approx(want), row


# ── The stop-colour law (row 198) ────────────────────────────────────────

def _color_corpus():
    path = os.path.join(os.path.dirname(__file__), "..", "..", "test_fixtures",
                        "gradient_stop", "stop_color.json")
    with open(path, encoding="utf-8") as f:
        return json.load(f)["vectors"]


def test_the_colour_corpus_is_not_vacuous():
    vecs = _color_corpus()
    assert sum(v["expected"] is None for v in vecs) >= 4
    assert sum(v["expected"] is not None for v in vecs) >= 2


@pytest.mark.parametrize("vec", _color_corpus(), ids=lambda v: v["name"])
def test_stop_color_vector(vec):
    from workspace_interpreter.gradient_law import set_stop_color
    stops = copy.deepcopy(vec["stops"])
    got = set_stop_color(stops, vec["index"], vec["value"])
    assert stops == vec["stops"], "the law does not mutate its input"
    if vec["expected"] is None:
        assert got is None
    else:
        assert got == (vec["expected"]["stops"], vec["expected"]["index"])
