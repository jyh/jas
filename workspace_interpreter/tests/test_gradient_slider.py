"""The Gradient slider's law (reference arm).

Runs the shared cross-language corpus
``test_fixtures/gradient_stop/slider.json`` against the five slider
functions in ``workspace_interpreter.gradient_law``. The Rust
(``cross_language_test.rs``) and Swift (``GradientStopCorpusTests``) arms
read the SAME fixture.
"""

from __future__ import annotations

import copy
import json
import os

import pytest

from workspace_interpreter import gradient_law

FIXTURE = os.path.join(
    os.path.dirname(__file__), "..", "..", "test_fixtures", "gradient_stop",
    "slider.json",
)

with open(FIXTURE, encoding="utf-8") as _f:
    _VECTORS = json.load(_f)["vectors"]

#: Each op with the vector keys it takes, in argument order.
OPS = {
    "add_stop": ("location",),
    "delete_stop": ("index",),
    "drag_stop": ("index", "location", "dy"),
    "set_midpoint": ("pair", "value"),
    "drag_midpoint": ("pair", "location"),
}


def run(vec, law=gradient_law):
    """The vector's op applied by ``law``, shaped as the fixture's
    ``expected``: ``None``, ``{stops, index}`` or ``{stops}``."""
    args = [vec[k] for k in OPS[vec["op"]]]
    got = getattr(law, vec["op"])(vec["stops"], *args)
    if got is None:
        return None
    if vec["op"] in ("set_midpoint", "drag_midpoint"):
        return {"stops": got}
    stops, index = got
    return {"stops": stops, "index": index}


def test_corpus_is_not_vacuous():
    # Every op must be witnessed both writing and refusing, or a law that
    # refuses everything (or writes everything) for that op could pass.
    for op in OPS:
        mine = [v for v in _VECTORS if v["op"] == op]
        assert any(v["expected"] is None for v in mine), op
        assert sum(v["expected"] is not None for v in mine) >= 3, op
    assert {v["op"] for v in _VECTORS} == set(OPS)


@pytest.mark.parametrize("vec", _VECTORS, ids=[v["name"] for v in _VECTORS])
def test_slider_vector(vec):
    stops = copy.deepcopy(vec["stops"])
    got = run(vec)
    assert vec["stops"] == stops, "the law must not mutate its input"
    assert got == vec["expected"]


def _failing():
    return [v["name"] for v in _VECTORS if run(v) != v["expected"]]


def test_the_corpus_rejects_an_add_that_ignores_the_midpoint(monkeypatch):
    # value_at with every midpoint read as 50 must fail an add vector.
    real = gradient_law.value_at

    def flat(stops, location):
        return real([dict(s, midpoint_to_next=50) for s in stops], location)
    monkeypatch.setattr(gradient_law, "value_at", flat)
    assert _failing()


def test_the_corpus_rejects_round_half_even(monkeypatch):
    monkeypatch.setattr(gradient_law, "round_channel", round)
    assert _failing()


def test_the_corpus_rejects_an_inclusive_off_bar_threshold(monkeypatch):
    monkeypatch.setattr(gradient_law, "OFF_BAR_PX", 19.999)
    assert _failing()


def test_the_corpus_rejects_a_delete_that_never_resets(monkeypatch):
    real = gradient_law.delete_stop

    def no_reset(stops, index):
        got = real(stops, index)
        if got is None:
            return None
        out, idx = got
        mids = [s["midpoint_to_next"] for i, s in enumerate(stops) if i != index]
        return [dict(s, midpoint_to_next=m) for s, m in zip(out, mids)], idx
    monkeypatch.setattr(gradient_law, "delete_stop", no_reset)
    assert _failing()
