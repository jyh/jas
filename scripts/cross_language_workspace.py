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
"""

import argparse
import os
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES_DIR = os.path.join(REPO_ROOT, "test_fixtures")

ALL_LANGUAGES = ["rust", "swift", "ocaml", "python"]

# Filled from --lang in main(); module-level so helpers see it.
LANGUAGES: list = []


def run_rust(args: list[str]) -> str:
    result = subprocess.run(
        ["cargo", "run", "--bin", "workspace_roundtrip",
         "-q", "--"] + args,
        cwd=os.path.join(REPO_ROOT, "jas_dioxus"),
        capture_output=True, text=True, timeout=30,
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
        capture_output=True, text=True, timeout=60,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Swift failed: {result.stderr}")
    return result.stdout


def run_ocaml(args: list[str]) -> str:
    result = subprocess.run(
        ["dune", "exec", "bin/workspace_roundtrip.exe", "--"] + args,
        cwd=os.path.join(REPO_ROOT, "jas_ocaml"),
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"OCaml failed: {result.stderr}")
    return result.stdout


def run_python(args: list[str]) -> str:
    result = subprocess.run(
        [sys.executable, "tools/workspace_roundtrip.py"] + args,
        cwd=os.path.join(REPO_ROOT, "jas"),
        capture_output=True, text=True, timeout=30,
    )
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
    """Every language must agree; when a golden is given, anchor to it."""
    ref_lang = "golden" if golden is not None else LANGUAGES[0]
    ref = golden if golden is not None else results[LANGUAGES[0]]
    ok = True
    for lang in LANGUAGES:
        if lang == ref_lang:
            continue
        if results[lang].strip() != ref.strip():
            print(f"  FAIL: {test_name} — {lang} differs from {ref_lang}")
            print(f"    {ref_lang}: {ref[:200]}...")
            print(f"    {lang}: {results[lang][:200]}...")
            ok = False
    return ok


def _golden(fixture_name: str) -> str:
    with open(os.path.join(FIXTURES_DIR, "expected", f"{fixture_name}.json")) as f:
        return f.read()


def main():
    global LANGUAGES
    parser = argparse.ArgumentParser(
        description="Cross-language workspace layout equivalence test")
    parser.add_argument("--lang",
                        help="Comma-separated languages (default: the active "
                             "ports; ocaml/python are pinned to the "
                             "five-port-parity tag and run in their own "
                             "canary lane — see POLICY.md)",
                        default="rust,swift")
    args = parser.parse_args()
    selected = [l.strip() for l in args.lang.split(",") if l.strip()]
    unknown = [l for l in selected if l not in ALL_LANGUAGES]
    if unknown:
        print(f"Unknown language(s): {', '.join(unknown)} "
              f"(choose from {', '.join(ALL_LANGUAGES)})", file=sys.stderr)
        sys.exit(2)
    LANGUAGES = selected

    passed = 0
    failed = 0

    # Test 1: default layout, anchored to the pinned golden
    print("Test 1: default layout")
    results = run_all(["default"])
    if assert_all_match(results, "default", golden=_golden("workspace_default")):
        print(f"  PASS: {', '.join(LANGUAGES)} match the golden")
        passed += 1
    else:
        failed += 1

    # Test 2: default layout with panes, anchored to the pinned golden
    print("Test 2: default layout with panes (1200x800)")
    results = run_all(["default_with_panes", "1200", "800"])
    if assert_all_match(results, "default_with_panes",
                        golden=_golden("workspace_default_with_panes")):
        print(f"  PASS: {', '.join(LANGUAGES)} match the golden")
        passed += 1
    else:
        failed += 1

    # Test 3: parse commutativity for each workspace fixture
    for fixture_name in ["workspace_default", "workspace_default_with_panes"]:
        print(f"Test 3: parse commutativity ({fixture_name})")
        fixture_path = os.path.join(FIXTURES_DIR, "expected", f"{fixture_name}.json")
        results = run_all(["parse", fixture_path])
        if assert_all_match(results, f"parse({fixture_name})",
                            golden=_golden(fixture_name)):
            print(f"  PASS: {', '.join(LANGUAGES)} match the golden")
            passed += 1
        else:
            failed += 1

    print(f"\n{passed} passed, {failed} failed")
    if failed > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
