#!/usr/bin/env python3
"""Derive test_fixtures/algorithms/picker_commits.json's goldens from the
SPEC (WIDGET_EVENTS.md: the `color_hue_bar` and `color_gradient` rows and
§The bound target), independently of any port's code.

    python3 scripts/derive_picker_commits_goldens.py test_fixtures/algorithms/picker_commits.json

A commit on the Color Picker's strip or field (finding 13, step 2b):

* The strip (`color_hue_bar`) parses ONE number `v` by the number grammar,
  clamped to [0, 1]; the field (`color_gradient`) parses `u,v`, two such
  numbers joined by one comma, each clamped. Any other text is `BadValue`.
* Off H mode (`dialog.radio_channel` present and not `h`) a parsed commit is
  `WrongMode`, detail `radio_channel=<mode>`, and writes nothing.
* In H mode the commit writes the PICK, rounded half away from zero, by bind
  ROLE: the strip's `value` takes `(1 - v) * 359`; the field's `saturation`
  and `brightness` take `100 u` and `100 (1 - v)`.

`value` is the parsed value (`v`, or `[u, v]`). ⛔ A write that lands on an
exact .5 is REFUSED, never written, as `derive_picker_picks_goldens.py`
refuses one: a tie would encode one implementation's rounding convention.

It is NOT part of any gate: the fixture on disk is the pinned truth, and
regenerating it is a deliberate act.
"""

import json
import math
import re
import sys

NUMBER = re.compile(r"-?[0-9]+(?:\.[0-9]+)?", re.ASCII)
HUE_MAX = 359.0

STRIP = [
    # (name, text, mode)
    ("strip_middle_is_magenta", "0.16666666666666666", None),
    ("strip_top_is_max", "0", "h"),
    ("strip_bottom_is_zero", "1", "h"),
    ("strip_interior", "0.27", "h"),
    ("strip_above_clamps_to_max", "-0.3", "h"),
    ("strip_below_clamps_to_zero", "1.4", "h"),
    ("strip_a_point_is_bad", "0.5,0.5", "h"),
    ("strip_a_word_is_bad", "a", "h"),
    ("strip_a_plus_sign_is_bad", "+0.5", "h"),
    ("strip_empty_is_bad", "", "h"),
    ("strip_off_h_is_wrong_mode", "0.25", "s"),
    ("strip_off_h_rgb_is_wrong_mode", "0.25", "bl"),
]
FIELD = [
    ("field_interior", "0.27,0.73", None),
    ("field_off_axis", "0.9,0.15", "h"),
    ("field_top_left_is_white", "0,0", "h"),
    ("field_right_of_clamps_to_full", "1.3,0.4", "h"),
    ("field_above_clamps_to_bright", "0.6,-0.2", "h"),
    ("field_one_coordinate_is_bad", "0.5", "h"),
    ("field_a_space_is_bad", "0.5, 0.5", "h"),
    ("field_three_coordinates_is_bad", "0.5,0.5,0.5", "h"),
    ("field_off_h_is_wrong_mode", "0.1,0.1", "b"),
]


def number(text):
    return float(text) if NUMBER.fullmatch(text) else None


def clamp01(x):
    return min(max(x, 0.0), 1.0)


def half_away(x, tag):
    frac = abs(x) - math.floor(abs(x))
    if abs(frac - 0.5) < 1e-9:
        raise SystemExit(f"REFUSED: {tag} lands on an exact .5 ({x!r}); choose another point")
    return math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5)


def vector(kind, name, text, mode):
    out = {"name": name, "kind": kind, "text": text}
    if mode is not None:
        out["radio_channel"] = mode
    if kind == "color_hue_bar":
        v = number(text)
        value = None if v is None else clamp01(v)
    else:
        parts = text.split(",")
        point = [number(p) for p in parts] if len(parts) == 2 else [None]
        value = None if None in point else [clamp01(p) for p in point]
    if value is None:
        return {**out, "refusal": "BadValue"}
    if mode not in (None, "h"):
        return {**out, "value": value, "refusal": "WrongMode", "detail": f"radio_channel={mode}"}
    if kind == "color_hue_bar":
        writes = {"value": half_away((1.0 - value) * HUE_MAX, name)}
    else:
        writes = {"saturation": half_away(100.0 * value[0], f"{name}.s"),
                  "brightness": half_away(100.0 * (1.0 - value[1]), f"{name}.b")}
    return {**out, "value": value, "writes": writes}


def main(path):
    vectors = [vector("color_hue_bar", *row) for row in STRIP] + \
              [vector("color_gradient", *row) for row in FIELD]
    doc = {
        "_doc": [
            "A commit on the Color Picker's strip (`color_hue_bar`, ONE number",
            "`v`) and field (`color_gradient`, `u,v`), each coordinate clamped",
            "to [0,1] (WIDGET_EVENTS.md). `refusal` is the class a refused",
            "commit names (`BadValue`, or `WrongMode` off H mode with its",
            "`detail`); otherwise `writes` is the pick each bind ROLE stores,",
            "rounded half away from zero: the strip's `value` (1 - v) 359, the",
            "field's `saturation` 100 u and `brightness` 100 (1 - v). An absent",
            "`radio_channel` is H mode. Derived from the spec by",
            "scripts/derive_picker_commits_goldens.py, not captured from a port;",
            "no write lands on an exact .5.",
        ],
        "vectors": vectors,
    }
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main(sys.argv[1])
