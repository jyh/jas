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
import json
import math
import os
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES_DIR = os.path.join(REPO_ROOT, "test_fixtures", "algorithms")

# Algorithm → (comparison strategy, tolerance)
ALGORITHMS = {
    "measure":           ("tolerance", 1e-4),
    "element_bounds":    ("tolerance", 1e-4),
    "flatten":           ("tolerance", 1e-9),
    "arrow_trim":        ("tolerance", 1e-4),
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
# Main
# ---------------------------------------------------------------

def main():
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
    args = parser.parse_args()

    langs = [l.strip() for l in args.lang.split(",")]
    for l in langs:
        if l not in LANGUAGES:
            print(f"Unknown language: {l}")
            sys.exit(1)

    algos = [args.algo] if args.algo else list(ALGORITHMS.keys())
    ref_lang = langs[0]  # First language is the reference
    compare_langs = [l for l in langs if l != ref_lang]

    passed = 0
    failed = 0
    errors = 0

    # Preflight (see check_measure_injection): run before any family, so a
    # drifted measurer is reported as a HARNESS fault by name rather than
    # surfacing later as a mysterious text_layout mismatch.
    for problem in check_measure_injection():
        print(f"  FAIL: harness/measure-unit {problem}")
        failed += 1

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
                    passed += 1
                else:
                    print(f"  FAIL: {algo}/{name} [oracle: {ref_lang} vs pinned expected]")
                    if args.verbose:
                        print(f"    expected: {json.dumps(golden, sort_keys=True)[:200]}")
                        print(f"    {ref_lang}:   {json.dumps(body, sort_keys=True)[:200]}")
                    failed += 1

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
                    failed += 1
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
                            failed += 1
                        else:
                            print(f"  KNOWN-GAP: {algo}/{name}.{key} "
                                  f"[oracle held out, see {KNOWN_GAP_KEY} in "
                                  f"{algo}.json]")
                        continue
                    if key not in body:
                        print(f"  FAIL: {algo}/{name} [oracle: {ref_lang} "
                              f"emits no '{key}']")
                        failed += 1
                        continue
                    if values_close(want, body[key], gold_tol):
                        passed += 1
                    else:
                        print(f"  FAIL: {algo}/{name}.{key} "
                              f"[oracle: {ref_lang} vs pinned expected]")
                        if args.verbose:
                            print(f"    expected: {json.dumps(want)[:200]}")
                            print(f"    {ref_lang}:   {json.dumps(body[key])[:200]}")
                        failed += 1
                for key in gap_keys:
                    if key not in golden:
                        print(f"  FAIL: {algo}/{name} [{KNOWN_GAP_KEYS_KEY} "
                              f"names '{key}', which is not in expected: "
                              f"a stale holdout]")
                        failed += 1

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
                        failed += 1
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

                if ok:
                    passed += 1
                else:
                    print(f"  FAIL: {algo}/{vec_name} [{ref_lang} vs {lang}]")
                    if args.verbose:
                        print(f"    {ref_lang}: {json.dumps(ref_body, sort_keys=True)[:200]}")
                        print(f"    {lang}:   {json.dumps(lang_body, sort_keys=True)[:200]}")
                    failed += 1

    total = passed + failed + errors
    print(f"\nCross-language algorithms: {passed} passed, {failed} failed, "
          f"{errors} errors ({len(algos)} algorithms × {len(compare_langs)} comparisons)")

    sys.exit(1 if (failed or errors) else 0)


if __name__ == "__main__":
    main()
