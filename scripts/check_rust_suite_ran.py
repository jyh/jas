#!/usr/bin/env python3
"""A suite that quietly stopped running still exits 0. Prove the main Rust suite RAN.

WHY THIS EXISTS
---------------
Two lanes in this repo already carry an execution gate, and both were built after
the same discovery: a green lane is not evidence that anything ran.
`check_wasm_canvas_count.py` guards the browser canvas lane by DERIVING both
sides of a count. `check_native_backend_lane.py` guards the `d2d`/`ffi` lanes by
asserting NAMED tests appear in the runner's stdout, because "a feature lane that
compiled nothing still exits 0".

The suite those two do not cover is the largest one in the repo. `cd jas_dioxus
&& cargo test` runs ~3,000 tests and is invoked by TWO jobs, and nothing reads
its output. Measured 2026-09-06, not argued: `cargo test` on a crate containing
zero tests exits **0**. (`pytest` exits 5 on an empty collection, which is why
the Python steps in this workflow need no equivalent gate -- the tool defends
itself and `cargo` does not.)

⛔ THE FAILURE MODE IS A GREEN LANE, NOT A RED ONE, and this repo has already met
it once at the authoring end: `check_unregistered_tests.py` exists because a test
function without `#[test]` had never run while sitting between neighbours that
had. That gate answers "was this test REGISTERED". It cannot answer "did the
registered suite still RUN", which is what a `#[cfg(test)]` module dropping out
of the build looks like: the total falls, every remaining test passes, and the
step exits 0.

WHY NAMED ANCHORS AND NOT A DERIVED COUNT
-----------------------------------------
`check_wasm_canvas_count.py` derives EXPECTED from the source and is right to:
every wasm test in that crate lives under a module-level `#[cfg(all(test,
target_arch = "wasm32"))]`, so a wasm build compiles all of them or none. **That
invariant does not hold here.** The native total moves with the feature set --
measured on kenai 2026-09-06, `--features web` ran 3,066 and
`--no-default-features --features d2d,ffi` ran 2,686 -- so a single derived
EXPECTED cannot cover both invocations, and a per-invocation table of totals
would be exactly the remembered number this repo's doctrine rejects.

So this gate takes the OTHER pattern already blessed here, from
`check_native_backend_lane.py`: **a named test is immune**. An anchor either
appears in the runner's stdout as executed and passing, or it does not.

⭐ AND THE DECLARATION ITSELF IS DERIVED, which is the half that does not rot.
The anchors are chosen one per AREA -- a top-level subdirectory of
`jas_dioxus/src/` holding a plain `#[cfg(test)]` module -- and
`declaration_findings()` recomputes that set of areas FROM THE SOURCE TREE on
every run. A new area with tests, or an area that grows one, reds this gate until
it is given a witness. The coverage rule is therefore not a list someone
remembered to update; it is a question asked of the tree.

A DISAGREEMENT IN EITHER DIRECTION IS A REFUSAL. An anchor that no longer exists
in the source reds here rather than silently never matching the log -- an anchor
that cannot be found is not a satisfied anchor, and a gate that tolerates being
wrong about its own subject is worth nothing.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "jas_dioxus" / "src"

# THE AREAS THIS GATE ADJUDICATES, one anchor each. An area is a top-level
# SUBDIRECTORY of `jas_dioxus/src/`; the anchor is a test inside it that the
# runner must report as executed and passing.
#
# `prefix` is what ties an anchor to its area, in the same posture as
# `check_native_backend_lane.py`'s feature->prefix map: an anchor swapped for a
# test somewhere else no longer matches its prefix and the DECLARATION reds,
# before any log is read. Without that, "one anchor per area" degrades into
# "eleven anchors, possibly all from one module", which asserts what a single
# anchor asserts and looks eleven times stronger.
AREAS: dict[str, dict[str, str]] = {
    "algorithms": {
        "prefix": "algorithms::",
        "anchor": "algorithms::hit_test::tests::"
                  "unfilled_ellipse_marquee_inside_outline_misses_under_identity_and_none",
        "reason": "Hit testing is reached by every selection gesture in the app; "
                  "an unfilled-ellipse marquee exercises the winding path rather "
                  "than a bounding box, so it cannot pass off a stub.",
    },
    "canvas": {
        "prefix": "canvas::",
        "anchor": "canvas::render::tests::"
                  "effective_mask_transform_unlinked_returns_captured_unlink_transform",
        "reason": "The web walk's mask transform, the half no native backend "
                  "reaches. `canvas::render` is also the module the Painter port "
                  "is drawing features OUT of, so it is the one most likely to "
                  "lose a test module to an edit rather than to a deletion.",
    },
    "document": {
        "prefix": "document::",
        "anchor": "document::model::tests::"
                  "id_index_matches_rebuild_after_controller_edits_and_undo_and_resolves",
        "reason": "The id index is the structure `emit_document` rebuilds per "
                  "paint and the web walk borrows; a divergence here is invisible "
                  "in every rendered pixel until a lookup misses.",
    },
    "geometry": {
        "prefix": "geometry::",
        "anchor": "geometry::live::tests::"
                  "expand_of_a_split_compound_copies_every_other_field_to_every_ring",
        "reason": "Live geometry's field-copying law across rings -- the shape of "
                  "defect this repo has met repeatedly, where one field is "
                  "forgotten and every other field agrees.",
    },
    "interpreter": {
        "prefix": "interpreter::",
        "anchor": "interpreter::effects::tests::"
                  "artboard_duplicate_copies_every_other_field_and_leaves_the_source_alone",
        "reason": "The interpreter is the executable meaning of the spec (POLICY "
                  "§1); duplicate-and-leave-the-source-alone is a two-sided "
                  "assertion, so a half-built effect fails it.",
    },
    "painter": {
        "prefix": "painter::",
        "anchor": "painter::element_render::tests::"
                  "the_subtract_rings_are_co_oriented_and_are_read_under_the_declared_even_odd_rule",
        "reason": "`emit_element` is the renderer of record for native (A6, "
                  "ratified), and the even-odd rule is a VALUE inside a call "
                  "rather than a call -- the class a whole-op witness pass "
                  "cannot see.",
    },
    "panels": {
        "prefix": "panels::",
        "anchor": "panels::tests::every_panel_menu_predicate_read_is_published_to_the_menu_context",
        "reason": "The panel/menu contract that #119 made generic across both "
                  "ports; it asserts over EVERY predicate read, so a predicate "
                  "added without publication reds it.",
    },
    "recorder": {
        "prefix": "recorder::",
        "anchor": "recorder::core::tests::pointer_events_convert_per_event_under_pan_zoom",
        "reason": "Per-event conversion under pan/zoom -- the smallest area with "
                  "tests, and therefore the one whose disappearance moves a total "
                  "by the least and hides best.",
    },
    "surface": {
        "prefix": "surface::",
        "anchor": "surface::tests::luminance_promotion_on_a_surface_applies_the_bytes_law",
        "reason": "The bytes law behind luminance promotion, whose ClipIn "
                  "fallback repair is a STANDING NEGATIVE in this seat's bank: "
                  "an area with known open work must not go quiet.",
    },
    "tools": {
        "prefix": "tools::",
        "anchor": "tools::yaml_tool::tests::"
                  "eyedropper_parity_click_source_with_selection_copies_fill_to_target",
        "reason": "`yaml_tool` is where the generic-YAML doctrine (CLAUDE.md: "
                  "native code is discouraged) actually executes; a parity test "
                  "here covers the interpreter-driven tool path, not a native one.",
    },
    "workspace": {
        "prefix": "workspace::",
        "anchor": "workspace::app_state::character_panel_apply_tests::"
                  "a_range_tracking_edit_writes_only_the_tracking_onto_the_range",
        "reason": "`writes ONLY the tracking` is a negative assertion over the "
                  "other fields, which is what makes it a witness rather than a "
                  "smoke test.",
    },
}

# ⚠️ A NARROW SECOND GUARD, AND ITS ROLE IS NAMED SO IT DOES NOT READ AS THE
# PRIMARY ONE. The real floor on this declaration is DERIVED, in
# `declaration_findings`: an area on disk with no entry here reds, so the
# declaration cannot silently shrink while the tree stays the same. This
# constant only covers the case that rule cannot see -- a TREE that has itself
# fallen below eight areas, which would be a restructuring worth a human
# looking at rather than a gate quietly adjusting. Kept deliberately slack for
# that reason: an exact floor here would red on every ordinary refactor while
# buying nothing the derived rule does not already buy.
MIN_AREAS = 8

# A test binary prints these and no source file does. Requiring the PAIR is what
# makes "this is a runner stream" a checked premise: one `test result:` line
# alone is satisfied by a three-line hand-written file.
RESULT_SUMMARY = re.compile(r"^test result: (?:ok|FAILED)\.", re.MULTILINE)
HARNESS_BANNER = re.compile(r"^running \d+ tests?[ \t\r]*$", re.MULTILINE)


def source_areas() -> set[str]:
    """Top-level `src/` subdirectories holding a PLAIN `#[cfg(test)]` module.

    ⛔ SUBDIRECTORIES ONLY, AND THE BOUNDARY IS DELIBERATE -- there is nothing
    missing from this function. Top-level `.rs` modules are excluded because the
    set of them that COMPILES depends on the feature set: `ffi.rs` carries tests
    that exist only under `--features ffi`, so "every top-level module with
    tests" is not a well-defined obligation without evaluating cfgs, and a rule
    that demands an anchor for a module the default lane never builds reds a
    working lane. Every `src/` SUBDIRECTORY holding a plain `#[cfg(test)]`
    module IS present in the default lane -- verified 2026-09-06 against
    `cargo test --lib -- --list`, 11 of 11 areas found, 3,085 tests listed.

    Plain, not `#[cfg(all(test, ...))]`: the wasm-gated modules belong to the
    lane `check_wasm_canvas_count.py` already guards, and counting them here
    would demand an anchor no native run can satisfy.
    """
    found: set[str] = set()
    if not SRC.is_dir():
        return found
    for path in SRC.rglob("*.rs"):
        rel = path.relative_to(SRC)
        if len(rel.parts) < 2:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            if line.strip() == "#[cfg(test)]":
                found.add(rel.parts[0])
                break
    return found


def source_has_test(anchor: str) -> bool:
    """Is `anchor` still a registered test in the source?

    The last path segment is the function name; it must appear as a `fn` with a
    `#[test]` attribute somewhere under the area's directory. Deliberately not a
    full module-path resolution: this asks "does this witness still exist",
    which is the question whose wrong answer makes an anchor silently
    unmatchable in the log.
    """
    parts = anchor.split("::")
    if len(parts) < 2:
        return False
    area, fn = parts[0], parts[-1]
    area_dir = SRC / area
    if not area_dir.is_dir():
        return False
    pattern = re.compile(r"#\[test\]\s*\n\s*(?:async\s+)?fn\s+" + re.escape(fn) + r"\b")
    for path in area_dir.rglob("*.rs"):
        if pattern.search(path.read_text(encoding="utf-8", errors="replace")):
            return True
    return False


def executed_ok(log: str, anchor: str) -> bool:
    """Did the runner report `anchor` as executed and PASSING?

    `\\r` in the trailing class, not decoration: a Windows lane tees this log and
    the line arrives CRLF-terminated.
    """
    pattern = re.compile(
        r"^test " + re.escape(anchor) + r" \.\.\. ok[ \t\r]*$", re.MULTILINE
    )
    return bool(pattern.search(log))


def declaration_findings() -> list[str]:
    """Findings about the DECLARATION, before any log is read."""
    findings: list[str] = []

    if len(AREAS) < MIN_AREAS:
        findings.append(
            f"this gate declares {len(AREAS)} area(s), floor is {MIN_AREAS} -- a "
            f"declaration this thin asserts almost nothing and would report "
            f"success on a suite that had mostly stopped running"
        )

    for area, spec in AREAS.items():
        prefix = spec.get("prefix")
        anchor = spec.get("anchor")
        reason = spec.get("reason")
        if not isinstance(prefix, str) or not prefix.endswith("::"):
            findings.append(
                f"area {area!r} maps to prefix {prefix!r}, which is not a module "
                f"path ending in '::' -- a prefix that is not a module path is "
                f"matched by tests the area does not own"
            )
            continue
        if not isinstance(anchor, str) or not anchor.startswith(prefix):
            findings.append(
                f"area {area!r} declares anchor {anchor!r}, which does not start "
                f"with {prefix!r} -- an anchor outside its own area proves that "
                f"OTHER area ran, and eleven anchors from one module look eleven "
                f"times stronger than the one assertion they make"
            )
        if not isinstance(reason, str) or not reason.strip():
            findings.append(
                f"area {area!r}: anchor carries no reason -- an anchor without an "
                f"argument is how a lane's coverage becomes folklore"
            )

    # ⭐ THE DERIVED HALF, and the half that does not rot. The obligation is
    # recomputed FROM THE TREE on every run, so a new area with tests reds this
    # gate until it is given a witness. A list someone must remember to update is
    # the defect this repo has met at `swift:dropdown` and at a stale floor of 4.
    on_disk = source_areas()
    if not on_disk:
        findings.append(
            f"no `#[cfg(test)]` module found under {SRC} -- this gate examined "
            f"nothing, which is a refusal and not a pass"
        )
    for area in sorted(on_disk - set(AREAS)):
        findings.append(
            f"src/{area}/ holds a #[cfg(test)] module but no area is declared for "
            f"it -- it would run, or stop running, entirely unwatched"
        )
    for area in sorted(set(AREAS) - on_disk):
        findings.append(
            f"area {area!r} is declared but src/{area}/ holds no #[cfg(test)] "
            f"module -- a stale declaration is an excuse that outlived its "
            f"subject, and it would keep this gate green while covering nothing"
        )

    # An anchor that no longer exists cannot be matched in any log. Caught HERE,
    # against the source, so the message names a renamed test rather than
    # reporting a lane that did not run.
    for area, spec in sorted(AREAS.items()):
        anchor = spec.get("anchor")
        if isinstance(anchor, str) and area in on_disk and not source_has_test(anchor):
            findings.append(
                f"area {area!r}: anchor {anchor!r} is not a #[test] fn anywhere "
                f"under src/{area}/ -- it was renamed or deleted. Pick a new "
                f"witness and say why; an anchor that cannot be found is not a "
                f"satisfied anchor"
            )
    return findings


def log_findings(log: str, label: str) -> list[str]:
    """Findings about the RUN, given a declaration that is sound."""
    if not log.strip():
        return [
            f"{label} is empty -- a lane that produced no output produced no "
            f"evidence, and absent evidence is RED, never a skip"
        ]
    if not RESULT_SUMMARY.search(log) or not HARNESS_BANNER.search(log):
        return [
            f"{label} lacks the `running N tests` banner and `test result:` "
            f"summary a real harness run prints, so it is not a cargo-test "
            f"stream. This gate reads the RUNNER'S STDOUT by design; pointed at "
            f"a build log or a truncated capture it refuses rather than passing"
        ]
    findings: list[str] = []
    for area, spec in sorted(AREAS.items()):
        anchor = spec["anchor"]
        if not executed_ok(log, anchor):
            findings.append(
                f"area {area!r}: {anchor} is not reported as executed and passing "
                f"in {label} -- either the suite did not run it, or its "
                f"#[cfg(test)] module stopped being compiled. The total would "
                f"fall and every remaining test would still pass"
            )
    return findings


def _fake_log(anchors: list[str], banner: bool = True, summary: bool = True) -> str:
    lines = []
    if banner:
        lines.append(f"running {len(anchors)} tests")
    lines += [f"test {a} ... ok" for a in anchors]
    if summary:
        lines.append("test result: ok. %d passed; 0 failed; 0 ignored" % len(anchors))
    return "\n".join(lines) + "\n"


def self_test() -> int:
    """Drive every failure arm, and the empty-scan fatal FIRST.

    ⛔ THE EMPTY ARM LEADS BECAUSE IT IS THE ONE THAT PROVES THE INSTRUMENT CAN
    FAIL AT ALL. A self-test whose arms all pass through the same "no findings"
    path would report success for a gate whose checks had been deleted.
    """
    arms = 0
    failures: list[str] = []

    def arm(label: str, ok: bool) -> None:
        nonlocal arms
        arms += 1
        if not ok:
            failures.append(label)

    # 1. EMPTY LOG IS FATAL -- proven before anything else.
    arm("an empty log is a finding", bool(log_findings("", "the log")))
    arm("a whitespace-only log is a finding", bool(log_findings("   \n\n", "the log")))

    all_anchors = [spec["anchor"] for spec in AREAS.values()]

    # 2. POSITIVE CONTROL: a well-formed log naming every anchor is clean. If
    #    this arm ever fails, the arms below prove nothing -- they would all be
    #    passing for the wrong reason.
    arm("a complete runner log yields no findings",
        log_findings(_fake_log(all_anchors), "the log") == [])

    # 3. A log that is not a runner stream is refused, not passed.
    arm("a log with no banner is refused",
        bool(log_findings(_fake_log(all_anchors, banner=False), "the log")))
    arm("a log with no result summary is refused",
        bool(log_findings(_fake_log(all_anchors, summary=False), "the log")))

    # 4. THE ARM THIS GATE EXISTS FOR: one area stops running, everything else
    #    still passes, and the run still exits 0.
    for drop in sorted(AREAS):
        kept = [spec["anchor"] for a, spec in AREAS.items() if a != drop]
        found = log_findings(_fake_log(kept), "the log")
        arm(f"a log missing {drop!r}'s anchor is a finding",
            any(drop in f for f in found))

    # 5. A test reported as FAILING is not a test reported as passing.
    one = all_anchors[0]
    bad = _fake_log(all_anchors).replace(f"test {one} ... ok", f"test {one} ... FAILED")
    arm("an anchor reported FAILED does not satisfy its area",
        bool(log_findings(bad, "the log")))

    # 6. THE DECLARATION ARMS. The live declaration must be clean first --
    #    otherwise a mutation below could be "caught" by a pre-existing finding.
    live = declaration_findings()
    arm("the live declaration is clean", live == [])

    saved = {a: dict(spec) for a, spec in AREAS.items()}
    victim = sorted(AREAS)[0]
    try:
        AREAS[victim]["prefix"] = "algorithms"          # no trailing '::'
        arm("a prefix that is not a module path is a finding",
            any("module path" in f for f in declaration_findings()))
        AREAS[victim].update(saved[victim])

        AREAS[victim]["anchor"] = "workspace::app_state::tests::somewhere_else"
        arm("an anchor outside its own area's prefix is a finding",
            any("does not start with" in f for f in declaration_findings()))
        AREAS[victim].update(saved[victim])

        AREAS[victim]["reason"] = "   "
        arm("an anchor with no reason is a finding",
            any("no reason" in f for f in declaration_findings()))
        AREAS[victim].update(saved[victim])

        AREAS[victim]["anchor"] = f"{victim}::tests::a_test_that_does_not_exist_anywhere"
        arm("an anchor that is not a #[test] fn in the source is a finding",
            any("renamed or deleted" in f for f in declaration_findings()))
        AREAS[victim].update(saved[victim])

        removed = AREAS.pop(victim)
        arm("an on-disk area with no declaration is a finding",
            any("no area is declared" in f for f in declaration_findings()))
        AREAS[victim] = removed

        AREAS["a_directory_that_does_not_exist"] = {
            "prefix": "a_directory_that_does_not_exist::",
            "anchor": "a_directory_that_does_not_exist::tests::x",
            "reason": "self-test only",
        }
        arm("a declared area absent from the tree is a finding",
            any("stale declaration" in f for f in declaration_findings()))
        del AREAS["a_directory_that_does_not_exist"]

        kept_areas = dict(AREAS)
        AREAS.clear()
        AREAS.update({k: kept_areas[k] for k in sorted(kept_areas)[:1]})
        arm("a declaration below the area floor is a finding",
            any("floor is" in f for f in declaration_findings()))
        AREAS.clear()
        AREAS.update(kept_areas)
    finally:
        AREAS.clear()
        AREAS.update(saved)

    arm("the declaration is restored after the mutations", declaration_findings() == [])

    if failures:
        print(f"check_rust_suite_ran SELF-TEST: FAILED {len(failures)} of {arms} arm(s)")
        for f in failures:
            print(f"  ARM FAILED: {f}")
        return 1
    print(
        f"check_rust_suite_ran SELF-TEST: OK ({arms} arms driven; empty-log fatal "
        f"proven FIRST; {len(AREAS)} declared area(s) each driven as a "
        f"stopped-running mutant; every declaration failure path NAMES findings)"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prove the main Rust suite RAN, area by area."
    )
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--log", help="the cargo-test stdout to adjudicate")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    findings = declaration_findings()
    if findings:
        print("check_rust_suite_ran: REFUSED -- the declaration is unsound:")
        for f in findings:
            print(f"  {f}")
        return 1

    if not args.log:
        print("check_rust_suite_ran: REFUSED -- --log is required (or --self-test). "
              "A run with no subject is not a pass.")
        return 2

    path = pathlib.Path(args.log)
    if not path.is_file():
        print(f"check_rust_suite_ran: REFUSED -- {args.log} does not exist. "
              f"A missing log is absent evidence, which is RED, never a skip.")
        return 2

    log = path.read_text(encoding="utf-8", errors="replace")
    findings = log_findings(log, args.log)
    if findings:
        print(f"check_rust_suite_ran: FAIL -- {len(findings)} finding(s):")
        for f in findings:
            print(f"  {f}")
        return 1

    print(
        f"check_rust_suite_ran: OK ({len(AREAS)} area(s) each proved by a named "
        f"test executed and passing in {args.log}). "
        f"SCOPE: this asserts each area RAN, never how much of it ran -- a count "
        f"is unsound here because the total moves with the feature set."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
