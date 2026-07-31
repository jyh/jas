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
2. The native lib test target contains EXACTLY `FLOOR` tests.

WHY (2) IS NOT OPTIONAL
-----------------------
Assertion (1) alone is trivially satisfiable by deleting tests or by wrapping
every offending test in `#[cfg(feature = "web")]`. That "fix" turns the gate
green while REDUCING what is verified natively -- the precise outcome this gate
exists to prevent. The floor is the anti-vacuity half, and it is the half that
does the work. It is EXACT in both directions -- see the note on FLOOR.

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
# tests.
#
# Measured 1830 immediately after the 2026-07-29 repair (from 0 -- the target did
# not build at all).
#
# TIGHT, deliberately, in the shape the preservation gate already uses in this
# repo ("14 against a floor of 14"). A first attempt set it to 1800 for ~1.6% of
# slack; a mutation then gated `painter::tests` off, the native count fell to
# 1824, and THE GATE STILL PASSED. A floor with slack is a floor with a hole
# exactly the size of the slack, and the hole admits precisely the move this
# assertion exists to forbid.
#
# So: adding native tests REQUIRES raising this number, and that friction is the
# feature -- it makes every change to native coverage a visible, deliberate line
# in a diff. Lowering it should arrive with a written reason.
#
# CORRECTED 2026-07-30: the comment above said that from day one and the CODE DID
# NOT DO IT -- the check was `count < floor`, so ADDING tests passed silently and
# only removals red. My own gate's documentation was wider than its behaviour,
# which is the exact defect class this repo treats as most serious, sitting in
# the file that exists to police it. Now `count != floor`, both directions.
#
# AND THE FIX EARNED ITSELF ON ITS FIRST RUN, on drift that was not mine. It red
# on `arc2-section20` where the pin read 1830 and the tree carried 1832; rebased
# onto main the same drift is 1830 vs 1833. Native tests were added three times
# and the pin was never raised, silently -- and the council record even states
# "Native lib tests 1833", so the number WAS measured and reported while the pin
# stayed put, because the code never asked for it. That is exactly the drift the
# comment above claimed to prevent and the one-sided check did not.
# Re-pinned to main's measured 1833, then 1836 an hour later.
#
# AND THAT IS THE PROBLEM. Three bumps in one session -- 1830, 1832, 1833, 1836 --
# is exactly the churn council O3.3 (DERIVEDFLOOR, 8031ebbc) exists to abolish.
# Starbuck's argument there: "a floor computed from the tree cannot go slack, and
# this repo's record on hand-typed floors is that TWO OF FOUR replacement numbers
# were wrong on the first attempt." MIN_CHECK_SCRIPTS was bumped four times in one
# day and wrong once. This constant is the same species and is heading the same way.
#
# THE EXACT PIN WAS THE RIGHT FIX TO A ONE-SIDED CHECK AND IS THE WRONG INSTRUMENT.
# The property actually wanted is derivable and needs no number at all: *no test
# that COULD run natively is gated behind `web`* -- i.e. every `#[cfg(feature =
# "web")]` on a test item OUTSIDE the five web-gated modules is declared with a
# reason, the `check_widget_kind_dispatch` shape. That cannot drift, because
# nothing restates it.
#
# Queued rather than done here so it does not derail B1, and recorded in the
# windows ledger so it cannot quietly expire -- which is the failure mode this
# whole week has been about.
#
# 2026-07-30, 1839 -> 2024. NOT drift, and not a native test written: the `web`
# gate MOVED. `lib.rs` had `#[cfg(feature = "web")] pub mod workspace;`, which
# put the entire workspace layer -- layout types, the layout-op dispatcher, pane
# geometry, key-chord resolution, the menu structure, the fixture serializer --
# out of a `--no-default-features` build, though nine of its seventeen
# submodules import nothing from Dioxus, web_sys, or the app shell. 185 tests
# that could always have run natively did not.
#
# THAT IS THIS GATE FINDING WHAT IT WAS BUILT TO FIND, and it is also the exact
# argument for the derived form: a COUNT could never have told anyone those 185
# tests existed. It went up by 185 and the only honest thing a count can say is
# "185 more than yesterday". The property -- *no test that COULD run natively is
# gated behind `web`* -- would have NAMED them, on the day the module was gated.
FLOOR = 2024


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
            f"only {count} tests in the native lib test target, pinned at {floor} -- "
            "the target builds but LESS is verified natively than before. If tests were "
            "deliberately gated behind `web`, say why and lower the pin on purpose"
        )
    if count > floor:
        return False, (
            f"{count} tests in the native lib test target, pinned at {floor} -- "
            f"{count - floor} MORE than pinned. That is almost always good news; raise "
            "the pin in the same commit that adds them. The pin is exact on purpose: a "
            "one-sided floor lets native coverage drift without anyone deciding to"
        )
    return True, f"native lib test target builds; {count} tests (pinned at {floor})"


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
        ("builds, exactly at the pin", True, FLOOR, True),
        # BOTH directions red. Before 2026-07-30 this case expected PASS, which
        # is what let the pin drift upward unnoticed.
        ("builds, one MORE than pinned", True, FLOOR + 1, False),
        ("builds, comfortably above", True, FLOOR + 500, False),
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
