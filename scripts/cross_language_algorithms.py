#!/usr/bin/env python3
"""Cross-language algorithm equivalence tests.

For each algorithm fixture, runs the algorithm_roundtrip CLI in each
language and compares the outputs using the appropriate comparison
strategy (exact, tolerance, or property-based).

Usage:
    python scripts/cross_language_algorithms.py
    python scripts/cross_language_algorithms.py --lang rust,swift
    python scripts/cross_language_algorithms.py --algo hit_test
    python scripts/cross_language_algorithms.py --verbose
"""

import argparse
import copy
import datetime
import hashlib
import json
import math
import os
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lane_report  # noqa: E402  (sibling module in scripts/)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES_DIR = os.path.join(REPO_ROOT, "test_fixtures", "algorithms")

sys.path.insert(0, REPO_ROOT)
# The analytic TCB the geometry checkers rule with. It imports nothing from
# this repository -- that property is what makes it an independent instrument
# rather than a fourth implementation, and scripts/check_geometry_checkers.py
# enforces it. See docs/CHECKERS.md.
from spec.geometry import linear_gradient as lg  # noqa: E402
from spec.geometry import probes as pr  # noqa: E402
from spec.geometry import region as rg  # noqa: E402

# Algorithm → (comparison strategy, tolerance)
ALGORITHMS = {
    "measure":           ("tolerance", 1e-4),
    "element_bounds":    ("tolerance", 1e-4),
    # The TRANSFORM-AWARE bbox the Properties panel shows: geometric bounds
    # mapped through the element's own matrix and every ancestor's, then
    # axis-aligned. A separate family because `element_bounds` gates
    # `Element::bounds`, which ignores `transform` entirely in both ports
    # (measured: a rect with translate(100,50) still reports [0,0,10,10]).
    "element_evaluated_bounds": ("tolerance", 1e-4),
    "flatten":           ("tolerance", 1e-9),
    # The ART flattener (`art_along_path::flatten` / `flattenArtPath`), which
    # is a DIFFERENT function from `flatten` above and not a wrapper over it:
    # it walks the FIRST SUBPATH only, dedupes coincident vertices as it goes,
    # and samples a cubic at 16 steps and a quad at 12 rather than at the
    # hit-test flattener's shared FLATTEN_STEPS. Shared by art-along-path,
    # pattern-along-path and the bristle brush, and driven by NO family until
    # this one: both ports dropped the whole path on a leading ClosePath,
    # identically, so no port-vs-port comparison could see it (S-4).
    "art_flatten":       ("tolerance", 1e-9),
    # The Calligraphic brush's variable-width outline. A FOURTH first-subpath
    # walker lives inside it (`sample_stroke_path` / `sampleStrokePath`, private
    # in both ports) with its own step counts -- 32 cubic / 24 quadratic samples
    # and a 1pt arc-length interval -- so it is not expressible through
    # `art_flatten`. It carried the same leading-ClosePath bail-out, identically
    # in both ports, and the calligraphic brush is the Phase-1 DEFAULT brush.
    # Gated at the public function so the family asserts the ribbon the artist
    # sees rather than an internal.
    "calligraphic_outline": ("tolerance", 1e-9),
    # The WIDTH TOOL's variable-width stroke outline, and the last family of
    # the Phase-3 plumbing pass to become reachable at all. It was
    # unreachable because the module RETURNED NOTHING: rails and caps existed
    # only as `web_sys` / CGContext drawing calls, and Rust's copy was gated
    # behind `web` for that one import, so on a native build it did not even
    # compile. Splitting the geometry from the rasterisation is what put the
    # caps on a wire. 1e-9 because the vectors are integer geometry and
    # multiples of 5/sqrt(2), and the cap defect this family was written
    # against moves a point by up to a full stroke DIAMETER.
    "offset_path":       ("tolerance", 1e-9),
    # The offset a PASTE applies to each pasted element (workspace/actions.yaml
    # §paste: "offset 24 points down and to the right", against
    # paste_in_place's explicit "no offset"). EXACT, and the result is the whole
    # element serialized through the shared document writer rather than a
    # coordinate list: the divergence this family exists for came in two halves,
    # a compound shape that did not move AND a group that lost its name, and a
    # coordinate-only comparison would have seen only the first.
    "paste_translate":    ("exact", None),
    "arrow_trim":        ("tolerance", 1e-4),
    # LINEAR gradient stop remap onto a split fragment (S-2). EXACT: colours
    # are reported as 8-bit hex (a Swift GradientStop stores its colour as a
    # hex string, so that is the widest value the two stop models share), and
    # locations are hand-derived halves and quarters that both ports reach by
    # the same arithmetic. A tolerance here would only hide a quantisation
    # disagreement, which is precisely what the family is for.
    "gradient_remap":    ("exact", None),
    "length":            ("tolerance", 1e-9),
    # Colour conversion is integer-valued in every channel (the panel's units),
    # so the comparison is EXACT: a one-unit miss is exactly the bug this
    # family exists to catch, and any tolerance would swallow it.
    "color_convert":     ("exact", None),
    "hit_test":          ("exact", None),
    # Closest-point projection onto a segment / cubic. Distances are reported
    # divided by each vector's declared `scale`, so 1e-9 is a tight relative
    # bound even for the 1e200-magnitude overflow vectors; the discriminating
    # failures it must catch are 0.02-to-0.48 wide in `t`.
    "path_project":      ("tolerance", 1e-9),
    # The number_input commit rule. EXACT: the whole point is which strings are
    # accepted at all (a null result vs a value) and the clamp landing exactly on
    # the declared bound, so any tolerance would swallow the divergence.
    "number_commit":     ("exact", None),
    "boolean":           ("exact_boolean", None),
    "boolean_normalize": ("exact_boolean", None),
    # The harness's OWN region metrics, which every boolean golden is
    # expressed in. Whole-object tolerance, so `expected` must pin EVERY
    # emitted key -- an instrument family that let a key go unpinned would
    # reproduce the defect it exists to close. 1e-9 because the vectors are
    # small-integer geometry: the answers are exact, and the discriminating
    # failures are whole units wide (e.g. 168 vs 0).
    "polygon_metrics":   ("tolerance", 1e-9),
    "fit_curve":         ("tolerance", 0.5),
    "shape_recognize":   ("shape", 0.5),
    "planar":            ("property_planar", 0.01),
    # The SHARED segment-splitting primitive under boolean, planar and
    # boolean_normalize -- the most production-reachable geometry in the
    # tree, and until this family it had no cross-language witness at all:
    # 11 Rust tests and 11 Swift tests mirrored BY HAND, which is agreement
    # by transcription rather than equivalence. Tolerance rather than exact
    # because the parameters come out of divisions; 1e-12 is ~10^4 ulps at
    # these magnitudes and ~10^3 times narrower than the PARAM_EPS band the
    # vectors straddle. The one field that admits NO tolerance -- which of
    # the four input endpoints the returned point is BIT-IDENTICAL to -- is
    # a string, so `values_close` compares it exactly.
    "arrangement":       ("tolerance", 1e-12),
    # The Scale / Rotate / Shear matrix builders behind every transform
    # dialog and every transform tool. 1e-12 and no tighter: cos(90 deg) is
    # 6.1e-17 in every IEEE dialect, sin(180 deg) is 1.2e-16 and tan(45 deg)
    # is 0.9999999999999999, so a hand-derived exact expectation can only be
    # pinned against a band. It is also, deliberately, four orders of
    # magnitude WIDER than the measured deg-to-radian spelling divergence
    # between the ports (`f64::to_radians` against `deg * .pi / 180`), which
    # is filed as a named coverage gap rather than swallowed silently.
    "transform_apply":   ("tolerance", 1e-12),
    # The list-marker half of the text_layout_paragraph MODULE, which the
    # verb of the same name never reaches (that one drives
    # `layout_with_paragraphs`). These four are called only from the
    # renderer, so every bulleted and numbered list went unwatched. EXACT:
    # every answer is a string or an integer.
    "paragraph_markers": ("exact", None),
    # Liang pattern hyphenation. EXACT for the same reason: a break mask is
    # booleans and the spelled form is a string.
    "hyphenator":        ("exact", None),
    # Polyline -> Bezier (Object > Simplify, and the tail of every boolean
    # result). 1e-9: the hand-derived vectors are exact small integers and
    # the fitted ones come out of the same least-squares solve in both ports.
    "simplify":          ("tolerance", 1e-9),
    # Every dashed stroke the app draws -- both ports expand the dashes
    # themselves rather than handing a dash array to the platform. 1e-9
    # because align mode accumulates a scaled dash length, so the last
    # boundary of a long run carries a few ulps of drift.
    "dash_renderer":     ("tolerance", 1e-9),
    # The three PATH BRUSHES. `art_flatten` gates the first-subpath walker
    # all three share -- the family whose absence let a leading-ClosePath
    # bail-out ship in both ports at once -- but nothing gated the warp, the
    # tiling or the bristle spread ABOVE it, so a repair at the walker could
    # be undone one level up in silence. 1e-9: the vectors run on straight
    # horizontal paths where the tangent is 0 and every answer is exact.
    "art_along_path":     ("tolerance", 1e-9),
    "pattern_along_path": ("tolerance", 1e-9),
    "bristle_stroke":     ("tolerance", 1e-9),
    "text_layout":       ("tolerance", 1e-4),
    "text_layout_paragraph": ("tolerance", 1e-4),
    "path_text_layout":  ("tolerance", 1e-4),
    "align":             ("tolerance", 1e-4),
}

# Known per-language algorithm exclusions (pre-existing bugs to fix separately)
SKIP_LANG_ALGO = set()

# Strategies whose fixtures pin a SUBSET of the emitted result keys, and so
# get the key-by-key oracle pass instead of the whole-object one. See the
# comment at that pass for why these families need an oracle at all.
ORACLE_PARTIAL_STRATEGIES = ("property_planar", "exact_boolean")

# The oracle holdout is PER GOLDEN KEY OF ONE VECTOR, never per strategy.
# Keying it by strategy — as an earlier revision did — silently disarms a
# whole family: `boolean` and `boolean_normalize` share the "exact_boolean"
# strategy, so holding the strategy out to tolerate ONE gap key in
# boolean.json also left all 42 of boolean_normalize.json's hand-derived
# golden checks unrun, with nothing in the output saying so.
#
# A vector declares a holdout with BOTH keys below: `_known_gap` (prose:
# what the ports emit instead, why, and what unblocks the fix) and
# `_known_gap_keys` (the exact `expected` keys held out). Every other key
# of that same vector, and every other vector of that fixture, stays
# gated. The pair is self-policing — a listed key that is absent from
# `expected`, or that the reference app now REPRODUCES, is reported as a
# failure telling you to delete the holdout. So a closed gap cannot sit
# around pretending to still be open.
KNOWN_GAP_KEY = "_known_gap"
KNOWN_GAP_KEYS_KEY = "_known_gap_keys"


# ---------------------------------------------------------------
# Language runners
# ---------------------------------------------------------------

def run_rust(algo, fixture_path):
    result = subprocess.run(
        ["cargo", "run", "--bin", "algorithm_roundtrip",
         "--no-default-features", "--", algo, fixture_path],
        cwd=os.path.join(REPO_ROOT, "jas_dioxus"),
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Rust failed: {result.stderr}")
    return result.stdout


def run_swift(algo, fixture_path):
    result = subprocess.run(
        ["swift", "run", "AlgorithmRoundtrip", algo, fixture_path],
        cwd=os.path.join(REPO_ROOT, "JasSwift"),
        capture_output=True, text=True, timeout=60,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Swift failed: {result.stderr}")
    return result.stdout


def run_ocaml(algo, fixture_path):
    result = subprocess.run(
        ["dune", "exec", "bin/algorithm_roundtrip.exe", "--", algo, fixture_path],
        cwd=os.path.join(REPO_ROOT, "jas_ocaml"),
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"OCaml failed: {result.stderr}")
    return result.stdout


def run_python(algo, fixture_path):
    result = subprocess.run(
        [sys.executable, os.path.join(REPO_ROOT, "jas", "tools", "algorithm_roundtrip.py"),
         algo, fixture_path],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Python failed: {result.stderr}")
    return result.stdout


LANGUAGES = {
    "rust": run_rust,
    "swift": run_swift,
    "ocaml": run_ocaml,
    "python": run_python,
}


# ---------------------------------------------------------------
# Comparison functions
# ---------------------------------------------------------------

def compare_exact(ref_result, other_result):
    """Exact equality comparison."""
    return ref_result == other_result


def values_close(a, b, tol):
    """Recursively compare JSON values within tolerance."""
    if isinstance(a, bool) and isinstance(b, bool):
        return a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(float(a) - float(b)) <= tol
    if isinstance(a, str) and isinstance(b, str):
        return a == b
    if a is None and b is None:
        return True
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return False
        return all(values_close(x, y, tol) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        if set(a.keys()) != set(b.keys()):
            return False
        return all(values_close(a[k], b[k], tol) for k in a)
    return a == b


def compare_tolerance(ref_result, other_result, tol):
    """Recursive numeric comparison within tolerance."""
    return values_close(ref_result, other_result, tol)


def _round4(v):
    """Round to 4 decimals, round-half-away-from-zero, matching the
    cross-language _fmt convention (math.floor(x*10000 + 0.5)/10000 for
    non-negatives, mirrored for negatives) used by every app serializer."""
    if v < 0:
        return -(math.floor(-v * 10000 + 0.5) / 10000)
    return math.floor(v * 10000 + 0.5) / 10000


def _round_rings(rings):
    return [[[_round4(c) for c in pt] for pt in ring] for ring in rings]


def compare_exact_boolean(ref_result, other_result):
    """Exact-vertex boolean comparison: the result polygon rings must be
    bit-equal (to 4-decimal _fmt precision) elementwise — same ring order,
    same vertex order, same coords. The coarse property fields (area /
    ring_count / sample_points or all_rings_simple) remain in the payload
    as a backstop but the gate is the rings."""
    return _round_rings(ref_result["rings"]) == _round_rings(other_result["rings"])


def compare_property_boolean(ref_result, other_result, tol):
    """Boolean op: ring_count exact, area within tol, sample_points exact."""
    if ref_result["ring_count"] != other_result["ring_count"]:
        return False
    if abs(ref_result["area"] - other_result["area"]) > tol:
        return False
    for sp_ref, sp_other in zip(ref_result["sample_points"],
                                 other_result["sample_points"]):
        if sp_ref["inside"] != sp_other["inside"]:
            return False
    return True


def compare_property_normalize(ref_result, other_result, tol):
    """Normalize: area within tol, ring_count exact, all_rings_simple exact."""
    if ref_result["ring_count"] != other_result["ring_count"]:
        return False
    if abs(ref_result["area"] - other_result["area"]) > tol:
        return False
    if ref_result["all_rings_simple"] != other_result["all_rings_simple"]:
        return False
    return True


def compare_property_planar(ref_result, other_result, tol):
    """Planar: face_count exact, face_areas_sorted within tol, sample_points exact."""
    if ref_result["face_count"] != other_result["face_count"]:
        return False
    ref_areas = ref_result["face_areas_sorted"]
    other_areas = other_result["face_areas_sorted"]
    if len(ref_areas) != len(other_areas):
        return False
    for a, b in zip(ref_areas, other_areas):
        if abs(a - b) > tol:
            return False
    for sp_ref, sp_other in zip(ref_result["sample_points"],
                                 other_result["sample_points"]):
        if sp_ref["inside_any_face"] != sp_other["inside_any_face"]:
            return False
    return True


def compare_shape(ref_result, other_result, tol):
    """Shape recognize: kind exact (or both null), params within tolerance."""
    if ref_result is None and other_result is None:
        return True
    if ref_result is None or other_result is None:
        return False
    if ref_result["kind"] != other_result["kind"]:
        return False
    return values_close(ref_result["params"], other_result["params"], tol)


def compare(strategy, ref_vec, other_vec, tol):
    """Dispatch to the appropriate comparison function."""
    ref_r = ref_vec["result"]
    other_r = other_vec["result"]
    if strategy == "exact":
        return compare_exact(ref_r, other_r)
    elif strategy == "exact_boolean":
        return compare_exact_boolean(ref_r, other_r)
    elif strategy == "tolerance":
        return compare_tolerance(ref_r, other_r, tol)
    elif strategy == "property_boolean":
        return compare_property_boolean(ref_r, other_r, tol)
    elif strategy == "property_normalize":
        return compare_property_normalize(ref_r, other_r, tol)
    elif strategy == "property_planar":
        return compare_property_planar(ref_r, other_r, tol)
    elif strategy == "shape":
        return compare_shape(ref_r, other_r, tol)
    else:
        raise ValueError(f"Unknown comparison strategy: {strategy}")


# ---------------------------------------------------------------
# Preflight: the harness must inject the SAME measure unit everywhere
# ---------------------------------------------------------------
#
# The three text families (text_layout, text_layout_paragraph,
# path_text_layout) do not measure text themselves — each roundtrip binary
# injects a `measure` closure built from the fixture's `char_width`. That
# makes the closure part of the harness, not part of either port, and it
# is the one input this script controls but never checked. It had already
# drifted: Rust counted Unicode scalars (`chars().count()`) while Swift
# counted grapheme clusters (`s.count`), which agree on ASCII and on
# nothing else. A comparison whose two sides were fed different measurers
# is not a comparison, and the resulting failure would have been read as a
# layout bug.
#
# Each port now has one named helper (`fixed_char_width_measure` /
# `fixedCharWidthMeasure`, unit-tested against the reference's `len(s)`),
# and the check below requires all THREE call sites per port to route
# through it. Three inline copies per port is exactly the shape that
# drifted once; naming the offending file:line is what stops a single
# reverted site from slipping through.
MEASURE_INJECTION_SITES = [
    # (harness source, how many `measure` bindings it must have,
    #  the helper each one must call)
    ("jas_dioxus/src/bin/algorithm_roundtrip.rs", 3, "fixed_char_width_measure"),
    ("JasSwift/ToolsAlgorithm/AlgorithmRoundtrip.swift", 3, "fixedCharWidthMeasure"),
]


def check_measure_injection():
    """Returns a list of problem strings (empty when the harness agrees)."""
    problems = []
    for rel, want_count, helper in MEASURE_INJECTION_SITES:
        path = os.path.join(REPO_ROOT, rel)
        try:
            with open(path, encoding="utf-8") as fh:
                lines = fh.readlines()
        except OSError as e:
            problems.append(f"{rel}: cannot read harness source ({e})")
            continue
        bindings = [(i + 1, ln) for i, ln in enumerate(lines)
                    if "measure" in ln and ln.lstrip().startswith("let measure")]
        if len(bindings) != want_count:
            problems.append(
                f"{rel}: expected {want_count} `let measure` binding(s), "
                f"found {len(bindings)} — the text families changed shape, so "
                f"update MEASURE_INJECTION_SITES deliberately")
        for lineno, ln in bindings:
            if helper not in ln:
                problems.append(
                    f"{rel}:{lineno}: `measure` does not call {helper}() — "
                    f"an inline measurer here re-opens the scalar-vs-grapheme "
                    f"drift for one family only: {ln.strip()}")
    return problems


# ---------------------------------------------------------------
# Preflight: one JSON string escaper per port
# ---------------------------------------------------------------
#
# The same shape as check_measure_injection, for the same reason. Until
# 2026-07-27 each active port carried FOUR independent copies of the
# canonical-JSON string escaper -- geometry test_json, workspace test_json,
# the dependency index, and (Rust only) `canonical_value`'s `{:?}` -- and
# three of them said in their own doc comments that they matched the first.
# They did not: `canonical_value` spelled U+0001 `\u{1}` where JasSwift
# emitted it raw, and none of the two-replacement copies escaped a control
# character at all, so the byte oracle behind the codec gates could not
# express a newline (coverage gap `codec-no-control-chars`, census 5.5).
#
# Each port now has ONE escaper -- `json_escape_string` / `jsonEscapeString`,
# gated across both ports by test_fixtures/algorithms/canonical_json_string.json
# -- and the check below requires that no other file re-derives it. A doc
# comment claiming to match a writer is not a mechanism; this is.
ESCAPER_HOMES = {
    "jas_dioxus/src/geometry/test_json.rs",
    "JasSwift/Sources/Geometry/TestJson.swift",
}

ESCAPER_ROOTS = [
    ("jas_dioxus/src", ".rs", "json_escape_string"),
    ("JasSwift/Sources", ".swift", "jsonEscapeString"),
]

# The two-replacement idiom, as it appears in each language's source text.
ESCAPER_SIGNATURES = [
    ('.replace(\'\\\\\', "\\\\\\\\")', "Rust"),
    ('replacingOccurrences(of: "\\\\", with: "\\\\\\\\")', "Swift"),
]


def check_json_string_escapers():
    """Returns a list of problem strings (empty when each port has one)."""
    problems = []
    for rel_root, ext, helper in ESCAPER_ROOTS:
        root = os.path.join(REPO_ROOT, rel_root)
        if not os.path.isdir(root):
            problems.append(f"{rel_root}: not a directory")
            continue
        for dirpath, _dirs, files in os.walk(root):
            for fname in sorted(files):
                if not fname.endswith(ext):
                    continue
                path = os.path.join(dirpath, fname)
                rel = os.path.relpath(path, REPO_ROOT)
                if rel in ESCAPER_HOMES:
                    continue
                try:
                    with open(path, encoding="utf-8") as fh:
                        lines = fh.readlines()
                except (OSError, UnicodeDecodeError) as e:
                    problems.append(f"{rel}: cannot read ({e})")
                    continue
                for i, ln in enumerate(lines):
                    for sig, lang in ESCAPER_SIGNATURES:
                        if sig in ln:
                            problems.append(
                                f"{rel}:{i + 1}: a {lang} inline JSON string "
                                f"escaper — call {helper}() instead. A local "
                                f"copy cannot escape a control character and "
                                f"re-opens `codec-no-control-chars`: "
                                f"{ln.strip()}")
    return problems


# ---------------------------------------------------------------
# The RELATIONAL S-4 gate: a leading ClosePath contributes nothing
# ---------------------------------------------------------------
#
# S-4 (JYH, fleet council 2026-07-27): "a ClosePath before any point has been
# established contributes nothing." That is a ruling about a SHAPE OF CODE, and
# the tree honours it in four separate first-subpath walkers through four
# hand-written guards of two different forms — `out.is_empty()` where the
# accumulator holds vertices, a `has_current` / `hasCurrent` flag where it holds
# samples a bare MoveTo does not emit. Two of those four were WRONG until
# 2026-07-27, in BOTH PORTS IDENTICALLY, which is precisely the class a
# port-vs-port comparison is structurally blind to: wrong-vs-wrong compares
# green. The value families that now watch them (`art_flatten`,
# `calligraphic_outline`) each cover only the inputs their vectors name, and
# nothing forced a FIFTH walker to choose either guard form.
#
# This pass is the mechanism that does. It is RELATIONAL, not value-pinned:
# for every registered algorithm, it takes each fixture vector that carries
# path data, manufactures a probe by prepending one ClosePath to every path in
# it, and asserts the algorithm's answer does not move. No new golden is
# written, S-4 is stated once, and — the point — an algorithm registered
# tomorrow is probed the day it lands, from the ordinary vectors its own author
# wrote for other reasons. Measured: with both 2026-07-27 guards reverted, the
# vectors that catch the defect here are the ones named
# `art_second_moveto_ends_the_first_subpath` (`d` = M L M L, containing no
# ClosePath at all) and `callig_line_no_leading_close` — neither was written as
# a leading-close test. That is the property a value family cannot have.
#
# It also compares the PROBE outputs across ports, so the two hand-written
# guards cannot drift apart at the leading close without a red.

LEADING_CLOSE_PROBE_SUFFIX = "::leading_close"

# Keys whose contents are GOLDEN, not input: never probed. `arrow_trim`'s
# `expected` is itself a path-command list, so a walk that did not skip these
# would mutate the answer alongside the question and compare green forever.
LEADING_CLOSE_GOLDEN_KEYS = ("expected", "translations")

# Registered algorithms that consume NO path, with the reason. Required so the
# classification is TOTAL over ALGORITHMS: an algorithm that yields no probe and
# is not listed here is a FAILURE telling its author to decide which it is. That
# is the forcing function the class was missing — a new path-consuming algorithm
# whose fixture happens to carry no path vector cannot pass silently. The list
# is also policed in reverse: if a fixture named here starts carrying path data,
# the stale entry is reported.
LEADING_CLOSE_NO_PATH_INPUT = {
    "measure": "unit conversion of a scalar; no geometry at all",
    "gradient_remap": "gradient stops + two bboxes; the fragment is a rect",
    "length": "unit-aware string parse/format of a scalar",
    "color_convert": "colour channels only",
    "path_project": "raw point + segment/cubic coordinate args, not a command list",
    "number_commit": "a widget's commit rule over a string",
    "boolean": "polygon RINGS (already-flattened point lists), not path commands",
    "boolean_normalize": "polygon rings, as `boolean`",
    "polygon_metrics": "polygon rings, as `boolean`",
    "fit_curve": "an input POINT list; the curve is the output",
    "shape_recognize": "an input point list, as `fit_curve`",
    "planar": "polylines (point lists), not path commands",
    "arrangement": "two raw SEGMENTS as coordinate pairs (and, for the dedup "
                   "half, a vertex list) -- the primitive sits below the "
                   "flattener, so a ClosePath has already been resolved into "
                   "segments before anything reaches it",
    "text_layout": "a string plus a width",
    "text_layout_paragraph": "a string plus paragraph attributes",
    "align": "rect bounds only",
    "transform_apply": "scalar factors and angles; the output is a matrix, "
                       "and no path enters or leaves",
    "paragraph_markers": "a list style and a counter; strings out",
    "hyphenator": "a word and a pattern list; a break mask out",
    "simplify": "an input POINT list, as `fit_curve`; the curve is the output",
}

# Algorithms whose OUTPUT is a path (or a document containing one) rather than
# an answer derived from one. For these the S-4-honouring behaviour is not
# invariance but FORWARDING: the leading ClosePath must be carried through
# unchanged, because a transform that speaks to position must preserve the
# command list it did not speak to (the Preservation Law) — dropping the close
# would be the bug. So the assertion is `strip_one_leading_close(probe) ==
# original` AND `probe != original`: a positive claim that the close really was
# carried, not a licence to differ. An entry that stops being needed is
# reported as a failure, so it cannot sit here pretending.
LEADING_CLOSE_PATH_OUTPUT = {
    "paste_translate": "the result is the pasted element serialized whole, so "
                       "the leading ClosePath is preserved in `d` — as the "
                       "Preservation Law requires of a transform that speaks "
                       "only to position",
}


def _is_path_command_list(v):
    """A path-command list as every fixture spells one: a non-empty list of
    objects each carrying a `cmd`."""
    return (isinstance(v, list) and len(v) > 0
            and all(isinstance(e, dict) and "cmd" in e for e in v))


def _with_leading_close(node):
    """Deep copy of `node` with one ClosePath prepended to EVERY path-command
    list reachable through non-golden keys. Returns (copy, paths_touched)."""
    if _is_path_command_list(node):
        return ([{"cmd": "Z"}] + copy.deepcopy(node), 1)
    if isinstance(node, dict):
        out, n = {}, 0
        for k, v in node.items():
            if k in LEADING_CLOSE_GOLDEN_KEYS or k.startswith("_"):
                out[k] = copy.deepcopy(v)
                continue
            out[k], c = _with_leading_close(v)
            n += c
        return (out, n)
    if isinstance(node, list):
        out, n = [], 0
        for v in node:
            nv, c = _with_leading_close(v)
            out.append(nv)
            n += c
        return (out, n)
    return (copy.deepcopy(node), 0)


def _without_leading_closes(node):
    """The exact inverse of `_with_leading_close`, for the path-OUTPUT form:
    drop one leading ClosePath from every path-command list in a result. A
    result that is the document writer's canonical STRING (paste_translate) is
    handled textually on the same rule — a `Z` that is FIRST inside an array."""
    if isinstance(node, str):
        return node.replace('[{"cmd":"Z"},', '[').replace('[{"cmd":"Z"}]', '[]')
    if _is_path_command_list(node):
        if node[0].get("cmd") == "Z":
            return copy.deepcopy(node[1:])
        return copy.deepcopy(node)
    if isinstance(node, dict):
        return {k: _without_leading_closes(v) for k, v in node.items()}
    if isinstance(node, list):
        return [_without_leading_closes(v) for v in node]
    return copy.deepcopy(node)


def _leading_close_probe_pairs(fixture_path):
    """Returns (doc_is_list, pairs) where each pair is (original, probe,
    paths_touched) for every non-skipped vector that carries path data."""
    with open(fixture_path, encoding="utf-8") as fh:
        doc = json.load(fh)
    vectors = doc if isinstance(doc, list) else doc.get("vectors", [])
    pairs = []
    for v in vectors:
        if not isinstance(v, dict) or v.get("_skip"):
            continue
        probe, n = _with_leading_close(v)
        if n == 0:
            continue
        probe["name"] = str(v.get("name", "?")) + LEADING_CLOSE_PROBE_SUFFIX
        pairs.append((v, probe, n))
    return (isinstance(doc, list), pairs)


def check_leading_close_invariance(langs, algos, verbose=False):
    """Run the S-4 relational pass. Returns (passed, failed, errors); prints
    its own FAIL / EXEMPT lines so a red names the algorithm and the vector."""
    passed = failed = errors = 0
    ref_lang = langs[0]
    with tempfile.TemporaryDirectory(prefix="s4-leading-close-") as tmpd:
        for algo in algos:
            strategy, tol = ALGORITHMS[algo]
            fixture_path = os.path.join(FIXTURES_DIR, f"{algo}.json")
            if not os.path.exists(fixture_path):
                continue  # the main loop already reports a missing fixture
            is_list, pairs = _leading_close_probe_pairs(fixture_path)

            # The classification must be total, and self-policing both ways.
            if not pairs:
                if algo in LEADING_CLOSE_NO_PATH_INPUT:
                    continue
                print(f"  FAIL: s4/leading-close {algo} [yields no probe and is "
                      f"not classified: if it consumes a path, give its fixture "
                      f"a path vector; if it does not, say so in "
                      f"LEADING_CLOSE_NO_PATH_INPUT with the reason]")
                failed += 1
                continue
            if algo in LEADING_CLOSE_NO_PATH_INPUT:
                print(f"  FAIL: s4/leading-close {algo} [classified as taking no "
                      f"path, but its fixture now carries {len(pairs)} path "
                      f"vector(s): delete the stale "
                      f"LEADING_CLOSE_NO_PATH_INPUT entry]")
                failed += 1
                continue

            k = len(pairs)
            combined = [p[0] for p in pairs] + [p[1] for p in pairs]
            probe_doc = combined if is_list else {"vectors": combined}
            probe_path = os.path.join(tmpd, f"{algo}.json")
            with open(probe_path, "w", encoding="utf-8", newline="") as fh:
                json.dump(probe_doc, fh)

            forwards = algo in LEADING_CLOSE_PATH_OUTPUT
            outputs = {}
            for lang in langs:
                if (lang, algo) in SKIP_LANG_ALGO:
                    continue
                try:
                    outputs[lang] = json.loads(LANGUAGES[lang](algo, probe_path))
                except Exception as e:
                    print(f"  ERROR: s4/leading-close {algo} {lang}: {e}")
                    errors += 1
            for lang, out in outputs.items():
                if len(out) != 2 * k:
                    print(f"  FAIL: s4/leading-close {algo} {lang} [emitted "
                          f"{len(out)} results for {2 * k} vectors]")
                    failed += 1
                    continue
                if not all(isinstance(r, dict) and "name" in r and "result" in r
                           for r in out):
                    print(f"  FAIL: s4/leading-close {algo} {lang} [results are "
                          f"not {{name, result}} objects, so the probe cannot be "
                          f"paired with its original — teach this pass that "
                          f"shape rather than dropping the algorithm]")
                    failed += 1
                    continue
                for i in range(k):
                    orig, probe = out[i], out[k + i]
                    name = orig["name"]
                    if forwards:
                        stripped = {"result":
                                    _without_leading_closes(probe["result"])}
                        ok = compare(strategy, orig, stripped, tol)
                        if ok and compare(strategy, orig, probe, tol):
                            print(f"  FAIL: s4/leading-close {algo}/{name} "
                                  f"[{lang}: listed in "
                                  f"LEADING_CLOSE_PATH_OUTPUT, but the leading "
                                  f"ClosePath is NOT carried into the output. "
                                  f"Either {lang} DROPPED it — a transform "
                                  f"guessing at what it was asked to preserve, "
                                  f"which is the bug this form exists to catch "
                                  f"— or the algorithm stopped returning a path "
                                  f"and the entry is stale. Fix the port, or "
                                  f"delete the entry]")
                            failed += 1
                            continue
                    else:
                        ok = compare(strategy, orig, probe, tol)
                    if ok:
                        passed += 1
                    else:
                        how = ("output does not forward the leading ClosePath "
                               "unchanged" if forwards
                               else "a leading ClosePath changed the answer")
                        print(f"  FAIL: s4/leading-close {algo}/{name} "
                              f"[{lang}: {how} — S-4 says it contributes "
                              f"nothing]")
                        if verbose:
                            print(f"    stripped: "
                                  f"{json.dumps(orig['result'], sort_keys=True)[:200]}")
                            print(f"    leading Z: "
                                  f"{json.dumps(probe['result'], sort_keys=True)[:200]}")
                        failed += 1
                # The two ports' guards are hand-written and of two different
                # forms; compare the PROBE answers directly so they cannot
                # drift apart at the leading close with no golden moving.
                if lang != ref_lang and ref_lang in outputs \
                        and len(outputs[ref_lang]) == 2 * k:
                    for i in range(k, 2 * k):
                        rv, lv = outputs[ref_lang][i], out[i]
                        if compare(strategy, rv, lv, tol):
                            passed += 1
                        else:
                            print(f"  FAIL: s4/leading-close {algo}/"
                                  f"{rv['name']} [{ref_lang} vs {lang}: the two "
                                  f"S-4 guards disagree]")
                            failed += 1
    return (passed, failed, errors)


# ---------------------------------------------------------------
# GEOMETRY CHECKERS -- the law tier. See docs/CHECKERS.md.
# ---------------------------------------------------------------
#
# A CHECKER is a small executable predicate that takes ANY input/output pair
# and rules it legal or not, written from the SPEC and never from the
# implementation. It is not a golden: it has no pinned answer, so it can rule
# a case nobody wrote down, and a shared bug in both ports does not make it
# green. It rides SEAM 1 -- the out-of-process `algorithm_roundtrip` wire --
# so ONE Python predicate adjudicates BOTH active ports and the Windows lane
# sees all of it (`swift test` is macOS-only; a Seam-2 checker would give the
# Windows seat the Rust arm alone, half-watched by construction).
#
# The verdicts are counted in lane_report's RELATIONAL bucket: a checker
# compares no two implementations and reproduces no golden, so folding it into
# either of the other two would overstate the run. RELATIONAL is non-zero and
# BLOCKING under `--lang rust` with no `--require-comparisons`, which is
# exactly the shape of the Windows lane.

# algorithm -> the law's name. Total over ALGORITHMS: an algorithm that is not
# here must be in GEOMETRY_CHECKER_GAPS with a written reason, and one that is
# in BOTH, or in NEITHER, is a failure. Policed in reverse too -- see
# CHECKER_PROBES.
GEOMETRY_CHECKERS = {
    "gradient_remap": "gradient_remap_repaints_the_fragment",
    "boolean": "boolean_result_is_the_sampled_combination",
    "boolean_normalize": "normalize_preserves_the_declared_region",
}

# Registered algorithms with NO checker, and why. A row here is a claim that
# nobody has to re-derive; a row that stops being true is caught by the probe
# sweep below, which is the direction `swift:dropdown` went stale in for
# months (the defect behind check_gate_consistency.py).
#
# "PHASE 2" means: a law IS available at this seam and is not written yet --
# the honest state, distinct from "no law exists". A reason that merely
# restates the implementation is not a reason.
GEOMETRY_CHECKER_GAPS = {
    "measure": "unit conversion of a scalar; any law would restate the "
               "conversion table, which is a golden with extra steps",
    "length": "as `measure`: a unit-aware string parse/format, no geometry",
    "color_convert": "PHASE 2 -- the round-trip law (rgb->hsb->rgb within one "
                     "panel unit) is a real law at this seam, unwritten",
    "number_commit": "a widget's commit rule over strings; the law IS the rule "
                     "table, so it belongs to the declarative tier, not here",
    "element_bounds": "PHASE 2 -- the containment law (every flattened point "
                      "inside the box, and the box touched on all four sides) "
                      "is available here, unwritten",
    "element_evaluated_bounds": "PHASE 2 -- as `element_bounds`, through the "
                                "element's own matrix and its ancestors'",
    "flatten": "PHASE 2 -- the deviation law (every sample within eps of the "
               "analytic curve, and the endpoints exact) is available here",
    "art_flatten": "PHASE 2 -- as `flatten`, on the first-subpath walker",
    "calligraphic_outline": "PHASE 2 -- the ribbon law (both rails everywhere "
                            "half the declared width from the spine) is "
                            "available here, unwritten",
    "offset_path": "PHASE 4 -- two laws are available at this seam and both "
                   "are unwritten. (1) THE RAIL LAW: every rail point sits "
                   "exactly wl (or wr) from the spine along the spine's own "
                   "normal, which is `calligraphic_outline`'s ribbon law with "
                   "a profile instead of a constant, so one predicate should "
                   "serve both. (2) THE CAP LAW, which is the sharper one and "
                   "is why this row says PHASE 4 rather than PHASE 2: SVG "
                   "11.4 defines a round cap as a SEMICIRCLE OF RADIUS HALF "
                   "THE STROKE WIDTH CENTRED ON THE ENDPOINT, and that is a "
                   "closed-form statement about the emitted polygon -- every "
                   "cap vertex is exactly r from the endpoint, the two ends "
                   "of the sweep ARE the two rail points, and the sweep lies "
                   "on the far side of the endpoint from the spine. It needs "
                   "no probe, no seed and no sampling box; it is exact, which "
                   "is the posture docs/CHECKERS.md section 4b asks for "
                   "first. It is unwritten because this pass was the "
                   "PLUMBING: the family had no verb, no fixture and no wire "
                   "at all until 2026-08-01",
    "paste_translate": "PHASE 2 -- the Preservation Law is checkable (every "
                       "coordinate moved by exactly the offset, every other "
                       "field byte-identical); it needs a document differ",
    "arrow_trim": "PHASE 2 -- the arc-length law (the trimmed end sits exactly "
                  "the setback along the original path) is available here",
    "path_project": "PHASE 2 -- the nearest-point law (no sample on the "
                    "segment is closer than the returned one) is available "
                    "here and needs no new instrument",
    "align": "PHASE 2 -- the coincidence law (each element's declared edge "
             "lands on the target edge, and the perpendicular axis does not "
             "move) is available here",
    "fit_curve": "PHASE 2 -- the max-deviation law over the input points",
    "shape_recognize": "PHASE 2 -- as `fit_curve`, plus a residual bound",
    "hit_test": "PHASE 3 -- no longer blocked on the instrument (spec/geometry"
                "/region.py exists and both boolean families rule with it), "
                "but hit_test's wire carries PATH COMMANDS and a tolerance, "
                "not rings, so the law needs the flattener's deviation "
                "property underneath it before a membership answer means "
                "anything",
    "planar": "PHASE 3 -- the instrument is no longer the blocker; what is "
              "missing is the adapter. planar's wire carries POLYLINES and "
              "emits FACES, and `a face is a minimal cycle of the arrangement` "
              "is not expressible as a membership question over the input "
              "rings the way a boolean result is. It carries a property "
              "STRATEGY today, which is a comparison rule, not a law",
    "polygon_metrics": "IT IS THE INSTRUMENT, and it is now the SECOND one: "
                       "spec/geometry/region.py answers the same membership "
                       "question, harness-side, importing nothing. Its checker "
                       "is the migration that retires the two production "
                       "copies (Phase 3, split out of Phase 2 deliberately) -- "
                       "until then this family pins the two hand-mirrored "
                       "copies against each other and nothing pins them "
                       "against the analytic tier",
    "paragraph_markers": "the marker table IS the spec (PARAGRAPH.md's "
                         "enumeration), so a law would restate it; the two "
                         "numeral encoders admit a real law -- to_alpha and "
                         "to_roman must be INJECTIVE and monotone over their "
                         "ranges -- and that is PHASE 3, unwritten",
    "hyphenator": "PHASE 3 -- the real law is that a break may fall only "
                  "where the MAXIMUM pattern level is odd, which is Liang's "
                  "rule stated over the pattern set rather than over the "
                  "code, plus the two window constraints. Unwritten: this "
                  "phase is the plumbing pass",
    "simplify": "PHASE 3 -- the max-deviation law (every input vertex within "
                "`precision` of the emitted curve) is the same law "
                "`fit_curve` needs and should be written once for both; "
                "additionally, no emitted vertex may fall on a detected "
                "corner's interior. Unwritten",
    "dash_renderer": "PHASE 3 -- and a strong law is available with no new "
                     "instrument: the emitted sub-paths must be DISJOINT and "
                     "ARC-LENGTH ORDERED, their total length must equal the "
                     "pattern's duty cycle times the path length (exactly in "
                     "preserve mode, and within the solved scale in align "
                     "mode), and every sub-path must lie ON the original "
                     "path. All three are properties of the answer, not "
                     "restatements of the walk",
    "art_along_path": "PHASE 3 -- the real law is a RIBBON law, the same one "
                      "`calligraphic_outline`'s gap row names: every warped "
                      "point must sit within h_out/2 of the spine, measured "
                      "perpendicular, and its arc-length position must be the "
                      "declared fraction of the path. Unwritten",
    "pattern_along_path": "PHASE 3 -- as `art_along_path`, plus a tiling "
                          "clause: consecutive tiles must be exactly `step` "
                          "apart in arc length and must not overlap",
    "bristle_stroke": "PHASE 3 -- the spread law: the bristle offsets must be "
                      "symmetric about the spine, evenly spaced, and span "
                      "exactly the brush width. It is a property of the "
                      "answer and needs no new instrument. Unwritten",
    "transform_apply": "PHASE 3 -- and a real law is available: each matrix "
                       "must FIX its reference point, and rotate must "
                       "preserve every pairwise distance while scale "
                       "multiplies each axis-parallel one by its factor. "
                       "Both are properties of the map, not restatements of "
                       "the builder. Unwritten: this phase is the plumbing "
                       "pass",
    "arrangement": "PHASE 3 -- and it is a REAL law, not a restatement: the "
                   "triple (p, s, t) must be SELF-CONSISTENT (p within "
                   "tolerance of both lerp(a1,a2,s) and lerp(b1,b2,t), both "
                   "parameters in [0,1]), and the reported set must be "
                   "COMPLETE against an independent exact-arithmetic "
                   "orientation test on the small-integer vectors. Neither "
                   "clause needs the module opened. Unwritten because this "
                   "phase is the plumbing pass and the verb had to exist "
                   "first; the fixture's `derivation` fields are the "
                   "hand-derived half already",
    "text_layout": "no geometry law without a font oracle: advance widths come "
                   "from the platform, so any predicate would be a golden",
    "text_layout_paragraph": "as `text_layout`",
    "path_text_layout": "as `text_layout`; the arc-length half is checkable "
                        "and is PHASE 2, the glyph half is not",
}

# The REVERSE direction, mechanised. Each registered checker names the shape it
# consumes; if a GAP algorithm's fixture starts carrying that shape, the gap
# row is stale and must be deleted rather than left asserting a hole that has
# closed. One direction of policing is how a stale exemption survives.
CHECKER_PROBES = {
    "gradient_remap_repaints_the_fragment":
        lambda v: all(k in v for k in ("angle", "parent", "fragment", "stops")),
    "boolean_result_is_the_sampled_combination":
        lambda v: ("function" in v and _is_ring_list(v.get("a"))
                   and _is_ring_list(v.get("b"))),
    "normalize_preserves_the_declared_region":
        lambda v: "input" in v and _is_ring_list(v.get("input")),
}


def _is_ring_list(value):
    """Is this a list of rings -- each a list of at least two [x, y] pairs?

    Deliberately structural rather than key-named: it is the SHAPE a region
    law consumes, so a gap row whose fixture starts carrying rings can be
    found stale by it. `input` alone would not do -- five tspan families and
    `length` carry an `input` of a completely different kind.
    """
    if not isinstance(value, list) or not value:
        return False
    for ring in value:
        if not isinstance(ring, list) or len(ring) < 2:
            return False
        for pt in ring:
            if not (isinstance(pt, list) and len(pt) == 2
                    and all(isinstance(c, (int, float))
                            and not isinstance(c, bool) for c in pt)):
                return False
    return True

# THE WITNESS SET'S SHAPE, WHICH ITS SIZE CANNOT SPEAK TO.
#
# Nine vectors and 585 sample comparisons, all green, all blind: every bbox in
# this family had one side exactly zero, so hypot(w,h) equalled max(w,h) on all
# eighteen of them and `half the DIAGONAL` -- the distinctive clause of the
# denotation -- was exercised by nothing. Counting vectors cannot see that.
# Counting samples cannot see that. Both measure POPULATION; the defect is
# COLLINEARITY, a property of the span.
#
# So a law may also declare what its witnesses must SEPARATE. Each probe below
# is a named property of a single vector; the fixture declares how many
# vectors must satisfy it, and the runner counts. The floors are total in both
# directions (see `_checker_config`): a declared floor with no probe is a
# number nothing measures, and a probe with no declared floor is a measurement
# nothing asserts.
#
# WHAT THIS IS NOT: it is a REGRESSION floor, not a discovery instrument. It
# keeps a clause that has been noticed from going unexercised again; it cannot
# tell anyone which clause to notice next. See docs/CHECKERS.md for the
# general answer (a mutant per clause of the analytic tier), of which this is
# the hand-rolled special case for the one clause that was caught.
CHECKER_WITNESS_PROBES = {
    "gradient_remap_repaints_the_fragment": {
        "two_dimensional_boxes":
            lambda v: all(b[2] > 0 and b[3] > 0
                          for b in (v["parent"], v["fragment"])),
        # The separation that matters, stated directly rather than inferred
        # from two-dimensionality: a corpus could be two-dimensional and still
        # not distinguish the diagonal from the longer side.
        "diagonal_differs_from_longer_side":
            lambda v: any(abs(math.hypot(b[2], b[3]) - max(b[2], b[3])) > 1e-9
                          for b in (v["parent"], v["fragment"])),
        # ... and the ratio test: similar, concentric boxes agree on the
        # remap under BOTH formulas, so a corpus of scaled copies is blind
        # however two-dimensional it is. This is the property the
        # `concentric_*` vector was authored to hold.
        "aspect_ratio_differs_between_parent_and_fragment":
            lambda v: abs(_aspect(v["parent"]) - _aspect(v["fragment"])) > 1e-9,
    },
    # THE REGION LAW'S SPAN. Its denotation has two independent halves -- the
    # SET OPERATION (four clauses, one per function) and the FILL RULE that
    # reads each operand (two clauses, and the non-zero one is the whole
    # content of the carried-rule ruling). A corpus can be any size, be
    # perfectly green, and exercise one value of each: thirteen union-only
    # vectors over single-ring even-odd operands would satisfy every count
    # while leaving `contains(..., NON_ZERO)` and three of the four
    # combination clauses run by nothing. That is `half_diag` with different
    # arithmetic, so it is written down rather than hoped for.
    "boolean_result_is_the_sampled_combination": {
        "union_vectors": lambda v: v.get("function") == "union",
        "intersect_vectors": lambda v: v.get("function") == "intersect",
        "subtract_vectors": lambda v: v.get("function") == "subtract",
        "exclude_vectors": lambda v: v.get("function") == "exclude",
        # The carried rule, on the operand side. Without one of these the
        # non-zero half of `contains` is dead code in every run, and the
        # pre-ruling behaviour -- a declared rule silently discarded -- would
        # be reintroducible with the whole board green.
        "operand_declares_nonzero":
            lambda v: rg.NON_ZERO in (v.get("a_fill_rule"),
                                      v.get("b_fill_rule")),
        # "The rule reads the WHOLE SET at once, not ring by ring" is only a
        # claim about sets with more than one ring.
        "operand_with_multiple_rings":
            lambda v: max(len(v.get("a") or []), len(v.get("b") or [])) > 1,
        # Disjoint operands make intersect and subtract trivial and make
        # union a concatenation: a corpus of them cannot separate the four
        # clauses from each other however many vectors it holds.
        "operands_overlap_in_area": lambda v: _bbox_overlap_area(v) > 0.0,
    },
    "normalize_preserves_the_declared_region": {
        # Same argument, one operand: the rule is the only thing normalize
        # SPENDS (BOOLEAN.md clause 3), so a corpus with no non-zero vector
        # watches the rule-reading half of this family with nothing.
        "declares_nonzero":
            lambda v: v.get("fill_rule") == rg.NON_ZERO,
        "declares_evenodd_explicitly":
            lambda v: v.get("fill_rule") == rg.EVEN_ODD,
        # An input whose own rings are already simple and disjoint is a
        # pass-through, and a corpus of pass-throughs cannot tell
        # canonicalisation from the identity function.
        "input_ring_is_not_simple":
            lambda v: any(rg.ring_defect(r) is not None
                          for r in (v.get("input") or [])),
        "input_has_multiple_rings": lambda v: len(v.get("input") or []) > 1,
    },
}


def _bbox_overlap_area(vec):
    """The area shared by operand A's and operand B's bounding boxes.

    A bbox test, not a region test: it is a WITNESS probe, so it must be
    cheap, total, and computable from the vector alone. Zero for disjoint
    operands and for operands that only touch along an edge.
    """
    ba = rg.bounding_box([vec.get("a") or []])
    bb = rg.bounding_box([vec.get("b") or []])
    if ba is None or bb is None:
        return 0.0
    w = min(ba[2], bb[2]) - max(ba[0], bb[0])
    h = min(ba[3], bb[3]) - max(ba[1], bb[1])
    return w * h if w > 0 and h > 0 else 0.0


def _aspect(bbox):
    """w/h for a bbox, with the degenerate cases mapped to distinct sentinels
    so a zero-height box never compares equal to a zero-width one."""
    w, h = bbox[2], bbox[3]
    if h == 0:
        return math.inf if w != 0 else -1.0
    return w / h


# Keys a checker may NEVER see. Mechanical, not intended: `expected` is the
# port's own pinned answer, and a predicate that reads it is differential
# testing wearing a hat.
CHECKER_FORBIDDEN_INPUT_KEYS = ("expected", "translations")


def checker_input(vec):
    """The vector as the law is allowed to see it: input only."""
    return {k: v for k, v in vec.items()
            if k not in CHECKER_FORBIDDEN_INPUT_KEYS}


def _fmt_colour(c):
    return "rgb({:.1f},{:.1f},{:.1f})@{:.1f}%".format(*c)


def gradient_remap_repaints_the_fragment(vec, out_stops, cfg):
    """THE LAW. A remapped gradient must paint the fragment the colours the
    parent painted over that same region.

    Written from `PATH_ERASER_TOOL.md` and the fixture's `_doc`, both of which
    state what a linear gradient MEANS; `gradient_remap.rs` was not opened.
    Returns None when the output is legal, else why it is not.
    """
    u = lg.axis_unit(vec["angle"])
    parent_centre, parent_half = lg.ramp(vec["parent"], u)
    frag_centre, frag_half = lg.ramp(vec["fragment"], u)
    n, tol = cfg["samples_per_vector"], cfg["tolerance_bytes"]
    # A uniform sweep of the fragment's own ramp, plus its knots: a piecewise
    # linear ramp can only bend at a stop, so a grid that misses the stops can
    # miss the bend.
    places = sorted({100.0 * k / (n - 1) for k in range(n)}
                    | {s["location"] for s in out_stops
                       if 0.0 <= s["location"] <= 100.0})
    for loc in places:
        here = lg.location_to_axial(loc, frag_centre, frag_half)
        want = lg.colour_at_axial(vec["stops"], parent_centre, parent_half, here)
        got = lg.colour_at_location(out_stops, loc)
        off = max(abs(a - b) for a, b in zip(want, got))
        if off > tol:
            return (f"{loc:g}% along the fragment: the parent painted "
                    f"{_fmt_colour(want)} there, the remap paints "
                    f"{_fmt_colour(got)} (off by {off:.3f} > {tol:g})")
    return len(places)


def gradient_remap_is_rulable(vec):
    """Why this vector cannot be ruled, or None if it can.

    A zero-length ramp collapses every location onto one point, so "what
    colour is here" has no answer. Declared rather than silently skipped: the
    fixture must name every unrulable vector, and a vector that becomes
    rulable makes the declaration stale.
    """
    u = lg.axis_unit(vec["angle"])
    if lg.ramp(vec["parent"], u)[1] == 0.0:
        return "the parent's ramp has zero length"
    if lg.ramp(vec["fragment"], u)[1] == 0.0:
        return "the fragment's ramp has zero length"
    return None


def gradient_remap_mutant(vec, out):
    """THE BUG, WRITTEN DOWN -- not a second copy of the implementation.

    PROVENANCE: this is the PRE-S-2 SHIPPING BEHAVIOUR, named in the fixture's
    own `_doc` ("a fragment that inherits its parent's gradient verbatim
    RE-FITS the whole ramp to its own smaller box: three fragments of a
    red-to-blue hull each run the full red-to-blue instead of each showing its
    slice") and in transcripts/BOOLEAN.md's statement of the phase-2 debt. It
    is a historical wrong answer, not an invented one -- a mutant an author
    invents is a self-graded exam, and its discriminating count reads healthy
    forever.

    `out` is unused: this bug is expressible from the INPUT alone. Not every
    one is -- see `boolean_pinch_regression_mutant`, whose bug is a bug of
    ENCODING and therefore has no expression that does not mention the
    encoding it corrupts.
    """
    del out
    return copy.deepcopy(vec["stops"])


# ---------------------------------------------------------------
# THE REGION LAWS -- the sampled winding rule, Phase 2
# ---------------------------------------------------------------
#
# WHAT THESE BUY THAT `compare_exact_boolean` CANNOT. That comparison demands
# ELEMENTWISE RING EQUALITY at 4dp: same ring order, same starting vertex,
# same direction, same vertex count. The REGION is unique but the RING
# ENCODING IS NOT -- ring order, start vertex, winding, one-ring-versus-two
# at a pinch and retained collinear vertices are every one of them free -- so
# that comparison is an ADMISSION BARRIER (it would red a third port, a
# Skia/Vello rewrite, or any snap_grid change that moved a coordinate by an
# ulp) while ALSO being unable to see a wrong region except differentially,
# which is to say only when the two ports are wrong in DIFFERENT ways.
#
# These laws are the other instrument, not a replacement: they rule the
# REGION and are blind to the encoding, they need only ONE lane (so the
# Windows seat, which has no Swift toolchain, adjudicates them in full), and
# a bug SHARED by both ports does not make them green. Both instruments run.
# Demoting the older one is a scope call for JYH, not for a checker author,
# and nothing here does it.
#
# THE LAW ITSELF, in one sentence: a point is in `A u B` iff it is in A or in
# B; in `A n B` iff in both; in `A - B` iff in A and not B; in `A xor B` iff
# in exactly one -- with membership read by ray cast over the ORIGINAL
# OPERAND RINGS under each operand's DECLARED fill rule, never over the
# sweep's output. Written from transcripts/BOOLEAN.md and the fixtures' own
# `_derivation` prose; neither boolean.rs nor Boolean.swift was opened to
# write it, and neither needs to be read to check it.


# The generative lane's seed for this process. Fresh nanoseconds by default;
# `JAS_PROPERTY_SEED` replays a run exactly. Resolved ONCE and printed at the
# head of the checker pass, per docs/CHECKERS.md section 5.
_REGION_RUN_SEED = None


def region_run_seed():
    global _REGION_RUN_SEED
    if _REGION_RUN_SEED is None:
        raw = os.environ.get("JAS_PROPERTY_SEED")
        if raw:
            _REGION_RUN_SEED = int(raw, 0) & ((1 << 64) - 1)
        else:
            import time
            _REGION_RUN_SEED = pr.finalize(time.time_ns())
    return _REGION_RUN_SEED


def _region_probe_points(cfg, law, vname, ring_sets):
    """The two lanes' probe points for one vector: `[(lane, (x, y)), ...]`.

    ANCHOR first (a deterministic jittered lattice, seedless, identical on
    every machine and every run), then GENERATIVE (a fresh draw from this
    run's seed). The box spans every ring of every operand AND of the result,
    grown by `sampling_box`.

    THE LANE COMES FROM THE PRODUCER, NEVER FROM THE INDEX. `pr.lattice` and
    `pr.scatter` each label what they draw. The label used to be recovered
    downstream as `"lattice" if idx < lattice_side ** 2 else "prng"`, which is
    not a reading of the lane but a MODEL of this function's concatenation
    order -- correct today, and silently wrong the moment the order changes,
    a lane is inserted, or the lattice emits a count other than side*side.
    That is tolerable in a failure MESSAGE and intolerable in a FLOOR, and the
    floors are per-lane now.

    A CORRECTION, BECAUSE THE OPPOSITE WAS WRITTEN HERE AND IT WAS FALSE.
    This sentence used to end "so a result that leaks outside the operands'
    hull is probed where it leaked rather than only where it was expected."
    It does not. The box is a FUNCTION OF THE OUTPUT, so a leak MOVES the
    box rather than being caught inside it: the probes follow the runaway
    into empty plane, every one of them stands clear of every edge, every one
    of them agrees with the spec that the empty plane is empty, and the lane
    reports a full sample having asked nothing about the region under test.
    Measured on `union_overlapping_squares`: append a 1pt ring 100pt away and
    `accepted` stays 88 of 88 against a floor of 64 while the probes landing
    INSIDE the region fall from 31 to ZERO -- and 0 of 17 vectors noticed,
    across 10 seeds, for specks of 0.1pt and 1.0pt at 100pt, 1000pt and
    10000pt.

    Why the result is nevertheless in the box: so that the NEGATIVE half of
    the membership question is asked where the result actually claims area.
    A leak is refused by `region.containment_defect` -- exactly, with no
    probe at all -- before this function is ever called, and the blindness
    itself is refused by the INSIDE floor below. Neither job belongs to a
    sampling box, and giving one of them to a sampling box is how F1 hid.
    """
    box = rg.bounding_box(ring_sets)
    if box is None:
        return None
    box = pr.sampling_box(box)
    points = list(pr.lattice(box, cfg["lattice_side"], law, vname))
    stream = pr.Stream(pr.derive(region_run_seed(), law, vname))
    points += list(pr.scatter(box, cfg["prng_probes"], stream))
    return points


def _rule_region(cfg, law, vname, out_rings, operand_sets, want, described):
    """The shared body of both region laws.

    `want(point) -> bool` is the spec's answer at a place, computed from the
    operands. `described` names the operands for the failure message. Returns
    `{lane: probes ruled}` for every probe lane, or a string saying why the
    output is illegal.

    FOUR CLAUSES, in this order, and the order is load-bearing:

      1. every result ring is SIMPLE            exact, per ring
      2. the result is CONTAINED in its operands' boxes   exact, per vertex
      3. the sample is BIG enough (accepted) and SAYS something (inside),
         IN EVERY LANE SEPARATELY
      4. the rings are LAMINAR, and every accepted probe's membership agrees

    The two exact clauses run before any probe is placed, because both of
    them describe defects that CORRUPT THE SAMPLE. A non-simple ring makes
    every membership answer over it suspect; a runaway vertex inflates the
    sampling box until the probes stop touching the subject. A sampled clause
    cannot adjudicate a defect that moves the sample.

    CLAUSE 3 IS CHARGED PER LANE, AND THAT IS THE WHOLE POINT OF HAVING TWO.
    The probes are `lattice(64) + scatter(24)` concatenated, and both floors
    used to be compared against the UNION -- so a fully blind ANCHOR lane was
    paid for by the generative lane's draws, on a floor DERIVED FROM THE
    ANCHOR LANE and justified in the fixture by the sentence "the generative
    lane's variation can only add to it". It could also substitute for it.
    MEASURED, 40 seeds: displace every lattice probe 10000pt (so all 64 are
    still ACCEPTED and none is informative) and the old union floors still
    pass 11 to 15 of `boolean`'s 17 non-empty vectors, median 13, and 0 to 4
    of `boolean_normalize`'s 16, median 1 -- the seedless lane a bisect
    depends on having asked nothing at all. Under the per-lane floors it is
    ZERO in both families at every one of those seeds. Each lane meets its
    own floor or the vector reds, and the red names the lane.
    """
    eps = cfg["tolerance_points"]
    lanes = pr.PROBE_LANES

    # THE STRUCTURAL HALF, first, because it needs no probe and because a
    # ring that is not simple makes every membership answer over it suspect.
    for i, ring in enumerate(out_rings):
        why = rg.ring_defect(ring)
        if why is not None:
            return (f"result ring {i} is not a simple closed curve: {why}. "
                    f"A region's encoding may not revisit a place -- this is "
                    f"the pinch regression's signature, and no membership "
                    f"question can see it")

    # THE CONTAINMENT CLAUSE, second, and still before any probe. Every
    # boolean of A and B is a SUBSET of `A u B`, and canonicalisation returns
    # the region it was given, so every result vertex must lie inside the box
    # of some operand. EXACT, O(vertices), and its only tolerance is the
    # serialisation epsilon this fixture already had to derive.
    #
    # IT MUST BE EXACT AND IT MUST RUN BEFORE THE SAMPLE. A far spurious ring
    # -- what a near-parallel intersection in a sweep-line boolean produces,
    # and a named failure mode -- INFLATES THE SAMPLING BOX, so the sampled
    # half of this law cannot see it at any density: the probes follow the
    # runaway and the refusal count stays perfect. See
    # `region.containment_defect` for the measurement.
    why = rg.containment_defect(
        out_rings, [rg.bounding_box([rings]) for rings in operand_sets], eps)
    if why is not None:
        return (f"the result reaches outside its operands: {why}. Every "
                f"boolean of A and B is a subset of A u B and no "
                f"canonicalisation adds area, so this is impossible for a "
                f"correct result -- and it is the one defect the sampled half "
                f"of this law can never see, because it moves the "
                f"sampling box")

    points = _region_probe_points(cfg, law, vname,
                                  list(operand_sets) + [out_rings])
    if points is None:
        return "there is no vertex anywhere to build a sampling box from"

    all_sets = list(operand_sets) + [out_rings]
    accepted = {lane: 0 for lane in lanes}
    inside = {lane: 0 for lane in lanes}
    per_ring = []
    membership_failure = None
    seen_lanes = set()
    for idx, (lane, p) in enumerate(points):
        # THE LANE IS READ, NOT DERIVED FROM `idx`. A lane the fixture does
        # not floor would otherwise be accumulated into a dict key nothing
        # asserts on and vanish -- the same shape as R5's "a lane that ruled
        # zero is ABSENT from the account, not present with a zero".
        seen_lanes.add(lane)
        if lane not in accepted:
            return (f"probe #{idx} came from lane '{lane}', which "
                    f"`spec.geometry.probes.PROBE_LANES` does not name, so no "
                    f"floor in this fixture is charged to it: an unfloored "
                    f"lane is a sample nobody has to answer for")
        # THE REJECTION. A point on a boundary has no defined answer, and the
        # three float dialects need not agree which side of an edge it is on.
        # Refusing it is what makes this law STRICT rather than FLAKY -- and
        # the refusal is counted, so a vector whose probes were all refused
        # reports itself instead of passing vacuously.
        if any(rg.distance_to_boundary(rings, p) < eps for rings in all_sets):
            continue
        accepted[lane] += 1
        per_ring.append(rg.contains_per_ring(out_rings, p))
        got = rg.contains(out_rings, p, rg.RESULT_FILL_RULE)
        exp = want(p)
        # THE INFORMATION COUNT, taken from the SPEC's answer and not the
        # result's: how many of the probes this lane was willing to answer
        # actually landed in the region being adjudicated. `accepted` counts
        # refusals; this counts information, and they are not the same
        # number. See the floor below.
        if exp:
            inside[lane] += 1
        if got != exp and membership_failure is None:
            membership_failure = (
                f"at ({p[0]:.6f}, {p[1]:.6f}) [{lane} probe #{idx}, run "
                f"seed 0x{region_run_seed():016x}]: {described} puts this "
                f"point {'INSIDE' if exp else 'OUTSIDE'} the region, the "
                f"result puts it {'INSIDE' if got else 'OUTSIDE'}")
            # NOT returned here. The whole probe set is walked first so the
            # STRUCTURAL verdict below can be reached: laminarity is a
            # property of the SAMPLE, not of a point, and returning at the
            # first wrong point would make that clause unreachable on every
            # output that is both misshapen and mis-membered -- which is
            # most of them. A structural verdict also says more: "these two
            # rings cross" names a cause, where "this point is on the wrong
            # side" names a symptom.

    # EVERY DECLARED LANE MUST HAVE DRAWN. A lane that emitted nothing
    # contributes a zero to no accumulator at all -- `accepted[lane]` stays at
    # its initialised 0 and reads exactly like a lane that drew and was
    # refused. Same sentence as R5's, one instrument down: a lane that ruled
    # zero is ABSENT from the account, not present with a zero, so the absence
    # is asserted rather than the presence.
    for lane in lanes:
        if lane not in seen_lanes:
            return (f"the '{lane}' probe lane produced NO PROBE AT ALL for "
                    f"this vector, so every floor charged to it is met by an "
                    f"accumulator that was never touched. Look for a probe "
                    f"count of zero in the fixture, or a generator that "
                    f"stopped yielding")

    # THE POPULATION FLOOR, PER LANE. It counts REFUSALS, and it cannot tell a
    # lane that sampled its subject from one that sampled empty plane -- those
    # are the same number, which is why the INFORMATION floor below exists
    # too. Per lane, because 64 of 88 is met by an anchor lane that refused a
    # third of its probes as long as the generative lane made the difference
    # up, and the anchor lane is the one whose count is supposed to be
    # reproducible.
    for lane in lanes:
        # Indexed, not `.get`: a missing per-lane floor is refused by
        # `_checker_config` before any vector is ruled, so a KeyError here
        # would mean the gate that guarantees it did not run.
        floor = cfg["min_accepted_per_vector"][lane]
        drawn = sum(1 for lane_of, _ in points if lane_of == lane)
        if accepted[lane] < floor:
            return (f"the '{lane}' lane accepted only {accepted[lane]} of its "
                    f"{drawn} probes (the other lane(s) accepted "
                    f"{ {l: accepted[l] for l in lanes if l != lane} }); "
                    f"floor for this lane is {floor}. A run that sampled "
                    f"almost nothing is not evidence, and it is the one "
                    f"failure mode that looks like success. THE FLOOR IS PER "
                    f"LANE because a union total lets the lane that varies "
                    f"discharge the obligation of the lane that does not")

    # THE INFORMATION FLOOR. `min_accepted_per_vector` above counts REFUSALS
    # and cannot tell a lane that sampled its subject from one that sampled
    # empty plane; those are the same number. This floor counts the probes
    # that landed INSIDE the region under test, which is the quantity that
    # actually goes to zero when the instrument goes blind -- measured, 88
    # accepted of 88 with ZERO inside, on a vector carrying a 1pt ring 100pt
    # away.
    #
    # IT IS CHARGED TO THE LANE IT WAS DERIVED FROM, WHICH IS THE ANCHOR LANE,
    # AND THAT IS THE REPAIR. The number is the corpus minimum over the
    # seedless lattice, and the fixture's own justification for it -- "the
    # generative lane's 24 draws can only add to it and the floor cannot go
    # flaky" -- was true of the FLOOR'S STABILITY and false of what the floor
    # then measured: 24 draws that can only add can also be the only thing
    # there. Blind the lattice on this corpus and boolean's union floor of 3
    # is still paid, by the generative lane alone, on a median of 13 of its
    # 17 non-empty vectors (11 to 15 over 40 seeds).
    #
    # THE GENERATIVE LANE CARRIES NO INFORMATION FLOOR, AND THAT IS DECLARED
    # RATHER THAN OMITTED (`checker.no_information_floor`, policed both ways
    # by `_checker_config`). It is not an oversight and it is not laziness: 24
    # uniform draws over a box a region fills 3/64 of put ZERO probes inside
    # in about a third of runs -- measured over 300 seeds, SIX of boolean's
    # non-empty vectors reach 0 -- so any per-vector information floor here
    # would be flaky, and a flaky floor is lowered until it is vacuous. The
    # information guarantee is the anchor lane's job precisely because the
    # anchor lane is deterministic; the generative lane's job is discovery,
    # and it is held to a POPULATION floor above so that a lane which stopped
    # running still reds.
    #
    # AND ITS EXEMPTION IS DECLARED, NEVER SILENT. Some regions really are
    # empty by construction -- an intersection of disjoint operands, a
    # canonicalisation of a zero-area input -- and for those, zero probes
    # inside is the correct and complete answer: the adjudication is that
    # every accepted probe is ruled OUTSIDE, which is a strong claim and not
    # a vacuous one. Those vectors are named in `checker.empty_regions` with
    # their reason, and the naming is policed BOTH WAYS: a declaration the
    # sample contradicts is refused here, and a declaration naming a vector
    # this fixture does not rule is refused by the runner. Sampling can
    # witness non-emptiness exactly (one probe inside proves it) and can
    # never prove emptiness, which is precisely why the emptiness claim is a
    # sentence a human wrote and not a number a run measured. An empty
    # declaration is now refused by ANY lane finding a point inside, not by
    # their sum -- the sum is the same test, but naming the lane says where
    # to look.
    empty_reason = (cfg["empty_regions"] or {}).get(vname)
    if empty_reason is not None:
        for lane in lanes:
            if inside[lane]:
                return (f"`checker.empty_regions` declares this vector's "
                        f"region EMPTY BY CONSTRUCTION -- \"{empty_reason}\" "
                        f"-- but {inside[lane]} of the '{lane}' lane's "
                        f"{accepted[lane]} accepted probes land INSIDE it by "
                        f"the spec's own reading. The declaration is false, "
                        f"and a false exemption is worse than no exemption")
    else:
        for lane in lanes:
            floor = (cfg["min_inside_probes_per_vector"] or {}).get(lane)
            if floor is None or inside[lane] >= floor:
                continue
            return (f"the '{lane}' lane put only {inside[lane]} of its "
                    f"{accepted[lane]} accepted probes INSIDE the region "
                    f"under test, floor {floor} for this lane (the other "
                    f"lane(s) put { {l: inside[l] for l in lanes if l != lane} }"
                    f" inside, and they may not pay this floor). This lane "
                    f"refused almost nothing and asked almost nothing. THE "
                    f"SAMPLING BOX IS A FUNCTION OF THE OUTPUT, so a result "
                    f"that runs away takes the probes with it and every count "
                    f"stays healthy. If this region is genuinely empty by "
                    f"construction, say so by name in "
                    f"`checker.empty_regions` with the reason; do not lower "
                    f"this floor, and do not move it to the other lane")

    why = rg.laminarity_defect(per_ring, len(out_rings))
    if why is not None:
        return why
    return membership_failure if membership_failure is not None else dict(accepted)


def _operand(vec, key):
    return [[(float(p[0]), float(p[1])) for p in ring]
            for ring in (vec.get(key) or [])]


def _declared_rule(vec, key):
    """The rule an operand declares, or the standing default.

    BOOLEAN.md clause 1: a bare ring list means EVEN-ODD. Absent is not
    "whatever the algorithm prefers" -- that reading is the pre-ruling defect
    this checker exists to keep out.
    """
    return vec.get(key) or rg.DEFAULT_FILL_RULE


_COMBINE = {
    "union":     lambda a, b: a or b,
    "intersect": lambda a, b: a and b,
    "subtract":  lambda a, b: a and not b,
    "exclude":   lambda a, b: a != b,
}


def boolean_result_is_the_sampled_combination(vec, out, cfg):
    """THE LAW. A point is in the result iff the operation says it is in the
    combination of the two operands, read at that point.

    Written from transcripts/BOOLEAN.md (the carried-rule ruling, RULED
    2026-07-26) and boolean.json's own `_derivation` prose. `boolean.rs` and
    `Boolean.swift` were not opened; nothing below mentions a sweep, an
    event, a queue or an edge chain, because the law is about the plane and
    not about how the plane was carved.
    """
    a, b = _operand(vec, "a"), _operand(vec, "b")
    rule_a = _declared_rule(vec, "a_fill_rule")
    rule_b = _declared_rule(vec, "b_fill_rule")
    combine = _COMBINE[vec["function"]]

    def want(p):
        return combine(rg.contains(a, p, rule_a), rg.contains(b, p, rule_b))

    described = (f"`A {vec['function']} B` (A read {rule_a}, B read {rule_b})")
    return _rule_region(cfg, "boolean_result_is_the_sampled_combination",
                        vec.get("name", "?"), out.get("rings") or [],
                        [a, b], want, described)


def boolean_is_rulable(vec):
    """Why this vector cannot be ruled, or None.

    Only one thing can stop it: no vertex anywhere in either operand, which
    leaves no place to put a probe. An EMPTY RESULT is perfectly rulable --
    every probe must then be outside, and that is a strong claim, not a
    vacuous one.
    """
    if rg.bounding_box([_operand(vec, "a"), _operand(vec, "b")]) is None:
        return "neither operand has a vertex, so there is nowhere to probe"
    for key in ("a_fill_rule", "b_fill_rule"):
        if vec.get(key) is not None and vec[key] not in rg.FILL_RULES:
            return f"{key}={vec[key]!r} is not a fill rule this law knows"
    if vec.get("function") not in _COMBINE:
        return f"function={vec.get('function')!r} has no combination clause"
    return None


def boolean_pinch_regression_mutant(vec, out):
    """THE BUG, WRITTEN DOWN. A multi-ring region emitted as ONE
    self-touching ring.

    PROVENANCE: boolean.json's own `_derivation` for
    `exclude_overlapping_squares` names it -- "the GAP THAT USED TO LIVE HERE
    (both ports emitting ONE self-touching twelve-vertex ring, because
    connect_edges cannot tell which of two regions touching at a pinch vertex
    it is on)" -- and transcripts/BOOLEAN.md records its repair as
    "Multi-ring results: FIXED 2026-07-26" by the split-at-repeated-vertex
    post-pass (`split_pinched_rings` / `splitPinchedRings`). A historical
    wrong answer, not an invented one.

    WHY IT MUST BE DERIVED FROM THE OUTPUT. This is a bug of ENCODING: the
    same region, emitted wrongly. There is no function of the INPUT that
    produces it, because producing it requires the region -- which is what
    the port under test is for. That is the whole reason the mutant signature
    takes `out`, and it is the reason this mutant is worth having: the clause
    it attacks (`every result ring is simple`) is exactly the one a
    membership question cannot ask, so a law without a structural half would
    swallow it whole. The concatenated ring SAMPLES CORRECTLY on some
    vectors; the structural clause is what refuses it.
    """
    del vec
    rings = out.get("rings") or []
    merged = [pt for ring in rings for pt in ring]
    return dict(out, rings=[merged] if merged else [])


def normalize_preserves_the_declared_region(vec, out, cfg):
    """THE LAW. Canonicalisation changes the ENCODING and never the REGION:
    the output, read even-odd, covers exactly the points the input covered
    when read under the rule the input DECLARED.

    Written from transcripts/BOOLEAN.md clause 3 -- "Canonicalization SPENDS
    the rule: `canonicalize` returns simple rings denoting THE SAME REGION
    read under even-odd, whatever rule came in. This is the single place a
    declared rule is interpreted" -- and from boolean_normalize.json's own
    per-vector `_derivation` arithmetic. `boolean_normalize.rs` was not
    opened.
    """
    src = _operand(vec, "input")
    rule = _declared_rule(vec, "fill_rule")

    def want(p):
        return rg.contains(src, p, rule)

    return _rule_region(cfg, "normalize_preserves_the_declared_region",
                        vec.get("name", "?"), out.get("rings") or [],
                        [src], want,
                        f"the input read {rule}")


def normalize_is_rulable(vec):
    """Why this vector cannot be ruled, or None.

    An input with no vertex at all denotes the empty region and offers no
    place to probe, so there is no question to ask. Declared in the fixture
    by name rather than skipped in silence.
    """
    if rg.bounding_box([_operand(vec, "input")]) is None:
        return "the input has no vertex, so there is nowhere to probe"
    if vec.get("fill_rule") is not None \
            and vec["fill_rule"] not in rg.FILL_RULES:
        return f"fill_rule={vec['fill_rule']!r} is not a fill rule"
    return None


def normalize_unspent_rule_mutant(vec, out):
    """THE BUG, WRITTEN DOWN. Normalisation that does NOT spend the rule:
    the input's rings handed straight back, to be read even-odd downstream.

    PROVENANCE: the pre-ruling state, recorded in transcripts/BOOLEAN.md's
    "Superseded reading, for the record" -- "the tree contradicted itself:
    `algorithms/boolean` declared even-odd with orientation outside the
    contract, while `algorithms/boolean_normalize` documented its input as
    non-zero winding", and clause 3's remedy, "canonicalization SPENDS the
    rule ... this is the single place a declared rule is interpreted". Its
    artist-visible symptom is stated one section up: "a document declaring
    fill-rule=nonzero would be silently reinterpreted by a boolean operation,
    and the artist would get a hole they never drew."

    It attacks BOTH halves of the law at once, which is why this family
    carries it rather than the pinch regression: on a non-zero vector it is a
    WRONG REGION (the membership clause refuses it), and on a self-crossing
    or retraced input it is a NON-SIMPLE RING (the structural clause refuses
    it), and the two sets of vectors barely overlap.
    """
    return dict(out, rings=copy.deepcopy(vec.get("input") or []))


CHECKER_FUNCS = {
    "gradient_remap_repaints_the_fragment": (
        gradient_remap_repaints_the_fragment,
        gradient_remap_is_rulable,
        gradient_remap_mutant,
    ),
    "boolean_result_is_the_sampled_combination": (
        boolean_result_is_the_sampled_combination,
        boolean_is_rulable,
        boolean_pinch_regression_mutant,
    ),
    "normalize_preserves_the_declared_region": (
        normalize_preserves_the_declared_region,
        normalize_is_rulable,
        normalize_unspent_rule_mutant,
    ),
}


# Keys a PARTICULAR law requires of its fixture, on top of the generic block.
# Declared per law rather than added to the generic list because a floor
# nothing evaluates reads as a guarantee: `empty_regions` means nothing to
# `gradient_remap`, and requiring it there would put an empty promise in a
# fixture no law would ever check it against.
#
# It is also the repair of a real hole. `lattice_side`, `prng_probes` and
# `min_accepted_per_vector` were read straight out of `cfg` by the region
# laws and required by nothing, so a fixture that dropped one got a
# KeyError traceback from the runner instead of a sentence naming the
# missing floor -- and a floor whose absence is a crash is a floor nobody
# can reason about.
CHECKER_LAW_REQUIRED_KEYS = {
    "boolean_result_is_the_sampled_combination": (
        "lattice_side", "prng_probes", "min_accepted_per_vector",
        "min_inside_probes_per_vector", "min_checks_per_probe_lane",
        "no_information_floor", "empty_regions"),
    "normalize_preserves_the_declared_region": (
        "lattice_side", "prng_probes", "min_accepted_per_vector",
        "min_inside_probes_per_vector", "min_checks_per_probe_lane",
        "no_information_floor", "empty_regions"),
}

# Floors a SAMPLED law declares once PER PROBE LANE, and whether a lane may
# be excused from carrying one.
#
# The two lanes of `spec/geometry/probes.py` are not interchangeable -- one is
# seedless and reproducible, the other is fresh every run -- so a single
# number compared against their UNION is discharged by whichever of them
# happens to have it, and the floor stops meaning what its own `_why` says.
# `min_inside_probes_per_vector: 3` was DERIVED from the anchor lane and could
# be PAID by the generative lane; measured over 40 seeds, a fully blind
# lattice still passed 11 to 15 of boolean's 17 non-empty vectors.
#
# `excusable_by` names the block a lane may be listed in INSTEAD of carrying
# the floor -- a declaration a human writes, with a reason, policed in both
# directions like `empty_regions` and `unrulable`. A floor with no excuse
# mechanism would be met by lowering it; a floor with a silent one would be
# met by deleting it.
PER_PROBE_LANE_FLOORS = {
    "min_accepted_per_vector": {"excusable_by": None},
    "min_inside_probes_per_vector": {"excusable_by": "no_information_floor"},
    "min_checks_per_probe_lane": {"excusable_by": None},
}


def _per_lane_floor_errors(algo, cfg):
    """Every per-probe-lane floor block, checked TOTAL over the lanes.

    Both directions, and both matter. A lane with no floor is a sample nobody
    answers for; a floor for a lane that does not exist is a number that reads
    as a guarantee and evaluates to nothing -- the `swift:dropdown` shape, and
    the reason R1 is policed both ways.
    """
    lanes = set(pr.PROBE_LANES)
    for key, rule in sorted(PER_PROBE_LANE_FLOORS.items()):
        block = cfg.get(key)
        if not isinstance(block, dict):
            return (f"{algo}.json declares {key}={block!r}. A sampled law's "
                    f"floors are PER PROBE LANE ({', '.join(sorted(lanes))}): "
                    f"one number over the union is paid by whichever lane "
                    f"happens to have it, which is how a floor DERIVED from "
                    f"the anchor lane was met by the generative lane alone")
        excused = {}
        if rule["excusable_by"]:
            excused = cfg.get(rule["excusable_by"]) or {}
            if not isinstance(excused, dict):
                return (f"{algo}.json declares "
                        f"{rule['excusable_by']}={excused!r}; it must be a map "
                        f"from probe-lane name to the reason that lane carries "
                        f"no `{key}`")
            for lane, reason in sorted(excused.items()):
                if not isinstance(reason, str) or not reason.strip():
                    return (f"{algo}.json excuses probe lane '{lane}' from "
                            f"`{key}` with no reason. An exemption nobody had "
                            f"to justify is how a floor is emptied one lane "
                            f"at a time")
        for lane in sorted((set(block) | set(excused)) - lanes):
            return (f"{algo}.json names probe lane '{lane}' in `{key}` or "
                    f"`{rule['excusable_by']}`, which "
                    f"`spec.geometry.probes.PROBE_LANES` does not draw: a "
                    f"floor no lane evaluates is a number that reads as a "
                    f"guarantee")
        for lane in sorted(lanes):
            if lane in block and lane in excused:
                return (f"{algo}.json both floors probe lane '{lane}' in "
                        f"`{key}` and excuses it in `{rule['excusable_by']}`. "
                        f"Decide which: a lane cannot be watched and excused "
                        f"at once")
            if lane not in block and lane not in excused:
                excuse = (f", or say in `{rule['excusable_by']}` why it "
                          f"carries none" if rule["excusable_by"] else "")
                return (f"{algo}.json declares no `{key}` for probe lane "
                        f"'{lane}'{excuse}. Silence is how a lane goes "
                        f"unfloored, and an unfloored lane is a sample nobody "
                        f"has to answer for")
            if lane in block and (not isinstance(block[lane], int)
                                  or block[lane] < 1):
                return (f"{algo}.json declares {key}['{lane}']="
                        f"{block[lane]!r}; it must be an integer >= 1 (a floor "
                        f"of zero is not a floor)")
    # DERIVED, NOT RESTATED. `min_checks_per_probe_lane` is a fixture-wide
    # total and its only honest value is `per-vector floor x vectors`; pinning
    # a measured total would go flaky the moment the generative lane moved.
    # Checked here so the two numbers cannot drift apart in the file.
    for lane in sorted(lanes):
        want = (cfg["min_accepted_per_vector"][lane]
                * cfg["min_rulable_vectors"])
        got = cfg["min_checks_per_probe_lane"][lane]
        if got != want:
            return (f"{algo}.json declares min_checks_per_probe_lane['{lane}']"
                    f"={got}, but the only derivable value is "
                    f"min_accepted_per_vector['{lane}'] x min_rulable_vectors "
                    f"= {cfg['min_accepted_per_vector'][lane]} x "
                    f"{cfg['min_rulable_vectors']} = {want}. Derive it; an "
                    f"observed total goes flaky with the seed and a hand-typed "
                    f"one drifts")
    total = sum(cfg["min_checks_per_probe_lane"][l] for l in sorted(lanes))
    if cfg["min_checks_per_lane"] != total:
        return (f"{algo}.json declares min_checks_per_lane="
                f"{cfg['min_checks_per_lane']} while its per-probe-lane floors "
                f"sum to {total}. The scalar is the LANGUAGE lane's total and "
                f"must be the sum of the probe lanes' -- two numbers about the "
                f"same quantity that disagree mean one of them is not being "
                f"read")
    return None


def _checker_config(algo, fixture_doc):
    """The fixture's own declared floors and knobs, validated.

    Every number lives in ONE place -- the fixture -- and every reader takes
    it from there. A floor hardcoded in a runner is itself a defect: a
    mirrored number drifts, and a floor of zero is not a floor.
    """
    cfg = fixture_doc.get("checker")
    if not isinstance(cfg, dict):
        return None, (f"{algo}.json declares no `checker` block, so the lane "
                      f"has no floor to meet and cannot go non-vacuous "
                      f"visibly")
    required = ("name", "seam", "law", "samples_per_vector",
                "min_rulable_vectors", "min_checks_per_lane", "unrulable",
                "mutant")
    missing = [k for k in required if k not in cfg]
    if missing:
        return None, (f"{algo}.json `checker` block is missing "
                      f"{', '.join(missing)}")
    law_keys = CHECKER_LAW_REQUIRED_KEYS.get(cfg["name"], ())
    missing = [k for k in law_keys if k not in cfg]
    if missing:
        return None, (f"{algo}.json `checker` block names law "
                      f"`{cfg['name']}`, which reads {', '.join(missing)} and "
                      f"finds it undeclared: a law's own floors are still "
                      f"floors, and one the fixture omits is not defaulted, "
                      f"it is refused")
    # The EMPTY-REGION exemptions. A vector whose adjudicated region is empty
    # by construction cannot meet an inside-probe floor, and that is not a
    # defect -- but it must be a SENTENCE SOMEBODY WROTE, because no run can
    # measure emptiness (a sample witnesses a region's presence and never its
    # absence). Shape-checked here; contradicted declarations are refused by
    # the law itself and stale names by the runner, so it is policed in all
    # three directions.
    empties = cfg.get("empty_regions")
    if "empty_regions" in cfg:
        if not isinstance(empties, dict):
            return None, (f"{algo}.json declares empty_regions="
                          f"{empties!r}; it must be a map from vector name to "
                          f"the reason that region is empty BY CONSTRUCTION")
        for vname, reason in sorted(empties.items()):
            if not isinstance(reason, str) or not reason.strip():
                return None, (f"{algo}.json exempts '{vname}' from the "
                              f"inside-probe floor with no reason. An "
                              f"exemption nobody had to justify is how a "
                              f"floor is emptied one vector at a time")
    # THE TOLERANCE CARRIES ITS UNIT IN ITS NAME, and the name is checked
    # rather than fixed. `tolerance_bytes` was the required spelling while
    # there was one law and its unit was colour channels; a region law's
    # tolerance is DOCUMENT POINTS and calling it bytes would be a lie, while
    # calling it `tolerance` would be a number with no unit -- which is
    # exactly how a tolerance goes quietly wrong (THE ULP RULE:
    # "a tolerance DERIVED FROM A REAL QUANTISATION STEP"; a step in what?).
    # So: exactly one `tolerance_<unit>` key, and its `_..._why` sibling
    # stating the derivation, both required.
    tol_keys = sorted(k for k in cfg
                      if k.startswith("tolerance_") and not k.startswith("_"))
    if len(tol_keys) != 1:
        return None, (f"{algo}.json declares {len(tol_keys)} `tolerance_<unit>`"
                      f" key(s) ({', '.join(tol_keys) or 'none'}); it must "
                      f"declare exactly one, and the unit belongs in the name "
                      f"-- a bare `tolerance` is a number whose derivation "
                      f"cannot be checked")
    if f"_{tol_keys[0]}_why" not in cfg and "_tolerance_why" not in cfg:
        return None, (f"{algo}.json declares {tol_keys[0]} with no "
                      f"`_{tol_keys[0]}_why`: THE ULP RULE requires a "
                      f"tolerance derived from a real quantisation step, and "
                      f"a derivation nobody wrote down is a guess")
    # Every floor in the block, whatever a law calls it. Laws grow their own
    # (`min_accepted_per_vector`), and a floor the generic reader does not
    # know the name of is still a floor: zero is not one.
    #
    # A MAP-VALUED FLOOR MUST BE ONE THIS FILE KNOWS HOW TO READ. The loop
    # below used to skip every dict, which was fine while `min_witnesses` was
    # the only one -- and became a hole the moment a floor could be keyed by
    # lane, because an unrecognised map is skipped by the scalar rule AND by
    # every specific rule, and a floor nobody reads is a number that looks
    # like a guarantee. Refused by name rather than skipped by shape.
    known_maps = {"min_witnesses"} | set(PER_PROBE_LANE_FLOORS)
    for key in sorted(k for k in cfg if k.startswith("min_")):
        if isinstance(cfg[key], dict):
            if key not in known_maps:
                return None, (f"{algo}.json declares {key} as a map, and no "
                              f"rule in this file reads a map by that name: "
                              f"it is skipped by the scalar floor check and "
                              f"by every specific one, so it asserts nothing "
                              f"while reading as a floor")
            continue
        if not isinstance(cfg[key], int) or cfg[key] < 1:
            return None, (f"{algo}.json declares {key}={cfg[key]!r}; it must "
                          f"be an integer >= 1 (a floor of zero is not a "
                          f"floor)")
    # The PER-PROBE-LANE floors, for a law that samples in lanes. Total over
    # `pr.PROBE_LANES` in both directions -- see `_per_lane_floor_errors`.
    # AFTER the scalar loop above, deliberately: it derives one of its numbers
    # from `min_rulable_vectors`, and multiplying a value nothing has
    # type-checked yet turns a fixture typo into a traceback instead of a
    # sentence.
    if any(k in law_keys for k in PER_PROBE_LANE_FLOORS):
        why = _per_lane_floor_errors(algo, cfg)
        if why is not None:
            return None, why
    mut = cfg["mutant"]
    if not isinstance(mut, dict) or not mut.get("provenance"):
        return None, (f"{algo}.json's mutant carries no `provenance`: a mutant "
                      f"must name the wrong answer it transcribes, or the "
                      f"family takes the red-self-test rung instead")
    if not isinstance(mut.get("min_discriminating"), int) \
            or mut["min_discriminating"] < 1:
        return None, (f"{algo}.json declares min_discriminating="
                      f"{mut.get('min_discriminating')!r}; a mutant nothing "
                      f"rejects measures nothing")

    # The witness-SHAPE floors, total in both directions against the probes
    # this law publishes. One direction only is how a stale exemption lives.
    probes = CHECKER_WITNESS_PROBES.get(cfg["name"], {})
    declared = cfg.get("min_witnesses")
    if not isinstance(declared, dict):
        return None, (f"{algo}.json declares no `min_witnesses` block. Its "
                      f"law publishes {len(probes)} witness-shape probe(s), "
                      f"and a corpus can satisfy every COUNT while being "
                      f"collinear -- which is how all 18 of this family's "
                      f"boxes were degenerate for its whole life")
    for name in sorted(set(declared) - set(probes)):
        return None, (f"{algo}.json declares min_witnesses['{name}'], which "
                      f"no probe of `{cfg['name']}` measures: a floor nothing "
                      f"evaluates is a number that reads as a guarantee")
    for name in sorted(set(probes) - set(declared)):
        return None, (f"{algo}.json declares no floor for the witness probe "
                      f"'{name}': a probe nothing asserts on is a measurement "
                      f"taken and discarded")
    for name, floor in sorted(declared.items()):
        if not isinstance(floor, int) or floor < 1:
            return None, (f"{algo}.json declares min_witnesses['{name}']="
                          f"{floor!r}; a floor of zero is not a floor")
    return cfg, None


# ---------------------------------------------------------------
# The checker report's FRESHNESS evidence
# ---------------------------------------------------------------
#
# `--reconcile` reads a file. A file is not a run: a stale copy left on disk
# (or, worse, COMMITTED) reconciles exactly as cleanly as a fresh one, and the
# gate would then be asserting last week's counts about today's tree. So the
# report carries evidence of what it was produced FROM, and the reader
# recomputes it. Two things are digested:
#
#   fixtures -- the vectors the counts were performed over. Add, edit or delete
#               a vector and the counts in a stale report are about a corpus
#               that no longer exists.
#   spec     -- the analytic tier the law is COMPUTED with. This is the
#               interlock the `half_diag` audit asked for: change the
#               denotation and a report produced under the old one stops being
#               evidence, rather than silently vouching for the new one.
#
# Both are computed HERE, by the writer, and called from
# check_geometry_checkers.py by the reader, so the two sides cannot drift into
# digesting different things -- which is the whole failure mode of a
# hand-mirrored number.


def _sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def fixture_digest(algos):
    """sha256 of each named algorithm fixture, as it is on disk right now."""
    out = {}
    for algo in sorted(set(algos)):
        path = os.path.join(FIXTURES_DIR, f"{algo}.json")
        if os.path.exists(path):
            out[algo] = _sha256_file(path)
    return out


def spec_digest():
    """sha256 of every analytic-tier module, keyed on a POSIX relative path.

    POSIX keys, not `str(Path)`: a digest map keyed on the platform separator
    compares unequal between a Windows writer and a POSIX reader for reasons
    that have nothing to do with content. That is check_swift_copy_sites.py's
    2026-07-28 defect wearing a different hat.
    """
    root = os.path.join(REPO_ROOT, "spec")
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != "__pycache__"]
        for fname in filenames:
            if not fname.endswith(".py"):
                continue
            full = os.path.join(dirpath, fname)
            rel = os.path.relpath(full, REPO_ROOT).replace(os.sep, "/")
            out[rel] = _sha256_file(full)
    return out


def checker_report(langs, executed):
    """The executed-count account, plus the evidence that it is THIS run's."""
    return {
        "run_id": uuid.uuid4().hex,
        "generated_at": datetime.datetime.now(
            datetime.timezone.utc).isoformat(timespec="seconds"),
        "lanes_requested": list(langs),
        # THE QUARANTINE RULE's precondition (docs/CHECKERS.md section 5.3):
        # a generative red must be reproducible after the CI log expires, so
        # the seed travels with the account and not only through stdout.
        "generative_seed": f"0x{region_run_seed():016x}",
        "inputs_digest": {
            "fixtures": fixture_digest(executed.keys()),
            "spec": spec_digest(),
        },
        "algorithms": executed,
    }


def check_geometry_laws(langs, algos, verbose=False):
    """Rule every registered family's OUTPUT against its law, in every lane.

    Returns (passed, failed, errors, executed) where `executed` is the
    machine-readable account of what ACTUALLY RAN -- the number the runner
    computed, not the number the fixture asked for. R1/R2/R5 of the totality
    rules; see docs/CHECKERS.md.
    """
    passed = failed = errors = 0
    executed = {}

    # THE GENERATIVE LANE'S SEED, at the head of the run and before anything
    # can fail, because a seed printed only on failure is a seed you cannot
    # get when the failure is intermittent. Fresh nanoseconds each run;
    # `JAS_PROPERTY_SEED=0x...` replays this run's draws exactly. It is also
    # written into the checker report, so a CI log that has expired is not
    # the only copy.
    print(f"  checker: generative seed 0x{region_run_seed():016x} "
          f"(replay: JAS_PROPERTY_SEED=0x{region_run_seed():016x})")

    # R1, forward: the classification must be TOTAL over ALGORITHMS.
    for algo in algos:
        named = algo in GEOMETRY_CHECKERS
        excused = algo in GEOMETRY_CHECKER_GAPS
        if named and excused:
            print(f"  FAIL: checker/{algo} [registered AND excused: decide "
                  f"which, a family cannot be both]")
            failed += 1
        elif not named and not excused:
            print(f"  FAIL: checker/{algo} [unclassified: register a checker "
                  f"in GEOMETRY_CHECKERS, or say in GEOMETRY_CHECKER_GAPS why "
                  f"there is no law for it. Silence is how a family goes "
                  f"unwatched]")
            failed += 1

    for name in GEOMETRY_CHECKERS.values():
        if name not in CHECKER_FUNCS:
            print(f"  FAIL: checker/{name} [named in GEOMETRY_CHECKERS but "
                  f"no such predicate exists]")
            failed += 1

    for algo in algos:
        fixture_path = os.path.join(FIXTURES_DIR, f"{algo}.json")
        if not os.path.exists(fixture_path):
            continue  # the main loop already reports a missing fixture
        with open(fixture_path, encoding="utf-8") as fh:
            doc = json.load(fh)
        vectors = [v for v in (doc if isinstance(doc, list)
                               else doc.get("vectors", []))
                   if isinstance(v, dict) and not v.get("_skip")]

        # R1, reverse: a gap row whose fixture now carries a registered law's
        # shape is STALE and must be deleted, not left asserting a closed hole.
        if algo in GEOMETRY_CHECKER_GAPS:
            for law, probe in CHECKER_PROBES.items():
                hits = [v.get("name", "?") for v in vectors if probe(v)]
                if hits:
                    print(f"  FAIL: checker/{algo} [excused as having no law, "
                          f"but {len(hits)} of its vectors now carry the shape "
                          f"`{law}` rules (e.g. {hits[0]}): delete the stale "
                          f"GEOMETRY_CHECKER_GAPS entry and register it]")
                    failed += 1
            continue
        if algo not in GEOMETRY_CHECKERS:
            continue

        law_name = GEOMETRY_CHECKERS[algo]
        if law_name not in CHECKER_FUNCS:
            continue  # already reported
        rule, rulable, mutate = CHECKER_FUNCS[law_name]
        cfg, why = _checker_config(algo, doc if isinstance(doc, dict) else {})
        if cfg is None:
            print(f"  FAIL: checker/{algo} [{why}]")
            failed += 1
            continue
        if cfg["name"] != law_name:
            print(f"  FAIL: checker/{algo} [fixture names checker "
                  f"'{cfg['name']}', the registry names '{law_name}']")
            failed += 1
            continue

        # R2, part one: the UNRULABLE set is declared, and policed both ways.
        declared = dict(cfg["unrulable"])
        rulable_vecs = []
        for v in vectors:
            vname = v.get("name", "?")
            why_not = rulable(checker_input(v))
            if why_not and vname not in declared:
                print(f"  FAIL: checker/{algo}/{vname} [cannot be ruled "
                      f"({why_not}) and is not declared in the fixture's "
                      f"`checker.unrulable`: a vector the law silently skips "
                      f"is a vector nothing watches]")
                failed += 1
            elif why_not:
                declared.pop(vname)
            elif vname in declared:
                print(f"  FAIL: checker/{algo}/{vname} [declared unrulable, "
                      f"but the law CAN rule it now: delete the stale "
                      f"`checker.unrulable` entry]")
                failed += 1
                declared.pop(vname)
                rulable_vecs.append(v)
            else:
                rulable_vecs.append(v)
        for stale in sorted(declared):
            print(f"  FAIL: checker/{algo} [`checker.unrulable` names "
                  f"'{stale}', which is not a vector in this fixture: a stale "
                  f"holdout]")
            failed += 1

        # The EMPTY-REGION exemptions, third direction. The law refuses a
        # declaration its sample contradicts, and refuses an undeclared
        # vector that went quiet; neither can see a declaration that is never
        # REACHED. A name that is not a rulable vector of this fixture
        # exempts nothing while reading as an exemption -- the same shape as
        # a stale `unrulable` holdout, one field over.
        ruled_names = {v.get("name", "?") for v in rulable_vecs}
        for stale in sorted(set(cfg.get("empty_regions") or {}) - ruled_names):
            print(f"  FAIL: checker/{algo} [`checker.empty_regions` names "
                  f"'{stale}', which this law does not rule (deleted, "
                  f"renamed, or declared unrulable): an exemption nothing "
                  f"reaches is a sentence that reads as a guarantee]")
            failed += 1

        if len(rulable_vecs) < cfg["min_rulable_vectors"]:
            print(f"  FAIL: checker/{algo} [{len(rulable_vecs)} rulable "
                  f"vector(s), floor is {cfg['min_rulable_vectors']}: vectors "
                  f"were removed without lowering the floor the fixture "
                  f"states about itself]")
            failed += 1

        # R3's floor, read once; the TEETH themselves are measured inside the
        # lane loop below, because a mutant may be a function of the OUTPUT.
        floor = cfg["mutant"]["min_discriminating"]

        # THE WITNESS SET'S SHAPE. Measured over the rulable vectors, because
        # a vector the law cannot rule contributes no evidence about any
        # clause. Counting vectors and samples cannot see collinearity: this
        # is the assertion that can.
        witnesses = {}
        for wname, probe in sorted(
                CHECKER_WITNESS_PROBES.get(law_name, {}).items()):
            hits = [v.get("name", "?") for v in rulable_vecs
                    if probe(checker_input(v))]
            witnesses[wname] = len(hits)
            wfloor = cfg["min_witnesses"][wname]
            if len(hits) < wfloor:
                print(f"  FAIL: checker/{algo} [{len(hits)} witness(es) "
                      f"satisfy '{wname}', floor {wfloor}. The corpus has "
                      f"gone COLLINEAR: it can be any size and still leave "
                      f"this clause of the denotation exercised by nothing, "
                      f"which is the state all 18 of this family's bounding "
                      f"boxes were in until 2026-07-31]")
                failed += 1

        # The rulings themselves, once per lane. ONE predicate, BOTH ports.
        per_lane = {}
        for lang in langs:
            if (lang, algo) in SKIP_LANG_ALGO:
                continue
            try:
                out = json.loads(LANGUAGES[lang](algo, fixture_path))
            except Exception as e:
                print(f"  ERROR: checker/{algo} {lang}: {e}")
                errors += 1
                continue
            by_name = {r.get("name"): r.get("result") for r in out
                       if isinstance(r, dict)}
            ruled = samples = lane_discriminating = 0
            # The same total, broken out by the PROBE lane it came from. Two
            # different senses of "lane" meet here and the names keep them
            # apart: `lang` is a LANGUAGE lane (rust, swift) and this is a
            # PROBE lane (anchor, generative). Pooling the probe lanes is
            # exactly the defect the per-vector floors just stopped having,
            # and it would come straight back at the fixture-wide total.
            by_probe_lane = {}
            for v in rulable_vecs:
                vname = v.get("name", "?")
                if vname not in by_name:
                    print(f"  FAIL: checker/{algo}/{vname} [{lang} emitted no "
                          f"result for this vector]")
                    failed += 1
                    continue
                verdict = rule(checker_input(v), by_name[vname], cfg)
                ruled += 1
                if isinstance(verdict, str):
                    print(f"  FAIL: checker/{algo}/{vname} [{lang}: "
                          f"{cfg['law']} — {verdict}]")
                    if verbose:
                        print(f"    output: "
                              f"{json.dumps(by_name[vname], sort_keys=True)[:200]}")
                    failed += 1
                elif isinstance(verdict, dict):
                    # A SAMPLED law accounts per probe lane; an unsampled one
                    # returns a bare count and has no lanes to account for.
                    for probe_lane, n in verdict.items():
                        by_probe_lane[probe_lane] = \
                            by_probe_lane.get(probe_lane, 0) + n
                    samples += sum(verdict.values())
                    passed += 1
                else:
                    samples += verdict
                    passed += 1
                # R3: TEETH, re-measured on every run and in every lane. The
                # mutant is fed to the SAME predicate and must be rejected.
                #
                # WHY THE MUTANT SEES THE OUTPUT. It used to be a function of
                # the vector alone, which is enough while every registered
                # bug is a bug of ARITHMETIC. A region law's prior bugs are
                # bugs of ENCODING -- "the same region emitted as one
                # self-touching ring" -- and an encoding bug has no
                # expression that does not mention the encoding it corrupts.
                # Deriving it from the port's real output also removes a
                # failure mode the old shape had: a mutant built from the
                # input can drift away from the shape the port actually
                # emits and go quietly toothless.
                if isinstance(rule(checker_input(v), mutate(v, by_name[vname]),
                                   cfg), str):
                    lane_discriminating += 1
            per_lane[lang] = {"ruled": ruled, "samples": samples,
                              "discriminating": lane_discriminating}
            if by_probe_lane:
                per_lane[lang]["samples_by_probe_lane"] = dict(by_probe_lane)
            if lane_discriminating < floor:
                print(f"  FAIL: checker/{algo} [{lang}: the mutant "
                      f"'{cfg['mutant'].get('name')}' is rejected on only "
                      f"{lane_discriminating} vector(s), floor {floor}. "
                      f"Either the law lost its teeth or the mutant went "
                      f"stale -- a stale mutant measures nothing while "
                      f"looking like it measures something]")
                failed += 1

            # R2, part two: the runner asserts the count it ACTUALLY RAN, not
            # the count the fixture declared. This is the assertion that
            # catches a seeding pass that seeded zero.
            if ruled != len(rulable_vecs):
                print(f"  FAIL: checker/{algo} [{lang} ruled {ruled} of "
                      f"{len(rulable_vecs)} rulable vectors]")
                failed += 1
            if samples < cfg["min_checks_per_lane"]:
                print(f"  FAIL: checker/{algo} [{lang} performed {samples} "
                      f"sample check(s), floor {cfg['min_checks_per_lane']}: "
                      f"the lane has gone vacuous, which is the one failure "
                      f"mode that looks like success]")
                failed += 1
            # THE SAME TOTAL, PER PROBE LANE, and it is not redundant with the
            # line above: `min_checks_per_lane` is the SUM, so an anchor lane
            # that halved is paid for by a generative lane that doubled. The
            # per-vector floors make that hard; this makes it impossible, and
            # it is the fixture-wide half of the same repair. Iterated over
            # the DECLARED lanes, never over the lanes observed -- a lane that
            # contributed nothing is absent from `by_probe_lane`, not present
            # with a zero.
            for probe_lane, probe_floor in sorted(
                    (cfg.get("min_checks_per_probe_lane") or {}).items()):
                got = by_probe_lane.get(probe_lane, 0)
                if got < probe_floor:
                    print(f"  FAIL: checker/{algo} [{lang} performed {got} "
                          f"sample check(s) in the '{probe_lane}' probe lane, "
                          f"floor {probe_floor} (all lanes: "
                          f"{ {k: by_probe_lane.get(k, 0) for k in sorted(cfg['min_checks_per_probe_lane'])} }). "
                          f"One lane went thin while the total stayed "
                          f"healthy, which is what a union floor cannot see]")
                    failed += 1

        # R5: the lanes must AGREE about how much was checked. A lane that
        # quietly stopped being adjudicated is invisible in a total.
        counts = {l: d["ruled"] for l, d in per_lane.items()}
        if len(set(counts.values())) > 1:
            print(f"  FAIL: checker/{algo} [lanes disagree about how many "
                  f"vectors were ruled: {counts}]")
            failed += 1
        # The floors travel WITH the counts. R5 claims the reconciler asserts
        # "each meets the declared floor", and that was true of
        # min_discriminating only: min_checks_per_lane and
        # min_rulable_vectors were checked here and nowhere else, so a
        # reconcile run could not tell a full lane from a two-thirds-empty
        # one. Copied from the fixture at the moment of use, never
        # hand-mirrored -- the fixture stays the single place each number is
        # DECLARED.
        #
        # `discriminating` is the WEAKEST lane's count, not the sum and not
        # the best: the reconciler's rule is "the mutant is rejected on at
        # least `floor` vectors", and a total over two lanes would let one
        # toothless lane hide behind the other's teeth.
        executed[algo] = {
            "law": law_name, "seam": cfg["seam"],
            "rulable_vectors": len(rulable_vecs),
            "min_rulable_vectors": cfg["min_rulable_vectors"],
            "min_checks_per_lane": cfg["min_checks_per_lane"],
            # Carried so `--reconcile` can assert the SPLIT and not only the
            # sum. Absent for a law that does not sample in lanes, which is
            # why the reconciler treats absence-with-no-floor as legal and
            # absence-with-a-floor as a red.
            "min_checks_per_probe_lane": dict(
                cfg.get("min_checks_per_probe_lane") or {}) or None,
            "witnesses": witnesses,
            "min_witnesses": dict(cfg["min_witnesses"]),
            "discriminating": min((d["discriminating"]
                                   for d in per_lane.values()), default=0),
            "min_discriminating": floor,
            "lanes": per_lane,
        }

    # R4: per-FAMILY vacuity, below lane_report's run-level resolution. A
    # registered family that ruled nothing is a FAILURE, not a silent
    # contributor of zero to a healthy-looking total.
    for algo in algos:
        if algo not in GEOMETRY_CHECKERS:
            continue
        acct = executed.get(algo)
        if not acct or not acct["lanes"] or not any(
                d["ruled"] for d in acct["lanes"].values()):
            print(f"  FAIL: checker/{algo} [registered, but this run ruled "
                  f"NOTHING for it]")
            failed += 1
    return (passed, failed, errors, executed)


# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------

def main():
    if "--self-test" in sys.argv:
        # The summary's own gate: see scripts/lane_report.py. Kept on this
        # script too so the runner and its reporting rules are checkable
        # together (`... --self-test && ... --lang rust,swift`).
        sys.exit(lane_report.self_test())

    parser = argparse.ArgumentParser(description="Cross-language algorithm tests")
    parser.add_argument("--lang",
                        help="Comma-separated languages (default: the active "
                             "ports; ocaml/python are pinned to the "
                             "five-port-parity tag and run in their own "
                             "canary lane — see POLICY.md)",
                        default="rust,swift")
    parser.add_argument("--algo", help="Single algorithm to test (default: all)")
    parser.add_argument("--verbose", action="store_true",
                        help="Print raw output on failure")
    parser.add_argument("--require-comparisons", action="store_true",
                        help="Exit non-zero (3) unless every requested "
                             "comparison lane actually compared. CI passes "
                             "this so the blocking lane cannot silently "
                             "degrade into an oracle-only run; a deliberate "
                             "single-lane oracle run omits it.")
    parser.add_argument("--self-test", action="store_true",
                        help="Check the summary's own reporting rules "
                             "(scripts/lane_report.py) and exit")
    parser.add_argument("--checker-report", metavar="PATH",
                        help="Write the geometry checkers' EXECUTED-COUNT "
                             "account to PATH, for "
                             "scripts/check_geometry_checkers.py --reconcile. "
                             "The counts are what the runner actually ran, "
                             "not what the fixtures asked for.")
    args = parser.parse_args()

    langs = [l.strip() for l in args.lang.split(",")]
    for l in langs:
        if l not in LANGUAGES:
            print(f"Unknown language: {l}")
            sys.exit(1)

    algos = [args.algo] if args.algo else list(ALGORITHMS.keys())
    # Lane arithmetic lives in lane_report so every runner counts the same way
    # (dedup included: `--lang rust,rust` is an oracle run, not two lanes).
    lanes = lane_report.Lanes.resolve(langs)
    ref_lang = lanes.reference
    compare_langs = list(lanes.comparison)

    # The two counts are kept apart from here to the summary. Folding them was
    # the defect: a single-lane run reported its ORACLE passes under a heading
    # that reads as cross-language agreement.
    oracle_passed = 0
    oracle_failed = 0
    compare_passed = 0
    compare_failed = 0
    harness_failed = 0
    per_lane = {l: 0 for l in compare_langs}
    errors = 0

    # Preflight (see check_measure_injection): run before any family, so a
    # drifted measurer is reported as a HARNESS fault by name rather than
    # surfacing later as a mysterious text_layout mismatch.
    for problem in check_measure_injection():
        print(f"  FAIL: harness/measure-unit {problem}")
        harness_failed += 1

    # Preflight (see check_json_string_escapers): a second inline escaper is a
    # PORT fault that no family can see, because every fixture string is
    # printable ASCII. Reported here by name for the same reason.
    for problem in check_json_string_escapers():
        print(f"  FAIL: port/json-string-escaper {problem}")
        harness_failed += 1

    # The RELATIONAL S-4 pass (see check_leading_close_invariance): asserts a
    # leading ClosePath changes no answer, for every registered algorithm whose
    # fixture carries path data — including algorithms added after this was
    # written. Runs before the value families so a class violation is reported
    # as one rather than as a scatter of unrelated vector mismatches.
    #
    # Merge note: these counts are neither oracle checks nor port-vs-port
    # comparisons — they are RELATIONAL. If the summary ever splits those two
    # apart, this is a third bucket, not a member of either.
    s4_passed, s4_failed, s4_errors = check_leading_close_invariance(
        langs, algos, args.verbose)
    errors += s4_errors

    # The CHECKER pass (see check_geometry_laws): rules each port's output
    # against a law written from the spec, in every lane, with the law's own
    # teeth re-measured against a historical wrong answer on every run. Also
    # relational -- it reproduces no golden and compares no two lanes.
    chk_passed, chk_failed, chk_errors, chk_executed = check_geometry_laws(
        langs, algos, args.verbose)
    errors += chk_errors
    s4_passed += chk_passed
    s4_failed += chk_failed
    if args.checker_report:
        with open(args.checker_report, "w", encoding="utf-8",
                  newline="") as fh:
            json.dump(checker_report(langs, chk_executed),
                      fh, indent=2, sort_keys=True)
            fh.write("\n")

    for algo in algos:
        strategy, tol = ALGORITHMS[algo]
        fixture_path = os.path.join(FIXTURES_DIR, f"{algo}.json")

        if not os.path.exists(fixture_path):
            # A missing fixture is a hard error, not a skip: every algorithm in
            # ALGORITHMS must have its fixture on disk, or the gate would go
            # silently vacuous for that algorithm (S3 rider). Known per-language
            # exclusions belong in SKIP_LANG_ALGO, never here.
            print(f"  ERROR: {algo}: fixture not found: {fixture_path}",
                  file=sys.stderr)
            errors += 1
            continue

        # Run reference language
        try:
            ref_output = json.loads(LANGUAGES[ref_lang](algo, fixture_path))
        except Exception as e:
            print(f"  ERROR: {algo} {ref_lang}: {e}")
            errors += 1
            continue

        # Oracle check: the app-vs-app comparison below only proves the four
        # apps AGREE, not that they are CORRECT — a shared bug (features
        # propagate by copying logic) produces the same wrong value in all
        # four and stays green. Where a fixture pins a golden (`expected` per
        # case, or `translations` per align vector), also assert the reference
        # app reproduces it. Restricted to the simple tolerance/exact
        # strategies; the shape strategy carries a differently shaped golden
        # compared by its own logic, and the strategies listed in
        # ORACLE_PARTIAL_STRATEGIES (today: property_planar and
        # exact_boolean) get the partial-golden pass immediately below.
        has_name_wrapper = (
            len(ref_output) == 0
            or (isinstance(ref_output[0], dict) and "name" in ref_output[0])
        )
        if strategy in ("tolerance", "exact"):
            with open(fixture_path, encoding="utf-8") as fh:
                fixture_doc = json.load(fh)
            fixture_cases = (fixture_doc if isinstance(fixture_doc, list)
                             else fixture_doc.get("vectors", []))
            for idx, out_vec in enumerate(ref_output):
                if idx >= len(fixture_cases):
                    break
                case = fixture_cases[idx]
                golden = case.get("expected", case.get("translations"))
                if golden is None:
                    continue  # no golden pinned for this vector
                # Extract the comparable body: {name,result} wrapper for most
                # algos, {translations:[...]} for align (unwrap to the list).
                if has_name_wrapper:
                    body = out_vec["result"]
                elif isinstance(out_vec, dict) and "translations" in out_vec:
                    body = out_vec["translations"]
                else:
                    body = out_vec
                name = case.get("name", f"#{idx}")
                oracle_ok = (values_close(golden, body, tol) if strategy == "tolerance"
                             else golden == body)
                if oracle_ok:
                    oracle_passed += 1
                else:
                    print(f"  FAIL: {algo}/{name} [oracle: {ref_lang} vs pinned expected]")
                    if args.verbose:
                        print(f"    expected: {json.dumps(golden, sort_keys=True)[:200]}")
                        print(f"    {ref_lang}:   {json.dumps(body, sort_keys=True)[:200]}")
                    oracle_failed += 1

        # Partial-golden oracle for the strategies in
        # ORACLE_PARTIAL_STRATEGIES. Their `expected` blocks pin a SUBSET of
        # the emitted result keys (area / ring_count / all_rings_simple /
        # face_count / face_areas_sorted / sample_points), so compare key by
        # key rather than whole-object. This matters most for the degenerate-
        # geometry vectors: T-junctions, collinear overlap, retrograde loops
        # and inter-ring cancellation are SHARED limitations, so an
        # app-vs-app comparison is blind to them — wrong-vs-wrong compares
        # green. Only a pinned, hand-derived expectation catches that.
        if strategy in ORACLE_PARTIAL_STRATEGIES:
            with open(fixture_path, encoding="utf-8") as fh:
                fixture_cases = json.load(fh).get("vectors", [])
            gold_tol = tol if tol is not None else 1e-6
            for idx, out_vec in enumerate(ref_output):
                if idx >= len(fixture_cases):
                    break
                case = fixture_cases[idx]
                golden = case.get("expected")
                if not isinstance(golden, dict):
                    continue
                body = out_vec["result"] if has_name_wrapper else out_vec
                name = case.get("name", f"#{idx}")
                gap_keys = case.get(KNOWN_GAP_KEYS_KEY) or []
                if case.get(KNOWN_GAP_KEY) and not gap_keys:
                    print(f"  FAIL: {algo}/{name} [has {KNOWN_GAP_KEY} but no "
                          f"{KNOWN_GAP_KEYS_KEY}: say which keys it holds out]")
                    oracle_failed += 1
                for key, want in golden.items():
                    if key in gap_keys:
                        # A documented derived-correct golden the ports do
                        # not reproduce yet: announced, never silent, and
                        # held out alone so its siblings stay gated. If the
                        # port now MATCHES, the gap is closed and the
                        # holdout must go — that is a failure, not a pass.
                        if key in body and values_close(want, body[key], gold_tol):
                            print(f"  FAIL: {algo}/{name}.{key} [held out as a "
                                  f"known gap but {ref_lang} now reproduces it: "
                                  f"delete the {KNOWN_GAP_KEY} holdout]")
                            oracle_failed += 1
                        else:
                            print(f"  KNOWN-GAP: {algo}/{name}.{key} "
                                  f"[oracle held out, see {KNOWN_GAP_KEY} in "
                                  f"{algo}.json]")
                        continue
                    if key not in body:
                        print(f"  FAIL: {algo}/{name} [oracle: {ref_lang} "
                              f"emits no '{key}']")
                        oracle_failed += 1
                        continue
                    if values_close(want, body[key], gold_tol):
                        oracle_passed += 1
                    else:
                        print(f"  FAIL: {algo}/{name}.{key} "
                              f"[oracle: {ref_lang} vs pinned expected]")
                        if args.verbose:
                            print(f"    expected: {json.dumps(want)[:200]}")
                            print(f"    {ref_lang}:   {json.dumps(body[key])[:200]}")
                        oracle_failed += 1
                for key in gap_keys:
                    if key not in golden:
                        print(f"  FAIL: {algo}/{name} [{KNOWN_GAP_KEYS_KEY} "
                              f"names '{key}', which is not in expected: "
                              f"a stale holdout]")
                        oracle_failed += 1

        # Run each comparison language
        for lang in compare_langs:
            if (lang, algo) in SKIP_LANG_ALGO:
                print(f"  SKIP: {algo} {lang} (known issue)")
                continue
            try:
                lang_output = json.loads(LANGUAGES[lang](algo, fixture_path))
            except Exception as e:
                print(f"  ERROR: {algo} {lang}: {e}")
                errors += 1
                continue

            # Determine comparison wrapper: some algos (align) emit bare
            # per-vector dicts without a {name, result} wrapper. For
            # those we pair by position and read names from the fixture.
            has_name_wrapper = (
                len(ref_output) == 0
                or (isinstance(ref_output[0], dict) and "name" in ref_output[0])
            )
            fixture_names = []
            if not has_name_wrapper:
                with open(fixture_path, encoding="utf-8") as fh:
                    fixture_names = [v.get("name", f"#{i}")
                                     for i, v in enumerate(json.load(fh)["vectors"])]

            # Compare each vector
            for idx, (ref_vec, lang_vec) in enumerate(zip(ref_output, lang_output)):
                if has_name_wrapper:
                    vec_name = ref_vec["name"]
                    if ref_vec["name"] != lang_vec["name"]:
                        print(f"  FAIL: {algo}/{vec_name} name mismatch "
                              f"({ref_lang}={ref_vec['name']}, {lang}={lang_vec['name']})")
                        compare_failed += 1
                        per_lane[lang] = per_lane.get(lang, 0) + 1
                        continue
                    ok = compare(strategy, ref_vec, lang_vec, tol)
                    ref_body = ref_vec["result"]
                    lang_body = lang_vec["result"]
                else:
                    vec_name = fixture_names[idx] if idx < len(fixture_names) else f"#{idx}"
                    ok = values_close(ref_vec, lang_vec, tol) if strategy == "tolerance" \
                        else (ref_vec == lang_vec)
                    ref_body = ref_vec
                    lang_body = lang_vec

                # Counted per lane whatever the outcome: "how many comparisons
                # did lane X actually perform" is the number that exposes a
                # lane which errored out of every family.
                per_lane[lang] = per_lane.get(lang, 0) + 1
                if ok:
                    compare_passed += 1
                else:
                    print(f"  FAIL: {algo}/{vec_name} [{ref_lang} vs {lang}]")
                    if args.verbose:
                        print(f"    {ref_lang}: {json.dumps(ref_body, sort_keys=True)[:200]}")
                        print(f"    {lang}:   {json.dumps(lang_body, sort_keys=True)[:200]}")
                    compare_failed += 1

    report = lane_report.LaneReport(
        title="Cross-language algorithms",
        scope=f"{len(algos)} algorithm" + ("s" if len(algos) != 1 else ""),
        lanes=lanes,
        oracle_passed=oracle_passed, oracle_failed=oracle_failed,
        comparison_passed=compare_passed, comparison_failed=compare_failed,
        harness_failed=harness_failed, errors=errors,
        relational_passed=s4_passed, relational_failed=s4_failed,
        oracle_what="vs the pinned goldens",
        comparison_what="lane-vs-lane agreement",
        relational_what="S-4 leading-ClosePath invariance + geometry "
                        "checkers, same lane",
        per_lane_comparisons=per_lane,
        require_comparisons=args.require_comparisons,
        unexercised=lane_report.unexercised_active_ports(lanes),
    )
    report.print_report()
    sys.exit(report.exit_code())


if __name__ == "__main__":
    main()
