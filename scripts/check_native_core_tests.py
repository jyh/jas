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

That is now the WHOLE claim. The test count is printed and not asserted.

WHERE THE ANTI-VACUITY HALF WENT (read this before adding a number back)
------------------------------------------------------------------------
Assertion (1) alone is trivially satisfiable by deleting tests or by wrapping
every offending test in `#[cfg(feature = "web")]` -- a "fix" that turns this
gate green while REDUCING what is verified natively. From 2026-07-29 to
2026-07-30 the guard against that was `FLOOR`, an exact pin on the test count.

**`FLOOR` is retired, and `scripts/check_native_test_gating.py` holds the claim
instead**: every `web` gate on a module or on a test item must be DECLARED with
a reason, and no declaration may outlive its gate.

The pin was retired on the evidence of its own last movement. It went
1839 -> 2024 because `lib.rs` read `#[cfg(feature = "web")] pub mod workspace;`,
which hid the entire workspace layer from a native build though nine of its
seventeen submodules import nothing from the frontend. 185 tests could always
have run natively and did not -- and a count could not say so. The most a count
can report is "185 more than yesterday"; the property NAMES them, on the day the
module is gated. (It was also drifting: five values in two days, one of them
wrong, in a file nobody else was reading. Council O3.3, DERIVEDFLOOR.)

WHAT IT DOES NOT COVER
----------------------
* It asserts the tests BUILD. Running them and requiring green is
  `cargo test --no-default-features --lib` itself, which the CI lanes invoke
  directly -- this gate is about the target existing at all.
* It says nothing about the four bin targets. `workspace_roundtrip` is repaired
  alongside this gate; the gate does not watch it.
* Nothing here now watches tests being DELETED outright. The exact pin did, and
  the replacement does not; the trade was deliberate. Gating a test is a
  one-line attribute that leaves every lane green, which is the move that needs
  a machine. Deleting a test deletes test code, which review sees.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CRATE = REPO / "jas_dioxus"

# THE HISTORY OF THE NUMBER THAT USED TO LIVE HERE, kept because it is the
# argument for what replaced it.
#
# `FLOOR` was an exact pin on the native test count, added 2026-07-29 at 1830 as
# the anti-vacuity half of this gate. It was RIGHT that assertion (1) needs a
# partner and WRONG about which partner.
#
#   1830  measured after the repair (from 0 -- the target did not build at all)
#   1832  drift found on a branch; the pin had never been raised
#   1833  the same drift on main -- and the council record already SAID 1833,
#         so the number was measured and reported while the pin stayed put
#   1836  an hour later
#   1839  the next day
#   2024  the `web` gate MOVED off `pub mod workspace` (GATEINWARD)
#
# Two lessons, in order of importance.
#
# FIRST: the check was one-sided. The comment claimed "adding native tests
# REQUIRES raising this number" from day one and the CODE DID NOT DO IT -- it
# read `count < floor`, so additions passed silently. Documentation wider than
# behaviour, in the file that exists to police exactly that. Fixed to an exact
# comparison, which then earned itself immediately on drift that was not mine.
#
# SECOND, and why the constant is gone: the last movement, 1839 -> 2024, was not
# drift and not a test anyone wrote. `lib.rs` read `#[cfg(feature = "web")] pub
# mod workspace;`, hiding the whole workspace layer from a native build though
# nine of its seventeen submodules import nothing from the frontend. **185 tests
# could always have run natively and did not, and the count could not say so.**
# The most a count reports is "185 more than yesterday". The property NAMES them.
#
# That property now lives in `scripts/check_native_test_gating.py`: every `web`
# gate on a module or a test item is declared with a reason, and no declaration
# outlives its gate. It has no number in it -- its anti-vacuity guard is derived,
# because a scanner that finds nothing makes every ledger row stale.
#
# Council O3.3 (DERIVEDFLOOR) had already ruled on the species: a floor computed
# from the tree cannot go slack, and this repo's record on hand-typed floors is
# that two of four replacement numbers were wrong on the first attempt. Five
# values in two days, one of them wrong, was this constant proving the point.


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


def verdict(build_ok: bool, count: int) -> tuple[bool, str]:
    """Pure decision, so the self-test can exercise it without cargo.

    `count` is REPORTED, never compared. Nothing restates it, so it cannot
    drift -- see the note above on the constant that used to live here.
    """
    if not build_ok:
        return False, (
            "the native lib TEST target does not build "
            "(`cargo test --no-default-features --lib --no-run`)"
        )
    return True, (
        f"native lib test target builds; {count} tests "
        f"(reported, not pinned -- check_native_test_gating.py holds the "
        f"anti-vacuity claim)"
    )


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

    ok, msg = verdict(build_ok, count)
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
        ("builds", True, 2041, True),
        # THE COUNT NO LONGER DECIDES. These two cases exist to PIN that: a
        # count moving in either direction is not this gate's business any
        # more, and reintroducing a comparison here would red them. The claim
        # they used to carry lives in check_native_test_gating.py, which names
        # the hidden tests instead of counting the visible ones.
        ("builds, count far below what it was", True, 3, True),
        ("builds, count far above", True, 99999, True),
    ]
    failures = []
    for label, build_ok, count, expect in cases:
        got, msg = verdict(build_ok, count)
        if got != expect:
            failures.append(f"  {label}: expected {'PASS' if expect else 'RED'}, got {'PASS' if got else 'RED'} ({msg})")

    # The partner gate must EXIST. Retiring a floor into a sibling and then
    # losing the sibling is how a claim evaporates while both files look fine.
    partner = REPO / "scripts" / "check_native_test_gating.py"
    if not partner.exists():
        failures.append(f"  partner: {partner.name} is missing -- this gate gave up "
                        f"its anti-vacuity half to it, so without it the only "
                        f"remaining claim is trivially satisfiable by gating tests")

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
