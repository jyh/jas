#!/usr/bin/env python3
"""A gate job must fail loud. It must never be SKIPPED into silence.

WHY THIS EXISTS
---------------
`cross-language` is the blocking gate for this project's prime directive --
exact functional equivalence across the active ports. Inside itself it is one of
the most carefully defended jobs in the tree: it self-tests the lane-report rules
before trusting a summary, it passes `--require-comparisons` so a run that
performed no lane-vs-lane comparison exits non-zero instead of passing as an
oracle run, and it reconciles the geometry checkers' executed counts so a checker
lane cannot go vacuous while every other gate stays green.

Every one of those guards the same class: THE GATE RAN BUT CHECKED NOTHING.
None of them can fire if the gate never runs.

MEASURED, run 31114155047 on 5095060d (HEAD of main, 2026-08-06): the macOS
`rust` job died in cargo's own bookkeeping -- `could not parse/generate dep info
... Invalid argument (os error 22)` -- before a single test executed. Because
`cross-language` declared `needs: [rust, swift]`, it was SKIPPED. The run page
shows it as "0s", which reads as *not applicable* rather than *not checked*, and
the prime-directive gate did not run at all on that commit. An unrelated
filesystem fault on a runner silenced the one check the whole port-parity
argument rests on.

This is the third instance of one shape found in this repository in a week:
the session-trailer gate was sound and unreached (`check_scrub_trigger.py`), a
fleet watch file was faithfully maintained and read by no process, and here a
gate is fully armed and skipped. In every case the artifact was correct and
nothing consumed it.

WHAT IT ASSERTS
---------------
A job that ASSERTS a property and declares `needs:` must also declare an `if:`
that survives a dependency's failure -- `always()` or `!cancelled()`. Otherwise a
red dependency turns the assertion into a neutral skip.

A job ASSERTS if any of its steps runs something under `scripts/`. That is
derived from the job's own content, not from a list someone remembers to update:
`cross-language` runs `scripts/lane_report.py` and the equivalence drivers, while
`pages.yml`'s `deploy` runs `actions/deploy-pages` and asserts nothing.

The distinction is deliberate and it is the whole rule. A job that ACTS may
depend on its predecessor -- deploying the output of a build that failed is
wrong, and skipping is the correct behaviour there. A job that JUDGES may not,
because a judgement that does not happen is not a pass.

WHAT IT DOES NOT COVER
----------------------
* `if:` expressions are matched textually for `always()` / `!cancelled()`. A
  condition that reaches the same effect by another route is not recognised, and
  this REFUSES rather than trying to evaluate GitHub expression syntax.
* It says nothing about whether a skipped job is reported anywhere downstream. A
  required-checks configuration could catch this too; this repository has no
  branch protection (measured: `gh api repos/jyh/jas/branches/main/protection`
  -> 404), so the workflow file is the only place the property can live.
* Step-level `if:` is out of scope. A step that skips itself inside a job that
  ran is a different question from a job that never ran.
"""

from __future__ import annotations

import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"

# A step invoking anything under this directory is judging, not acting.
ASSERTS_MARKER = "scripts/"

# Conditions that survive a dependency's failure. `always()` also runs on
# cancellation; `!cancelled()` does not, and is the better default -- an operator
# who cancels a run means it.
SURVIVES = ("always()", "!cancelled()", "! cancelled()")


class Unresolvable(Exception):
    """The YAML cannot be decided statically. Refuse; never guess."""


def asserts_a_property(job: dict) -> bool:
    """True iff any step of `job` runs something under `scripts/`."""
    for step in job.get("steps") or []:
        if not isinstance(step, dict):
            continue
        run = step.get("run")
        if isinstance(run, str) and ASSERTS_MARKER in run:
            return True
    return False


def condition_survives_dependency_failure(cond: object) -> bool:
    """True iff `if:` still runs the job when a dependency failed.

    Raises Unresolvable for a condition this checker cannot decide, rather than
    guessing -- guessing is how the original hole stayed invisible.
    """
    if cond is None:
        return False
    if isinstance(cond, bool):
        # `if: true` runs unconditionally only in the sense GitHub means for
        # step conditions; for a job with needs it still respects the needs
        # result. Treat it as not surviving.
        return False
    if not isinstance(cond, str):
        raise Unresolvable(f"unrecognised `if:` shape: {type(cond).__name__}")
    text = cond.replace("${{", " ").replace("}}", " ")
    return any(marker in text for marker in SURVIVES)


def scan(docs: dict[str, dict]) -> list[str]:
    """Findings for a mapping of workflow-name -> parsed YAML."""
    findings: list[str] = []
    judged = 0

    for name, doc in sorted(docs.items()):
        if not isinstance(doc, dict):
            findings.append(f"{name}: not a mapping")
            continue
        for job_name, job in sorted((doc.get("jobs") or {}).items()):
            if not isinstance(job, dict) or not asserts_a_property(job):
                continue
            judged += 1
            needs = job.get("needs")
            if not needs:
                continue  # nothing can skip it
            try:
                survives = condition_survives_dependency_failure(job.get("if"))
            except Unresolvable as exc:
                findings.append(f"{name}:{job_name}: REFUSING to guess -- {exc}")
                continue
            if not survives:
                findings.append(
                    f"{name}:{job_name} asserts a property and declares "
                    f"needs={needs!r} with no surviving `if:` -- a failure in "
                    f"any dependency SKIPS it, and a skipped gate reads as "
                    f"'not applicable' rather than 'not checked'"
                )

    # ANTI-VACUITY. A scan that found no judging jobs reports no violations,
    # which is indistinguishable from every gate being safe.
    if judged == 0:
        findings.append(
            "NO job in any workflow runs anything under scripts/ -- either the "
            "glob is broken or the gates are gone. This is not a pass."
        )
    return findings


def _load() -> dict[str, dict]:
    docs = {}
    for path in sorted(WORKFLOWS.glob("*.yml")) + sorted(WORKFLOWS.glob("*.yaml")):
        docs[path.name] = yaml.safe_load(path.read_text(encoding="utf-8"))
    return docs


def self_test() -> int:
    """Prove this checker FAILS before trusting any green it reports."""
    failures = []
    gate_step = {"run": "python scripts/cross_language_algorithms.py"}
    act_step = {"uses": "actions/deploy-pages@v4"}

    def wf(jobs):
        return {"on": {"push": None}, "jobs": jobs}

    # (a) THE EMPTY SET, FIRST.
    if not scan({}):
        failures.append("an empty workflow set must be FATAL, not green")

    # (b) THE HISTORICAL DEFECT, planted verbatim: a gate with needs and no if.
    bad = {"t.yml": wf({"cross-language": {"needs": ["rust"], "steps": [gate_step]}})}
    found = scan(bad)
    if not found or not any("SKIPS it" in f for f in found):
        failures.append(f"needs-without-if on a gate must be caught, got {found}")

    # (c) The repaired shapes must pass.
    for label, cond in [("!cancelled()", "${{ !cancelled() }}"), ("always()", "always()")]:
        ok = {"t.yml": wf({"g": {"needs": ["rust"], "if": cond, "steps": [gate_step]}})}
        if scan(ok):
            failures.append(f"the repaired shape ({label}) must pass, got {scan(ok)}")

    # (d) A gate with NO needs is unskippable already.
    if scan({"t.yml": wf({"g": {"steps": [gate_step]}})}):
        failures.append("a gate with no needs must pass")

    # (e) THE DISTINCTION THAT IS THE RULE: a job that ACTS may depend on its
    #     predecessor. Deploying the output of a failed build is wrong, so
    #     skipping is correct there and must not be reported.
    acting = {"p.yml": wf({"build": {"steps": [gate_step]},
                           "deploy": {"needs": ["build"], "steps": [act_step]}})}
    if scan(acting):
        failures.append(f"an acting job with needs must be allowed, got {scan(acting)}")

    # (f) ...but the acting workflow must still not be vacuous: strip the gate
    #     and the anti-vacuity floor must fire.
    only_acting = {"p.yml": wf({"deploy": {"needs": ["build"], "steps": [act_step]}})}
    if not any("not a pass" in f for f in scan(only_acting)):
        failures.append("a tree with no judging job must hit the anti-vacuity floor")

    # (g) An undecidable condition must REFUSE, not pass.
    murky = {"t.yml": wf({"g": {"needs": ["r"], "if": ["weird"], "steps": [gate_step]}})}
    if not any("REFUSING" in f for f in scan(murky)):
        failures.append(f"an undecidable `if:` must refuse, got {scan(murky)}")

    # (h) YAML 1.1 resolves an unquoted `on:` to True; this checker reads jobs
    #     only, so it must be insensitive to that. Guard against a future edit
    #     that starts reading `on` and silently mis-parses every real workflow.
    yamlish = {"t.yml": {True: {"push": None},
                         "jobs": {"g": {"needs": ["r"], "steps": [gate_step]}}}}
    if not any("SKIPS it" in f for f in scan(yamlish)):
        failures.append("the YAML-1.1 `on:` key must not affect job scanning")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(
        "check_gate_cannot_skip SELF-TEST: OK (empty scan fatal proven FIRST, "
        "the historical needs-without-if shape caught, two repaired conditions "
        "accepted, acting-jobs-may-depend upheld, anti-vacuity floor fires, "
        "undecidable condition refused)"
    )
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()

    docs = _load()
    findings = scan(docs)
    if findings:
        print("FAIL: a gate job can be skipped into silence by a dependency.")
        for f in findings:
            print(f"  {f}")
        print()
        print("A judgement that did not happen is not a pass. Give the job")
        print("`if: ${{ !cancelled() }}` so a red dependency leaves it RED,")
        print("not neutral.")
        return 1
    print(f"check_gate_cannot_skip: OK ({len(docs)} workflow file(s) scanned; "
          f"every job that asserts a property runs even when a dependency fails)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
