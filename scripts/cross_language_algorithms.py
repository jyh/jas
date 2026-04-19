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
    "hit_test":          ("exact", None),
    "boolean":           ("property_boolean", 0.01),
    "boolean_normalize": ("property_normalize", 0.01),
    "fit_curve":         ("tolerance", 0.5),
    "shape_recognize":   ("shape", 0.5),
    "planar":            ("property_planar", 0.01),
    "text_layout":       ("tolerance", 1e-4),
    "text_layout_paragraph": ("tolerance", 1e-4),
    "path_text_layout":  ("tolerance", 1e-4),
}

# Known per-language algorithm exclusions (pre-existing bugs to fix separately)
SKIP_LANG_ALGO = {
    ("swift", "boolean_normalize"),  # Range crash in Swift normalize()
    # Phase 11: Swift / OCaml / Python runners are added in their own
    # commits; until then those languages skip text_layout_paragraph.
    ("swift", "text_layout_paragraph"),
    ("ocaml", "text_layout_paragraph"),
    ("python", "text_layout_paragraph"),
}


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
# Main
# ---------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Cross-language algorithm tests")
    parser.add_argument("--lang", help="Comma-separated languages (default: all)",
                        default=",".join(LANGUAGES.keys()))
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

    for algo in algos:
        strategy, tol = ALGORITHMS[algo]
        fixture_path = os.path.join(FIXTURES_DIR, f"{algo}.json")

        if not os.path.exists(fixture_path):
            print(f"  SKIP: {algo} (fixture not found)")
            continue

        # Run reference language
        try:
            ref_output = json.loads(LANGUAGES[ref_lang](algo, fixture_path))
        except Exception as e:
            print(f"  ERROR: {algo} {ref_lang}: {e}")
            errors += 1
            continue

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

            # Compare each vector
            for ref_vec, lang_vec in zip(ref_output, lang_output):
                vec_name = ref_vec["name"]
                if ref_vec["name"] != lang_vec["name"]:
                    print(f"  FAIL: {algo}/{vec_name} name mismatch "
                          f"({ref_lang}={ref_vec['name']}, {lang}={lang_vec['name']})")
                    failed += 1
                    continue

                if compare(strategy, ref_vec, lang_vec, tol):
                    passed += 1
                else:
                    print(f"  FAIL: {algo}/{vec_name} [{ref_lang} vs {lang}]")
                    if args.verbose:
                        print(f"    {ref_lang}: {json.dumps(ref_vec['result'], sort_keys=True)[:200]}")
                        print(f"    {lang}:   {json.dumps(lang_vec['result'], sort_keys=True)[:200]}")
                    failed += 1

    total = passed + failed + errors
    print(f"\nCross-language algorithms: {passed} passed, {failed} failed, "
          f"{errors} errors ({len(algos)} algorithms × {len(compare_langs)} comparisons)")

    sys.exit(1 if (failed or errors) else 0)


if __name__ == "__main__":
    main()
