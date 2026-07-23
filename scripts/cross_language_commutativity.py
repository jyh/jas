#!/usr/bin/env python3
"""Cross-language serialize-parse commutativity test.

Tests the commutative diagram:

            to_svg_A          parse_B          to_test_json_B
   Doc ──────────────> SVG_A ──────────────> Doc' ──────────────> JSON'
    |                                                                ||
    |  to_test_json_A                                                ||
    +──────────────────────────────────────────────────────────> JSON

For each SVG fixture:
1. Each language parses the fixture and emits canonical JSON (parse mode).
2. Each language re-serializes the fixture to SVG (roundtrip mode).
3. For each pair (serializer A, parser B): B parses A's SVG → canonical JSON.
4. All canonical JSON outputs must match.

Requires:
- OCaml: dune exec bin/svg_roundtrip.exe -- (from jas_ocaml/)
- Python: python jas/tools/svg_roundtrip.py (from jas/)

Usage:
    python scripts/cross_language_commutativity.py [--lang rust,swift]

Every (serializer, parser) cell is anchored to the fixture's pinned expected
JSON, so a restricted language set still verifies against the shared golden,
not merely mutual agreement. Default is the active ports (rust, swift);
ocaml/python are pinned to the five-port-parity tag and run in their own
canary lane (POLICY.md).
"""

import argparse
import os
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES_DIR = os.path.join(REPO_ROOT, "test_fixtures")

# SVG fixtures to test. The text fixtures were historically excluded
# because the Python port's document_to_svg needed a QApplication; that
# port is frozen at the five-port-parity tag, so the exclusion is moot
# for the active-port gate. Their genuinely new coverage here is the
# cross-emit cells (Rust-emitted SVG parsed by Swift and vice versa).
FIXTURE_NAMES = [
    "line_basic", "rect_basic", "rect_with_stroke",
    "circle_basic", "ellipse_basic",
    "polyline_basic", "polygon_basic", "path_all_commands",
    "text_basic", "text_path_basic",
    "group_nested", "transform_translate", "transform_rotate",
    "multi_layer",
]


def run_rust(mode: str, svg_path: str) -> str:
    result = subprocess.run(
        ["cargo", "run", "--bin", "svg_roundtrip", "--no-default-features",
         "-q", "--", mode, svg_path],
        cwd=os.path.join(REPO_ROOT, "jas_dioxus"),
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Rust {mode} failed: {result.stderr}")
    return result.stdout


def run_ocaml(mode: str, svg_path: str) -> str:
    result = subprocess.run(
        ["dune", "exec", "bin/svg_roundtrip.exe", "--", mode, svg_path],
        cwd=os.path.join(REPO_ROOT, "jas_ocaml"),
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"OCaml {mode} failed: {result.stderr}")
    return result.stdout


def run_python(mode: str, svg_path: str) -> str:
    result = subprocess.run(
        [sys.executable, os.path.join(REPO_ROOT, "jas", "tools", "svg_roundtrip.py"),
         mode, svg_path],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Python {mode} failed: {result.stderr}")
    return result.stdout


def run_swift(mode: str, svg_path: str) -> str:
    result = subprocess.run(
        ["swift", "run", "SvgRoundtrip", mode, svg_path],
        cwd=os.path.join(REPO_ROOT, "JasSwift"),
        capture_output=True, text=True, timeout=60,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Swift {mode} failed: {result.stderr}")
    return result.stdout


ALL_LANGUAGES = {
    "rust": run_rust,
    "ocaml": run_ocaml,
    "swift": run_swift,
    "python": run_python,
}

# Filled from --lang in main(); module-level so the step functions see it.
LANGUAGES: dict = {}


def main():
    global LANGUAGES
    parser = argparse.ArgumentParser(
        description="Cross-language serialize-parse commutativity test")
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
    LANGUAGES = {l: ALL_LANGUAGES[l] for l in selected}

    passed = 0
    failed = 0

    for name in FIXTURE_NAMES:
        svg_path = os.path.join(FIXTURES_DIR, "svg", f"{name}.svg")
        expected_path = os.path.join(FIXTURES_DIR, "expected", f"{name}.json")
        with open(expected_path) as f:
            expected_json = f.read().strip()

        # Step 1: Each language parses the original SVG.
        parse_results = {}
        for lang, runner in LANGUAGES.items():
            try:
                json_out = runner("parse", svg_path)
                parse_results[lang] = json_out
                if json_out != expected_json:
                    print(f"  FAIL: {name} parse by {lang} differs from expected")
                    failed += 1
                    continue
            except Exception as e:
                print(f"  ERROR: {name} parse by {lang}: {e}")
                failed += 1
                continue

        # Step 2: Each language re-serializes to SVG.
        svg_outputs = {}
        for lang, runner in LANGUAGES.items():
            try:
                svg_out = runner("roundtrip", svg_path)
                svg_outputs[lang] = svg_out
            except Exception as e:
                print(f"  ERROR: {name} roundtrip by {lang}: {e}")

        # Step 3: Cross-language commutativity.
        # For each pair (serializer, parser): parser reads serializer's SVG.
        for ser_lang, svg_out in svg_outputs.items():
            for par_lang, par_runner in LANGUAGES.items():
                # Write serializer's SVG to a temp file.
                with tempfile.NamedTemporaryFile(
                    mode="w", suffix=".svg", delete=False
                ) as tmp:
                    tmp.write(svg_out)
                    tmp_path = tmp.name

                try:
                    json_out = par_runner("parse", tmp_path)
                    if json_out != expected_json:
                        print(f"  FAIL: {name} [{ser_lang}→svg→{par_lang}] "
                              f"canonical JSON mismatch")
                        failed += 1
                    else:
                        passed += 1
                except Exception as e:
                    print(f"  ERROR: {name} [{ser_lang}→svg→{par_lang}]: {e}")
                    failed += 1
                finally:
                    os.unlink(tmp_path)

    print(f"\nCross-language commutativity: {passed} passed, {failed} failed "
          f"({len(FIXTURE_NAMES)} fixtures × {len(LANGUAGES)} serializers × "
          f"{len(LANGUAGES)} parsers = {len(FIXTURE_NAMES) * len(LANGUAGES)**2} pairs)")

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
