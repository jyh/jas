"""The Color panel's colour bar: a normalized point -> the colour shown there.

Held to test_fixtures/algorithms/color_bar.json, whose goldens are derived from
the spec's formula (scripts/derive_color_bar_goldens.py), not from this code.
"""
import json
import os

from workspace_interpreter import color_util

FIXTURE = os.path.join(
    os.path.dirname(__file__), "..", "..", "test_fixtures", "algorithms", "color_bar.json")


def _vectors():
    with open(FIXTURE, encoding="utf-8") as f:
        return json.load(f)["vectors"]


def test_every_vector_maps_to_its_golden():
    vectors = _vectors()
    assert len(vectors) >= 12
    misses = [(v["name"], color_util.color_bar_hex(v["u"], v["v"]), v["expected"])
              for v in vectors if color_util.color_bar_hex(v["u"], v["v"]) != v["expected"]]
    assert misses == []


def test_the_rgb_and_the_hex_are_one_colour():
    for v in _vectors():
        assert color_util.rgb_to_hex(*color_util.color_bar_rgb(v["u"], v["v"])) == v["expected"]


def test_the_seam_is_continuous():
    # v = 1/2 from above and below meet at full saturation, 80 % brightness.
    assert color_util.color_bar_hex(0.0, 0.5) == "#cc0000"
    assert color_util.color_bar_hex(0.0, 0.5 - 1e-12) == "#cc0000"
    assert color_util.color_bar_hex(0.0, 0.5 + 1e-12) == "#cc0000"
