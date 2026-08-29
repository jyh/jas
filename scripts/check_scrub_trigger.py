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


PR_EVENTS = ("pull_request", "pull_request_target")


def pr_triggers(on: object) -> dict[str, object]:
    """{event: its value} for every PR event in `on`, in any spelling.

    Returns {} when nothing here judges a pull request.
    """
    if isinstance(on, str):
        return {on: None} if on in PR_EVENTS else {}
    if isinstance(on, list):
        return {e: None for e in on if e in PR_EVENTS}
    if not isinstance(on, dict):
        raise Unresolvable(f"unrecognised `on:` shape: {type(on).__name__}")
    return {e: on[e] for e in PR_EVENTS if e in on}


def pr_base_filter(event: str, value: object) -> str | None:
    """The reason this PR trigger is base-filtered, or None if it is not.

    ⛔ THE ASYMMETRY IS THE WHOLE POINT. For `push`, `branches:` filters the ref
    being pushed. For `pull_request` IT FILTERS THE **BASE** BRANCH -- so
    `branches: [main]` does not mean "PRs whose changes are on main", it means
    "PRs INTO main", and a PR stacked on any other branch never matches. The
    workflow then does not run AT ALL, contributes no checks, and the PR shows
    green from whatever sibling workflow has no such filter. Nothing anywhere
    says the suite was absent.
    """
    if value is None:
        return None
    if not isinstance(value, dict):
        raise Unresolvable(f"unrecognised `on.{event}` shape: {type(value).__name__}")
    if "branches-ignore" in value:
        # An ignore-list is a base filter by another name, and deciding whether
        # it excludes a base anyone will stack on is exactly the guess this
        # refuses. Same doctrine as the push rule.
        raise Unresolvable(f"`on.{event}.branches-ignore` cannot be decided here")
    branches = value.get("branches")
    if branches is None:
        return None
    if not isinstance(branches, list):
        raise Unresolvable(f"unrecognised `on.{event}.branches` shape: {branches!r}")
    if "**" in branches:
        return None
    return (f"`on.{event}.branches` is {branches!r} -- that filters the BASE "
            f"branch, so a PR stacked on any other base never runs this "
            f"workflow and its absence is invisible on the PR")


def scan_pr_filters(docs: dict[str, dict]) -> list[str]:
    """Findings for the rule: no workflow that judges a PR may base-filter it.

    ⛔ NOT REACHABILITY THIS TIME -- EVERY PR WORKFLOW IS HELD TO IT. The push
    rule above asks whether SOME path reaches the trailer gate, because one
    reaching path is enough to close that hole. This rule is the opposite
    shape: the workflow that goes dark is the one nobody misses, and a clean
    sibling is precisely what hides it. Absorbing a filtered workflow into a
    sibling's green would reproduce the defect inside the gate written to
    prevent it.
    """
    findings: list[str] = []
    refusals: list[str] = []
    judging: list[str] = []

    for name, doc in sorted(docs.items()):
        if not isinstance(doc, dict):
            refusals.append(f"{name}: not a mapping")
            continue
        # YAML 1.1 resolves an unquoted `on:` to the boolean True; read both.
        on = doc.get("on", doc.get(True))
        try:
            events = pr_triggers(on)
        except Unresolvable as exc:
            refusals.append(f"{name}: REFUSING to guess -- {exc}")
            continue
        for event, value in sorted(events.items()):
            judging.append(f"{name}:{event}")
            try:
                why = pr_base_filter(event, value)
            except Unresolvable as exc:
                refusals.append(f"{name}: REFUSING to guess -- {exc}")
                continue
            if why:
                findings.append(f"{name}: {why}")

    # ANTI-VACUITY, and it is not ceremony. This rule's natural output on a
    # tree it has no opinion about is [], which is byte-identical to the output
    # on a tree it has approved. A repo where NOTHING triggers on a pull
    # request is not a repo with no PR problem -- it is the same hole in its
    # limiting case: a PR that no workflow judges, showing whatever checks the
    # push lane happens to leave behind.
    if not judging and not refusals:
        return ["NO workflow triggers on a pull request -- nothing judges a PR, "
                "which is the condition this rule exists to make loud"]
    return refusals + findings


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

    # ------------------------------------------------------------------
    # (h) ⛔ THE SECOND RULE: NO WORKFLOW THAT JUDGES A PR MAY CARRY A BASE
    #     FILTER. For `pull_request`, `branches:` matches the BASE branch, so a
    #     PR STACKED ON ANOTHER BRANCH never matches `[main]` and the workflow
    #     silently does not run -- while the PR still shows GREEN from whatever
    #     sibling workflow has no such filter. Measured here 2026-08-28 on two
    #     stacked PRs: 4/4 checks green, all four of them hook gates, ZERO test
    #     jobs. A STACKED PR WAS INDISTINGUISHABLE FROM A TESTED ONE.
    #     Fixed in the workflow by #48; this is the gate that holds it down,
    #     because a fix with no gate is remembering.
    # ------------------------------------------------------------------

    # (h1) THE EMPTY SET FIRST, again. A rule that examines nothing returns an
    #      empty finding list, which is indistinguishable from a clean tree.
    if not scan_pr_filters({}):
        failures.append("a tree where NOTHING judges a PR must be FATAL, not green")

    # (h2) THE HISTORICAL DEFECT, planted verbatim -- test.yml as it stood.
    dark = {"test.yml": {"on": {"push": {"branches": ["main"]},
                                "pull_request": {"branches": ["main"]}},
                         "jobs": {"j": good_job}}}
    found = scan_pr_filters(dark)
    if not found or not any("base" in f for f in found):
        failures.append(f"`pull_request: branches: [main]` must be caught, got {found}")

    # (h3) The repaired shape must pass, in every spelling Actions accepts --
    #      and the `push` filter must survive, since removing it would run the
    #      whole matrix on every push to every branch.
    for label, on in [
        ("pull_request: null", {"push": {"branches": ["main"]}, "pull_request": None}),
        ("branches: ['**']", {"pull_request": {"branches": ["**"]}}),
        ("list form", ["push", "pull_request"]),
        ("types only", {"pull_request": {"types": ["opened", "synchronize"]}}),
    ]:
        ok = {"w.yml": {"on": on, "jobs": {"j": good_job}}}
        if scan_pr_filters(ok):
            failures.append(f"the repaired shape ({label}) must pass, got {scan_pr_filters(ok)}")

    # (h4) `pull_request_target` carries the same trap and more privilege.
    tgt = {"w.yml": {"on": {"pull_request_target": {"branches": ["main"]}},
                     "jobs": {"j": good_job}}}
    if not scan_pr_filters(tgt):
        failures.append("`pull_request_target` must be held to the same rule")

    # (h5) A workflow with NO pull_request trigger is not judged by this rule --
    #      but it also cannot satisfy it, which (h1) is what makes fatal.
    push_only = {"w.yml": {"on": {"push": None}, "jobs": {"j": good_job}}}
    if not scan_pr_filters(push_only):
        failures.append("a tree with no PR-judging workflow at all must be caught")

    # (h6) ...and one clean PR workflow makes the tree sound even beside a
    #      push-only sibling. Reachability, not exclusivity -- same doctrine as
    #      the rule above.
    mixed_pr = dict(push_only)
    mixed_pr["test.yml"] = {"on": {"pull_request": None}, "jobs": {"j": good_job}}
    if scan_pr_filters(mixed_pr):
        failures.append(f"a push-only sibling must not fail a judged tree, got {scan_pr_filters(mixed_pr)}")

    # (h7) ...but a FILTERED PR workflow is NOT absorbed by a clean sibling.
    #      This is the arm that matters: the dark workflow is the one whose
    #      absence nobody could see, and a sibling's green is exactly what hid
    #      it. If this passed, the rule would be decorative.
    both = {"test.yml": {"on": {"pull_request": {"branches": ["main"]}}, "jobs": {"j": good_job}},
            "scrub.yml": {"on": {"pull_request": None}, "jobs": {"j": good_job}}}
    if not scan_pr_filters(both):
        failures.append("a filtered PR workflow must NOT be absorbed by a clean sibling")

    # (h8) An undecidable filter REFUSES rather than guessing.
    murky_pr = {"w.yml": {"on": {"pull_request": {"branches-ignore": ["x"]}},
                          "jobs": {"j": good_job}}}
    if not any("REFUSING" in f for f in scan_pr_filters(murky_pr)):
        failures.append(f"an undecidable PR filter must refuse, got {scan_pr_filters(murky_pr)}")

    # (h9) YAML 1.1 `on:` -> True, here too.
    yamlish_pr = {"w.yml": {True: {"pull_request": {"branches": ["main"]}},
                            "jobs": {"j": good_job}}}
    if not scan_pr_filters(yamlish_pr):
        failures.append("the YAML-1.1 `on:`->True key must be read by the PR rule")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(
        "check_scrub_trigger SELF-TEST: OK (empty scan fatal proven FIRST, "
        "the historical `branches: [main]` shape caught, four repaired "
        "spellings accepted, shallow checkout caught, undecidable trigger "
        "refused, YAML-1.1 `on:` key read; PR base-filter rule: empty set "
        "fatal, the historical `pull_request: branches: [main]` caught, "
        "`pull_request_target` held to it, four repaired spellings accepted, "
        "not absorbed by a clean sibling, undecidable filter refused)"
    )
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()

    docs = _load()
    rc = 0
    findings = scan(docs)
    if findings:
        print(f"FAIL: the {GUARDED} gate is not reached on every pushed branch.")
        for f in findings:
            print(f"  {f}")
        print()
        print("A gate that does not run is not a guard. Give the workflow that "
              "invokes it an unfiltered `on.push`.")
        rc = 1

    # The two rules are REPORTED SEPARATELY AND BOTH ALWAYS RUN. Returning on
    # the first failure would let one hole hide the other, and these two are
    # the same defect wearing different clothes: a gate nothing invokes, and a
    # suite no PR triggers.
    pr_findings = scan_pr_filters(docs)
    if pr_findings:
        print("FAIL: a workflow that judges a pull request carries a BASE filter.")
        for f in pr_findings:
            print(f"  {f}")
        print()
        print("For `pull_request`, `branches:` matches the BASE branch. A PR "
              "stacked on another branch never matches it, the workflow does "
              "not run, and the PR still shows green from its siblings -- a "
              "stacked PR indistinguishable from a tested one. Drop the "
              "filter (or use `**`); keep the one on `push` if you need it.")
        rc = 1
    if rc:
        return rc
    print(f"check_scrub_trigger: OK ({len(docs)} workflow file(s) scanned; "
          f"{GUARDED} runs on every pushed branch with full history; "
          f"no PR-judging workflow carries a base filter)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
