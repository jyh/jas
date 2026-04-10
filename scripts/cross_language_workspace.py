#!/usr/bin/env python3
"""Cross-language workspace layout equivalence test.

Tests that all four language implementations (Rust, Swift, OCaml, Python)
produce identical canonical JSON for workspace operations.

Tests:
1. Default layout: all 4 languages produce the same canonical JSON.
2. Default layout with panes: same at 1200x800 viewport.
3. Parse commutativity: parse fixture in A, re-serialize → same JSON.

Usage:
    python scripts/cross_language_workspace.py
"""

import os
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES_DIR = os.path.join(REPO_ROOT, "test_fixtures")

LANGUAGES = ["rust", "swift", "ocaml", "python"]


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
        ["swift", "run", "-c", "release", "WorkspaceRoundtrip"] + args,
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


def assert_all_match(results: dict[str, str], test_name: str):
    ref_lang = LANGUAGES[0]
    ref = results[ref_lang]
    for lang in LANGUAGES[1:]:
        if results[lang] != ref:
            print(f"  FAIL: {test_name} — {lang} differs from {ref_lang}")
            print(f"    {ref_lang}: {ref[:200]}...")
            print(f"    {lang}: {results[lang][:200]}...")
            return False
    return True


def main():
    passed = 0
    failed = 0

    # Test 1: default layout
    print("Test 1: default layout")
    results = run_all(["default"])
    if assert_all_match(results, "default"):
        print("  PASS: all 4 languages match")
        passed += 1
    else:
        failed += 1

    # Test 2: default layout with panes
    print("Test 2: default layout with panes (1200x800)")
    results = run_all(["default_with_panes", "1200", "800"])
    if assert_all_match(results, "default_with_panes"):
        print("  PASS: all 4 languages match")
        passed += 1
    else:
        failed += 1

    # Test 3: parse commutativity for each workspace fixture
    for fixture_name in ["workspace_default", "workspace_default_with_panes"]:
        print(f"Test 3: parse commutativity ({fixture_name})")
        fixture_path = os.path.join(FIXTURES_DIR, "expected", f"{fixture_name}.json")
        results = run_all(["parse", fixture_path])
        if assert_all_match(results, f"parse({fixture_name})"):
            print("  PASS: all 4 languages match")
            passed += 1
        else:
            failed += 1

    print(f"\n{passed} passed, {failed} failed")
    if failed > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
