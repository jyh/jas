#!/usr/bin/env python3
"""Derive test_fixtures/algorithms/picker_picks.json's goldens from the SPEC'S
FORMULA (workspace/dialogs/color_picker.yaml, `cp_colorbar` and
`cp_gradient`), independently of any port's code.

    python3 scripts/derive_picker_picks_goldens.py test_fixtures/algorithms/picker_picks.json

Two pick functions, each over a point normalized to [0, 1] (`u` left to
right, `v` top to bottom, each clamped):

* `strip_value(v, max)`: the Color Picker's vertical strip. TOP IS MAX for
  every channel (h 359, s and b 100, r g b 255), so the value is
  `(1 - v) * max`. The H-mode picture is drawn top to bottom red, magenta,
  blue, cyan, green, yellow, red, so the pick lands on the hue drawn under it.
* `gradient_sb(u, v)`: the field. `u` is saturation, `v` is brightness
  upside down: `(100 u, 100 (1 - v))`.

`expected` is the exact value; `written` is what a pick stores, rounded half
AWAY from zero as every app rounds. ⛔ A vector whose value lands on an exact
.5 is REFUSED, never written: the reference's `round` is half-to-even, so a
tie would make the golden encode a convention one implementation does not
share. The mid-strip vector (v = 1/6) is the one that caught the strip's
picture disagreeing with its pick in both ports (10-30); the ends cannot see
that, because 0 and 360 are both red.

It is NOT part of any gate: the fixture on disk is the pinned truth, and
regenerating it is a deliberate act.
"""
import json
import math
import sys

STRIP = [
    # (name, v, max)
    ("hue_top_is_max", 0.0, 359.0),
    ("hue_bottom_is_zero", 1.0, 359.0),
    ("hue_one_sixth_down_is_magenta", 1.0 / 6.0, 359.0),
    ("hue_two_thirds_down_is_green", 2.0 / 3.0, 359.0),
    ("hue_above_the_strip_clamps_to_max", -0.3, 359.0),
    ("hue_below_the_strip_clamps_to_zero", 1.4, 359.0),
    ("percent_centre_is_half", 0.5, 100.0),
    ("percent_interior", 0.27, 100.0),
    ("byte_quarter_down", 0.25, 255.0),
    ("byte_interior", 0.85, 255.0),
]

GRADIENT = [
    # (name, u, v)
    ("top_left_is_white", 0.0, 0.0),
    ("top_right_is_the_pure_hue", 1.0, 0.0),
    ("bottom_left_is_black", 0.0, 1.0),
    ("bottom_right_is_black", 1.0, 1.0),
    ("centre_is_half_and_half", 0.5, 0.5),
    ("interior", 0.27, 0.73),
    ("interior_off_axis", 0.9, 0.15),
    ("left_of_the_field_clamps_to_grey", -0.4, 0.4),
    ("right_of_the_field_clamps_to_full", 1.3, 0.4),
    ("above_the_field_clamps_to_bright", 0.6, -0.2),
    ("below_the_field_clamps_to_black", 0.6, 1.7),
]


def half_away(x, tag):
    frac = abs(x) - math.floor(abs(x))
    if abs(frac - 0.5) < 1e-9:
        raise SystemExit(f"REFUSED: {tag} lands on an exact .5 ({x!r}); choose another point")
    return math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5)


def clamp01(x):
    return min(max(x, 0.0), 1.0)


def strip_value(v, mx):
    return (1.0 - clamp01(v)) * mx


def gradient_sb(u, v):
    return (100.0 * clamp01(u), 100.0 * (1.0 - clamp01(v)))


def main(out):
    vectors = []
    for n, v, mx in STRIP:
        x = strip_value(v, mx)
        vectors.append({"name": n, "function": "strip_value", "v": v, "max": mx,
                        "expected": x, "written": half_away(x, n)})
    for n, u, v in GRADIENT:
        s, b = gradient_sb(u, v)
        vectors.append({"name": n, "function": "gradient_sb", "u": u, "v": v,
                        "expected": [s, b],
                        "written": [half_away(s, f"{n}.s"), half_away(b, f"{n}.b")]})
    doc = {
        "_doc": [
            "The Color Picker's two pick functions, each over a point normalized",
            "to [0,1] (`u` left to right, `v` top to bottom, each clamped):",
            "`strip_value(v, max)` = (1 - v) max, the vertical strip, TOP IS MAX",
            "for every channel; `gradient_sb(u, v)` = (100 u, 100 (1 - v)), the",
            "field's saturation and brightness (workspace/dialogs/color_picker.yaml).",
            "`expected` is exact, compared within 1e-9; `written` is what a pick",
            "stores, rounded half away from zero. Goldens are derived from the",
            "formula by scripts/derive_picker_picks_goldens.py, not captured from",
            "a port, and no vector lands on an exact .5 rounding tie. The",
            "v = 1/6 vector pins the strip's MIDDLE, where a picture drawn the",
            "other way up disagrees with the pick (the ends are both red).",
        ],
        "vectors": vectors,
    }
    with open(out, "w", encoding="utf-8", newline="") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    for vec in vectors:
        print(f"  {vec['function']:<12} {vec['name']:<40} {vec['written']}")


if __name__ == "__main__":
    main(sys.argv[1])
