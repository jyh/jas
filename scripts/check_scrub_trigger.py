#!/usr/bin/env python3
"""The session-trailer gate must run on EVERY pushed branch, not just main.

WHY THIS EXISTS
---------------
The 2026-07-22 history rewrite removed chat-service session URLs from this
repository. `scripts/check_commit_trailers.py` exists so they cannot come back,
and that gate is sound: its self-test proves it fails on an empty scan and
catches both forbidden shapes, and run against the two commits that carried
them it reports both.

It nevertheless did not stop them. The gate was wired into a workflow whose
trigger read

    on:
      push:
        branches: [main]

so a branch pushed to origin WITHOUT a pull request targeting main never ran it.
Two such branches reached the public remote carrying session URLs. One predated
the gate; the other was pushed after it and would still not have triggered it.

The gate was never wrong. Its TRIGGER was, and a trigger is invisible to every
test the gate has, because the gate cannot see whether anything invoked it.

So this check does not re-test the trailer rule. It asserts the property the
trailer gate's own tests structurally cannot: that the gate is REACHED on every
ref a leak can arrive on.

WHAT IT ASSERTS
---------------
1. At least one workflow actually invokes the trailer gate. A tree where
   nothing runs it is a FAILURE here, not a vacuous pass.
2. At least one job invoking it sits in a workflow whose `on.push` carries NO
   branch filter, AND checks out with `fetch-depth: 0`. Both in the SAME job:
   an unfiltered trigger that hands the gate a truncated history is not a
   guard, and a full checkout under a filtered trigger is not reached.

REACHABILITY, NOT EXCLUSIVITY. Other jobs may invoke the gate under narrower
triggers -- the Windows lane does, as part of running every gate on both
platform families -- and that is belt-and-braces, not a defect. What this
asserts is that SOME path reaches the gate on every pushed branch.

WHAT IT DOES NOT COVER
----------------------
* It reads workflow YAML statically. It cannot see a `paths:` filter combined
  with a matrix, or a trigger supplied by a reusable workflow, and it REFUSES
  rather than guessing -- guessing is the failure mode that produced the hole.
* It asserts the gate is INVOKED, not that its arguments are sane. A step that
  runs the gate with a range that scans nothing passes here; the gate's own
  fail-closed empty-scan contract is what covers that.
* It says nothing about tags, or about pushes to forks. A fork's pushes run
  under the fork's own Actions settings and no configuration here reaches them.
"""

from __future__ import annotations

import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"

# The gate whose reachability this file guards. Derived as a path so a rename
# breaks this check loudly instead of leaving it watching a file that is gone.
GUARDED = "check_commit_trailers.py"


class Unresolvable(Exception):
    """The YAML cannot be decided statically. Refuse; never guess."""


def _steps(job: dict) -> list[dict]:
    steps = job.get("steps") or []
    return [s for s in steps if isinstance(s, dict)]


def invokes_guard(job: dict) -> bool:
    """True iff any step in `job` runs the guarded gate."""
    for step in _steps(job):
        run = step.get("run")
        if isinstance(run, str) and GUARDED in run:
            return True
    return False


def checkout_is_full(job: dict) -> bool:
    """True iff the job's checkout asks for the whole history."""
    for step in _steps(job):
        uses = step.get("uses")
        if not isinstance(uses, str) or not uses.startswith("actions/checkout"):
            continue
        with_ = step.get("with") or {}
        # `fetch-depth: 0` is YAML int 0; a string "0" is equally valid to
        # Actions, so accept both rather than being clever about the type.
        if str(with_.get("fetch-depth")) == "0":
            return True
    return False


def push_is_unfiltered(on: object) -> bool:
    """True iff `on` triggers on a push to ANY branch.

    Raises Unresolvable when the shape is one this checker cannot decide.
    """
    # `on: push` (a bare string) and `on: [push, ...]` both mean every branch.
    if isinstance(on, str):
        return on == "push"
    if isinstance(on, list):
        return "push" in on
    if not isinstance(on, dict):
        raise Unresolvable(f"unrecognised `on:` shape: {type(on).__name__}")

    if "push" not in on:
        return False
    push = on["push"]
    # `push:` with an empty value means every branch.
    if push is None:
        return True
    if not isinstance(push, dict):
        raise Unresolvable(f"unrecognised `on.push` shape: {type(push).__name__}")
    if "branches-ignore" in push:
        # An ignore-list is a filter by another name, and deciding whether it
        # excludes anything that matters is exactly the guess this refuses.
        raise Unresolvable("`on.push.branches-ignore` cannot be decided here")
    branches = push.get("branches")
    if branches is None:
        return True
    if not isinstance(branches, list):
        raise Unresolvable(f"unrecognised `on.push.branches` shape: {branches!r}")
    # `**` matches every branch name, including ones with slashes.
    return "**" in branches


def scan(docs: dict[str, dict]) -> list[str]:
    """Findings for a mapping of workflow-name -> parsed YAML.

    Empty when SOME job invoking the guard is reached on every pushed branch
    with full history. Every invoking job that falls short is reported as a
    near-miss, so a failure names what to change rather than only what is wrong.
    """
    reaching: list[str] = []
    near_misses: list[str] = []
    refusals: list[str] = []
    invoking: list[str] = []

    for name, doc in sorted(docs.items()):
        if not isinstance(doc, dict):
            refusals.append(f"{name}: not a mapping")
            continue
        jobs = doc.get("jobs") or {}
        # PyYAML resolves an unquoted `on:` key to the boolean True, because
        # YAML 1.1 says so. Accept both spellings rather than depending on how
        # the file happens to quote it.
        on = doc.get("on", doc.get(True))
        for job_name, job in sorted(jobs.items()):
            if not isinstance(job, dict) or not invokes_guard(job):
                continue
            where = f"{name}:{job_name}"
            invoking.append(where)
            try:
                unfiltered = push_is_unfiltered(on)
            except Unresolvable as exc:
                refusals.append(f"{where}: REFUSING to guess -- {exc}")
                continue
            full = checkout_is_full(job)
            if unfiltered and full:
                reaching.append(where)
            elif not unfiltered:
                near_misses.append(
                    f"{where}: workflow `on.push` is filtered ({on!r}) -- a "
                    f"branch pushed outside that filter is never scanned here"
                )
            else:
                near_misses.append(
                    f"{where}: unfiltered trigger but no `fetch-depth: 0` -- "
                    f"the gate would see a truncated history"
                )

    # ANTI-VACUITY. Nothing invoking the gate reads identically to everything
    # being in order, and that is the shape of the original defect.
    if not invoking:
        return [
            f"NO workflow job invokes {GUARDED} -- the guard is unreached, "
            f"which is the condition this check exists to make loud"
        ] + refusals

    # An undecidable trigger is never absorbed by a sibling that happens to
    # pass. Refusing is the whole point; a green built on a shrug is the
    # failure mode that produced the hole.
    if refusals:
        return refusals + near_misses

    if reaching:
        return []
    return [
        f"no job invoking {GUARDED} is reached on every pushed branch with "
        f"full history"
    ] + near_misses


def _load() -> dict[str, dict]:
    docs = {}
    for path in sorted(WORKFLOWS.glob("*.yml")) + sorted(WORKFLOWS.glob("*.yaml")):
        docs[path.name] = yaml.safe_load(path.read_text(encoding="utf-8"))
    return docs


def self_test() -> int:
    """Prove this checker FAILS before trusting any green it reports."""
    failures = []

    full_checkout = {"uses": "actions/checkout@v4", "with": {"fetch-depth": 0}}
    guard_step = {"run": f"python scripts/{GUARDED}"}
    good_job = {"steps": [full_checkout, guard_step]}

    # (a) THE EMPTY SET, FIRST. No workflows at all must not read as clean.
    if not scan({}):
        failures.append("an empty workflow set must be FATAL, not green")

    # (b) Workflows that exist but never invoke the gate must also fail.
    idle = {"w.yml": {"on": {"push": None}, "jobs": {"j": {"steps": [full_checkout]}}}}
    if not scan(idle):
        failures.append("a tree where nothing invokes the gate must be caught")

    # (c) THE HISTORICAL DEFECT, planted verbatim. This is the shape that let
    #     two branches reach the public remote unscanned.
    narrow = {"w.yml": {"on": {"push": {"branches": ["main"]}}, "jobs": {"j": good_job}}}
    found = scan(narrow)
    if not found or not any("filtered" in f for f in found):
        failures.append(f"`branches: [main]` must be caught, got {found}")

    # (d) The repaired shape must pass, in each spelling Actions accepts.
    for label, on in [
        ("push: null", {"push": None}),
        ("push: {branches: ['**']}", {"push": {"branches": ["**"]}}),
        ("bare string", "push"),
        ("list", ["push", "pull_request"]),
    ]:
        ok = {"w.yml": {"on": on, "jobs": {"j": good_job}}}
        if scan(ok):
            failures.append(f"the repaired shape ({label}) must pass, got {scan(ok)}")

    # (e) A shallow checkout must be caught even when the trigger is right.
    shallow_job = {"steps": [{"uses": "actions/checkout@v4"}, guard_step]}
    shallow = {"w.yml": {"on": {"push": None}, "jobs": {"j": shallow_job}}}
    if not scan(shallow):
        failures.append("a shallow checkout must be caught")

    # (e2) REACHABILITY, NOT EXCLUSIVITY. One reaching job makes the tree
    #      sound even when a sibling runs the gate under a narrow trigger --
    #      which is exactly this repo's shape, since the Windows lane runs
    #      every gate on both platform families.
    mixed = {
        "scrub.yml": {"on": {"push": None}, "jobs": {"j": good_job}},
        "test.yml": {"on": {"push": {"branches": ["main"]}}, "jobs": {"w": good_job}},
    }
    if scan(mixed):
        failures.append(f"a narrow sibling must not fail a reached tree, got {scan(mixed)}")

    # (e3) ...but narrow siblings ALONE are still a hole.
    only_narrow = {"test.yml": {"on": {"push": {"branches": ["main"]}}, "jobs": {"w": good_job}}}
    if not scan(only_narrow):
        failures.append("narrow-only invocation must be caught")

    # (f) An undecidable trigger must REFUSE, not pass. Guessing is how the
    #     original hole stayed invisible.
    murky = {"w.yml": {"on": {"push": {"branches-ignore": ["x"]}}, "jobs": {"j": good_job}}}
    found = scan(murky)
    if not any("REFUSING" in f for f in found):
        failures.append(f"an undecidable trigger must refuse, got {found}")

    # (f2) A refusal must not be ABSORBED by a sibling that passes. If an
    #      undecidable trigger could be shrugged off because some other job
    #      looked fine, the refusal would be decorative.
    murky_plus = dict(murky)
    murky_plus["ok.yml"] = {"on": {"push": None}, "jobs": {"j": good_job}}
    if not any("REFUSING" in f for f in scan(murky_plus)):
        failures.append("a refusal must not be absorbed by a passing sibling")

    # (g) YAML 1.1 resolves an unquoted `on:` to the boolean True. A checker
    #     that reads only the string key would report every real workflow as
    #     having no trigger -- and, since a missing trigger is not "unfiltered",
    #     would fail closed but for the WRONG reason, masking the real state.
    yamlish = {"w.yml": {True: {"push": None}, "jobs": {"j": good_job}}}
    if scan(yamlish):
        failures.append(f"the YAML-1.1 `on:`->True key must be read, got {scan(yamlish)}")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(
        "check_scrub_trigger SELF-TEST: OK (empty scan fatal proven FIRST, "
        "the historical `branches: [main]` shape caught, four repaired "
        "spellings accepted, shallow checkout caught, undecidable trigger "
        "refused, YAML-1.1 `on:` key read)"
    )
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()

    docs = _load()
    findings = scan(docs)
    if findings:
        print(f"FAIL: the {GUARDED} gate is not reached on every pushed branch.")
        for f in findings:
            print(f"  {f}")
        print()
        print("A gate that does not run is not a guard. Give the workflow that "
              "invokes it an unfiltered `on.push`.")
        return 1
    print(f"check_scrub_trigger: OK ({len(docs)} workflow file(s) scanned; "
          f"{GUARDED} runs on every pushed branch with full history)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
