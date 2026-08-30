#!/usr/bin/env python3
"""Assert that the wasm-canvas lane RAN the canvas tests -- all of them.

WHY THIS EXISTS. The `wasm-canvas` lane is the only instrument in this repo
that executes the browser canvas path; the native suite cannot reach it. Its
verdict was guarded by a hand-written floor:

    if [ -z "$n" ] || [ "$n" -lt 4 ]; then ... exit 1

That floor was right when it was written (2026-08-28, PR #46, four tests) and
it had gone stale by 2026-08-30, when the lane ran SEVENTEEN. Measured, from
the lane's own `canvas lane ran N test(s)` line on main at 9bc6b06c -- not
estimated. A floor of 4 against a lane of 17 cannot distinguish a lane that
half-ran from one that ran: THIRTEEN tests could stop being compiled and the
lane would still report success. That is the exact shape the lane was built to
end, reappearing inside the lane's own guard.

THE FIX IS NOT A BIGGER NUMBER. Raising 4 to 17 buys one day and then rots the
same way, and it teaches its next reader to bump it -- which is the habit that
produced the stale 4. The floor's problem is not its value, it is that it is
REMEMBERED. So both sides of the comparison are DERIVED here:

    EXPECTED  the number of `#[wasm_bindgen_test]` attributes in the crate's
              own source. This is sound because every such test in this crate
              lives inside a module gated `#[cfg(all(test, target_arch =
              "wasm32"))]` -- module-level, never per-test -- so a wasm test
              build compiles ALL of them or none. Verified at 9bc6b06c:
              painter/canvas2d.rs:556 and canvas/render.rs:4155 are the only
              two such modules, holding 13 and 4.

    OBSERVED  the counts libtest printed in the log, one per test binary.

A test ADDED to the crate moves both sides together and stays green with no
edit here. A test that silently stops being compiled -- a cfg that stops
matching, a module no longer declared, a renamed file dropped from `mod` --
moves only OBSERVED, and reds. That is the failure this file exists for, and
it is precisely the one a floor cannot see.

WHY "EVERY NONZERO BINARY MUST MATCH", not "the maximum must match".
`wasm-pack test` runs seven binaries here; three print a result. Two of them
(`src/lib.rs` and `src/main.rs`) each link the crate's modules and so each run
the full 17; `tests/cross_language_test.rs` carries no wasm test and honestly
runs 0. Taking the max would let a binary that dropped to 16 hide behind a
sibling still at 17. Taking the sum would red every time a binary is added or
removed, for a reason that has nothing to do with coverage. The invariant that
is actually true of this crate is: a binary either links the wasm test modules
and runs all of them, or links none and runs zero.

A DISAGREEMENT IN EITHER DIRECTION IS A REFUSAL. If OBSERVED exceeds EXPECTED,
this script's derivation is the thing that is wrong (a macro-generated test,
say) -- and a gate that quietly tolerates being wrong about its own subject is
worth nothing. Loud and wrong is repairable; silent and wrong is not.

USAGE
    check_wasm_canvas_count.py --log /tmp/wasm.log [--crate jas_dioxus]
    check_wasm_canvas_count.py --self-test
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
import tempfile

# libtest's end-of-binary summary. Both the native and the wasm-bindgen
# harnesses print this shape, e.g.
#   test result: ok. 17 passed; 0 failed; 0 ignored; 0 filtered out; ...
RESULT_RE = re.compile(r"test result:.*?(\d+) passed;\s*(\d+) failed")

# The attribute, counted in source. Written to tolerate the `#[wasm_bindgen_test]`
# and `#[wasm_bindgen_test(async)]` spellings, and leading indentation.
ATTR_RE = re.compile(r"^\s*#\[wasm_bindgen_test\b", re.MULTILINE)


def expected_from_source(crate_dir: pathlib.Path) -> int:
    """Count the wasm test attributes the crate's own source declares.

    Extracted so the self-test drives the SAME derivation main() uses. A
    control that runs beside the instrument instead of through it validates
    nothing.
    """
    total = 0
    for path in sorted(crate_dir.rglob("*.rs")):
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        total += len(ATTR_RE.findall(text))
    return total


def observed_from_log(log_text: str) -> list[tuple[int, int]]:
    """Every libtest summary in the log, as (passed, failed) in order."""
    return [(int(p), int(f)) for p, f in RESULT_RE.findall(log_text)]


def judge(expected: int, observed: list[tuple[int, int]]) -> list[str]:
    """Return the list of complaints. Empty list == the lane is trustworthy.

    Pure, and separated from I/O, so the self-test drives the real predicate
    rather than a paraphrase of it.
    """
    problems: list[str] = []

    # A count has no failure mode: a derivation that found nothing looks
    # exactly like a crate with no wasm tests. Refuse rather than compare
    # zero against zero and call it agreement.
    if expected == 0:
        problems.append(
            "the source derivation found ZERO `#[wasm_bindgen_test]` attributes. "
            "Either the crate has no browser tests, or this script's scope is "
            "wrong. Both deserve a refusal -- comparing 0 against 0 is not a check."
        )
        return problems

    if not observed:
        problems.append(
            "the log contains no `test result:` line at all. The lane produced "
            "no test summary, so nothing was measured -- a green here would be "
            "the shape this lane exists to end."
        )
        return problems

    failed_total = sum(f for _, f in observed)
    if failed_total:
        problems.append(f"{failed_total} test(s) FAILED in the lane's own summary.")

    nonzero = [p for p, _ in observed if p > 0]
    if not nonzero:
        problems.append(
            f"every test binary reported 0 passed, but the crate declares "
            f"{expected} `#[wasm_bindgen_test]`. The lane executed nothing."
        )
        return problems

    mismatched = sorted({p for p in nonzero if p != expected})
    if mismatched:
        shape = ", ".join(str(p) for p in mismatched)
        direction = "fewer" if all(p < expected for p in mismatched) else "a differing number of"
        problems.append(
            f"the crate declares {expected} `#[wasm_bindgen_test]`, but a test "
            f"binary ran {direction} ({shape}). A binary in this crate links the "
            f"wasm test modules and runs ALL of them, or links none and runs zero "
            f"-- so a count between the two means tests stopped being compiled, "
            f"or this script's derivation is stale. Neither is a clean lane."
        )

    return problems


# --------------------------------------------------------------------------
# self-test
# --------------------------------------------------------------------------

# The shape the real lane emits, reduced to the lines that matter. Captured
# from run 33283686329 (main @ 9bc6b06c, 2026-08-30): src/lib.rs 17,
# src/main.rs 17, tests/cross_language_test.rs 0.
REAL_LOG = """\
     Running unittests src/lib.rs (target/wasm32-unknown-unknown/debug/deps/jas_dioxus-237.wasm)
Running headless tests in Chrome on `http://127.0.0.1:33217/`
running 17 tests
test result: ok. 17 passed; 0 failed; 0 ignored; 0 filtered out; finished in 0.12s
     Running unittests src/main.rs (target/wasm32-unknown-unknown/debug/deps/jas_dioxus-2dd.wasm)
Running headless tests in Chrome on `http://127.0.0.1:43277/`
running 17 tests
test result: ok. 17 passed; 0 failed; 0 ignored; 0 filtered out; finished in 0.06s
     Running tests/cross_language_test.rs (target/wasm32-unknown-unknown/debug/deps/cross-fd4.wasm)
running 0 tests
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
"""


def _old_floor_predicate(log_text: str, floor: int = 4) -> bool:
    """The gate this file REPLACES, transcribed exactly.

        n=$(grep -oE '[0-9]+ passed' log | head -1 | grep -oE '[0-9]+')
        if [ -z "$n" ] || [ "$n" -lt 4 ]; then fail

    Kept executable, not described, so the self-test can show on the SAME
    fixture that the old predicate passed where the new one refuses. A claim
    that an old gate was blind is worth what its demonstration is worth.
    """
    m = re.search(r"(\d+) passed", log_text)
    if not m:
        return False
    return int(m.group(1)) >= floor


def self_test() -> int:
    failures: list[str] = []

    def check(name: str, got, want) -> None:
        if got != want:
            failures.append(f"  {name}: expected {want!r}, got {got!r}")

    # -- the derivation, driven on a fixture tree with a KNOWN answer --------
    with tempfile.TemporaryDirectory() as td:
        root = pathlib.Path(td)
        (root / "sub").mkdir()
        (root / "a.rs").write_text(
            "#[cfg(all(test, target_arch = \"wasm32\"))]\n"
            "mod m {\n"
            "    #[wasm_bindgen_test]\n    fn one() {}\n"
            "    #[wasm_bindgen_test]\n    fn two() {}\n"
            "}\n",
            encoding="utf-8",
        )
        (root / "sub" / "b.rs").write_text(
            "    #[wasm_bindgen_test(async)]\n    async fn three() {}\n", encoding="utf-8"
        )
        # A decoy: the attribute NAMED in a comment and in a string is not a
        # declaration. Counting mentions instead of declarations is the
        # cheapest way to build a deriver that is confidently wrong.
        (root / "sub" / "c.rs").write_text(
            "// #[wasm_bindgen_test] in a comment does not declare a test\n"
            "const S: &str = \"#[wasm_bindgen_test]\";\n",
            encoding="utf-8",
        )
        check("derivation over a known tree", expected_from_source(root), 3)

        # ...and a tree with none, which must derive 0 rather than guess.
        (root / "a.rs").unlink()
        (root / "sub" / "b.rs").unlink()
        check("derivation over a tree with no wasm tests", expected_from_source(root), 0)

    # -- the log parser -----------------------------------------------------
    check("parser on the real lane log", observed_from_log(REAL_LOG), [(17, 0), (17, 0), (0, 0)])
    check("parser on an empty log", observed_from_log(""), [])
    check(
        "parser reads the failed column",
        observed_from_log("test result: FAILED. 16 passed; 1 failed; 0 ignored"),
        [(16, 1)],
    )

    # -- the judgement, both arms, one variable at a time --------------------
    # GREEN: the real lane, against the real expectation.
    check("the real lane at its real count", judge(17, [(17, 0), (17, 0), (0, 0)]), [])

    # GREEN control: adding a test binary that carries no wasm test must NOT
    # red the lane. A gate that reds on an unrelated change gets disabled.
    check(
        "a new zero-test binary appears",
        judge(17, [(17, 0), (17, 0), (0, 0), (0, 0)]),
        [],
    )

    # GREEN control: the count moving UP on BOTH sides together -- a test was
    # added -- must stay green with no edit to this file. This is the whole
    # argument for deriving rather than pinning.
    check("a test is added to the crate", judge(18, [(18, 0), (18, 0), (0, 0)]), [])

    def reds(name: str, expected: int, observed: list[tuple[int, int]]) -> None:
        if not judge(expected, observed):
            failures.append(f"  {name}: expected a REFUSAL, got a clean pass")

    reds("the lane ran nothing at all", 17, [])
    reds("every binary reported zero", 17, [(0, 0), (0, 0)])
    reds("one binary half-ran", 17, [(17, 0), (16, 0), (0, 0)])
    reds("a test stopped compiling everywhere", 17, [(16, 0), (16, 0), (0, 0)])
    reds("a test failed", 17, [(16, 1), (17, 0)])
    reds("the observed count exceeds the source", 17, [(18, 0), (18, 0)])
    reds("the derivation itself found nothing", 0, [(17, 0)])

    # -- THE ARM THAT JUSTIFIES THE CHANGE ----------------------------------
    # One variable: the SAME log, the two predicates. The old floor passes a
    # lane in which a test silently stopped being compiled; the new one
    # refuses it. Differing outputs on a fixed input is the only evidence
    # that replacing the gate bought anything.
    half_ran = REAL_LOG.replace("17 passed", "16 passed").replace("running 17", "running 16")
    check("OLD floor on a lane that lost a test", _old_floor_predicate(half_ran), True)
    if not judge(17, observed_from_log(half_ran)):
        failures.append("  NEW gate on a lane that lost a test: expected a REFUSAL, got a pass")

    # ...and the converse, so the pair is not merely two labels on one
    # outcome: on a lane that truly ran nothing, BOTH refuse. The old gate was
    # not useless, it was blind to one class, and saying so precisely is the
    # difference between a finding and a slogan.
    check("OLD floor on a lane that ran nothing", _old_floor_predicate("no summary here"), False)
    if not judge(17, observed_from_log("no summary here")):
        failures.append("  NEW gate on a lane that ran nothing: expected a REFUSAL, got a pass")

    if failures:
        print("SELF-TEST FAILED:")
        for line in failures:
            print(line)
        return 1

    print("check_wasm_canvas_count self-test: OK")
    print("  derivation driven on a known tree (3, and 0), comment/string decoys rejected")
    print("  7 refusal arms, 3 clean-pass arms, and the old floor driven on the same")
    print("  fixture to show what the replacement buys (it passes a 16-of-17 lane)")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--log", required=True, help="the lane's captured output")
    ap.add_argument(
        "--crate",
        default="jas_dioxus",
        help="crate directory whose src/ declares the wasm tests",
    )
    args = ap.parse_args()

    root = pathlib.Path(__file__).resolve().parent.parent
    crate_src = (root / args.crate / "src").resolve()
    if not crate_src.is_dir():
        print(f"FAIL: no such crate source directory: {crate_src}", file=sys.stderr)
        return 1

    log_path = pathlib.Path(args.log)
    if not log_path.is_file():
        print(f"FAIL: no such log: {log_path}", file=sys.stderr)
        return 1

    expected = expected_from_source(crate_src)
    observed = observed_from_log(log_path.read_text(encoding="utf-8", errors="replace"))
    problems = judge(expected, observed)

    if problems:
        print("FAIL: the wasm-canvas lane's verdict is not trustworthy.", file=sys.stderr)
        for p in problems:
            print(f"       - {p}", file=sys.stderr)
        print(
            f"       source declares {expected}; binaries reported "
            f"{[p for p, _ in observed] or 'nothing'}.",
            file=sys.stderr,
        )
        return 1

    ran = [p for p, _ in observed if p > 0]
    print(
        f"canvas lane ran {expected} test(s) in a real browser, "
        f"in {len(ran)} test binary/binaries -- matching the "
        f"{expected} `#[wasm_bindgen_test]` the crate declares."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
