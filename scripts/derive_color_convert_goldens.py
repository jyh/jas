#!/usr/bin/env python3
"""Derive test_fixtures/algorithms/color_convert.json's goldens from the SPEC
FORMULAS, independently of any port's code.

Run it to REGENERATE the fixture:

    python3 scripts/derive_color_convert_goldens.py \
        test_fixtures/algorithms/color_convert.json

It exists so the corpus's central claim -- that its goldens were derived and
not captured from an implementation -- is auditable rather than asserted. It is
NOT part of any gate: the fixture on disk is the pinned truth, and regenerating
it is a deliberate act. Two things it reports on every run, both load-bearing:
which vectors land on an exact x.5 rounding boundary (and whether half-away and
half-to-even agree there, so no golden can quietly encode a convention the ports
do not share), and which panel_channels vectors actually DISCRIMINATE the two
orderings the family exists to separate -- a family of vectors that all agree
either way would be a gate in name only.

Rounding: every app rounds half AWAY FROM ZERO (Rust `f64::round`, Swift
`Double.rounded()`). Python's builtin `round` is half-to-EVEN, so this
generator uses an explicit `half_away` and REPORTS every vector that lands on
an exact .5 boundary, so a golden can never silently encode one convention
where the ports use the other.
"""
import json
import math
import os
import sys

HALF_HITS = []


def half_away(x, tag):
    frac = abs(x) - math.floor(abs(x))
    if abs(frac - 0.5) < 1e-12:
        HALF_HITS.append((tag, x))
    return math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5)


def quantise8(v, tag):
    """The float→u8 step: round half away from zero, saturating (Rust `as u8`)."""
    x = half_away(v * 255.0, tag)
    return max(0, min(255, x))


def rgb_to_hsb(r, g, b, tag=""):
    r1, g1, b1 = r / 255.0, g / 255.0, b / 255.0
    mx, mn = max(r1, g1, b1), min(r1, g1, b1)
    d = mx - mn
    s = 0.0 if mx == 0.0 else d / mx
    v = mx
    h = 0.0
    if d > 0.0:
        if mx == r1:
            h = ((g1 - b1) / d + (6.0 if g1 < b1 else 0.0)) / 6.0
        elif mx == g1:
            h = ((b1 - r1) / d + 2.0) / 6.0
        else:
            h = ((r1 - g1) / d + 4.0) / 6.0
    return (half_away(h * 360.0, tag + ".h") % 360,
            half_away(s * 100.0, tag + ".s"),
            half_away(v * 100.0, tag + ".b"))


def hsb_to_rgb(h, s, b, tag=""):
    s1, b1 = s / 100.0, b / 100.0
    c = b1 * s1
    x = c * (1.0 - abs(math.fmod(h / 60.0, 2.0) - 1.0))
    m = b1 - c
    if h < 60.0:
        r1, g1, b1_ = c, x, 0.0
    elif h < 120.0:
        r1, g1, b1_ = x, c, 0.0
    elif h < 180.0:
        r1, g1, b1_ = 0.0, c, x
    elif h < 240.0:
        r1, g1, b1_ = 0.0, x, c
    elif h < 300.0:
        r1, g1, b1_ = x, 0.0, c
    else:
        r1, g1, b1_ = c, 0.0, x
    return tuple(half_away((v + m) * 255.0, tag + ".rgb") for v in (r1, g1, b1_))


def rgb_to_cmyk(r, g, b, tag=""):
    if r == 0 and g == 0 and b == 0:
        return (0, 0, 0, 100)
    c1, m1, y1 = 1.0 - r / 255.0, 1.0 - g / 255.0, 1.0 - b / 255.0
    k1 = min(c1, m1, y1)
    return (half_away((c1 - k1) / (1.0 - k1) * 100.0, tag + ".c"),
            half_away((m1 - k1) / (1.0 - k1) * 100.0, tag + ".m"),
            half_away((y1 - k1) / (1.0 - k1) * 100.0, tag + ".y"),
            half_away(k1 * 100.0, tag + ".k"))


def panel_channels(rf, gf, bf, tag=""):
    """The Color-panel overlay pipeline: QUANTISE TO 8 BITS FIRST, then derive
    every channel from those three integers."""
    r = quantise8(rf, tag + ".r")
    g = quantise8(gf, tag + ".g")
    b = quantise8(bf, tag + ".b")
    h, s, br = rgb_to_hsb(r, g, b, tag)
    c, m, y, k = rgb_to_cmyk(r, g, b, tag)
    return {"r": r, "g": g, "bl": b, "h": h, "s": s, "b": br,
            "c": c, "m": m, "y": y, "k": k,
            "hex": "%02x%02x%02x" % (r, g, b)}


def float_hsb_channels(rf, gf, bf):
    """What a FLOAT-FIRST reader answers — NOT the spec, used only to prove a
    vector actually discriminates the two orderings."""
    mx, mn = max(rf, gf, bf), min(rf, gf, bf)
    d = mx - mn
    s = 0.0 if mx == 0.0 else d / mx
    h = 0.0
    if d > 0.0:
        if mx == rf:
            h = ((gf - bf) / d + (6.0 if gf < bf else 0.0)) / 6.0
        elif mx == gf:
            h = ((bf - rf) / d + 2.0) / 6.0
        else:
            h = ((rf - gf) / d + 4.0) / 6.0
    return {"h": half_away(h * 360.0, "") % 360,
            "s": half_away(s * 100.0, ""),
            "b": half_away(mx * 100.0, "")}


RGB_HSB = [
    ("hsb_black", 0, 0, 0),
    ("hsb_white", 255, 255, 255),
    ("hsb_red", 255, 0, 0),
    ("hsb_green", 0, 255, 0),
    ("hsb_blue", 0, 0, 255),
    ("hsb_cyan", 0, 255, 255),
    ("hsb_magenta", 255, 0, 255),
    ("hsb_yellow", 255, 255, 0),
    ("hsb_mid_gray", 128, 128, 128),
    ("hsb_hue_wraps_to_zero", 255, 0, 1),
    ("hsb_max_is_green_arm", 64, 192, 128),
    ("hsb_max_is_blue_arm", 64, 128, 192),
    ("hsb_near_black", 7, 7, 9),
    ("hsb_one_count_red", 1, 0, 0),
    ("hsb_divergence_664040", 102, 64, 64),
    ("hsb_divergence_664141", 102, 65, 65),
    ("hsb_divergence_cc9266", 204, 146, 102),
    ("hsb_divergence_cc9166", 204, 145, 102),
    ("hsb_roundtrip_probe", 128, 64, 192),
]

HSB_RGB = [
    ("torgb_red", 0.0, 100.0, 100.0),
    ("torgb_hue_360_is_red", 360.0, 100.0, 100.0),
    ("torgb_yellow_at_60", 60.0, 100.0, 100.0),
    ("torgb_green_at_120", 120.0, 100.0, 100.0),
    ("torgb_cyan_at_180", 180.0, 100.0, 100.0),
    ("torgb_blue_at_240", 240.0, 100.0, 100.0),
    ("torgb_magenta_at_300", 300.0, 100.0, 100.0),
    ("torgb_black", 0.0, 0.0, 0.0),
    ("torgb_white", 0.0, 0.0, 100.0),
    ("torgb_half_boundary_sat_50", 0.0, 50.0, 100.0),
    ("torgb_half_boundary_bright_50", 0.0, 0.0, 50.0),
    ("torgb_just_under_60", 59.9, 100.0, 100.0),
    ("torgb_mid_hsb", 200.0, 50.0, 80.0),
    ("torgb_low_bright", 20.0, 75.0, 12.0),
    ("torgb_fractional_hue", 217.5, 37.0, 93.0),
]

RGB_CMYK = [
    ("cmyk_black_special_case", 0, 0, 0),
    ("cmyk_white", 255, 255, 255),
    ("cmyk_red", 255, 0, 0),
    ("cmyk_mid_gray", 128, 128, 128),
    ("cmyk_near_black", 1, 1, 1),
    ("cmyk_blue_only", 0, 0, 1),
    ("cmyk_664040", 102, 64, 64),
    ("cmyk_cc9266", 204, 146, 102),
]

# The pipeline family. Every vector is a FLOAT rgb triple such as a
# `.hsb`-represented colour hands back, and the golden is the QUANTISE-FIRST
# answer. Vectors marked discriminating=True are ones where a float-first
# reader answers differently — those are the ones that gate the ordering.
PANEL = [
    ("panel_exact_eighth_bit_values", 0.4, 0.25, 0.25),
    ("panel_float_sat_rounds_down", 0.4013, 0.2504, 0.2504),
    ("panel_float_sat_rounds_up", 0.8, 0.5725, 0.4),
    ("panel_colorbar_click_mid", 0.2039215686, 0.6, 0.7529411765),
    ("panel_colorbar_hue_fraction", 0.7529411765, 0.5647058824, 0.4),
    ("panel_complement_of_0477cc", 0.8, 0.5686274510, 0.4),
    ("panel_white", 1.0, 1.0, 1.0),
    ("panel_black", 0.0, 0.0, 0.0),
    ("panel_saturating_over_one", 1.4, -0.4, 0.5),
    ("panel_half_pixel_up", 0.5019607843, 0.2509803922, 0.7529411765),
    ("panel_tiny_nonzero", 0.001, 0.0, 0.0),
    ("panel_grey_from_float", 0.5, 0.5, 0.5),
    # Harvested from the colour bar's own parameterisation (width 200,
    # height 64 — render_color_bar's constants) at the pixels where a
    # float-first reader and the quantise-first spec disagree, one per
    # channel plus one that misses on two at once.
    ("panel_bar_px_1_1_hue_misses", 0.99375, 0.963626953125, 0.9626953125000001),
    ("panel_bar_px_0_4_sat_misses", 0.975, 0.853125, 0.853125),
    ("panel_bar_px_0_9_bright_misses", 0.94375, 0.6783203125, 0.6783203125),
    ("panel_bar_px_0_20_sat_and_bright_miss", 0.875, 0.328125, 0.328125),
]


def main():
    vectors = []
    for (name, r, g, b) in RGB_HSB:
        h, s, br = rgb_to_hsb(r, g, b, name)
        vectors.append({"name": name, "function": "rgb_to_hsb",
                        "rgb": [r, g, b], "expected": [h, s, br]})
    for (name, h, s, b) in HSB_RGB:
        rr, gg, bb = hsb_to_rgb(h, s, b, name)
        vectors.append({"name": name, "function": "hsb_to_rgb",
                        "hsb": [h, s, b], "expected": [rr, gg, bb]})
    for (name, r, g, b) in RGB_CMYK:
        c, m, y, k = rgb_to_cmyk(r, g, b, name)
        vectors.append({"name": name, "function": "rgb_to_cmyk",
                        "rgb": [r, g, b], "expected": [c, m, y, k]})
    discriminating = []
    for (name, rf, gf, bf) in PANEL:
        want = panel_channels(rf, gf, bf, name)
        vectors.append({"name": name, "function": "panel_channels",
                        "float_rgb": [rf, gf, bf], "expected": want})
        if not (0.0 <= rf <= 1.0 and 0.0 <= gf <= 1.0 and 0.0 <= bf <= 1.0):
            continue
        fl = float_hsb_channels(rf, gf, bf)
        if any(fl[k] != want[k] for k in ("h", "s", "b")):
            discriminating.append((name, {k: fl[k] for k in ("h", "s", "b")},
                                   {k: want[k] for k in ("h", "s", "b")}))

    print("half-boundary vectors (generator convention = half AWAY from zero, "
          "matching Rust/Swift; python builtin round would differ on any that "
          "are NOT already even):")
    for tag, x in sorted(set(HALF_HITS)):
        away = math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5)
        print("   ", tag, x, "-> half_away", away, "| python round", round(x),
              "AGREE" if away == round(x) else "*** DISAGREE ***")
    print()
    print("ordering-DISCRIMINATING panel vectors "
          "(float-first answer vs quantise-first golden):")
    for name, fl, q in discriminating:
        print("   ", name, "float-first", fl, "!= quantise-first", q)
    print(f"\n{len(discriminating)} of {len(PANEL)} panel vectors discriminate "
          "the two orderings")
    print(f"total vectors: {len(vectors)}")

    doc = {
        "_doc": (
            "Colour-conversion conformance corpus: the four primitives every "
            "port's Color panel is built out of. rgb_to_hsb / hsb_to_rgb / "
            "rgb_to_cmyk pin the conversions themselves; panel_channels pins "
            "the ORDER the Color-panel overlay applies them in — quantise the "
            "float colour to three u8s FIRST, then derive hue / saturation / "
            "brightness / CMYK / hex from those integers. The order is the "
            "whole point: a reader that asks a float colour for its own h/s/b "
            "instead answers up to a whole unit differently, and since the "
            "panel's WRITE path recomputes the unedited channels from this "
            "same map, the divergence reaches the COMMITTED colour "
            "(COLORTIERS, 2026-07-26: Swift committed 664040 where Rust "
            "committed 664141).\n"
            "Goldens are derived from the spec formulas by "
            "scripts/derive_color_convert_goldens.py, not captured from a "
            "port -- run it to re-derive this file. Every "
            "rounding is half AWAY from zero, which is what Rust's f64::round "
            "and Swift's Double.rounded() do. Several vectors land exactly "
            "on x.5 -- the deliberate torgb_half_boundary_* pair, and also "
            "the 127.5 components in panel_grey_from_float and "
            "panel_saturating_over_one -- and half-away-from-zero is shared "
            "by both ports, so no golden encodes a rounding they disagree on."
        ),
        "vectors": vectors,
    }
    out = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "test_fixtures", "algorithms", "color_convert.json")
    if len(sys.argv) > 1:
        out = sys.argv[1]
    with open(out, "w", encoding="utf-8", newline="") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    print("wrote", out)


if __name__ == "__main__":
    main()
