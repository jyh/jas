"""WHAT A LINEAR GRADIENT PAINTS AT A POINT -- the denotation, not an algorithm.

This module answers one question: given a stop list, a bounding box and an
angle, WHAT COLOUR lands at a given place? It is the measuring instrument a
gradient checker rules with. It computes no remap, no split, no fragment: it
knows nothing about any transformation of a gradient, only about what a
gradient MEANS.

WHERE THE DENOTATION COMES FROM. Not from any implementation. It is stated in
prose, with worked arithmetic, in the `_doc` of
`test_fixtures/algorithms/gradient_remap.json`, which is hand-authored spec
text:

    "a linear gradient is an angle plus stops, and the painter resolves it
     against the element's OWN bbox -- the ramp runs from centre - half_diag*u
     to centre + half_diag*u, u = (cos t, -sin t), half_diag = half the bbox
     diagonal"

Everything below is that sentence made executable, plus the one further fact
the same `_doc` states by worked example: a stop's `location` is a percentage
of the ramp, 0 at the near end and 100 at the far end, colours interpolate
linearly between adjacent stops, and the ramp is CLAMPED to the first and last
stop colour outside their span. `midpoint` is carried by the model and is NOT
read by the painter today; this module does not read it either, and a checker
that needs it must say so.

THE ULP RULE -- READ BEFORE ADDING A CHECKER HERE.

    This is a THIRD floating-point dialect. Python will not agree bit-for-bit
    with Rust or with Swift on a borderline value, and nothing here tries to.
    The analytic tier may therefore host ONLY laws whose verdict is robust to
    ulp-scale disagreement -- a sampled colour compared with a tolerance
    derived from a real quantisation step, never `==`. A bit-exact law (the
    circle invariant is `==` with no tolerance band, deliberately) MUST stay
    in-process and mirrored per port. Move one here and it will go quietly
    wrong, in the direction of green.

UNITS. Colour channels are BYTES, 0..255, because that is the unit a stop
actually stores (`hex`) and therefore the unit a tolerance can be reasoned
about in. Opacity is a PERCENTAGE, 0..100, likewise. Positions are document
points.
"""

import math

# A colour is (r, g, b, opacity): channels in 0..255, opacity in 0..100.
CHANNELS = 4


def axis_unit(angle_deg):
    """The ramp direction for `angle_deg`, in a y-DOWN coordinate space.

    u = (cos t, -sin t): angle 0 runs left-to-right, angle 90 runs UPWARD on
    screen. The minus sign is the whole content of the
    `angle_90_pins_the_y_down_sign` vector.
    """
    t = math.radians(angle_deg)
    return (math.cos(t), -math.sin(t))


def ramp(bbox, u):
    """(centre_axial, half_length) of the ramp a `bbox` resolves.

    `bbox` is (x, y, w, h). The ramp is centred on the box centre projected
    onto u and runs half the box DIAGONAL either way -- not half the width,
    and not the box's projected extent.
    """
    x, y, w, h = bbox
    cx, cy = x + w / 2.0, y + h / 2.0
    return (cx * u[0] + cy * u[1], math.hypot(w, h) / 2.0)


def location_to_axial(loc, centre_axial, half):
    """Where stop `location` (0..100) sits along the ramp, absolutely."""
    return centre_axial + (loc / 50.0 - 1.0) * half


def parse_hex(text):
    """'rrggbb' (with or without '#') -> (r, g, b) bytes."""
    s = str(text).lstrip("#")
    if len(s) != 6:
        raise ValueError(f"not a 6-digit hex colour: {text!r}")
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))


def stop_colour(stop):
    """One stop as (r, g, b, opacity)."""
    r, g, b = parse_hex(stop["hex"])
    return (float(r), float(g), float(b), float(stop.get("opacity", 100.0)))


def colour_at_location(stops, loc):
    """The colour a stop list shows at `location` (0..100).

    Linear between the two bracketing stops; CLAMPED to the first/last stop
    colour outside their span. Stops are read in the order given -- a stop
    list is an ordered ramp, and a checker must not silently sort one.
    """
    if not stops:
        raise ValueError("a gradient with no stops paints nothing")
    if loc <= stops[0]["location"]:
        return stop_colour(stops[0])
    if loc >= stops[-1]["location"]:
        return stop_colour(stops[-1])
    for lo, hi in zip(stops, stops[1:]):
        a, b = lo["location"], hi["location"]
        if a <= loc <= b:
            if b == a:
                return stop_colour(hi)
            t = (loc - a) / (b - a)
            ca, cb = stop_colour(lo), stop_colour(hi)
            return tuple(ca[i] + (cb[i] - ca[i]) * t for i in range(CHANNELS))
    raise ValueError(f"location {loc} is not bracketed by an ordered ramp")


def colour_at_axial(stops, centre_axial, half, s):
    """The colour a gradient shows at absolute axial position `s`.

    `half == 0` is refused rather than answered: a zero-length ramp collapses
    every location onto one point, so "what colour is here" has no answer and
    a checker must declare the case unrulable instead of inventing one.
    """
    if half == 0.0:
        raise ZeroDivisionError("a zero-length ramp has no colour at a place")
    return colour_at_location(stops, 50.0 * ((s - centre_axial) / half + 1.0))
