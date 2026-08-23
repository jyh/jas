#!/usr/bin/env python3
"""In a full-surface lane, one red step must not hide every step behind it.

WHY THIS EXISTS
---------------
`check_gate_cannot_skip.py` asserts that a JOB which judges cannot be skipped
into silence by a failed dependency. Its own "WHAT IT DOES NOT COVER" names the
other half and leaves it open:

    * Step-level `if:` is out of scope. A step that skips itself inside a job
      that ran is a different question from a job that never ran.

This is that different question, and the Windows lane is where it was measured.

GitHub Actions gives every step an implicit `if: success()`. A job's step list is
therefore a CHAIN, not a set: the first red step aborts it and every later step
reports `skipped`. On a run page that reads as *not applicable* rather than *not
checked* -- the identical misreading the job-level gate exists to prevent, one
level down.

MEASURED on `main` at 5095060d. The `windows` job is a single sequential list of
19 steps. `Encoding hygiene` sits at position 5 of 19; `Rust tests`, `Native core
tests`, `Native test gating` and the single-lane cross-language oracle sit at
positions 15-19. A red at position 5 takes all four with it, and takes them
silently.

That is not hypothetical. Across `f40ecff1..6721cd09` -- 61 first-parent commits
-- the Windows lane's Rust steps did not execute at all.

PIN THE UNIT, because the headline is what travels: **61 is the number of
first-parent commits during which those steps were DARK, not the number of
commits that changed Rust.** Measured separately: 28 of the 61 touched
`jas_dioxus/`. Both numbers are real and they answer different questions. The
lane was dark for 61; the content moved underneath it in 28.

WHAT IT ASSERTS
---------------
For every job declared in FULL_SURFACE:

1. Every step that JUDGES declares an `if:` that survives an earlier step's
   failure -- `always()` or `!cancelled()`.
2. No judging step is marked `continue-on-error: true`. That mechanism achieves
   the opposite trade: the step runs and the lane stays green, so the coverage
   is restored and the REPORTING is thrown away. The queue item asks for run
   *and report*; this is the half a careless repair drops.
3. Every step parses into a form this scanner recognises (`run:` or `uses:`). A
   novel spelling REDS rather than being silently skipped -- the same rule
   `check_native_test_gating.py` applies to `#[cfg]` shapes.
4. Every PREMISES declaration names a step that still exists. A declaration that
   outlives its step is deleted in the same commit that removes the step.
5. Every job named in FULL_SURFACE exists in the workflow it names.

A step JUDGES if it runs anything under `scripts/`, or invokes a test runner
(`pytest`, `cargo test`, `swift test`). Derived from the step's own content, not
from a hand list -- the defect `check_lane_coverage.py` was written for is that a
hand-maintained list silently under-covers whatever is added after it.

Steps that only SET UP -- `actions/checkout`, `setup-python`, a toolchain, `pip
install` -- judge nothing and are outside the rule by construction, not by
exemption. Running the Rust tests after a failed checkout would produce noise,
not coverage. That distinction is the whole rule here, exactly as the ACTS/JUDGES
distinction is the whole rule in the job-level sibling.

WHY A DECLARED SET RATHER THAN EVERY JOB
----------------------------------------
The property is desirable in every lane and is asserted in one, deliberately.
P1.5 scopes to the Windows lane; widening to all 16 jobs would rewrite jobs this
item never examined, and a gate that lands green everywhere on its first day has
not been shown to have teeth anywhere. FULL_SURFACE is the extension point and
each entry carries its reason. **This is a stated scope limit, not a claim that
the other 15 jobs are safe -- they are not asserted, and several are chains that
can hide exactly this way.** Widening them is follow-on work, and naming it here
is what keeps it from being forgotten.

WHAT IT DOES NOT COVER
----------------------
* `if:` is matched TEXTUALLY for `always()` / `!cancelled()`, and an expression
  reaching the same effect by another route is not recognised. This REFUSES
  rather than evaluating GitHub expression syntax -- same refusal, same reason,
  as the job-level sibling.
* It cannot know whether a judging step genuinely DEPENDS on an earlier step's
  side effects on disk. A step that needs a file an earlier step wrote will now
  run and fail confusingly instead of skipping quietly. Deciding that is the
  author's job; PREMISES is where the decision gets written down, and the
  narrower `steps.<id>.conclusion` coupling is available for the cases that
  need it (the corpus-freshness step uses exactly that against the LF preflight).
* A multi-command `run:` block is ITSELF a chain and this gate cannot see
  inside one. GitHub runs `bash -eo pipefail`, so the first failing command
  aborts the rest of that block -- and the Windows lane's `Structural gates`
  step invokes over forty gates that way. That is this exact defect one level
  further down. It is NAMED here rather than fixed: splitting it would mean
  forty steps or a runner that collects failures, which is a different change
  from the one this item asked for.
* It says nothing about ORDER. Isolated steps still run in sequence, so a lane
  is no faster; it only stops being blind.
* It does not assert the lane is complete. `check_lane_coverage.py` is what
  requires each gate to appear on both platform families; this one only ensures
  that whatever IS in the lane actually gets to run.
"""

from __future__ import annotations

import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"

# Lanes where a first failure must not hide the rest. Key is "workflow:job";
# the value is the REASON, not decoration -- an entry without an argument is how
# a scope becomes arbitrary.
FULL_SURFACE: dict[str, str] = {
    "test.yml:windows": (
        "The slowest and most expensive lane, and the only one that can see "
        "encoding, newline and path-separator defects. A red at step 5 of 19 "
        "hid its Rust steps for 61 first-parent commits (f40ecff1..6721cd09)."
    ),
}

# Judging steps that must STAY fail-fast, because a later step's result would be
# misleading rather than merely red. Key is "workflow:job:step-name", value is
# the reason. EMPTY TODAY, and that is a real statement: in the Windows lane
# every premise (checkout, setup-python, the toolchain, pip install, and both
# preflights) judges nothing, so all six fall outside the rule by construction
# and need no exemption. The mechanism is proved by self-test case (g) rather
# than by production use -- the same posture `check_lane_coverage.py` takes with
# its own empty EXEMPT.
PREMISES: dict[str, str] = {}

# A step invoking anything under this directory is judging, not setting up.
JUDGES_MARKER = "scripts/"

# Test runners judge too, and they do not live under scripts/. `pytest` catches
# both `python -m pytest` and a bare invocation.
JUDGES_RUNNERS = ("pytest", "cargo test", "swift test")

# Conditions that survive an EARLIER STEP's failure. Identical vocabulary to the
# job-level sibling on purpose: two gates disagreeing about what "survives"
# means would be worse than either being wrong alone.
SURVIVES = ("always()", "!cancelled()", "! cancelled()")

# A lane with one judging step cannot hide anything, so finding one or fewer in
# a lane declared full-surface means the SCANNER broke, not that the lane is
# safe. Derived intent, hand-typed threshold: the number encodes a decision
# ("hiding requires something to hide behind"), which per O3.3 DERIVEDFLOOR is
# the kind that stays typed.
MIN_JUDGING_STEPS = 2


class Unresolvable(Exception):
    """The YAML cannot be decided statically. Refuse; never guess."""


def step_label(step: dict, index: int) -> str:
    """A stable human name for a step, for declarations and for findings."""
    name = step.get("name")
    if isinstance(name, str) and name.strip():
        return name.strip()
    uses = step.get("uses")
    if isinstance(uses, str) and uses.strip():
        return uses.strip()
    run = step.get("run")
    if isinstance(run, str) and run.strip():
        return run.strip().splitlines()[0].strip()
    return f"<step #{index}>"


def judges(step: dict) -> bool:
    """True iff this step asserts a property rather than preparing to.

    Raises Unresolvable for a step shape this scanner does not recognise. A
    novel spelling must RED, not pass -- a step the scanner cannot read is a
    step whose isolation nobody has checked.
    """
    run = step.get("run")
    if run is None:
        if "uses" in step:
            return False  # an action step sets up; it does not run our gates
        raise Unresolvable("step has neither `run:` nor `uses:`")
    if not isinstance(run, str):
        raise Unresolvable(f"unrecognised `run:` shape: {type(run).__name__}")
    if JUDGES_MARKER in run:
        return True
    return any(runner in run for runner in JUDGES_RUNNERS)


def condition_survives_step_failure(cond: object) -> bool:
    """True iff `if:` still runs the step when an EARLIER STEP failed."""
    if cond is None:
        return False
    if isinstance(cond, bool):
        # `if: true` does NOT override the implicit success() for steps -- a
        # truthy constant still respects the job's failure state. Treat it as
        # not surviving rather than reasoning about GitHub's coercion rules.
        return False
    if not isinstance(cond, str):
        raise Unresolvable(f"unrecognised `if:` shape: {type(cond).__name__}")
    text = cond.replace("${{", " ").replace("}}", " ")
    return any(marker in text for marker in SURVIVES)


def scan(docs: dict[str, dict]) -> list[str]:
    """Findings for a mapping of workflow-name -> parsed YAML."""
    findings: list[str] = []
    seen_premises: set[str] = set()

    for key, reason in sorted(FULL_SURFACE.items()):
        if ":" not in key:
            findings.append(f"FULL_SURFACE key {key!r} is not 'workflow:job'")
            continue
        wf_name, job_name = key.split(":", 1)
        doc = docs.get(wf_name)
        if not isinstance(doc, dict):
            findings.append(
                f"{key}: declared full-surface but workflow {wf_name!r} is "
                f"absent or unreadable -- a declaration outliving its lane"
            )
            continue
        job = (doc.get("jobs") or {}).get(job_name)
        if not isinstance(job, dict):
            findings.append(
                f"{key}: declared full-surface but that job does not exist "
                f"(reason on file: {reason})"
            )
            continue

        judging = 0
        for index, step in enumerate(job.get("steps") or []):
            if not isinstance(step, dict):
                findings.append(f"{key}: step #{index} is not a mapping")
                continue
            label = step_label(step, index)
            try:
                if not judges(step):
                    continue
            except Unresolvable as exc:
                findings.append(
                    f"{key}:{label}: REFUSING to guess -- {exc}"
                )
                continue

            judging += 1
            premise_key = f"{key}:{label}"
            if premise_key in PREMISES:
                seen_premises.add(premise_key)
                continue

            if step.get("continue-on-error") is True:
                findings.append(
                    f"{key}:{label} is `continue-on-error: true` -- that "
                    f"restores the coverage and throws away the REPORT. The "
                    f"lane would go green over a real failure."
                )
                continue

            try:
                survives = condition_survives_step_failure(step.get("if"))
            except Unresolvable as exc:
                findings.append(f"{key}:{label}: REFUSING to guess -- {exc}")
                continue
            if not survives:
                findings.append(
                    f"{key}:{label} judges a property with no surviving `if:` "
                    f"-- an earlier red step SKIPS it, and a skipped step reads "
                    f"as 'not applicable' rather than 'not checked'"
                )

        # ANTI-VACUITY, per lane. A lane with nothing to hide behind cannot be
        # hiding anything; finding that in a lane declared full-surface means
        # the scanner stopped seeing steps.
        if judging < MIN_JUDGING_STEPS:
            findings.append(
                f"{key}: only {judging} judging step(s) found, expected at "
                f"least {MIN_JUDGING_STEPS} -- a lane declared full-surface "
                f"with nothing to hide is a broken scan, not a pass"
            )

    # No declaration may outlive its step. The declarations are hand-written and
    # the scan reads YAML, so the two are independent oracles -- the same
    # argument `check_native_test_gating.py` makes for its ledger.
    for stale in sorted(set(PREMISES) - seen_premises):
        findings.append(
            f"PREMISES declares {stale!r}, which is not a judging step in that "
            f"lane -- delete the row in the commit that removes the step"
        )

    if not FULL_SURFACE:
        findings.append(
            "FULL_SURFACE is empty -- no lane is asserted, so this gate cannot "
            "fail. That is not a pass."
        )
    return findings


def _load() -> dict[str, dict]:
    docs = {}
    for path in sorted(WORKFLOWS.glob("*.yml")) + sorted(WORKFLOWS.glob("*.yaml")):
        docs[path.name] = yaml.safe_load(path.read_text(encoding="utf-8"))
    return docs


def self_test() -> int:
    """Prove this checker FAILS before trusting any green it reports."""
    global FULL_SURFACE, PREMISES
    saved_surface, saved_premises = FULL_SURFACE, PREMISES
    failures: list[str] = []

    gate = {"name": "gate", "run": "python scripts/check_thing.py"}
    tests = {"name": "tests", "run": "cd jas_dioxus && cargo test"}
    setup = {"uses": "actions/checkout@v4"}
    pip = {"run": "pip install -r requirements.txt"}
    ok_if = "${{ !cancelled() }}"

    def wf(steps):
        return {"t.yml": {"on": {"push": None},
                          "jobs": {"lane": {"runs-on": "windows-latest",
                                            "steps": steps}}}}

    try:
        FULL_SURFACE = {"t.yml:lane": "self-test"}
        PREMISES = {}

        # (a) THE EMPTY SET, FIRST. A scan with no workflows must not be green.
        if not scan({}):
            failures.append("an empty workflow set must be FATAL, not green")

        # (b) THE HISTORICAL DEFECT, planted verbatim: the Windows lane's shape
        #     -- a chain of judging steps, none isolated.
        found = scan(wf([setup, pip, gate, tests]))
        if len([f for f in found if "no surviving `if:`" in f]) != 2:
            failures.append(f"both unisolated judging steps must be caught, got {found}")

        # (c) The repaired shape passes.
        good = [setup, pip, dict(gate, **{"if": ok_if}), dict(tests, **{"if": ok_if})]
        if scan(wf(good)):
            failures.append(f"the repaired lane must pass, got {scan(wf(good))}")

        # (d) `always()` is accepted too.
        alt = [setup, pip, dict(gate, **{"if": "always()"}),
               dict(tests, **{"if": "always()"})]
        if scan(wf(alt)):
            failures.append(f"always() must be accepted, got {scan(wf(alt))}")

        # (e) THE DISTINCTION THAT IS THE RULE: setup steps judge nothing, so an
        #     un-isolated checkout/pip must NOT be reported. If this ever fires,
        #     the gate is demanding that the Rust tests run after a failed
        #     checkout -- noise, not coverage.
        only_setup = scan(wf([setup, pip, dict(gate, **{"if": ok_if}),
                              dict(tests, **{"if": ok_if})]))
        if any("checkout" in f or "pip install" in f for f in only_setup):
            failures.append(f"setup steps must never be demanded, got {only_setup}")

        # (f) THE HALF A CARELESS REPAIR DROPS: continue-on-error restores the
        #     run and throws away the report. It must be caught, not accepted.
        sloppy = [setup, pip, dict(gate, **{"continue-on-error": True}),
                  dict(tests, **{"if": ok_if})]
        if not any("throws away the REPORT" in f for f in scan(wf(sloppy))):
            failures.append(f"continue-on-error must be caught, got {scan(wf(sloppy))}")

        # (g) THE PREMISES MECHANISM, which has no production use today. A
        #     declared premise is allowed to stay fail-fast...
        PREMISES = {"t.yml:lane:gate": "self-test premise"}
        with_premise = scan(wf([setup, pip, gate, dict(tests, **{"if": ok_if})]))
        if with_premise:
            failures.append(f"a declared premise must be allowed, got {with_premise}")

        # (h) ...and a premise declaration must not outlive its step.
        stale = scan(wf([setup, pip, dict(tests, **{"if": ok_if}),
                         dict(gate, **{"if": ok_if, "name": "renamed"})]))
        if not any("delete the row" in f for f in stale):
            failures.append(f"a stale PREMISES row must be caught, got {stale}")
        PREMISES = {}

        # (i) ANTI-VACUITY: a lane the scanner can no longer read steps in must
        #     RED rather than report no violations.
        if not any("broken scan" in f for f in scan(wf([setup, pip]))):
            failures.append("a lane with no judging steps must hit the floor")

        # (j) A novel step shape must REFUSE, not pass silently.
        murky = scan(wf([setup, pip, dict(gate, **{"if": ok_if}),
                         dict(tests, **{"if": ok_if}), {"name": "odd"}]))
        if not any("REFUSING" in f for f in murky):
            failures.append(f"an unrecognised step shape must refuse, got {murky}")

        # (k) An undecidable `if:` must refuse rather than be read as surviving.
        weird = scan(wf([setup, pip, dict(gate, **{"if": ["weird"]}),
                         dict(tests, **{"if": ok_if})]))
        if not any("REFUSING" in f for f in weird):
            failures.append(f"an undecidable `if:` must refuse, got {weird}")

        # (l) A FULL_SURFACE entry naming a job that does not exist is a
        #     declaration outliving its lane, and must red.
        FULL_SURFACE = {"t.yml:ghost": "self-test"}
        if not any("does not exist" in f for f in scan(wf([gate]))):
            failures.append("a FULL_SURFACE row for a missing job must red")

        # (m) An empty FULL_SURFACE cannot fail, so it must not be green.
        FULL_SURFACE = {}
        if not any("not a pass" in f for f in scan(wf([gate]))):
            failures.append("an empty FULL_SURFACE must hit the anti-vacuity floor")

        # (n) YAML 1.1 resolves an unquoted `on:` to True. This checker reads
        #     `jobs` only and must be insensitive to that.
        FULL_SURFACE = {"t.yml:lane": "self-test"}
        yamlish = {"t.yml": {True: {"push": None},
                             "jobs": {"lane": {"steps": [gate, tests]}}}}
        if len([f for f in scan(yamlish) if "no surviving `if:`" in f]) != 2:
            failures.append("the YAML-1.1 `on:` key must not affect step scanning")
    finally:
        FULL_SURFACE, PREMISES = saved_surface, saved_premises

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(
        "check_step_cannot_hide SELF-TEST: OK (empty scan fatal proven FIRST, "
        "the historical chain shape caught, two repaired conditions accepted, "
        "setup-steps-are-not-demanded upheld, continue-on-error caught, the "
        "PREMISES mechanism and its stale-row guard both exercised, "
        "anti-vacuity floors fire, novel step and undecidable `if:` refused)"
    )
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()

    docs = _load()
    findings = scan(docs)
    if findings:
        print("FAIL: one red step would hide the rest of a full-surface lane.")
        for f in findings:
            print(f"  {f}")
        print()
        print("A step list is a CHAIN: GitHub gives every step an implicit")
        print("`if: success()`, so the first red aborts the rest and they report")
        print("`skipped` -- which reads as 'not applicable', not 'not checked'.")
        print("Give each judging step `if: ${{ !cancelled() }}` so the lane")
        print("reports its whole surface in one run. Do NOT reach for")
        print("`continue-on-error`: that keeps the run and discards the verdict.")
        return 1
    lanes = len(FULL_SURFACE)
    print(f"check_step_cannot_hide: OK ({lanes} full-surface lane(s); every "
          f"judging step runs and reports even when an earlier step fails)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
