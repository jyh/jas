#!/usr/bin/env python3
"""Cross-language workspace layout equivalence test.

Tests that the selected language implementations produce identical canonical
JSON for workspace operations.

Tests:
1. Default layout: every language matches the pinned golden.
2. Default layout with panes (1200x800): every language matches the golden.
3. Parse commutativity: parse fixture in A, re-serialize → same JSON.

Tests 1-2 are anchored to the pinned fixtures in test_fixtures/expected/ —
not merely mutual agreement — so a restricted language set (or a coordinated
drift in all selected languages) still fails against the shared golden.

Usage:
    python scripts/cross_language_workspace.py [--lang rust,swift]

Default is the active ports (rust, swift); ocaml/python are pinned to the
five-port-parity tag and run in their own canary lane (POLICY.md).

HOW THE TWO COUNTS DIFFER HERE (scripts/lane_report.py). Every lane is compared
to the golden, never directly to another lane, so each (test, lane) cell is an
ORACLE check. The cross-language claim is transitive: because the anchor is
EXACT string equality, k lanes matching the same golden means all k*(k-1)/2 lane
pairs agree — which is 0 pairs when k is 1. The old summary ("4 passed, 0
failed") named no lane at all, so a single-lane run and the real two-lane gate
printed the identical line.
"""

import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lane_report  # noqa: E402  (sibling module in scripts/)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES_DIR = os.path.join(REPO_ROOT, "test_fixtures")

ALL_LANGUAGES = ["rust", "swift", "ocaml", "python"]

# Filled from --lang in main(); module-level so helpers see it.
LANGUAGES: list = []


# Every runner passes `encoding="utf-8"` explicitly -- `text=True` alone
# decodes with the locale codec, which is cp1252 on Windows and mangles any
# non-ASCII a lane emits. See the runner note in
# `cross_language_algorithms.py` for the failure this actually caused.
def run_rust(args: list[str]) -> str:
    result = subprocess.run(
        ["cargo", "run", "--bin", "workspace_roundtrip",
         "-q", "--"] + args,
        cwd=os.path.join(REPO_ROOT, "jas_dioxus"),
        capture_output=True, text=True, encoding="utf-8", timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Rust failed: {result.stderr}")
    return result.stdout


def run_swift(args: list[str]) -> str:
    result = subprocess.run(
        # Debug (not -c release) to match the algorithm/commutativity drivers
        # and the CI `swift build` pre-build — a roundtrip's output is
        # opt-level-independent, and release-only left the binary to compile
        # on-demand inside the 60s timeout (finding #25).
        ["swift", "run", "WorkspaceRoundtrip"] + args,
        cwd=os.path.join(REPO_ROOT, "JasSwift"),
        capture_output=True, text=True, encoding="utf-8", timeout=60,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Swift failed: {result.stderr}")
    return result.stdout


def run_ocaml(args: list[str]) -> str:
    result = subprocess.run(
        ["dune", "exec", "bin/workspace_roundtrip.exe", "--"] + args,
        cwd=os.path.join(REPO_ROOT, "jas_ocaml"),
        capture_output=True, text=True, encoding="utf-8", timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"OCaml failed: {result.stderr}")
    return result.stdout


def run_python(args: list[str]) -> str:
    result = subprocess.run(
        [sys.executable, "tools/workspace_roundtrip.py"] + args,
        cwd=os.path.join(REPO_ROOT, "jas"),
        capture_output=True, text=True, encoding="utf-8", timeout=30,
        # The CHILD must emit UTF-8, not just the parent decode it. A
        # Python child writing to a pipe encodes with the LOCALE codec
        # (cp1252 on Windows); the parent's utf-8 decode then dies inside
        # subprocess's reader THREAD and hands back stdout=None with
        # returncode 0. Canonical explanation in
        # scripts/check_corpus_manifest.py, self-test item 11.
        env={**os.environ, "PYTHONIOENCODING": "utf-8"},
    )
    if result.stdout is None:
        raise RuntimeError(
            "stdout was not captured: the reader thread died decoding the "
            f"child. rc={result.returncode} stderr={(result.stderr or '')[:200]!r}")
    if result.returncode != 0:
        raise RuntimeError(f"Python failed: {result.stderr}")
    return result.stdout


RUNNERS = {
    "rust": run_rust,
    "swift": run_swift,
    "ocaml": run_ocaml,
    "python": run_python,
}


def run_all(args: list[str]) -> dict[str, str]:
    results = {}
    for lang in LANGUAGES:
        results[lang] = RUNNERS[lang](args)
    return results


def assert_all_match(results: dict[str, str], test_name: str,
                     golden: str | None = None):
    """Every language must agree; when a golden is given, anchor to it.

    Returns (ok, matched_langs) — the caller needs the per-lane outcome to
    count ORACLE cells and the lane pairs they establish transitively.
    """
    ref_lang = "golden" if golden is not None else LANGUAGES[0]
    ref = golden if golden is not None else results[LANGUAGES[0]]
    ok = True
    matched = []
    for lang in LANGUAGES:
        if lang == ref_lang:
            continue
        if results[lang].strip() != ref.strip():
            print(f"  FAIL: {test_name} — {lang} differs from {ref_lang}")
            print(f"    {ref_lang}: {ref[:200]}...")
            print(f"    {lang}: {results[lang][:200]}...")
            ok = False
        else:
            matched.append(lang)
    return ok, matched


def _golden(fixture_name: str) -> str:
    with open(os.path.join(FIXTURES_DIR, "expected", f"{fixture_name}.json"), encoding="utf-8") as f:
        return f.read()


def main():
    global LANGUAGES
    if "--self-test" in sys.argv:
        sys.exit(lane_report.self_test())
    parser = argparse.ArgumentParser(
        description="Cross-language workspace layout equivalence test")
    parser.add_argument("--lang",
                        help="Comma-separated languages (default: the active "
                             "ports; ocaml/python are pinned to the "
                             "five-port-parity tag and run in their own "
                             "canary lane — see POLICY.md)",
                        default="rust,swift")
    parser.add_argument("--require-comparisons", action="store_true",
                        help="Exit non-zero (3) unless the run established at "
                             "least one lane pair (CI passes this; a "
                             "deliberate single-lane oracle run omits it)")
    parser.add_argument("--self-test", action="store_true",
                        help="Check the summary's own reporting rules "
                             "(scripts/lane_report.py) and exit")
    args = parser.parse_args()
    selected = [l.strip() for l in args.lang.split(",") if l.strip()]
    unknown = [l for l in selected if l not in ALL_LANGUAGES]
    if unknown:
        print(f"Unknown language(s): {', '.join(unknown)} "
              f"(choose from {', '.join(ALL_LANGUAGES)})", file=sys.stderr)
        sys.exit(2)
    lanes = lane_report.Lanes.resolve(selected)
    LANGUAGES = list(lanes.requested)

    oracle_passed = 0
    oracle_failed = 0
    comparison_passed = 0
    per_lane = {l: 0 for l in lanes.comparison}

    def account(matched):
        """One ORACLE check per lane; the pairs those matches establish."""
        nonlocal oracle_passed, oracle_failed, comparison_passed
        oracle_passed += len(matched)
        oracle_failed += len(LANGUAGES) - len(matched)
        comparison_passed += lane_report.pairs_via_golden(len(matched))
        for lane in matched:
            if lane in per_lane:
                # A lane pairs with every OTHER lane that matched.
                per_lane[lane] += len(matched) - 1

    # Test 1: default layout, anchored to the pinned golden
    print("Test 1: default layout")
    results = run_all(["default"])
    ok, matched = assert_all_match(results, "default",
                                   golden=_golden("workspace_default"))
    if ok:
        print(f"  PASS: {', '.join(LANGUAGES)} match the golden")
    account(matched)

    # Test 2: default layout with panes, anchored to the pinned golden
    print("Test 2: default layout with panes (1200x800)")
    results = run_all(["default_with_panes", "1200", "800"])
    ok, matched = assert_all_match(results, "default_with_panes",
                                   golden=_golden("workspace_default_with_panes"))
    if ok:
        print(f"  PASS: {', '.join(LANGUAGES)} match the golden")
    account(matched)

    # Test 3: parse commutativity for each workspace fixture
    for fixture_name in ["workspace_default", "workspace_default_with_panes"]:
        print(f"Test 3: parse commutativity ({fixture_name})")
        fixture_path = os.path.join(FIXTURES_DIR, "expected", f"{fixture_name}.json")
        results = run_all(["parse", fixture_path])
        ok, matched = assert_all_match(results, f"parse({fixture_name})",
                                       golden=_golden(fixture_name))
        if ok:
            print(f"  PASS: {', '.join(LANGUAGES)} match the golden")
        account(matched)

    report = lane_report.LaneReport(
        title="Cross-language workspace", scope="4 tests",
        lanes=lanes,
        oracle_passed=oracle_passed, oracle_failed=oracle_failed,
        comparison_passed=comparison_passed,
        oracle_lanes=lanes.requested,
        oracle_what="vs the pinned golden, one check per lane per test",
        comparison_what="lane pairs established transitively through the "
                        "exact-equality golden",
        per_lane_comparisons=per_lane,
        require_comparisons=args.require_comparisons,
        unexercised=lane_report.unexercised_active_ports(lanes),
    )
    report.print_report()
    sys.exit(report.exit_code())


if __name__ == "__main__":
    main()
