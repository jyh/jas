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
