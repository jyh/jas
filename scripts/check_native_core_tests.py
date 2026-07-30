#!/usr/bin/env python3
"""The Rust core's own tests must BUILD AND RUN without the `web` feature.

WHY THIS EXISTS
---------------
On 2026-07-29 the jas/windows seat measured, at `main` 8c10de3:

    cargo check --no-default-features --lib   ->  exit 0
    cargo test  --no-default-features --lib   ->  exit 101, 25x E0433

The shared Rust core COMPILES natively on Windows and its own tests DO NOT. Test
code inside natively-compiling modules reached into `#[cfg(feature = "web")]`
modules: `geometry/svg.rs` and `document/controller.rs` for two genuinely
web-free helpers, `interpreter/effects.rs` and `cross_language_test.rs` for the
app shell and the recorder.

That mattered the day the Captain ruled D1: port six keeps the Rust core and
grows a new native Windows frontend. **If port six stands on this core, the
core's tests must run on the platform it ships to** -- otherwise "the Rust core
is portable" is a claim about type-checking only, and its native BEHAVIOUR is
unmeasured. That is exactly the shape of claim this project treats as its most
serious defect.

The failure was invisible from macOS and from the web, because both build with
`web` on. It took a third platform to make it reachable, and a gate to make the
repair stay repaired.

WHAT IT ASSERTS
---------------
1. `cargo test --no-default-features --lib --no-run` exits 0.
2. The native lib test target contains AT LEAST `FLOOR` tests.

WHY (2) IS NOT OPTIONAL
-----------------------
Assertion (1) alone is trivially satisfiable by deleting tests or by wrapping
every offending test in `#[cfg(feature = "web")]`. That "fix" turns the gate
green while REDUCING what is verified natively -- the precise outcome this gate
exists to prevent. The floor is the anti-vacuity half, and it is the half that
does the work. It may be RAISED when the native surface grows; lowering it is a
deliberate act that should arrive with a written reason.

WHAT IT DOES NOT COVER
----------------------
* It asserts the tests BUILD and that enough of them EXIST. Running them and
  requiring green is `cargo test --no-default-features --lib` itself, which the
  CI lanes invoke directly -- this gate is about the target existing at all.
* It says nothing about the four bin targets. `workspace_roundtrip` is repaired
  alongside this gate; the gate does not watch it.
* A test gated behind `web` for a GOOD reason (it drives `AppState` or the
  Dioxus renderer) is invisible here. The floor is the only pressure against
  over-gating, and it is a blunt one.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CRATE = REPO / "jas_dioxus"

# Anti-vacuity floor: the native lib test target must carry at least this many
# tests. Measured after the 2026-07-29 repair; raise it when the native surface
# grows, and never lower it without a written reason.
FLOOR = 2000


def parse_test_count(listing: str) -> int:
    """Count tests from `cargo test -- --list` output.

    The listing is one `name: test` line per test, then a summary line
    `N tests, M benchmarks`. Prefer the summary; fall back to counting lines,
    because a cargo that changes its summary wording must not silently yield 0.
    """
    m = re.search(r"^(\d+) tests?(?:, \d+ benchmark)", listing, re.MULTILINE)
    if m:
        return int(m.group(1))
    return len(re.findall(r"^\S.*: test$", listing, re.MULTILINE))


def verdict(build_ok: bool, count: int, floor: int) -> tuple[bool, str]:
    """Pure decision, so the self-test can exercise it without cargo."""
    if not build_ok:
        return False, (
            "the native lib TEST target does not build "
            "(`cargo test --no-default-features --lib --no-run`)"
        )
    if count < floor:
        return False, (
            f"only {count} tests in the native lib test target, floor is {floor} -- "
            "the target builds but too little is verified natively. If tests were "
            "deliberately gated behind `web`, say why and lower the floor on purpose"
        )
    return True, f"native lib test target builds; {count} tests (floor {floor})"


def run() -> int:
    build = subprocess.run(
        ["cargo", "test", "--no-default-features", "--lib", "--no-run"],
        cwd=CRATE, capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    build_ok = build.returncode == 0

    count = 0
    if build_ok:
        listing = subprocess.run(
            ["cargo", "test", "--no-default-features", "--lib", "--", "--list"],
            cwd=CRATE, capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
        count = parse_test_count(listing.stdout)

    ok, msg = verdict(build_ok, count, FLOOR)
    if ok:
        print(f"native core tests: {msg}")
        return 0

    print(f"native core tests: FAIL -- {msg}", file=sys.stderr)
    if not build_ok:
        errs = [ln for ln in build.stderr.splitlines() if ln.startswith("error")]
        print(f"\n{len(errs)} compiler error line(s); first 15:", file=sys.stderr)
        for ln in errs[:15]:
            print(f"  {ln}", file=sys.stderr)
        print(
            "\nThe core compiles natively but its tests do not. Do NOT repair this by\n"
            "gating the offending tests behind `web` unless the test genuinely drives\n"
            "the frontend -- prefer moving the web-free helper it needs into a\n"
            "non-gated module and re-exporting it.",
            file=sys.stderr,
        )
    return 1


def self_test() -> int:
    """Prove the gate's RED before trusting its green."""
    cases = [
        # (label, build_ok, count, expect_pass)
        ("build fails", False, 9999, False),
        ("build fails, zero tests", False, 0, False),
        ("builds but empty", True, 0, False),
        ("builds, one short of floor", True, FLOOR - 1, False),
        ("builds, exactly at floor", True, FLOOR, True),
        ("builds, comfortably above", True, FLOOR + 500, True),
    ]
    failures = []
    for label, build_ok, count, expect in cases:
        got, msg = verdict(build_ok, count, FLOOR)
        if got != expect:
            failures.append(f"  {label}: expected {'PASS' if expect else 'RED'}, got {'PASS' if got else 'RED'} ({msg})")

    parse_cases = [
        ("summary line", "a: test\nb: test\n\n2 tests, 0 benchmarks\n", 2),
        ("summary wins over lines", "x: test\n\n1731 tests, 0 benchmarks\n", 1731),
        ("no summary falls back to lines", "a: test\nb: test\nc: test\n", 3),
        ("empty listing", "", 0),
        ("benchmarks are not tests", "\n0 tests, 4 benchmarks\n", 0),
    ]
    for label, text, expect in parse_cases:
        got = parse_test_count(text)
        if got != expect:
            failures.append(f"  parse/{label}: expected {expect}, got {got}")

    if failures:
        print("self-test FAILED:", file=sys.stderr)
        for f in failures:
            print(f, file=sys.stderr)
        return 1
    print(
        f"self-test OK: {len(cases)} verdict cases "
        f"({sum(1 for c in cases if not c[3])} RED, {sum(1 for c in cases if c[3])} pass), "
        f"{len(parse_cases)} parse cases"
    )
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true", help="prove the gate's RED and exit")
    args = ap.parse_args()
    sys.exit(self_test() if args.self_test else run())
