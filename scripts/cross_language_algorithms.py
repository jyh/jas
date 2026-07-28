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
import json
import math
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lane_report  # noqa: E402  (sibling module in scripts/)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES_DIR = os.path.join(REPO_ROOT, "test_fixtures", "algorithms")

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
            with open(path) as fh:
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
    "text_layout": "a string plus a width",
    "text_layout_paragraph": "a string plus paragraph attributes",
    "align": "rect bounds only",
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
    with open(fixture_path) as fh:
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
            with open(probe_path, "w") as fh:
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
            with open(fixture_path) as fh:
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
            with open(fixture_path) as fh:
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
                with open(fixture_path) as fh:
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
        relational_what="S-4 leading-ClosePath invariance, same lane",
        per_lane_comparisons=per_lane,
        require_comparisons=args.require_comparisons,
        unexercised=lane_report.unexercised_active_ports(lanes),
    )
    report.print_report()
    sys.exit(report.exit_code())


if __name__ == "__main__":
    main()
