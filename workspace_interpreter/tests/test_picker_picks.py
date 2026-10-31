"""The Color Picker's two picks: a normalized point -> the value written.

Held to test_fixtures/algorithms/picker_picks.json, whose goldens are derived
from the spec's formula (scripts/derive_picker_picks_goldens.py), not from this
code.
"""
import json
import math
import os

from workspace_interpreter import color_util

FIXTURE = os.path.join(
    os.path.dirname(__file__), "..", "..", "test_fixtures", "algorithms", "picker_picks.json")


def _vectors(function):
    with open(FIXTURE, encoding="utf-8") as f:
        return [v for v in json.load(f)["vectors"] if v["function"] == function]


def _half_away(x):
    return math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5)


def test_every_strip_vector_maps_to_its_golden():
    vectors = _vectors("strip_value")
    assert len(vectors) >= 8
    for v in vectors:
        got = color_util.strip_value(v["v"], v["max"])
        assert abs(got - v["expected"]) < 1e-9, (v["name"], got)
        assert _half_away(got) == v["written"], v["name"]


def test_every_gradient_vector_maps_to_its_golden():
    vectors = _vectors("gradient_sb")
    assert len(vectors) >= 8
    for v in vectors:
        s, b = color_util.gradient_sb(v["u"], v["v"])
        assert abs(s - v["expected"][0]) < 1e-9 and abs(b - v["expected"][1]) < 1e-9, (v["name"], s, b)
        assert [_half_away(s), _half_away(b)] == v["written"], v["name"]


def test_the_strip_middle_is_magenta_not_yellow():
    # One sixth down the hue strip picks 299 (magenta). A strip drawn
    # red-yellow-green top-down would show yellow there; the ends cannot tell.
    assert _half_away(color_util.strip_value(1.0 / 6.0, 359.0)) == 299
