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

TWO KINDS OF CELL, COUNTED APART (scripts/lane_report.py, and the same defect
the algorithm runner carried): a DIAGONAL cell (rust emits, rust parses) is an
ORACLE check -- one port's serializer composed with its own parser, against the
golden. Only an OFF-DIAGONAL cell (rust emits, swift parses) compares two
implementations. With one lane every cell is diagonal, so `--lang rust` performs
ZERO cross-language comparisons while the old summary reported "14 passed".

NOT COUNTED, deliberately: step 1's parse-the-original-SVG check increments
nothing on success (it only fails loudly). Its passes are therefore invisible in
the totals, which understates the oracle evidence rather than overstating it.
"""

import argparse
import itertools
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lane_report  # noqa: E402  (sibling module in scripts/)

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
    if "--self-test" in sys.argv:
        sys.exit(lane_report.self_test())
    parser = argparse.ArgumentParser(
        description="Cross-language serialize-parse commutativity test")
    parser.add_argument("--lang",
                        help="Comma-separated languages (default: the active "
                             "ports; ocaml/python are pinned to the "
                             "five-port-parity tag and run in their own "
                             "canary lane — see POLICY.md)",
                        default="rust,swift")
    parser.add_argument("--require-comparisons", action="store_true",
                        help="Exit non-zero (3) unless every requested "
                             "comparison lane actually compared (CI passes "
                             "this; a deliberate single-lane oracle run "
                             "omits it)")
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
    LANGUAGES = {l: ALL_LANGUAGES[l] for l in lanes.requested}

    # Diagonal cells (a port's own serializer + parser vs the golden) are
    # ORACLE; only off-diagonal cells compare two implementations.
    oracle_passed = 0
    oracle_failed = 0
    compare_passed = 0
    compare_failed = 0
    errors = 0
    per_lane = {l: 0 for l in lanes.comparison}

    for name in FIXTURE_NAMES:
        svg_path = os.path.join(FIXTURES_DIR, "svg", f"{name}.svg")
        expected_path = os.path.join(FIXTURES_DIR, "expected", f"{name}.json")
        with open(expected_path, encoding="utf-8") as f:
            expected_json = f.read().strip()

        # Step 1: Each language parses the original SVG.
        parse_results = {}
        for lang, runner in LANGUAGES.items():
            try:
                json_out = runner("parse", svg_path)
                parse_results[lang] = json_out
                if json_out != expected_json:
                    print(f"  FAIL: {name} parse by {lang} differs from expected")
                    oracle_failed += 1
                    continue
            except Exception as e:
                print(f"  ERROR: {name} parse by {lang}: {e}")
                errors += 1
                continue

        # Step 2: Each language re-serializes to SVG.
        svg_outputs = {}
        for lang, runner in LANGUAGES.items():
            try:
                svg_out = runner("roundtrip", svg_path)
                svg_outputs[lang] = svg_out
            except Exception as e:
                print(f"  ERROR: {name} roundtrip by {lang}: {e}")
                errors += 1

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

                # A DIAGONAL cell exercises one port only: its serializer
                # composed with its own parser, anchored to the golden. That is
                # an oracle, not evidence that two ports agree.
                cross = ser_lang != par_lang
                try:
                    json_out = par_runner("parse", tmp_path)
                    if cross:
                        for lane in (ser_lang, par_lang):
                            if lane in per_lane:
                                per_lane[lane] += 1
                    if json_out != expected_json:
                        print(f"  FAIL: {name} [{ser_lang}→svg→{par_lang}] "
                              f"canonical JSON mismatch")
                        if cross:
                            compare_failed += 1
                        else:
                            oracle_failed += 1
                    elif cross:
                        compare_passed += 1
                    else:
                        oracle_passed += 1
                except Exception as e:
                    print(f"  ERROR: {name} [{ser_lang}→svg→{par_lang}]: {e}")
                    errors += 1
                finally:
                    os.unlink(tmp_path)

    n_cross = len(list(itertools.permutations(lanes.requested, 2)))
    report = lane_report.LaneReport(
        title="Cross-language commutativity",
        scope=f"{len(FIXTURE_NAMES)} fixtures × {len(LANGUAGES)}² cells "
              f"= {len(FIXTURE_NAMES) * len(LANGUAGES) ** 2} "
              f"({len(FIXTURE_NAMES) * n_cross} off-diagonal)",
        lanes=lanes,
        oracle_passed=oracle_passed, oracle_failed=oracle_failed,
        comparison_passed=compare_passed, comparison_failed=compare_failed,
        errors=errors,
        oracle_lanes=lanes.requested,
        oracle_what="on the diagonal: own serializer + own parser, "
                    "vs the pinned golden",
        comparison_what="one port's SVG parsed by another, vs the golden "
                        "(off-diagonal cells)",
        per_lane_comparisons=per_lane,
        require_comparisons=args.require_comparisons,
        unexercised=lane_report.unexercised_active_ports(lanes),
    )
    report.print_report()
    sys.exit(report.exit_code())


if __name__ == "__main__":
    main()
