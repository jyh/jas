#!/usr/bin/env python3
"""A feature lane that compiled nothing still exits 0. Prove the backend RAN.

WHY THIS EXISTS
---------------
`jas_dioxus` carries two bodies of code that no CI job had ever compiled: the
1,958-line Direct2D painter backend behind `feature = "d2d"`, and the extern "C"
surface behind `feature = "ffi"`. Putting them under CI is P2.2. This gate is the
part that keeps the new lane from lying.

THE FAILURE MODE IS NOT A RED LANE. IT IS A GREEN ONE.

`src/painter/mod.rs:281` gates the backend on `#[cfg(all(feature = "d2d",
windows))]`. So a d2d lane that runs on a non-Windows runner ENABLES THE FEATURE
AND COMPILES NONE OF THE CODE. It resolves the feature, builds the crate, runs
the suite, and exits 0 -- having built zero of the 1,958 lines the lane exists to
cover. The same shape appears whenever a cfg quietly stops holding: a runner
image change, a target rename, a `runs-on` edited in a hurry.

EVERY FIELD AN OPERATOR WOULD CHECK READS EXACTLY LIKE SUCCESS:

  * EXIT STATUS cannot see it. A vacuous lane exits 0.
  * DURATION cannot see it. Measured on this Windows box, a Smart-App-Control
    block produced a build-only run -- zero tests executed -- in 81s, which is
    FASTER than a passing run. A duration budget would have published that as an
    improvement.
  * THE TEST TOTAL cannot see it. A d2d lane on a non-Windows runner never
    builds the 41 backend tests, so it prints the IDENTICAL baseline count.
    Nothing sums wrong.

A NAMED TEST is immune to all three -- but only if the guard reads the right
stream.

GREP THE RUNNER'S STDOUT, NEVER THE SOURCE TREE
-----------------------------------------------
The source is checked out on every platform; only the COMPILATION is gated. So a
guard written as "does this test name appear in the repo" passes on Linux, macOS
and Windows alike -- INCLUDING ON THE VACUOUS LANE. That guard would be a green
tick over precisely the failure it exists to detect: the vacuity class reproduced
inside its own detector.

This gate therefore reads a LOG CAPTURED FROM A REAL RUN and matches the line
that only an executed test binary can emit:

    test painter::direct2d::painter::tests::fill_rect_lands_opaque_red_inside_and_nothing_outside ... ok

It additionally requires a `test result:` summary line, which no source file
produces, so a log that is not a runner stream is refused rather than searched.

ASSERT PRESENCE, NEVER A COUNT
------------------------------
Verified character-for-character against real cargo stdout on this box: the d2d
anchor appears TWICE under a full default `cargo test` and ONCE under
`--no-default-features --features d2d,ffi`, because `src/main.rs` re-declares the
module tree instead of importing the lib, so `painter` compiles into both the lib
and the bin target -- while `ffi` appears ONCE in every configuration, because
`main.rs` has no `mod ffi`. Same repository, same run, two different
multiplicities.

MULTIPLICITY IS A PROPERTY OF THE MODULE'S POSITION IN THE TWO SOURCE TREES --
not of tests in general, and not stable per feature. So a `-eq 1` assertion fails
on a WORKING lane, and a `-eq 2` assertion generalised from d2d fails on ffi.
Either one is a red lane over a green build, which is how a gate gets disabled by
whoever is on call. Presence needs neither number. The observed count is PRINTED
as a note and deliberately NOT asserted.

WHAT IT ASSERTS
---------------
For a named PROFILE:

1. The log exists, is non-empty, and is a cargo-test stream (a `test result:`
   summary line is present). Anything else REFUSES -- absent is never `skip`.
2. Every anchor declared for the profile appears as an EXECUTED, PASSING test
   line. `... FAILED` and `... ignored` are both rejected: a test that did not
   run is the condition this gate exists to catch.
3. The profile's own declaration is not vacuous -- it has anchors, every anchor
   carries a reason, and each feature the profile claims to cover contributes at
   least one anchor whose module path proves it. An anchor list swapped for a
   test that runs in every configuration reds the DECLARATION, without this gate
   ever reading the source tree.

WHAT IT DOES NOT COVER
----------------------
* It does not read the source tree, ON PURPOSE (see above). A renamed test
  therefore reds here as "absent from the run output" rather than as "renamed".
  That message is less specific and the trade is deliberate: a source-reading
  variant of this gate passes on the vacuous lane it exists to catch.
* It does not invoke cargo. A checker that built its own evidence would be this
  repo's finding #25 one level down -- a driver invoking a feature set nobody
  pre-built, compiling inside its own timeout. The lane's cargo step produces the
  log; this gate only reads it.
* It does not assert the lane is complete. It asserts the lane is not EMPTY.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# The lanes this gate adjudicates. A profile is DATA with an argument attached,
# in the same posture as checker_lane_registry.json: adding or dropping coverage
# is then a reviewable edit with a sentence, not an emergent consequence of an
# edit to CI.
#
# `features` names what the profile claims to cover, and each entry maps to the
# module prefix that PROVES it. That mapping is what makes the anti-vacuity floor
# structural: an anchor swapped for a test that runs in every configuration no
# longer matches its prefix, and the declaration reds.
PROFILES: dict[str, dict] = {
    "windows-d2d-ffi": {
        "invocation": (
            "cargo test --no-default-features --features d2d,ffi "
            "(in jas_dioxus/, on a Windows runner)"
        ),
        "reason": (
            "The only configuration in which the Direct2D backend compiles at "
            "all: painter/mod.rs:281 is #[cfg(all(feature = \"d2d\", windows))], "
            "so this lane on any other platform builds none of the 1,958 lines "
            "it is named for and still exits 0. --no-default-features is "
            "deliberate -- it drops the dioxus/wasm dependency graph the backend "
            "does not need, and the `web` half is already covered by the "
            "`windows` job's own `cargo test` step."
        ),
        "features": {"d2d": "painter::direct2d::", "ffi": "ffi::"},
        "anchors": {
            "painter::direct2d::painter::tests::"
            "fill_rect_lands_opaque_red_inside_and_nothing_outside": (
                "Exercises the backend's device, brush and geometry path in one "
                "assertion -- it cannot pass without real Direct2D objects, so "
                "it cannot be satisfied by a lane that compiled the module out."
            ),
            "ffi::tests::the_five_frozen_classes_map_by_position": (
                "The extern \"C\" surface's frozen error contract, whose whole "
                "cost lands on a native shell OUTSIDE this repo. `ffi` is "
                "lib-only (src/main.rs declares no `mod ffi`), so this anchor "
                "also pins the asymmetry that makes counting the wrong test."
            ),
        },
    },
    "ffi-second-family": {
        "invocation": (
            "cargo test --no-default-features --features ffi "
            "(--manifest-path jas_dioxus/Cargo.toml, on a non-Windows runner)"
        ),
        "reason": (
            "The FFI surface carries NO platform cfg -- unlike d2d it compiles "
            "everywhere -- so watching it on Windows alone would be watching it "
            "on one platform family by accident rather than by necessity, which "
            "is the hole check_lane_coverage.py exists to forbid one level up. "
            "This profile is what lets the same gate run on both families "
            "honestly, rather than taking an EXEMPT row for a script that had no "
            "platform reason to be Windows-only."
        ),
        "features": {"ffi": "ffi::"},
        "anchors": {
            "ffi::tests::the_five_frozen_classes_map_by_position": (
                "The same frozen contract as the Windows profile, on the other "
                "platform family: a divergence in the extern \"C\" surface "
                "between platforms is exactly what a single-family lane cannot "
                "see."
            ),
        },
    },
}

# A test binary prints this and no source file does. Its presence is what makes
# "this is a runner stream" a checked premise rather than an assumption.
RESULT_SUMMARY = re.compile(r"^test result: (?:ok|FAILED)\.", re.MULTILINE)

# Anti-vacuity floor on the declaration itself. A profile with no anchors asserts
# nothing and reports success; that is the same class this gate exists to catch,
# one level up.
MIN_ANCHORS = 1


def executed_ok(log: str, name: str) -> int:
    """How many times `name` appears as an EXECUTED, PASSING test line.

    Returned as a count for REPORTING only -- callers assert `> 0`. See the
    module docstring: the count is not stable across invocations, and asserting
    it reds a working lane.
    """
    # `\r` in the trailing class, not decoration: the Windows lane tees this log
    # through bash, and a CRLF capture would otherwise fail to match a line that
    # is plainly there -- a red lane over a green build, from a line ending. The
    # self-test's case (j) is what caught it, on the first run of this file.
    pattern = re.compile(
        r"^test[ \t]+" + re.escape(name) + r"[ \t]+\.\.\.[ \t]+ok[ \t\r]*$",
        re.MULTILINE,
    )
    return len(pattern.findall(log))


def mentioned(log: str, name: str) -> bool:
    """True iff the bare name appears anywhere at all.

    Used only to tell two failures apart in the REPORT: a lane that built nothing
    versus a lane whose test ran and did not pass. The verdict never depends on
    it -- a bare name is exactly the evidence this gate refuses to accept.
    """
    return name in log


def declaration_findings(profile_name: str) -> list[str]:
    """Findings about the PROFILE, before any log is read."""
    findings: list[str] = []
    profile = PROFILES.get(profile_name)
    if profile is None:
        known = ", ".join(sorted(PROFILES))
        return [f"unknown profile {profile_name!r} -- declared profiles: {known}"]

    anchors = profile.get("anchors") or {}
    if len(anchors) < MIN_ANCHORS:
        findings.append(
            f"profile {profile_name!r} declares {len(anchors)} anchor(s), floor "
            f"is {MIN_ANCHORS} -- a profile with no anchor asserts nothing and "
            f"would report success on an empty lane"
        )
    for name, why in anchors.items():
        if not isinstance(why, str) or not why.strip():
            findings.append(
                f"profile {profile_name!r}: anchor {name!r} carries no reason -- "
                f"an anchor without an argument is how a lane's coverage becomes "
                f"folklore"
            )

    # THE STRUCTURAL HALF. Each feature the profile claims must be proved by an
    # anchor whose module path could only have compiled under that feature.
    for feature, prefix in (profile.get("features") or {}).items():
        if not any(name.startswith(prefix) for name in anchors):
            findings.append(
                f"profile {profile_name!r} claims to cover feature {feature!r} "
                f"but declares no anchor under {prefix!r} -- an anchor that runs "
                f"in every configuration proves nothing about this one"
            )
    return findings


def log_findings(profile_name: str, log: str, label: str) -> list[str]:
    """Findings about the RUN, given a profile whose declaration is sound."""
    findings: list[str] = []
    profile = PROFILES[profile_name]

    if not log.strip():
        return [
            f"{label} is empty -- a lane that produced no output produced no "
            f"evidence, and absent evidence is RED, never a skip"
        ]
    if not RESULT_SUMMARY.search(log):
        return [
            f"{label} carries no `test result:` summary line, so it is not a "
            f"cargo-test stream. This gate reads the RUNNER'S STDOUT by design; "
            f"pointed at anything else -- a source file, a build log, a truncated "
            f"capture -- it refuses rather than searching it"
        ]

    for name in profile["anchors"]:
        if executed_ok(log, name):
            continue
        if mentioned(log, name):
            findings.append(
                f"{name}\n"
                f"      appears in {label} but NOT as a passing test line. The "
                f"test was built and did not pass (`... FAILED`), was skipped "
                f"(`... ignored`), or the name occurs only in prose. A bare name "
                f"is not evidence that anything executed."
            )
        else:
            findings.append(
                f"{name}\n"
                f"      is ABSENT from {label}. The lane built none of the code "
                f"this anchor belongs to. Its exit status, its duration and its "
                f"test total all read exactly like success."
            )
    return findings


def self_test() -> int:
    """Prove this checker FAILS before trusting any green it reports."""
    failures: list[str] = []
    profile = "windows-d2d-ffi"
    d2d, ffi = list(PROFILES[profile]["anchors"])

    def run(log: str) -> list[str]:
        return log_findings(profile, log, "<self-test log>")

    summary = "\ntest result: ok. 2189 passed; 0 failed; 16 ignored\n"
    good = f"test {d2d} ... ok\ntest {ffi} ... ok\n" + summary

    # (a) THE VACUOUS LANE, FIRST -- the whole reason this file exists. A run
    #     that passed thousands of tests without building the backend must RED.
    vacuous = "test geometry::tests::something_else ... ok\n" + summary
    found = run(vacuous)
    if len(found) != 2:
        failures.append(
            f"a lane that built neither backend must red on BOTH anchors, got "
            f"{len(found)}"
        )
    if not any("is ABSENT" in f for f in found):
        failures.append("the vacuous lane's finding must say the anchor is ABSENT")

    # (b) The real shape passes. Guards against a gate that reds on everything.
    if run(good):
        failures.append(f"a real passing run must pass, got {run(good)}")

    # (c) THE SOURCE-TREE MUTATION -- the vacuity class reproduced inside the
    #     detector. The names are present, as they are in every checkout on every
    #     platform, but nothing executed them.
    short = d2d.rsplit("::", 1)[-1]
    as_source = f"    fn {short}() {{\n// see {d2d}\n// see {ffi}\n" + summary
    found = run(as_source)
    if len(found) != 2:
        failures.append(
            "a log that MENTIONS both names without running them must red on "
            "both -- this is the mutation that makes 'grep the source' wrong"
        )
    if not any("NOT as a passing test line" in f for f in found):
        failures.append(
            "the mention-only finding must say why a bare name is not evidence"
        )

    # (d) MULTIPLICITY MUST NOT DECIDE THE VERDICT. The d2d anchor really does
    #     appear twice under a default `cargo test` and once under
    #     --no-default-features; a count assertion would red a working lane.
    twice = f"test {d2d} ... ok\n" + good
    if run(twice):
        failures.append(f"a doubled anchor must PASS, got {run(twice)}")
    if executed_ok(twice, d2d) != 2:
        failures.append("the reporting count must still observe the doubling")

    # (e) A test that ran and FAILED is not a test that ran.
    failed = good.replace(f"test {d2d} ... ok", f"test {d2d} ... FAILED")
    if not any("NOT as a passing test line" in f for f in run(failed)):
        failures.append("`... FAILED` must red")

    # (f) ...and neither is one that was ignored. This is the subtler half: an
    #     ignored test is present in the output and executed nothing.
    ignored = good.replace(f"test {d2d} ... ok", f"test {d2d} ... ignored")
    if not any("NOT as a passing test line" in f for f in run(ignored)):
        failures.append("`... ignored` must red")

    # (g) A near-miss name must not satisfy an anchor. Anchoring the pattern at
    #     both ends is what makes this hold.
    near = good.replace(f"test {d2d} ... ok", f"test {d2d}_extra ... ok")
    if executed_ok(near, d2d) != 0:
        failures.append("a longer name must not satisfy the anchor")
    if not run(near):
        failures.append("a lane running only a near-miss name must red")

    # (h) NOT A RUNNER STREAM. Test lines with no summary is what a truncated
    #     capture looks like, and it must refuse rather than search.
    truncated = good.replace(summary, "\n")
    if not any("not a cargo-test stream" in f for f in run(truncated)):
        failures.append("a log with no `test result:` summary must refuse")

    # (i) An empty log is refused, not treated as nothing-to-check.
    if not any("is empty" in f for f in run("")):
        failures.append("an empty log must red")

    # (j) LINE ENDINGS MUST NOT DECIDE THE VERDICT. The Windows lane tees this
    #     log through bash; a future runner image could hand back CRLF.
    if run(good.replace("\n", "\r\n")):
        failures.append("a CRLF log must not change the verdict")

    # (k) THE DECLARATION'S OWN VACUITY, in three shapes.
    saved = PROFILES[profile]["anchors"]
    try:
        PROFILES[profile]["anchors"] = {}
        if not any("floor is" in f for f in declaration_findings(profile)):
            failures.append("a profile with no anchors must red")
        PROFILES[profile]["anchors"] = {ffi: "only the portable half"}
        if not any("'d2d'" in f for f in declaration_findings(profile)):
            failures.append(
                "a profile claiming d2d with only an ffi anchor must red -- that "
                "is an anchor list swapped for one that runs anywhere"
            )
        PROFILES[profile]["anchors"] = {d2d: "", ffi: "fine"}
        if not any("carries no reason" in f for f in declaration_findings(profile)):
            failures.append("an anchor with no reason must red")
    finally:
        PROFILES[profile]["anchors"] = saved

    # (l) An unknown profile refuses instead of passing over nothing.
    if not any("unknown profile" in f for f in declaration_findings("no-such-lane")):
        failures.append("an unknown profile must red")

    # (m) Every profile as COMMITTED must be sound, not merely the one exercised
    #     above -- a second profile added without an anchor would otherwise ship
    #     green and assert nothing.
    for name in PROFILES:
        found = declaration_findings(name)
        if found:
            failures.append(f"committed profile {name!r} is unsound: {found}")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(
        "check_native_backend_lane SELF-TEST: OK (vacuous lane proven RED FIRST, "
        "mention-without-execution refused, doubled anchor proven to PASS, FAILED "
        "and ignored both rejected, near-miss name rejected, non-stream and empty "
        "logs refused, CRLF proven not to decide the verdict, and the "
        "declaration's own vacuity caught in three shapes)"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prove a feature lane executed the backend it is named for."
    )
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--profile", help=f"one of: {', '.join(sorted(PROFILES))}")
    parser.add_argument("--log", help="the log captured from the lane's cargo run")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    if not args.profile or not args.log:
        print("FAIL: --profile and --log are both required.")
        print(f"  declared profiles: {', '.join(sorted(PROFILES))}")
        return 1

    findings = declaration_findings(args.profile)
    if findings:
        print("FAIL: the lane's declaration does not assert what it claims.")
        for f in findings:
            print(f"  {f}")
        return 1

    path = pathlib.Path(args.log)
    if not path.is_absolute():
        path = ROOT / path
    label = args.log
    if not path.exists():
        print("FAIL: the lane's evidence could not be read.")
        print(f"  {label} does not exist. The cargo step is what produces it; a")
        print("  missing log means the lane did not run, and a lane that did not")
        print("  run is RED, never a skip.")
        return 1

    # errors="replace" is deliberate: this file is a CAPTURED RUNNER STREAM, not
    # repo content. A stray byte in a panic message must not turn this gate into
    # a UnicodeDecodeError, which would read as a different failure than the one
    # that happened. The encoding is still stated explicitly, per
    # check_encoding_hygiene.py -- the locale codec here is cp1252.
    log = path.read_text(encoding="utf-8", errors="replace")

    findings = log_findings(args.profile, log, label)
    profile = PROFILES[args.profile]

    if findings:
        print("FAIL: this lane did not run the backend it is named for.")
        print(f"  profile   : {args.profile}")
        print(f"  invocation: {profile['invocation']}")
        for f in findings:
            print(f"  MISSING {f}")
        print()
        print("A lane in this state exits 0, finishes in a plausible time, and")
        print("prints the baseline test total. Nothing an operator would check")
        print("distinguishes it from success, which is why this gate exists.")
        print("If a test was renamed, update its anchor in PROFILES and say why")
        print("the replacement could not compile without the feature.")
        return 1

    print(f"check_native_backend_lane: OK ({args.profile})")
    for name in profile["anchors"]:
        # PIN THE UNIT. The count is EXECUTIONS of one test, which is not the
        # number of tests and is not stable across invocations -- printed so the
        # log carries the fact, and NOT asserted, because asserting it reds a
        # working lane the day a module's tree membership changes.
        count = executed_ok(log, name)
        print(f"  {name}\n      executed {count}x (presence asserted, count not)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
