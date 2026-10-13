#!/usr/bin/env python3
"""Derive test_fixtures/algorithms/color_bar.json's goldens from the SPEC'S
FORMULA (workspace/panels/color.yaml, `cp_color_bar`), independently of any
port's code.

    python3 scripts/derive_color_bar_goldens.py test_fixtures/algorithms/color_bar.json

The point is normalized: `u` runs 0..1 left to right, `v` 0..1 top to bottom,
each clamped to [0, 1]. Hue is 360 u. The top half (v <= 1/2) ramps saturation
0 -> 100 % while brightness goes 100 -> 80 %; the bottom half holds saturation
at 100 % while brightness goes 80 -> 0 %. HSB -> RGB is the colour corpus's
conversion (`color_convert.json`), rounded half AWAY from zero as every app
rounds. ⛔ A vector whose channel lands on an exact .5 is REFUSED, never
written: the reference's `round` is half-to-even, so a tie would make the
golden encode a convention one implementation does not share.

It is NOT part of any gate: the fixture on disk is the pinned truth, and
regenerating it is a deliberate act.
"""
import json
import math
import sys

VECTORS = [
    # (name, u, v)
    ("top_left_is_white", 0.0, 0.0),
    ("bottom_left_is_black", 0.0, 1.0),
    ("middle_left_is_full_red", 0.0, 0.5),
    ("middle_third_is_full_green", 1.0 / 3.0, 0.5),
    ("middle_centre_is_full_cyan", 0.5, 0.5),
    ("middle_right_is_red_again", 1.0, 0.5),
    ("top_quarter_is_a_pastel", 0.27, 0.23),
    ("bottom_quarter_is_a_dark_shade", 0.75, 0.75),
    ("interior_top_half", 0.6, 0.1),
    ("interior_bottom_half", 0.15, 0.9),
    ("just_above_the_seam", 0.4, 0.49),
    ("just_below_the_seam", 0.4, 0.51),
    ("left_of_the_bar_clamps_to_hue_0", -0.2, 0.5),
    ("right_of_the_bar_clamps_to_hue_360", 1.3, 0.5),
    ("above_the_bar_clamps_to_white", 0.7, -0.4),
    ("below_the_bar_clamps_to_black", 0.7, 1.6),
]


def half_away(x, tag):
    frac = abs(x) - math.floor(abs(x))
    if abs(frac - 0.5) < 1e-9:
        raise SystemExit(f"REFUSED: {tag} lands on an exact .5 ({x!r}); choose another point")
    return math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5)


def clamp01(x):
    return min(max(x, 0.0), 1.0)


def color_bar(name, u, v):
    hue = 360.0 * clamp01(u)
    v = clamp01(v)
    if v <= 0.5:
        t = v / 0.5
        sat, br = t * 100.0, 100.0 - t * 20.0
    else:
        t = (v - 0.5) / 0.5
        sat, br = 100.0, 80.0 * (1.0 - t)
    s1, b1 = sat / 100.0, br / 100.0
    c = b1 * s1
    x = c * (1 - abs((hue / 60.0) % 2 - 1))
    m = b1 - c
    if hue < 60:
        rgb = (c, x, 0.0)
    elif hue < 120:
        rgb = (x, c, 0.0)
    elif hue < 180:
        rgb = (0.0, c, x)
    elif hue < 240:
        rgb = (0.0, x, c)
    elif hue < 300:
        rgb = (x, 0.0, c)
    else:
        rgb = (c, 0.0, x)
    r, g, b = (half_away((ch + m) * 255, f"{name}.{k}") for ch, k in zip(rgb, "rgb"))
    return f"#{r:02x}{g:02x}{b:02x}"


def main(out):
    doc = {
        "_doc": [
            "The Color panel's colour bar (`cp_color_bar`): a point normalized to",
            "[0,1]^2 -> the colour the bar shows there, as #rrggbb lowercase.",
            "`u` runs left to right, `v` top to bottom, each clamped to [0, 1];",
            "hue is 360 u; the top half ramps saturation 0->100 % with brightness",
            "100->80 %, the bottom half holds saturation 100 % with brightness",
            "80->0 % (workspace/panels/color.yaml). ONE function per port maps it,",
            "and every view of the bar calls it with its own pixel point divided",
            "by its own size. Goldens are derived from that formula by",
            "scripts/derive_color_bar_goldens.py, not captured from a port, and",
            "no vector lands on an exact .5 rounding tie.",
        ],
        "vectors": [
            {"name": n, "u": u, "v": v, "expected": color_bar(n, u, v)}
            for n, u, v in VECTORS
        ],
    }
    with open(out, "w", encoding="utf-8", newline="") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    for vec in doc["vectors"]:
        print(f"  {vec['name']:<40} {vec['expected']}")


if __name__ == "__main__":
    main(sys.argv[1])
